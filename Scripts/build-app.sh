#!/bin/bash
# Builds "MDKit.app" into build/ (release, arm64). Ad-hoc signed unless SIGN_IDENTITY is set.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
APP="$ROOT/build/MDKit.app"

[ -x build/atracdenc ] || ./Scripts/build-atracdenc.sh
swift build -c release --product MDKit
BIN="$(swift build -c release --show-bin-path)/MDKit"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MDKit"
cp build/atracdenc "$APP/Contents/Resources/atracdenc"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Hardened runtime + ad-hoc signature so Gatekeeper accepts a locally built app after first-run approval.
SIGN="${SIGN_IDENTITY:--}"
codesign --force --options runtime --sign "$SIGN" "$APP/Contents/Resources/atracdenc"
codesign --force --options runtime --entitlements Resources/MDKit.entitlements --sign "$SIGN" "$APP"
echo "$APP"
