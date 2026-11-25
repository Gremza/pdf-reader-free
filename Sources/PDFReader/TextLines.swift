import CoreGraphics
import CoreText
import Foundation

// MARK: - Edit Text: lines of a page

/// What the lines need of a font: its widths (in em), name and flags.
struct LineFont {
    let composite: Bool
    let baseFont: String
    let flags: Int
    let width: (Int) -> CGFloat
}

/// An operator of a content stream with its operands and where it is.
struct ContentOp {
    enum Operand {
        case number(CGFloat)
        case string([UInt8])
        case name(String)
        case array([Operand])
        case other

        var number: CGFloat? { if case .number(let n) = self { n } else { nil } }
        var bytes: [UInt8]? { if case .string(let s) = self { s } else { nil } }
    }

    let op: String
    let operands: [Operand]
    let range: Range<Int>
}

/// A piece of text shown by one operator (or one part of a TJ array, between wide gaps).
struct TextRun {
    let op: Int
    /// The part of a TJ array; nil for Tj, ' and ".
    let elements: Range<Int>?
    /// All of it in unscaled text space, for taking it out.
    let advance: CGFloat
    /// On the baseline in user space, without spaces at the end.
    let start: CGPoint
    let end: CGPoint
    let size: CGFloat
    var angle: CGFloat
    let mirrored: Bool
    let invisible: Bool
    let color: [CGFloat]
    let font: LineFont?
    let tfs: CGFloat
    let th: CGFloat
    var along: CGFloat = 0
    var alongEnd: CGFloat = 0
    var offset: CGFloat = 0
}

/// The text shown on one baseline without a wide gap.
struct TextLine {
    /// The rectangle around `points` moved from `low` to `high` along `v`.
    static func bounds(of points: [CGPoint], from v: CGPoint, low: CGFloat, high: CGFloat) -> CGRect {
        var rect = CGRect.null
        for p in points {
            rect = rect.union(CGRect(x: p.x + v.x * low, y: p.y + v.y * low, width: 0, height: 0))
            rect = rect.union(CGRect(x: p.x + v.x * high, y: p.y + v.y * high, width: 0, height: 0))
        }
        return rect
    }

    let runs: [TextRun]
    /// Counterclockwise, a multiple of 90.
    let angle: Int
    let start: CGPoint
    let end: CGPoint
    let size: CGFloat
    let color: [CGFloat]
    let font: LineFont?
    let rect: CGRect

    /// The middle of the line's height, where its letters are, in user space.
    var band: CGRect {
        let rad = CGFloat(angle) * .pi / 180
        let v = CGPoint(x: -sin(rad), y: cos(rad))
        return Self.bounds(of: [start, end], from: v, low: 0.15 * size, high: 0.55 * size)
    }
}

/// Reads the lines of a page from its content stream, and takes one out. Text inside forms, invisible text
/// (as Recognize Text adds) and turned or mirrored text are left alone. The same reading as `textlines.js`.
enum TextContent {
    // MARK: Tokens

    private static let whitespace: Set<UInt8> = [0, 9, 10, 12, 13, 32]
    private static let delimiters = Set("()<>[]{}/%".utf8)

    private static func isRegular(_ b: UInt8) -> Bool { !whitespace.contains(b) && !delimiters.contains(b) }

