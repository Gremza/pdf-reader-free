import SwiftUI
import PDFKit

/// Menu bar versions of the top bar buttons, in the File, Edit, View and Pages menus.
/// The shortcuts follow Adobe Acrobat Reader.
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

        CommandGroup(after: .pasteboard) {
            DocumentMenuItems(tabs: tabs) { model in
                Divider()
                Button("Search") { model.focusRequest = .search }
                    .keyboardShortcut("f")
                    .disabled(model.isPresenting)
                Button("Find Next", action: model.nextResult)
                    .keyboardShortcut("g")
                Button("Find Previous", action: model.previousResult)
                    .keyboardShortcut("g", modifiers: [.command, .shift])
            }
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
            .keyboardShortcut(.f4, modifiers: [])
            .disabled(tabs.selected == nil || tabs.isPresenting)
            Divider()
        }

        CommandGroup(after: .toolbar) {
            DocumentMenuItems(tabs: tabs) { model in
                Button("Zoom In", action: model.zoomIn)
                    .keyboardShortcut("=")
                Button("Zoom Out", action: model.zoomOut)
                    .keyboardShortcut("-")

                Divider()

                Button("Actual Size", action: model.actualSize)
                    .keyboardShortcut("1")
                Toggle("Fit Page", isOn: Binding(get: { model.fitMode == .page }, set: { _ in model.fitPage() }))
                    .keyboardShortcut("0")
                Toggle("Fit Width", isOn: Binding(get: { model.fitMode == .width }, set: { _ in model.fitWidth() }))
                    .keyboardShortcut("2")

                Picker("Layout", selection: Binding(get: { model.layout }, set: { model.layout = $0 })) {
                    ForEach(PageLayout.allCases) { layout in
                        Text(layout.title).tag(layout)
                    }
                }
                .pickerStyle(.inline)

                Button("Rotate Left") { model.rotate(by: -90) }
                    .keyboardShortcut("-", modifiers: [.command, .shift])
                Button("Rotate Right") { model.rotate(by: 90) }
                    .keyboardShortcut("=", modifiers: [.command, .shift])

                Divider()

                Button("Previous Page", action: plainKey(model.previousPage))
                    .keyboardShortcut(.leftArrow, modifiers: [])
                    .disabled(model.currentPage <= 1)
                Button("Next Page", action: plainKey(model.nextPage))
                    .keyboardShortcut(.rightArrow, modifiers: [])
                    .disabled(model.currentPage >= model.pageCount)
                Button("First Page", action: plainKey(model.firstPage))
                    .keyboardShortcut(.home, modifiers: [])
                    .disabled(model.currentPage <= 1)
                Button("Last Page", action: plainKey(model.lastPage))
                    .keyboardShortcut(.end, modifiers: [])
                    .disabled(model.currentPage >= model.pageCount)
                Button("Go to Page…") { model.focusRequest = .page }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(model.isPresenting)

                Divider()

                Toggle("Full Screen Mode", isOn: Binding(get: { tabs.isPresenting }, set: { _ in tabs.togglePresentation() }))
                    .keyboardShortcut("l")
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
            .keyboardShortcut("i", modifiers: [.command, .shift])
            Button("Merge PDFs at End…", action: model.mergePDFs)
            Divider()
            Button("Rotate Page \(n) Left") { model.rotatePage(n, by: -90) }
            Button("Rotate Page \(n) Right") { model.rotatePage(n, by: 90) }
            Divider()
            Button("Delete Page \(n)") { model.deletePage(n) }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(model.pageCount <= 1)
        }
        .disabled(!model.canEdit)
    }
}

/// Shortcuts without ⌘ (arrows, Home, End) belong to a text field or dialog while it has the keyboard.
@MainActor
private func plainKey(_ action: @escaping () -> Void) -> () -> Void {
    {
        let window = NSApp.keyWindow
        if let event = NSApp.currentEvent, event.type == .keyDown, let responder = window?.firstResponder,
           responder is NSText || window !== TabsModel.shared.window {
            responder.keyDown(with: event)
        } else {
            action()
        }
    }
}

private extension KeyEquivalent {
    static let f4 = KeyEquivalent(Character(Unicode.Scalar(NSF4FunctionKey)!))
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
