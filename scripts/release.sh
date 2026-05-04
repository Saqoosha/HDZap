#!/usr/bin/env bash
set -euo pipefail

# Release a new HDZap version to TestFlight.
#   MODEL_NAME="Opus 4.7 (1M context)" ./scripts/release.sh 1.0.1
#
# Steps:
#   1. Bump MARKETING_VERSION to <version> and CURRENT_PROJECT_VERSION to (current+1)
#   2. Build & archive (scripts/build.sh)
#   3. Export .ipa & upload to TestFlight (scripts/upload-testflight.sh)
#   4. jj describe the change with a Co-Authored-By line that names the running model
#   5. jj bookmark set main -r @ + jj git push --bookmark main
#      (jj auto-creates a new empty change at @ after the push — do NOT run jj new)
#   6. git tag v<version> on the released commit + git push origin v<version>
#
# Recovery on failure: if any step fails after the project.yml bump, the script
# automatically restores project.yml from git. TestFlight uploads cannot be undone,
# but a partial release leaves the working tree clean.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="${ROOT_DIR}/app"
PROJECT_YML="${APP_DIR}/project.yml"

usage() {
  echo "Usage: MODEL_NAME=\"<model name>\" $0 <version>"
  echo "Example: MODEL_NAME=\"Opus 4.7 (1M context)\" $0 1.0.1"
  exit 1
}

[[ $# -lt 1 ]] && usage

: "${MODEL_NAME:?MODEL_NAME must be set so commit Co-Authored-By matches the running model}"

VERSION="$1"
TAG="v${VERSION}"

# Tighten to 3-component (Apple's CFBundleShortVersionString rules want X.Y.Z).
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Error: Invalid version format. Use X.Y.Z (e.g., 1.0.1)" >&2
  exit 1
fi

cd "$ROOT_DIR"

echo "=== Releasing HDZap ${VERSION} ==="

CURRENT_BUILD=$(grep 'CURRENT_PROJECT_VERSION:' "${PROJECT_YML}" | sed 's/.*: *"\([0-9]*\)".*/\1/')
if ! [[ "$CURRENT_BUILD" =~ ^[0-9]+$ ]]; then
  echo "Error: failed to parse CURRENT_PROJECT_VERSION from ${PROJECT_YML} (got: '${CURRENT_BUILD}')" >&2
  exit 1
fi
NEW_BUILD=$((CURRENT_BUILD + 1))

# If anything between the version bump and the successful release fails,
# restore project.yml so the working tree isn't left torn.
restore_project_yml() {
  local code=$?
  if [[ "${SKIP_RESTORE:-0}" == "1" ]]; then return $code; fi
  echo "Error during release — restoring ${PROJECT_YML} from git" >&2
  git checkout -- "${PROJECT_YML}" 2>/dev/null || true
  return $code
}
trap restore_project_yml ERR

echo "=== Bumping version to ${VERSION} (build ${NEW_BUILD}) ==="
sed -i '' "s/MARKETING_VERSION: \".*\"/MARKETING_VERSION: \"${VERSION}\"/" "${PROJECT_YML}"
sed -i '' "s/CURRENT_PROJECT_VERSION: \".*\"/CURRENT_PROJECT_VERSION: \"${NEW_BUILD}\"/" "${PROJECT_YML}"

# BSD sed exits 0 even on no-op — verify the substitution actually took.
if ! grep -q "MARKETING_VERSION: \"${VERSION}\"" "${PROJECT_YML}"; then
  echo "Error: MARKETING_VERSION substitution did not take effect in ${PROJECT_YML}" >&2
  exit 1
fi
if ! grep -q "CURRENT_PROJECT_VERSION: \"${NEW_BUILD}\"" "${PROJECT_YML}"; then
  echo "Error: CURRENT_PROJECT_VERSION substitution did not take effect in ${PROJECT_YML}" >&2
  exit 1
fi

echo "=== Build & archive ==="
"${ROOT_DIR}/scripts/build.sh"

echo "=== Export .ipa & upload to TestFlight ==="
"${ROOT_DIR}/scripts/upload-testflight.sh"

# Past this point the version bump represents a real shipped build, so we keep it
# in the working tree even if the commit/push step fails — the user can finish by hand.
SKIP_RESTORE=1
trap - ERR

echo "=== Commit version bump (jj) ==="
jj describe -m "Release ${VERSION} (build ${NEW_BUILD})

- Bump MARKETING_VERSION to ${VERSION}
- Bump CURRENT_PROJECT_VERSION to ${NEW_BUILD}

Co-Authored-By: Claude ${MODEL_NAME} <noreply@anthropic.com>"

jj bookmark set main -r @
# jj git push auto-creates a new empty change at @ — no jj new needed (per CLAUDE.md).
jj git push --bookmark main

# Resolve the released commit explicitly so the tag points at the release commit,
# not at the empty change jj auto-creates after `jj git push`.
RELEASE_COMMIT=$(git rev-parse main)

echo "=== Git tag ${TAG} ==="
if git tag --list "$TAG" | grep -q .; then
  echo "Error: tag $TAG already exists locally. Re-running with the same version is not supported." >&2
  echo "       Bump to a new patch version, or delete the tag explicitly first:" >&2
  echo "         git tag -d $TAG && git push origin :refs/tags/$TAG" >&2
  exit 1
fi
git tag "$TAG" "$RELEASE_COMMIT"
git push origin "$TAG"

echo ""
echo "=== Release ${VERSION} (build ${NEW_BUILD}) complete ==="
echo ""
echo "Next:"
echo "  - TestFlight processes the build (~5–30 min). Beta testers see it once VALID."
echo "  - Open https://appstoreconnect.apple.com/apps"
