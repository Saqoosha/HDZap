#!/usr/bin/env bash
set -euo pipefail

# Release a new HDZap version to TestFlight.
#   ./scripts/release.sh 1.0.1
#
# Steps:
#   1. Bump MARKETING_VERSION to <version> and CURRENT_PROJECT_VERSION to (current+1)
#   2. Build & archive (scripts/build.sh)
#   3. Export .ipa & upload to TestFlight (scripts/upload-testflight.sh)
#   4. jj describe + jj new (commit the version bump)
#   5. jj bookmark set main + jj git push --bookmark main
#   6. git tag v<version> && git push origin v<version>
#
# The script fails fast on any error, so re-running after a failure is safe.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="${ROOT_DIR}/app"
PROJECT_YML="${APP_DIR}/project.yml"

usage() {
  echo "Usage: $0 <version>"
  echo "Example: $0 1.0.1"
  exit 1
}

[[ $# -lt 1 ]] && usage

VERSION="$1"
TAG="v${VERSION}"

if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
  echo "Error: Invalid version format. Use X.Y or X.Y.Z (e.g., 1.0.1)" >&2
  exit 1
fi

cd "$ROOT_DIR"

echo "=== Releasing HDZap ${VERSION} ==="

CURRENT_BUILD=$(grep 'CURRENT_PROJECT_VERSION:' "${PROJECT_YML}" | sed 's/.*: *"\([0-9]*\)".*/\1/')
NEW_BUILD=$((CURRENT_BUILD + 1))

echo "=== Bumping version to ${VERSION} (build ${NEW_BUILD}) ==="
sed -i '' "s/MARKETING_VERSION: \".*\"/MARKETING_VERSION: \"${VERSION}\"/" "${PROJECT_YML}"
sed -i '' "s/CURRENT_PROJECT_VERSION: \".*\"/CURRENT_PROJECT_VERSION: \"${NEW_BUILD}\"/" "${PROJECT_YML}"

echo "=== Build & archive ==="
"${ROOT_DIR}/scripts/build.sh"

echo "=== Export .ipa & upload to TestFlight ==="
"${ROOT_DIR}/scripts/upload-testflight.sh"

echo "=== Commit version bump (jj) ==="
jj describe -m "Release ${VERSION} (build ${NEW_BUILD})

- Bump MARKETING_VERSION to ${VERSION}
- Bump CURRENT_PROJECT_VERSION to ${NEW_BUILD}

Co-Authored-By: Claude ${MODEL_NAME:-Opus 4.7 (1M context)} <noreply@anthropic.com>"

jj bookmark set main -r @
jj new
jj git push --bookmark main

echo "=== Git tag ${TAG} ==="
if git rev-parse "$TAG" >/dev/null 2>&1; then
  echo "Tag $TAG already exists, updating to current commit"
  git tag -d "$TAG"
  git push origin ":refs/tags/$TAG" 2>/dev/null || true
fi
git tag "$TAG"
git push origin "$TAG"

echo ""
echo "=== Release ${VERSION} (build ${NEW_BUILD}) complete ==="
echo ""
echo "Next:"
echo "  - TestFlight processes the build (~5–30 min). Beta testers see it once VALID."
echo "  - Check status: ./scripts/testflight-status.sh   (if added later)"
echo "  - Or: open https://appstoreconnect.apple.com/apps"
