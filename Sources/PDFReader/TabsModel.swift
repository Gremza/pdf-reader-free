import SwiftUI
import PDFKit
import UniformTypeIdentifiers

@MainActor
final class DocumentTab: Identifiable {
    let id = UUID()
    let model: PDFViewModel

    var url: URL { model.url }
    var title: String { url.lastPathComponent }

    init(url: URL, document: PDFDocument) {
        self.model = PDFViewModel(document: document, url: url)
    }
}

/// All open PDFs of the single app window, shown as tabs in the top bar.
@MainActor
final class TabsModel: ObservableObject {
    static let shared = TabsModel()

    @Published private(set) var tabs: [DocumentTab] = []
    @Published var selectedID: DocumentTab.ID?
    @Published var isFullScreen = false
    @Published var showThumbnails = true
    weak var window: NSWindow?

    var selected: DocumentTab? { tabs.first { $0.id == selectedID } }

    // MARK: Opening

    func open(_ urls: [URL]) {
        var failed: [String] = []
        for url in urls {
            if let existing = tabs.first(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) {
                selectedID = existing.id
            } else if let document = PDFDocument(url: url) {
                let tab = DocumentTab(url: url, document: document)
                tabs.append(tab)
                selectedID = tab.id
                NSDocumentController.shared.noteNewRecentDocumentURL(url)
            } else {
                failed.append(url.lastPathComponent)
            }
        }
        window?.makeKeyAndOrderFront(nil)

        if !failed.isEmpty {
            let alert = NSAlert()
            alert.messageText = "The file can't be opened"
            alert.informativeText = failed.joined(separator: "\n")
            alert.runModal()
        }
    }

    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK {
            open(panel.urls)
        }
    }

    // MARK: Tabs

    /// Asks to save unsaved changes first; does nothing when the user cancels.
    func close(_ id: DocumentTab.ID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs[index]
        if tab.model.isDirty {
            selectedID = id
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Save changes to \"\(tab.title)\"?"
            alert.informativeText = "Your changes will be lost if you don't save them."
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Don't Save")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn: guard tab.model.save() else { return }
            case .alertSecondButtonReturn: break
            default: return
            }
        }
        tabs.remove(at: index)
        if selectedID == id {
            selectedID = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id
        }
    }

    /// ⌘W closes the current tab, or the window when no tab is open.
    func closeSelected() {
        if let selectedID {
            close(selectedID)
        } else {
            window?.performClose(nil)
        }
    }

    func selectNext() { selectOffset(1) }
    func selectPrevious() { selectOffset(-1) }

    private func selectOffset(_ offset: Int) {
        guard !tabs.isEmpty else { return }
        let index = tabs.firstIndex { $0.id == selectedID } ?? 0
        selectedID = tabs[(index + offset + tabs.count) % tabs.count].id
    }

    // MARK: Window

    private var discardConfirmed = false

    /// Before the window closes or the app quits; false when the user wants to keep the changes.
    func confirmDiscardChanges() -> Bool {
        let count = tabs.filter(\.model.isDirty).count
        guard count > 0, !discardConfirmed else { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = count == 1
            ? "One document has unsaved changes"
            : "\(count) documents have unsaved changes"
        alert.informativeText = "Your changes will be lost if you close now."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Close Without Saving")
        discardConfirmed = alert.runModal() == .alertSecondButtonReturn
        return discardConfirmed
    }

    func toggleFullScreen() {
        window?.toggleFullScreen(nil)
    }
}
