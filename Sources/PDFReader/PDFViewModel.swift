import SwiftUI
import PDFKit
import UniformTypeIdentifiers

enum FitMode {
    case width, page, custom
}

/// A text field of the top bar that a menu item can focus.
enum BarField {
    case page, search
}

/// A running export, e.g. ("Exporting", 3, 10).
struct ExportProgress {
    var label: String
    var done: Int
    var total: Int
}

/// The document before an edit, for undo.
private struct Snapshot {
    let data: Data
    let version: Int
}

/// An edit could not be applied; shown to the user as is.
struct EditError: LocalizedError {
    let title: String
    let detail: String
    var errorDescription: String? { detail }

    static let protected = EditError(
        title: "This PDF is protected",
        detail: "PDFs protected by a password or restrictions can't be edited.")
}

enum PageLayout: String, CaseIterable, Identifiable {
    case single, continuous, twoUp, twoUpContinuous
    var id: Self { self }

    var title: String {
        switch self {
        case .single: "Single Page"
        case .continuous: "Continuous"
        case .twoUp: "Two Pages"
        case .twoUpContinuous: "Two Pages, Continuous"
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

/// Owns the PDFView so toolbar actions can drive it, and the edits made to the document.
@MainActor
final class PDFViewModel: ObservableObject {
    static let undoLimit = 30

    let pdfView = PDFView()
    /// Where the PDF is saved; changes with "Save As".
    @Published private(set) var url: URL

    @Published var currentPage = 1
    @Published var pageCount = 0
    @Published var searchText = ""
    /// Set by the menu bar; the top bar focuses the field and clears it.
    @Published var focusRequest: BarField?
    /// Full Screen Mode: one page at a time on black, like a presentation.
    @Published private(set) var isPresenting = false
    /// Pages done so far while exporting; nil when no export is running.
    @Published private(set) var exportProgress: ExportProgress?
    /// Bumps on every change of the document's pages, so thumbnails redraw.
    @Published private(set) var revision = 0
    // Every edit gets a new version; the document is unsaved while it differs from the saved one
    @Published private var version = 0
    @Published private var savedVersion = 0
    @Published private var history: [Snapshot] = []
    private var nextVersion = 1
    @Published private(set) var fitMode = FitMode.width
    @Published var layout = PageLayout.single {
        didSet {
            let page = pdfView.currentPage
            pdfView.displayMode = displayMode
            applyFit()
            if let page { pdfView.go(to: page) }
        }
    }

    private var fitBeforePresenting = FitMode.width
    private var scaleBeforePresenting: CGFloat = 1
    private var searchResults: [PDFSelection] = []
    private var searchIndex = 0
    private var observers: [NSObjectProtocol] = []

    var isDirty: Bool { version != savedVersion }
    var canUndo: Bool { !history.isEmpty && canEdit }
    /// Edits wait while an export reads the document.
    var canEdit: Bool { exportProgress == nil }
    var baseName: String { url.deletingPathExtension().lastPathComponent }
    /// Full Screen Mode always shows single pages, whatever the layout.
    private var displayMode: PDFDisplayMode { isPresenting ? .singlePage : layout.displayMode }

    init(document: PDFDocument, url: URL) {
        self.url = url
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
    func firstPage() { pdfView.goToFirstPage(nil) }
    func lastPage() { pdfView.goToLastPage(nil) }

    // MARK: Full Screen Mode

    /// Shows one fitted page at a time on black, without page borders or scroll bars;
    /// the layout and zoom come back afterwards.
    func setPresenting(_ presenting: Bool) {
        guard presenting != isPresenting else { return }
        let page = pdfView.currentPage
        if presenting {
            fitBeforePresenting = fitMode
            scaleBeforePresenting = pdfView.scaleFactor
            fitMode = .page
        } else {
            fitMode = fitBeforePresenting
        }
        isPresenting = presenting
        pdfView.displayMode = displayMode
        pdfView.displaysPageBreaks = !presenting
        pdfView.pageShadowsEnabled = !presenting
        pdfView.backgroundColor = presenting ? .black : .windowBackgroundColor
        if let scrollView = pdfView.documentView?.enclosingScrollView {
            scrollView.hasVerticalScroller = !presenting
            scrollView.hasHorizontalScroller = !presenting
        }
        if fitMode == .custom {
            pdfView.autoScales = false
            pdfView.scaleFactor = scaleBeforePresenting
        }
        applyFit()
        if let page { pdfView.go(to: page) }
    }

    /// Clicking a link in Full Screen Mode follows it instead of turning the page.
    func isLink(at windowPoint: NSPoint) -> Bool {
        let point = pdfView.convert(windowPoint, from: nil)
        guard let page = pdfView.page(for: point, nearest: false) else { return false }
        return page.annotation(at: pdfView.convert(point, to: page))?.type == "Link"
    }

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
            if displayMode == .twoUp || displayMode == .twoUpContinuous { size.width *= 2 }
            let margin: CGFloat = isPresenting ? 0 : 16
            let available = pdfView.bounds.insetBy(dx: margin, dy: margin).size
            guard size.width > 0, size.height > 0, available.width > 0, available.height > 0 else { return }
            pdfView.autoScales = false
            pdfView.scaleFactor = min(available.width / size.width, available.height / size.height)
        }
    }

    // MARK: Rotation

    /// Rotates all pages; saved into the file like any other edit.
    func rotate(by degrees: Int) {
        applyEdit { doc in
            for i in 0..<doc.pageCount {
                if let page = doc.page(at: i) { Self.rotate(page, by: degrees) }
            }
        }
    }

    nonisolated private static func rotate(_ page: PDFPage, by degrees: Int) {
        page.rotation = ((page.rotation + degrees) % 360 + 360) % 360
    }

    // MARK: Export

    /// Saves every page as 1.jpg, 2.jpg, … in a new folder named after the PDF.
    func exportJPEG() {
        exportToFolder(message: "Choose where to create the folder of JPG images", label: "Exporting") { page, number in
            ("\(number).jpg", try Self.jpegData(for: page))
        }
    }

    /// Saves every page as 1.pdf, 2.pdf, … in a new folder named after the PDF.
    func splitPages() {
        guard ensureEditable() else { return }
        exportToFolder(message: "Choose where to create the folder of PDF pages", label: "Splitting") { page, number in
            let single = PDFDocument()
            guard let copy = page.copy() as? PDFPage else { throw CocoaError(.fileWriteUnknown) }
            single.insert(copy, at: 0)
            guard let data = single.dataRepresentation() else { throw CocoaError(.fileWriteUnknown) }
            return ("\(number).pdf", data)
        }
    }

    /// Creates a folder named after the PDF and writes one file per page into it.
    private func exportToFolder(
        message: String, label: String,
        file: @escaping @Sendable (PDFPage, Int) throws -> (name: String, data: Data)
    ) {
        guard canEdit, let source = exportSource() else { return }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Export"
        panel.message = message
        guard panel.runModal() == .OK, let parent = panel.url else { return }

        let folder: URL
        do {
            folder = try Self.makeFolder(in: parent, named: baseName)
        } catch {
            showExportError(error)
            return
        }

        let total = pageCount
        exportProgress = ExportProgress(label: label, done: 0, total: total)

        Task { [weak self] in
            do {
                try await Self.writePages(of: source, to: folder, file: file) { done in
                    self?.exportProgress?.done = done
                }
                self?.exportProgress = nil
                NSWorkspace.shared.open(folder)
            } catch {
                self?.exportProgress = nil
                self?.showExportError(error)
            }
        }
    }

    /// Exports read a separate copy of the document, so the visible one stays untouched.
    enum ExportSource: Sendable {
        case file(URL)
        case data(Data)

        nonisolated func open() -> PDFDocument? {
            switch self {
            case .file(let url): PDFDocument(url: url)
            case .data(let data): PDFDocument(data: data)
            }
        }
    }

    private var thumbnailSnapshot: (revision: Int, source: ExportSource)?

    /// The pages as of `revision`, for thumbnails rendered off the main thread; read once per change.
    func thumbnailSource() -> ExportSource? {
        if let thumbnailSnapshot, thumbnailSnapshot.revision == revision { return thumbnailSnapshot.source }
        let source: ExportSource
        if !isDirty {
            source = .file(url)
        } else if let data = pdfView.document?.dataRepresentation() {
            source = .data(data)
        } else {
            return nil
        }
        thumbnailSnapshot = (revision, source)
        return source
    }

    /// The saved file when nothing changed (also works for protected PDFs), otherwise the edited document.
    private func exportSource() -> ExportSource? {
        if !isDirty { return .file(url) }
        guard let data = pdfView.document?.dataRepresentation() else {
            showExportError(CocoaError(.fileWriteUnknown))
            return nil
        }
        return .data(data)
    }

    /// Renders off the main thread.
    nonisolated private static func writePages(
        of source: ExportSource, to folder: URL,
        file: @Sendable (PDFPage, Int) throws -> (name: String, data: Data),
        progress: @escaping @MainActor @Sendable (Int) -> Void
    ) async throws {
        guard let copy = source.open() else { throw CocoaError(.fileReadCorruptFile) }
        for index in 0..<copy.pageCount {
            guard let page = copy.page(at: index) else { continue }
            let output = try file(page, index + 1)
            try output.data.write(to: folder.appendingPathComponent(output.name))
            await progress(index + 1)
        }
    }

    /// Creates "name", or "name 2", "name 3", … when that folder already exists.
    private static func makeFolder(in parent: URL, named name: String) throws -> URL {
        var folder = parent.appendingPathComponent(name, isDirectory: true)
        var number = 2
        while FileManager.default.fileExists(atPath: folder.path) {
            folder = parent.appendingPathComponent("\(name) \(number)", isDirectory: true)
            number += 1
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        return folder
    }

    /// Renders the page at 144 DPI on white, as JPEG.
    nonisolated private static func jpegData(for page: PDFPage, scale: CGFloat = 2) throws -> Data {
        let box = page.bounds(for: .cropBox)
        let rotation = (page.rotation % 360 + 360) % 360
        var size = box.size
        if rotation % 180 != 0 { size = CGSize(width: size.height, height: size.width) }
        let width = Int((size.width * scale).rounded()), height = Int((size.height * scale).rounded())

        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw CocoaError(.fileWriteUnknown) }

        context.setFillColor(.white)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        // Page rotation is clockwise; CoreGraphics angles are counterclockwise
        switch rotation {
        case 90:
            context.translateBy(x: 0, y: box.width)
            context.rotate(by: -.pi / 2)
        case 180:
            context.translateBy(x: box.width, y: box.height)
            context.rotate(by: .pi)
        case 270:
            context.translateBy(x: box.height, y: 0)
            context.rotate(by: .pi / 2)
        default:
            break
        }
        context.translateBy(x: -box.minX, y: -box.minY)
        // Rotation is applied above, so draw the page unrotated
        page.rotation = 0
        page.draw(with: .cropBox, to: context)

        let data = NSMutableData()
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return data as Data
    }

    private func showExportError(_ error: Error) {
        showError("Export failed", error.localizedDescription)
    }

    func showError(_ title: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.runModal()
    }

    // MARK: Editing

    /// Encrypted PDFs can't be written back without losing their protection, so they stay read-only.
    private func ensureEditable() -> Bool {
        guard let doc = pdfView.document else { return false }
        if doc.isEncrypted || doc.isLocked || !doc.allowsDocumentChanges {
            showError(EditError.protected.title, EditError.protected.detail)
            return false
        }
        return true
    }

    /// Changes the document in place; the previous state goes on the undo stack.
    /// `pageAfter` is the page (1-based) to show afterwards.
    private func applyEdit(pageAfter: Int? = nil, _ change: (PDFDocument) throws -> Void) {
        guard canEdit, ensureEditable(), let doc = pdfView.document else { return }
        guard let before = doc.dataRepresentation() else {
            showError("Edit failed", "The PDF can't be read.")
            return
        }
        do {
            try change(doc)
        } catch let error as EditError {
            showError(error.title, error.detail)
            return
        } catch {
            showError("Edit failed", error.localizedDescription)
            return
        }
        history.append(Snapshot(data: before, version: version))
        if history.count > Self.undoLimit { history.removeFirst() }
        version = nextVersion
        nextVersion += 1
        documentChanged(page: pageAfter ?? currentPage)
    }

    func undo() {
        guard canUndo, let snapshot = history.popLast(), let doc = PDFDocument(data: snapshot.data) else { return }
        let page = currentPage
        pdfView.document = doc
        pdfView.displayMode = displayMode
        version = snapshot.version
        documentChanged(page: page)
    }

    /// Shows the changed pages and keeps the view where the user was.
    private func documentChanged(page: Int) {
        guard let doc = pdfView.document else { return }
        pageCount = doc.pageCount
        pdfView.layoutDocumentView()
        applyFit()
        goToPage(page)
        updateCurrentPage()
        revision += 1
        if !searchText.trimmingCharacters(in: .whitespaces).isEmpty { search() }
    }

    // Page numbers below are 1-based, like in the UI

    func deletePage(_ number: Int) {
        guard pageCount > 1 else {
            showError("The page can't be deleted", "A PDF must have at least one page.")
            return
        }
        applyEdit(pageAfter: number) { $0.removePage(at: number - 1) }
    }

    func rotatePage(_ number: Int, by degrees: Int) {
        applyEdit(pageAfter: number) { doc in
            if let page = doc.page(at: number - 1) { Self.rotate(page, by: degrees) }
        }
    }

    /// Moves a page so that it ends up at position `to`.
    func movePage(_ from: Int, to: Int) {
        guard from != to else { return }
        applyEdit(pageAfter: to) { doc in
            guard let page = doc.page(at: from - 1) else { return }
            doc.removePage(at: from - 1)
            doc.insert(page, at: to - 1)
        }
    }

    /// Inserts an empty page with the size of the page before it.
    func insertBlankPage(after: Int) {
        applyEdit(pageAfter: after + 1) { doc in
            guard let reference = doc.page(at: max(0, after - 1)) else { return }
            var size = reference.bounds(for: .mediaBox).size
            if reference.rotation % 180 != 0 { size = CGSize(width: size.height, height: size.width) }
            let page = PDFPage()
            page.setBounds(CGRect(origin: .zero, size: size), for: .mediaBox)
            page.setBounds(CGRect(origin: .zero, size: size), for: .cropBox)
            doc.insert(page, at: after)
        }
    }

    /// Lets the user pick PDFs and inserts their pages after page `after` (0 = at the start).
    func insertPDFs(after: Int, message: String) {
        guard canEdit, ensureEditable() else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        panel.message = message
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }

        applyEdit(pageAfter: after + 1) { doc in
            var sources: [PDFDocument] = []
            for url in panel.urls {
                guard let source = PDFDocument(url: url) else {
                    throw EditError(title: "The file can't be opened", detail: url.lastPathComponent)
                }
                if source.isLocked { throw EditError.protected }
                sources.append(source)
            }
            var at = after
            for source in sources {
                for i in 0..<source.pageCount {
                    guard let page = source.page(at: i)?.copy() as? PDFPage else { continue }
                    doc.insert(page, at: at)
                    at += 1
                }
            }
        }
    }

    func mergePDFs() {
        insertPDFs(after: pageCount, message: "Choose the PDFs to merge")
    }

    /// Asks which pages to keep and saves them as a new PDF.
    func extractPagesPrompt(defaultValue: String? = nil) {
        guard canEdit, ensureEditable(), let doc = pdfView.document else { return }

        let alert = NSAlert()
        alert.messageText = "Extract Pages"
        alert.informativeText = "Enter the pages to save in a new PDF, e.g. 1-3, 5 (\(pageCount) pages in total)."
        alert.addButton(withTitle: "Extract")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: defaultValue ?? "\(currentPage)")
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let text = field.stringValue
        guard let indexes = Self.parsePageRanges(text, pageCount: pageCount) else {
            showError("Invalid pages", "Enter numbers from 1 to \(pageCount), e.g. 1-3, 5")
            return
        }
        let extracted = PDFDocument()
        for index in indexes {
            if let page = doc.page(at: index)?.copy() as? PDFPage {
                extracted.insert(page, at: extracted.pageCount)
            }
        }
        let name = "\(baseName) (pages \(text.filter { !$0.isWhitespace })).pdf"
        guard let target = askSaveURL(name: name, type: .pdf, message: "Save Extracted Pages") else { return }
        guard let data = extracted.dataRepresentation() else {
            showError("The PDF can't be saved", "The pages can't be written.")
            return
        }
        write(data, to: target)
    }

