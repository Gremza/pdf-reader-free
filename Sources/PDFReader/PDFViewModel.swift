import SwiftUI
import PDFKit
import Quartz
import UniformTypeIdentifiers
import Vision

enum FitMode {
    case width, page, custom
}

/// A text field of the top bar that a menu item can focus.
enum BarField {
    case page, search
}

/// A running export, e.g. ("Exporting", 3, 10); a total of 0 means the progress is unknown.
struct ExportProgress {
    var label: String
    var done: Int
    var total: Int
    /// Shows a Cancel button, which cancels `PDFViewModel.progressTask`.
    var canCancel = false
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
    /// Made with "New PDF…" and not saved yet; "Save" asks where to save it.
    @Published private(set) var isNew: Bool

    @Published var currentPage = 1
    @Published var pageCount = 0
    @Published var searchText = ""
    /// Set by the menu bar; the top bar focuses the field and clears it.
    @Published var focusRequest: BarField?
    /// Full Screen Mode: one page at a time on black, like a presentation.
    @Published private(set) var isPresenting = false
    /// Pages done so far while exporting; nil when no export is running.
    @Published private(set) var exportProgress: ExportProgress?
    /// The running work that the Cancel button of `exportProgress` stops.
    private var progressTask: Task<Void, Never>?
    /// "Add Image to Page": the image being moved and resized, before it is placed.
    @Published private(set) var placingImage: ImagePlacementView?
    private var placementObservers: [NSObjectProtocol] = []
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
    /// Edits wait while an export reads the document or an image is being placed.
    var canEdit: Bool { exportProgress == nil && placingImage == nil }
    var baseName: String { url.deletingPathExtension().lastPathComponent }
    /// Full Screen Mode always shows single pages, whatever the layout.
    private var displayMode: PDFDisplayMode { isPresenting ? .singlePage : layout.displayMode }

