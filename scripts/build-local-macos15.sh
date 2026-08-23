#!/bin/zsh

set -euo pipefail

script_directory=${0:A:h}
repository_root=${script_directory:h}
derived_data_path=${SCREENDROP_DERIVED_DATA_PATH:-"${repository_root}/.deriveddata-stable"}
signing_identity=${SCREENDROP_SIGNING_IDENTITY:-"Apple Development: Helmi Nugraha (3GN9W972YM)"}
app_path="${derived_data_path}/Build/Products/Debug/Screendrop.app"

if ! security find-identity -v -p codesigning | grep -Fq "\"${signing_identity}\""; then
    print -u2 "Code-signing identity not found: ${signing_identity}"
    exit 1
fi

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    xcodebuild build \
    -project "${repository_root}/Screendrop.xcodeproj" \
    -scheme Screendrop \
    -configuration Debug \
    -destination "platform=macOS" \
    -derivedDataPath "${derived_data_path}" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO

codesign \
    --force \
    --deep \
    --options runtime \
    --timestamp=none \
    --sign "${signing_identity}" \
    --identifier com.fayazahmed.Screendrop \
    --entitlements "${repository_root}/Screendrop/Screendrop.entitlements" \
    "${app_path}"

codesign --verify --deep --strict --verbose=2 "${app_path}"
print "Built and signed: ${app_path}"
