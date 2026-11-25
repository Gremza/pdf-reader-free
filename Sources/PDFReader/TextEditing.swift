import AppKit
import PDFKit

// MARK: - Edit Text

extension PDFViewModel {
    /// A click on a line of text opens a field over it; each changed line is an edit that can be undone.
    /// Choosing it again ends it.
    func editText() {
        if textOverlay != nil { return endTextEditing() }
        guard canEdit, !isPresenting, pdfView.document != nil, ensureEditable() else { return }
        let overlay = TextEditOverlay(frame: pdfView.bounds, model: self)
        overlay.autoresizingMask = [.width, .height]
        pdfView.addSubview(overlay)
        pdfView.window?.makeFirstResponder(overlay)
        textObservers = observeViewChanges { [weak overlay] in overlay?.viewChanged() }
        textOverlay = overlay
    }

    func endTextEditing() {
        guard let overlay = textOverlay else { return }
        // A field still open keeps its new text
        overlay.commitField()
        textObservers.forEach(NotificationCenter.default.removeObserver)
        textObservers = []
        overlay.removeFromSuperview()
        textOverlay = nil
        pdfView.window?.makeFirstResponder(pdfView)
    }

    /// The lines of a page that are upright on screen, read from a saved copy of the document.
    func editableLines(page index: Int) -> [EditableLine] {
        guard let source = textSource ?? pdfView.document?.dataRepresentation().flatMap(PDFDocument.init(data:)) else { return [] }
        textSource = source
        guard let page = source.page(at: index), let pageRef = page.pageRef else { return [] }
        let text = PageText(page: pageRef)
        let lines = TextContent.read(text.bytes, fonts: text.font).lines
        return lines.enumerated().compactMap { offset, line in
            guard ((line.angle - page.rotation) % 360 + 360) % 360 == 0 else { return nil }
            // Spaces as pdf.js gives them in the Windows app: one between words
            let string = (page.selection(for: line.band)?.string ?? "")
                .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
            return EditableLine(index: offset, line: line, text: string)
        }
    }

    /// Takes line `lineIndex` of the page out and writes `text` in its place, in the closest standard font,
    /// at its size and in its color.
    func replaceLine(page index: Int, lineIndex: Int, with text: String) {
        applyEdit(pageAfter: index + 1, duringTextEditing: true) { doc in
            // The same letters as in the Windows app, whose standard fonts write only these
            guard text.canBeConverted(to: .windowsCP1252) else {
                throw EditError(title: "The text can't be written", detail: "It has letters that the standard fonts can't write.")
            }
            let failed = EditError(title: "Edit failed", detail: "The page can't be drawn.")
            guard let old = doc.page(at: index), let data = doc.dataRepresentation(),
                  let source = PDFDocument(data: data), let pageRef = source.page(at: index)?.pageRef else { throw failed }
            let content = PageText(page: pageRef)
            let (ops, lines) = TextContent.read(content.bytes, fonts: content.font)
            guard lines.indices.contains(lineIndex) else { throw failed }
            let line = lines[lineIndex]
            // The old content stays as it was drawn, whatever it leaves changed
            let newContent = Array("q\n".utf8) + TextContent.removing(line, ops: ops, from: content.bytes) + Array("\nQ\n".utf8)
            guard let written = try? PageWriter.page(pageRef, contents: newContent), let writtenPage = written.page(at: 1),
                  let new = PageImage.drawnPage(box: old.bounds(for: .mediaBox), cropBox: old.bounds(for: .cropBox), draw: { context in
                      context.drawPDFPage(writtenPage)
                      Self.draw(text, like: line, in: context)
                  })
            else { throw failed }
            Self.replacePage(at: index, in: doc, with: new)
        }
        textSource = nil
    }

    private static func draw(_ text: String, like line: TextLine, in context: CGContext) {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let font = CTFontCreateWithName(TextContent.standardFont(line.font) as CFString, line.size, nil)
        let color = CGColor(srgbRed: line.color[0], green: line.color[1], blue: line.color[2], alpha: 1)
        let string = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ])
        context.saveGState()
        context.translateBy(x: line.start.x, y: line.start.y)
        context.rotate(by: CGFloat(line.angle) * .pi / 180)
        context.textMatrix = .identity
        context.textPosition = .zero
        CTLineDraw(CTLineCreateWithAttributedString(string), context)
        context.restoreGState()
    }
}

/// A line that can be edited: its index among the page's lines and its text as PDFKit reads it.
struct EditableLine {
    let index: Int
    let line: TextLine
    let text: String
}

/// Lies over the PDF view while text is edited: shows the line under the pointer, and a click opens a field
/// over it. Return (or a click elsewhere) keeps the new text, Esc closes the field, Esc again ends editing.
final class TextEditOverlay: NSView, NSTextFieldDelegate {
    private weak var model: PDFViewModel?
    private var lines: [Int: [EditableLine]] = [:]
    private var hovered: (page: PDFPage, line: EditableLine)?
    private var field: (page: PDFPage, line: EditableLine, view: NSTextField)?

