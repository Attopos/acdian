#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$PWD"
APP="${ACDIAN_BUILD_DIR:-/private/tmp/acdian-build-$UID}/ACdian.app"
MODULE_CACHE="${ACDIAN_MODULE_CACHE:-/private/tmp/acdian-swift-cache-$UID}"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$MODULE_CACHE"
xcrun swiftc -swift-version 5 -O -module-cache-path "$MODULE_CACHE" -target arm64-apple-macos14.0 -framework SwiftUI -framework AppKit -framework WebKit -framework PDFKit -framework UniformTypeIdentifiers Sources/*.swift -o "$APP/Contents/MacOS/acdian"
cp -R Resources/. "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>acdian</string>
<key>CFBundleIdentifier</key><string>com.acdian.reader</string>
<key>CFBundleName</key><string>ACdian</string>
<key>CFBundleDisplayName</key><string>ACdian</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.3.3</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key><array><string>en</string><string>es</string><string>zh-Hans</string></array>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>NSDesktopFolderUsageDescription</key><string>ACdian accesses your existing local pages and saves your edits.</string>
<key>NSDocumentsFolderUsageDescription</key><string>ACdian accesses your existing local pages and saves your edits.</string>
</dict></plist>
PLIST
if [[ -n "${ACDIAN_BUNDLE_ID:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $ACDIAN_BUNDLE_ID" "$APP/Contents/Info.plist"
fi
xattr -cr "$APP"
codesign --force --deep --sign - "$APP"
echo "Built: $APP"
python3 package.py "$APP" "${ACDIAN_OUTPUT_DIR:-$ROOT/dist}"
