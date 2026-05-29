#!/usr/bin/env python3
"""Measure Cartesia /tts/sse Time-To-First-Audio (TTFA) for HDZap phrases.

Supports two modes:
  --mode direct  → call Cartesia /tts/sse directly (baseline)
  --mode proxy   → call HDZap Worker, which forwards to Cartesia (real production path)

For race-time TTS the metric that matters is how soon the user hears something after
LAP-tap, NOT how long the full audio takes to download. SSE streaming lets playback start
as soon as the first PCM chunk arrives; this script records the exact time to that chunk.

Metrics captured per phrase:
- t_connect:      HTTP request sent → first byte received (TCP+TLS+HTTP overhead)
- t_first_chunk:  request sent → first `type=chunk` SSE event (TTFA — the headline number)
- t_done:         request sent → `type=done` event (full generation complete)
- audio_seconds:  total PCM duration (sample_count / sample_rate)
- realtime_ratio: t_done / audio_seconds (<1 means faster than realtime, good for streaming)

Also writes one WAV per phrase to outputs/_streaming/<mode>/ so you can confirm chunks
decode correctly. Each WAV is the concatenated PCM, wrapped with a RIFF header.
"""
from __future__ import annotations

import argparse
import base64
import json
import os
import struct
import sys
import time
from pathlib import Path

import httpx
from dotenv import load_dotenv

ROOT = Path(__file__).parent.parent
sys.path.insert(0, str(ROOT))

VOICE_ID = "06950fa3-534d-46b3-93bb-f852770ea0b5"  # Takeshi (Hero)
SAMPLE_RATE = 24000  # SSE recommends 24kHz raw PCM
ENCODING = "pcm_s16le"

PROXY_URL = "https://hdzap-premium.saqoosha.workers.dev/tts"

PHRASES = [
    ("short_lap_ja",      "ja", "ラップ3、12.34、ベストラップ"),
    ("short_lap_en",      "en", "Lap 3, 12.34, best lap"),
    ("countdown_ja",      "ja", "10"),
    ("start_ja",          "ja", "スタート"),
    ("last_lap_ja",       "ja", "ファイナルラップです"),
    ("long_summary_ja",   "ja", "ラップ3、12.34秒、トータル8周、2分15.66秒、ベストラップは11.20秒でした"),
    ("long_summary_en",   "en", "Lap 3, 12.34 seconds. Total 8 laps in 2 minutes 15.66 seconds. Best lap was 11.20 seconds."),
]


def pcm_to_wav(pcm: bytes, sample_rate: int = SAMPLE_RATE) -> bytes:
    """RIFF/WAVE wrapper around concatenated PCM chunks (mono s16le)."""
    data_size = len(pcm)
    return (
        b"RIFF" + struct.pack("<I", 36 + data_size) + b"WAVE"
        + b"fmt " + struct.pack("<I", 16) + struct.pack("<H", 1) + struct.pack("<H", 1)
        + struct.pack("<I", sample_rate) + struct.pack("<I", sample_rate * 2)
        + struct.pack("<H", 2) + struct.pack("<H", 16)
        + b"data" + struct.pack("<I", data_size) + pcm
    )


