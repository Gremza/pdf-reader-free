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
| macOS release zip | `ditto -c -k --keepParent "build/PDF Gremza.app" build/PDF-Reader.zip` | upload to the GitHub release |
| Windows dev (also on Mac) | `cd windows && npm start` | the menu bar title says "Electron" in dev; that is expected |
| Windows installers | `cd windows && npm run dist` | `windows/dist/PDF-Reader-{Setup,Portable}-<ver>-x64.exe` (builds fine on a Mac) |
| Electron as a Mac app (testing only) | `cd windows && npm run dist:mac` | `windows/dist/mac-arm64/PDF Gremza.app`, ad-hoc signed |

- macOS 14+ and Swift tools 5.10 (Swift 5 language mode).
- Icons: the logo is `Resources/AppIcon.svg`; `swift Tools/make_icon.swift` makes `Resources/AppIcon.icns` / `.png` (on the macOS icon grid), `windows/src/icon.png` and `docs/icon.png` from it.
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
  - Navigation, zoom, fit modes, layouts and search.
  - **Edits:** every page operation goes through `applyEdit(pageAfter:_:)`. It snapshots `dataRepresentation()` onto `history` for undo (max 30) and gives the edit a new `version`. `isDirty` means `version != savedVersion`, and `documentChanged()` bumps `revision`, which redraws the thumbnails.
  - **Rotation:** "rotate all pages" (View menu) is a saved edit too, not just a view rotation.
  - **Protected PDFs:** encrypted, locked or restricted PDFs are refused by `ensureEditable()`.
  - **Exports** (`exportToFolder` for JPG and split, `exportWord`) read a **separate copy** of the document off the main thread through `ExportSource`: the saved file when the tab is clean, the current data when it is dirty. Edits are blocked while `exportProgress != nil` (`canEdit`).
  - Saving writes atomically. `saveAs` changes `url` and refreshes `TabsModel.shared` so the tab title updates.
  - Page numbers in the API are 1-based, like the UI.
- `WordExport.swift`: PDF text to paragraphs to `.docx`, ported from `windows/src/word.js` and `docx.js`. Lines come from `PDFSelection.selectionsByLine()`, and paragraphs are joined using the same heuristics as the JS version. It includes its own stored zip writer and CRC32.
- `ThumbnailSidebar.swift`: SwiftUI thumbnails that render lazily and re-render on `revision`. Click goes to the page, right-click opens the page menu, Delete removes the page. Dragging reorders pages, using a drag string with the `pdfreader-page:` prefix, plus a drop zone after the last page.
- `UpdateChecker.swift`: checks the latest GitHub release at launch and daily, downloads `PDF-Reader.zip`, checks the bundle id and version, and swaps the bundle in place (`replaceItemAt`); "Restart Now" reopens the app after it quits. Settings (`checkForUpdates`, `installUpdatesAutomatically`) are in `UserDefaults`; the menu items are in the app menu.
- `TopBar.swift`: the tab strip with a `»` overflow and the document controls. The "Document" menu button (`DocumentMenu`) holds the page edits, save and export. Keyboard shortcuts are on the **menu items**, not on the toolbar buttons; menu items focus the search and page fields through `PDFViewModel.focusRequest`. Unsaved tabs show `● ` before the title.
- `WindowChrome.swift`: hidden title bar and traffic-light positioning. The close button's target and action are re-pointed to ask about unsaved changes first. ⌘W with no tabs calls `performClose`, which goes through the same check.

## Windows architecture (`windows/src/`)

- `main.js`:
  - window, file IO, dialogs, writable-path allow-list, export folders, the unsaved-changes prompt on close
  - **the macOS app menu** (`updateAppMenu`, built from `menu-state` sent by the renderer; on Windows `Menu.setApplicationMenu(null)`)
  - `app.setName("PDF Gremza")`
- `preload.js`: the `window.host` bridge.
- `renderer.js`:
  - tabs, pdf.js viewer and thumbnails (drag to reorder)
  - `actions` (every command, used by buttons, shortcuts and menu actions); `syncMenu()` sends enabled/checked state to the main process
  - edits through `applyEdit`, with byte snapshots for undo
  - Full Screen Mode: `startPresentation` / `endPresentation`, `tab.setPresenting`, `presentationKeys`; the main process enters and leaves full screen (`set-presenting`)
- `updater.js`: the same update check in the main process. The installer build runs the downloaded setup with `--updated /S` when the app quits; the portable build swaps its own `.exe`. Settings are in `settings.json` under `userData`; the renderer shows them under the **Updates** button.
- `editing.js`: pdf-lib page operations and `parsePageRanges`.
- `word.js` and `docx.js`: the Word export.

## Rules

- **Feature parity:** a new feature goes into both apps, with the same English wording, menu placement and shortcut (⌘ on Mac, Ctrl on Windows). Use the `add-feature` skill, and the `parity-checker` agent to find gaps.
- Every toolbar or icon action must also be in the menu bar on macOS: File, Edit, View, Pages, Window.
- Never modify the user's files except on an explicit save. Exports always create new files or folders: "name", then "name 2", and so on.
- Keep the macOS app dependency-free. Use only system frameworks (PDFKit, AppKit, SwiftUI, UniformTypeIdentifiers).
- Match the surrounding style: short doc comments on the "why", `// MARK:` sections, no dead code.
- Before publishing, check that no debug leftovers remain (e.g. `window.__state`).

## Testing

- macOS logic: compile the sources (minus `PDFReaderApp.swift`) with a test `main.swift` that drives `PDFViewModel` on a generated PDF. Use the `test-native` skill.
- macOS UI: launch a temporary ad-hoc signed `.app` from the scratchpad (not `build.sh`, which overwrites `/Applications`), then read and click menus with AppleScript and System Events. Screenshots are not permitted on this machine.
- Never test on the owner's own PDFs in place. Copy them to the scratchpad first.
