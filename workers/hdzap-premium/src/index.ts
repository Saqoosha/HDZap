import { Hono } from "hono";
import { AwsClient } from "aws4fetch";
import { AppleJwsError, verifyAppleJws } from "./appleJws";

type Env = {
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
  /** Per-IP daily request counter. Keys: `rl:<ip>:<YYYY-MM-DD>`, TTL 48h. */
  RATELIMIT: KVNamespace;
  /**
   * Cross-user shared TTS audio cache. Keys are hex SHA-256 of the canonical request
   * (`v3|provider|voice|lang|rate|pitch|text` — see `buildCacheKey()`). First caller
   * pays the provider; everyone afterwards streams from R2 with the same content.
   */
  TTS_CACHE: R2Bucket;
};

/**
 * Daily per-IP request caps. Bearer and JWS get the same generous cap because IP-level
 * rate limiting is fundamentally a coarse guardrail given residential NAT (carriers,
 * Apple Private Relay, home WiFi all share an IP across many users) — a tighter cap
 * would break the legit first-time-audition session (~100-150 previews across 55 voices)
 * for any user behind a shared IP. The real ceilings on abuse are the TTS provider
 * spending caps (AWS Polly $50/mo budget, Azure fixed-tier model) and the
 * Apple-signed JWS gate; this cap exists to stop a single host running a curl loop, not
 * a determined attacker rotating residential proxies.
 */
const DAILY_CAP_BEARER = 1000;
const DAILY_CAP_JWS = 1000;

const app = new Hono<{ Bindings: Env }>();

