/**
 * Apple StoreKit 2 JWS verification.
 *
 * iOS clients ship the JWS representation of a `Transaction` from
 * `Transaction.currentEntitlements` as `Authorization: Bearer <jws>`. We verify:
 *
 *   1. The JWS signature (ES256, signed by the leaf cert in `x5c[0]`).
 *   2. Each cert in `x5c` is within its validity window AND signed by the next cert up;
 *      the chain's top cert is byte-identical (DER equality) to the embedded Apple Root
 *      CA G3 PEM. Apple uses G3 to sign all StoreKit JWS as of 2026.
 *   3. The payload's `bundleId`, `productId`, and `expiresDate`.
 *
 * Chain verification uses `node:crypto`'s `X509Certificate` (Workers nodejs_compat).
 * The signature on the JWS itself uses `jose.jwtVerify` with the leaf cert's public key.
 *
 * Reference: Apple's [App Store Server Notifications V2 Receipt JWS](
 * https://developer.apple.com/documentation/appstoreservernotifications/jwstransaction).
 */

import { X509Certificate } from "node:crypto";
import { decodeProtectedHeader, importX509, jwtVerify } from "jose";

/**
 * Apple Root CA G3 — the only root currently used to sign StoreKit2 JWS payloads.
 * Published at https://www.apple.com/certificateauthority/AppleRootCA-G3.cer.
 * SHA-256 fingerprint: 63:34:3A:BF:B8:9A:6A:03:EB:B5:7E:9B:3F:5F:A7:BE:7C:4F:5C:75:6F:30:17:B3:A8:C4:88:C3:65:3E:91:79
 */
const APPLE_ROOT_CA_G3_PEM = `-----BEGIN CERTIFICATE-----
MIICQzCCAcmgAwIBAgIILcX8iNLFS5UwCgYIKoZIzj0EAwMwZzEbMBkGA1UEAwwS
QXBwbGUgUm9vdCBDQSAtIEczMSYwJAYDVQQLDB1BcHBsZSBDZXJ0aWZpY2F0aW9u
IEF1dGhvcml0eTETMBEGA1UECgwKQXBwbGUgSW5jLjELMAkGA1UEBhMCVVMwHhcN
MTQwNDMwMTgxOTA2WhcNMzkwNDMwMTgxOTA2WjBnMRswGQYDVQQDDBJBcHBsZSBS
b290IENBIC0gRzMxJjAkBgNVBAsMHUFwcGxlIENlcnRpZmljYXRpb24gQXV0aG9y
aXR5MRMwEQYDVQQKDApBcHBsZSBJbmMuMQswCQYDVQQGEwJVUzB2MBAGByqGSM49
AgEGBSuBBAAiA2IABJjpLz1AcqTtkyJygRMc3RCV8cWjTnHcFBbZDuWmBSp3ZHtf
TjjTuxxEtX/1H7YyYl3J6YRbTzBPEVoA/VhYDKX1DyxNB0cTddqXl5dvMVztK517
IDvYuVTZXpmkOlEKMaNCMEAwHQYDVR0OBBYEFLuw3qFYM4iapIqZ3r6966/ayySr
MA8GA1UdEwEB/wQFMAMBAf8wDgYDVR0PAQH/BAQDAgEGMAoGCCqGSM49BAMDA2gA
MGUCMQCD6cHEFl4aXTQY2e3v9GwOAEZLuN+yRhHFD/3meoyhpmvOwgPUnPWTxnS4
at+qIxUCMG1mihDK1A3UT82NQz60imOlM27jbdoXt2QfyFMm+YhidDkLF1vLUagM
6BgD56KyKA==
-----END CERTIFICATE-----`;

const APPLE_ROOT_FINGERPRINT_SHA256 =
  "63:34:3A:BF:B8:9A:6A:03:EB:B5:7E:9B:3F:5F:A7:BE:7C:4F:5C:75:6F:30:17:B3:A8:C4:88:C3:65:3E:91:79";

/** Apple's `JWSTransactionDecodedPayload` (subset we care about). */
export type AppleTransactionPayload = {
  transactionId: string;
  originalTransactionId: string;
  webOrderLineItemId?: string;
  bundleId: string;
  productId: string;
  subscriptionGroupIdentifier?: string;
  purchaseDate: number;
  originalPurchaseDate: number;
  expiresDate?: number;
  type: string; // "Auto-Renewable Subscription" | "Non-Consumable" | ...
  inAppOwnershipType?: string;
  signedDate: number;
  environment: "Sandbox" | "Production";
  revocationDate?: number;
  revocationReason?: number;
};

