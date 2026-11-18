#!/bin/bash
# Builds DisplayBar.app with SwiftPM and signs it.
#   SIGN_IDENTITY  codesign identity (default: ad-hoc "-")
#   BUNDLE_ID      bundle identifier (default: com.displaybar.app)
#   CONFIG         release | debug (default: release)
#   OUTPUT         output folder (default: build)
#   VERSION        marketing version (default: 1.0.0)
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=${CONFIG:-release}
OUTPUT=${OUTPUT:-build}
BUNDLE_ID=${BUNDLE_ID:-com.displaybar.app}
SIGN_IDENTITY=${SIGN_IDENTITY:--}
VERSION=${VERSION:-1.0.0}
BUILD=$(date +%Y%m%d%H%M)

# Map the checkout path to "." so the binary doesn't carry the builder's home folder.
FLAGS=(-Xswiftc -file-prefix-map -Xswiftc "$PWD=." -Xcc "-ffile-prefix-map=$PWD=.")
swift build -c "$CONFIG" "${FLAGS[@]}"
BIN_DIR=$(swift build -c "$CONFIG" "${FLAGS[@]}" --show-bin-path)

APP="$OUTPUT/DisplayBar.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/DisplayBar" "$APP/Contents/MacOS/DisplayBar"
sed -e "s/__BUNDLE_ID__/$BUNDLE_ID/" -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" \
    Resources/Info.plist > "$APP/Contents/Info.plist"
if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns "$APP/Contents/Resources/"; fi

codesign --force --options runtime --timestamp=none --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --strict "$APP"
echo "Built $APP ($(du -sh "$APP" | cut -f1), $(lipo -archs "$APP/Contents/MacOS/DisplayBar"))"
