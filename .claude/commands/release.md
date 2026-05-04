# Release HDZap

Release a new version of HDZap to TestFlight with automatic version bump and a generated commit message.

## Task

### 1. Get current version and changes

```bash
# Current marketing + build version
grep -E 'MARKETING_VERSION|CURRENT_PROJECT_VERSION' app/project.yml

# Most recent release tag
git tag --sort=-version:refname | head -1

# Diff from previous tag (or HEAD if no tags yet)
PREV_TAG="$(git tag --sort=-version:refname | head -1)"
if [[ -n "$PREV_TAG" ]]; then
  git diff "${PREV_TAG}..HEAD" -- app firmware
else
  git log --oneline -- app firmware | head
fi
```

### 2. Decide the version bump

Based on the diff, pick:

- **Major (X.0.0)**: Breaking BLE protocol change, big rewrite, incompatible firmware
- **Minor (X.Y.0)**: New visible feature on the app or goggle OSD, new BLE characteristic, significant change
- **Patch (X.Y.Z)**: Bug fix, small UX tweak, refactor, perf, docs

Default to **patch** when uncertain. Build number is bumped automatically by the script.

### 3. Run release.sh

```bash
MODEL_NAME="<your model name>" ./scripts/release.sh <new_version>
```

Set `MODEL_NAME` so the Co-Authored-By line in the commit matches the actual model running.

The script:
1. Bumps `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `app/project.yml`
2. Runs `xcodegen generate` and archives the iOS app
3. Exports `.ipa` and uploads it to TestFlight via `altool`
4. `jj describe` + `jj new`
5. `jj bookmark set main && jj git push --bookmark main`
6. Creates and pushes a `v<version>` git tag

### 4. Tell the user where to find the build

```
TestFlight processes the new build in 5–30 min. Once VALID, internal testers
in the "Internal Testers" group can install via the TestFlight app.
```

If a TestFlight "What to Test" note is wanted, ask the user before adding it via ASC API or the web UI.

## Notes

- **Always analyze the diff first** before deciding the version. The repo contains both `app/` (iOS) and `firmware/` (ESP32). Firmware-only changes do **not** require an iOS release; skip the script and tell the user.
- The `.p8` private key location and ASC API credentials live in `docs/testflight-setup.md` and the `testflight_credentials` memory entry. The script defaults to those — override via `ASC_API_KEY_ID` / `ASC_API_ISSUER_ID` env vars if needed.
- Re-running `release.sh` with the same version number replaces the tag but the build number always increments, so TestFlight will accept the upload.
- **Release notes for TestFlight** are entered separately in App Store Connect (TestFlight tab → build → Test Details → "What to Test"). They are not part of the git commit message.