const ALLOWED_PROVIDERS = new Set(["polly", "azure"]);
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
  // PERF DIAGNOSTIC: phase timing. `?nocache=1` query param skips R2 entirely so we can
  // measure the true cold path (auth + provider call). Each `mark()` logs a delta from the
  // request start, so observability shows where the time goes per request.
  const tStart = Date.now();
  const phaseTimings: Record<string, number> = {};
  const mark = (phase: string) => {
    phaseTimings[phase] = Date.now() - tStart;
  };
  const skipCache = new URL(c.req.url).searchParams.get("nocache") === "1";

  // Two-tier auth: real subscribers ship Apple-signed JWS; non-subscribers use the shared
  // dev bearer for in-app voice previews. The JWS path is Apple-cryptographic-proof, the
  // bearer path is rate-limited by text length so a leaked bearer can't bill us into the
  // ground (60 chars max + Polly/Azure caps).
  const auth = c.req.header("Authorization") || "";
  const token = auth.replace(/^Bearer\s+/i, "").trim();
  if (!token) return c.json({ error: "unauthorized", reason: "missing-token" }, 401);
  mark("auth-header");

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
      mark("jws-verified");
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

  // Per-IP daily rate limit — moved entirely to the background so it doesn't sit on the
  // request's critical path. KV.get + KV.put together routinely take 600-800 ms (KV is
  // eventually-consistent and not co-located with the Worker isolate); blocking the
  // response on that turned TTFA from ~200 ms into ~1 s. The trade-off is that we no
  // longer hard-reject the FIRST few over-cap requests — by the time the counter
  // updates, a determined attacker could squeeze a handful past the cap. Acceptable
  // because the actual ceiling on abuse is the per-provider monthly budget; the rate
  // limit is just a guardrail against a single host running a curl loop, and a few
  // bonus requests don't materially change the bill.
  const ip = c.req.header("CF-Connecting-IP") || c.req.header("X-Real-IP") || "unknown";
  const cap = authMode === "jws" ? DAILY_CAP_JWS : DAILY_CAP_BEARER;
  c.executionCtx.waitUntil((async () => {
    const result = await consumeRateLimitToken(c.env.RATELIMIT, ip, cap);
    if (!result.ok) {
      console.warn("rate-limit-exceeded (background, not enforced this request)", {
        ip, authMode, count: result.count, cap,
      });
    }
  })());
  mark("rate-limit-bg");

  let body: {
    provider?: string;
    text?: string;
    voice?: string;
    lang?: string;
    rate?: number;
    pitch?: number;
  };
  try {
    body = await c.req.json();
  } catch {
    return c.json({ error: "invalid-json" }, 400);
  }

  // `provider` is required — defaulting to anything would silently route an ill-formed
  // request to a real (billable) upstream call. Reject with a specific 400 instead.
  if (typeof body.provider !== "string" || body.provider.trim() === "") {
    return c.json({ error: "missing-provider" }, 400);
  }
  const provider = body.provider.trim().toLowerCase();
  const text = (body.text || "").trim();
  const voice = (body.voice || "").trim();
  const lang = (body.lang || "").trim();
  // Rate (speech tempo) and pitch (semitone offset) are accepted as raw numbers from the
  // client and clamped here — out-of-range values would otherwise produce monster/chipmunk
  // audio that's not useful for racing. Polly + Azure both honour rate; only Azure honours
  // pitch (Polly Neural rejects pitch outright, so the client side omits it).
  const rate = clamp(body.rate ?? 1.0, 0.5, 2.5);
  const pitch = clamp(body.pitch ?? 0.0, -10.0, 10.0);

  if (!ALLOWED_PROVIDERS.has(provider)) return c.json({ error: "bad-provider" }, 400);
  if (!text) return c.json({ error: "missing-text" }, 400);
  if (text.length > maxChars)
    return c.json({ error: "text-too-long", limit: maxChars, authMode }, 400);
  if (!voice) return c.json({ error: "missing-voice" }, 400);
  if (!ALLOWED_LANGS.has(lang)) return c.json({ error: "bad-lang" }, 400);

  // Build the cache key from every parameter that changes the audio. Two callers with
  // identical params share one cache entry regardless of who they are — that's the whole
  // point of R2 caching here vs. per-user storage.
  const cacheKey = await buildCacheKey({
    provider,
    voice,
    lang,
    rate,
    pitch,
    text,
  });

  // Cache hit → stream straight from R2. The provider-specific Content-Type lives in
  // the object's httpMetadata so we don't have to re-derive it from `provider` here.
  if (!skipCache) {
    const hit = await c.env.TTS_CACHE.get(cacheKey);
    mark("r2-lookup");
    if (hit) {
      console.log("r2-cache=hit", { key: cacheKey, provider, size: hit.size, ...phaseTimings });
      return new Response(hit.body, {
        status: 200,
        headers: {
          ...responseHeadersFor(provider, "hit"),
          "X-HDZap-Timings": JSON.stringify(phaseTimings),
        },
      });
    }
  } else {
    mark("r2-skipped");
  }

  // Cache miss — call the provider, then tee the body so the client gets streaming
  // playback while R2 gets a written copy for every subsequent caller.
  mark("upstream-start");
  let upstream: Response;
  try {
    if (provider === "polly") {
      upstream = await proxyPolly(
        c.env.POLLY_ACCESS_KEY_ID,
        c.env.POLLY_SECRET_ACCESS_KEY,
        voice,
        lang,
        text,
        rate,
        pitch,
      );
    } else if (provider === "azure") {
      upstream = await proxyAzure(c.env.AZURE_SPEECH_KEY, voice, lang, text, rate, pitch);
    } else {
      return c.json({ error: "unreachable" }, 500);
    }
    mark("upstream-headers");
  } catch (e) {
    return c.json(
      { error: "internal", message: e instanceof Error ? e.message : String(e) },
      502
    );
  }

  // Don't cache provider errors — they'd poison the entry and serve a 4xx forever. Each
  // proxy function also content-type-validates the upstream response (a provider returning
  // HTTP 200 with an HTML maintenance page or plaintext quota notice gets downgraded to
  // 502 there) so a wrong body never reaches iOS as "audio/* PCM" to be played as static.
  if (!upstream.ok || !upstream.body) {
    return upstream;
  }

  console.log("r2-cache=miss", { key: cacheKey, provider, ...phaseTimings });

  // When `?nocache=1` is set, skip the tee + R2 write entirely so we measure the true
  // upstream-only path with no extra Worker work.
  if (skipCache) {
    return new Response(upstream.body, {
      status: 200,
      headers: {
        ...responseHeadersFor(provider, "miss"),
        "X-HDZap-Timings": JSON.stringify(phaseTimings),
      },
    });
  }

  // tee the body so the client keeps streaming on its branch; the cache-write branch we
  // drain into an ArrayBuffer first because R2 rejects unknown-length ReadableStreams
  // ("Provided readable stream must have a known length"). Polly/Azure PCM for a single
  // utterance is small (<100 KB), so buffering one isn't a memory concern.
  const [toClient, toR2] = upstream.body.tee();
  c.executionCtx.waitUntil((async () => {
    try {
      const buf = await new Response(toR2).arrayBuffer();
      await c.env.TTS_CACHE.put(cacheKey, buf, {
        httpMetadata: { contentType: contentTypeFor(provider) },
        customMetadata: {
          provider,
          voice,
          lang,
          chars: String(text.length),
        },
      });
      console.log("r2-cache=written", { key: cacheKey, size: buf.byteLength });
    } catch (e) {
      // R2 write failures shouldn't break the client response — the next caller just
      // pays the provider again. Surface in logs so we notice systemic outages.
      console.error("r2-cache=write-failed", { key: cacheKey, message: (e as Error).message });
    }
  })());

  return new Response(toClient, {
    status: 200,
    headers: {
      ...responseHeadersFor(provider, "miss"),
      "X-HDZap-Timings": JSON.stringify(phaseTimings),
    },
  });
});

