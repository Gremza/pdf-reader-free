import AppKit
import PDFKit

// MARK: - Draw Shapes

/// The shapes of "Draw Shapes": borders only, to point at something on a page.
enum ShapeKind: String, CaseIterable, Identifiable {
    case line, arrow, rectangle, oval

    var id: Self { self }
    var title: String { rawValue.capitalized }

    var systemImage: String {
        switch self {
        case .line: "line.diagonal"
        case .arrow: "arrow.up.right"
        case .rectangle: "rectangle"
        case .oval: "oval"
        }
    }
}

/// The same colors as in the Windows app.
enum ShapeColor: String, CaseIterable, Identifiable {
    case red, orange, yellow, green, blue, black

    var id: Self { self }
    var title: String { rawValue.capitalized }

    var cgColor: CGColor {
        let hex: Int = switch self {
        case .red: 0xE53935
        case .orange: 0xFB8C00
        case .yellow: 0xFDD835
        case .green: 0x43A047
        case .blue: 0x1E88E5
        case .black: 0x000000
        }
        return CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                       blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// Line widths in points.
enum ShapeWidth: CGFloat, CaseIterable, Identifiable {
    case thin = 1, medium = 2, thick = 4

    var id: Self { self }

    var title: String {
        switch self {
        case .thin: "Thin"
        case .medium: "Medium"
        case .thick: "Thick"
        }
    }
}

/// A shape drawn on a page but not yet part of it.
struct DrawnShape {
    var kind: ShapeKind
    /// The ends of a line or arrow, or two opposite corners, in the page's user space.
    var start: CGPoint
    var end: CGPoint
    var color: ShapeColor
    var width: ShapeWidth
    let page: PDFPage

    var rect: CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
    }

    /// The outline, in the page's user space. The arrowhead grows with the line width, as in the Windows app.
    var path: CGPath {
        let path = CGMutablePath()
        switch kind {
        case .line:
            path.move(to: start)
            path.addLine(to: end)
        case .arrow:
            path.move(to: start)
            path.addLine(to: end)
            let angle = atan2(end.y - start.y, end.x - start.x)
            let length = 4 * width.rawValue + 6
            let tip = { (side: CGFloat) in
                CGPoint(x: end.x + length * cos(angle + .pi + side * .pi / 6), y: end.y + length * sin(angle + .pi + side * .pi / 6))
            }
            path.move(to: tip(-1))
            path.addLine(to: end)
            path.addLine(to: tip(1))
        case .rectangle:
            path.addRect(rect)
        case .oval:
            path.addEllipse(in: rect)
        }
        return path
    }

    /// Strokes the shape; `transform` maps the page's user space into the context, `scale` is its zoom.
    func stroke(in context: CGContext, transform: CGAffineTransform = .identity, scale: CGFloat = 1) {
        var transform = transform
        guard let path = path.copy(using: &transform) else { return }
        context.saveGState()
        context.addPath(path)
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(width.rawValue * scale)
        context.setLineCap(.round)
        context.setLineJoin(kind == .rectangle ? .miter : .round)
        context.strokePath()
        context.restoreGState()
    }

    /// How far `point` is from the outline, in page space.
    func distance(to point: CGPoint) -> CGFloat {
        let r = rect
        switch kind {
        case .line, .arrow:
            return Self.distance(from: point, toSegment: start, end)
        case .rectangle:
            if r.contains(point) {
                return min(point.x - r.minX, r.maxX - point.x, point.y - r.minY, r.maxY - point.y)
            }
            return hypot(max(r.minX - point.x, 0, point.x - r.maxX), max(r.minY - point.y, 0, point.y - r.maxY))
        case .oval:
            let rx = r.width / 2, ry = r.height / 2
            guard rx > 0, ry > 0 else { return Self.distance(from: point, toSegment: start, end) }
            let d = hypot((point.x - r.midX) / rx, (point.y - r.midY) / ry)
            return abs(d - 1) * min(rx, ry)
        }
    }

    /// The points that reshape it: the two ends, or the four corners.
    var handles: [CGPoint] {
        switch kind {
        case .line, .arrow: [start, end]
        case .rectangle, .oval: ImagePlacementView.corners(of: rect)
        }
    }

    /// Moves handle `index` to `point`; with Shift, lines keep to 45° steps and the others stay square or round.
    mutating func reshape(handle index: Int, to point: CGPoint, constrained: Bool) {
        switch kind {
        case .line, .arrow:
            if index == 0 {
                start = constrained ? Self.constrain(point, from: end, kind: kind) : point
            } else {
                end = constrained ? Self.constrain(point, from: start, kind: kind) : point
            }
        case .rectangle, .oval:
            let r = rect
            let corner = handles[index]
            let fixed = CGPoint(x: r.minX + r.maxX - corner.x, y: r.minY + r.maxY - corner.y)
            start = fixed
            end = constrained ? Self.constrain(point, from: fixed, kind: kind) : point
        }
    }

    static func constrain(_ point: CGPoint, from anchor: CGPoint, kind: ShapeKind) -> CGPoint {
        let dx = point.x - anchor.x, dy = point.y - anchor.y
        switch kind {
        case .line, .arrow:
            let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * .pi / 4
            let length = hypot(dx, dy)
            return CGPoint(x: anchor.x + length * cos(angle), y: anchor.y + length * sin(angle))
        case .rectangle, .oval:
            let side = max(abs(dx), abs(dy))
            return CGPoint(x: anchor.x + (dx < 0 ? -side : side), y: anchor.y + (dy < 0 ? -side : side))
        }
    }

    private static func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        let t = lengthSquared == 0 ? 0 : min(max(((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared, 0), 1)
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
}

extension PDFViewModel {
    /// Shapes are drawn over the pages and become part of them with Done; choosing it again is Done too.
    func drawShapes() {
        if shapeOverlay != nil { return finishShapes() }
        guard canEdit, !isPresenting, pdfView.document != nil, ensureEditable() else { return }
        let overlay = ShapeOverlay(frame: pdfView.bounds, pdfView: pdfView)
        overlay.autoresizingMask = [.width, .height]
        overlay.onCancel = { [weak self] in self?.cancelShapes() }
        pdfView.addSubview(overlay)
        pdfView.window?.makeFirstResponder(overlay)
        shapeObservers = observeViewChanges { [weak overlay] in overlay?.needsDisplay = true }
        shapeOverlay = overlay
    }

    /// Draws the shapes into their pages, as one edit that can be undone.
    func finishShapes() {
        guard let overlay = shapeOverlay, let doc = pdfView.document else { return }
        let pages = Dictionary(grouping: overlay.shapes) { doc.index(for: $0.page) }.filter { $0.key != NSNotFound }
        endShapes()
        guard !pages.isEmpty else { return }
        applyEdit(pageAfter: currentPage) { doc in
            // The pages are drawn from a saved copy, which has the content of every earlier edit
            guard let data = doc.dataRepresentation(), let source = PDFDocument(data: data) else {
                throw EditError(title: "The shapes can't be added", detail: "The page can't be drawn.")
            }
            for (index, shapes) in pages {
                guard let old = doc.page(at: index), let pageRef = source.page(at: index)?.pageRef,
                      let new = PageImage.drawnPage(box: old.bounds(for: .mediaBox), cropBox: old.bounds(for: .cropBox), draw: { context in
                          context.drawPDFPage(pageRef)
                          for shape in shapes { shape.stroke(in: context) }
                      })
                else { throw EditError(title: "The shapes can't be added", detail: "The page can't be drawn.") }
                Self.replacePage(at: index, in: doc, with: new)
            }
        }
    }

    /// Takes the shapes away without drawing them.
    func cancelShapes() {
        endShapes()
    }

    private func endShapes() {
        guard let overlay = shapeOverlay else { return }
        shapeObservers.forEach(NotificationCenter.default.removeObserver)
        shapeObservers = []
        overlay.removeFromSuperview()
        shapeOverlay = nil
        pdfView.window?.makeFirstResponder(pdfView)
    }
}

/// Lies over the PDF view while shapes are drawn. Dragging on a page draws a shape with the chosen tool;
/// clicking a shape selects it: dragging moves it, its handles reshape it, the color and width change it, Delete removes it.
final class ShapeOverlay: NSView, ObservableObject {
    // The choices of the last drawing, for the next one
    private static var lastKind = ShapeKind.rectangle
    private static var lastColor = ShapeColor.red
    private static var lastWidth = ShapeWidth.medium

    @Published var kind = ShapeOverlay.lastKind {
        didSet { Self.lastKind = kind; focus() }
    }
    /// Also changes the selected shape.
    @Published var color = ShapeOverlay.lastColor {
        didSet { Self.lastColor = color; changeSelected { $0.color = color } }
    }
    @Published var width = ShapeOverlay.lastWidth {
        didSet { Self.lastWidth = width; changeSelected { $0.width = width } }
    }

    private(set) var shapes: [DrawnShape] = []
    var onCancel: (() -> Void)?
    private weak var pdfView: PDFView?
    private var selected: Int? {
        didSet { needsDisplay = true }
    }
    private var drag: Drag?

    private enum Drag {
        case draw
        case move(last: CGPoint)
        case reshape(handle: Int)
    }

    /// Distances in points on screen, the same at every zoom.
    private static let handleRadius: CGFloat = 6
    private static let grabDistance: CGFloat = 6

    init(frame: NSRect, pdfView: PDFView) {
        self.pdfView = pdfView
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }

    private func focus() {
        window?.makeFirstResponder(self)
    }

    private func changeSelected(_ change: (inout DrawnShape) -> Void) {
        if let selected { change(&shapes[selected]) }
        needsDisplay = true
        focus()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    override func keyDown(with event: NSEvent) {
        // Delete and forward delete remove the selected shape
        if [51, 117].contains(event.keyCode), let index = selected {
            shapes.remove(at: index)
            selected = nil
        } else {
            super.keyDown(with: event)
        }
    }

    // Scrolling and zooming still move the pages underneath
    override func scrollWheel(with event: NSEvent) {
        pdfView?.documentView?.enclosingScrollView?.scrollWheel(with: event)
    }

    override func magnify(with event: NSEvent) {
        pdfView?.magnify(with: event)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // No page menu while drawing, as on Windows
    override func rightMouseDown(with event: NSEvent) {}

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        focus()
        guard let pdfView else { return }
        let inView = convert(event.locationInWindow, from: nil)
        // Handles are found on screen, so they are as easy to grab at every zoom
        if let index = selected,
           let handle = shapes[index].handles.firstIndex(where: { distance(viewPoint($0, on: shapes[index].page), inView) <= Self.handleRadius + 2 }) {
            drag = .reshape(handle: handle)
            return
        }
        guard let page = pdfView.page(for: convert(inView, to: pdfView), nearest: false) else {
            selected = nil
            return
        }
        let point = pagePoint(inView, on: page)
        let tolerance = Self.grabDistance / pdfView.scaleFactor
        // The shape drawn last is on top
        if let index = shapes.indices.last(where: {
            shapes[$0].page == page && shapes[$0].distance(to: point) <= tolerance + shapes[$0].width.rawValue / 2
        }) {
            selected = index
            drag = .move(last: point)
            NSCursor.closedHand.push()
            return
        }
        shapes.append(DrawnShape(kind: kind, start: point, end: point, color: color, width: width, page: page))
        selected = shapes.count - 1
        drag = .draw
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag, let index = selected else { return }
        let page = shapes[index].page
        let point = pagePoint(convert(event.locationInWindow, from: nil), on: page)
        let shift = event.modifierFlags.contains(.shift)
        switch drag {
        case .draw:
            // The drag starts at `start`, which stays where it is
            let start = shapes[index].start
            shapes[index].end = shift ? DrawnShape.constrain(point, from: start, kind: shapes[index].kind) : point
        case .move(let last):
            // The whole shape stays on its page
            let box = page.bounds(for: .cropBox), r = shapes[index].rect
            let dx = min(max(point.x - last.x, box.minX - r.minX), box.maxX - r.maxX)
            let dy = min(max(point.y - last.y, box.minY - r.minY), box.maxY - r.maxY)
            shapes[index].start.x += dx
            shapes[index].start.y += dy
            shapes[index].end.x += dx
            shapes[index].end.y += dy
            self.drag = .move(last: CGPoint(x: last.x + dx, y: last.y + dy))
        case .reshape(let handle):
            shapes[index].reshape(handle: handle, to: point, constrained: shift)
            // A rectangle's corners are renumbered when it turns inside out; keep dragging the same one
            if let nearest = shapes[index].handles.indices.min(by: {
                distance(shapes[index].handles[$0], point) < distance(shapes[index].handles[$1], point)
            }) {
                self.drag = .reshape(handle: nearest)
            }
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { drag = nil }
        switch drag {
        case .move: NSCursor.pop()
        case .draw:
            // A click without a drag draws nothing
            if let index = selected, let pdfView,
               distance(shapes[index].start, shapes[index].end) * pdfView.scaleFactor < 3 {
                shapes.remove(at: index)
            }
            // A color chosen next is for the next shape; clicking a shape selects it to change it
            selected = nil
        default: break
        }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let pdfView, let context = NSGraphicsContext.current?.cgContext else { return }
        let visible = pdfView.visiblePages
        for (index, shape) in shapes.enumerated() where visible.contains(shape.page) {
            context.saveGState()
            context.clip(to: convert(pdfView.convert(shape.page.bounds(for: pdfView.displayBox), from: shape.page), from: pdfView))
            shape.stroke(in: context, transform: transform(for: shape.page), scale: pdfView.scaleFactor)
            context.restoreGState()
            guard index == selected else { continue }
            NSColor.controlAccentColor.setFill()
            NSColor.white.setStroke()
            for handle in shape.handles {
                let point = viewPoint(handle, on: shape.page)
                let square = NSBezierPath(rect: CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8))
                square.fill()
                square.stroke()
            }
        }
    }

    /// Maps the page's user space into this view.
    private func transform(for page: PDFPage) -> CGAffineTransform {
        let origin = viewPoint(.zero, on: page)
        let x = viewPoint(CGPoint(x: 100, y: 0), on: page), y = viewPoint(CGPoint(x: 0, y: 100), on: page)
        return CGAffineTransform(a: (x.x - origin.x) / 100, b: (x.y - origin.y) / 100,
                                 c: (y.x - origin.x) / 100, d: (y.y - origin.y) / 100, tx: origin.x, ty: origin.y)
    }

    private func viewPoint(_ point: CGPoint, on page: PDFPage) -> CGPoint {
        guard let pdfView else { return point }
        return convert(pdfView.convert(point, from: page), from: pdfView)
    }

    /// A point of this view in the page's user space, kept on the page.
    private func pagePoint(_ point: CGPoint, on page: PDFPage) -> CGPoint {
        guard let pdfView else { return point }
        let p = pdfView.convert(convert(point, to: pdfView), to: page)
        let box = page.bounds(for: .cropBox)
        return CGPoint(x: min(max(p.x, box.minX), box.maxX), y: min(max(p.y, box.minY), box.maxY))
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }
}
