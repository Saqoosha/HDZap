#!/usr/bin/env bash
set -euo pipefail

# Release a new HDZap version.
#   MODEL_NAME="Opus 4.7" ./scripts/release.sh 1.0.1
#
# Requires running on the `develop` bookmark with a clean working tree that
# is in sync with origin/develop. The release flow is:
#
#   1. Bump MARKETING_VERSION to <version> and CURRENT_PROJECT_VERSION to (current+1)
#   2. Build & archive the iOS app (scripts/build.sh)
#   3. Export .ipa & upload to TestFlight (scripts/upload-testflight.sh)
#      ^ irreversible step; everything before this is roll-back-able
#   4. jj describe the working-copy change with a Co-Authored-By line
#   5. jj bookmark set develop -r @ + jj git push --bookmark develop
#      (jj auto-creates a new empty change at @ after the push — do NOT run jj new)
#   6. Wait for the develop CI run to go green (firmware build + staging Pages deploy)
#   7. Open a release PR develop → main and merge it (--merge, preserves the cut)
#   8. Tag the merge commit on main as v<version>, push tag
#   9. Re-run main's Web Flasher CI so the deployed firmware on /flash/
#      picks up the new tag (the merge → CI start → tag push race means the
#      first run built before the tag was visible to git describe)
#  10. Create a GitHub Release for v<version>
#  11. Fast-forward local develop to main so the next cycle starts in sync
#
# For build-only releases (CURRENT_PROJECT_VERSION bump only, MARKETING_VERSION
# unchanged) — used when shipping to existing TestFlight beta testers without
# a fresh beta-review approval — see `.claude/skills/release/SKILL.md` for the
# manual procedure. This script does not handle that variant.
#
# Recovery on failure: if any step before TestFlight upload fails, the script
# restores project.yml from git so the working tree stays clean. After a
# successful upload the bump is kept (the build is shipped), even if the later
# git/PR/tag steps fail — finish those by hand from the existing bump commit.

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

if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Error: Invalid version format. Use X.Y.Z (e.g., 1.0.1)" >&2
  exit 1
fi

cd "$ROOT_DIR"

echo "=== Pre-flight checks ==="

# Working copy (@) must be at develop, working tree clean, in sync with origin.
DEVELOP_REV=$(jj log -r develop --no-graph --no-pager -T 'commit_id' 2>/dev/null | head -c 40 || true)
WC_REV=$(jj log -r '@' --no-graph --no-pager -T 'commit_id' 2>/dev/null | head -c 40 || true)
if [[ -z "$DEVELOP_REV" || -z "$WC_REV" ]]; then
  echo "Error: failed to read jj revisions for develop / @" >&2
  exit 1
fi
if [[ "$DEVELOP_REV" != "$WC_REV" ]]; then
  echo "Error: working copy (@) is not at the develop bookmark." >&2
  echo "       develop = ${DEVELOP_REV}" >&2
  echo "       @       = ${WC_REV}" >&2
  echo "       Run: jj edit develop" >&2
  exit 1
fi

if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "Error: working tree is not clean. Commit or restore changes first." >&2
  git status --short
  exit 1
fi

git fetch origin --tags
LOCAL_DEVELOP=$(git rev-parse develop)
REMOTE_DEVELOP=$(git rev-parse origin/develop)
if [[ "$LOCAL_DEVELOP" != "$REMOTE_DEVELOP" ]]; then
  echo "Error: local develop is not in sync with origin/develop." >&2
  echo "       local  = ${LOCAL_DEVELOP}" >&2
  echo "       origin = ${REMOTE_DEVELOP}" >&2
  exit 1
fi

# Tag must not already exist locally or on origin.
if git tag --list "$TAG" | grep -q .; then
  echo "Error: tag $TAG already exists locally. Bump to a new version, or delete it first:" >&2
  echo "         git tag -d $TAG && git push origin :refs/tags/$TAG" >&2
  exit 1
fi
if git ls-remote --tags origin "refs/tags/$TAG" | grep -q .; then
  echo "Error: tag $TAG already exists on origin." >&2
  exit 1
fi

echo "  develop @ ${DEVELOP_REV:0:12}, working tree clean, tag ${TAG} free"

CURRENT_BUILD=$(grep 'CURRENT_PROJECT_VERSION:' "${PROJECT_YML}" | sed 's/.*: *"\([0-9]*\)".*/\1/')
if ! [[ "$CURRENT_BUILD" =~ ^[0-9]+$ ]]; then
  echo "Error: failed to parse CURRENT_PROJECT_VERSION from ${PROJECT_YML} (got: '${CURRENT_BUILD}')" >&2
  exit 1
fi
NEW_BUILD=$((CURRENT_BUILD + 1))

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

# Past this point the version bump represents a real shipped build, so we keep
# it in the working tree even if the later steps fail — the user can finish
# the commit/PR/tag flow by hand without losing the bump.
SKIP_RESTORE=1
trap - ERR

echo "=== Commit version bump on develop (jj) ==="
jj describe -m "Release ${VERSION} (build ${NEW_BUILD})

