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

`MODEL_NAME` is required (the script fails fast if unset) so the Co-Authored-By line in the commit matches the actual model running.

The script:
1. Bumps `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `app/project.yml`
2. Runs `xcodegen generate` and archives the iOS app
3. Exports `.ipa` and uploads it to TestFlight via `altool`
4. `jj describe` the working-copy change with the bump
5. `jj bookmark set develop -r @` and `jj git push --bookmark develop` (jj auto-creates a new empty change at `@` after the push — no `jj new` needed)
6. Waits for the develop CI run to go green (firmware build + staging Pages deploy), opens a release PR `develop → main`, and merges it — direct push to `main` is rejected by branch protection
7. After the merge, captures the merged commit hash on `main`, tags it as `v<version>`, and pushes the tag (`git push origin v<version>`)
8. Creates a GitHub Release for `v<version>` and fast-forwards local `develop` to `main` so the next cycle starts in sync

### 4. Tell the user where to find the build

```text
TestFlight processes the new build in 5–30 min. Once VALID, internal testers
in the "Internal Testers" group can install via the TestFlight app.
```

If a TestFlight "What to Test" note is wanted, ask the user before adding it via ASC API or the web UI.

## Notes

- **Always analyze the diff first** before deciding the version. The repo contains both `app/` (iOS) and `firmware/` (ESP32). Firmware-only changes do **not** require an iOS release; skip the script and tell the user.
- The `.p8` private key location and ASC API credentials live in `docs/testflight-setup.md` (and, for Claude Code only, the `testflight_credentials` memory entry). The script defaults to those — override via `ASC_API_KEY_ID` / `ASC_API_ISSUER_ID` env vars when releasing for a different team or app.
- Re-running `release.sh` with the **same** version number now fails fast — the tag-replace branch was removed because it silently masked auth/network errors. To re-cut a release, bump to the next patch version, or delete the tag explicitly first (`git tag -d <tag> && git push origin :refs/tags/<tag>`).
- **Release notes for TestFlight** are entered separately in App Store Connect (TestFlight tab → build → Test Details → "What to Test"). They are not part of the git commit message.
