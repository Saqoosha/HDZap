# release-process Specification

## Purpose

Promote a develop snapshot to production with one command, ensuring the iOS build reaches TestFlight, the firmware reaches production Pages, and the release is tagged + announced via GitHub Releases — with rollback-ability up to the irreversible TestFlight upload step.

## Requirements

### Requirement: Single entry point / 単一エントリポイント

Releases SHALL be driven by `scripts/release.sh <version>` with `MODEL_NAME` set so the commit Co-Authored-By line matches the running model. Direct push to `main` is rejected by branch protection (per `dual-branch-deployment`); the script is the sanctioned promotion path.

`<version>` MUST match `X.Y.Z` (semver MAJOR.MINOR.PATCH). The script computes `TAG = vX.Y.Z`.

`MODEL_NAME` 環境変数の必須化は、Co-Authored-By を間違いなく明記するための運用ルール。`scripts/release.sh` は人間+AI 共同作業の前提で書かれている。

#### Scenario: Run with no version
- Given the operator runs `MODEL_NAME="Opus 4.7" ./scripts/release.sh`
- When the argument check fails
- Then the script prints usage and exits 1

#### Scenario: Run without MODEL_NAME
- Given the operator runs `./scripts/release.sh 1.0.1` without setting MODEL_NAME
- When the script's `: "${MODEL_NAME:?...}"` check fires
- Then the script exits with the informative message

### Requirement: Pre-flight checks / プリフライトチェック

The script SHALL refuse to proceed unless ALL of the following hold:

1. The working copy (`@`) is at the `develop` bookmark.
2. The git working tree is clean (no staged or unstaged changes).
3. Local `develop` is in sync with `origin/develop` (after `git fetch origin --tags`).
4. The release tag does NOT already exist locally or on origin.
5. `CURRENT_PROJECT_VERSION` in `app/project.yml` parses as an integer.

Failure of any check SHALL print a specific actionable error and exit non-zero before any state mutation.

`jj` (Jujutsu) を使うため `jj log -r develop` と `jj log -r '@'` の commit_id 比較で「working copy が develop か」を判定する。これは jj-first ワークフローの結果。

#### Scenario: Dirty working tree
- Given uncommitted changes in `app/`
- When the script runs
- Then `git diff --quiet` fails and the script prints "working tree is not clean", shows `git status --short`, and exits 1

#### Scenario: Tag already exists
- Given `git tag --list v1.0.1` outputs anything
- When the script runs
- Then the script prints "tag v1.0.1 already exists locally", suggests deletion commands, and exits 1

### Requirement: Version bump / バージョンバンプ

The script SHALL update `app/project.yml`:

- `MARKETING_VERSION` → the new `<version>`.
- `CURRENT_PROJECT_VERSION` → `(current + 1)`.

