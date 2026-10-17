import SwiftUI
import PDFKit
import UniformTypeIdentifiers

final class DocumentTab: Identifiable {
    let id = UUID()
    let url: URL
    let model: PDFViewModel

    var title: String { url.lastPathComponent }

    @MainActor
    init(url: URL, document: PDFDocument) {
        self.url = url
        self.model = PDFViewModel(document: document)
    }
}

/// All open PDFs of the single app window, shown as tabs in the top bar.
@MainActor
final class TabsModel: ObservableObject {
    static let shared = TabsModel()

    @Published private(set) var tabs: [DocumentTab] = []
    @Published var selectedID: DocumentTab.ID?
    @Published var isFullScreen = false
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
            alert.messageText = "Skedari nuk mund të hapet"
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

    func close(_ id: DocumentTab.ID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
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

    func toggleFullScreen() {
        window?.toggleFullScreen(nil)
    }
}
