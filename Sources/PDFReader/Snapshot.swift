import AppKit
import PDFKit

// MARK: - Take a Snapshot

extension PDFViewModel {
    /// Snapshots are rendered at 300 DPI, but never larger than this many pixels on a side.
    nonisolated private static let snapshotMaxSide: CGFloat = 6000

    /// Like Acrobat's "Take a Snapshot": the pointer becomes a crosshair, and the part of a page dragged over
    /// is copied to the clipboard and saved as a JPG. Choosing it again, or Esc, cancels.
    func takeSnapshot() {
        if isTakingSnapshot { return endSnapshot() }
        guard canEdit, !isPresenting, pdfView.document != nil else { return }
        let overlay = SnapshotOverlay(frame: pdfView.bounds, pdfView: pdfView)
        overlay.autoresizingMask = [.width, .height]
        overlay.onSelect = { [weak self] page, region in self?.saveSnapshot(of: page, region: region) }
        overlay.onCancel = { [weak self] in self?.endSnapshot() }
        pdfView.addSubview(overlay)
        pdfView.window?.makeFirstResponder(overlay)
        isTakingSnapshot = true
    }

    func endSnapshot() {
        guard isTakingSnapshot else { return }
        pdfView.subviews.filter { $0 is SnapshotOverlay }.forEach { $0.removeFromSuperview() }
        isTakingSnapshot = false
        pdfView.window?.makeFirstResponder(pdfView)
    }

    /// `region` is in page space; the image shows it upright, the way it is on screen.
    private func saveSnapshot(of page: PDFPage, region: CGRect) {
        endSnapshot()
        guard let doc = pdfView.document, let copy = page.copy() as? PDFPage else { return }
        let number = doc.index(for: page) + 1
        let scale = min(300.0 / 72, Self.snapshotMaxSide / max(region.width, region.height, 1))
        let data: Data
        do {
            data = try Self.jpegData(for: copy, region: region, scale: scale)
        } catch {
            showError("Export failed", error.localizedDescription)
            return
        }
        if let image = NSImage(data: data) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([image])
        }
        guard let target = askSaveURL(name: "\(baseName) (page \(number)).jpg", type: .jpeg, message: "Save Snapshot as JPG")
        else { return }
        write(data, to: target)
    }

    // MARK: Right-click menu

    /// Shown above PDFKit's own items when the page is right-clicked.
    func contextMenuItems() -> [NSMenuItem] {
        [
            MenuAction.item("Take a Snapshot", systemImage: "camera", enabled: canEdit, run: takeSnapshot),
            MenuAction.item("Recognize Text", enabled: canEdit, run: recognizeText),
        ]
    }
}

/// Runs a closure from an AppKit menu item; the item keeps it alive.
private final class MenuAction: NSObject {
    private let run: () -> Void

    private init(_ run: @escaping () -> Void) {
        self.run = run
    }

    @objc private func runAction() { run() }

    @MainActor
    static func item(_ title: String, systemImage: String? = nil, enabled: Bool, run: @escaping () -> Void) -> NSMenuItem {
        let action = MenuAction(run)
        // Without an action, the menu shows the item disabled
        let item = NSMenuItem(title: title, action: enabled ? #selector(runAction) : nil, keyEquivalent: "")
        item.target = action
        item.representedObject = action
        if let systemImage { item.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil) }
        return item
    }
}

/// Lies over the PDF view while a snapshot is taken: a crosshair, and the rectangle being dragged,
/// kept within the page where the drag started.
final class SnapshotOverlay: NSView {
    private weak var pdfView: PDFView?
    /// The page and the dragged part of it, in page space.
    var onSelect: ((PDFPage, CGRect) -> Void)?
    var onCancel: (() -> Void)?

    private var page: PDFPage?
    private var pageFrame = NSRect.zero
    private var start = NSPoint.zero
    private var selection: NSRect? {
        didSet { needsDisplay = true }
    }

    init(frame: NSRect, pdfView: PDFView) {
        self.pdfView = pdfView
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    // Scrolling and zooming still move the pages underneath
    override func scrollWheel(with event: NSEvent) {
        pdfView?.documentView?.enclosingScrollView?.scrollWheel(with: event)
    }

    override func magnify(with event: NSEvent) {
        pdfView?.magnify(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        selection = nil
        page = nil
        guard let pdfView else { return }
        let point = convert(event.locationInWindow, from: nil)
        // A drag that starts beside the pages takes nothing
        guard let page = pdfView.page(for: convert(point, to: pdfView), nearest: false) else { return }
        self.page = page
        pageFrame = convert(Self.rect(pdfView.convert(page.bounds(for: pdfView.displayBox), from: page)), from: pdfView)
        start = point
    }

    override func mouseDragged(with event: NSEvent) {
        guard page != nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        selection = NSRect(x: min(start.x, point.x), y: min(start.y, point.y),
                           width: abs(point.x - start.x), height: abs(point.y - start.y))
            .intersection(pageFrame)
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            page = nil
            selection = nil
        }
        // A click without a drag keeps waiting for one
        guard let page, let pdfView, let selection, selection.width >= 4, selection.height >= 4 else { return }
        let region = Self.rect(pdfView.convert(convert(selection, to: pdfView), to: page))
        onSelect?(page, region)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let selection else { return }
        NSColor.controlAccentColor.withAlphaComponent(0.15).setFill()
        selection.fill()
        NSColor.controlAccentColor.setStroke()
        let border = NSBezierPath(rect: selection.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1
        border.stroke()
    }

    /// A rectangle with a positive width and height, whichever way a rotated page turned it.
    private static func rect(_ rect: NSRect) -> NSRect {
        rect.standardized
    }
}
