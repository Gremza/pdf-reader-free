import AppKit
import PDFKit

let dir = URL(fileURLWithPath: CommandLine.arguments[1])
func makePDF(_ url: URL, pages: Int) {
    var box = CGRect(x: 0, y: 0, width: 595, height: 842)
    let ctx = CGContext(url as CFURL, mediaBox: &box, nil)!
    for p in 1...pages {
        ctx.beginPDFPage(nil)
        let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.current = ns
        NSAttributedString(string: "Titulli i faqes \(p)", attributes: [.font: NSFont(name: "Helvetica-Bold", size: 20)!]).draw(at: CGPoint(x: 60, y: 760))
        let body = String(repeating: "Kjo është një fjali e gjatë shqip me ë dhe ç që vazhdon në rreshtin tjetër. ", count: 6)
        NSAttributedString(string: body, attributes: [.font: NSFont(name: "Helvetica", size: 12)!]).draw(in: CGRect(x: 60, y: 500, width: 475, height: 240))
        ctx.endPDFPage()
    }
    ctx.closePDF()
}

@MainActor func run() async {
    let src = dir.appendingPathComponent("test.pdf")
    makePDF(src, pages: 4)
    let m = PDFViewModel(document: PDFDocument(url: src)!, url: src)
    func check(_ what: String, _ ok: Bool) { print(ok ? "OK  " : "FAIL", what) }
    func firstWord(_ i: Int) -> String { m.pdfView.document!.page(at: i)!.string!.components(separatedBy: "\n")[0] }

    check("4 faqe", m.pageCount == 4 && !m.isDirty)
    m.deletePage(2)
    check("fshi faqen 2 -> 3 faqe, dirty", m.pageCount == 3 && m.isDirty && firstWord(1) == "Titulli i faqes 3")
    m.undo()
    check("zhbëj -> 4 faqe, jo dirty", m.pageCount == 4 && !m.isDirty && firstWord(1) == "Titulli i faqes 2")
    m.movePage(1, to: 3)
    check("lëviz 1 -> 3", (0..<4).map(firstWord) == ["Titulli i faqes 2","Titulli i faqes 3","Titulli i faqes 1","Titulli i faqes 4"])
    m.undo()
    m.insertBlankPage(after: 2)
    check("faqe bosh pas 2", m.pageCount == 5 && (m.pdfView.document!.page(at: 2)!.string ?? "").isEmpty
          && m.pdfView.document!.page(at: 2)!.bounds(for: .mediaBox).size == CGSize(width: 595, height: 842))
    m.rotatePage(1, by: -90)
    check("rrotullo faqen 1 majtas", m.pdfView.document!.page(at: 0)!.rotation == 270)
    m.rotate(by: 90)
    check("rrotullo të gjitha", m.pdfView.document!.page(at: 0)!.rotation == 0 && m.pdfView.document!.page(at: 1)!.rotation == 90)
    check("ruaj", m.save() && !m.isDirty)
    let reopened = PDFDocument(url: src)!
    check("skedari i ruajtur ka 5 faqe dhe rrotullimin", reopened.pageCount == 5 && reopened.page(at: 1)!.rotation == 90)
    m.undo()
    check("zhbëj pas ruajtjes -> dirty", m.isDirty)

    // Full Screen Mode: single fitted pages on black, then the layout and zoom come back
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = m.pdfView
    m.layout = .twoUpContinuous
    m.fitWidth()
    m.goToPage(2)
    m.setPresenting(true)
    let fitted = 600 / 842.0
    check("full screen: single page, black, fitted", m.isPresenting && m.pdfView.displayMode == .singlePage
          && m.pdfView.backgroundColor == .black && !m.pdfView.displaysPageBreaks && m.fitMode == .page
          && abs(m.pdfView.scaleFactor - fitted) < 0.01 && m.currentPage == 2)
    m.nextPage()
    check("full screen: next page", m.currentPage == 3)
    m.previousPage(); m.previousPage()
    check("full screen: previous page", m.currentPage == 1)
    m.lastPage()
    check("full screen: last page", m.currentPage == m.pageCount)
    m.firstPage()
    check("full screen: first page", m.currentPage == 1)
    m.insertBlankPage(after: 1); m.undo()
    check("full screen: undo keeps single page", m.pdfView.displayMode == .singlePage)
    m.goToPage(3)
    m.setPresenting(false)
    check("full screen off: layout, fit and page back", !m.isPresenting && m.pdfView.displayMode == .twoUpContinuous
          && m.fitMode == .width && m.pdfView.displaysPageBreaks && m.currentPage == 3)
    m.actualSize()
    m.setPresenting(true); m.setPresenting(false)
    check("full screen off: custom zoom back", m.fitMode == .custom && abs(m.pdfView.scaleFactor - 1) < 0.01)
    window.contentView = nil

    m.searchText = "Titulli"
    m.search()
    let firstHit = m.currentPage
    m.nextResult(); m.previousResult()
    check("find next / previous", m.currentPage == firstHit)

    check("ranges 1-3, 5", PDFViewModel.parsePageRanges("1-3, 5", pageCount: 5) == [0,1,2,4])
    check("ranges 4-", PDFViewModel.parsePageRanges("4-", pageCount: 5) == [3,4])
    check("ranges gabim", PDFViewModel.parsePageRanges("0", pageCount: 5) == nil && PDFViewModel.parsePageRanges("2-9", pageCount: 5) == nil && PDFViewModel.parsePageRanges("abc", pageCount: 5) == nil)

    let doc = await WordExport.extract(from: .file(src)) { _ in }!
    check("word ka tekst", doc.hasText && doc.pages.count == 5)
    for (i, page) in doc.pages.enumerated() {
        print("  faqja \(i+1): \(page.count) paragrafë", page.map { p in p.runs.map { "[\($0.bold ? "B " : "")\($0.size)] \($0.text.prefix(50))" }.joined() })
    }
    try! WordExport.docx(doc).write(to: dir.appendingPathComponent("test.docx"))
}

@main struct Main { static func main() async { await run() } }
