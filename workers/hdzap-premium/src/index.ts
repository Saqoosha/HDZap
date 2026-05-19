import { Hono } from "hono";
import { AwsClient } from "aws4fetch";
import { AppleJwsError, verifyAppleJws } from "./appleJws";

type Env = {
  CARTESIA_API_KEY: string;
  AZURE_SPEECH_KEY: string;
  /**
   * IAM user (`hdzap-premium-polly`) scoped to a single permission:
   * `polly:SynthesizeSpeech`. The Worker signs Polly requests with SigV4 using these long-
   * lived keys — much simpler than the Cognito identity-pool path the iOS-direct version
   * of YourLaps needed, since the Worker is itself a trusted server.
   */
  POLLY_ACCESS_KEY_ID: string;
  POLLY_SECRET_ACCESS_KEY: string;
  /**
   * Shared "preview" bearer for non-subscribers — gates the limited preview path used by
   * the in-app voice picker before a subscription exists. Subscribers send JWS instead and
   * get the unrestricted path; the bearer path stays narrow (50-char text cap) so a leaked
   * value can't be used to ship a full free competitor.
   */
  DEV_BEARER: string;
  /**
   * When "true" (string), accept self-signed JWS from Xcode's local `.storekit`
   * configuration — these have `kid: "Apple_Xcode_Key"` and don't chain to Apple Root CA G3,
   * so they're only safe to honour in dev/staging. Production deploys leave this unset.
   */
  ALLOW_XCODE_LOCAL_JWS?: string;
};

const app = new Hono<{ Bindings: Env }>();

const ALLOWED_PROVIDERS = new Set(["cartesia", "polly", "azure"]);
const ALLOWED_CARTESIA_MODELS = new Set(["sonic-3.5", "sonic-3", "sonic-2", "sonic"]);
const ALLOWED_LANGS = new Set(["ja", "en"]);

// Two-tier text limits: JWS-authed callers (real subscribers) get a generous limit for
// final-lap summaries; bearer-authed preview callers get a tight cap that's just enough
// for "ラップ3、12.34、ベストラップ" -class sample sentences. A leaked bearer can't be turned
// into a "free TTS-as-a-service" with a 50-char cap on every request.
const MAX_TRANSCRIPT_CHARS_JWS = 300;
const MAX_TRANSCRIPT_CHARS_BEARER = 60;

/** Apple expects these bundle + product IDs exactly. Update both sides if Apple changes. */
const APP_BUNDLE_ID = "sh.saqoo.HDZap";
const ALLOWED_PRODUCT_IDS = new Set([
  "sh.saqoo.HDZap.premium.monthly",
  "sh.saqoo.HDZap.premium.yearly",
]);
/**
 * Apple's billing-retry grace is up to ~16 days after `expiresDate`. Honour it so a real
 * subscriber whose card temporarily declined doesn't lose Premium audio mid-race.
 */
const GRACE_PERIOD_MS = 16 * 24 * 60 * 60 * 1000;

// AWS region the IAM user's keys are scoped against and where Polly synthesises speech.
// Tokyo is closest to the JP user base; en-US voices stream from the same region without
// added latency since Polly Neural runs in every Polly region.
const AWS_REGION = "ap-northeast-1";

app.get("/", (c) => c.text("hdzap-premium worker — POST /tts"));
app.get("/healthz", (c) => c.json({ ok: true, ts: Date.now() }));

