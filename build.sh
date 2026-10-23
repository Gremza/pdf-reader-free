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
codesign --force --sign - "$APP"
# Install to /Applications so it opens from Finder/Launchpad
rm -rf "/Applications/PDF Gremza.app"
# The app was called "PDF Reader" before 1.4
rm -rf "/Applications/PDF Reader.app"
cp -R "$APP" /Applications/
echo "U ndërtua dhe u instalua: /Applications/PDF Gremza.app"
