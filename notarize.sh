#!/bin/zsh
# Notarizes build/PDF Gremza.app (run ./build.sh first) and makes build/PDF-Reader.zip for the release.
# Uses the "gremza-notary" keychain profile (xcrun notarytool store-credentials).
set -e
cd "$(dirname "$0")"

APP="build/PDF Gremza.app"
ZIP="build/PDF-Reader.zip"
codesign --verify --strict "$APP"
codesign -dvv "$APP" 2>&1 | grep -q "Authority=Developer ID Application" || { echo "Not signed with Developer ID"; exit 1; }

# Apple checks the zip; the ticket is then stapled to the app so it opens offline too
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "gremza-notary" --wait
xcrun stapler staple "$APP"

# The release zip must contain the stapled app
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
spctl --assess --type execute -vv "$APP"
echo "Notarized: $ZIP"
