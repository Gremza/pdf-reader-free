import SwiftUI
import PDFKit

struct PDFKitView: NSViewRepresentable {
    let pdfView: PDFView

    func makeNSView(context: Context) -> PDFView { pdfView }
    func updateNSView(_ nsView: PDFView, context: Context) {}
}

/// The PDF view of a tab; its right-click menu starts with the tab's own items.
final class DocumentPDFView: PDFView {
    weak var owner: PDFViewModel?

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        guard let items = owner?.contextMenuItems() else { return menu }
        if !menu.items.isEmpty { menu.insertItem(.separator(), at: 0) }
        for item in items.reversed() { menu.insertItem(item, at: 0) }
        return menu
    }
}
