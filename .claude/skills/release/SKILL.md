---
name: release
description: Cut a new HDZap release — bump the iOS marketing/build version on the develop branch, build and upload the iOS app to TestFlight, promote develop → main via a release PR, deploy the Web Flasher firmware + end-user manual to production GitHub Pages, tag the released commit as v<X.Y.Z>, and publish a GitHub Release. Also handles **build-only releases** (CURRENT_PROJECT_VERSION bump only, no MARKETING_VERSION change) when the operator needs to ship to existing TestFlight beta testers without triggering a fresh beta-review approval cycle. Use when the user says "release", "ship it", "cut a release", "new version", "promote develop to main", "TestFlight build", "bump version", "tag a release", "v1.0.x", "build-only release", "ship without bumping version", or otherwise asks to release HDZap.
---

# Release HDZap

Cut a new HDZap release from `develop` → `main`, ship the iOS app to TestFlight, deploy the Web Flasher + manual to production, and tag the released commit.

Two variants:

- **Full release** (`v<X.Y.Z>`): MARKETING_VERSION + CURRENT_PROJECT_VERSION both bump. Triggers a fresh TestFlight beta-review approval. This is the default — use for any release that ships visible iOS changes worth a version-string bump.
- **Build-only release** (`v<X.Y.Z>+buildN`): CURRENT_PROJECT_VERSION bumps only; MARKETING_VERSION stays put. Apple skips the beta-review approval step (build numbers within the same version go through automatic / fast-track review), so the build reaches existing internal testers immediately. Use when a fix needs to ship to current testers without re-onboarding through review — see the dedicated section below.

## Branching model

- `develop` — active work; CI deploys to staging at <https://saqoosha.github.io/HDZap/dev/> (`/dev/flash/`, `/dev/ja/`).
- `main` — known-good release; CI deploys to production (`/flash/`, `/ja/`, `/`). Branch-protected: PR-only merge.
- Releases promote `develop` → `main` through a release PR. The TestFlight build, the Web Flasher firmware, and the manual ship together as one unit.

## Procedure

### 1. Get current version and changes

```bash
# Current marketing + build version
grep -E 'MARKETING_VERSION|CURRENT_PROJECT_VERSION' app/project.yml

# Most recent release tag
git tag --sort=-version:refname | head -1

# Diff from previous tag (or develop tip if no tags yet)
PREV_TAG="$(git tag --sort=-version:refname | head -1)"
if [[ -n "$PREV_TAG" ]]; then
  git log --oneline "${PREV_TAG}..develop" -- app firmware docs/manual
  git diff "${PREV_TAG}..develop" -- app firmware
else
  git log --oneline develop -- app firmware docs/manual | head
fi
```

### 2. Decide the version bump

Based on the diff, pick:

- **Major (X.0.0)**: Breaking BLE protocol change, big rewrite, incompatible firmware
- **Minor (X.Y.0)**: New visible feature on the app or goggle OSD, new BLE characteristic, significant change
- **Patch (X.Y.Z)**: Bug fix, small UX tweak, refactor, perf, docs

Default to **patch** when uncertain. The build number is bumped automatically by the script.

### 3. Run release.sh

The script must be run from the `develop` bookmark with a clean working tree that is in sync with `origin/develop`. It will refuse to start otherwise.

```bash
MODEL_NAME="<your model name>" ./scripts/release.sh <new_version>
```

`MODEL_NAME` is required (the script fails fast if unset) so the Co-Authored-By line in the commit matches the actual model running.

The script:

