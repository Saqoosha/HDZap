#!/usr/bin/env python3
"""Run every available TTS provider against every phrase in phrases.json.

Outputs land in outputs/{provider}/{voice}/{phrase_id}.{mp3|wav} so the comparison HTML can
discover them with a directory listing. results.json captures latency + errors per cell.

Usage:
    cp .env.example .env  # fill in keys
    uv sync
    uv run python tts_test.py             # all providers, all phrases
    uv run python tts_test.py --provider gemini --provider polly
    uv run python tts_test.py --lang ja   # JA only
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

from dotenv import load_dotenv

from providers import ALL_PROVIDERS, Provider, Result, Voice


ROOT = Path(__file__).parent
OUTPUTS = ROOT / "outputs"
RESULTS = ROOT / "results.json"


def load_phrases() -> list[dict]:
    """Flatten phrases.json into a single list, preserving category for the report."""
    data = json.loads((ROOT / "phrases.json").read_text())
    flat = []
    for category, body in data["categories"].items():
        for p in body["phrases"]:
            flat.append({**p, "category": category, "category_desc": body["description"]})
    return flat


def matches_filter(name: str, allow: list[str]) -> bool:
    if not allow:
        return True
    return any(needle.lower() in name.lower() for needle in allow)


def synth_one(provider: Provider, voice: Voice, phrase: dict) -> dict:
    """One (provider, voice, phrase) cell — returns a result row dict."""
    out_dir = OUTPUTS / provider.name / voice.id.replace("/", "_")
    out_dir.mkdir(parents=True, exist_ok=True)
    out_file = out_dir / f"{phrase['id']}.tmp"

    print(f"  [{provider.name}/{voice.id}/{phrase['id']}] ...", flush=True)
    res: Result = provider.synthesize(phrase["text"], phrase["lang"], voice)

    row = {
        "provider": provider.name,
        "voice_id": voice.id,
        "voice_label": voice.label,
        "phrase_id": phrase["id"],
        "phrase_text": phrase["text"],
        "lang": phrase["lang"],
        "category": phrase["category"],
        "latency_ms": round(res.latency_ms, 1),
        "error": res.error,
        "audio_path": None,
    }

    if res.error:
        print(f"    ✗ {res.error}", flush=True)
        return row

    # Move tmp -> final with correct extension once we know the format
    final = out_dir / f"{phrase['id']}.{res.audio_format}"
    final.write_bytes(res.audio)
    if out_file.exists():
        out_file.unlink()
    row["audio_path"] = str(final.relative_to(ROOT))
    row["audio_bytes"] = len(res.audio)
    print(f"    ✓ {res.latency_ms:.0f}ms, {len(res.audio):,} bytes → {final.name}", flush=True)
    return row


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--provider", action="append", default=[],
        help="Substring filter on provider name; repeat to allow multiple. Default = all available."
    )
    parser.add_argument(
        "--lang", choices=["ja", "en"], default=None,
        help="Restrict to one language. Default = both."
    )
    parser.add_argument(
        "--category", action="append", default=[],
        help="Filter phrase categories (lap_short, lap_best, fixed_cues, final_summary)."
    )
    parser.add_argument(
        "--voice-limit", type=int, default=2,
        help="Max voices per provider/language to test (keeps the matrix manageable). Default 2."
    )
    parser.add_argument(
        "--workers", type=int, default=4,
        help="Parallel API calls. Default 4. Drop to 1 for rate-limited providers."
    )
    args = parser.parse_args()

    # `override=True`: a key set in `.env` overrides whatever the parent shell exports.
    # Without this, an OPENAI_API_KEY sitting in the user's shell rc would silently run real
    # synthesis calls even when the user hasn't filled in .env. Set the key to empty in .env
    # to explicitly disable a provider whose key happens to be in your shell.
    load_dotenv(ROOT / ".env", override=True)

    # Belt-and-braces: if .env exists but doesn't mention a given key, the shell-exported value
    # is still in os.environ. We want a clear opt-in story, so warn loudly when keys come from
    # the parent shell instead of .env.
    env_path = ROOT / ".env"
    env_keys_set: set[str] = set()
    if env_path.exists():
        for line in env_path.read_text().splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                env_keys_set.add(line.split("=", 1)[0].strip())

    phrases = load_phrases()
    if args.lang:
        phrases = [p for p in phrases if p["lang"] == args.lang]
    if args.category:
        phrases = [p for p in phrases if p["category"] in args.category]

    providers: list[Provider] = []
    for p in ALL_PROVIDERS:
        if not matches_filter(p.name, args.provider):
            continue
        if not p.is_available():
            missing = [k for k in p.env_keys if not os.environ.get(k)]
            print(f"⊘ {p.name}: missing env vars {missing} — skipping")
            continue
        # Warn when a key was inherited from parent shell instead of explicit .env entry.
        # Prevents the silent "I didn't write any keys but it still cost me money" surprise.
        inherited = [k for k in p.env_keys if k not in env_keys_set]
        if inherited:
            print(
                f"⚠ {p.name}: using shell-exported {inherited} (not in .env). "
                f"Set them to empty in .env to disable."
            )
        providers.append(p)

    if not providers:
        print("No providers available. Did you fill in .env?", file=sys.stderr)
        return 1

    print(f"\nProviders: {len(providers)} | Phrases: {len(phrases)}")
    print(f"Output: {OUTPUTS}\n")

    OUTPUTS.mkdir(exist_ok=True)
    jobs = []
    for prov in providers:
        for lang in (["ja", "en"] if not args.lang else [args.lang]):
            voices = prov.voices_for(lang)[: args.voice_limit]
            for voice in voices:
                for phrase in phrases:
                    if phrase["lang"] != lang:
                        continue
                    jobs.append((prov, voice, phrase))

    print(f"Jobs: {len(jobs)}\n")

    rows = []
    with ThreadPoolExecutor(max_workers=args.workers) as ex:
        futures = [ex.submit(synth_one, prov, voice, phrase) for prov, voice, phrase in jobs]
        for f in as_completed(futures):
            rows.append(f.result())

    rows.sort(key=lambda r: (r["lang"], r["category"], r["phrase_id"], r["provider"], r["voice_id"]))
    RESULTS.write_text(json.dumps({"rows": rows}, ensure_ascii=False, indent=2))
    print(f"\n✓ Wrote {len(rows)} rows to {RESULTS}")
    print("Open compare.html in a browser to listen.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