After the substitutions, the script SHALL grep-verify that both new values are present in the file (BSD `sed` exits 0 even on no-op, so the verify step catches a regex that didn't match).

#### Scenario: Build number bump
- Given `CURRENT_PROJECT_VERSION: "23"` and version 1.0.1
- When the bump runs
- Then the file has `MARKETING_VERSION: "1.0.1"` and `CURRENT_PROJECT_VERSION: "24"`

#### Scenario: Bump verify fails
- Given the sed regex doesn't match (e.g. unexpected formatting in project.yml)
- When the verify grep runs
- Then the script prints "MARKETING_VERSION substitution did not take effect" and exits 1
- And the ERR trap restores project.yml from git

### Requirement: Build → upload → commit ordering / ビルド → アップロード → コミット順序

The script SHALL execute in this order:

1. Bump version in project.yml.
2. `scripts/build.sh` — build & archive the iOS app.
3. `scripts/upload-testflight.sh` — export .ipa & upload to TestFlight.
4. After upload succeeds: clear the ERR trap (`SKIP_RESTORE=1; trap - ERR`). Subsequent failures keep the bump in the working tree.
5. `jj describe -m "Release X.Y.Z (build N)\n..."` with the Co-Authored-By line.
6. `jj bookmark set develop -r @ + jj git push --bookmark develop`.

Up to and including step 3, an error SHALL trigger the ERR trap to restore project.yml from git, leaving the working tree clean. After step 3, the bump is kept — the build is shipped to TestFlight and the operator can finish the commit/PR/tag flow by hand.

`jj git push` は push 後に自動で `@` 上に新しい empty change を作るため、`jj new` を別途呼ばない。CLAUDE.md でルール化されている。

#### Scenario: TestFlight upload fails
- Given the build succeeded but the TestFlight upload threw (network, code-sign, etc.)
- When the ERR trap fires
- Then `git checkout -- app/project.yml` restores the original
- And the operator can retry from a clean working tree

#### Scenario: Commit step fails after TestFlight success
- Given the upload succeeded but `jj describe` failed
- When the failure happens
- Then the ERR trap is no longer active (cleared after step 3)
- And the bump remains in the working tree
- And the operator finishes commit/PR/tag manually from the existing bump

### Requirement: Wait for develop CI / develop CI 待機

After the develop bookmark is pushed, the script SHALL wait for the develop "Web Flasher" workflow run on the release commit to complete. The script SHALL:

1. Sleep ~5 s for GitHub to register the push event.
2. Poll `gh run list` up to 6 times (~30 s total) to find the run by `headSha == DEVELOP_RELEASE_COMMIT`.
3. `gh run watch <run-id> --exit-status` to block until the run finishes.
4. On run failure: exit 1 with a message that the bump and TestFlight build are already shipped (the operator must investigate before promoting to main).
5. On no run found within the polling window: print a warning and continue (the upstream `gh` API can lag).

#### Scenario: Develop CI passes
- Given the bookmark push triggers the CI run
- When `gh run watch` returns 0
- Then the script proceeds to open the release PR

#### Scenario: Develop CI fails
- Given the firmware build for develop fails on the release commit
- When `gh run watch` returns non-zero
- Then the script exits 1
- And prints that promotion to main is blocked until the failure is resolved

### Requirement: Release PR develop → main / リリース PR develop → main

The script SHALL open a PR using `gh pr create --base main --head develop --title "Release <version> (build <N>)" --body <body>`. The body SHALL mention:

- iOS app uploaded to TestFlight as build N.
- Firmware will be served from `/flash/` once the PR merges.
- Staging preview URL: `https://saqoosha.github.io/HDZap/dev/`.

The PR SHALL be merged via `gh pr merge --merge --delete-branch=false` (merge commit, NOT squash). Preserving the merge commit keeps the develop history intact on main, so the release point is observable.

`--delete-branch=false` は重要: `develop` を消さずに、リリース後も継続使用する。`squash` ではなく `merge` を選ぶのは、TestFlight build commit + その後の develop 進捗を main に明示的に取り込みたいから。

#### Scenario: Open and merge release PR
- Given the develop CI passed
- When the script runs `gh pr create` and `gh pr merge --merge`
- Then a release PR is created and merged with a merge commit on main
- And develop branch is preserved

### Requirement: Tag and GitHub Release / タグと GitHub Release

After the merge, the script SHALL:

1. `git fetch origin main` to get the merge commit.
2. `git tag -a v<version> <main HEAD> -m "Release X.Y.Z (build N)"`.
3. `git push origin v<version>`.
4. `gh release create v<version>` with title `HDZap X.Y.Z (build N)` and notes referencing the production Pages, manual, and release PR URLs.

The annotated tag (NOT lightweight) is required so `git describe` on main always lands on a release tag with metadata.

#### Scenario: Tag pushed
- Given the merge commit exists on origin/main
- When the script tags and pushes
- Then `git ls-remote --tags origin v<version>` returns the tag
- And the GitHub Release page lists it under Releases

### Requirement: Develop fast-forward / develop の Fast-forward

After tagging, the script SHALL fast-forward local develop to `main@origin` and push:

```
jj git fetch
jj bookmark set develop -r main@origin
jj git push --bookmark develop
```

This brings the merge commit onto develop so the next release cycle starts from a develop in sync with main. Without this, develop stays one merge commit behind and the next release would re-merge that gap into main.

#### Scenario: Develop FF
- Given main@origin has the new merge commit
- When `jj bookmark set develop -r main@origin` runs
- Then local develop points at the merge commit
- And `jj git push` updates origin/develop to match

### Requirement: Co-Authored-By in commits / コミットの Co-Authored-By

The release commit message SHALL end with `Co-Authored-By: Claude <MODEL_NAME> <noreply@anthropic.com>`. The MODEL_NAME env var captures the running model so attribution is accurate when AI assists the release.

#### Scenario: Commit message format
- Given `MODEL_NAME="Opus 4.7 (1M context)"`
- When `jj describe` runs
- Then the message ends with `Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>`