1. **Pre-flight**: verify working copy is at `develop`, tree is clean, `develop` is in sync with `origin/develop`, and the target tag does not yet exist.
2. **Bump** `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `app/project.yml`.
3. Run `xcodegen generate` and **archive** the iOS app (`scripts/build.sh`).
4. Export `.ipa` and **upload to TestFlight** via `altool` (`scripts/upload-testflight.sh`). **This is the irreversible step** — everything before it is roll-back-able; everything after preserves the bump even on failure.
5. `jj describe` the working-copy change with the bump.
6. `jj bookmark set develop -r @` and `jj git push --bookmark develop`.
7. **Wait** for the develop CI run to go green (firmware build + staging Pages deploy under `/dev/`).
8. **Open a release PR** `develop → main` and **merge it** (`--merge`, preserves the cut as a merge commit on `main`).
9. Fetch `origin/main`, **tag** the merge commit as `v<version>`, push the tag.
10. **Create a GitHub Release** with consistent formatting:

    ```bash
    gh release create "v<X.Y.Z>" \
      --title "<X.Y.Z>" \
      --notes "<release notes>"
    ```

    **Title format**: `X.Y.Z` for full releases (e.g., "1.0.1"), `X.Y.Z build N` for build-only (e.g., "1.0.0 build 4").
    **Body format** (both variants):
    - `## What's in X.Y.Z` (full) or `## Changes since <previous>` (build-only) — bullet list of user-facing changes only; skip docs/infra/CI/internal changes
    - `## Compatibility` (full releases only; omit for build-only)
    - `## Links` — TestFlight beta invite + Web Flasher + Manual (EN) + Manual (JA)
    - Do NOT include a "🤖 Generated with…" footer line.

11. **Fill TestFlight "What to Test"** for both en-US and ja locales via the App Store Connect API — see the TestFlight "What to Test" section below.
12. **Fast-forward** local `develop` to `main` so the next cycle starts in sync.

### 4. Re-run main CI after the tag push (cosmetic, but matters)

The `gh pr merge` push and the tag push race against CI. The merge commit lands on `main` and triggers the Web Flasher workflow before `git push origin <tag>` finishes, so the first CI run on `main` builds firmware against a tree where `git describe --tags` still resolves to the *previous* tag (`v<prev>-N-g<sha>`) instead of the new one. The deployed firmware on <https://saqoosha.github.io/HDZap/flash/> shows the dev-style string until the next CI run.

The version-check feature still works through this — `firmwareMajor()` only parses the leading integer, which is preserved across both forms — so this is purely cosmetic. But a tagged release should serve a tagged firmware string, so the script (and any manual procedure) re-runs `main`'s latest CI after pushing the tag:

```bash
RUN_ID=$(gh run list --branch main --workflow "Web Flasher" --limit 1 --json databaseId --jq '.[0].databaseId')
gh run rerun "$RUN_ID"
gh run watch "$RUN_ID" --exit-status
```

The re-run picks up the new tag and rebuilds + redeploys, so the production Web Flasher serves firmware stamped with the new tag string.

### 5. Tell the user where to find the build

```
TestFlight processes the new build in 5–30 min. Once VALID, internal testers
in the "Internal Testers" group can install via the TestFlight app.
```

Also share the production URLs once the main-branch CI deploy lands:

- Web Flasher: <https://saqoosha.github.io/HDZap/flash/>
- Manual (English): <https://saqoosha.github.io/HDZap/>
- Manual (日本語): <https://saqoosha.github.io/HDZap/ja/>

## TestFlight "What to Test"

Fill the "What to Test" field for every build via the App Store Connect API, in both en-US and ja.

```python
# Generate JWT from the .p8 key, then:
POST /v1/betaBuildLocalizations
# or PATCH if the locale already exists

locales = {
    "en-US": "What to test:\n• …",
    "ja": "テスト内容:\n• …",
}
```

- The build ID comes from the `altool --upload-app` response (`Delivery UUID`), or from `GET /v1/builds?filter[app]=<app_id>&sort=-uploadedDate`.
- Draft the notes by looking at the user-facing diff — skip docs/infra/CI/internal changes.
- Write both locales in parallel; create if missing, update if the locale already exists on the build.

## Build-only release (no MARKETING_VERSION bump)

