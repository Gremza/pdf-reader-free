<p align="center">
  <img src="Resources/AppIcon.png" width="160" alt="PDF Reader icon">
</p>

<h1 align="center">PDF Reader Free</h1>

<p align="center">
  A simple, fast and free PDF viewer for macOS and Windows.<br>
  Një lexues PDF i thjeshtë, i shpejtë dhe falas për macOS dhe Windows.
</p>

---

## Features

- **Tabs in the top bar** — open many PDFs side by side; tabs that don't fit go into a `»` overflow menu
- **Page thumbnails** sidebar
- **Zoom**: zoom in/out, fit width, fit whole page, actual size (100%)
- **Layouts**: single page, continuous, two pages, two pages continuous
- **Rotate** pages left / right
- **Full screen**
- **Search** text inside the document
- Open via `⌘O`, drag & drop, the Dock icon, or Finder's *Open With*
- Read-only — never modifies your files
- No tracking, no accounts, no network access

The macOS app is native (SwiftUI + PDFKit); the Windows app is built with Electron and [pdf.js](https://mozilla.github.io/pdf.js/) and has the same features.

## Keyboard shortcuts

| Action | macOS | Windows |
|---|---|---|
| Open PDF(s) | `⌘O` | `Ctrl+O` |
| Close tab | `⌘W` | `Ctrl+W` |
| Next / previous tab | `⌘⇧]` / `⌘⇧[` | `Ctrl+Tab` / `Ctrl+Shift+Tab` |
| Next / previous page | `⌘↓` / `⌘↑` | `Ctrl+↓` / `Ctrl+↑` |
| Zoom in / out | `⌘+` / `⌘−` | `Ctrl++` / `Ctrl+−` (or `Ctrl` + mouse wheel) |
| Fit width / fit page | `⌘1` / `⌘2` | `Ctrl+1` / `Ctrl+2` |
| Actual size | `⌘0` | `Ctrl+0` |
| Rotate left / right | `⌘L` / `⌘R` | `Ctrl+L` / `Ctrl+R` |
| Full screen | `⌃⌘F` | `F11` |
| Search | `⌘F` | `Ctrl+F` (`Enter` / `Shift+Enter` for next / previous) |

## Install

### macOS

Grab `PDF-Reader.zip` from the [latest release](../../releases/latest), unzip it and move **PDF Reader.app** to `/Applications`.

The app is not notarized by Apple, so the first time macOS will block it. Right-click the app → **Open** → **Open** (or allow it in *System Settings → Privacy & Security*). After that it opens normally.

### Windows

Grab `PDF-Reader-Setup-<version>-x64.exe` from the [latest release](../../releases/latest) and run it (or use `PDF-Reader-Portable-<version>-x64.exe`, which runs without installing). The installer registers PDF Reader under *Open with* for `.pdf` files.

The app is not code-signed, so Windows SmartScreen may warn the first time: click **More info** → **Run anyway**.

### Build from source (macOS)

Requires macOS 14+ and Xcode 15+ (or the Swift toolchain).

```sh
git clone https://github.com/Gremza/pdf-reader-free.git
cd pdf-reader-free
./build.sh
```

`build.sh` compiles a release build, creates `build/PDF Reader.app` and copies it to `/Applications`.

To regenerate the app icon after editing it: `swift Tools/make_icon.swift`

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
  PDFReaderApp.swift   App entry, menu commands, file opening
  TabsModel.swift      Open documents / tabs
  TopBar.swift         Tab strip with overflow + toolbar controls
  ContentView.swift    Window layout, empty state, drag & drop
  PDFViewModel.swift   Navigation, zoom, fit modes, layouts, rotation, search
  PDFKitViews.swift    PDFView / thumbnail wrappers
  WindowChrome.swift   Hidden title bar, traffic light positioning
Resources/             Info.plist, app icon
Tools/make_icon.swift  Draws the app icon

windows/src/
  main.js              Electron main process: window, file opening, single instance
  preload.js           Bridge between the window and the main process
  index.html           Top bar, empty state
  renderer.js          Tabs, navigation, zoom, layouts, rotation, search, thumbnails
  styles.css           Light / dark theme
```

## Contributing

Issues and pull requests are welcome.

## License

[MIT](LICENSE) © 2026 Marsel Preci