    static func parse(_ bytes: [UInt8]) -> [ContentOp] {
        var ops: [ContentOp] = []
        var operands: [ContentOp.Operand] = []
        var start = -1
        var stack: [[ContentOp.Operand]] = []
        var i = 0
        let n = bytes.count

        func push(_ value: ContentOp.Operand, at: Int) {
            if !stack.isEmpty {
                stack[stack.count - 1].append(value)
            } else {
                if start < 0 { start = at }
                operands.append(value)
            }
        }

        while i < n {
            let c = bytes[i]
            if whitespace.contains(c) {
                i += 1
            } else if c == 0x25 { // % comment
                while i < n, bytes[i] != 10, bytes[i] != 13 { i += 1 }
            } else if c == 0x28 { // ( literal string
                let at = i
                var out: [UInt8] = []
                var depth = 1
                i += 1
                while i < n, depth > 0 {
                    let b = bytes[i]
                    i += 1
                    if b == 0x5C, i < n {
                        let e = bytes[i]
                        i += 1
                        switch e {
                        case 0x6E: out.append(10)
                        case 0x72: out.append(13)
                        case 0x74: out.append(9)
                        case 0x62: out.append(8)
                        case 0x66: out.append(12)
                        case 0x30...0x37:
                            var value = Int(e - 0x30)
                            var k = 0
                            while k < 2, i < n, (0x30...0x37).contains(bytes[i]) {
                                value = value * 8 + Int(bytes[i] - 0x30)
                                i += 1
                                k += 1
                            }
                            out.append(UInt8(value & 0xFF))
                        case 13: if i < n, bytes[i] == 10 { i += 1 }
                        case 10: break
                        default: out.append(e)
                        }
                    } else if b == 0x28 {
                        depth += 1
                        out.append(b)
                    } else if b == 0x29 {
                        depth -= 1
                        if depth > 0 { out.append(b) }
                    } else {
                        out.append(b)
                    }
                }
                push(.string(out), at: at)
            } else if c == 0x3C, i + 1 < n, bytes[i + 1] == 0x3C { // << dictionary
                let at = i
                i = skipDictionary(bytes, from: i)
                push(.other, at: at)
            } else if c == 0x3C { // <hex string>
                let at = i
                var digits: [UInt8] = []
                i += 1
                while i < n, bytes[i] != 0x3E {
                    if let h = hexValue(bytes[i]) { digits.append(h) }
                    i += 1
                }
                i += 1
                if digits.count % 2 == 1 { digits.append(0) }
                push(.string(stride(from: 0, to: digits.count, by: 2).map { digits[$0] * 16 + digits[$0 + 1] }), at: at)
            } else if c == 0x5B { // [
                if stack.isEmpty, start < 0 { start = i }
                stack.append([])
                i += 1
            } else if c == 0x5D { // ]
                i += 1
                if let array = stack.popLast() { push(.array(array), at: i) }
            } else if c == 0x2F { // /name
                let at = i
                i += 1
                let from = i
                while i < n, isRegular(bytes[i]) { i += 1 }
                push(.name(String(decoding: bytes[from..<i], as: UTF8.self)), at: at)
            } else if c == 0x7B || c == 0x7D || c == 0x3E || c == 0x29 {
                i += 1
            } else {
                let at = i
                while i < n, isRegular(bytes[i]) { i += 1 }
                let word = String(decoding: bytes[at..<i], as: UTF8.self)
                if let number = Double(word), word.range(of: #"^[+-]?(\d+\.?\d*|\.\d+)$"#, options: .regularExpression) != nil {
                    push(.number(CGFloat(number)), at: at)
                } else if !stack.isEmpty || ["true", "false", "null"].contains(word) {
                    push(.other, at: at)
                } else {
                    ops.append(ContentOp(op: word, operands: operands, range: (start < 0 ? at : start)..<i))
                    operands = []
                    start = -1
                    // An inline image: its data runs to EI
                    if word == "ID" { i = skipInlineImage(bytes, from: i) }
                }
            }
        }
        return ops
    }

    private static func hexValue(_ b: UInt8) -> UInt8? {
        switch b {
        case 0x30...0x39: b - 0x30
        case 0x41...0x46: b - 0x37
        case 0x61...0x66: b - 0x57
        default: nil
        }
    }

    private static func skipDictionary(_ bytes: [UInt8], from start: Int) -> Int {
        var i = start
        var depth = 0
        while i < bytes.count {
            if bytes[i] == 0x3C, i + 1 < bytes.count, bytes[i + 1] == 0x3C {
                depth += 1
                i += 2
            } else if bytes[i] == 0x3E, i + 1 < bytes.count, bytes[i + 1] == 0x3E {
                depth -= 1
                i += 2
                if depth == 0 { return i }
            } else if bytes[i] == 0x28 {
                // A string may hold >> of its own
                var d = 0
                repeat {
                    if bytes[i] == 0x5C { i += 1 } else if bytes[i] == 0x28 { d += 1 } else if bytes[i] == 0x29 { d -= 1 }
                    i += 1
                } while i < bytes.count && d > 0
            } else {
                i += 1
            }
        }
        return i
    }

    private static func skipInlineImage(_ bytes: [UInt8], from start: Int) -> Int {
        var i = start + 1
        while i + 1 < bytes.count {
            if bytes[i] == 0x45, bytes[i + 1] == 0x49, whitespace.contains(bytes[i - 1]),
               i + 2 >= bytes.count || whitespace.contains(bytes[i + 2]) {
                return i + 2
            }
            i += 1
        }
        return bytes.count
    }

    // MARK: Lines

    private struct GraphicsState {
        var ctm = CGAffineTransform.identity
        var color: [CGFloat] = [0, 0, 0]
        var tc: CGFloat = 0, tw: CGFloat = 0, th: CGFloat = 1, tl: CGFloat = 0
        var font: LineFont?
        var size: CGFloat = 0, rise: CGFloat = 0
        var mode = 0
    }

