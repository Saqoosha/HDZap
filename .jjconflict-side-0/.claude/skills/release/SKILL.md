---
name: release
description: Cut a new HDZap release — bump the iOS marketing/build version on the develop branch, build and upload the iOS app to TestFlight, promote develop → main via a release PR, deploy the Web Flasher firmware + end-user manual to production GitHub Pages, tag the released commit as v<X.Y.Z>, and publish a GitHub Release. Use when the user says "release", "ship it", "cut a release", "new version", "promote develop to main", "TestFlight build", "bump version", "tag a release", "v1.0.x", or otherwise asks to release HDZap.
---

# Release HDZap

Cut a new HDZap release from `develop` → `main`, ship the iOS app to TestFlight, deploy the Web Flasher + manual to production, and tag the released commit.

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
10. **Create a GitHub Release** with notes pointing at the PR + production URLs.
11. **Fast-forward** local `develop` to `main` so the next cycle starts in sync.

### 4. Tell the user where to find the build

```
TestFlight processes the new build in 5–30 min. Once VALID, internal testers
in the "Internal Testers" group can install via the TestFlight app.
```

Also share the production URLs once the main-branch CI deploy lands:

- Web Flasher: <https://saqoosha.github.io/HDZap/flash/>
- Manual (English): <https://saqoosha.github.io/HDZap/>
- Manual (日本語): <https://saqoosha.github.io/HDZap/ja/>

If a TestFlight "What to Test" note is wanted, ask the user before adding it via ASC API or the web UI.

## Notes

- **Always analyze the diff first** before deciding the version. The repo contains both `app/` (iOS) and `firmware/` (ESP32). Firmware-only changes still ship through the release PR (the Web Flasher firmware bundle moves with the release), but you can skip the iOS bump+upload by running just the PR + tag steps by hand if the iOS app has not changed.
- The release PR uses `--merge`. After the merge, `main`'s HEAD is the merge commit, and the script fast-forwards local `develop` to `main` so the two stay aligned.
- **Branch protection**: `main` is protected against direct push (PR-only merge, force-push and delete blocked, admin bypass enabled for emergencies). The release script promotes through a PR, so this is not an obstacle. Hotfixes still go via PR — branch from `main`, fix, PR straight back to `main`, then bring `develop` up to date.
- The `.p8` private key location and ASC API credentials live in `docs/testflight-setup.md` (and, for Claude Code only, the `testflight_credentials` memory entry). The script defaults to those — override via `ASC_API_KEY_ID` / `ASC_API_ISSUER_ID` env vars when releasing for a different team or app.
- Re-running `release.sh` with the **same** version number fails fast — the tag-replace branch was removed because it silently masked auth/network errors. To re-cut a release, bump to the next patch version, or delete the tag explicitly first (`git tag -d <tag> && git push origin :refs/tags/<tag>`).
- **Release notes for TestFlight** are entered separately in App Store Connect (TestFlight tab → build → Test Details → "What to Test"). They are not part of the git commit message. The GitHub Release notes are auto-generated by the script and can be edited afterwards via `gh release edit <tag>`.
