#!/bin/zsh
# Builds MicIngest for distribution: Release archive, Developer ID signature, Apple notarization,
# stapled tickets. Result: build/MicIngest.app, a ZIP, and a signed DMG.
#
#   NOTARY_PROFILE=<notarytool keychain profile> scripts/release.sh
#
# Without NOTARY_PROFILE the app is built and signed but not notarized.
# Set the profile explicitly to notarize a distribution build.
# One-time setup of a profile: xcrun notarytool store-credentials <name> --apple-id … --team-id …
set -euo pipefail
cd "$(dirname "$0")/.."

out="$PWD/build"
if pgrep -f "$out/MicIngest.app/Contents/MacOS/MicIngest" >/dev/null; then
  echo "build/MicIngest.app is running. Quit it first; it is replaced by this build." >&2
  exit 1
fi
work="$(mktemp -d)"            # archive and intermediates stay out of the project folder
trap 'rm -rf "${work:?}"' EXIT
mkdir -p "$out"

echo "==> Archive (Release, arm64)"
if ! xcodebuild -project MicIngest.xcodeproj -scheme MicIngest -configuration Release \
  -destination 'generic/platform=macOS' ARCHS=arm64 \
  -derivedDataPath "$work/DerivedData" -archivePath "$work/MicIngest.xcarchive" archive \
  > "$work/archive.log" 2>&1; then
  cat "$work/archive.log" >&2
  exit 1
fi
grep -E "warning:|ARCHIVE" "$work/archive.log" || true
[[ -d "$work/MicIngest.xcarchive" ]] || { echo "Archive failed." >&2; exit 1; }

echo "==> Export with Developer ID"
cat > "$work/ExportOptions.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>developer-id</string>
	<key>signingStyle</key>
	<string>automatic</string>
</dict>
</plist>
PLIST
if ! xcodebuild -exportArchive -archivePath "$work/MicIngest.xcarchive" \
  -exportOptionsPlist "$work/ExportOptions.plist" -exportPath "$work/export" \
  > "$work/export.log" 2>&1; then
  cat "$work/export.log" >&2
  exit 1
fi
grep -E "warning:|EXPORT" "$work/export.log" || true
app="$work/export/MicIngest.app"
[[ -d "$app" ]] || { echo "Export failed." >&2; exit 1; }

echo "==> Verify signature"
signing_identity=$(codesign -dv --verbose=2 "$app" 2>&1 | sed -n 's/^Authority=\(Developer ID Application:.*\)$/\1/p')
[[ -n "$signing_identity" ]] || { echo "Developer ID Application signature is required." >&2; exit 1; }
codesign --verify --deep --strict --verbose=2 "$app"
codesign -dv --verbose=2 "$app" 2>&1 | grep -E "Authority=Developer ID|TeamIdentifier|flags|Timestamp"

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  echo "==> Notarize"
  ditto -c -k --keepParent "$app" "$work/upload.zip"
  xcrun notarytool submit "$work/upload.zip" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json \
    | tee "$work/notary.json"
  id=$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' "$work/notary.json")
  notary_status=$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["status"])' "$work/notary.json")
  if [[ "$notary_status" != "Accepted" ]]; then
    xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" >&2
    echo "Notarization was not accepted ($notary_status)." >&2
    exit 1
  fi

  echo "==> Staple and check with Gatekeeper"
  xcrun stapler staple "$app"
  xcrun stapler validate "$app"
  spctl --assess --type execute --verbose=2 "$app"
else
  echo "==> NOTARY_PROFILE is not set: skipping notarization. This build will be blocked by Gatekeeper on other Macs."
fi

version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$app/Contents/Info.plist")
rm -rf "${out:?}/MicIngest.app"
ditto "$app" "$out/MicIngest.app"
ditto -c -k --keepParent "$out/MicIngest.app" "$out/MicIngest-$version.zip"
echo "==> Create signed DMG"
staging="$work/dmg-root"
mkdir -p "$staging"
ditto "$app" "$staging/MicIngest.app"
ln -s /Applications "$staging/Applications"
cp LICENSE THIRD_PARTY_NOTICES.md "$staging/"
dmg="$work/MicIngest-$version.dmg"
hdiutil create -volname MicIngest -srcfolder "$staging" -format UDZO -ov "$dmg"
codesign --force --timestamp --sign "$signing_identity" "$dmg"
codesign --verify --strict --verbose=2 "$dmg"
hdiutil verify "$dmg"

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  echo "==> Notarize DMG"
  xcrun notarytool submit "$dmg" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json \
    | tee "$work/dmg-notary.json"
  dmg_id=$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' "$work/dmg-notary.json")
  dmg_notary_status=$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["status"])' "$work/dmg-notary.json")
  if [[ "$dmg_notary_status" != "Accepted" ]]; then
    xcrun notarytool log "$dmg_id" --keychain-profile "$NOTARY_PROFILE" >&2
    echo "DMG notarization was not accepted ($dmg_notary_status)." >&2
    exit 1
  fi
  xcrun stapler staple "$dmg"
  xcrun stapler validate "$dmg"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"
fi

ditto "$dmg" "$out/MicIngest-$version.dmg"
echo "==> Done: $out/MicIngest.app, $out/MicIngest-$version.zip, $out/MicIngest-$version.dmg"
