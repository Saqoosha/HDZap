#!/usr/bin/env bash
#
# Dev-loop one-shot: regenerate the Xcode project, build the iOS+watchOS
# bundle, push iOS+watchOS to their physical devices, and optionally
# launch the iOS app. Bypasses iOS's "auto app install to paired Watch"
# queue by talking to both devices via devicectl in parallel — install
# is real-time, not "sometime over the next few hours when the watch is
# on its charger."
#
# Usage:
#   scripts/watch-deploy.sh             # build + install on both
#   scripts/watch-deploy.sh --launch    # also launch iOS app after install
#   scripts/watch-deploy.sh --no-build  # skip build, reuse prior DerivedData
#
# Requires both devices in `xcrun devicectl list devices` as
# "available (paired)" — pair the watch with this iPhone in the Watch app
# on iPhone, and trust the Mac on both devices, before running.

set -euo pipefail

LAUNCH=0
DO_BUILD=1
for arg in "$@"; do
  case "$arg" in
    --launch) LAUNCH=1 ;;
    --no-build) DO_BUILD=0 ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$REPO_ROOT/app"
PROJECT="$APP_DIR/HDZap.xcodeproj"
SCHEME=HDZap
BUNDLE_ID=sh.saqoo.HDZap

# Detect connected iPhone + Apple Watch from devicectl. The State
# column reports "available (paired)" right after a device wakes; once
# devicectl establishes a tunnel it transitions to "connected". Both
# are valid for install — match either, but skip "unavailable" so an
# older paired iPhone listed but offline doesn't get picked.
detect_device() {
  local pattern="$1"
  xcrun devicectl list devices 2>/dev/null \
    | awk -v p="$pattern" '
      (/available \(paired\)/ || /connected/) && !/unavailable/ && tolower($0) ~ tolower(p) {
        for (i = 1; i <= NF; i++) if ($i ~ /^[0-9A-F]{8}-/) { print $i; exit }
      }'
}

IPHONE_ID="$(detect_device iPhone)"
WATCH_ID="$(detect_device Watch)"

if [[ -z "$IPHONE_ID" ]]; then
  echo "error: no paired iPhone found via devicectl" >&2
  xcrun devicectl list devices >&2
  exit 1
fi
if [[ -z "$WATCH_ID" ]]; then
  echo "error: no paired Apple Watch found via devicectl" >&2
  xcrun devicectl list devices >&2
  exit 1
fi

echo "iPhone:       $IPHONE_ID"
echo "Apple Watch:  $WATCH_ID"

# Re-derive the .app path from xcodebuild settings rather than hard-
# coding DerivedData — different machines/Xcode versions hash the dir
# name differently and the only stable source is the build settings.
build_settings() {
  xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
             -destination "id=$IPHONE_ID" -configuration Debug \
             -showBuildSettings 2>/dev/null
}

if (( DO_BUILD )); then
  if [[ ! -d "$PROJECT" ]] || [[ "$APP_DIR/project.yml" -nt "$PROJECT/project.pbxproj" ]]; then
    echo "==> xcodegen generate"
    (cd "$APP_DIR" && xcodegen generate)
  fi
  echo "==> xcodebuild ($SCHEME for $IPHONE_ID)"
  xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
             -destination "id=$IPHONE_ID" -configuration Debug \
             -allowProvisioningUpdates build \
    | xcbeautify 2>/dev/null || true
  # xcbeautify above silences output if installed; re-run to surface the
  # exit code (xcodebuild | xcbeautify always exits 0 on the pipe).
  xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
             -destination "id=$IPHONE_ID" -configuration Debug \
             -allowProvisioningUpdates build >/dev/null
fi

IPHONE_APP=$(build_settings | awk -F' = ' '
  /^[[:space:]]+TARGET_BUILD_DIR/ { dir=$2 }
  /^[[:space:]]+FULL_PRODUCT_NAME/ { name=$2 }
  END { print dir "/" name }')
WATCH_APP="$IPHONE_APP/Watch/HDZapWatch.app"

if [[ ! -d "$IPHONE_APP" ]]; then
  echo "error: built iOS .app not found at $IPHONE_APP" >&2
  exit 1
fi
if [[ ! -d "$WATCH_APP" ]]; then
  echo "error: embedded watch .app not found at $WATCH_APP" >&2
  exit 1
fi

# Install on both in parallel. Watch installs are flaky on the first
# attempt — the proximity tunnel times out under load. Retry once with
# a short delay before giving up; if it still fails, fall back to
# iPhone-only install and let iOS's auto-propagation pick up the
# embedded watch app within a few minutes.
install_iphone() {
  echo "==> iPhone install"
  xcrun devicectl device install app --device "$IPHONE_ID" "$IPHONE_APP"
}

install_watch() {
  for attempt in 1 2; do
    echo "==> Watch install (attempt $attempt)"
    if xcrun devicectl device install app --device "$WATCH_ID" "$WATCH_APP"; then
      return 0
    fi
    sleep 3
  done
  echo "warning: Watch direct install failed twice; relying on iPhone-side auto-propagation" >&2
  return 0
}

install_iphone
install_watch

if (( LAUNCH )); then
  echo "==> launch on iPhone"
  xcrun devicectl device process launch --device "$IPHONE_ID" "$BUNDLE_ID"
fi

echo "==> done"
