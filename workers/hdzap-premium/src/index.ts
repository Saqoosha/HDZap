import { Hono } from "hono";
import { AwsClient } from "aws4fetch";

type Env = {
  CARTESIA_API_KEY: string;
  AZURE_SPEECH_KEY: string;
  // Stub auth: a single shared bearer until StoreKit JWS verification lands.
  // Set via `wrangler secret put DEV_BEARER` for now.
  DEV_BEARER: string;
};

const app = new Hono<{ Bindings: Env }>();

const ALLOWED_PROVIDERS = new Set(["cartesia", "polly", "azure"]);
const ALLOWED_CARTESIA_MODELS = new Set(["sonic-3.5", "sonic-3", "sonic-2", "sonic"]);
const ALLOWED_LANGS = new Set(["ja", "en"]);

// Trust-but-verify: a fixed maximum so a misbehaving client (or someone who exfiltrates the dev
// bearer) can't bill us for kilobyte-long transcripts. Bumped if real lap summaries grow.
const MAX_TRANSCRIPT_CHARS = 300;

// AWS region + Cognito Identity Pool. The pool grants unauthenticated public access to Polly
// (same pool YourLaps uses), so we don't need IAM user keys baked into the Worker — Cognito
// hands out short-lived temp credentials per Worker instance.
const AWS_REGION = "ap-northeast-1";
const COGNITO_POOL_ID = "ap-northeast-1:5bdffc81-8338-478e-8800-946e78f74614";

app.get("/", (c) => c.text("hdzap-premium worker — POST /tts"));
app.get("/healthz", (c) => c.json({ ok: true, ts: Date.now() }));

app.post("/tts", async (c) => {
  // Stub auth — replaced by JWS verification later. Reject early when bearer is missing or wrong.
  const auth = c.req.header("Authorization") || "";
  const token = auth.replace(/^Bearer\s+/i, "");
  if (!c.env.DEV_BEARER || token !== c.env.DEV_BEARER) {
    return c.json({ error: "unauthorized" }, 401);
  }

  let body: {
    provider?: string;
    text?: string;
    voice?: string;
    lang?: string;
    model?: string;
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

  if (!ALLOWED_PROVIDERS.has(provider)) return c.json({ error: "bad-provider" }, 400);
  if (!text) return c.json({ error: "missing-text" }, 400);
  if (text.length > MAX_TRANSCRIPT_CHARS)
    return c.json({ error: "text-too-long", limit: MAX_TRANSCRIPT_CHARS }, 400);
  if (!voice) return c.json({ error: "missing-voice" }, 400);
  if (!ALLOWED_LANGS.has(lang)) return c.json({ error: "bad-lang" }, 400);

  try {
    if (provider === "cartesia") {
      const model = (body.model || "sonic-3.5").trim();
      if (!ALLOWED_CARTESIA_MODELS.has(model)) return c.json({ error: "bad-model" }, 400);
      return await proxyCartesia(c.env.CARTESIA_API_KEY, model, voice, lang, text);
    }
    if (provider === "polly") {
      return await proxyPolly(voice, lang, text);
    }
    if (provider === "azure") {
      return await proxyAzure(c.env.AZURE_SPEECH_KEY, voice, lang, text);
    }
  } catch (e) {
    return c.json(
      { error: "internal", message: e instanceof Error ? e.message : String(e) },
      502
    );
  }
  return c.json({ error: "unreachable" }, 500);
});

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

/**
 * Module-level Cognito creds cache. A Worker isolate can serve many requests; reusing the
 * temp creds across the isolate's lifetime cuts the 2-RTT Cognito handshake out of the hot
 * path. We refresh ~60s before expiry to stay safely inside the validity window.
 */
let cachedCognitoCreds:
  | { accessKeyId: string; secretAccessKey: string; sessionToken: string; expiresAt: number }
  | null = null;

async function getCognitoCreds() {
  if (cachedCognitoCreds && Date.now() < cachedCognitoCreds.expiresAt - 60_000) {
    return cachedCognitoCreds;
  }

  // Step 1: GetId — pool-level call that returns an opaque identity handle.
  const getIdResp = await fetch(`https://cognito-identity.${AWS_REGION}.amazonaws.com/`, {
    method: "POST",
    headers: {
      "Content-Type": "application/x-amz-json-1.1",
      "X-Amz-Target": "AWSCognitoIdentityService.GetId",
    },
    body: JSON.stringify({ IdentityPoolId: COGNITO_POOL_ID }),
  });
  if (!getIdResp.ok) {
    throw new Error(`Cognito GetId failed: ${getIdResp.status} ${await getIdResp.text()}`);
  }
  const { IdentityId } = (await getIdResp.json()) as { IdentityId: string };

  // Step 2: GetCredentialsForIdentity — swap the identity handle for STS-style temp creds.
  const credResp = await fetch(`https://cognito-identity.${AWS_REGION}.amazonaws.com/`, {
    method: "POST",
    headers: {
      "Content-Type": "application/x-amz-json-1.1",
      "X-Amz-Target": "AWSCognitoIdentityService.GetCredentialsForIdentity",
    },
    body: JSON.stringify({ IdentityId }),
  });
  if (!credResp.ok) {
    throw new Error(`Cognito GetCredentialsForIdentity failed: ${credResp.status}`);
  }
  const credBody = (await credResp.json()) as {
    Credentials: { AccessKeyId: string; SecretKey: string; SessionToken: string; Expiration: number };
  };
  const creds = {
    accessKeyId: credBody.Credentials.AccessKeyId,
    secretAccessKey: credBody.Credentials.SecretKey,
    sessionToken: credBody.Credentials.SessionToken,
    // Cognito returns Expiration as a Unix timestamp (seconds), not ms.
    expiresAt: credBody.Credentials.Expiration * 1000,
  };
  cachedCognitoCreds = creds;
  return creds;
}

async function proxyPolly(voiceId: string, lang: string, text: string): Promise<Response> {
  const creds = await getCognitoCreds();
  const aws = new AwsClient({
    accessKeyId: creds.accessKeyId,
    secretAccessKey: creds.secretAccessKey,
    sessionToken: creds.sessionToken,
    region: AWS_REGION,
    service: "polly",
  });

  // Wrap the text in YourLaps' `<prosody rate="x-fast">` style — keeps the iOS app from having
  // to know about SSML and matches the production race-call cadence already proven on YourLaps.
  const ssml = `<speak><prosody rate="x-fast">${escapeSsml(text)}</prosody></speak>`;

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
): Promise<Response> {
  const region = "japaneast";
  const xmlLang = lang === "ja" ? "ja-JP" : "en-US";
  const gender = azureGenderFor(voiceId);
  const ssml =
    `<speak version='1.0' xml:lang='${xmlLang}'>` +
    `<voice xml:lang='${xmlLang}' xml:gender='${gender}' name='${voiceId}'>` +
    `${escapeSsml(text)}</voice></speak>`;

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