    /// The operators of the content and its lines; `fonts` gives a font of the page's resources by name.
    static func read(_ bytes: [UInt8], fonts: (String) -> LineFont?) -> (ops: [ContentOp], lines: [TextLine]) {
        let ops = parse(bytes)
        var runs: [TextRun] = []
        var gs = GraphicsState()
        var saved: [GraphicsState] = []
        var tm = CGAffineTransform.identity
        var tlm = CGAffineTransform.identity

        func nextLine(_ tx: CGFloat, _ ty: CGFloat) {
            tlm = CGAffineTransform(translationX: tx, y: ty).concatenating(tlm)
            tm = tlm
        }

        func codes(_ str: [UInt8]) -> [Int] {
            guard gs.font?.composite == true else { return str.map(Int.init) }
            return stride(from: 0, to: str.count - 1, by: 2).map { Int(str[$0]) * 256 + Int(str[$0 + 1]) }
        }

        /// The advance of a string in unscaled text space, and where its last letter that isn't a space ends.
        func advance(of str: [UInt8]) -> (advance: CGFloat, ink: CGFloat) {
            var advance: CGFloat = 0, ink: CGFloat = 0
            for code in codes(str) {
                let space = code == 32 && gs.font?.composite != true
                let w = gs.font?.width(code) ?? 0.5
                advance += (w * gs.size + gs.tc + (space ? gs.tw : 0)) * gs.th
                if !space { ink = advance }
            }
            return (advance, ink)
        }

        func move(_ advance: CGFloat) {
            tm = CGAffineTransform(translationX: advance, y: 0).concatenating(tm)
        }

        func show(_ op: Int, _ elements: Range<Int>?, _ advance: CGFloat, _ ink: CGFloat) {
            guard ink > 0 else { return }
            let m = tm.concatenating(gs.ctm)
            let start = CGPoint(x: 0, y: gs.rise).applying(m)
            let end = CGPoint(x: 0, y: gs.rise).applying(CGAffineTransform(translationX: ink, y: 0).concatenating(tm).concatenating(gs.ctm))
            let up = CGPoint(x: m.c * gs.size, y: m.d * gs.size)
            runs.append(TextRun(
                op: op, elements: elements, advance: advance, start: start, end: end,
                size: hypot(up.x, up.y), angle: atan2(m.b, m.a) * 180 / .pi, mirrored: m.a * up.y - m.b * up.x < 0,
                invisible: gs.mode == 3 || gs.mode == 7, color: gs.color, font: gs.font, tfs: gs.size, th: gs.th))
        }

        for (index, item) in ops.enumerated() {
            let o = item.operands
            func num(_ k: Int) -> CGFloat { k < o.count ? o[k].number ?? 0 : 0 }
            switch item.op {
            case "q": saved.append(gs)
            case "Q": if let last = saved.popLast() { gs = last }
            case "cm": if o.count == 6 { gs.ctm = CGAffineTransform(a: num(0), b: num(1), c: num(2), d: num(3), tx: num(4), ty: num(5)).concatenating(gs.ctm) }
            case "BT": tm = .identity; tlm = .identity
            case "Tc": gs.tc = num(0)
            case "Tw": gs.tw = num(0)
            case "Tz": gs.th = num(0) / 100
            case "TL": gs.tl = num(0)
            case "Ts": gs.rise = num(0)
            case "Tr": gs.mode = Int(num(0))
            case "Tf":
                if case .name(let name)? = o.first { gs.font = fonts(name) } else { gs.font = nil }
                gs.size = num(1)
            case "Td": nextLine(num(0), num(1))
            case "TD": gs.tl = -num(1); nextLine(num(0), num(1))
            case "Tm":
                if o.count == 6 {
                    tm = CGAffineTransform(a: num(0), b: num(1), c: num(2), d: num(3), tx: num(4), ty: num(5))
                    tlm = tm
                }
            case "T*": nextLine(0, -gs.tl)
            case "g": gs.color = [num(0), num(0), num(0)]
            case "rg": gs.color = [num(0), num(1), num(2)]
            case "k": gs.color = cmyk(num(0), num(1), num(2), num(3))
            case "cs":
                // A new color space starts black
                if case .name(let space)? = o.first, ["DeviceGray", "DeviceRGB", "DeviceCMYK"].contains(space) { gs.color = [0, 0, 0] }
            case "sc", "scn":
                let values = o.compactMap(\.number)
                if values.count == 1 { gs.color = [values[0], values[0], values[0]] }
                else if values.count == 3 { gs.color = values }
                else if values.count == 4 { gs.color = cmyk(values[0], values[1], values[2], values[3]) }
            case "'", "\"":
                if item.op == "\"" {
                    gs.tw = num(0)
                    gs.tc = num(1)
                }
                nextLine(0, -gs.tl)
                guard let str = o.last?.bytes else { break }
                let (advance, ink) = advance(of: str)
                show(index, nil, advance, ink)
                move(advance)
            case "Tj":
                guard let str = o.first?.bytes else { break }
                let (advance, ink) = advance(of: str)
                show(index, nil, advance, ink)
                move(advance)
            case "TJ":
                guard case .array(let items)? = o.first else { break }
                // A wide gap inside the array splits it, like the columns of a table
                var first = 0
                var total: CGFloat = 0, ink: CGFloat = 0
                func flush(_ to: Int) {
                    if to > first { show(index, first..<to, total, ink) }
                    move(total)
                    total = 0
                    ink = 0
                }
                for (k, element) in items.enumerated() {
                    if let value = element.number {
                        let shift = -value / 1000 * gs.size * gs.th
                        if abs(value) >= 1500, items[first..<k].contains(where: { $0.bytes != nil }) {
                            flush(k)
                            move(shift)
                            first = k + 1
                        } else if first == k {
                            move(shift)
                            first = k + 1
                        } else {
                            total += shift
                        }
                    } else if let str = element.bytes {
                        let piece = advance(of: str)
                        if piece.ink > 0 { ink = total + piece.ink }
                        total += piece.advance
                    }
                }
                flush(items.count)
            default:
                break
            }
        }
        return (ops, groupLines(runs))
    }