app.post("/tts", async (c) => {
  // Two-tier auth: real subscribers ship Apple-signed JWS; non-subscribers use the shared
  // dev bearer for in-app voice previews. The JWS path is Apple-cryptographic-proof, the
  // bearer path is rate-limited by text length so a leaked bearer can't bill us into the
  // ground (60 chars max + Cartesia/Polly/Azure caps).
  const auth = c.req.header("Authorization") || "";
  const token = auth.replace(/^Bearer\s+/i, "").trim();
  if (!token) return c.json({ error: "unauthorized", reason: "missing-token" }, 401);

  // JWS has 3 dot-separated base64url segments; the bearer is a single opaque random
  // string. This shape check is a routing hint, not a security boundary — we still
  // cryptographically verify the JWS below.
  const looksLikeJws = token.split(".").length === 3;
  let authMode: "jws" | "bearer";
  let userId: string | null = null;
  let maxChars: number;

  if (looksLikeJws) {
    try {
      const payload = await verifyAppleJws(
        token,
        APP_BUNDLE_ID,
        ALLOWED_PRODUCT_IDS,
        GRACE_PERIOD_MS,
        { allowXcodeLocalJws: c.env.ALLOW_XCODE_LOCAL_JWS === "true" },
      );
      authMode = "jws";
      userId = payload.originalTransactionId;
      maxChars = MAX_TRANSCRIPT_CHARS_JWS;
      console.log("auth=jws", { userId, productId: payload.productId, env: payload.environment });
    } catch (e) {
      const code = e instanceof AppleJwsError ? e.code : "internal";
      const message = (e as Error).message;
      console.error("jws-verify-failed", { code, message });
      if (e instanceof AppleJwsError) {
        return c.json({ error: `jws-${e.code}`, message: e.message }, 401);
      }
      return c.json({ error: "jws-internal", message }, 401);
    }
  } else {
    if (!c.env.DEV_BEARER || token !== c.env.DEV_BEARER) {
      console.error("auth=bearer-rejected", { tokenLen: token.length });
      return c.json({ error: "unauthorized", reason: "bad-bearer" }, 401);
    }
    authMode = "bearer";
    maxChars = MAX_TRANSCRIPT_CHARS_BEARER;
    console.log("auth=bearer");
  }

  let body: {
    provider?: string;
    text?: string;
    voice?: string;
    lang?: string;
    model?: string;
    rate?: number;
    pitch?: number;
  };
  try {
    body = await c.req.json();
  } catch {
    return c.json({ error: "invalid-json" }, 400);
  }

  // Default to cartesia for backwards compat with the iOS build that doesn't yet send `provider`.
  const provider = (body.provider || "cartesia").trim().toLowerCase();
  const text = (body.text || "").trim();
  const voice = (body.voice || "").trim();
  const lang = (body.lang || "").trim();
  // Rate (speech tempo) and pitch (semitone offset) are accepted as raw numbers from the
  // client and clamped here — out-of-range values would otherwise produce monster/chipmunk
  // audio that's not useful for racing. Cartesia ignores both; Polly + Azure honour them
  // via SSML `<prosody>`.
  const rate = clamp(body.rate ?? 1.0, 0.5, 2.5);
  const pitch = clamp(body.pitch ?? 0.0, -10.0, 10.0);

  if (!ALLOWED_PROVIDERS.has(provider)) return c.json({ error: "bad-provider" }, 400);
  if (!text) return c.json({ error: "missing-text" }, 400);
  if (text.length > maxChars)
    return c.json({ error: "text-too-long", limit: maxChars, authMode }, 400);
  if (!voice) return c.json({ error: "missing-voice" }, 400);
  if (!ALLOWED_LANGS.has(lang)) return c.json({ error: "bad-lang" }, 400);

  void userId; // reserved for per-user rate limiting via KV — wire up in a follow-up.

  try {
    if (provider === "cartesia") {
      const model = (body.model || "sonic-3.5").trim();
      if (!ALLOWED_CARTESIA_MODELS.has(model)) return c.json({ error: "bad-model" }, 400);
      return await proxyCartesia(c.env.CARTESIA_API_KEY, model, voice, lang, text);
    }
    if (provider === "polly") {
      return await proxyPolly(
        c.env.POLLY_ACCESS_KEY_ID,
        c.env.POLLY_SECRET_ACCESS_KEY,
        voice,
        lang,
        text,
        rate,
        pitch,
      );
    }
    if (provider === "azure") {
      return await proxyAzure(c.env.AZURE_SPEECH_KEY, voice, lang, text, rate, pitch);
    }
  } catch (e) {
    return c.json(
      { error: "internal", message: e instanceof Error ? e.message : String(e) },
      502
    );
  }
  return c.json({ error: "unreachable" }, 500);
});

function clamp(n: number, lo: number, hi: number): number {
  return Math.min(hi, Math.max(lo, n));
}

// MARK: - Cartesia (SSE → raw PCM s16le 24kHz)

async function proxyCartesia(
  apiKey: string,
  model: string,
  voiceId: string,
  lang: string,
  text: string,
): Promise<Response> {
  const resp = await fetch("https://api.cartesia.ai/tts/sse", {
    method: "POST",
    headers: {
      "X-API-Key": apiKey,
      "Cartesia-Version": "2024-11-13",
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      model_id: model,
      transcript: text,
      voice: { mode: "id", id: voiceId },
      output_format: { container: "raw", encoding: "pcm_s16le", sample_rate: 24000 },
      language: lang,
    }),
  });

  if (!resp.ok) {
    const errBody = await resp.text();
    return new Response(
      JSON.stringify({ error: "upstream-cartesia", status: resp.status, body: errBody.slice(0, 500) }),
      { status: resp.status, headers: { "Content-Type": "application/json" } },
    );
  }

  return new Response(resp.body, {
    status: 200,
    headers: {
      "Content-Type": "text/event-stream",
      "X-HDZap-Provider": "cartesia",
      "X-HDZap-Format": "pcm-sse",
      "Cache-Control": "no-store",
      "X-Accel-Buffering": "no",
    },
  });
}

// MARK: - AWS Polly (chunked mp3)

