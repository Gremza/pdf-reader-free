# PDF Gremza

A free PDF viewer and page editor with two apps that must stay feature-equal:

- **macOS**: native SwiftUI + PDFKit (`Sources/PDFReader/`), no third-party dependencies. The app is about 1.4 MB. **This is the main Mac app.** The owner does not want to ship the Electron build on Mac because it is about 300 MB.
- **Windows**: Electron + pdf.js + pdf-lib (`windows/`). It also runs on a Mac with `npm start`, but only for development.

**All UI text is in English** (labels, menus, alerts, tooltips), with the same wording on both platforms; so are the code, comments, README and website. The owner speaks Albanian: answer the owner in Albanian.

## Build & run

| | Command | Output |
|---|---|---|
| macOS debug | `swift build` | `.build/debug/PDFReader` |
| macOS release + install | `./build.sh` | `build/PDF Gremza.app`, **copied over `/Applications/PDF Gremza.app`** |
| macOS release zip | `./notarize.sh` (after `./build.sh`) | `build/PDF-Reader.zip`, notarized by Apple; upload to the GitHub release |
| Windows dev (also on Mac) | `cd windows && npm start` | the menu bar title says "Electron" in dev; that is expected |
| Windows installers | `cd windows && npm run dist` | `windows/dist/PDF-Reader-{Setup,Portable}-<ver>-x64.exe` (builds fine on a Mac) |
| Electron as a Mac app (testing only) | `cd windows && npm run dist:mac` | `windows/dist/mac-arm64/PDF Gremza.app`, ad-hoc signed |

