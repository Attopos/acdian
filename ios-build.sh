#!/bin/zsh
# Generates the Xcode project and builds the iOS app for a simulator, and for a
# paired iPhone or iPad when one is connected. No argument builds both.
#   ./ios-build.sh [simulator|device]
set -euo pipefail
cd "$(dirname "$0")"
WHAT="${1:-all}"
DERIVED="${ACDIAN_IOS_BUILD_DIR:-/private/tmp/acdian-ios-build-$UID}"
xcodegen generate --quiet

if [[ "$WHAT" != device ]]; then
    # The simulator build runs unsigned, so it reads the app's local Documents folder.
    xcodebuild -quiet -project ACdian.xcodeproj -scheme ACdian -configuration Debug \
        -destination 'generic/platform=iOS Simulator' -derivedDataPath "$DERIVED" \
        CODE_SIGNING_ALLOWED=NO build
    echo "Simulator app: $DERIVED/Build/Products/Debug-iphonesimulator/ACdian.app"
fi

if [[ "$WHAT" != simulator ]]; then
    DEVICE="$(xcrun devicectl list devices 2>/dev/null | awk '/available \(paired\)/ && !/simulated/' | grep -oE '[0-9A-F]{8}-[0-9A-F]{16}' | head -1 || true)"
    if [[ -z "$DEVICE" ]]; then
        echo "No paired iPhone or iPad; skipped the device build."
    else
        xcodebuild -quiet -project ACdian.xcodeproj -scheme ACdian -configuration Debug \
            -destination "id=$DEVICE" -derivedDataPath "$DERIVED" -allowProvisioningUpdates build
        echo "Device app: $DERIVED/Build/Products/Debug-iphoneos/ACdian.app"
        echo "Device: $DEVICE"
    fi
fi
