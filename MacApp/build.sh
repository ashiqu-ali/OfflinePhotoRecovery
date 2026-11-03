#!/bin/bash
# Builds "build/Offline Photo Finder.app": compiles the Swift code, bundles libimobiledevice inside
# the app, and signs it on this Mac with the no-network sandbox entitlements.
#
# Needs Xcode (or its command-line tools) and, one time while online: brew install libimobiledevice
# After that, building and running work with the internet switched off.
set -euo pipefail
cd "$(dirname "$0")"

APP="${OUT_DIR:-build}/Offline Photo Finder.app"

swift build -c release --product OfflinePhotoFinder
BIN_DIR="$(swift build -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN_DIR/OfflinePhotoFinder" "$APP/Contents/MacOS/OfflinePhotoFinder"
cp Resources/Info.plist "$APP/Contents/Info.plist"

Scripts/bundle-libimobiledevice.sh "$APP"

# "-" signs locally (no Apple account). The entitlements file is what turns on the sandbox.
codesign --force --sign - --entitlements Resources/OfflinePhotoFinder.entitlements "$APP"
codesign --verify --strict "$APP"

echo
echo "Built: $APP"
echo "Signed entitlements (no com.apple.security.network.* keys means no network access):"
codesign -d --entitlements - "$APP" 2>/dev/null
