#!/usr/bin/env bash
# Mirror the published manual layout into a local _site/ dir and serve
# it on http://localhost:8000/. Mirrors what CI's `stage_pages` does
# (see .github/workflows/flasher.yml) so the local preview pixel-
# matches the eventual GitHub Pages render.
#
# Usage:
#   scripts/manual-dev-server.sh
#
# Press Ctrl+C to stop.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT=$(mktemp -d -t hdzap-manual-XXXX)
trap 'rm -rf "$OUT"' EXIT INT TERM

DOCS=docs/manual
mkdir -p "$OUT/images" "$OUT/ja/images"
cp "$DOCS/_pages/index.html"      "$OUT/index.html"
cp "$DOCS/_pages/ja/index.html"   "$OUT/ja/index.html"
cp "$DOCS/en.md"                  "$OUT/index.md"
cp "$DOCS/ja.md"                  "$OUT/ja/index.md"
cp -R "$DOCS/images/."            "$OUT/images/"
cp -R "$DOCS/images/."            "$OUT/ja/images/"

# Favicons (chrome refs them from the viewer HTML)
for f in favicon.ico favicon-16x16.png favicon-32x32.png apple-touch-icon.png; do
  [ -f "$DOCS/$f" ] && cp "$DOCS/$f" "$OUT/$f"
done

echo "📚 serving $OUT at http://localhost:8000/  (en)  and  http://localhost:8000/ja/  (ja)"
echo "   Ctrl+C to stop"
cd "$OUT" && python3 -m http.server 8000
