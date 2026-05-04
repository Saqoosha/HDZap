#!/usr/bin/env bash
set -euo pipefail

# Build & archive the iOS app for App Store distribution.
# Output: app/build/archives/HDZap.xcarchive

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="${ROOT_DIR}/app"
BUILD_DIR="${APP_DIR}/build"
ARCHIVE_PATH="${BUILD_DIR}/archives/HDZap.xcarchive"

cd "${APP_DIR}"

mkdir -p "${BUILD_DIR}/archives"

echo "=== xcodegen generate ==="
xcodegen generate

echo "=== xcodebuild archive ==="
xcodebuild \
  -project HDZap.xcodeproj \
  -scheme HDZap \
  -destination 'generic/platform=iOS' \
  -configuration Release \
  -archivePath "${ARCHIVE_PATH}" \
  -allowProvisioningUpdates \
  archive

echo ""
echo "Archived: ${ARCHIVE_PATH}"
