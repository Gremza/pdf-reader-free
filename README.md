<p align="center">
  <img src="Resources/AppIcon.png" width="160" alt="PDF Gremza icon">
</p>

<h1 align="center">PDF Gremza</h1>

<p align="center">
  A simple, fast and free PDF viewer for macOS and Windows.
</p>

<p align="center">
  <a href="https://gremza.github.io/pdf-reader-free/"><b>Website & downloads</b></a> ·
  <a href="../../releases/latest">Latest release</a>
</p>

---

## Features

- **Tabs in the top bar** — open many PDFs side by side, drag a tab left or right to change the order; tabs that don't fit go into a `»` overflow menu
- **Page thumbnails** sidebar — drag to reorder pages, right-click for page actions, `Delete` removes a page
- **Zoom**: zoom in/out, fit width, fit whole page, actual size (100%)
- **Layouts**: single page, continuous, two pages, two pages continuous
- **Fade Between Pages** — page turns cross-fade from one page to the next; on by default, turn it off in the View menu or the Document button
- **Rotate** pages left / right
- **Full Screen Mode** — only the page, on black, without bars or borders; turn pages like a presentation with the arrow keys, `Space`, `Page Up` / `Page Down` or a click (right-click goes back); `Esc` exits
- **Search** text inside the document
- **New PDF** — make a new PDF from PDFs and images (JPG, PNG and more), one after the other in the order of their names; save it with Save
- **Edit pages**: delete, rotate, insert blank pages, insert PDFs or images (each image becomes a page), add them at the end, with undo
- **Add Image to Page** — put a picture, logo or signature on a page: drag it into place, drag a corner to resize it, then *Place Image*
- **Save / Save As** — changes are only written when you save; unsaved tabs show `●` and ask before closing
- **Extract pages** (e.g. `1-3, 5`) into a new PDF, or **split** every page into its own PDF
- **Reduce File Size** — saves a smaller copy whose images are stored again as JPEG at high, medium or low quality (200, 144 or 96 dpi); the original stays unchanged
- **Recognize Text** (OCR) — makes scanned pages searchable: the text found on each page is added as an invisible layer over it, so it can be searched and copied; pages that already have text are skipped. Also in the right-click menu of a page. It works offline, with Apple's Vision on macOS and [Tesseract](https://github.com/naptha/tesseract.js) (English and Albanian) on Windows
- **Export to Word** (`.docx`) — the text of the PDF, with paragraphs, bold/italic and font sizes
- **Export to JPG** — saves every page as an image (`1.jpg`, `2.jpg`, …) in a new folder named after the PDF
- **Take a Snapshot** (Edit menu or right-click on a page) — drag over part of a page to save it as a JPG at 300 dpi; it is also copied to the clipboard, like in Acrobat. `Esc` cancels
- **Print** — the system print dialog with printer, pages, copies, paper size and orientation; prints unsaved edits too, and turns pages of the other orientation to fill the sheet
- **Updates** — checks GitHub for a new version at launch and once a day; installs it automatically or asks first (*Check for Updates…*, *Check for Updates Automatically*, *Install Updates Automatically* in the app menu on macOS and the **Updates** button on Windows)
- **Keyboard shortcuts like Adobe Acrobat Reader**, shown next to the menu items
- On macOS every action is also in the menu bar (File, Edit, View, Pages)
- Open via `⌘O`, drag & drop, the Dock icon, or Finder's *Open With*
- No tracking, no accounts; the only network access is the update check (it can be turned off)

