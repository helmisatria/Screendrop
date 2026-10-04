#!/bin/bash
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
derived_data="${SCREENDROP_DERIVED_DATA_PATH:-$HOME/Library/Developer/Screendrop-Release}"
signing_identity="${SCREENDROP_SIGNING_IDENTITY:-Developer ID Application: Helmi Nugraha (WP9CSH76KL)}"
signing_team="${SCREENDROP_SIGNING_TEAM:-WP9CSH76KL}"
app="$derived_data/Build/Products/Release/Screendrop.app"

if ! security find-identity -v -p codesigning | grep -F "\"$signing_identity\"" > /dev/null; then
  echo "Signing identity not found: $signing_identity" >&2
  exit 1
fi

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
xcodebuild build -quiet \
  -project "$repo_dir/Screendrop.xcodeproj" \
  -scheme Screendrop -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$derived_data" \
  -onlyUsePackageVersionsFromResolvedFile \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$signing_identity" DEVELOPMENT_TEAM="$signing_team"

# Xcode signs nested frameworks and helpers with their own entitlements.
codesign --verify --deep --strict "$app"
requirement="$(codesign -d -r- "$app" 2>&1)"
if [[ "$requirement" != *certificate* || "$requirement" == *cdhash* ]]; then
  echo 'A certificate-based signing identity is required to keep permissions across rebuilds.' >&2
  exit 1
fi
echo "Built and signed Release: $app"