    /// Parses "1-3, 5, 8-" into 0-based page indexes, or returns nil when invalid.
    /// "8-" means "from page 8 to the end".
    nonisolated static func parsePageRanges(_ text: String, pageCount: Int) -> [Int]? {
        var indexes: [Int] = []
        let parts = text.split(whereSeparator: { $0 == "," || $0 == ";" || $0.isWhitespace })
        for part in parts {
            let bounds = part.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
                .map { $0.replacingOccurrences(of: "–", with: "") }
            let ends = part.contains("-") ? bounds : [String(part)]
            guard let start = Int(ends[0]) else { return nil }
            let end = ends.count == 1 ? start : ends[1].isEmpty ? pageCount : Int(ends[1])
            guard let end, start >= 1, end <= pageCount, start <= end else { return nil }
            indexes += (start - 1)..<end
        }
        return indexes.isEmpty ? nil : indexes
    }

    // MARK: Saving

    /// Writes back to the file; returns false when it failed.
    @discardableResult
    func save() -> Bool {
        guard isDirty else { return true }
        guard let data = pdfView.document?.dataRepresentation(), write(data, to: url) else { return false }
        savedVersion = version
        return true
    }

    @discardableResult
    func saveAs() -> Bool {
        guard let data = pdfView.document?.dataRepresentation(),
              let target = askSaveURL(name: url.lastPathComponent, type: .pdf, message: "Save As"),
              write(data, to: target)
        else { return false }
        url = target
        savedVersion = version
        NSDocumentController.shared.noteNewRecentDocumentURL(target)
        // The tab title shows the new name
        TabsModel.shared.objectWillChange.send()
        return true
    }