The macOS app is native (SwiftUI + PDFKit); the Windows app is built with Electron and [pdf.js](https://mozilla.github.io/pdf.js/) and has the same features.

## Keyboard shortcuts

The same as in Adobe Acrobat Reader.

| Action | macOS | Windows |
|---|---|---|
| Open PDF(s) | `⌘O` | `Ctrl+O` |
| Close tab | `⌘W` | `Ctrl+W` |
| Next / previous tab | `⌘⇧]` / `⌘⇧[` | `Ctrl+Tab` / `Ctrl+Shift+Tab` |
| Next / previous page | `→` / `←` or `↓` / `↑` (or `Page Down` / `Page Up`, e.g. from a presentation remote) | `→` / `←` or `↓` / `↑` (or `Page Down` / `Page Up`, `Ctrl+Page Down` / `Ctrl+Page Up`) |
| First / last page | `Home` / `End` | `Home` / `End` |
| Go to page | `⌘⇧N` | `Ctrl+Shift+N` |
| Zoom in / out | `⌘=` / `⌘−` | `Ctrl+=` / `Ctrl+−` (or `Ctrl` + mouse wheel) |
| Actual size | `⌘1` | `Ctrl+1` |
| Fit page / fit width | `⌘0` / `⌘2` | `Ctrl+0` / `Ctrl+2` |
| Rotate left / right | `⌘⇧−` / `⌘⇧=` | `Ctrl+Shift+−` / `Ctrl+Shift+=` |
| Full Screen Mode | `⌘L` | `Ctrl+L` (or `F11`) |
| Show / hide thumbnails | `F4` | `F4` |
| Search | `⌘F` | `Ctrl+F` |
| Find next / previous | `⌘G` / `⌘⇧G` | `Ctrl+G` / `Ctrl+Shift+G` (or `F3` / `Shift+F3`) |
| New PDF | `⌘N` | `Ctrl+N` |
| Insert PDFs or images | `⌘⇧I` | `Ctrl+Shift+I` |
| Delete page | `⌘⇧D` | `Ctrl+Shift+D` |
| Export pages to JPG | `⌘E` | `Ctrl+E` |
| Print | `⌘P` | `Ctrl+P` |
| Save / Save As | `⌘S` / `⌘⇧S` | `Ctrl+S` / `Ctrl+Shift+S` |
| Undo | `⌘Z` | `Ctrl+Z` |

In Full Screen Mode: `→` `↓` `Space` `Page Down` `Enter` or a click for the next page, `←` `↑` `Shift+Space` `Page Up` `Backspace` or a right-click for the previous one, `Home` / `End` for the first / last page, `Esc` to exit.

## Install

### macOS

Grab `PDF-Reader.zip` from the [latest release](../../releases/latest), unzip it and move **PDF Gremza.app** to `/Applications`.

The app is signed and notarized by Apple, so it opens normally (the first time macOS only asks to confirm opening an app downloaded from the internet).

### Windows

Grab `PDF-Reader-Setup-<version>-x64.exe` from the [latest release](../../releases/latest) and run it (or use `PDF-Reader-Portable-<version>-x64.exe`, which runs without installing). The installer registers PDF Gremza under *Open with* for `.pdf` files.

The app is not code-signed, so Windows SmartScreen may warn the first time: click **More info** → **Run anyway**.

### Build from source (macOS)

Requires macOS 14+ and Xcode 15+ (or the Swift toolchain).

```sh
git clone https://github.com/Gremza/pdf-reader-free.git
cd pdf-reader-free
./build.sh
```

`build.sh` compiles a release build, creates `build/PDF Gremza.app` and copies it to `/Applications`.

The logo is `Resources/AppIcon.svg`. After changing it, regenerate the macOS, Windows and website icons with `swift Tools/make_icon.swift`

### Build from source (Windows)

Requires Node.js 20+. Works on Windows, macOS or Linux.

```sh
cd windows
npm install
npm start            # run in development
npm run dist         # build the x64 installer + portable exe into windows/dist/
npm run dist:arm64   # same for Windows on ARM
```

## Project structure

```
Sources/PDFReader/
  PDFReaderApp.swift   App entry, file opening, quit confirmation
  MenuCommands.swift   File / Edit / View / Pages menu bar items
  TabsModel.swift      Open documents / tabs, unsaved-changes prompts
  TopBar.swift         Tab strip with overflow + toolbar controls
  ContentView.swift    Window layout, empty state, drag & drop
  PDFViewModel.swift   Navigation, zoom, layouts, search, page edits, undo, save, export
  PageImages.swift     Images as pages, New PDF, Add Image to Page
  ThumbnailSidebar.swift  Thumbnails: reorder by drag, page context menu
  WordExport.swift     PDF text → paragraphs → .docx
  PDFKitViews.swift    PDFView wrapper; the page's right-click menu
  Snapshot.swift       Take a Snapshot: drag over part of a page, save it as JPG
  WindowChrome.swift   Hidden title bar, traffic light positioning
Resources/             Info.plist, app icon
Tools/make_icon.swift  Makes every app icon from Resources/AppIcon.svg

windows/src/
  main.js              Electron main process: window, file opening, single instance
  preload.js           Bridge between the window and the main process
  index.html           Top bar, empty state
  renderer.js          Tabs, navigation, zoom, layouts, rotation, search, thumbnails
  editing.js           Page edits with pdf-lib, New PDF
  images.js            Images as pages and over a page (JPEG / PNG kept as they are)
  reduce.js            Reduce File Size: images recompressed as JPEG
  ocr.js               Recognize Text with Tesseract (models in tessdata/)
  snapshot.js          Take a Snapshot: drag over part of a page, save it as JPG
  icons/               Menu item icons
  styles.css           Light / dark theme
```

## Contributing

Issues and pull requests are welcome.

## License

[MIT](LICENSE) © 2026 Marsel Preci
