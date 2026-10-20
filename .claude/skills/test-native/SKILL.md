---
name: test-native
description: Test the native macOS app (Sources/PDFReader) — logic tests with a PDFKit harness on a generated PDF, and UI checks of menus, dialogs and thumbnails via AppleScript/System Events. Use after changing PDFViewModel, WordExport, TabsModel, MenuCommands or ThumbnailSidebar.
---

# Testing the native macOS app

Never test on the owner's PDFs in place, and never use `build.sh` for testing (it overwrites `/Applications/PDF Reader.app`). Work in the session scratchpad (`$S` below).

## 1. Logic harness (fast, no UI)

Compile every source except `PDFReaderApp.swift` (it holds `@main`) together with `scripts/harness_main.swift`, which generates a 4-page PDF and drives `PDFViewModel` directly (delete, move, blank page, rotate, undo, save + reopen, `parsePageRanges`, Word extraction + `.docx`).

```sh
mkdir -p $S/harness && cd "<repo>/Sources/PDFReader"
for f in *.swift; do [ $f != PDFReaderApp.swift ] && cp $f $S/harness/; done
cp "<repo>/.claude/skills/test-native/scripts/harness_main.swift" $S/harness/main.swift
cd $S/harness && swiftc -parse-as-library -o harness *.swift && ./harness $S/harness 2>/dev/null
textutil -convert txt -stdout $S/harness/test.docx | head   # the .docx opens
```

Every line should start with `OK`. Add a `check(...)` for each new model operation. Avoid panels/alerts in the harness (`insertPDFs`, `saveAs`, `extractPagesPrompt` open dialogs) — test their non-UI parts instead. Use named fonts (Helvetica) in generated PDFs; system UI fonts spam CoreText warnings.

## 2. UI checks in the real app

```sh
swift build
APP=$S/PDFTest.app; rm -rf $APP; mkdir -p $APP/Contents/MacOS
cp .build/debug/PDFReader $APP/Contents/MacOS/; cp Resources/Info.plist $APP/Contents/
codesign --force --sign - $APP; cp some.pdf $S/ui.pdf; open -a $APP $S/ui.pdf
P='tell application "System Events" to tell (first process whose name is "PDFReader")'
osascript -e "$P to get {name, enabled} of menu items of menu 1 of menu bar item \"Faqet\" of menu bar 1"
osascript -e "$P to click menu item \"Fshi faqen 1\" of menu 1 of menu bar item \"Faqet\" of menu bar 1"
osascript -e "$P to get value of attribute \"AXMenuItemMarkChar\" of menu items of menu 1 of menu bar item \"View\" of menu bar 1"
```

- Alerts appear as `window 1`: read `value of static texts`, click `button "Anulo"`.
- Thumbnails: `UI elements of UI element 1 of scroll area 1 of group 1 of window 1` (position/size per page; portrait vs landscape sizes reveal order after a drag).
- Right-click / drag: `swiftc -o $S/mouse scripts/mouse.swift`, then `$S/mouse right X Y` or `$S/mouse drag X1 Y1 X2 Y2`. Context menus are read via `menus of UI element N of …`.
- `screencapture` is not permitted on this machine — verify through accessibility instead, and tell the owner what could not be checked visually.
- Quit with ⌘Q → "Mbyll pa ruajtur", then delete `$S/PDFTest.app`.
