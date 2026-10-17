<p align="center">
  <img src="Resources/AppIcon.png" width="160" alt="PDF Reader icon">
</p>

<h1 align="center">PDF Reader Free</h1>

<p align="center">
  A simple, fast and free PDF viewer for macOS — built with SwiftUI and PDFKit.<br>
  Një lexues PDF i thjeshtë, i shpejtë dhe falas për macOS.
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

## Keyboard shortcuts

| Action | Shortcut |
|---|---|
| Open PDF(s) | `⌘O` |
| Close tab | `⌘W` |
| Next / previous tab | `⌘⇧]` / `⌘⇧[` |
| Next / previous page | `⌘↓` / `⌘↑` |
| Zoom in / out | `⌘+` / `⌘−` |
| Fit width / fit page | `⌘1` / `⌘2` |
| Actual size | `⌘0` |
| Rotate left / right | `⌘L` / `⌘R` |
| Full screen | `⌃⌘F` |
| Search | `⌘F` |

## Install

### Download

Grab `PDF-Reader.zip` from the [latest release](../../releases/latest), unzip it and move **PDF Reader.app** to `/Applications`.

The app is not notarized by Apple, so the first time macOS will block it. Right-click the app → **Open** → **Open** (or allow it in *System Settings → Privacy & Security*). After that it opens normally.

### Build from source

Requires macOS 14+ and Xcode 15+ (or the Swift toolchain).

```sh
git clone https://github.com/Gremza/pdf-reader-free.git
cd pdf-reader-free
./build.sh
```

`build.sh` compiles a release build, creates `build/PDF Reader.app` and copies it to `/Applications`.

To regenerate the app icon after editing it: `swift Tools/make_icon.swift`

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
```

## Contributing

Issues and pull requests are welcome.

## License

[MIT](LICENSE) © 2026 Marsel Preci