Use this variant when the operator wants the develop tip to reach existing TestFlight beta testers **without** triggering a fresh beta-review approval. Apple gates beta-review on `CFBundleShortVersionString` (= `MARKETING_VERSION`); a `CFBundleVersion` (= `CURRENT_PROJECT_VERSION`) bump within the same marketing version goes through automatic / fast-track review and reaches testers immediately.

`scripts/release.sh` only knows full releases (it requires `X.Y.Z` and bumps both fields), so the build-only path is currently a manual procedure. Steps mirror the script but with two differences: `MARKETING_VERSION` stays put, and the tag uses SemVer build-metadata syntax `v<X.Y.Z>+build<N>` instead of `v<X.Y.Z>`.

### Procedure

1. **Pre-flight** (same as the script): on develop, working tree clean, `develop == origin/develop`, target tag `v<current-marketing>+build<N+1>` does not exist.

2. **Bump build only** in `app/project.yml`:

   ```bash
   CURRENT_BUILD=$(grep 'CURRENT_PROJECT_VERSION:' app/project.yml | sed 's/.*: *"\([0-9]*\)".*/\1/')
   NEW_BUILD=$((CURRENT_BUILD + 1))
   sed -i '' "s/CURRENT_PROJECT_VERSION: \".*\"/CURRENT_PROJECT_VERSION: \"${NEW_BUILD}\"/" app/project.yml
   # MARKETING_VERSION stays at its current value — do NOT touch it.
   ```

3. **Build & archive**. `project.yml` uses `<TEAM_ID>` as a placeholder for `DEVELOPMENT_TEAM` — pass the real team ID on the xcodebuild command line:

   ```bash
   cd app && xcodegen generate && xcodebuild \
     -project HDZap.xcodeproj \
     -scheme HDZap \
     -destination 'generic/platform=iOS' \
     -configuration Release \
     -archivePath build/archives/HDZap.xcarchive \
     -allowProvisioningUpdates \
     DEVELOPMENT_TEAM=VCFY2GFR89 \
     archive
   ```

4. **Upload to TestFlight** (irreversible). `upload-testflight.sh` has `<KEY_ID>` / `<ISSUER_ID>` placeholders — pass real values via env vars:

   ```bash
   ASC_API_KEY_ID=76DV838N2N \
   ASC_API_ISSUER_ID=69a6de6e-6653-47e3-e053-5b8c7c11a4d1 \
   ./scripts/upload-testflight.sh
   ```

5. **Commit & push develop** (jj):

   ```bash
   jj describe -m "Bump build to ${NEW_BUILD} (<X.Y.Z> build ${NEW_BUILD}) for TestFlight

   Build-number-only bump — MARKETING_VERSION stays at <X.Y.Z> so the
   build can ship to existing beta testers without a fresh beta-review
   approval cycle.

   Co-Authored-By: Claude <model> <noreply@anthropic.com>"
   jj bookmark set develop -r @
   jj git push --bookmark develop
   ```

6. **Open + merge release PR** `develop → main` with `--merge` (matches the full-release path; preserves the cut as a merge commit).

7. **Tag the merge commit** with SemVer build-metadata syntax:

   ```bash
   git fetch origin main
   MERGE_COMMIT=$(git rev-parse origin/main)
   git tag -a "v<X.Y.Z>+build${NEW_BUILD}" "$MERGE_COMMIT" \
     -m "Build ${NEW_BUILD} of <X.Y.Z>"
   git push origin "v<X.Y.Z>+build${NEW_BUILD}"
   ```

   The `+build<N>` suffix is intentional. The version-check feature on iOS only parses the **major** integer (digits before the first `.`), so `v1.0.0+build3` parses identically to `v1.0.0` (major = 1) and the compatibility check still works. Crucially, this format also avoids reusing or colliding with the existing `v<X.Y.Z>` tag.