function clamp(n: number, lo: number, hi: number): number {
  return Math.min(hi, Math.max(lo, n));
}

/**
 * Canonical hex SHA-256 of every parameter that affects the generated audio. Stable across
 * callers — same params = same key = one shared R2 entry. The `|` separator is fine
 * because none of the field values (provider/voice/lang are enum-like, numbers are floats,
 * text is user input but `|` is rare in race phrases) can collide ambiguously at this
 * granularity.
 */
async function buildCacheKey(req: {
  provider: string;
  voice: string;
  lang: string;
  rate: number;
  pitch: number;
  text: string;
}): Promise<string> {
  // "v3" prefix invalidates the previous canonical-key shape, which carried a trailing
  // `model` segment (only ever non-empty for the now-removed Cartesia provider). Same v3
  // prefix is mirrored by the iOS client's `TTSCache.key()` once that side bumps too.
  // Bump again the next time the wire format changes incompatibly. Stale v1/v2 entries
  // stay orphaned in R2 — Cloudflare doesn't charge enough on a few KB of stragglers to
  // bother with a cleanup script.
  const canonical = [
    "v3",
    req.provider,
    req.voice,
    req.lang,
    req.rate.toFixed(3),
    req.pitch.toFixed(3),
    req.text,
  ].join("|");
  const buf = new TextEncoder().encode(canonical);
  const hash = await crypto.subtle.digest("SHA-256", buf);
  return Array.from(new Uint8Array(hash))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

/**
 * What `Content-Type` we serve for each provider. Polly and Azure both ship raw s16le PCM
 * bytes streaming-style so iOS schedules each chunk on AVAudioPlayerNode as soon as it
 * lands. The cache-miss path also stuffs this into the R2 object's
 * `httpMetadata.contentType` so cache hits don't need a parallel lookup table.
 */
function contentTypeFor(_provider: string): string {
  return "audio/pcm";
}

/**
 * Sample rate of the raw PCM stream each provider emits. Azure streams at the engine's
 * native 24 kHz so iOS schedules buffers without resampling. Polly Neural's PCM mode only
 * supports 8 kHz or 16 kHz (22 / 24 kHz are mp3-only) — we use 16 kHz and let iOS
 * upsample to 24 kHz via AVAudioConverter.
 */
function sampleRateFor(provider: string): number {
  return provider === "polly" ? 16000 : 24000;
}

/**
 * Full response header set we send to the iOS client. Both Polly and Azure stream raw
 * chunked PCM, so the header set is uniform — `X-HDZap-SampleRate` tells iOS which
 * AVAudioFormat to allocate up front. `X-HDZap-Cache` tags hit/miss so the client can log
 * it without parsing the body.
 */
function responseHeadersFor(provider: string, cacheStatus: "hit" | "miss"): Record<string, string> {
  return {
    "Content-Type": contentTypeFor(provider),
    "Cache-Control": "no-store",
    "X-HDZap-Provider": provider,
    "X-HDZap-Cache": cacheStatus,
    "X-HDZap-Format": "pcm-raw",
    "X-HDZap-SampleRate": String(sampleRateFor(provider)),
  };
}

/**
 * Read → check-against-cap → increment KV counter for the IP's daily quota. We bake the
 * UTC date into the key so the counter rolls over at 00:00 UTC, and TTL each entry at 48h
 * so yesterday's keys clean themselves up. KV's eventual consistency (~60 s) means a
 * determined attacker hitting multiple PoPs could squeeze a few extra requests past the
 * cap, but for a "stop bearer abuse" guardrail that's acceptable — Durable Objects would
 * give strict consistency at the cost of meaningfully more complexity + paid-plan ties.
 */
async function consumeRateLimitToken(
  kv: KVNamespace,
  ip: string,
  cap: number,
): Promise<{ ok: boolean; count: number; retryAfterSeconds: number }> {
  const today = new Date().toISOString().slice(0, 10);
  const key = `rl:${ip}:${today}`;
  const current = Number((await kv.get(key)) ?? "0");
  const next = current + 1;
  if (next > cap) {
    // Seconds until 00:00 UTC tomorrow — when the bucket rolls over.
    const now = new Date();
    const tomorrow = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate() + 1));
    const retryAfterSeconds = Math.ceil((tomorrow.getTime() - now.getTime()) / 1000);
    return { ok: false, count: current, retryAfterSeconds };
  }
  // 48h TTL — gives a comfortable margin past the 24h bucket so the read sees the
  // counter, and self-evicts so the namespace doesn't grow unbounded.
  await kv.put(key, String(next), { expirationTtl: 60 * 60 * 48 });
  return { ok: true, count: next, retryAfterSeconds: 0 };
}

