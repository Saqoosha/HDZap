import { Hono } from "hono";

type Env = {
  CARTESIA_API_KEY: string;
  // Stub auth: a single shared bearer until StoreKit JWS verification lands.
  // Set via `wrangler secret put DEV_BEARER` for now.
  DEV_BEARER: string;
};

const app = new Hono<{ Bindings: Env }>();

const ALLOWED_MODELS = new Set(["sonic-3.5", "sonic-3", "sonic-2", "sonic"]);
const ALLOWED_LANGS = new Set(["ja", "en"]);

// Trust-but-verify: a fixed maximum so a misbehaving client (or someone who exfiltrates the dev
// bearer) can't bill us for kilobyte-long transcripts. Bumped if real lap summaries grow.
const MAX_TRANSCRIPT_CHARS = 300;

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

  const text = (body.text || "").trim();
  const voice = (body.voice || "").trim();
  const lang = (body.lang || "").trim();
  const model = (body.model || "sonic-3.5").trim();

  if (!text) return c.json({ error: "missing-text" }, 400);
  if (text.length > MAX_TRANSCRIPT_CHARS)
    return c.json({ error: "text-too-long", limit: MAX_TRANSCRIPT_CHARS }, 400);
  if (!voice) return c.json({ error: "missing-voice" }, 400);
  if (!ALLOWED_LANGS.has(lang)) return c.json({ error: "bad-lang" }, 400);
  if (!ALLOWED_MODELS.has(model)) return c.json({ error: "bad-model" }, 400);

  // Forward to Cartesia /tts/sse. We pass the response stream through untouched so SSE event
  // boundaries reach the client exactly as Cartesia emits them — no buffering, no rewrite.
  const cartesiaResp = await fetch("https://api.cartesia.ai/tts/sse", {
    method: "POST",
    headers: {
      "X-API-Key": c.env.CARTESIA_API_KEY,
      "Cartesia-Version": "2024-11-13",
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      model_id: model,
      transcript: text,
      voice: { mode: "id", id: voice },
      output_format: {
        container: "raw",
        encoding: "pcm_s16le",
        sample_rate: 24000,
      },
      language: lang,
    }),
  });

  if (!cartesiaResp.ok) {
    // Surface the upstream status so the client can distinguish e.g. rate-limit (429) from
    // a real outage (5xx). The body is short ("Invalid request: ..."), safe to echo back.
    const errBody = await cartesiaResp.text();
    return c.json(
      { error: "upstream-error", status: cartesiaResp.status, body: errBody.slice(0, 500) },
      (cartesiaResp.status >= 400 && cartesiaResp.status < 600
        ? (cartesiaResp.status as 400 | 401 | 403 | 404 | 429 | 500 | 502 | 503 | 504)
        : 502)
    );
  }

  return new Response(cartesiaResp.body, {
    status: 200,
    headers: {
      "Content-Type": "text/event-stream",
      "Cache-Control": "no-store",
      "X-Accel-Buffering": "no",
    },
  });
});

export default app;
