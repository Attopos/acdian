#!/bin/zsh
# Build ACdian and replace the one installed copy. No backup is kept: git can rebuild any old version.
set -euo pipefail
cd "$(dirname "$0")"
if [[ -n "${ACDIAN_BUNDLE_ID:-}" ]]; then
    echo "ACDIAN_BUNDLE_ID marks a test build; not installing it." >&2
    exit 1
fi
INSTALLED="${ACDIAN_INSTALL_PATH:-/Applications/ACdian.app}"
APP="${ACDIAN_BUILD_DIR:-/private/tmp/acdian-build-$UID}/ACdian.app"
NEW="$INSTALLED:h/.ACdian-new.app"
OLD="$INSTALLED:h/.ACdian-old.app"
./build.sh

# The executable is lowercase; match the full path so test copies elsewhere keep running.
RUNNING="^$INSTALLED/Contents/MacOS/acdian"
WAS_RUNNING=0
if pgrep -f "$RUNNING" >/dev/null; then
    WAS_RUNNING=1
    osascript -e "tell application \"$INSTALLED\" to quit"
    for _ in {1..40}; do
        pgrep -f "$RUNNING" >/dev/null || break
        sleep 0.5
    done
    if pgrep -f "$RUNNING" >/dev/null; then
        echo "ACdian did not quit; nothing was installed." >&2
        exit 1
    fi
fi

# Move, not copy, so the build folder does not stay behind as another copy.
rm -rf "$NEW" "$OLD"
mv "$APP" "$NEW"
[[ -e "$INSTALLED" ]] && mv "$INSTALLED" "$OLD"
if ! mv "$NEW" "$INSTALLED"; then
    [[ -e "$OLD" ]] && mv "$OLD" "$INSTALLED"
    echo "Could not replace $INSTALLED; the previous version is still installed." >&2
    exit 1
fi
rm -rf "$OLD"
codesign --verify --strict "$INSTALLED"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$INSTALLED"
echo "Installed: $INSTALLED"
# The build folder is empty once the app has moved; the Swift module cache stays,
# as it is small and makes the next build faster.
rm -rf "$APP:h"
echo "Free disk: $(df -h /private/tmp | awk 'NR==2 {print $4}')"
if (( WAS_RUNNING )); then
    open "$INSTALLED"
fi
