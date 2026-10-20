import AppKit
import PDFKit
import UniformTypeIdentifiers

/// Turns the text of a PDF into a Word document.
/// PDFs store positioned lines of text, not paragraphs, so lines are joined into paragraphs
/// when they are close together and the previous line runs to the margin.
enum WordExport {
    static let docxType = UTType(filenameExtension: "docx") ?? .data

    struct Run: Sendable {
        var text: String
        var bold: Bool
        var italic: Bool
        var size: CGFloat
    }

    struct Paragraph: Sendable {
        var runs: [Run]
    }

    struct Document: Sendable {
        var pageWidth: CGFloat
        var pageHeight: CGFloat
        var pages: [[Paragraph]]

        var hasText: Bool {
            pages.contains { $0.contains { $0.runs.contains { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty } } }
        }
    }

    // MARK: - Text

    /// Reads a separate copy of the PDF off the main thread; nil when it can't be opened.
    nonisolated static func extract(
        from source: PDFViewModel.ExportSource,
        progress: @escaping @MainActor @Sendable (Int) -> Void
    ) async -> Document? {
        guard let pdf = source.open() else { return nil }
        var document = Document(pageWidth: 612, pageHeight: 792, pages: [])
        if let first = pdf.page(at: 0) {
            var size = first.bounds(for: .mediaBox).size
            if first.rotation % 180 != 0 { size = CGSize(width: size.height, height: size.width) }
            document.pageWidth = size.width
            document.pageHeight = size.height
        }
        for index in 0..<pdf.pageCount {
            let pageParagraphs = pdf.page(at: index).map { paragraphs(from: lines(of: $0)) } ?? []
            document.pages.append(pageParagraphs)
            await progress(index + 1)
        }
        return document
    }

    private struct Line {
        var x: CGFloat
        var y: CGFloat
        var right: CGFloat
        var size: CGFloat
        var runs: [Run]
    }

