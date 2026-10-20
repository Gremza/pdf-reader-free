---
name: add-feature
description: Add or change a feature in PDF Reader Free so the native macOS app and the Windows (Electron) app stay equal — where each piece goes, Albanian wording, menus, shortcuts, tests. Use for any new command, edit, export or UI control.
---

# Adding a feature to both apps

Read `CLAUDE.md` first. A feature is done only when it exists in **both** apps with the **same Albanian text**.

## macOS (`Sources/PDFReader/`)
1. Logic in `PDFViewModel.swift`. Page edits go through `applyEdit(pageAfter:) { doc in … }` so undo, dirty state, thumbnails and search refresh for free; throw `EditError` for user-facing failures. Long work reads a copy via `exportSource()` off the main thread and reports `exportProgress`.
2. UI: a toolbar button or entry in `DocumentMenu` (`TopBar.swift`); page-level actions also in the thumbnail context menu (`ThumbnailSidebar.swift`).
3. **Menu bar** (`MenuCommands.swift`): every action, with its shortcut on the menu item (not on the toolbar button). Wrap in `DocumentMenuItems(tabs:) { model in … }` and disable with `!model.canEdit` where it edits/exports.
4. No third-party packages.

## Windows (`windows/src/`)
1. pdf-lib operation in `editing.js` (bytes in → bytes out), wired through `tab.applyEdit(...)` in `renderer.js`.
2. Add to `actions`, the `shortcuts` table (Ctrl+…), the document popup (`showDocumentMenu`) / page menu as fitting.
3. macOS dev menu: add an `item(...)` in `updateAppMenu()` (`main.js`) and any needed state to `syncMenu()`.
4. New file IO goes through an `ipcMain.handle` in `main.js` with path checks (`writablePaths`, `exportFolders`) and a `preload.js` bridge entry.

## Then
- Update the README feature list and shortcut table.
- Test the macOS side with the `test-native` skill; run `npm start` in `windows/` and exercise the feature.
- Optionally run the `parity-checker` and `albanian-ui-reviewer` agents.
