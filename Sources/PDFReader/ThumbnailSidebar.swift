import SwiftUI
import PDFKit

/// Page thumbnails: click to go to a page, right-click for page actions, drag to reorder, Delete to remove.
struct ThumbnailSidebar: View {
    @ObservedObject var model: PDFViewModel
    @State private var dropTarget: Int?
    @FocusState private var focused: Bool

    private static let dragPrefix = "pdfreader-page:"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(Array(1..<model.pageCount + 1), id: \.self) { number in
                        cell(number)
                    }
                    // Dropping below the last page moves the page to the end
                    Color.clear
                        .frame(height: 40)
                        .overlay(alignment: .top) { dropLine(visible: dropTarget == model.pageCount + 1) }
                        .dropDestination(for: String.self) { items, _ in
                            drop(items, at: model.pageCount + 1)
                        } isTargeted: { dropTarget = $0 ? model.pageCount + 1 : nil }
                }
                .padding(.vertical, 10)
            }
            .background(Color(nsColor: .controlBackgroundColor))
            .focusable()
            .focusEffectDisabled()
            .focused($focused)
            .onDeleteCommand { model.deletePage(model.currentPage) }
            .onChange(of: model.currentPage) {
                withAnimation { proxy.scrollTo(model.currentPage) }
            }
        }
    }

    private func cell(_ number: Int) -> some View {
        let isCurrent = number == model.currentPage
        return VStack(spacing: 4) {
            PageThumbnail(model: model, number: number)
                .padding(3)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(isCurrent ? Color.accentColor : .clear, lineWidth: 3)
                )
            Text("\(number)")
                .font(.system(size: 11, weight: isCurrent ? .semibold : .regular))
                .foregroundStyle(isCurrent ? .primary : .secondary)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .overlay(alignment: .top) { dropLine(visible: dropTarget == number) }
        .contentShape(Rectangle())
        .id(number)
        .onTapGesture {
            model.goToPage(number)
            focused = true
        }
        .contextMenu { pageMenu(number) }
        .draggable(Self.dragPrefix + "\(number)") {
            PageThumbnail(model: model, number: number)
        }
        .dropDestination(for: String.self) { items, _ in
            drop(items, at: number)
        } isTargeted: { dropTarget = $0 ? number : (dropTarget == number ? nil : dropTarget) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Page \(number)")
        .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private func pageMenu(_ number: Int) -> some View {
        Button("Rotate Left") { model.rotatePage(number, by: -90) }
        Button("Rotate Right") { model.rotatePage(number, by: 90) }
        Divider()
        Button("Insert Blank Page After This") { model.insertBlankPage(after: number) }
        Button("Insert Pages from PDF After This…") {
            model.insertPDFs(after: number, message: "Choose the PDFs to insert")
        }
        Button("Save This Page as PDF…") { model.extractPagesPrompt(defaultValue: "\(number)") }
        Divider()
        Button("Delete Page") { model.deletePage(number) }
            .disabled(model.pageCount <= 1)
    }

    private func dropLine(visible: Bool) -> some View {
        Capsule()
            .fill(Color.accentColor)
            .frame(height: 3)
            .padding(.horizontal, 14)
            .offset(y: -3)
            .opacity(visible ? 1 : 0)
    }

    /// The dragged page goes before page `position` (pageCount + 1 = at the end).
    private func drop(_ items: [String], at position: Int) -> Bool {
        dropTarget = nil
        guard let item = items.first, item.hasPrefix(Self.dragPrefix),
              let from = Int(item.dropFirst(Self.dragPrefix.count)), from <= model.pageCount
        else { return false }
        // Position counted before the dragged page is taken out
        model.movePage(from, to: position > from ? position - 1 : position)
        return true
    }
}

/// Renders lazily, when the thumbnail scrolls into view, and again after the page changes.
private struct PageThumbnail: View {
    @ObservedObject var model: PDFViewModel
    let number: Int
    @State private var image: NSImage?

    private static let maxSize = CGSize(width: 110, height: 140)

    var body: some View {
        let size = displaySize
        Group {
            if let image {
                Image(nsImage: image).resizable()
            } else {
                Color.white
            }
        }
        .frame(width: size.width, height: size.height)
        .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
        .task(id: "\(model.revision)-\(number)") {
            guard let page = model.pdfView.document?.page(at: number - 1) else { return }
            let scale = NSScreen.main?.backingScaleFactor ?? 2
            image = page.thumbnail(of: CGSize(width: size.width * scale, height: size.height * scale), for: .cropBox)
        }
    }

    private var displaySize: CGSize {
        guard let page = model.pdfView.document?.page(at: number - 1) else { return Self.maxSize }
        var size = page.bounds(for: .cropBox).size
        if page.rotation % 180 != 0 { size = CGSize(width: size.height, height: size.width) }
        guard size.width > 0, size.height > 0 else { return Self.maxSize }
        let scale = min(Self.maxSize.width / size.width, Self.maxSize.height / size.height)
        return CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
    }
}
