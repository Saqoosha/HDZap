# dual-branch-deployment Specification

## Purpose

Run a single GitHub Pages site that serves both the production (`main`) and staging (`develop`) slices simultaneously, so users can always reach the released artifacts and the team can preview unreleased work without fighting for the deploy lane.

## Requirements

### Requirement: Branches and URL slices / ブランチと URL スライス

The repository SHALL maintain two long-lived branches:

- `develop` (default) — staging. Pages slice: `/dev/`, `/dev/flash/`, `/dev/ja/`.
- `main` — production. Pages slice: `/`, `/flash/`, `/ja/`. Branch-protected; direct push rejected.

`main` SHALL only be updated via release PRs from `develop`. Releases promote develop → main; see `release-process`.

`develop` をデフォルトブランチにするのは、PR が無指定でも開発トランクに向くようにするため。`main` はリリース歴のみが乗る。

#### Scenario: Direct push to main rejected
- Given a developer attempts `git push origin <local>:main`
- When the remote evaluates branch protection
- Then the push is rejected with "protected branch"
- And the developer must open a PR (or use scripts/release.sh) to land on main

### Requirement: Pages composition / Pages 構成

CI on every push SHALL check out **both** branches (or PR head + base for PR builds), build firmware for each, and compose a single `_site/` artifact:

- `main` content lands at the root: `_site/index.html`, `_site/flash/`, `_site/ja/`, `_site/images/`, `_site/ja/images/`.
- `develop` content lands under `_site/dev/`: `_site/dev/index.html`, `_site/dev/flash/`, `_site/dev/ja/`, `_site/dev/images/`, `_site/dev/ja/images/`.
- Favicons live at the site root only (browser auto-discovery scope is the host, not the path).
- `_site/.nojekyll` MUST exist so GitHub Pages does not run Jekyll over the artifact (manual pages render markdown client-side via marked.js).

The single composed artifact ensures pushing to one branch refreshes its slice without disturbing the other slice's content. GitHub Pages allows only one site per repo, so the composition is the only mechanism that lets both slices coexist.

#### Scenario: Push to develop only
- Given current `_site` deployed at `2026-05-08T11:00Z` with main at sha A1 and develop at sha D1
- When a new commit lands on develop (sha D2)
- Then CI re-checks both branches, builds main from A1 (unchanged) and develop from D2
- And the composed `_site` retains main's content at root and updates `/dev/`
- And the deployed Pages site reflects develop's update without disturbing main's URLs

### Requirement: Concurrency lane / コンカレンシーレーン

The CI workflow SHALL define a concurrency group:

- Push events: group `pages` with `cancel-in-progress: true`. Pages deploys serialize globally (one Pages site per repo, latest run wins).
- PR events: group `pages-pr-<head_ref>` with `cancel-in-progress: true`. PR builds use a per-PR group so they don't fight the deploy lane.

This separation keeps a long-running PR build from cancelling a release deploy and vice versa.

#### Scenario: Two pushes in quick succession
- Given a deploy is in progress for develop@D1
- When a new push lands on develop@D2
- Then the in-flight run is cancelled
- And the new run for D2 starts and deploys when complete

#### Scenario: PR build does not cancel deploy
- Given a deploy is in progress for develop@D1
- When a PR opens with head ref feature/X (PR build queues)
- Then the PR build runs in `pages-pr-feature/X` and does NOT cancel the develop deploy

### Requirement: Build firmware for both branches / 両ブランチでファームウェアをビルド

The CI workflow SHALL `pio run -e m5stick-s3` for both `src/main/firmware/` and `src/develop/firmware/`. Each side's build artifacts SHALL be staged into that side's `docs/flash/firmware/` directory:

- `bootloader.bin`
- `partitions.bin`
- `boot_app0.bin` (sourced from PlatformIO's Arduino-ESP32 framework)
- `firmware.bin` renamed to `hdzap.bin`

Each side SHALL also produce a `CHECKSUMS.txt` (sha256sum) for the four binaries. CI SHALL fail if any expected artifact is missing or smaller than 1 KiB (sanity check against an empty / failed build).

`hdzap.bin` という名前は web flasher の manifest が参照する固定名。元の `firmware.bin` は PlatformIO 依存の名前なので、配信用にリネームしている。

#### Scenario: Successful build of both sides
- Given main@A1 and develop@D1
- When CI runs both `pio run` commands
- Then `src/main/docs/flash/firmware/hdzap.bin >= 1 KiB` and `src/develop/.../hdzap.bin >= 1 KiB`
- And both `CHECKSUMS.txt` files are present

#### Scenario: One side's build fails
- Given main@A1 builds successfully but develop@D1 fails
- When CI hits the verify step for develop
- Then the workflow exits non-zero with the failing artifact name
- And no Pages deploy occurs

### Requirement: Manifest version stamping / Manifest バージョンスタンプ

After each side's firmware is staged, CI SHALL update that side's `docs/flash/manifest.json` `version` field to `<branch>-<short sha>`. The stamp SHALL use the branch name (`main` or `develop`) and the short sha of the checked-out commit on that side.

The web flasher loads `manifest.json` and displays the version on the install page; the stamp identifies which build is live without ambiguity.

The two sides' manifest files are independent — main's manifest stamps to `main-<sha>` and develop's manifest stamps to `develop-<sha>`. The composed Pages site serves them at `/flash/manifest.json` and `/dev/flash/manifest.json` respectively.

#### Scenario: Manifest stamp for main
- Given `main@A1234567`
- When the CI manifest-stamp step runs
- Then `src/main/docs/flash/manifest.json` has `"version": "main-A1234567"`

### Requirement: Deploy gating / デプロイゲーティング

The deploy job SHALL run only when `github.event_name != 'pull_request'`. PR builds upload the artifact for inspection but MUST NOT push to the live Pages site. Push events on `main` and `develop` (and `workflow_dispatch`) SHALL deploy.

#### Scenario: PR build does not deploy
- Given a PR opens against `develop`
- When CI runs to completion (build artifact uploaded)
- Then the deploy job is skipped (gated on `github.event_name`)
- And the live Pages site is unchanged

### Requirement: PlatformIO cache / PlatformIO キャッシュ

CI SHALL cache `~/.platformio` and `~/.cache/pip` keyed by `runner.os` and the hash of both branches' `firmware/platformio.ini`. A cache miss falls back to `pio-<os>-` prefix. Builds that change `platformio.ini` cleanly invalidate the cache.

#### Scenario: First run after platformio.ini change
- Given main's platformio.ini was edited
- When CI runs
- Then the cache key changes (different hash)
- And the runner downloads PlatformIO toolchains fresh

### Requirement: Path filters / パスフィルタ

The workflow SHALL trigger only when the push or PR touches:

- `firmware/**`
- `docs/flash/**`
- `docs/manual/**`
- `.github/workflows/flasher.yml`

App-side iOS changes do NOT trigger this workflow (they ship via TestFlight via `release-process`).

#### Scenario: iOS-only commit
- Given a commit that only modifies `app/HDZap/Views/`
- When pushed to develop
- Then the Web Flasher workflow does NOT trigger
- And the Pages site is not redeployed