export class AppleJwsError extends Error {
  constructor(public code: string, message: string) {
    super(message);
    this.name = "AppleJwsError";
  }
}

/**
 * Verify the JWS signature, validate the cert chain to Apple Root CA G3, and check the
 * payload fields. Throws `AppleJwsError` on any failure with a short code suitable for
 * surfacing to the caller (`error: "jws-<code>"`).
 *
 * @param jws  Apple-signed JWS string (3 dot-separated base64url segments).
 * @param expectedBundleId  Must match the iOS app's `CFBundleIdentifier`.
 * @param allowedProductIds  Set of valid StoreKit product IDs (monthly + yearly).
 * @param gracePeriodMs  Honour expired transactions within this window (Apple's billing
 *   retry grace is up to ~16 days; default = 0 means strict expiry).
 */
export async function verifyAppleJws(
  jws: string,
  expectedBundleId: string,
  allowedProductIds: Set<string>,
  gracePeriodMs = 0,
  options: { allowXcodeLocalJws?: boolean } = {},
): Promise<AppleTransactionPayload> {
  // 1. Parse the protected header to get the cert chain.
  let header: ReturnType<typeof decodeProtectedHeader>;
  try {
    header = decodeProtectedHeader(jws);
  } catch (e) {
    throw new AppleJwsError("bad-header", `JWS header parse failed: ${(e as Error).message}`);
  }
  if (header.alg !== "ES256") {
    throw new AppleJwsError("bad-alg", `expected ES256, got ${header.alg}`);
  }
  const x5c = header.x5c as string[] | undefined;
  if (!x5c || x5c.length < 1) {
    throw new AppleJwsError(
      "missing-x5c",
      `JWS header missing x5c (keys=${Object.keys(header).join(",")})`,
    );
  }

  // Xcode-local detection: when running with a `.storekit` configuration file, Xcode
  // signs the JWS with a *self-signed* certificate (`kid: "Apple_Xcode_Key"`, subject
  // "StoreKit Testing in Xcode") that does NOT chain up to Apple Root CA G3. We only
  // accept this path when the Worker is explicitly configured for dev (env-gated) — in
  // production the absence of a real Apple chain is fatal.
  const isXcodeLocal = header.kid === "Apple_Xcode_Key";
  if (isXcodeLocal && !options.allowXcodeLocalJws) {
    throw new AppleJwsError(
      "xcode-local-disabled",
      "JWS is Xcode-locally signed; set ALLOW_XCODE_LOCAL_JWS=true to accept (dev only)",
    );
  }
  if (!isXcodeLocal && x5c.length < 2) {
    // Real Apple JWS always ships leaf + intermediate + (sometimes) root in x5c. A
    // single-cert chain that ISN'T the Xcode test signer is almost certainly tampered.
    throw new AppleJwsError("short-x5c", "real Apple JWS must have leaf + intermediate certs");
  }

  // 2. Load the leaf cert as a public key, then verify the JWS signature with it.
  // jose's `importX509` wants PEM, so wrap the DER base64.
  const leafPem = `-----BEGIN CERTIFICATE-----\n${chunk64(x5c[0])}\n-----END CERTIFICATE-----`;
  let leafKey: Awaited<ReturnType<typeof importX509>>;
  try {
    leafKey = await importX509(leafPem, "ES256");
  } catch (e) {
    throw new AppleJwsError("bad-leaf-cert", `leaf cert import failed: ${(e as Error).message}`);
  }
  let payload: AppleTransactionPayload;
  try {
    const verified = await jwtVerify(jws, leafKey, { algorithms: ["ES256"] });
    payload = verified.payload as unknown as AppleTransactionPayload;
  } catch (e) {
    throw new AppleJwsError("bad-signature", `JWS signature invalid: ${(e as Error).message}`);
  }

  // 3. Verify the x5c chain — only for real Apple JWS. Xcode-local has a self-signed
  // leaf with no chain to walk, and we already accepted that path above (gated by env).
  if (!isXcodeLocal) {
    await verifyChain(x5c);
  }

  // 4. Payload checks.
  if (payload.bundleId !== expectedBundleId) {
    throw new AppleJwsError("bad-bundle", `expected bundle ${expectedBundleId}, got ${payload.bundleId}`);
  }
  if (!allowedProductIds.has(payload.productId)) {
    throw new AppleJwsError("bad-product", `productId ${payload.productId} not in allowed set`);
  }
  if (payload.revocationDate) {
    // Apple revoked this transaction (refund, family-share end, etc.). Treat as no entitlement.
    throw new AppleJwsError("revoked", `transaction revoked at ${payload.revocationDate}`);
  }
  if (payload.expiresDate !== undefined) {
    const now = Date.now();
    if (now > payload.expiresDate + gracePeriodMs) {
      throw new AppleJwsError(
        "expired",
        `subscription expired at ${payload.expiresDate} (now ${now}, grace ${gracePeriodMs})`,
      );
    }
  }

  return payload;
}