async function proxyPolly(
  accessKeyId: string,
  secretAccessKey: string,
  voiceId: string,
  lang: string,
  text: string,
  rate: number,
  pitch: number,
): Promise<Response> {
  // The IAM user is restricted to `polly:SynthesizeSpeech` only — no session token needed
  // since the keys are long-lived (rotated via 1Password + `wrangler secret put` when we
  // suspect compromise). aws4fetch signs the request with SigV4.
  const aws = new AwsClient({
    accessKeyId,
    secretAccessKey,
    region: AWS_REGION,
    service: "polly",
  });

  // Polly Neural voices accept `rate` but reject `pitch` — the latter is a Standard-engine-
  // only feature ("Unsupported Neural feature" 400). Since our entire Polly catalog is
  // Neural (Takumi/Kazuha/Tomoko), we just skip the pitch attribute here and let the iOS UI
  // hide the slider for this provider. `rate` arrives as a multiplier (1.0 = baseline); we
  // round to the closest percentage Polly understands (50%-200%).
  void pitch; // intentionally ignored on Polly Neural
  const ratePct = `${Math.round(rate * 100)}%`;
  const ssml =
    `<speak><prosody rate="${ratePct}">${escapeSsml(text)}</prosody></speak>`;

  const url = `https://polly.${AWS_REGION}.amazonaws.com/v1/speech`;
  const resp = await aws.fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      Text: ssml,
      TextType: "ssml",
      VoiceId: voiceId,
      OutputFormat: "mp3",
      Engine: "neural",
      LanguageCode: lang === "ja" ? "ja-JP" : "en-US",
    }),
  });

  if (!resp.ok) {
    const errBody = await resp.text();
    return new Response(
      JSON.stringify({ error: "upstream-polly", status: resp.status, body: errBody.slice(0, 500) }),
      { status: resp.status, headers: { "Content-Type": "application/json" } },
    );
  }

  return new Response(resp.body, {
    status: 200,
    headers: {
      "Content-Type": "audio/mpeg",
      "X-HDZap-Provider": "polly",
      "X-HDZap-Format": "mp3",
      "Cache-Control": "no-store",
    },
  });
}

// MARK: - Azure Speech (chunked mp3)

/** Azure JA-Neural voices are gender-tagged by name suffix — Daichi/Keita/Naoki are male, the
 *  rest of the catalog is female. The SSML `xml:gender` attribute is required for some voices,
 *  otherwise Azure returns 400. */
function azureGenderFor(voiceId: string): "Male" | "Female" {
  return /Daichi|Keita|Naoki/.test(voiceId) ? "Male" : "Female";
}

async function proxyAzure(
  subscriptionKey: string,
  voiceId: string,
  lang: string,
  text: string,
  rate: number,
  pitch: number,
): Promise<Response> {
  const region = "japaneast";
  const xmlLang = lang === "ja" ? "ja-JP" : "en-US";
  const gender = azureGenderFor(voiceId);
  // Azure accepts the same SSML `<prosody>` shape as Polly. Rate as multiplier (1.4 = 40%
  // faster); pitch as signed percentage like "+10%". We convert semitones → percent via the
  // familiar 100 cents = 1 semitone musical interval, with each semitone ≈ 6% on Azure's
  // perceptual scale. Capped at ±50% server-side anyway.
  const rateStr = rate.toFixed(2);
  const pitchPct = `${pitch >= 0 ? "+" : ""}${Math.round(pitch * 6)}%`;
  const ssml =
    `<speak version='1.0' xml:lang='${xmlLang}'>` +
    `<voice xml:lang='${xmlLang}' xml:gender='${gender}' name='${voiceId}'>` +
    `<prosody rate='${rateStr}' pitch='${pitchPct}'>${escapeSsml(text)}</prosody>` +
    `</voice></speak>`;

  const resp = await fetch(
    `https://${region}.tts.speech.microsoft.com/cognitiveservices/v1`,
    {
      method: "POST",
      headers: {
        "Ocp-Apim-Subscription-Key": subscriptionKey,
        "Content-Type": "application/ssml+xml",
        "X-Microsoft-OutputFormat": "audio-24khz-48kbitrate-mono-mp3",
        "User-Agent": "hdzap-premium",
      },
      body: ssml,
    },
  );

  if (!resp.ok) {
    const errBody = await resp.text();
    return new Response(
      JSON.stringify({ error: "upstream-azure", status: resp.status, body: errBody.slice(0, 500) }),
      { status: resp.status, headers: { "Content-Type": "application/json" } },
    );
  }

  return new Response(resp.body, {
    status: 200,
    headers: {
      "Content-Type": "audio/mpeg",
      "X-HDZap-Provider": "azure",
      "X-HDZap-Format": "mp3",
      "Cache-Control": "no-store",
    },
  });
}

// MARK: - util

/** SSML requires `&`, `<`, `>`, `"` to be entity-encoded. HDZap text is operator-controlled
 *  numbers + katakana so this is mostly defensive. */
function escapeSsml(s: string): string {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}

export default app;