    private func askSaveURL(name: String, type: UTType, message: String) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = name
        panel.message = message
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Atomic, so a failed save never leaves a half-written file.
    @discardableResult
    private func write(_ data: Data, to target: URL) -> Bool {
        do {
            try data.write(to: target, options: .atomic)
            return true
        } catch {
            showError("The file can't be saved", error.localizedDescription)
            return false
        }
    }

    // MARK: Word

    /// Saves the text of the PDF as a Word document.
    func exportWord() {
        guard canEdit, let source = exportSource() else { return }
        exportProgress = ExportProgress(label: "Preparing Word", done: 0, total: pageCount)

        Task { [weak self] in
            let document = await WordExport.extract(from: source) { done in
                self?.exportProgress?.done = done
            }
            guard let self else { return }
            exportProgress = nil
            guard let document else {
                showError("Word export failed", "The PDF can't be read.")
                return
            }
            guard document.hasText else {
                showError("This PDF has no text",
                          "The pages are probably scanned images, so there is no text to export to Word.")
                return
            }
            guard let target = askSaveURL(name: "\(baseName).docx", type: WordExport.docxType, message: "Export to Word"),
                  write(WordExport.docx(document), to: target)
            else { return }
            NSWorkspace.shared.open(target)
        }
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

    func previousResult() {
        guard !searchResults.isEmpty else { return search() }
        searchIndex = (searchIndex - 1 + searchResults.count) % searchResults.count
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
