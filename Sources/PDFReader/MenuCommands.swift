import SwiftUI
import PDFKit

/// Menu bar versions of the top bar buttons, in the File and View menus.
struct DocumentCommands: Commands {
    @ObservedObject var tabs: TabsModel

    var body: some Commands {
        CommandGroup(after: .saveItem) {
            DocumentMenuItems(tabs: tabs) { model in
                Divider()
                Button("Ruaj") { model.save() }
                    .keyboardShortcut("s")
                    .disabled(!model.isDirty || !model.canEdit)
                Button("Ruaj si…") { model.saveAs() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(!model.canEdit)
                Divider()
                Button("Nxirr faqet në PDF të ri…") { model.extractPagesPrompt() }
                    .disabled(!model.canEdit)
                Button("Ndaj në faqe të veçanta…", action: model.splitPages)
                    .disabled(!model.canEdit)
                Divider()
                Button("Eksporto në Word…", action: model.exportWord)
                    .disabled(!model.canEdit)
                Button("Eksporto si JPG…", action: model.exportJPEG)
                    .keyboardShortcut("e")
                    .disabled(!model.canEdit)
            }
        }

        CommandGroup(replacing: .undoRedo) {
            DocumentMenuItems(tabs: tabs) { model in
                Button("Zhbëj") {
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
            Button("Ribëj") {
                (NSApp.keyWindow?.firstResponder as? NSTextView)?.undoManager?.redo()
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
        }

        CommandMenu("Faqet") {
            DocumentMenuItems(tabs: tabs) { model in
                let n = model.currentPage
                Group {
                    Button("Shto faqe bosh pas faqes \(n)") { model.insertBlankPage(after: n) }
                    Button("Shto faqe nga PDF pas faqes \(n)…") {
                        model.insertPDFs(after: n, message: "Zgjidh PDF-të që do të shtohen")
                    }
                    Button("Bashko PDF në fund…", action: model.mergePDFs)
                    Divider()
                    Button("Rrotullo faqen \(n) majtas") { model.rotatePage(n, by: -90) }
                    Button("Rrotullo faqen \(n) djathtas") { model.rotatePage(n, by: 90) }
                    Divider()
                    Button("Fshi faqen \(n)") { model.deletePage(n) }
                        .disabled(model.pageCount <= 1)
                }
                .disabled(!model.canEdit)
            }
        }

        CommandGroup(replacing: .toolbar) {
            Button(tabs.showThumbnails ? "Fshih miniaturat" : "Shfaq miniaturat") {
                withAnimation { tabs.showThumbnails.toggle() }
            }
            .keyboardShortcut("s", modifiers: [.command, .control])
            .disabled(tabs.selected == nil)
            Divider()
        }

        CommandGroup(after: .toolbar) {
            DocumentMenuItems(tabs: tabs) { model in
                Button("Zmadho", action: model.zoomIn)
                    .keyboardShortcut("+")
                Button("Zvogëlo", action: model.zoomOut)
                    .keyboardShortcut("-")
                Button("Madhësia reale", action: model.actualSize)
                    .keyboardShortcut("0")

                Divider()

                Toggle("Gjerësia e plotë", isOn: Binding(get: { model.fitMode == .width }, set: { _ in model.fitWidth() }))
                    .keyboardShortcut("1")
                Toggle("Faqja e plotë", isOn: Binding(get: { model.fitMode == .page }, set: { _ in model.fitPage() }))
                    .keyboardShortcut("2")

                Picker("Pamja", selection: Binding(get: { model.layout }, set: { model.layout = $0 })) {
                    ForEach(PageLayout.allCases) { layout in
                        Text(layout.title).tag(layout)
                    }
                }
                .pickerStyle(.inline)

                Button("Rrotullo majtas") { model.rotate(by: -90) }
                    .keyboardShortcut("l")
                Button("Rrotullo djathtas") { model.rotate(by: 90) }
                    .keyboardShortcut("r")

                Divider()

                Button("Faqja e mëparshme", action: model.previousPage)
                    .keyboardShortcut(.upArrow)
                    .disabled(model.currentPage <= 1)
                Button("Faqja tjetër", action: model.nextPage)
                    .keyboardShortcut(.downArrow)
                    .disabled(model.currentPage >= model.pageCount)

                Divider()
            }
        }
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
