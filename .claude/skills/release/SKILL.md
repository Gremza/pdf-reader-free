---
name: release
description: Publish a new PDF Gremza release on GitHub (Gremza/pdf-reader-free) — bump versions, build the native macOS zip and the Windows installers, commit, push, and create the release with a feature list. Use when the owner asks to publish / release / "publikoje".
---

# Releasing

Publishing is outward-facing: only do it when the owner asked for it.

1. **Clean up**: no debug leftovers (`grep -rn "DEBUG\|__state" windows/src Sources`), `swift build` has no warnings.
2. **Version** (same in both):
   - `plutil -replace CFBundleShortVersionString -string X.Y Resources/Info.plist`
   - `plutil -replace CFBundleVersion -string <n+1> Resources/Info.plist`
   - `"version": "X.Y.0"` in `windows/package.json`
3. **macOS**: `./build.sh` (also installs to /Applications), then
   `rm -f build/PDF-Reader.zip && ditto -c -k --keepParent "build/PDF Gremza.app" build/PDF-Reader.zip`
4. **Windows**: `cd windows && rm -rf dist/*.exe dist/*.blockmap && npm run dist`
   → `dist/PDF-Reader-Setup-X.Y.0-x64.exe`, `dist/PDF-Reader-Portable-X.Y.0-x64.exe`
5. **Commit & push** to `main` (do not add `.vscode/`), with the attribution trailer from the session instructions.
6. **Release**: `gh release create vX.Y --title "PDF Gremza X.Y" --notes-file notes.md build/PDF-Reader.zip windows/dist/PDF-Reader-Setup-*.exe windows/dist/PDF-Reader-Portable-*.exe`
7. **gremza.com/pdf-reader/** (Albanian page, static site in `~/Desktop/Projekte/gremza.com`, not a git repo):
   - In `pdf-reader/index.html` change the Windows links (`releases/download/vX.Y/PDF-Reader-{Setup,Portable}-X.Y.0-x64.exe`, also in the JSON-LD), "Versioni X.Y" and `softwareVersion`, and the feature cards if features changed. Bump the `<lastmod>` of the page in `sitemap.xml`.
   - Server: `ssh hpanel2`, folder `/home/gremza/web/gremza.com/public_html`, files owned by `gremza:gremza`. First compare `md5sum` with the local files (changes may have been made on the server), back up what you replace, then upload and check the live page and the download links.

## Release notes (English, like earlier releases)
- What's new, then the **full feature list** (the owner wants features shown on the web page), then per-platform install notes:
  - macOS: `PDF-Reader.zip`, move to /Applications; not notarized → right-click → Open → Open; macOS 14+, Apple Silicon.
  - Windows: Setup (adds *Open with*) or Portable; not signed → SmartScreen: More info → Run anyway.
Finally, give the owner the release URL.
