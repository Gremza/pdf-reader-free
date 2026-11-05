import AppKit
import PDFKit
import ImageIO
import UniformTypeIdentifiers

/// An image file for a PDF page, with the EXIF orientation that photos are shown with.
struct PageImage {
    let image: CGImage
    let orientation: CGImagePropertyOrientation

    init?(url: URL) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        self.image = image
        orientation = (properties?[kCGImagePropertyOrientation] as? UInt32).flatMap(CGImagePropertyOrientation.init) ?? .up
    }

    /// The size as the image is shown, in pixels.
    var size: CGSize {
        let width = CGFloat(image.width), height = CGFloat(image.height)
        return orientation.rawValue >= 5 ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
    }

    /// Draws the image upright into the unit square. A JPEG goes into a PDF as it is, without recompressing.
    func draw(in context: CGContext) {
        context.saveGState()
        context.concatenate(Self.orientationTransform(orientation))
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        context.restoreGState()
    }

    /// Turns the stored image in the unit square the way its EXIF orientation says.
    static func orientationTransform(_ orientation: CGImagePropertyOrientation) -> CGAffineTransform {
        switch orientation {
        case .upMirrored: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 1, ty: 0)
        case .down: CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 1, ty: 1)
        case .downMirrored: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 1)
        case .leftMirrored: CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: 1, ty: 1)
        case .right: CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 1)
        case .rightMirrored: CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
        case .left: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1, ty: 0)
        default: .identity
        }
    }

    /// Maps the unit square, upright as the page is shown, onto `rect` in the page's user space.
    static func uprightTransform(_ rect: CGRect, rotation: Int) -> CGAffineTransform {
        // Page rotation turns the page clockwise for display, so the image is turned back
        let turn: CGAffineTransform = switch (rotation % 360 + 360) % 360 {
        case 90: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1, ty: 0)
        case 180: CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 1, ty: 1)
        case 270: CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 1)
        default: .identity
        }
        return turn.concatenating(CGAffineTransform(a: rect.width, b: 0, c: 0, d: rect.height, tx: rect.minX, ty: rect.minY))
    }

    /// An A4 page, turned like the image, with the image as large as it fits.
    func page() -> PDFPage? {
        let a4 = CGSize(width: 595, height: 842)
        let pageSize = size.width > size.height ? CGSize(width: a4.height, height: a4.width) : a4
        let scale = min(pageSize.width / size.width, pageSize.height / size.height)
        let width = size.width * scale, height = size.height * scale
        let rect = CGRect(x: (pageSize.width - width) / 2, y: (pageSize.height - height) / 2, width: width, height: height)
        return PageImage.drawnPage(box: CGRect(origin: .zero, size: pageSize)) { context in
            context.concatenate(Self.uprightTransform(rect, rotation: 0))
            draw(in: context)
        }
    }

    /// A one-page PDF with the given boxes and whatever `draw` draws in its user space.
    static func drawnPage(box: CGRect, cropBox: CGRect? = nil, draw: (CGContext) -> Void) -> PDFPage? {
        var mediaBox = box
        var crop = cropBox ?? box
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data), let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
        else { return nil }
        let boxes = [
            kCGPDFContextMediaBox: Data(bytes: &mediaBox, count: MemoryLayout<CGRect>.size),
            kCGPDFContextCropBox: Data(bytes: &crop, count: MemoryLayout<CGRect>.size),
        ] as CFDictionary
        context.beginPDFPage(boxes)
        draw(context)
        context.endPDFPage()
        context.closePDF()
        return PDFDocument(data: data as Data)?.page(at: 0)
    }
}

/// The image of "Add Image to Page" while it is being placed: shown over the PDF view with a frame,
/// moved and resized by the mouse. It becomes part of the page only when it is placed.
final class ImagePlacementView: NSView {
    let image: PageImage
    let page: PDFPage
    /// Where the image goes, in the page's user space.
    private(set) var rect: CGRect
    private weak var pdfView: PDFView?
    private var drag: Drag?
    /// Room around the image for the corner handles.
    static let margin: CGFloat = 5

