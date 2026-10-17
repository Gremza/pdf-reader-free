import SwiftUI
import PDFKit

enum FitMode {
    case width, page, custom
}

enum PageLayout: String, CaseIterable, Identifiable {
    case single, continuous, twoUp, twoUpContinuous
    var id: Self { self }

    var title: String {
        switch self {
        case .single: "Një faqe"
        case .continuous: "E vazhduar"
        case .twoUp: "Dy faqe"
        case .twoUpContinuous: "Dy faqe, e vazhduar"
        }
    }

    var systemImage: String {
        switch self {
        case .single: "doc"
        case .continuous: "doc.text"
        case .twoUp: "book"
        case .twoUpContinuous: "book.pages"
        }
    }

    var displayMode: PDFDisplayMode {
        switch self {
        case .single: .singlePage
        case .continuous: .singlePageContinuous
        case .twoUp: .twoUp
        case .twoUpContinuous: .twoUpContinuous
        }
    }
}

/// Owns the PDFView so toolbar actions can drive it.
@MainActor
final class PDFViewModel: ObservableObject {
    let pdfView = PDFView()

    @Published var currentPage = 1
    @Published var pageCount = 0
    @Published var searchText = ""
    @Published private(set) var fitMode = FitMode.width
    @Published var layout = PageLayout.continuous {
        didSet {
            let page = pdfView.currentPage
            pdfView.displayMode = layout.displayMode
            applyFit()
            if let page { pdfView.go(to: page) }
        }
    }

    private var searchResults: [PDFSelection] = []
    private var searchIndex = 0
    private var observers: [NSObjectProtocol] = []

    init(document: PDFDocument) {
        pdfView.document = document
        pdfView.autoScales = true
        pdfView.displayMode = layout.displayMode
        pdfView.displayDirection = .vertical
        pdfView.backgroundColor = .windowBackgroundColor
        pdfView.postsFrameChangedNotifications = true
        pageCount = document.pageCount

        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: .PDFViewPageChanged, object: pdfView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateCurrentPage() }
            },
            // Keep "fit page" fitted while the window is resized
            center.addObserver(forName: NSView.frameDidChangeNotification, object: pdfView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if self?.fitMode == .page { self?.applyFit() } }
            },
        ]
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    private func updateCurrentPage() {
        guard let page = pdfView.currentPage, let doc = pdfView.document else { return }
        currentPage = doc.index(for: page) + 1
    }

    // MARK: Navigation

    func goToPage(_ number: Int) {
        guard let doc = pdfView.document,
              let page = doc.page(at: min(max(number, 1), doc.pageCount) - 1) else { return }
        pdfView.go(to: page)
    }

    func previousPage() { pdfView.goToPreviousPage(nil) }
    func nextPage() { pdfView.goToNextPage(nil) }

    // MARK: Zoom

    func zoomIn() {
        fitMode = .custom
        pdfView.zoomIn(nil)
    }

    func zoomOut() {
        fitMode = .custom
        pdfView.zoomOut(nil)
    }

    func actualSize() {
        fitMode = .custom
        pdfView.autoScales = false
        pdfView.scaleFactor = 1.0
    }

    func fitWidth() {
        fitMode = .width
        applyFit()
    }

    func fitPage() {
        fitMode = .page
        applyFit()
        if let page = pdfView.currentPage { pdfView.go(to: page) }
    }

    private func applyFit() {
        switch fitMode {
        case .custom:
            break
        case .width:
            // PDFView's autoscale fits the page width
            pdfView.autoScales = true
        case .page:
            guard let page = pdfView.currentPage ?? pdfView.document?.page(at: 0) else { return }
            var size = page.bounds(for: pdfView.displayBox).size
            if page.rotation % 180 != 0 { size = CGSize(width: size.height, height: size.width) }
            if layout == .twoUp || layout == .twoUpContinuous { size.width *= 2 }
            let margin: CGFloat = 16
            let available = pdfView.bounds.insetBy(dx: margin, dy: margin).size
            guard size.width > 0, size.height > 0, available.width > 0, available.height > 0 else { return }
            pdfView.autoScales = false
            pdfView.scaleFactor = min(available.width / size.width, available.height / size.height)
        }
    }

    // MARK: Rotation

    func rotate(by degrees: Int) {
        guard let doc = pdfView.document else { return }
        let current = pdfView.currentPage
        for i in 0..<doc.pageCount {
            doc.page(at: i)?.rotation += degrees
        }
        pdfView.layoutDocumentView()
        applyFit()
        if let current { pdfView.go(to: current) }
    }

    // MARK: Search

    func search() {
        guard let doc = pdfView.document else { return }
        let query = searchText.trimmingCharacters(in: .whitespaces)
        searchResults = query.isEmpty ? [] : doc.findString(query, withOptions: .caseInsensitive)
        searchIndex = 0
        pdfView.highlightedSelections = searchResults.isEmpty ? nil : searchResults
        showCurrentResult()
    }

    func nextResult() {
        guard !searchResults.isEmpty else { return search() }
        searchIndex = (searchIndex + 1) % searchResults.count
        showCurrentResult()
    }

    private func showCurrentResult() {
        guard searchResults.indices.contains(searchIndex) else {
            pdfView.clearSelection()
            return
        }
        let selection = searchResults[searchIndex]
        pdfView.setCurrentSelection(selection, animate: true)
        pdfView.go(to: selection)
    }
}
