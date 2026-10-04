#!/bin/bash
set -euo pipefail
umask 077

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
release_tag="${1:?Usage: package-release.sh v1.2.3 OUTPUT_DIRECTORY}"
output_dir="${2:?Provide a separate output directory}"
: "${APPLE_TEAM_ID:?Set APPLE_TEAM_ID}"
: "${DEVELOPER_ID_APPLICATION:?Set DEVELOPER_ID_APPLICATION to your signing identity}"
case "$DEVELOPER_ID_APPLICATION" in
  'Developer ID Application: '*) ;;
  *) echo 'A Developer ID Application identity is required.' >&2; exit 1 ;;
esac
python3 "$repo_dir/scripts/validate-release.py" "$release_tag"
if ! security find-identity -v -p codesigning | grep -F "\"$DEVELOPER_ID_APPLICATION\"" > /dev/null; then
  echo 'The Developer ID Application certificate and private key are not available.' >&2
  exit 1
fi

notary_arguments=()
if [[ -n "${SCREENDROP_NOTARY_PROFILE:-}" ]]; then
  notary_arguments=(--keychain-profile "$SCREENDROP_NOTARY_PROFILE")
else
  : "${APP_STORE_CONNECT_KEY_FILE:?Set APP_STORE_CONNECT_KEY_FILE or SCREENDROP_NOTARY_PROFILE}"
  : "${APP_STORE_CONNECT_KEY_ID:?Set APP_STORE_CONNECT_KEY_ID}"
  : "${APP_STORE_CONNECT_ISSUER_ID:?Set APP_STORE_CONNECT_ISSUER_ID}"
  notary_arguments=(--key "$APP_STORE_CONNECT_KEY_FILE" --key-id "$APP_STORE_CONNECT_KEY_ID" --issuer "$APP_STORE_CONNECT_ISSUER_ID")
fi
sparkle_arguments=(--account "${SPARKLE_KEYCHAIN_ACCOUNT:-helmisatria.Screendrop}")
if [[ -n "${SPARKLE_PRIVATE_KEY_FILE:-}" ]]; then
  sparkle_arguments=(--ed-key-file "$SPARKLE_PRIVATE_KEY_FILE")
fi

mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
derived_data="$output_dir/DerivedData"
archive="$output_dir/Screendrop.xcarchive"
export_options="$output_dir/ExportOptions.plist"
exported_app="$output_dir/export/Screendrop.app"
updates="$output_dir/updates"
mkdir -p "$updates"
export SCREENDROP_EXPORT_OPTIONS="$export_options"
python3 - <<'PY'
import os, plistlib
from pathlib import Path
Path(os.environ['SCREENDROP_EXPORT_OPTIONS']).write_bytes(plistlib.dumps({
    'method': 'developer-id', 'signingStyle': 'manual',
    'teamID': os.environ['APPLE_TEAM_ID'],
    'signingCertificate': os.environ['DEVELOPER_ID_APPLICATION'],
    'manageAppVersionAndBuildNumber': False,
}))
PY

xcodebuild archive -quiet \
  -project "$repo_dir/Screendrop.xcodeproj" -scheme Screendrop \
  -configuration Release -destination 'generic/platform=macOS' \
  -archivePath "$archive" -derivedDataPath "$derived_data" \
  -onlyUsePackageVersionsFromResolvedFile \
  ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$DEVELOPER_ID_APPLICATION" DEVELOPMENT_TEAM="$APPLE_TEAM_ID"
xcodebuild -exportArchive -archivePath "$archive" \
  -exportPath "$output_dir/export" -exportOptionsPlist "$export_options"

codesign --verify --deep --strict "$exported_app"
codesign -d --verbose=2 "$exported_app" 2>&1 | grep -F "Authority=$DEVELOPER_ID_APPLICATION" > /dev/null
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$exported_app/Contents/Info.plist")" = "${release_tag#v}"
lipo "$exported_app/Contents/MacOS/Screendrop" -verify_arch arm64 x86_64
test ! -e "$exported_app/Contents/MacOS/Screendrop.debug.dylib"

ditto -c -k --sequesterRsrc --keepParent "$exported_app" "$output_dir/notarization.zip"
xcrun notarytool submit "$output_dir/notarization.zip" "${notary_arguments[@]}" \
  --wait --timeout 20m --output-format json > "$output_dir/notarization.json"
python3 - "$output_dir/notarization.json" <<'PY'
import json, sys
from pathlib import Path
result=json.loads(Path(sys.argv[1]).read_text())
if result.get('status') != 'Accepted':
    raise SystemExit('Notarization was not accepted; no release package will be published.')
print('Notarization accepted.')
PY
xcrun stapler staple "$exported_app"
xcrun stapler validate "$exported_app"
spctl --assess --type execute --verbose=2 "$exported_app"

package_name="Screendrop-${release_tag#v}.zip"
ditto -c -k --sequesterRsrc --keepParent "$exported_app" "$updates/$package_name"
if [[ -n "${SCREENDROP_RELEASE_NOTES_FILE:-}" ]]; then
  cp "$SCREENDROP_RELEASE_NOTES_FILE" "$updates/${package_name%.zip}.md"
fi
sparkle_bin="$derived_data/SourcePackages/artifacts/sparkle/Sparkle/bin"
"$sparkle_bin/generate_appcast" "${sparkle_arguments[@]}" \
  --download-url-prefix "https://github.com/helmisatria/Screendrop/releases/download/$release_tag/" \
  --link 'https://github.com/helmisatria/Screendrop' \
  --maximum-deltas 0 --embed-release-notes "$updates"
signature="$("$sparkle_bin/sign_update" "${sparkle_arguments[@]}" -p "$updates/$package_name")"
"$sparkle_bin/sign_update" "${sparkle_arguments[@]}" --verify "$updates/$package_name" "$signature"
xcrun swift "$repo_dir/scripts/verify-update-signature.swift" \
  "$updates/$package_name" "$exported_app/Contents/Info.plist" "$updates/appcast.xml"
echo "Verified signed release package and appcast: $updates"