- macOS 14+ and Swift tools 5.10 (Swift 5 language mode).
- Icons: the logo is `Resources/AppIcon.svg`; `swift Tools/make_icon.swift` makes `Resources/AppIcon.icns` / `.png` (on the macOS icon grid), `windows/src/icon.png` and `docs/icon.png` from it.
- macOS signing: `build.sh` signs with **"Developer ID Application: marsel preci (NH46K275BX)"** (picked by hash, hardened runtime), and `notarize.sh` notarizes with the `gremza-notary` keychain profile (Apple ID with an app-specific password). The updater only checks bundle id and version, so ad-hoc 1.4 updates to signed builds fine.
- The owner's keychain has **two identical "Apple Development" certificates**, so electron-builder signing with an identity fails as "ambiguous". The `mac` build config uses `identity: "-"` (ad-hoc) and `hardenedRuntime: false` for that reason.
- Version numbers live in `Resources/Info.plist` (`CFBundleShortVersionString`, `CFBundleVersion`) and `windows/package.json` (`version`). Keep both in step.
- Releases: GitHub `Gremza/pdf-reader-free`, published with `gh release create`. See the `release` skill. **The update check depends on the asset names** (`PDF-Reader.zip`, `PDF-Reader-{Setup,Portable}-<ver>-x64.exe`) and on the tag (`v1.3`) matching the app versions. The app was renamed from "PDF Reader" to "PDF Gremza" after 1.3; the asset names keep the old name so that installed 1.3 apps still find their update. The macOS update recognizes the app by bundle id, not by name.
- The main web page is **https://gremza.com/pdf-reader/** (Albanian, part of the gremza.com static site); the release skill says how to update it.
- Website: `docs/index.html` on GitHub Pages (https://gremza.github.io/pdf-reader-free/), served from `main` /docs. The download buttons pick their files from the latest release through the GitHub API, so a new release needs no page edit unless the features change. Keep its feature list in step with the README.

## macOS architecture (`Sources/PDFReader/`)

- `PDFReaderApp.swift`: the single `Window` scene, File menu basics (Open / Close Tab), tab switching, and `applicationShouldTerminate` (asks about unsaved changes).
- `MenuCommands.swift`: menu bar mirrors of every toolbar action:
  - File: everything in the "Document" button (save, undo, page edits, export); the page edits are shared with the Pages menu (`PageEditItems`)
  - Edit: Undo / Redo, which replace `.undoRedo`, then Search, Find Next / Previous (`after: .pasteboard`)
  - View: thumbnails, zoom, fit, layouts, rotation, pages, Full Screen Mode
  - **Shortcuts follow Adobe Acrobat Reader** (README table). Keys without ⌘ (←/→, Home, End) go through `plainKey`, which hands them back to a text field or dialog that has the keyboard.
  - a `Pages` menu
  - `DocumentMenuItems` observes the selected tab's model. When no PDF is open it shows the items disabled, using a placeholder model.
  - **The `.sidebar`, `.toolbar` (before) and `.importExport` placements don't show** in this window. Use `CommandGroup(replacing: .toolbar)`, `after: .toolbar` and `after: .saveItem` instead.
- `TabsModel.swift`: the open tabs (`DocumentTab` holds a `PDFViewModel`), `showThumbnails`, the close-tab prompt (Save / Don't Save / Cancel), and `confirmDiscardChanges()` for quitting or closing the window.
  - **Full Screen Mode** (`isPresenting`, ⌘L): hides the top bar and thumbnails, puts the window into full screen (and back, unless it already was), and turns pages with keys and clicks through a local event monitor; `Esc` or leaving full screen ends it. The page itself is set up by `PDFViewModel.setPresenting` (single page, fitted, black, no page breaks or scroll bars; layout and zoom restored afterwards).
- `PDFViewModel.swift`: one per tab. It owns the `PDFView` and handles:
  - Navigation, zoom, fit modes, layouts and search. Page turns go through `turnPage`, which adds a `CATransition` fade to the PDFView's layer when "Fade Between Pages" is on (`fadeKey` in UserDefaults, on by default, toggled by `FadeToggle`); `showPage` moves without fading, e.g. after an edit.
  - **Edits:** every page operation goes through `applyEdit(pageAfter:_:)`. It snapshots `dataRepresentation()` onto `history` for undo (max 30) and gives the edit a new `version`. `isDirty` means `version != savedVersion`, and `documentChanged()` bumps `revision`, which redraws the thumbnails.
  - **Rotation:** "rotate all pages" (View menu) is a saved edit too, not just a view rotation.
  - **Protected PDFs:** encrypted, locked or restricted PDFs are refused by `ensureEditable()`.
  - **Exports** (`exportToFolder` for JPG and split, `exportWord`) read a **separate copy** of the document off the main thread through `ExportSource`: the saved file when the tab is clean, the current data when it is dirty. Edits are blocked while `exportProgress != nil` (`canEdit`).
  - **Printing** (`printDocument`, ⌘P): `PDFDocument.printOperation` with scale-down-to-fit and auto-rotate, shown as a sheet with the full system print panel. It prints the document as it is now, unsaved edits included; PDFs that forbid printing are refused.
  - Saving writes atomically. `saveAs` changes `url` and refreshes `TabsModel.shared` so the tab title updates.
  - Page numbers in the API are 1-based, like the UI.
  - **Reduce File Size** (`reduceFileSize`): the system Quartz filter "Reduce File Size" with our own quality presets, applied through the `QuartzFilter` write option of `dataRepresentation(options:)` (undocumented; Preview uses it). It recompresses images by their drawn resolution and keeps links, outline and text. The copy is only offered when it is smaller.
  - **Recognize Text** (`recognizeText`, OCR): Vision (`VNRecognizeTextRequest`) reads each page without text, drawn upright at 300 DPI. Vision has no Albanian, so it uses `ocrLanguages` (tr/fr/de/en) **without language correction**, which keeps ë and ç. Vision misses small text on a whole page, so each page is read in 5×2 overlapping tiles (lines cut by a tile's side are joined with the next tile's piece by their shared text, `joined`), then in full-width rows, then whole; Cyrillic look-alike letters and junk after numbers are cleaned up (`cleaned`). Each such page is drawn again (`drawPDFPage`, images stay as they are) into a new PDF with the lines in invisible text mode, and replaces the old page through `applyEdit` (rotation and annotations move over). It runs off the main thread with a Cancel button (`ExportProgress.canCancel`, `progressTask`).
- `PageImages.swift`: images for pages.
  - `PageImage` reads an image with its EXIF orientation (`orientationTransform`, the same matrices as `images.js`) and draws it upright into the unit square; a JPEG goes into the PDF as it is. `uprightTransform` maps that square onto a rect in a page's user space, turned back against the page's rotation.
  - **New PDF…** (⌘N, `TabsModel.showNewPDFPanel`): the chosen PDFs and images, sorted by name, in a tab with `isNew` (unsaved from the start; `save()` goes to `saveAs()`). `insertFiles` is shared with "Insert PDFs or Images After Page n…" and "Add PDFs or Images at End…"; each image becomes an A4 page turned like the image.
  - **Add Image to Page n…**: an `ImagePlacementView` (an NSView over the PDF view, following its page through scroll/zoom/page notifications) is moved and resized with the mouse while `placingImage` blocks edits (`canEdit`); `ImagePlacementBar` in `ContentView` has Cancel (Esc) / Place Image (Return). `placeImage` draws the page again (`drawnPage`, from a saved copy) with the image over it and swaps it in through `applyEdit` and `replacePage`.
- `Snapshot.swift`: **Take a Snapshot** (Edit menu and the page's right-click menu, camera icon). `takeSnapshot` lays a `SnapshotOverlay` over the `PDFView` (crosshair, drag kept within one page, scroll passes through); the region is rendered at 300 DPI by `jpegData(for:region:scale:)` from a copy of the page, copied to the clipboard and offered in a save panel. Edits wait while it is active (`isTakingSnapshot` is part of `canEdit`); Esc or the bar's Cancel ends it. Also `contextMenuItems()`, which `DocumentPDFView` (`PDFKitViews.swift`, the tab's `PDFView` subclass) puts above PDFKit's own right-click items: Take a Snapshot and Recognize Text.
- `WordExport.swift`: PDF text to paragraphs to `.docx`, ported from `windows/src/word.js` and `docx.js`. Lines come from `PDFSelection.selectionsByLine()`, and paragraphs are joined using the same heuristics as the JS version. It includes its own stored zip writer and CRC32.
- `ThumbnailSidebar.swift`: SwiftUI thumbnails that render lazily and re-render on `revision`. Click goes to the page, right-click opens the page menu, Delete removes the page. Dragging reorders pages, using a drag string with the `pdfreader-page:` prefix, plus a drop zone after the last page.
- `UpdateChecker.swift`: checks the latest GitHub release at launch and daily, downloads `PDF-Reader.zip`, checks the bundle id and version, and swaps the bundle in place (`replaceItemAt`); "Restart Now" reopens the app after it quits. Settings (`checkForUpdates`, `installUpdatesAutomatically`) are in `UserDefaults`; the menu items are in the app menu.
- `TopBar.swift`: the tab strip with a `»` overflow and the document controls. The "Document" menu button (`DocumentMenu`) holds save, layout and rotation, the page edits and export; there are no separate Layout, Actual Size or JPG buttons. Keyboard shortcuts are on the **menu items**, not on the toolbar buttons; menu items focus the search and page fields through `PDFViewModel.focusRequest`. Unsaved tabs show `● ` before the title.
- `WindowChrome.swift`: hidden title bar and traffic-light positioning. The close button's target and action are re-pointed to ask about unsaved changes first. ⌘W with no tabs calls `performClose`, which goes through the same check.

## Windows architecture (`windows/src/`)

- `main.js`:
  - window, file IO, dialogs, writable-path allow-list, export folders, the unsaved-changes prompt on close
  - **the menu bar**: `menuTemplate()`, built from `menu-state` sent by the renderer. On macOS it is the app menu (`updateAppMenu`). On Windows there is no application menu (the title bar is hidden): the renderer draws `#menubar` (File, Edit, View, Pages, Window, Help; `Alt`+letter) as the window's top row beside the native caption buttons (`titleBarOverlay` height `MENU_BAR_HEIGHT`), and `show-menu-bar-menu` pops up the same submenu below the clicked button. Its keys are only shown; the renderer's `shortcuts` handle them. Windows has Exit in File and About / the update settings in Help
  - `app.setName("PDF Gremza")`
- `preload.js`: the `window.host` bridge.
- `renderer.js`:
  - tabs, pdf.js viewer and thumbnails (drag to reorder)
  - `actions` (every command, used by buttons, shortcuts and menu actions); `syncMenu()` sends enabled/checked state to the main process
  - edits through `applyEdit`, with byte snapshots for undo
  - Printing (`tab.print()`, Ctrl+P): every page is rendered at 200 DPI (`intent: "print"`) into `#print-container`, which the print CSS shows alone, one page per sheet, with `@page` sized like the first page; pages of the other orientation are turned counterclockwise. The main process opens the system dialog with `webContents.print` (`print` IPC) and the container is removed when the job is sent or cancelled.
  - Fade Between Pages: `turnPage` copies the visible page canvases onto a `.page-fade` layer and fades it out once the new page is drawn; the setting is in `localStorage`
  - Full Screen Mode: `startPresentation` / `endPresentation`, `tab.setPresenting`, `presentationKeys`; the main process enters and leaves full screen (`set-presenting`)
- `updater.js`: the same update check in the main process. The installer build runs the downloaded setup with `--updated /S` when the app quits; the portable build swaps its own `.exe`. Settings are in `settings.json` under `userData`; the renderer shows them under the **Updates** button.
- `editing.js`: pdf-lib page operations and `parsePageRanges`.
- `reduce.js`: Reduce File Size. It decodes 8-bit gray/RGB images (JPEG, or Flate with PNG predictors) through `createImageBitmap`, scales them down to the dpi for a full page and stores them as JPEG with an `OffscreenCanvas`, only when that is smaller. CMYK, indexed, JBIG2 and JPEG 2000 images stay as they are. The presets (`REDUCED_QUALITIES`) match the macOS ones.
- `ocr.js`: Recognize Text with tesseract.js, fully offline: the worker, the SIMD LSTM core (`corePath`) and the gzipped `tessdata_fast` models (`src/tessdata/`, `sqi+eng`) load from `app://`. Lines from the TSV output are drawn with pdf-lib as invisible Helvetica text (WinAnsi only). The other tesseract core builds are left out by the `files` patterns in `package.json`; together this adds about 4.5 MB to the installers.
- `images.js` and New PDF / Add Image to Page: `readImage` takes JPEG (size and EXIF orientation from its markers) and PNG as they are and draws other images into a PNG; `insertImagePage` / `drawImageOnPage` draw it with raw operators through a matrix. `createPDF` and `pageEdits.insertFiles` (in `editing.js`) mix PDFs and images. In `renderer.js`, `tab.addImage` puts a `.image-placement` element (in fractions of the page) into the pdf.js page div, put back on `pagerender`/`pagerendered` because pdf.js empties the div; `placeImage` maps it to the page through the page view's viewport. A new tab has `path: null` and `savedBytes: null`.
- `snapshot.js`: Take a Snapshot. `startSnapshot` lays a crosshair layer over the viewer; the part of the page is rendered with a pdf.js viewport offset at 300 DPI. The main process (`save-snapshot`) copies it to the clipboard (Electron's W3C-style `clipboard.write` with a PNG `ClipboardItem`) and saves it. The page's right-click menu is `showViewMenu` in `renderer.js`; native menu icons come from `src/icons/` (`menuIcon` in `main.js`, a template image on macOS).
- `word.js` and `docx.js`: the Word export.

## Rules

- **Feature parity:** a new feature goes into both apps, with the same English wording, menu placement and shortcut (⌘ on Mac, Ctrl on Windows). Use the `add-feature` skill, and the `parity-checker` agent to find gaps.
- Every toolbar or icon action must also be in the menu bar: File, Edit, View, Pages, Window (the native one on macOS; the same `menuTemplate()` on Windows).
- Never modify the user's files except on an explicit save. Exports always create new files or folders: "name", then "name 2", and so on.
- Keep the macOS app dependency-free. Use only system frameworks (PDFKit, Quartz, AppKit, SwiftUI, UniformTypeIdentifiers, Vision).
- Match the surrounding style: short doc comments on the "why", `// MARK:` sections, no dead code.
- Before publishing, check that no debug leftovers remain (e.g. `window.__state`).

## Testing

- macOS logic: compile the sources (minus `PDFReaderApp.swift`) with a test `main.swift` that drives `PDFViewModel` on a generated PDF. Use the `test-native` skill.
- macOS UI: launch a temporary ad-hoc signed `.app` from the scratchpad (not `build.sh`, which overwrites `/Applications`), then read and click menus with AppleScript and System Events. Screenshots are not permitted on this machine.
- Never test on the owner's own PDFs in place. Copy them to the scratchpad first.