// MARK: - AWS Polly (raw PCM streaming)

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
  // only feature ("Unsupported Neural feature" 400). `rate` arrives as a multiplier (1.0
  // = baseline); we round to the closest percentage Polly understands (50%-200%).
  void pitch; // intentionally ignored on Polly Neural
  const ratePct = `${Math.round(rate * 100)}%`;
  const ssml =
    `<speak><prosody rate="${ratePct}">${escapeSsml(text)}</prosody></speak>`;

  // OutputFormat=pcm gives raw s16le bytes that iOS can play streaming-style: schedule
  // each chunk on AVAudioPlayerNode as it arrives instead of waiting for the full mp3.
  // Polly Neural with pcm only accepts SampleRate 8000 or 16000 (22050 / 24000 are mp3-
  // only). iOS upsamples 16 kHz → 24 kHz via AVAudioConverter — quality loss is minor
  // for race-call speech where prosody dominates and a couple of kHz of headroom is
  // imperceptible.
  const url = `https://polly.${AWS_REGION}.amazonaws.com/v1/speech`;
  const resp = await aws.fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      Text: ssml,
      TextType: "ssml",
      VoiceId: voiceId,
      OutputFormat: "pcm",
      SampleRate: "16000",
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

  // Polly returns `application/x-amzn-pcm` for OutputFormat=pcm — accept anything starting
  // with `audio/` or `application/` containing `pcm`, since AWS has tweaked this string
  // in the past. A maintenance HTML page would not match.
  const upstreamType = (resp.headers.get("Content-Type") || "").toLowerCase();
  if (!(upstreamType.startsWith("audio/") || upstreamType.includes("pcm"))) {
    return new Response(
      JSON.stringify({ error: "upstream-bad-content-type", provider: "polly", contentType: upstreamType }),
      { status: 502, headers: { "Content-Type": "application/json" } },
    );
  }

  return new Response(resp.body, {
    status: 200,
    headers: {
      "Content-Type": "audio/pcm",
      "X-HDZap-Provider": "polly",
      "X-HDZap-Format": "pcm-raw",
      "X-HDZap-SampleRate": "16000",
      "Cache-Control": "no-store",
    },
  });
}

// MARK: - Azure Speech (raw PCM streaming)

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
  // faster); pitch as signed percentage like "+10%". Semitones → percent via the familiar
  // 100 cents = 1 semitone interval, ~6% per semitone on Azure's perceptual scale.
  const rateStr = rate.toFixed(2);
  const pitchPct = `${pitch >= 0 ? "+" : ""}${Math.round(pitch * 6)}%`;
  const ssml =
    `<speak version='1.0' xml:lang='${xmlLang}'>` +
    `<voice xml:lang='${xmlLang}' xml:gender='${gender}' name='${voiceId}'>` +
    `<prosody rate='${rateStr}' pitch='${pitchPct}'>${escapeSsml(text)}</prosody>` +
    `</voice></speak>`;

  // raw-24khz-16bit-mono-pcm matches the engine's source format on iOS, so `schedulePCM`
  // takes the no-conversion fast path (engine source is 24 kHz mono Float32). True
  // streaming: first chunk plays as soon as it lands.
  const resp = await fetch(
    `https://${region}.tts.speech.microsoft.com/cognitiveservices/v1`,
    {
      method: "POST",
      headers: {
        "Ocp-Apim-Subscription-Key": subscriptionKey,
        "Content-Type": "application/ssml+xml",
        "X-Microsoft-OutputFormat": "raw-24khz-16bit-mono-pcm",
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

  // Azure returns `audio/basic` or `audio/x-wav` etc. depending on the OutputFormat we
  // asked for (`raw-24khz-16bit-mono-pcm` typically yields `audio/x-wav` or similar). A
  // maintenance HTML page would not start with `audio/`.
  const upstreamType = (resp.headers.get("Content-Type") || "").toLowerCase();
  if (!upstreamType.startsWith("audio/")) {
    return new Response(
      JSON.stringify({ error: "upstream-bad-content-type", provider: "azure", contentType: upstreamType }),
      { status: 502, headers: { "Content-Type": "application/json" } },
    );
  }

  return new Response(resp.body, {
    status: 200,
    headers: {
      "Content-Type": "audio/pcm",
      "X-HDZap-Provider": "azure",
      "X-HDZap-Format": "pcm-raw",
      "X-HDZap-SampleRate": "24000",
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
