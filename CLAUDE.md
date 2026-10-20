# PDF Reader Free

A free PDF viewer and page editor with two apps that must stay feature-equal:

- **macOS**: native SwiftUI + PDFKit (`Sources/PDFReader/`), no third-party dependencies. The app is about 1.4 MB. **This is the main Mac app.** The owner does not want to ship the Electron build on Mac because it is about 300 MB.
- **Windows**: Electron + pdf.js + pdf-lib (`windows/`). It also runs on a Mac with `npm start`, but only for development.

The owner speaks Albanian. **All UI text is in Albanian** (labels, menus, alerts, tooltips), with the same wording on both platforms. Code, comments and the README are in English. Answer the owner in Albanian.

## Build & run

| | Command | Output |
|---|---|---|
| macOS debug | `swift build` | `.build/debug/PDFReader` |
| macOS release + install | `./build.sh` | `build/PDF Reader.app`, **copied over `/Applications/PDF Reader.app`** |
| macOS release zip | `ditto -c -k --keepParent "build/PDF Reader.app" build/PDF-Reader.zip` | upload to the GitHub release |
| Windows dev (also on Mac) | `cd windows && npm start` | the menu bar title says "Electron" in dev; that is expected |
| Windows installers | `cd windows && npm run dist` | `windows/dist/PDF-Reader-{Setup,Portable}-<ver>-x64.exe` (builds fine on a Mac) |
| Electron as a Mac app (testing only) | `cd windows && npm run dist:mac` | `windows/dist/mac-arm64/PDF Reader.app`, ad-hoc signed |

- macOS 14+ and Swift tools 5.10 (Swift 5 language mode).
- The owner's keychain has **two identical "Apple Development" certificates**, so electron-builder signing with an identity fails as "ambiguous". The `mac` build config uses `identity: "-"` (ad-hoc) and `hardenedRuntime: false` for that reason.
- Version numbers live in `Resources/Info.plist` (`CFBundleShortVersionString`, `CFBundleVersion`) and `windows/package.json` (`version`). Keep both in step.
- Releases: GitHub `Gremza/pdf-reader-free`, published with `gh release create`. See the `release` skill.

## macOS architecture (`Sources/PDFReader/`)

- `PDFReaderApp.swift`: the single `Window` scene, File menu basics (Hap / Mbyll tab-in), tab switching, and `applicationShouldTerminate` (asks about unsaved changes).
- `MenuCommands.swift`: menu bar mirrors of every toolbar action:
  - File: save, export
  - Edit: Zhbëj / Ribëj, which replace `.undoRedo`
  - View: thumbnails, zoom, fit, layouts, rotation, pages
  - a `Faqet` menu
  - `DocumentMenuItems` observes the selected tab's model. When no PDF is open it shows the items disabled, using a placeholder model.
  - **The `.sidebar`, `.toolbar` (before) and `.importExport` placements don't show** in this window. Use `CommandGroup(replacing: .toolbar)`, `after: .toolbar` and `after: .saveItem` instead.
- `TabsModel.swift`: the open tabs (`DocumentTab` holds a `PDFViewModel`), `showThumbnails`, the close-tab prompt (Ruaj / Mos ruaj / Anulo), and `confirmDiscardChanges()` for quitting or closing the window.
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
- `TopBar.swift`: the tab strip with a `»` overflow and the document controls. The "Dokumenti" menu button (`DocumentMenu`) holds the page edits, save and export. Keyboard shortcuts are on the **menu items**, not on the toolbar buttons; ⌘F and ⌃⌘F are the exceptions. Unsaved tabs show `● ` before the title.
- `WindowChrome.swift`: hidden title bar and traffic-light positioning. The close button's target and action are re-pointed to ask about unsaved changes first. ⌘W with no tabs calls `performClose`, which goes through the same check.

## Windows architecture (`windows/src/`)

- `main.js`:
  - window, file IO, dialogs, writable-path allow-list, export folders, the unsaved-changes prompt on close
  - **the macOS app menu** (`updateAppMenu`, built from `menu-state` sent by the renderer; on Windows `Menu.setApplicationMenu(null)`)
  - `app.setName("PDF Reader")`
- `preload.js`: the `window.host` bridge.
- `renderer.js`:
  - tabs, pdf.js viewer and thumbnails (drag to reorder)
  - `actions` (every command, used by buttons, shortcuts and menu actions); `syncMenu()` sends enabled/checked state to the main process
  - edits through `applyEdit`, with byte snapshots for undo
- `editing.js`: pdf-lib page operations and `parsePageRanges`.
- `word.js` and `docx.js`: the Word export.

## Rules

- **Feature parity:** a new feature goes into both apps, with the same Albanian wording, menu placement and shortcut (⌘ on Mac, Ctrl on Windows). Use the `add-feature` skill, and the `parity-checker` agent to find gaps.
- Every toolbar or icon action must also be in the menu bar on macOS: File, Edit, View, Faqet, Window.
- Never modify the user's files except on an explicit save. Exports always create new files or folders: "name", then "name 2", and so on.
- Keep the macOS app dependency-free. Use only system frameworks (PDFKit, AppKit, SwiftUI, UniformTypeIdentifiers).
- Match the surrounding style: short doc comments on the "why", `// MARK:` sections, no dead code.
- Before publishing, check that no debug leftovers remain (e.g. `window.__state`).

## Testing

- macOS logic: compile the sources (minus `PDFReaderApp.swift`) with a test `main.swift` that drives `PDFViewModel` on a generated PDF. Use the `test-native` skill.
- macOS UI: launch a temporary ad-hoc signed `.app` from the scratchpad (not `build.sh`, which overwrites `/Applications`), then read and click menus with AppleScript and System Events. Screenshots are not permitted on this machine.
- Never test on the owner's own PDFs in place. Copy them to the scratchpad first.
