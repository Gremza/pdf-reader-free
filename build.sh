#!/bin/zsh
# Builds "PDF Gremza.app" in ./build
set -e
cd "$(dirname "$0")"

swift build -c release
APP="build/PDF Gremza.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/PDFReader "$APP/Contents/MacOS/PDFReader"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Sign with the Developer ID (by hash, so duplicate certificates can't make it ambiguous),
# with hardened runtime and a timestamp, as notarization requires. Ad-hoc if it is missing.
IDENTITY=$(security find-identity -v -p codesigning | awk '/Developer ID Application: .*\(NH46K275BX\)/ { print $2; exit }')
if [[ -n "$IDENTITY" ]]; then
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
else
  echo "Developer ID not found, signing ad-hoc (not for release)"
  codesign --force --sign - "$APP"
fi
# Install to /Applications so it opens from Finder/Launchpad
rm -rf "/Applications/PDF Gremza.app"
# The app was called "PDF Reader" before 1.4
rm -rf "/Applications/PDF Reader.app"
cp -R "$APP" /Applications/
echo "U ndërtua dhe u instalua: /Applications/PDF Gremza.app"