    private enum Drag {
        case move(offset: CGSize)
        /// The corner across from the one being dragged stays where it is.
        case resize(fixed: CGPoint)
    }

    init(image: PageImage, page: PDFPage, rect: CGRect, in pdfView: PDFView) {
        self.image = image
        self.page = page
        self.rect = rect
        self.pdfView = pdfView
        super.init(frame: .zero)
        updateFrame()
    }

    required init?(coder: NSCoder) { nil }

    /// Follows the page when the PDF view scrolls, zooms or changes its layout.
    func updateFrame() {
        guard let pdfView else { return }
        // In the single page layouts, its page may not be the one shown
        isHidden = !pdfView.visiblePages.contains(page)
        frame = pdfView.convert(rect, from: page).insetBy(dx: -Self.margin, dy: -Self.margin)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let imageRect = bounds.insetBy(dx: Self.margin, dy: Self.margin)
        context.saveGState()
        context.concatenate(PageImage.uprightTransform(imageRect, rotation: 0))
        image.draw(in: context)
        context.restoreGState()

        NSColor.controlAccentColor.setStroke()
        NSColor.controlAccentColor.setFill()
        NSBezierPath(rect: imageRect.insetBy(dx: 0.5, dy: 0.5)).stroke()
        for corner in Self.corners(of: imageRect) {
            NSBezierPath(rect: CGRect(x: corner.x - 4, y: corner.y - 4, width: 8, height: 8)).fill()
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
        for corner in Self.corners(of: bounds.insetBy(dx: Self.margin, dy: Self.margin)) {
            addCursorRect(CGRect(x: corner.x - 6, y: corner.y - 6, width: 12, height: 12), cursor: .crosshair)
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    static func corners(of rect: CGRect) -> [CGPoint] {
        [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
         CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)]
    }

    /// The mouse in the page's user space.
    private func pagePoint(_ event: NSEvent) -> CGPoint? {
        guard let pdfView else { return nil }
        return pdfView.convert(pdfView.convert(event.locationInWindow, from: nil), to: page)
    }

    override func mouseDown(with event: NSEvent) {
        guard let pdfView, let point = pagePoint(event) else { return }
        // Corners are found on screen, so they are as easy to grab at every zoom
        let inView = convert(event.locationInWindow, from: nil)
        let corners = Self.corners(of: bounds.insetBy(dx: Self.margin, dy: Self.margin))
        if let corner = corners.firstIndex(where: { hypot($0.x - inView.x, $0.y - inView.y) <= 8 }) {
            let grabbed = pdfView.convert(Self.corners(of: pdfView.convert(rect, from: page))[corner], to: page)
            drag = .resize(fixed: CGPoint(x: rect.minX + rect.maxX - grabbed.x, y: rect.minY + rect.maxY - grabbed.y))
        } else {
            drag = .move(offset: CGSize(width: point.x - rect.minX, height: point.y - rect.minY))
            NSCursor.closedHand.push()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag, let point = pagePoint(event) else { return }
        let box = page.bounds(for: .cropBox)
        var next = rect
        switch drag {
        case .move(let offset):
            next.origin.x = min(max(point.x - offset.width, box.minX), box.maxX - rect.width)
            next.origin.y = min(max(point.y - offset.height, box.minY), box.maxY - rect.height)
        case .resize(let fixed):
            // Keeps the shape of the image; never larger than the page, never smaller than 8 points
            let aspect = rect.width / rect.height
            let towardsX = point.x >= fixed.x ? box.maxX - fixed.x : fixed.x - box.minX
            let towardsY = point.y >= fixed.y ? box.maxY - fixed.y : fixed.y - box.minY
            let width = min(max(abs(point.x - fixed.x), abs(point.y - fixed.y) * aspect, 8), towardsX, towardsY * aspect)
            next = CGRect(x: point.x >= fixed.x ? fixed.x : fixed.x - width,
                          y: point.y >= fixed.y ? fixed.y : fixed.y - width / aspect,
                          width: width, height: width / aspect)
        }
        rect = next
        updateFrame()
        window?.invalidateCursorRects(for: self)
    }

    override func mouseUp(with event: NSEvent) {
        if case .move = drag { NSCursor.pop() }
        drag = nil
    }
}

// MARK: - New PDF, inserting files, Add Image to Page

extension PDFViewModel {
    /// PDFs and images, in the order of their names.
    static let insertableTypes: [UTType] = [.pdf, .image]

    /// Inserts the pages of PDFs, and images as pages of their own, at `index` (0-based).
    static func insertFiles(_ urls: [URL], into doc: PDFDocument, at index: Int) throws {
        var pages: [PDFPage] = []
        for url in urls {
            if UTType(filenameExtension: url.pathExtension)?.conforms(to: .pdf) == true {
                guard let source = PDFDocument(url: url) else {
                    throw EditError(title: "The file can't be opened", detail: url.lastPathComponent)
                }
                if source.isLocked { throw EditError.protected }
                pages += (0..<source.pageCount).compactMap { source.page(at: $0)?.copy() as? PDFPage }
            } else {
                guard let page = PageImage(url: url)?.page() else {
                    throw EditError(title: "The file can't be opened", detail: url.lastPathComponent)
                }
                pages.append(page)
            }
        }
        for (offset, page) in pages.enumerated() {
            doc.insert(page, at: index + offset)
        }
    }

    /// Asks for PDFs and images; nil when cancelled.
    static func chooseFiles(message: String, prompt: String? = nil) -> [URL]? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = insertableTypes
        panel.allowsMultipleSelection = true
        panel.message = message
        if let prompt { panel.prompt = prompt }
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return nil }
        return panel.urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Puts the chosen image in the middle of the page, at most half its size, to be moved and resized.
    func addImage(toPage number: Int) {
        guard canEdit, ensureEditable(), let page = pdfView.document?.page(at: number - 1) else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.message = "Choose the image to add to page \(number)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let image = PageImage(url: url), image.size.width > 0, image.size.height > 0 else {
            showError("The file can't be opened", url.lastPathComponent)
            return
        }

        let box = page.bounds(for: .cropBox)
        let turned = page.rotation % 180 != 0
        let shown = turned ? CGSize(width: box.height, height: box.width) : box.size
        let scale = min(shown.width / 2 / image.size.width, shown.height / 2 / image.size.height, 1)
        var size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        if turned { size = CGSize(width: size.height, height: size.width) }
        showPage(number)
        startPlacing(ImagePlacementView(
            image: image, page: page,
            rect: CGRect(x: box.midX - size.width / 2, y: box.midY - size.height / 2, width: size.width, height: size.height),
            in: pdfView))
    }

    /// Draws the image into the page, as an edit that can be undone.
    func placeImage() {
        guard let placement = placingImage, let index = pdfView.document.map({ $0.index(for: placement.page) }),
              index != NSNotFound else { return }
        let rect = placement.rect
        let image = placement.image
        endPlacing()
        applyEdit(pageAfter: index + 1) { doc in
            // The page is drawn from a saved copy, which has the content of every earlier edit
            guard let old = doc.page(at: index), let data = doc.dataRepresentation(),
                  let source = PDFDocument(data: data)?.page(at: index), let pageRef = source.pageRef,
                  let new = PageImage.drawnPage(box: old.bounds(for: .mediaBox), cropBox: old.bounds(for: .cropBox), draw: { context in
                      context.drawPDFPage(pageRef)
                      context.concatenate(PageImage.uprightTransform(rect, rotation: old.rotation))
                      image.draw(in: context)
                  })
            else { throw EditError(title: "The image can't be added", detail: "The page can't be drawn.") }
            Self.replacePage(at: index, in: doc, with: new)
        }
    }

    func cancelImagePlacement() {
        endPlacing()
    }

    /// The new page has only the page content; rotation, links and notes move over from the old one.
    static func replacePage(at index: Int, in doc: PDFDocument, with new: PDFPage) {
        guard let old = doc.page(at: index) else { return }
        new.rotation = old.rotation
        for annotation in old.annotations {
            old.removeAnnotation(annotation)
            new.addAnnotation(annotation)
        }
        doc.removePage(at: index)
        doc.insert(new, at: index)
    }
}