/**
 * Walk the x5c chain bottom-up and anchor it to the embedded Apple Root CA G3. Each link
 * must be (a) inside its validity window and (b) signed by the next cert up; the chain's
 * top cert must be byte-identical (DER) to the embedded trusted root. DER equality is a
 * strictly stronger invariant than fingerprint equality and equally cheap to check, so
 * the trust anchor is by-value rather than by-hash.
 */
async function verifyChain(x5c: string[]): Promise<void> {
  let certs: X509Certificate[];
  try {
    certs = x5c.map((derB64) => {
      const der = Uint8Array.from(atob(derB64), (c) => c.charCodeAt(0));
      return new X509Certificate(der);
    });
  } catch (e) {
    throw new AppleJwsError("chain-parse", `cert parse failed: ${(e as Error).message}`);
  }

  // 4a. Each cert must be within its validity window. `X509Certificate.verify()` checks
  // signature only — an expired-but-correctly-signed intermediate would otherwise pass.
  const nowMs = Date.now();
  for (let i = 0; i < certs.length; i++) {
    const notBefore = Date.parse(certs[i].validFrom);
    const notAfter = Date.parse(certs[i].validTo);
    if (Number.isNaN(notBefore) || Number.isNaN(notAfter)) {
      throw new AppleJwsError("chain-validity-parse", `cert[${i}] validity dates unparseable`);
    }
    if (nowMs < notBefore || nowMs > notAfter) {
      throw new AppleJwsError(
        "chain-expired",
        `cert[${i}] outside validity (notBefore=${certs[i].validFrom}, notAfter=${certs[i].validTo})`,
      );
    }
  }

  // 4b. Each cert in the chain must be signed by the next one up.
  for (let i = 0; i < certs.length - 1; i++) {
    let ok: boolean;
    try {
      ok = certs[i].verify(certs[i + 1].publicKey);
    } catch (e) {
      throw new AppleJwsError("chain-verify", `cert[${i}] verify threw: ${(e as Error).message}`);
    }
    if (!ok) {
      throw new AppleJwsError("chain-broken", `cert[${i}] not signed by cert[${i + 1}]`);
    }
  }

  // 4c. Anchor the chain to the embedded Apple Root CA G3 by DER equality. SHA-256
  // fingerprint match is necessary but not sufficient — the real check is that the top
  // cert's bytes are identical to the PEM we shipped, so its public key is by definition
  // the one that signed everything below. `X509Certificate.raw` is the DER buffer.
  const trustedRoot = new X509Certificate(APPLE_ROOT_CA_G3_PEM);
  if (trustedRoot.fingerprint256 !== APPLE_ROOT_FINGERPRINT_SHA256) {
    // Embedded PEM corruption guard — should never trip in practice.
    throw new AppleJwsError("trust-anchor", "embedded Apple Root CA G3 fingerprint mismatch");
  }
  const topCert = certs[certs.length - 1];
  if (!certBytesEqual(topCert.raw, trustedRoot.raw)) {
    throw new AppleJwsError(
      "not-apple-root",
      `top cert (fingerprint ${topCert.fingerprint256}) does not equal embedded Apple Root G3 DER`,
    );
  }
}

/// Byte-equality on `X509Certificate.raw`. We normalize both sides through `Buffer.from`
/// because the Workers `nodejs_compat` runtime has historically returned the `.raw`
/// property as either a `Buffer` (Node-style) or an `ArrayBuffer` (Web-style) depending
/// on version. Indexing an `ArrayBuffer` directly via `[i]` returns `undefined`, which
/// would make a hand-rolled byte loop falsely report "equal" or "not equal" depending on
/// which side wraps first. `Buffer.from` accepts both shapes and normalizes to a real
/// indexable buffer.
function certBytesEqual(a: Buffer | ArrayBuffer, b: Buffer | ArrayBuffer): boolean {
  return Buffer.from(a).equals(Buffer.from(b));
}

/** Wrap a long base64 string to 64-char lines (PEM convention; jose tolerates either way). */
function chunk64(b64: string): string {
  const out: string[] = [];
  for (let i = 0; i < b64.length; i += 64) out.push(b64.slice(i, i + 64));
  return out.join("\n");
}