    init(document: PDFDocument, url: URL, isNew: Bool = false) {
        self.url = url
        self.isNew = isNew
        // A new PDF is unsaved from the start
        if isNew { version = nextVersion; nextVersion += 1 }
        pdfView.document = document
        pdfView.autoScales = true
        pdfView.displayMode = layout.displayMode
        pdfView.displayDirection = .vertical
        pdfView.backgroundColor = .windowBackgroundColor
        pdfView.postsFrameChangedNotifications = true
        // Page turns fade through the view's layer
        pdfView.wantsLayer = true
        pageCount = document.pageCount

        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: .PDFViewPageChanged, object: pdfView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateCurrentPage() }
            },
            // Keep "fit page" and "fit width" fitted while the window is resized
            center.addObserver(forName: NSView.frameDidChangeNotification, object: pdfView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.applyFit() }
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

    /// The UserDefaults key of "Fade Between Pages", which is on by default.
    static let fadeKey = "fadeBetweenPages"

    func goToPage(_ number: Int) { turnPage { showPage(number) } }
    func previousPage() { turnPage { pdfView.goToPreviousPage(nil) } }
    func nextPage() { turnPage { pdfView.goToNextPage(nil) } }
    func firstPage() { turnPage { pdfView.goToFirstPage(nil) } }
    func lastPage() { turnPage { pdfView.goToLastPage(nil) } }

    func showPage(_ number: Int) {
        guard let doc = pdfView.document,
              let page = doc.page(at: min(max(number, 1), doc.pageCount) - 1) else { return }
        pdfView.go(to: page)
    }

    /// Core Animation cross-fades the whole view from the old page to the new one,
    /// including pages that PDFKit is still drawing.
    private func turnPage(_ change: () -> Void) {
        if UserDefaults.standard.object(forKey: Self.fadeKey) as? Bool ?? true, let layer = pdfView.layer {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.3
            layer.add(fade, forKey: "pageFade")
        }
        change()
    }

    // MARK: Full Screen Mode

    /// Shows one fitted page at a time on black, without page borders or scroll bars;
    /// the layout and zoom come back afterwards.
    func setPresenting(_ presenting: Bool) {
        guard presenting != isPresenting else { return }
        if presenting { endPlacing() }
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
        let scale: CGFloat
        switch fitMode {
        case .custom:
            return
        case .width:
            // Not PDFView's autoScales: with single pages it fits the whole page, not the width.
            // The document view is as wide as the widest row of pages with their margins, unscaled,
            // and the scroll view's width leaves out a scroll bar that takes room.
            pdfView.layoutDocumentView()
            guard let documentView = pdfView.documentView,
                  let scrollView = documentView.enclosingScrollView,
                  documentView.frame.width > 0, scrollView.contentSize.width > 0 else { return }
            scale = scrollView.contentSize.width / documentView.frame.width
        case .page:
            guard let page = pdfView.currentPage ?? pdfView.document?.page(at: 0) else { return }
            var size = page.bounds(for: pdfView.displayBox).size
            if page.rotation % 180 != 0 { size = CGSize(width: size.height, height: size.width) }
            if displayMode == .twoUp || displayMode == .twoUpContinuous { size.width *= 2 }
            let margin: CGFloat = isPresenting ? 0 : 16
            let available = pdfView.bounds.insetBy(dx: margin, dy: margin).size
            guard size.width > 0, size.height > 0, available.width > 0, available.height > 0 else { return }
            scale = min(available.width / size.width, available.height / size.height)
        }
        pdfView.autoScales = false
        pdfView.scaleFactor = scale
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

        /// The size of the PDF as it would be saved now.
        nonisolated var byteCount: Int {
            switch self {
            case .file(let url): (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            case .data(let data): data.count
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
        context.concatenate(displayTransform(box: box, rotation: rotation, scale: scale))
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

    /// Maps the page's user space to an image of the page as it is shown: upright and `scale` pixels per point.
    nonisolated private static func displayTransform(box: CGRect, rotation: Int, scale: CGFloat) -> CGAffineTransform {
        var transform = CGAffineTransform(scaleX: scale, y: scale)
        // Page rotation is clockwise; CoreGraphics angles are counterclockwise
        switch rotation {
        case 90:
            transform = transform.translatedBy(x: 0, y: box.width).rotated(by: -.pi / 2)
        case 180:
            transform = transform.translatedBy(x: box.width, y: box.height).rotated(by: .pi)
        case 270:
            transform = transform.translatedBy(x: box.height, y: 0).rotated(by: .pi / 2)
        default:
            break
        }
        return transform.translatedBy(x: -box.minX, y: -box.minY)
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
    func ensureEditable() -> Bool {
        guard let doc = pdfView.document else { return false }
        if doc.isEncrypted || doc.isLocked || !doc.allowsDocumentChanges {
            showError(EditError.protected.title, EditError.protected.detail)
            return false
        }
        return true
    }

    /// Changes the document in place; the previous state goes on the undo stack.
    /// `pageAfter` is the page (1-based) to show afterwards. Returns false when nothing changed.
    @discardableResult
    func applyEdit(pageAfter: Int? = nil, _ change: (PDFDocument) throws -> Void) -> Bool {
        guard canEdit, ensureEditable(), let doc = pdfView.document else { return false }
        guard let before = doc.dataRepresentation() else {
            showError("Edit failed", "The PDF can't be read.")
            return false
        }
        do {
            try change(doc)
        } catch let error as EditError {
            showError(error.title, error.detail)
            return false
        } catch {
            showError("Edit failed", error.localizedDescription)
            return false
        }
        history.append(Snapshot(data: before, version: version))
        if history.count > Self.undoLimit { history.removeFirst() }
        version = nextVersion
        nextVersion += 1
        documentChanged(page: pageAfter ?? currentPage)
        return true
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
        showPage(page)
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

    /// Lets the user pick PDFs and images and inserts them after page `after` (0 = at the start).
    /// Each image becomes a page of its own.
    func insertFiles(after: Int, message: String) {
        guard canEdit, ensureEditable(), let urls = Self.chooseFiles(message: message) else { return }
        applyEdit(pageAfter: after + 1) { doc in
            try Self.insertFiles(urls, into: doc, at: after)
        }
    }

    func addFilesAtEnd() {
        insertFiles(after: pageCount, message: "Choose the PDFs or images to add at the end")
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
        if isNew { return saveAs() }
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
        isNew = false
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

    // MARK: Printing

    /// Prints the pages as they are now, unsaved edits included, through the system print panel
    /// (printer, pages, copies, paper size, orientation, scale, preview).
    func printDocument() {
        guard canEdit, let doc = pdfView.document else { return }
        guard doc.allowsPrinting else {
            showError("This PDF can't be printed", "Its author doesn't allow printing.")
            return
        }
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.isHorizontallyCentered = true
        info.isVerticallyCentered = true
        guard let operation = doc.printOperation(for: info, scalingMode: .pageScaleDownToFit, autoRotate: true) else {
            showError("Printing failed", "The PDF can't be read.")
            return
        }
        operation.jobTitle = baseName
        operation.printPanel.options.formUnion([
            .showsCopies, .showsPageRange, .showsPaperSize, .showsOrientation, .showsScaling, .showsPreview,
        ])
        if let window = pdfView.window {
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            operation.run()
        }
    }

    // MARK: Reduce File Size

    /// The image quality of a reduced copy; the same presets as in the Windows app.
    enum ReducedQuality: CaseIterable {
        case high, medium, low

        var title: String {
            switch self {
            case .high: "High Quality"
            case .medium: "Medium Quality"
            case .low: "Low Quality"
            }
        }

        var dpi: Int {
            switch self {
            case .high: 200
            case .medium: 144
            case .low: 96
            }
        }

        var jpegQuality: Double {
            switch self {
            case .high: 0.8
            case .medium: 0.6
            case .low: 0.4
            }
        }

        /// The settings of the system's "Reduce File Size" Quartz filter, with this quality.
        var filterProperties: [String: Any] {
            [
                "Name": "Reduce File Size",
                "FilterType": 1,
                "Domains": ["Applications": true],
                "FilterData": ["ColorSettings": ["ImageSettings": [
                    "Compression Quality": jpegQuality,
                    "ImageCompression": "ImageJPEGCompress",
                    "ImageScaleSettings": [
                        "ImageResolution": dpi,
                        "ImageScaleInterpolate": true,
                        "ImageSizeMax": 0,
                        "ImageSizeMin": 0,
                    ],
                ]]],
            ]
        }
    }

    /// Saves a copy of the PDF whose images are stored again as JPEG at a lower resolution and quality.
    func reduceFileSize() {
        guard canEdit, ensureEditable(), let quality = askReducedQuality(), let source = exportSource() else { return }
        let originalSize = source.byteCount
        exportProgress = ExportProgress(label: "Reducing", done: 0, total: 0)

        Task { [weak self] in
            let data = await Self.reducedData(of: source, quality: quality)
            guard let self else { return }
            exportProgress = nil
            guard let data else {
                showError("Reducing the file size failed", "The PDF can't be read.")
                return
            }
            guard data.count < originalSize else {
                showError("This PDF can't be made smaller",
                          "Its images are already compressed, or it has no images." + (quality == .low ? "" : " Try a lower quality."))
                return
            }
            guard let target = askSaveURL(name: "\(baseName) (reduced).pdf", type: .pdf, message: "Save Reduced Size PDF"),
                  write(data, to: target)
            else { return }
            NSDocumentController.shared.noteNewRecentDocumentURL(target)
            showReduced(from: originalSize, to: data.count, at: target)
        }
    }

    private func askReducedQuality() -> ReducedQuality? {
        let alert = NSAlert()
        alert.messageText = "Reduce File Size"
        alert.informativeText = "Choose the quality of the images in the smaller copy. " +
            "Lower quality makes a smaller file. The original PDF stays unchanged."
        for quality in ReducedQuality.allCases {
            alert.addButton(withTitle: "\(quality.title) (\(quality.dpi) dpi)")
        }
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        // Medium is the default, like in the Windows app
        alert.buttons[0].keyEquivalent = ""
        alert.buttons[1].keyEquivalent = "\r"
        let index = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        return ReducedQuality.allCases.indices.contains(index) ? ReducedQuality.allCases[index] : nil
    }

    /// The Quartz filter recompresses every image at the resolution it is drawn with; links,
    /// outline and text stay as they are. "QuartzFilter" is the write option Preview uses for it.
    nonisolated private static func reducedData(of source: ExportSource, quality: ReducedQuality) async -> Data? {
        guard let doc = source.open(), let filter = QuartzFilter(properties: quality.filterProperties) else { return nil }
        return doc.dataRepresentation(options: [PDFDocumentWriteOption(rawValue: "QuartzFilter"): filter])
    }

    private func showReduced(from original: Int, to reduced: Int, at target: URL) {
        let alert = NSAlert()
        alert.messageText = "The smaller PDF is saved"
        let percent = Int((100 - Double(reduced) * 100 / Double(original)).rounded())
        alert.informativeText = "Reduced from \(Self.formatSize(original)) to \(Self.formatSize(reduced)) (\(percent)% smaller)."
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "OK")
        if alert.runModal() == .alertFirstButtonReturn { TabsModel.shared.open([target]) }
    }

    /// "173 KB", "16.1 MB": the same format as in the Windows app.
    nonisolated static func formatSize(_ bytes: Int) -> String {
        bytes < 1_000_000
            ? "\(max(1, Int((Double(bytes) / 1000).rounded()))) KB"
            : String(format: "%.1f MB", Double(bytes) / 1_000_000)
    }

    // MARK: Recognize Text

    /// Vision has no Albanian; with these languages and without language correction it keeps ë and ç.
    nonisolated private static let ocrLanguages = ["tr-TR", "fr-FR", "de-DE", "en-US"]
    /// Scanned pages are read at 300 DPI, but never larger than this many pixels on a side.
    nonisolated private static let ocrMaxSide: CGFloat = 6000
    /// Vision skips lines of small text on a whole page (a bank statement lost its card numbers),
    /// but finds them in parts of it, so each page is read in this many overlapping bands.
    nonisolated private static let ocrBands = 5

    /// The pages with recognized text, as a PDF whose pages replace those at `indexes` (0-based).
    private struct RecognizedPages: Sendable {
        var data = Data()
        var indexes: [Int] = []
        /// Pages that already had text.
        var skipped = 0
    }

    /// A line of text found on the page image, in its pixels.
    private struct RecognizedLine {
        let text: String
        let rect: CGRect
    }

    func cancelProgress() {
        progressTask?.cancel()
    }

    /// Finds the text of scanned pages with Vision and adds it as an invisible layer over each page,
    /// so it can be searched and copied. Pages that already have text are skipped.
    func recognizeText() {
        guard canEdit, ensureEditable(), let source = exportSource() else { return }
        let total = pageCount
        exportProgress = ExportProgress(label: "Recognizing text", done: 0, total: total, canCancel: true)

        progressTask = Task { [weak self] in
            let result = await Self.recognizeText(in: source) { done in
                self?.exportProgress?.done = done
            }
            guard let self else { return }
            exportProgress = nil
            progressTask = nil
            if Task.isCancelled { return }
            guard let result, let recognized = PDFDocument(data: result.data) else {
                showError("Recognizing text failed", "The PDF can't be read.")
                return
            }
            if result.skipped == total {
                showError("This PDF already has text", "Every page already has text that can be searched and copied.")
                return
            }
            guard !result.indexes.isEmpty else {
                showError("No text was found", "The pages may be blank, or the text may be too small or unclear to read.")
                return
            }
            let changed = applyEdit { doc in
                for (i, index) in result.indexes.enumerated() {
                    guard let new = recognized.page(at: i)?.copy() as? PDFPage else { continue }
                    Self.replacePage(at: index, in: doc, with: new)
                }
            }
            if changed { showRecognized(pages: result.indexes.count, skipped: result.skipped) }
        }
    }

    private func showRecognized(pages: Int, skipped: Int) {
        let alert = NSAlert()
        alert.messageText = "Text recognized"
        alert.informativeText = "The text of \(pages == 1 ? "1 page" : "\(pages) pages") can now be searched and copied. " +
            (skipped == 0 ? "" : "Pages that already had text were skipped. ") +
            "Save the PDF to keep it."
        alert.runModal()
    }

    /// Reads a copy of the document off the main thread; returns nil when it can't be read or was cancelled.
    /// Each page with text found is drawn again into a new PDF, with that text over it in invisible ink.
    nonisolated private static func recognizeText(
        in source: ExportSource, progress: @escaping @MainActor @Sendable (Int) -> Void
    ) async -> RecognizedPages? {
        guard let doc = source.open() else { return nil }
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data), let context = CGContext(consumer: consumer, mediaBox: nil, nil)
        else { return nil }

        var result = RecognizedPages()
        for index in 0..<doc.pageCount {
            if Task.isCancelled { return nil }
            guard let page = doc.page(at: index), let pageRef = page.pageRef else { continue }
            if page.string?.contains(where: { !$0.isWhitespace }) == true {
                result.skipped += 1
            } else if let (lines, toPixels) = try? recognizedLines(on: page, pageRef), !lines.isEmpty {
                var mediaBox = page.bounds(for: .mediaBox)
                var cropBox = page.bounds(for: .cropBox)
                let boxes = [
                    kCGPDFContextMediaBox: Data(bytes: &mediaBox, count: MemoryLayout<CGRect>.size),
                    kCGPDFContextCropBox: Data(bytes: &cropBox, count: MemoryLayout<CGRect>.size),
                ] as CFDictionary
                context.beginPDFPage(boxes)
                context.drawPDFPage(pageRef)
                context.concatenate(toPixels.inverted())
                drawInvisible(lines, in: context)
                context.endPDFPage()
                result.indexes.append(index)
            }
            await progress(index + 1)
        }
        context.closePDF()
        result.data = data as Data
        return result
    }

    /// Draws the page upright, like it is shown, and reads its lines of text with Vision.
    /// Also returns the transform from the page's user space to the pixels of that image.
    nonisolated private static func recognizedLines(
        on page: PDFPage, _ pageRef: CGPDFPage
    ) throws -> ([RecognizedLine], CGAffineTransform) {
        let box = page.bounds(for: .cropBox)
        let rotation = (page.rotation % 360 + 360) % 360
        var size = box.size
        if rotation % 180 != 0 { size = CGSize(width: size.height, height: size.width) }
        let scale = min(300.0 / 72, ocrMaxSide / max(size.width, size.height, 1))
        let width = Int((size.width * scale).rounded()), height = Int((size.height * scale).rounded())

        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { throw CocoaError(.fileReadUnknown) }
        context.setFillColor(.white)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let toPixels = displayTransform(box: box, rotation: rotation, scale: scale)
        context.concatenate(toPixels)
        context.drawPDFPage(pageRef)
        guard let image = context.makeImage() else { throw CocoaError(.fileReadUnknown) }

        let handler = VNImageRequestHandler(cgImage: image)
        /// The lines Vision finds in `region` (normalized, origin at the bottom left), in pixels of the image.
        func read(_ region: CGRect) throws -> [RecognizedLine] {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            request.recognitionLanguages = ocrLanguages
            request.regionOfInterest = region
            try handler.perform([request])
            return (request.results ?? []).compactMap { observation in
                guard let text = observation.topCandidates(1).first?.string.trimmingCharacters(in: .whitespaces),
                      !text.isEmpty else { return nil }
                // The box is relative to the region
                let box = observation.boundingBox
                let rect = CGRect(x: region.minX + box.minX * region.width, y: region.minY + box.minY * region.height,
                                  width: box.width * region.width, height: box.height * region.height)
                return RecognizedLine(text: text, rect: VNImageRectForNormalizedRect(rect, width, height))
            }
        }

        // The bands overlap by half. Each keeps the lines whose middle is in its own share,
        // so a line cut by the edge of one band comes whole from the next.
        let step = 1 / CGFloat(ocrBands + 1)
        var lines: [RecognizedLine] = []
        for band in 0..<ocrBands {
            let region = CGRect(x: 0, y: CGFloat(band) * step, width: 1, height: 2 * step)
            let low = band == 0 ? -CGFloat.infinity : region.minY + step / 2
            let high = band == ocrBands - 1 ? CGFloat.infinity : region.maxY - step / 2
            lines += try read(region).filter { low..<high ~= $0.rect.midY / CGFloat(height) }
        }
        // Lines that no band found may still be found on the whole page
        let found = lines
        lines += try read(CGRect(x: 0, y: 0, width: 1, height: 1)).filter { line in
            !found.contains { overlapsMostly($0.rect, line.rect) }
        }
        return (lines, toPixels)
    }

    /// True when the two boxes share more than a fifth of the smaller one.
    nonisolated private static func overlapsMostly(_ a: CGRect, _ b: CGRect) -> Bool {
        let common = a.intersection(b)
        return !common.isNull && common.width * common.height > 0.2 * min(a.width * a.height, b.width * b.height)
    }

    /// Each line is stretched over the width Vision found for it, so selections match the scan.
    nonisolated private static func drawInvisible(_ lines: [RecognizedLine], in context: CGContext) {
        context.setTextDrawingMode(.invisible)
        context.textMatrix = .identity
        let base = CTFontCreateWithName("Helvetica" as CFString, 1, nil)
        let ascent = CTFontGetAscent(base), descent = CTFontGetDescent(base)
        for line in lines {
            let size = line.rect.height / (ascent + descent)
            let font = CTFontCreateCopyWithAttributes(base, size, nil, nil)
            let ctLine = CTLineCreateWithAttributedString(NSAttributedString(string: line.text, attributes: [.font: font]))
            let width = CTLineGetTypographicBounds(ctLine, nil, nil, nil)
            guard width > 0 else { continue }
            context.saveGState()
            context.translateBy(x: line.rect.minX, y: line.rect.minY + descent * size)
            context.scaleBy(x: line.rect.width / width, y: 1)
            context.textPosition = .zero
            CTLineDraw(ctLine, context)
            context.restoreGState()
        }
    }

    // MARK: Add Image to Page

    /// The image sits over the PDF view and follows its page when the view scrolls or zooms.
    func startPlacing(_ placement: ImagePlacementView) {
        placingImage = placement
        pdfView.addSubview(placement)
        let clipView = pdfView.documentView?.enclosingScrollView?.contentView
        clipView?.postsBoundsChangedNotifications = true
        let center = NotificationCenter.default
        let update: @Sendable (Notification) -> Void = { [weak placement] _ in
            MainActor.assumeIsolated { placement?.updateFrame() }
        }
        placementObservers = [
            center.addObserver(forName: .PDFViewScaleChanged, object: pdfView, queue: .main, using: update),
            center.addObserver(forName: .PDFViewDisplayModeChanged, object: pdfView, queue: .main, using: update),
            center.addObserver(forName: .PDFViewPageChanged, object: pdfView, queue: .main, using: update),
            center.addObserver(forName: NSView.frameDidChangeNotification, object: pdfView, queue: .main, using: update),
            center.addObserver(forName: NSView.boundsDidChangeNotification, object: clipView, queue: .main, using: update),
        ]
    }

    /// Takes the image away again; `placeImage` draws it into the page for good.
    func endPlacing() {
        guard let placement = placingImage else { return }
        placementObservers.forEach(NotificationCenter.default.removeObserver)
        placementObservers = []
        placement.removeFromSuperview()
        placingImage = nil
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