    init(frame: NSRect, model: PDFViewModel) {
        self.model = model
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var pdfView: PDFView? { model?.pdfView }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .iBeam)
    }

    /// The view scrolled or zoomed: the field and the highlight follow their page.
    func viewChanged() {
        if let field { field.view.frame = fieldFrame(field.line, on: field.page, font: field.view.font) }
        needsDisplay = true
    }

    // Scrolling and zooming still move the pages underneath; no page menu while editing
    override func scrollWheel(with event: NSEvent) {
        pdfView?.documentView?.enclosingScrollView?.scrollWheel(with: event)
    }

    override func magnify(with event: NSEvent) {
        pdfView?.magnify(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {}

    override func cancelOperation(_ sender: Any?) {
        model?.endTextEditing()
    }

    // MARK: Lines

    private func line(at event: NSEvent) -> (page: PDFPage, line: EditableLine)? {
        guard let pdfView, let model, let doc = pdfView.document else { return nil }
        let point = convert(convert(event.locationInWindow, from: nil), to: pdfView)
        guard let page = pdfView.page(for: point, nearest: false) else { return nil }
        let index = doc.index(for: page)
        if lines[index] == nil { lines[index] = model.editableLines(page: index) }
        let inPage = pdfView.convert(point, to: page)
        return lines[index]?.first { $0.line.rect.contains(inPage) }.map { (page, $0) }
    }

    /// The document changed: lines are read again.
    func documentChanged() {
        lines = [:]
        hovered = nil
        needsDisplay = true
    }

    private func viewRect(_ rect: CGRect, on page: PDFPage) -> CGRect {
        guard let pdfView else { return .zero }
        return convert(pdfView.convert(rect, from: page), from: pdfView).standardized
    }

    override func mouseMoved(with event: NSEvent) {
        let found = line(at: event)
        if found?.line.index != hovered?.line.index || found?.page != hovered?.page {
            hovered = found
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let found = line(at: event)
        // A click beside the lines puts the new text of an open field in place
        guard let found else { return commitField() }
        if let field, field.page == found.page, field.line.index == found.line.index { return }
        commitField()
        // The edit read the page again
        guard let fresh = line(at: event) else { return }
        openField(fresh.line, on: fresh.page)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let hovered, field?.line.index != hovered.line.index || field?.page != hovered.page else { return }
        let rect = viewRect(hovered.line.line.rect, on: hovered.page)
        NSColor.controlAccentColor.withAlphaComponent(0.1).setFill()
        NSColor.controlAccentColor.setStroke()
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: -1, dy: -1), xRadius: 2, yRadius: 2)
        path.fill()
        path.stroke()
    }

    // MARK: Field

    private func openField(_ line: EditableLine, on page: PDFPage) {
        guard let pdfView else { return }
        let font = NSFont(name: TextContent.standardFont(line.line.font), size: line.line.size * pdfView.scaleFactor)
            ?? .systemFont(ofSize: line.line.size * pdfView.scaleFactor)
        let view = NSTextField(string: line.text)
        view.font = font
        view.textColor = NSColor(srgbRed: line.line.color[0], green: line.line.color[1], blue: line.line.color[2], alpha: 1)
        view.isBordered = false
        view.focusRingType = .none
        view.drawsBackground = true
        view.backgroundColor = .white
        view.wantsLayer = true
        view.layer?.borderColor = NSColor.controlAccentColor.cgColor
        view.layer?.borderWidth = 2
        view.layer?.cornerRadius = 2
        view.cell?.usesSingleLineMode = true
        view.cell?.isScrollable = true
        view.delegate = self
        view.frame = fieldFrame(line, on: page, font: font)
        addSubview(view)
        field = (page, line, view)
        needsDisplay = true
        window?.makeFirstResponder(view)
        view.currentEditor()?.selectAll(nil)
    }

    /// Over the line, as tall as its letters, and as wide as its text (never narrower than the line).
    private func fieldFrame(_ line: EditableLine, on page: PDFPage, font: NSFont?) -> CGRect {
        let rect = viewRect(line.line.rect, on: page)
        let text = field?.view.stringValue ?? line.text
        let width = (text as NSString).size(withAttributes: [.font: font as Any]).width + (font?.pointSize ?? 12)
        return CGRect(x: rect.minX, y: rect.minY, width: max(rect.width, width), height: rect.height)
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field else { return }
        field.view.frame = fieldFrame(field.line, on: field.page, font: field.view.font)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            commitField()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            closeField()
            return true
        default:
            return false
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        commitField()
    }

    /// Puts the new text in place when it changed, and closes the field.
    func commitField() {
        guard let field, let doc = pdfView?.document else { return }
        let text = field.view.stringValue
        let index = doc.index(for: field.page)
        closeField()
        guard text != field.line.text, index != NSNotFound else { return }
        model?.replaceLine(page: index, lineIndex: field.line.index, with: text)
        documentChanged()
    }

    private func closeField() {
        guard let current = field else { return }
        field = nil
        current.view.delegate = nil
        current.view.removeFromSuperview()
        window?.makeFirstResponder(self)
        needsDisplay = true
    }
}
