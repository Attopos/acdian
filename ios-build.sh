#!/bin/zsh
# Builds the iOS app and installs it on every connected, unlocked iPhone and
# iPad, then releases the memory and disk the build used.
#   ./ios-build.sh               build, install on the paired devices, clean up
#   ./ios-build.sh --simulator   build for the simulator instead (no install)
#   ./ios-build.sh --keep        skip the clean-up, e.g. to run UI tests on the build
#   ./ios-build.sh clean         only clean up
# The clean-up runs however the script ends: success, failure or Ctrl-C. It
# shuts down simulators, quits Simulator, and deletes the build folders, the
# generated ACdian.xcodeproj and this project's DerivedData. Simulator runtimes
# and devices, and the pages folder, are never touched.
set -euo pipefail
cd "$(dirname "$0")"
DERIVED="${ACDIAN_IOS_BUILD_DIR:-/private/tmp/acdian-ios-build-$UID}"
SIMULATOR=0 KEEP=0 ONLY_CLEAN=0
for arg in "$@"; do
    case "$arg" in
    --simulator) SIMULATOR=1 ;;
    --keep) KEEP=1 ;;
    clean) ONLY_CLEAN=1 ;;
    *) echo "Usage: ./ios-build.sh [--simulator] [--keep] | clean" >&2; exit 2 ;;
    esac
done

clean() {
    xcrun simctl shutdown all >/dev/null 2>&1 || true
    if pgrep -x Simulator >/dev/null; then osascript -e 'tell application "Simulator" to quit' >/dev/null 2>&1 || true; fi
    rm -rf "$DERIVED" /private/tmp/acdian-ios-build-*(N) /private/tmp/acdian-ios-phone-*(N) ACdian.xcodeproj ~/Library/Developer/Xcode/DerivedData/ACdian-*(N)
    echo "Cleaned up. Free disk: $(df -h /private/tmp | awk 'NR==2 {print $4}')"
}
if (( ONLY_CLEAN )); then clean; exit 0; fi
if (( KEEP )); then
    trap 'echo "Kept the build in $DERIVED; run ./ios-build.sh clean when done."' EXIT
else
    trap clean EXIT
fi

xcodegen generate --quiet
if (( SIMULATOR )); then
    # The simulator build runs unsigned, so it reads the app's local Documents folder.
    xcodebuild -quiet -project ACdian.xcodeproj -scheme ACdian -configuration Debug \
        -destination 'generic/platform=iOS Simulator' -derivedDataPath "$DERIVED" CODE_SIGNING_ALLOWED=NO build
    echo "Simulator app: $DERIVED/Build/Products/Debug-iphonesimulator/ACdian.app"
    exit 0
fi

DEVICES=(${(f)"$(xcrun devicectl list devices 2>/dev/null | awk '(/available \(paired\)/ || / connected /) && !/simulated/' | grep -oE '[0-9A-F]{8}-[0-9A-F]{16}' || true)"})
xcodebuild -quiet -project ACdian.xcodeproj -scheme ACdian -configuration Debug \
    -destination 'generic/platform=iOS' -derivedDataPath "$DERIVED" -allowProvisioningUpdates build
APP="$DERIVED/Build/Products/Debug-iphoneos/ACdian.app"
if (( ${#DEVICES} == 0 )); then
    echo "Built, but no paired iPhone or iPad is connected and unlocked, so nothing was installed."
    exit 0
fi
for device in $DEVICES; do
    xcrun devicectl device install app --device "$device" "$APP" >/dev/null
    echo "Installed on $device"
done
