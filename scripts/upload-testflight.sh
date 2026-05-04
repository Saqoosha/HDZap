#!/usr/bin/env bash
set -euo pipefail

# Export an .ipa from the archive and upload it to TestFlight via altool.
# Reads ASC API credentials from ASC_API_KEY_ID / ASC_API_ISSUER_ID env vars
# (defaulting to the team VCFY2GFR89 key created on 2026-05-04).

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="${ROOT_DIR}/app"
BUILD_DIR="${APP_DIR}/build"
ARCHIVE_PATH="${BUILD_DIR}/archives/HDZap.xcarchive"
EXPORT_DIR="${BUILD_DIR}/export"
EXPORT_OPTIONS="${BUILD_DIR}/ExportOptions.plist"
IPA_PATH="${EXPORT_DIR}/HDZap.ipa"

ASC_API_KEY_ID="${ASC_API_KEY_ID:-76DV838N2N}"
ASC_API_ISSUER_ID="${ASC_API_ISSUER_ID:-69a6de6e-6653-47e3-e053-5b8c7c11a4d1}"

cd "${APP_DIR}"

if [[ ! -d "${ARCHIVE_PATH}" ]]; then
  echo "Error: archive not found at ${ARCHIVE_PATH}" >&2
  echo "Run scripts/build.sh first." >&2
  exit 1
fi

if [[ ! -f "${EXPORT_OPTIONS}" ]]; then
  echo "Error: ${EXPORT_OPTIONS} missing — needed for app-store-connect export." >&2
  exit 1
fi

# altool searches a fixed list of locations for the .p8; ensure it can find the key.
P8_RUNTIME_DIR="${HOME}/.appstoreconnect/private_keys"
P8_PATH="${P8_RUNTIME_DIR}/AuthKey_${ASC_API_KEY_ID}.p8"
if [[ ! -f "${P8_PATH}" ]]; then
  if [[ -f "${HOME}/.blitz/AuthKey_${ASC_API_KEY_ID}.p8" ]]; then
    mkdir -p "${P8_RUNTIME_DIR}"
    cp "${HOME}/.blitz/AuthKey_${ASC_API_KEY_ID}.p8" "${P8_PATH}"
    chmod 600 "${P8_PATH}"
  else
    echo "Error: AuthKey_${ASC_API_KEY_ID}.p8 not found in ~/.appstoreconnect/private_keys/ or ~/.blitz/" >&2
    exit 1
  fi
fi

rm -rf "${EXPORT_DIR}"
mkdir -p "${EXPORT_DIR}"

echo "=== xcodebuild exportArchive ==="
xcodebuild -exportArchive \
  -archivePath "${ARCHIVE_PATH}" \
  -exportPath "${EXPORT_DIR}" \
  -exportOptionsPlist "${EXPORT_OPTIONS}" \
  -allowProvisioningUpdates

if [[ ! -f "${IPA_PATH}" ]]; then
  echo "Error: ipa not found at ${IPA_PATH}" >&2
  exit 1
fi

echo ""
echo "=== altool --upload-app ==="
xcrun altool --upload-app -f "${IPA_PATH}" --type ios \
  --apiKey "${ASC_API_KEY_ID}" \
  --apiIssuer "${ASC_API_ISSUER_ID}"

echo ""
echo "Uploaded: ${IPA_PATH}"