    private static func cmyk(_ c: CGFloat, _ m: CGFloat, _ y: CGFloat, _ k: CGFloat) -> [CGFloat] {
        [(1 - c) * (1 - k), (1 - m) * (1 - k), (1 - y) * (1 - k)]
    }

    private static func groupLines(_ all: [TextRun]) -> [TextLine] {
        // Only upright, unmirrored, visible text, turned by a multiple of 90°
        var runs = all.filter {
            !$0.invisible && !$0.mirrored && $0.size > 0.5 && abs($0.angle - ($0.angle / 90).rounded() * 90) < 0.5
        }
        for k in runs.indices {
            let quarter = Int(((runs[k].angle / 90).rounded()))
            runs[k].angle = CGFloat(((quarter * 90) % 360 + 360) % 360)
            let rad = runs[k].angle * .pi / 180
            let u = CGPoint(x: cos(rad), y: sin(rad)), v = CGPoint(x: -u.y, y: u.x)
            runs[k].along = runs[k].start.x * u.x + runs[k].start.y * u.y
            runs[k].alongEnd = runs[k].end.x * u.x + runs[k].end.y * u.y
            runs[k].offset = runs[k].start.x * v.x + runs[k].start.y * v.y
        }
        runs.sort { ($0.angle, $0.offset, $0.along) < ($1.angle, $1.offset, $1.along) }

        // Runs on one baseline, then split where the gap is wide
        var groups: [(runs: [TextRun], alongEnd: CGFloat)] = []
        var k = 0
        while k < runs.count {
            let first = runs[k]
            var baseline: [TextRun] = []
            while k < runs.count, runs[k].angle == first.angle, runs[k].offset - first.offset <= 0.3 * first.size {
                baseline.append(runs[k])
                k += 1
            }
            baseline.sort { $0.along < $1.along }
            var current: (runs: [TextRun], along: CGFloat, alongEnd: CGFloat, size: CGFloat)?
            for run in baseline {
                if let c = current, run.along <= c.alongEnd + 1.5 * c.size, run.along >= c.along - c.size {
                    current!.runs.append(run)
                    current!.alongEnd = max(c.alongEnd, run.alongEnd)
                } else {
                    if let c = current { groups.append((c.runs, c.alongEnd)) }
                    current = ([run], run.along, run.alongEnd, run.size)
                }
            }
            if let c = current { groups.append((c.runs, c.alongEnd)) }
        }

        return groups.map { lineRuns, alongEnd in
            let first = lineRuns[0]
            let rad = first.angle * .pi / 180
            let u = CGPoint(x: cos(rad), y: sin(rad)), v = CGPoint(x: -u.y, y: u.x)
            let length = alongEnd - first.along
            let end = CGPoint(x: first.start.x + u.x * length, y: first.start.y + u.y * length)
            // Room for capitals above the baseline and descenders below
            let rect = TextLine.bounds(of: [first.start, end], from: v, low: -0.25 * first.size, high: 0.85 * first.size)
            return TextLine(runs: lineRuns, angle: Int(first.angle), start: first.start, end: end, size: first.size,
                            color: first.color, font: first.font, rect: rect)
        }
    }

