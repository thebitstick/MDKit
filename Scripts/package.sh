#!/bin/bash
# Builds MDKit.app and packages it as a zip and a DMG in build/release/, with checksums.
#
#   Scripts/package.sh
#
# The build is host-architecture only (Homebrew's libusb/keystone are single-arch), so the zip is
# arm64 on Apple Silicon and x86_64 on Intel. The app is ad-hoc signed unless SIGN_IDENTITY is set.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
ARCH=$(uname -m)
APP=$(Scripts/build-app.sh | tail -1)

DIST=build/release
rm -rf "$DIST"; mkdir -p "$DIST"
NAME="MDKit-$VERSION-$ARCH"

# Zip: no extended attributes or resource forks, so any unzip tool yields an app whose signature verifies.
ditto -c -k --keepParent --norsrc --noextattr --noqtn "$APP" "$DIST/$NAME.zip"

# DMG: the app next to an Applications shortcut.
STAGE=$(mktemp -d)
ditto --norsrc --noextattr "$APP" "$STAGE/MDKit.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "MDKit $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DIST/$NAME.dmg"
rm -rf "$STAGE"

# Prove it: unpack with the stock unzip and verify the signature.
CHECK=$(mktemp -d); unzip -q "$DIST/$NAME.zip" -d "$CHECK"
codesign --verify --deep --strict "$CHECK/MDKit.app" && echo "  signature verifies after a plain unzip"
rm -rf "$CHECK"

( cd "$DIST" && shasum -a 256 "$NAME.zip" "$NAME.dmg" > SHA256SUMS.txt )
echo "Packaged:"; ls -lh "$DIST" | sed 's/^/  /'