    nonisolated private static func lines(of page: PDFPage) -> [Line] {
        guard let selection = page.selection(for: page.bounds(for: .mediaBox)) else { return [] }
        return selection.selectionsByLine().compactMap { lineSelection in
            guard let text = lineSelection.attributedString else { return nil }
            var runs: [Run] = []
            text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length)) { value, range, _ in
                let piece = (text.string as NSString).substring(with: range)
                    .replacingOccurrences(of: "\r", with: "")
                    .replacingOccurrences(of: "\n", with: "")
                    .replacingOccurrences(of: "\t", with: " ")
                guard !piece.isEmpty else { return }
                let font = value as? NSFont
                let name = font?.fontName ?? ""
                let traits = font?.fontDescriptor.symbolicTraits ?? []
                let run = Run(
                    text: piece,
                    bold: traits.contains(.bold) || name.range(of: "bold|black|heavy|semibold|demi", options: [.regularExpression, .caseInsensitive]) != nil,
                    italic: traits.contains(.italic) || name.range(of: "italic|oblique", options: [.regularExpression, .caseInsensitive]) != nil,
                    size: ((font?.pointSize ?? 11) * 2).rounded() / 2)
                append(run, to: &runs)
            }
            guard runs.contains(where: { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }) else { return nil }
            let bounds = lineSelection.bounds(for: page)
            return Line(x: bounds.minX, y: bounds.minY, right: bounds.maxX,
                        size: runs.map(\.size).max() ?? 11, runs: runs)
        }
    }

    nonisolated private static func paragraphs(from lines: [Line]) -> [Paragraph] {
        guard let left = lines.map(\.x).min(), let right = lines.map(\.right).max() else { return [] }
        var paragraphs: [Paragraph] = []
        var previous: Line?

        for line in lines {
            if let previous, continuesParagraph(previous, line, left: left, right: right) {
                var runs = paragraphs[paragraphs.count - 1].runs
                let last = runs[runs.count - 1].text
                // "exam-" + "ple" → "example"; otherwise join the lines with a space
                if last.range(of: "[a-zëç]-$", options: [.regularExpression, .caseInsensitive]) != nil,
                   line.runs[0].text.range(of: "^[a-zëç]", options: .regularExpression) != nil {
                    runs[runs.count - 1].text.removeLast()
                } else if !(last.last?.isWhitespace ?? false) {
                    runs[runs.count - 1].text += " "
                }
                for run in line.runs { append(run, to: &runs) }
                paragraphs[paragraphs.count - 1].runs = runs
            } else {
                paragraphs.append(Paragraph(runs: line.runs))
            }
            previous = line
        }
        for i in paragraphs.indices {
            let last = paragraphs[i].runs.count - 1
            while paragraphs[i].runs[last].text.last?.isWhitespace == true { paragraphs[i].runs[last].text.removeLast() }
        }
        return paragraphs
    }

    nonisolated private static func continuesParagraph(_ previous: Line, _ line: Line, left: CGFloat, right: CGFloat) -> Bool {
        let size = max(previous.size, line.size)
        let gap = previous.y - line.y
        return gap > 0
            && gap < size * 1.7
            && abs(previous.size - line.size) < 1
            // The previous line reaches the right margin, so the text wraps
            && previous.right > right - size * 4
            // A first-line indent starts a new paragraph
            && line.x < left + size * 1.5
    }

    nonisolated private static func append(_ run: Run, to runs: inout [Run]) {
        if let last = runs.last, last.bold == run.bold, last.italic == run.italic, last.size == run.size {
            runs[runs.count - 1].text += run.text
        } else {
            runs.append(run)
        }
    }

    // MARK: - .docx

    nonisolated static func docx(_ document: Document) -> Data {
        zip([
            ("[Content_Types].xml", contentTypes),
            ("_rels/.rels", rootRels),
            ("word/_rels/document.xml.rels", documentRels),
            ("word/styles.xml", styles),
            ("word/document.xml", documentXML(document)),
        ])
    }

    private static let contentTypes = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
        <Default Extension="xml" ContentType="application/xml"/>
        <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
        <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>
        </Types>
        """

    private static let rootRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
        </Relationships>
        """

    private static let documentRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
        </Relationships>
        """

    private static let styles = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        <w:docDefaults>
        <w:rPrDefault><w:rPr><w:rFonts w:ascii="Arial" w:hAnsi="Arial" w:eastAsia="Arial" w:cs="Arial"/><w:sz w:val="22"/><w:szCs w:val="22"/><w:lang w:val="sq-AL"/></w:rPr></w:rPrDefault>
        <w:pPrDefault><w:pPr><w:spacing w:after="160" w:line="264" w:lineRule="auto"/></w:pPr></w:pPrDefault>
        </w:docDefaults>
        <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/></w:style>
        </w:styles>
        """

    nonisolated private static func documentXML(_ document: Document) -> String {
        var body: [String] = []
        for (index, page) in document.pages.enumerated() {
            let pageBreak = index > 0 ? "<w:pageBreakBefore/>" : ""
            if page.isEmpty {
                body.append("<w:p><w:pPr>\(pageBreak)</w:pPr></w:p>")
                continue
            }
            for (i, paragraph) in page.enumerated() {
                body.append("<w:p><w:pPr>\(i == 0 ? pageBreak : "")</w:pPr>\(paragraph.runs.map(runXML).joined())</w:p>")
            }
        }
        // Word measures in twentieths of a point
        let width = Int((document.pageWidth * 20).rounded())
        let height = Int((document.pageHeight * 20).rounded())
        let orientation = width > height ? " w:orient=\"landscape\"" : ""
        return """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
            <w:body>
            \(body.joined(separator: "\n"))
            <w:sectPr><w:pgSz w:w="\(width)" w:h="\(height)"\(orientation)/><w:pgMar w:top="1134" w:right="1134" w:bottom="1134" w:left="1134" w:header="708" w:footer="708" w:gutter="0"/></w:sectPr>
            </w:body>
            </w:document>
            """
    }

    nonisolated private static func runXML(_ run: Run) -> String {
        let halfPoints = Int((min(max(run.size, 6), 72) * 2).rounded())
        let properties = (run.bold ? "<w:b/>" : "") + (run.italic ? "<w:i/>" : "")
            + "<w:sz w:val=\"\(halfPoints)\"/><w:szCs w:val=\"\(halfPoints)\"/>"
        return "<w:r><w:rPr>\(properties)</w:rPr><w:t xml:space=\"preserve\">\(escapeXML(run.text))</w:t></w:r>"
    }

    nonisolated private static func escapeXML(_ text: String) -> String {
        // Characters XML does not allow; PDFs sometimes contain them
        let allowed = text.unicodeScalars.filter { scalar in
            switch scalar.value {
            case 0x09, 0x0A, 0x0D: true
            case 0x00...0x1F, 0xFFFE, 0xFFFF: false
            default: true
            }
        }
        return String(String.UnicodeScalarView(allowed))
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    // MARK: - Zip

    /// Minimal zip writer (stored, no compression, no zip64), enough for a .docx package.
    nonisolated private static func zip(_ entries: [(name: String, content: String)]) -> Data {
        var locals = Data()
        var centrals = Data()

        for entry in entries {
            let name = Data(entry.name.utf8)
            let data = Data(entry.content.utf8)
            let crc = crc32(data)
            let offset = UInt32(locals.count)

            locals.append(le32: 0x04034b50)
            locals.append(le16: 20)       // version needed
            locals.append(le16: 0x0800)   // UTF-8 names
            locals.append(le16: 0)        // stored
            locals.append(le16: 0)        // time
            locals.append(le16: 0x21)     // date: 1980-01-01
            locals.append(le32: crc)
            locals.append(le32: UInt32(data.count))
            locals.append(le32: UInt32(data.count))
            locals.append(le16: UInt16(name.count))
            locals.append(le16: 0)
            locals.append(name)
            locals.append(data)

            centrals.append(le32: 0x02014b50)
            centrals.append(le16: 20)     // version made by
            centrals.append(le16: 20)
            centrals.append(le16: 0x0800)
            centrals.append(le16: 0)
            centrals.append(le16: 0)
            centrals.append(le16: 0x21)
            centrals.append(le32: crc)
            centrals.append(le32: UInt32(data.count))
            centrals.append(le32: UInt32(data.count))
            centrals.append(le16: UInt16(name.count))
            centrals.append(Data(count: 12)) // extra, comment, disk, attributes
            centrals.append(le32: offset)
            centrals.append(name)
        }

        var end = Data()
        end.append(le32: 0x06054b50)
        end.append(Data(count: 4))
        end.append(le16: UInt16(entries.count))
        end.append(le16: UInt16(entries.count))
        end.append(le32: UInt32(centrals.count))
        end.append(le32: UInt32(locals.count))
        end.append(le16: 0)
        return locals + centrals + end
    }

    nonisolated private static let crcTable: [UInt32] = (0..<256).map { n in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }

    nonisolated private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data { crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFFFFFF
    }
}

private extension Data {
    mutating func append(le16 value: UInt16) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    mutating func append(le32 value: UInt32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