    // MARK: Taking a line out

    /// The content with the text of `line` taken out. Each piece is replaced by a move of the same length,
    /// so whatever follows stays where it was.
    static func removing(_ line: TextLine, ops: [ContentOp], from bytes: [UInt8]) -> [UInt8] {
        let byOp = Dictionary(grouping: line.runs, by: \.op)
        func move(_ run: TextRun) -> String {
            format(run.tfs * run.th != 0 ? -run.advance / (run.tfs * run.th) * 1000 : 0)
        }
        let edits: [(range: Range<Int>, text: String)] = byOp.map { index, runs in
            let item = ops[index]
            let text: String
            switch item.op {
            case "TJ":
                guard case .array(let items)? = item.operands.first else { return (item.range, "") }
                var parts: [String] = []
                var k = 0
                while k < items.count {
                    if let run = runs.first(where: { $0.elements?.lowerBound == k }), let elements = run.elements {
                        parts.append(move(run))
                        k = elements.upperBound
                    } else {
                        parts.append(operand(items[k]))
                        k += 1
                    }
                }
                text = "[\(parts.joined(separator: " "))] TJ"
            case "Tj": text = "[\(move(runs[0]))] TJ"
            case "'": text = "T* [\(move(runs[0]))] TJ"
            default:
                let aw = item.operands.first?.number ?? 0, ac = item.operands.count > 1 ? item.operands[1].number ?? 0 : 0
                text = "\(format(aw)) Tw \(format(ac)) Tc T* [\(move(runs[0]))] TJ"
            }
            return (item.range, text)
        }
        var out = bytes
        for edit in edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            out.replaceSubrange(edit.range, with: Array(edit.text.utf8))
        }
        return out
    }

    private static func format(_ value: CGFloat) -> String {
        guard value.isFinite else { return "0" }
        var text = String(format: "%.3f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text == "-0" ? "0" : text
    }

    private static func operand(_ value: ContentOp.Operand) -> String {
        switch value {
        case .number(let n): format(n)
        case .string(let s): "<" + s.map { String(format: "%02x", $0) }.joined() + ">"
        default: "0"
        }
    }

    // MARK: The style of the new text

    /// The standard font closest to the line's font: Helvetica, Times or Courier, bold and italic as it is.
    static func standardFont(_ font: LineFont?) -> String {
        let name = (font?.baseFont ?? "").replacingOccurrences(of: #"^[A-Z]{6}\+"#, with: "", options: .regularExpression).lowercased()
        let flags = font?.flags ?? 0
        let matches = { (pattern: String, text: String) in text.range(of: pattern, options: .regularExpression) != nil }
        let family = matches("courier|mono|consol|monaco|menlo", name) || flags & 1 != 0 ? "Courier"
            : matches("times|georgia|garamond|cambria|minion|palatino|antiqua|roman|serif", name.replacingOccurrences(of: "sans", with: ""))
                || (flags & 2 != 0 && !name.contains("sans")) ? "Times" : "Helvetica"
        let bold = matches("bold|black|heavy|semibold|demi", name) || flags & 262_144 != 0
        let italic = matches("italic|oblique", name) || flags & 64 != 0
        if family == "Times" { return "Times-" + (bold && italic ? "BoldItalic" : bold ? "Bold" : italic ? "Italic" : "Roman") }
        return family + (bold || italic ? "-" : "") + (bold ? "Bold" : "") + (italic ? "Oblique" : "")
    }
}

// MARK: - Pages of Core Graphics

/// The content of a page, its streams one after the other, and its fonts by resource name.
final class PageText {
    let bytes: [UInt8]
    let page: CGPDFPage
    private let fontDictionary: CGPDFDictionaryRef?
    private var cache: [String: LineFont?] = [:]

    init(page: CGPDFPage) {
        self.page = page
        let stream = CGPDFContentStreamCreateWithPage(page)
        var bytes: [UInt8] = []
        if let streams = CGPDFContentStreamGetStreams(stream) {
            for k in 0..<CFArrayGetCount(streams) {
                guard let pointer = CFArrayGetValueAtIndex(streams, k) else { continue }
                var format = CGPDFDataFormat.raw
                if let data = CGPDFStreamCopyData(unsafeBitCast(pointer, to: CGPDFStreamRef.self), &format) as Data?, format == .raw {
                    bytes += data
                    bytes.append(10)
                }
            }
        }
        self.bytes = bytes
        fontDictionary = Self.resources(of: page).flatMap { PDFObjects.dictionary($0, "Font") }
    }

    /// The page's resources, which may be inherited from its parents.
    static func resources(of page: CGPDFPage) -> CGPDFDictionaryRef? {
        var node: CGPDFDictionaryRef? = page.dictionary
        for _ in 0..<32 {
            guard let current = node else { return nil }
            if let resources = PDFObjects.dictionary(current, "Resources") { return resources }
            node = PDFObjects.dictionary(current, "Parent")
        }
        return nil
    }

    func font(_ name: String) -> LineFont? {
        if let cached = cache[name] { return cached }
        let font = fontDictionary.flatMap { PDFObjects.dictionary($0, name) }.map(Self.fontInfo)
        cache[name] = font
        return font
    }

    private static let standardFonts: Set<String> = [
        "Helvetica", "Helvetica-Bold", "Helvetica-Oblique", "Helvetica-BoldOblique",
        "Times-Roman", "Times-Bold", "Times-Italic", "Times-BoldItalic",
        "Courier", "Courier-Bold", "Courier-Oblique", "Courier-BoldOblique", "Symbol", "ZapfDingbats",
    ]

    private static func fontInfo(_ dict: CGPDFDictionaryRef) -> LineFont {
        let baseFont = PDFObjects.name(dict, "BaseFont") ?? ""
        let subtype = PDFObjects.name(dict, "Subtype")

        if subtype == "Type0" {
            let descendant = PDFObjects.array(dict, "DescendantFonts").flatMap { PDFObjects.dictionary(at: 0, $0) }
            let dw = descendant.flatMap { PDFObjects.number($0, "DW") } ?? 1000
            var widths: [Int: CGFloat] = [:]
            if let w = descendant.flatMap({ PDFObjects.array($0, "W") }) {
                var k = 0
                let count = CGPDFArrayGetCount(w)
                while k < count {
                    guard let first = PDFObjects.number(at: k, w).map(Int.init) else { break }
                    if let list = PDFObjects.array(at: k + 1, w) {
                        for j in 0..<CGPDFArrayGetCount(list) { widths[first + j] = PDFObjects.number(at: j, list) ?? dw }
                        k += 2
                    } else {
                        guard let last = PDFObjects.number(at: k + 1, w).map(Int.init) else { break }
                        let value = PDFObjects.number(at: k + 2, w) ?? dw
                        if last >= first { for c in first...min(last, first + 65_535) { widths[c] = value } }
                        k += 3
                    }
                }
            }
            let flags = descendant.flatMap { PDFObjects.dictionary($0, "FontDescriptor") }.flatMap { PDFObjects.number($0, "Flags") } ?? 0
            return LineFont(composite: true, baseFont: baseFont, flags: Int(flags)) { (widths[$0] ?? dw) / 1000 }
        }

        let firstChar = Int(PDFObjects.number(dict, "FirstChar") ?? 0)
        let widths = PDFObjects.array(dict, "Widths").map { array in
            (0..<CGPDFArrayGetCount(array)).map { PDFObjects.number(at: $0, array) ?? 0 }
        }
        let descriptor = PDFObjects.dictionary(dict, "FontDescriptor")
        let flags = descriptor.flatMap { PDFObjects.number($0, "Flags") } ?? 0
        let missing = descriptor.flatMap { PDFObjects.number($0, "MissingWidth") }
        // Type 3 glyphs are measured by their font matrix
        let scale = subtype == "Type3" ? PDFObjects.array(dict, "FontMatrix").flatMap { PDFObjects.number(at: 0, $0) } ?? 0.001 : 0.001
        let standard = widths == nil && standardFonts.contains(baseFont) ? CTFontCreateWithName(baseFont as CFString, 1, nil) : nil
        return LineFont(composite: false, baseFont: baseFont, flags: Int(flags)) { code in
            if let widths, widths.indices.contains(code - firstChar) { return widths[code - firstChar] * scale }
            if let standard, let scalar = Unicode.Scalar(code) {
                var character = UniChar(scalar.value)
                var glyph = CGGlyph()
                if CTFontGetGlyphsForCharacters(standard, &character, &glyph, 1) {
                    return CGFloat(CTFontGetAdvancesForGlyphs(standard, .horizontal, &glyph, nil, 1))
                }
            }
            return missing.map { $0 * scale } ?? 0.5
        }
    }
}

/// Small helpers for reading Core Graphics PDF objects.
enum PDFObjects {
    static func dictionary(_ dict: CGPDFDictionaryRef, _ key: String) -> CGPDFDictionaryRef? {
        var value: CGPDFDictionaryRef?
        return CGPDFDictionaryGetDictionary(dict, key, &value) ? value : nil
    }

    static func array(_ dict: CGPDFDictionaryRef, _ key: String) -> CGPDFArrayRef? {
        var value: CGPDFArrayRef?
        return CGPDFDictionaryGetArray(dict, key, &value) ? value : nil
    }

    static func name(_ dict: CGPDFDictionaryRef, _ key: String) -> String? {
        var value: UnsafePointer<CChar>?
        return CGPDFDictionaryGetName(dict, key, &value) ? value.map { String(cString: $0) } : nil
    }

    static func number(_ dict: CGPDFDictionaryRef, _ key: String) -> CGFloat? {
        var value: CGPDFReal = 0
        return CGPDFDictionaryGetNumber(dict, key, &value) ? value : nil
    }

    static func dictionary(at index: Int, _ array: CGPDFArrayRef) -> CGPDFDictionaryRef? {
        var value: CGPDFDictionaryRef?
        return CGPDFArrayGetDictionary(array, index, &value) ? value : nil
    }

    static func array(at index: Int, _ array: CGPDFArrayRef) -> CGPDFArrayRef? {
        var value: CGPDFArrayRef?
        return CGPDFArrayGetArray(array, index, &value) ? value : nil
    }

    static func number(at index: Int, _ array: CGPDFArrayRef) -> CGFloat? {
        var value: CGPDFReal = 0
        return CGPDFArrayGetNumber(array, index, &value) ? value : nil
    }
}

// MARK: - A page with new content

/// Writes a one-page PDF with the page's boxes and resources and new content, so the page can be drawn
/// without the text that was taken out. PDFKit can't change a page's content, so the resources are written
/// again from Core Graphics' own reading; their streams go in as Core Graphics decodes them.
enum PageWriter {
    struct WriteError: Error {}

    static func page(_ page: CGPDFPage, contents: [UInt8]) throws -> CGPDFDocument {
        var writer = Writer()
        let resources = try PageText.resources(of: page).map { try writer.dictionaryReference($0) } ?? "<<>>"
        let media = page.getBoxRect(.mediaBox), crop = page.getBoxRect(.cropBox)
        let box = { (r: CGRect) in "[\(r.minX) \(r.minY) \(r.maxX) \(r.maxY)]" }
        let contentsNumber = writer.add(stream: "<< /Length \(contents.count) >>", data: contents)
        let pageNumber = writer.reserve()
        let pagesNumber = writer.reserve()
        writer.set(pageNumber, "<< /Type /Page /Parent \(pagesNumber) 0 R /MediaBox \(box(media)) /CropBox \(box(crop)) /Resources \(resources) /Contents \(contentsNumber) 0 R >>")
        writer.set(pagesNumber, "<< /Type /Pages /Kids [\(pageNumber) 0 R] /Count 1 >>")
        let catalog = writer.add("<< /Type /Catalog /Pages \(pagesNumber) 0 R >>")
        guard let provider = CGDataProvider(data: writer.file(root: catalog) as CFData),
              let document = CGPDFDocument(provider), document.numberOfPages == 1 else { throw WriteError() }
        return document
    }

    private struct Writer {
        private var objects: [Int: [UInt8]] = [:]
        private var written: [UnsafeRawPointer: Int] = [:]
        private var next = 1
        private var depth = 0

        mutating func reserve() -> Int {
            next += 1
            return next - 1
        }

        mutating func set(_ number: Int, _ body: String) {
            objects[number] = Array(body.utf8)
        }

        mutating func add(_ body: String) -> Int {
            let number = reserve()
            set(number, body)
            return number
        }

        mutating func add(stream dictionary: String, data: [UInt8]) -> Int {
            let number = reserve()
            objects[number] = Array((dictionary + "\nstream\n").utf8) + data + Array("\nendstream".utf8)
            return number
        }

        func file(root: Int) -> Data {
            var out = Array("%PDF-1.7\n%\u{E2}\u{E3}\u{CF}\u{D3}\n".utf8)
            var offsets: [Int] = []
            for number in 1..<next {
                offsets.append(out.count)
                out += Array("\(number) 0 obj\n".utf8) + (objects[number] ?? Array("null".utf8)) + Array("\nendobj\n".utf8)
            }
            let xref = out.count
            out += Array("xref\n0 \(next)\n0000000000 65535 f \n".utf8)
            for offset in offsets { out += Array(String(format: "%010d 00000 n \n", offset).utf8) }
            out += Array("trailer\n<< /Size \(next) /Root \(root) 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8)
            return Data(out)
        }

        /// Every dictionary and stream becomes an object of its own, written once however often it is used.
        mutating func dictionaryReference(_ dict: CGPDFDictionaryRef) throws -> String {
            let key = unsafeBitCast(dict, to: UnsafeRawPointer.self)
            if let number = written[key] { return "\(number) 0 R" }
            let number = reserve()
            written[key] = number
            objects[number] = Array(try dictionaryBody(dict, skip: []).utf8)
            return "\(number) 0 R"
        }

        private mutating func streamReference(_ stream: CGPDFStreamRef) throws -> String {
            let key = unsafeBitCast(stream, to: UnsafeRawPointer.self)
            if let number = written[key] { return "\(number) 0 R" }
            let number = reserve()
            written[key] = number
            var format = CGPDFDataFormat.raw
            guard let dict = CGPDFStreamGetDictionary(stream), let data = CGPDFStreamCopyData(stream, &format) as Data?
            else { throw WriteError() }
            // Decoded data loses its filters; JPEG and JPEG 2000 images stay as they are
            let filter = format == .jpegEncoded ? " /Filter /DCTDecode" : format == .JPEG2000 ? " /Filter /JPXDecode" : ""
            let body = try dictionaryBody(dict, skip: ["Filter", "DecodeParms", "Length", "F", "FFilter", "FDecodeParms", "DL"])
            let header = String(body.dropLast(2)) + "/Length \(data.count)\(filter) >>"
            objects[number] = Array((header + "\nstream\n").utf8) + [UInt8](data) + Array("\nendstream".utf8)
            return "\(number) 0 R"
        }

        private mutating func dictionaryBody(_ dict: CGPDFDictionaryRef, skip: Set<String>) throws -> String {
            var entries: [(String, CGPDFObjectRef)] = []
            CGPDFDictionaryApplyBlock(dict, { key, value, _ in
                entries.append((String(cString: key), value))
                return true
            }, nil)
            var out = "<< "
            // A page's parent would pull in the whole document
            for (key, value) in entries where !skip.contains(key) && key != "Parent" {
                out += "/\(Self.name(key)) \(try self.value(value)) "
            }
            return out + ">>"
        }

        private mutating func value(_ object: CGPDFObjectRef) throws -> String {
            depth += 1
            defer { depth -= 1 }
            guard depth < 100 else { throw WriteError() }
            switch CGPDFObjectGetType(object) {
            case .boolean:
                var value: CGPDFBoolean = 0
                CGPDFObjectGetValue(object, .boolean, &value)
                return value != 0 ? "true" : "false"
            case .integer:
                var value: CGPDFInteger = 0
                CGPDFObjectGetValue(object, .integer, &value)
                return "\(value)"
            case .real:
                var value: CGPDFReal = 0
                CGPDFObjectGetValue(object, .real, &value)
                return String(format: "%.6f", value)
            case .name:
                var value: UnsafePointer<CChar>?
                CGPDFObjectGetValue(object, .name, &value)
                return "/" + Self.name(value.map { String(cString: $0) } ?? "")
            case .string:
                var value: CGPDFStringRef?
                CGPDFObjectGetValue(object, .string, &value)
                guard let value, let bytes = CGPDFStringGetBytePtr(value) else { return "()" }
                return "<" + UnsafeBufferPointer(start: bytes, count: CGPDFStringGetLength(value)).map { String(format: "%02x", $0) }.joined() + ">"
            case .array:
                var value: CGPDFArrayRef?
                CGPDFObjectGetValue(object, .array, &value)
                guard let array = value else { return "[]" }
                var items: [String] = []
                for k in 0..<CGPDFArrayGetCount(array) {
                    var item: CGPDFObjectRef?
                    if CGPDFArrayGetObject(array, k, &item), let item { items.append(try self.value(item)) } else { items.append("null") }
                }
                return "[" + items.joined(separator: " ") + "]"
            case .dictionary:
                var value: CGPDFDictionaryRef?
                CGPDFObjectGetValue(object, .dictionary, &value)
                return try value.map { try dictionaryReference($0) } ?? "null"
            case .stream:
                var value: CGPDFStreamRef?
                CGPDFObjectGetValue(object, .stream, &value)
                return try value.map { try streamReference($0) } ?? "null"
            default:
                return "null"
            }
        }

        /// A name with the characters that can't stand in it as #xx.
        private static func name(_ name: String) -> String {
            name.utf8.map { b in
                b > 32 && b < 127 && !"()<>[]{}/%#".utf8.contains(b) ? String(UnicodeScalar(b)) : String(format: "#%02X", b)
            }.joined()
        }
    }
}
