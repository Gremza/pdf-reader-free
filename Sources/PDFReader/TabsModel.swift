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
    @Published var selectedID: DocumentTab.ID? {
        didSet { if isPresenting { presentSelected() } }
    }
    @Published var isFullScreen = false
    /// Full Screen Mode: only the page, without the top bar and thumbnails.
    @Published private(set) var isPresenting = false
    @Published var showThumbnails = true
    weak var window: NSWindow?

    var selected: DocumentTab? { tabs.first { $0.id == selectedID } }

    init() {
        installPageKeys()
    }

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

    /// Dragging a tab onto another one puts it in that tab's place.
    func moveTab(_ id: DocumentTab.ID, to target: DocumentTab.ID) {
        guard id != target, let from = tabs.firstIndex(where: { $0.id == id }),
              let to = tabs.firstIndex(where: { $0.id == target }) else { return }
        tabs.insert(tabs.remove(at: from), at: to)
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

    // MARK: Page Down / Page Up

    /// Presentation remotes send Page Down / Page Up, so these keys turn pages outside
    /// Full Screen Mode too, even while the page or search field has the keyboard.
    private func installPageKeys() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handlePageKey(event) ?? false }
            return handled ? nil : event
        }
    }

    private func handlePageKey(_ event: NSEvent) -> Bool {
        guard !isPresenting, event.window === window, let model = selected?.model,
              event.modifierFlags.isDisjoint(with: [.command, .control, .option]) else { return false }
        switch event.specialKey {
        case .pageDown?: model.nextPage()
        case .pageUp?: model.previousPage()
        default: return false
        }
        return true
    }

    // MARK: Full Screen Mode

    private weak var presented: PDFViewModel?
    /// Whether Full Screen Mode put the window into full screen, so leaving it restores the window.
    private var presentationEnteredFullScreen = false
    private var presentationMonitor: Any?

    func togglePresentation() {
        isPresenting ? endPresentation() : startPresentation()
    }

    func startPresentation() {
        guard !isPresenting, selected != nil, let window else { return }
        isPresenting = true
        presentSelected()
        presentationEnteredFullScreen = !window.styleMask.contains(.fullScreen)
        if presentationEnteredFullScreen { window.toggleFullScreen(nil) }
        presentationMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handlePresentationEvent(event) ?? false }
            return handled ? nil : event
        }
        NSCursor.setHiddenUntilMouseMoves(true)
    }

    func endPresentation() {
        guard isPresenting else { return }
        isPresenting = false
        presented?.setPresenting(false)
        presented = nil
        if let presentationMonitor { NSEvent.removeMonitor(presentationMonitor) }
        presentationMonitor = nil
        if presentationEnteredFullScreen, let window, window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        }
        presentationEnteredFullScreen = false
    }

    /// Moves Full Screen Mode along when another tab is selected; ends it when the last tab closes.
    private func presentSelected() {
        guard let model = selected?.model else { return endPresentation() }
        if presented !== model { presented?.setPresenting(false) }
        presented = model
        model.setPresenting(true)
    }

    /// Keys and clicks turn the pages like a presentation; shortcuts with ⌘ still reach the menu bar.
    /// Returns whether the event was used.
    private func handlePresentationEvent(_ event: NSEvent) -> Bool {
        guard isPresenting, event.window === window, let model = presented else { return false }
        switch event.type {
        case .leftMouseDown:
            guard !model.isLink(at: event.locationInWindow) else { return false }
            model.nextPage()
        case .rightMouseDown:
            model.previousPage()
        default:
            guard event.modifierFlags.isDisjoint(with: [.command, .control, .option]) else { return false }
            let shift = event.modifierFlags.contains(.shift)
            switch (event.specialKey, event.charactersIgnoringModifiers) {
            case (.rightArrow?, _), (.downArrow?, _), (.pageDown?, _), (.carriageReturn?, _), (.enter?, _):
                model.nextPage()
            case (.leftArrow?, _), (.upArrow?, _), (.pageUp?, _), (.delete?, _):
                model.previousPage()
            case (.home?, _): model.firstPage()
            case (.end?, _): model.lastPage()
            case (_, " "?): shift ? model.previousPage() : model.nextPage()
            case (_, "\u{1b}"?): endPresentation()
            default: return false
            }
        }
        NSCursor.setHiddenUntilMouseMoves(true)
        return true
    }
}