def measure_one(text: str, lang: str, mode: str) -> dict:
    """Hit /tts/sse once (direct or proxy), return latency metrics + concatenated PCM."""
    if mode == "direct":
        url = "https://api.cartesia.ai/tts/sse"
        headers = {
            "X-API-Key": os.environ["CARTESIA_API_KEY"],
            "Cartesia-Version": "2024-11-13",
            "Content-Type": "application/json",
        }
        payload = {
            "model_id": "sonic-3.5",
            "transcript": text,
            "voice": {"mode": "id", "id": VOICE_ID},
            "output_format": {
                "container": "raw",
                "encoding": ENCODING,
                "sample_rate": SAMPLE_RATE,
            },
            "language": lang,
        }
    elif mode == "proxy":
        url = PROXY_URL
        headers = {
            "Authorization": f"Bearer {os.environ['HDZAP_WORKER_BEARER']}",
            "Content-Type": "application/json",
        }
        # Worker takes a simplified body shape (text/voice/lang/model only)
        payload = {
            "text": text,
            "voice": VOICE_ID,
            "lang": lang,
            "model": "sonic-3.5",
        }
    else:
        raise ValueError(f"unknown mode: {mode}")

    t_start = time.perf_counter()
    t_first_byte: float | None = None
    t_first_chunk: float | None = None
    t_done: float | None = None
    pcm_chunks: list[bytes] = []
    chunk_timestamps: list[float] = []  # ms-since-start per audio chunk — reveals if chunks
                                        # actually stream over time or arrive bundled.

    with httpx.Client(timeout=60.0, http2=False) as client:
        with client.stream("POST", url, json=payload, headers=headers) as r:
            r.raise_for_status()
            buf = ""
            for raw_chunk in r.iter_bytes(chunk_size=1):  # smallest unit so we record true arrival time
                if t_first_byte is None:
                    t_first_byte = time.perf_counter() - t_start
                buf += raw_chunk.decode("utf-8", errors="replace")
                # SSE events are separated by blank lines
                while "\n\n" in buf:
                    event, buf = buf.split("\n\n", 1)
                    # An event may have multiple "data: " lines; concatenate them per SSE spec
                    data_lines = [line[6:] for line in event.split("\n") if line.startswith("data: ")]
                    if not data_lines:
                        continue
                    payload_json = "".join(data_lines)
                    try:
                        ev = json.loads(payload_json)
                    except json.JSONDecodeError:
                        continue
                    etype = ev.get("type")
                    now_ms = (time.perf_counter() - t_start) * 1000
                    if etype == "chunk" and ev.get("data"):
                        if t_first_chunk is None:
                            t_first_chunk = time.perf_counter() - t_start
                        pcm_chunks.append(base64.b64decode(ev["data"]))
                        chunk_timestamps.append(now_ms)
                    elif etype == "done" or ev.get("done"):
                        t_done = time.perf_counter() - t_start
                    elif etype == "error":
                        raise RuntimeError(f"SSE error: {ev.get('error')}")
            # Fallback: if the server closes the connection without emitting a "done" event
            # in time for our parser, treat the stream end as completion.
            if t_done is None:
                t_done = time.perf_counter() - t_start

    pcm = b"".join(pcm_chunks)
    audio_seconds = (len(pcm) / 2) / SAMPLE_RATE  # 2 bytes per sample
    # Inter-chunk gaps reveal whether the server truly streams or just sends a bundled response.
    # A real stream shows gaps growing with audio duration; a bundled response shows ~0ms gaps.
    gaps = [round(chunk_timestamps[i+1] - chunk_timestamps[i], 1) for i in range(len(chunk_timestamps) - 1)]
    return {
        "t_connect_ms":     round((t_first_byte or 0) * 1000, 1),
        "t_first_chunk_ms": round((t_first_chunk or 0) * 1000, 1),
        "t_done_ms":        round((t_done or 0) * 1000, 1),
        "chunks":           len(pcm_chunks),
        "pcm_bytes":        len(pcm),
        "audio_seconds":    round(audio_seconds, 3),
        "realtime_ratio":   round((t_done or 0) / audio_seconds, 2) if audio_seconds else None,
        "chunk_arrival_ms": [round(t, 1) for t in chunk_timestamps],
        "inter_chunk_gaps": gaps,
        "pcm":              pcm,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", choices=["direct", "proxy"], default="direct",
                        help="direct = call Cartesia; proxy = call HDZap Worker which forwards")
    parser.add_argument("--samples", type=int, default=3,
                        help="Samples per phrase; median is reported (default 3)")
    args = parser.parse_args()

    load_dotenv(ROOT / ".env", override=True)
    if args.mode == "direct" and not os.environ.get("CARTESIA_API_KEY"):
        print("CARTESIA_API_KEY missing for direct mode. Run via `op run --env-file=.env.op -- ...`", file=sys.stderr)
        return 1
    if args.mode == "proxy" and not os.environ.get("HDZAP_WORKER_BEARER"):
        print("HDZAP_WORKER_BEARER missing for proxy mode. Run via `op run --env-file=.env.op -- ...`", file=sys.stderr)
        return 1

    out_dir = ROOT / "outputs" / "_streaming" / args.mode
    out_dir.mkdir(parents=True, exist_ok=True)

    print(f"=== mode: {args.mode} ===")
    print(f"{'phrase':<20} {'lang':<5} {'connect':>9} {'TTFA':>8} {'done':>8} {'audio':>9} {'rt':>5}  chunks")
    print("-" * 90)
    results = []
    for slug, lang, text in PHRASES:
        try:
            # Warm and measured. Take N samples and report the median TTFA to suppress
            # cold-connection noise (TLS handshake on first call is ~150ms slower).
            samples = []
            for _ in range(args.samples):
                samples.append(measure_one(text, lang, args.mode))
                time.sleep(0.6)  # avoid 429
            samples.sort(key=lambda s: s["t_first_chunk_ms"])
            median = samples[len(samples) // 2]
        except Exception as e:
            print(f"{slug:<20} {lang:<5} ✗ {type(e).__name__}: {e}")
            continue

        wav_path = out_dir / f"{slug}.wav"
        wav_path.write_bytes(pcm_to_wav(median["pcm"]))

        gaps = median["inter_chunk_gaps"]
        gap_min = min(gaps) if gaps else 0
        gap_max = max(gaps) if gaps else 0
        gap_med = sorted(gaps)[len(gaps)//2] if gaps else 0
        print(
            f"{slug:<20} {lang:<5} "
            f"{median['t_connect_ms']:>7.0f}ms "
            f"{median['t_first_chunk_ms']:>6.0f}ms "
            f"{median['t_done_ms']:>6.0f}ms "
            f"{median['audio_seconds']:>7.2f}s "
            f"{median['realtime_ratio']:>4.2f}x  "
            f"{median['chunks']:>3}  "
            f"gaps min/med/max: {gap_min:>5.1f}/{gap_med:>5.1f}/{gap_max:>5.1f}ms"
        )
        # Don't keep PCM in JSON output
        median_no_pcm = {k: v for k, v in median.items() if k != "pcm"}
        results.append({"slug": slug, "lang": lang, "text": text, **median_no_pcm, "wav": str(wav_path.relative_to(ROOT))})

    summary_path = ROOT / f"streaming_latency_{args.mode}.json"
    summary_path.write_text(json.dumps(
        {"mode": args.mode, "voice_id": VOICE_ID, "sample_rate": SAMPLE_RATE, "results": results},
        ensure_ascii=False, indent=2,
    ))
    print(f"\n✓ Wrote {summary_path.name} ({len(results)} phrases)")
    print(f"✓ WAVs in {out_dir}/")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
