#!/usr/bin/env python3
"""Compare how Cartesia reads Japanese numbers under different text formats.

The default reading "ラップ3、12.34" comes out as "らっぷさん、いちに、さんよん" — digit-by-digit.
We want "じゅうにてん さんよん" (cardinal). This script generates 4 candidate spellings of the
same lap-time phrase so we can pick the format that produces natural cardinal reading.
"""
from __future__ import annotations

import os
import sys
from pathlib import Path

import httpx
from dotenv import load_dotenv

ROOT = Path(__file__).parent.parent
sys.path.insert(0, str(ROOT))


# Same Cartesia voice across all variants so we isolate the text format effect.
VOICE_ID = "06950fa3-534d-46b3-93bb-f852770ea0b5"  # Takeshi - Hero
VOICE_NAME = "Takeshi"

VARIANTS = [
    # (slug, description, text)
    (
        "v1_digits",
        "Current: bare arabic digits (the broken baseline)",
        "ラップ3、12.34、ベストラップ",
    ),
    (
        "v2_kanji",
        "Kanji numerals",
        "ラップ三、十二点三四、ベストラップ",
    ),
    (
        "v3_kana_reading",
        "Full hiragana reading (cardinal)",
        "ラップさん、じゅうにてんさんよん、ベストラップ",
    ),
    (
        "v4_kana_compact",
        "Hiragana with no commas",
        "ラップさん じゅうにてん さんよん ベストラップ",
    ),
    (
        "v5_mixed_kanji",
        "Arabic lap + kanji time",
        "ラップ3、十二点三四、ベストラップ",
    ),
    (
        "v6_summary_digits",
        "Long summary — current digit form (baseline broken)",
        "ラップ3 12.34秒、トータル8周、2分15.66秒、ベストラップは11.20秒でした",
    ),
    (
        "v7_summary_kana",
        "Long summary — fully read out",
        "ラップさん じゅうにてんさんよんびょう、トータル はっしゅう、にふん じゅうごてんろくろくびょう、ベストラップは じゅういってんにじゅうびょう でした",
    ),
    (
        "v8_summary_kanji",
        "Long summary — kanji numerals",
        "ラップ三 十二点三四秒、トータル八周、二分十五点六六秒、ベストラップは十一点二〇秒でした",
    ),
    (
        "v9_summary_kuten",
        "Long summary — replace SPACE before number with 、 (test the user's hypothesis)",
        "ラップ3、12.34秒、トータル8周、2分15.66秒、ベストラップは11.20秒でした",
    ),
    (
        "v10_summary_kuten_plus_period",
        "Long summary — 、 + 。 sentence boundary before time",
        "ラップ3。12.34秒、トータル8周、2分15.66秒、ベストラップは11.20秒でした",
    ),
    (
        "v11_summary_no_total_space",
        "Long summary — sprinkle 、 throughout, no spaces",
        "ラップ3、12.34秒、トータル、8周、2分15.66秒、ベストラップは、11.20秒でした",
    ),
]


def synth(text: str) -> bytes:
    """Single Cartesia POST. Returns raw mp3 bytes or raises on non-200."""
    r = httpx.post(
        "https://api.cartesia.ai/tts/bytes",
        headers={
            "X-API-Key": os.environ["CARTESIA_API_KEY"],
            "Cartesia-Version": "2024-11-13",
            "Content-Type": "application/json",
        },
        json={
            "model_id": "sonic-3.5",
            "transcript": text,
            "voice": {"mode": "id", "id": VOICE_ID},
            "output_format": {
                "container": "mp3",
                "bit_rate": 128000,
                "sample_rate": 44100,
            },
            "language": "ja",
        },
        timeout=30.0,
    )
    r.raise_for_status()
    return r.content


def main() -> int:
    load_dotenv(ROOT / ".env", override=True)
    if not os.environ.get("CARTESIA_API_KEY"):
        # tolerate the shell-exported form too
        print("Set CARTESIA_API_KEY env or .env", file=sys.stderr)
        return 1

    out_dir = ROOT / "outputs" / "_number_format_test" / VOICE_NAME
    out_dir.mkdir(parents=True, exist_ok=True)

    rows = []
    for slug, desc, text in VARIANTS:
        print(f"  [{slug}] {text}")
        try:
            audio = synth(text)
        except httpx.HTTPStatusError as e:
            print(f"    ✗ {e.response.status_code} {e.response.text[:100]}")
            continue
        path = out_dir / f"{slug}.mp3"
        path.write_bytes(audio)
        rows.append({
            "slug": slug,
            "description": desc,
            "text": text,
            "audio_path": str(path.relative_to(ROOT)),
            "audio_bytes": len(audio),
        })
        print(f"    ✓ {len(audio):,} bytes")

    # Tiny HTML for side-by-side audition.
    html = ["<!doctype html><html><head><meta charset='utf-8'>",
            "<title>Number format comparison</title>",
            "<style>body{font-family:-apple-system,sans-serif;max-width:800px;margin:20px auto;padding:0 20px}",
            ".v{padding:12px;margin:8px 0;border:1px solid #ddd;border-radius:6px}",
            ".v h3{margin:0 0 4px;font-size:14px}",
            ".v .desc{color:#666;font-size:12px;margin-bottom:4px}",
            ".v .text{font-family:monospace;background:#f5f5f5;padding:6px;border-radius:3px;font-size:14px}",
            ".v audio{width:100%;margin-top:8px}</style></head><body>",
            f"<h1>Number format A/B — {VOICE_NAME}</h1>",
            "<p>Same phrase, 8 spellings. Listen for which one reads 12 as 'jūni' (cardinal) instead of 'ichi-ni' (digits).</p>"]
    for r in rows:
        html.append(f"<div class='v'><h3>{r['slug']}</h3>"
                    f"<div class='desc'>{r['description']}</div>"
                    f"<div class='text'>{r['text']}</div>"
                    f"<audio controls src='{r['audio_path']}'></audio></div>")
    html.append("</body></html>")
    (ROOT / "number_format_test.html").write_text("\n".join(html))
    print(f"\n✓ Wrote number_format_test.html ({len(rows)} variants)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
