#!/bin/zsh
# Archives the iOS app and uploads it to App Store Connect for TestFlight.
#   ./testflight.sh          archive, upload, clean up
#   ./testflight.sh --keep   keep the archive and build folders (for debugging)
# The App Store Connect API key is read from ~/.appstoreconnect/config:
#   KEY_ID=…  ISSUER_ID=…  KEY_PATH=~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8
# (or from ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_PATH). The key never goes in the repo.
# The build number is the upload time (yyyyMMddHHmm), so every upload is higher
# than the last. Clean-up runs however the script ends, as in ios-build.sh.
set -euo pipefail
cd "$(dirname "$0")"
WORK="/private/tmp/acdian-testflight-$UID"
KEEP=0; [[ "${1:-}" == --keep ]] && KEEP=1

clean() {
    rm -rf "$WORK" ACdian.xcodeproj ~/Library/Developer/Xcode/DerivedData/ACdian-*(N)
    echo "Cleaned up. Free disk: $(df -h /private/tmp | awk 'NR==2 {print $4}')"
}
if (( KEEP )); then trap 'echo "Kept $WORK"' EXIT; else trap clean EXIT; fi

CONFIG="$HOME/.appstoreconnect/config"
[[ -f "$CONFIG" ]] && source "$CONFIG"
KEY_ID="${ASC_KEY_ID:-${KEY_ID:-}}"; ISSUER_ID="${ASC_ISSUER_ID:-${ISSUER_ID:-}}"
KEY_PATH="${ASC_KEY_PATH:-${KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_$KEY_ID.p8}}"
if [[ -z "$KEY_ID" || -z "$ISSUER_ID" || ! -f "$KEY_PATH" ]]; then
    echo "Missing the App Store Connect API key: set KEY_ID, ISSUER_ID and KEY_PATH in $CONFIG." >&2
    exit 1
fi
AUTH=(-allowProvisioningUpdates -authenticationKeyPath "$KEY_PATH" -authenticationKeyID "$KEY_ID" -authenticationKeyIssuerID "$ISSUER_ID")
BUILD="$(date +%Y%m%d%H%M)"
mkdir -p "$WORK"

xcodegen generate --quiet
xcodebuild -quiet -project ACdian.xcodeproj -scheme ACdian -configuration Release \
    -destination 'generic/platform=iOS' -derivedDataPath "$WORK/derived" \
    -archivePath "$WORK/ACdian.xcarchive" CURRENT_PROJECT_VERSION="$BUILD" $AUTH archive

cat > "$WORK/export.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>upload</string>
  <key>signingStyle</key><string>automatic</string>
  <key>teamID</key><string>DC9UKDP974</string>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict></plist>
PLIST
xcodebuild -quiet -exportArchive -archivePath "$WORK/ACdian.xcarchive" \
    -exportOptionsPlist "$WORK/export.plist" -exportPath "$WORK/export" $AUTH
echo "Uploaded build $BUILD of version $(grep -m1 MARKETING_VERSION project.yml | grep -oE '[0-9.]+') to App Store Connect."