8. **Re-run main CI** (same race as full releases — see step 4 above):

   ```bash
   RUN_ID=$(gh run list --branch main --workflow "Web Flasher" --limit 1 --json databaseId --jq '.[0].databaseId')
   gh run rerun "$RUN_ID"
   gh run watch "$RUN_ID" --exit-status
   ```

9. **Fast-forward develop to main** so the next cycle starts in sync:

   ```bash
   jj git fetch
   jj bookmark set develop -r main@origin
   jj git push --bookmark develop
   ```

10. **Create a GitHub Release** with the same title and body format as full releases:

    ```bash
    gh release create "v<X.Y.Z>+build${NEW_BUILD}" \
      --title "<X.Y.Z> build ${NEW_BUILD}" \
      --notes "<release notes>"
    ```

    **Title format**: `X.Y.Z build N` (e.g., "1.0.0 build 4").
    **Body format**:
    - `## Changes since <previous>` — bullet list of user-facing changes only; skip docs/infra/CI/internal changes
    - `## Links` — TestFlight beta invite + Web Flasher + Manual (EN) + Manual (JA)
    - Do NOT include a "🤖 Generated with…" footer line.

11. **Fill TestFlight "What to Test"** for both en-US and ja locales — see the TestFlight "What to Test" section above.

### When to use full vs. build-only

| Situation | Variant | Tag |
|---|---|---|
| Visible iOS UX change, app feature, version-string-worthy | Full | `v<X.Y.Z>` |
| Bug fix urgent enough to skip beta-review re-run | Build-only | `v<X.Y.Z>+build<N>` |
| Firmware-only change (no iOS code touched) | Full *or* skip iOS upload (see Notes) | `v<X.Y.Z>` |
| Quick re-upload to fix a TestFlight processing failure on the same build | Full (next patch) | `v<X.Y.(Z+1)>` |

When in doubt, default to a full release — the build-only path is for the specific case where retaining the existing beta-review approval is operationally important.

## Notes

- **Always analyze the diff first** before deciding the version. The repo contains both `app/` (iOS) and `firmware/` (ESP32). Firmware-only changes still ship through the release PR (the Web Flasher firmware bundle moves with the release), but you can skip the iOS bump+upload by running just the PR + tag steps by hand if the iOS app has not changed.
- The release PR uses `--merge`. After the merge, `main`'s HEAD is the merge commit, and the script fast-forwards local `develop` to `main` so the two stay aligned.
- **Branch protection**: `main` is protected against direct push (PR-only merge, force-push and delete blocked, admin bypass enabled for emergencies). The release script promotes through a PR, so this is not an obstacle. Hotfixes still go via PR — branch from `main`, fix, PR straight back to `main`, then bring `develop` up to date.
- **Placeholder credentials**: `project.yml` uses `<TEAM_ID>` for `DEVELOPMENT_TEAM` (valid YAML). `ExportOptions.plist` uses `YOUR_TEAM_ID` for `teamID` (valid XML — the legacy `<TEAM_ID>` literal broke `plutil` / xcodebuild parsing because `<` and `>` are XML special characters). `upload-testflight.sh` uses `<KEY_ID>` / `<ISSUER_ID>` for ASC API credentials. Pass real values on the command line or via env vars at build time.
- The `.p8` private key location and ASC API credentials live in `docs/testflight-setup.md` (and, for Claude Code only, the `testflight_credentials` memory entry).
- Re-running `release.sh` with the **same** version number fails fast — the tag-replace branch was removed because it silently masked auth/network errors. To re-cut a release, bump to the next patch version, or delete the tag explicitly first (`git tag -d <tag> && git push origin :refs/tags/<tag>`).
- **GitHub Release body**: include user-facing changes only — skip docs/infra/CI/internal commits. Never include a "🤖 Generated with…" footer. Edit any existing release that doesn't match with `gh release edit <tag>`.
- **TestFlight "What to Test"** is set via the ASC API (not the GitHub Release body). Fill both en-US and ja for every build.
