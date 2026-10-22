import SwiftUI
import PDFKit

/// Menu bar versions of the top bar buttons, in the File, Edit, View and Pages menus.
struct DocumentCommands: Commands {
    @ObservedObject var tabs: TabsModel

    var body: some Commands {
        CommandGroup(after: .saveItem) {
            DocumentMenuItems(tabs: tabs) { model in
                Divider()
                Button("Save") { model.save() }
                    .keyboardShortcut("s")
                    .disabled(!model.isDirty || !model.canEdit)
                Button("Save As…") { model.saveAs() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(!model.canEdit)
                // ⌘Z stays on Edit ▸ Undo
                Button("Undo", action: model.undo)
                    .disabled(!model.canUndo)
                Divider()
                PageEditItems(model: model)
                Divider()
                Button("Extract Pages to New PDF…") { model.extractPagesPrompt() }
                    .disabled(!model.canEdit)
                Button("Split into Single Pages…", action: model.splitPages)
                    .disabled(!model.canEdit)
                Divider()
                Button("Export to Word…", action: model.exportWord)
                    .disabled(!model.canEdit)
                Button("Export as JPG…", action: model.exportJPEG)
                    .keyboardShortcut("e")
                    .disabled(!model.canEdit)
            }
        }

        CommandGroup(replacing: .undoRedo) {
            DocumentMenuItems(tabs: tabs) { model in
                Button("Undo") {
                    // Text fields (search, page number) keep their own undo
                    if let editor = NSApp.keyWindow?.firstResponder as? NSTextView {
                        editor.undoManager?.undo()
                    } else {
                        model.undo()
                    }
                }
                .keyboardShortcut("z")
            }
            .disabled(false)
            Button("Redo") {
                (NSApp.keyWindow?.firstResponder as? NSTextView)?.undoManager?.redo()
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
        }

        CommandMenu("Pages") {
            DocumentMenuItems(tabs: tabs) { model in
                PageEditItems(model: model)
            }
        }

        CommandGroup(replacing: .toolbar) {
            Button(tabs.showThumbnails ? "Hide Thumbnails" : "Show Thumbnails") {
                withAnimation { tabs.showThumbnails.toggle() }
            }
            .keyboardShortcut("s", modifiers: [.command, .control])
            .disabled(tabs.selected == nil)
            Divider()
        }

        CommandGroup(after: .toolbar) {
            DocumentMenuItems(tabs: tabs) { model in
                Button("Zoom In", action: model.zoomIn)
                    .keyboardShortcut("+")
                Button("Zoom Out", action: model.zoomOut)
                    .keyboardShortcut("-")
                Button("Actual Size", action: model.actualSize)
                    .keyboardShortcut("0")

                Divider()

                Toggle("Fit Width", isOn: Binding(get: { model.fitMode == .width }, set: { _ in model.fitWidth() }))
                    .keyboardShortcut("1")
                Toggle("Fit Page", isOn: Binding(get: { model.fitMode == .page }, set: { _ in model.fitPage() }))
                    .keyboardShortcut("2")

                Picker("Layout", selection: Binding(get: { model.layout }, set: { model.layout = $0 })) {
                    ForEach(PageLayout.allCases) { layout in
                        Text(layout.title).tag(layout)
                    }
                }
                .pickerStyle(.inline)

                Button("Rotate Left") { model.rotate(by: -90) }
                    .keyboardShortcut("l")
                Button("Rotate Right") { model.rotate(by: 90) }
                    .keyboardShortcut("r")

                Divider()

                Button("Previous Page", action: model.previousPage)
                    .keyboardShortcut(.upArrow)
                    .disabled(model.currentPage <= 1)
                Button("Next Page", action: model.nextPage)
                    .keyboardShortcut(.downArrow)
                    .disabled(model.currentPage >= model.pageCount)

                Divider()
            }
        }
    }
}

/// Edits of the current page, in both the File and the Pages menu.
private struct PageEditItems: View {
    @ObservedObject var model: PDFViewModel

    var body: some View {
        let n = model.currentPage
        Group {
            Button("Insert Blank Page After Page \(n)") { model.insertBlankPage(after: n) }
            Button("Insert Pages from PDF After Page \(n)…") {
                model.insertPDFs(after: n, message: "Choose the PDFs to insert")
            }
            Button("Merge PDFs at End…", action: model.mergePDFs)
            Divider()
            Button("Rotate Page \(n) Left") { model.rotatePage(n, by: -90) }
            Button("Rotate Page \(n) Right") { model.rotatePage(n, by: 90) }
            Divider()
            Button("Delete Page \(n)") { model.deletePage(n) }
                .disabled(model.pageCount <= 1)
        }
        .disabled(!model.canEdit)
    }
}

/// Builds menu items for the selected tab's document, shown disabled when no PDF is open.
private struct DocumentMenuItems<Content: View>: View {
    @ObservedObject var tabs: TabsModel
    @ViewBuilder let content: (PDFViewModel) -> Content

    var body: some View {
        if let model = tabs.selected?.model {
            ModelObserver(model: model, content: content)
        } else {
            ModelObserver(model: .placeholder, content: content)
                .disabled(true)
        }
    }

    /// Re-renders the items whenever the model changes (page, fit mode, layout…).
    private struct ModelObserver: View {
        @ObservedObject var model: PDFViewModel
        let content: (PDFViewModel) -> Content

        var body: some View { content(model) }
    }
}

private extension PDFViewModel {
    static let placeholder = PDFViewModel(document: PDFDocument(), url: URL(fileURLWithPath: "/"))
}