- Bump MARKETING_VERSION to ${VERSION}
- Bump CURRENT_PROJECT_VERSION to ${NEW_BUILD}

Co-Authored-By: Claude ${MODEL_NAME} <noreply@anthropic.com>"

jj bookmark set develop -r @
# jj git push auto-creates a new empty change at @ — no jj new needed (per CLAUDE.md).
jj git push --bookmark develop

DEVELOP_RELEASE_COMMIT=$(git rev-parse develop)

echo "=== Waiting for develop CI to go green ==="
# Give GitHub a few seconds to register the push event.
sleep 5
RUN_ID=""
for _ in 1 2 3 4 5 6; do
  RUN_ID=$(gh run list --branch develop --workflow "Web Flasher" --limit 5 \
    --json databaseId,headSha \
    --jq ".[] | select(.headSha == \"$DEVELOP_RELEASE_COMMIT\") | .databaseId" \
    | head -1)
  [[ -n "$RUN_ID" ]] && break
  sleep 5
done
if [[ -n "$RUN_ID" ]]; then
  if ! gh run watch "$RUN_ID" --exit-status; then
    echo "Error: develop CI run $RUN_ID failed. Investigate before promoting to main." >&2
    echo "       The version bump is already pushed to develop and the build is on TestFlight." >&2
    exit 1
  fi
else
  echo "Warn: no CI run found for develop@${DEVELOP_RELEASE_COMMIT:0:12}; skipping wait." >&2
fi

echo "=== Opening release PR develop → main ==="
PR_BODY=$(cat <<EOF
Release ${VERSION} (build ${NEW_BUILD}).

- iOS app uploaded to TestFlight as build ${NEW_BUILD}
- Firmware will be served from the Web Flasher at /flash/ once this merges
- Staging preview: https://saqoosha.github.io/HDZap/dev/

Generated by \`scripts/release.sh\`.
EOF
)

PR_URL=$(gh pr create \
  --base main \
  --head develop \
  --title "Release ${VERSION} (build ${NEW_BUILD})" \
  --body "$PR_BODY")
echo "  PR: $PR_URL"

echo "=== Merging release PR ==="
gh pr merge "$PR_URL" --merge --delete-branch=false

echo "=== Tagging ${TAG} on main ==="
git fetch origin main
RELEASE_COMMIT=$(git rev-parse origin/main)
git tag -a "$TAG" "$RELEASE_COMMIT" -m "Release ${VERSION} (build ${NEW_BUILD})"
git push origin "$TAG"

# The merge that landed the release commit on main triggered the Web Flasher
# workflow before this tag push could finish, so the first CI run on main
# built firmware against a tree where `git describe --tags` resolved to the
# *previous* tag (`v<prev>-N-g<sha>`) instead of `$TAG`. Re-run that CI now
# so the production /flash/ deploy serves firmware stamped with the new tag.
# The version-check feature still works without this — `firmwareMajor()`
# only parses the leading integer — but the dev-style version string on
# /flash/ is cosmetically wrong for a tagged release.
echo "=== Re-running main CI so /flash/ firmware reflects ${TAG} ==="
MAIN_RUN_ID=$(gh run list --branch main --workflow "Web Flasher" --limit 1 \
  --json databaseId --jq '.[0].databaseId')
if [[ -n "$MAIN_RUN_ID" ]]; then
  gh run rerun "$MAIN_RUN_ID"
  if ! gh run watch "$MAIN_RUN_ID" --exit-status; then
    echo "Warn: main CI re-run failed. Production /flash/ keeps the prior firmware." >&2
    echo "      Investigate via: gh run view $MAIN_RUN_ID" >&2
    # Don't exit — the tag, GitHub Release, and develop fast-forward steps
    # below are still useful even if the cosmetic re-run failed.
  fi
else
  echo "Warn: no main Web Flasher run found to re-trigger; skipping." >&2
fi

echo "=== Creating GitHub Release ==="
gh release create "$TAG" \
  --title "HDZap ${VERSION} (build ${NEW_BUILD})" \
  --notes "$(cat <<EOF
iOS app build ${NEW_BUILD} uploaded to TestFlight.

Production Web Flasher: https://saqoosha.github.io/HDZap/flash/
Manual: https://saqoosha.github.io/HDZap/

Release PR: $PR_URL
EOF
)"

echo "=== Fast-forwarding local develop to main ==="
jj git fetch
jj bookmark set develop -r main@origin
jj git push --bookmark develop

echo ""
echo "=== Release ${VERSION} (build ${NEW_BUILD}) complete ==="
echo "  PR:      $PR_URL"
echo "  Tag:     $TAG"
echo "  Commit:  $RELEASE_COMMIT"
echo ""
echo "Next:"
echo "  - TestFlight processes the build (~5-30 min). Internal testers install once VALID."
echo "  - Production Pages deploy runs from the merge commit; watch:"
echo "      gh run watch \$(gh run list --branch main --workflow 'Web Flasher' --limit 1 --json databaseId --jq '.[0].databaseId')"
