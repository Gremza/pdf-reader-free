import SwiftUI

/// The single top row: traffic lights, tabs on the left, document controls on the right.
struct TopBar: View {
    static let height: CGFloat = 40

    @EnvironmentObject private var tabs: TabsModel

    var body: some View {
        HStack(spacing: 6) {
            Color.clear.frame(width: tabs.isFullScreen ? 4 : 72)

            Button {
                withAnimation { tabs.showThumbnails.toggle() }
            } label: {
                Label("Thumbnails", systemImage: "sidebar.left")
            }
            .buttonStyle(BarButtonStyle())
            .help("Show/hide thumbnails (F4)")
            .disabled(tabs.selected == nil)

            TabStrip()

            if let tab = tabs.selected {
                DocumentControls(model: tab.model)
            }
        }
        .labelStyle(.iconOnly)
        .padding(.trailing, 10)
        .frame(height: Self.height)
        .background(WindowDragArea())
    }
}

// MARK: - Tabs

private struct TabStrip: View {
    @EnvironmentObject private var tabs: TabsModel

    private let minTabWidth: CGFloat = 110
    private let maxTabWidth: CGFloat = 210
    private let overflowWidth: CGFloat = 48
    private let addWidth: CGFloat = 30

    var body: some View {
        GeometryReader { geo in
            let layout = layout(for: geo.size.width)
            HStack(spacing: 2) {
                ForEach(layout.visible) { tab in
                    TabItem(tab: tab, model: tab.model, isSelected: tab.id == tabs.selectedID, width: layout.tabWidth)
                }

                if !layout.hidden.isEmpty {
                    Menu {
                        ForEach(layout.hidden) { tab in
                            Button(tab.title) { tabs.selectedID = tab.id }
                        }
                    } label: {
                        Text("»\(layout.hidden.count)")
                            .font(.system(size: 12, weight: .semibold))
                            .monospacedDigit()
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(width: overflowWidth - 4)
                    .help("More tabs")
                }

                Button(action: tabs.showOpenPanel) {
                    Label("Open PDF", systemImage: "plus")
                }
                .buttonStyle(BarButtonStyle())
                .help("Open PDF (⌘O)")
            }
            .frame(maxHeight: .infinity)
        }
        .frame(minWidth: minTabWidth + addWidth)
    }

    private struct Layout {
        var visible: [DocumentTab]
        var hidden: [DocumentTab]
        var tabWidth: CGFloat
    }

    /// Shrinks tabs down to `minTabWidth`; whatever still doesn't fit goes into the overflow menu.
    private func layout(for width: CGFloat) -> Layout {
        let all = tabs.tabs
        guard !all.isEmpty else { return Layout(visible: [], hidden: [], tabWidth: 0) }

        let available = width - addWidth
        if CGFloat(all.count) * minTabWidth <= available {
            let w = min(maxTabWidth, available / CGFloat(all.count) - 2)
            return Layout(visible: all, hidden: [], tabWidth: w)
        }

        let room = available - overflowWidth
        let fit = max(1, Int(room / minTabWidth))
        var visible = Array(all.prefix(fit))
        // Keep the selected tab visible
        if let selected = tabs.selected, !visible.contains(where: { $0.id == selected.id }) {
            visible[fit - 1] = selected
        }
        let hidden = all.filter { tab in !visible.contains { $0.id == tab.id } }
        return Layout(visible: visible, hidden: hidden, tabWidth: max(minTabWidth, room / CGFloat(fit)) - 2)
    }
}

private struct TabItem: View {
    @EnvironmentObject private var tabs: TabsModel
    let tab: DocumentTab
    /// Observed for the unsaved-changes dot
    @ObservedObject var model: PDFViewModel
    let isSelected: Bool
    let width: CGFloat
    @State private var isHovering = false
    @State private var isDropTarget = false

    private static let dragPrefix = "pdfreader-tab:"

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.fill")
                .font(.system(size: 11))
                .foregroundStyle(.red)
            Text((model.isDirty ? "● " : "") + tab.title)
                .font(.system(size: 12, weight: isSelected ? .medium : .regular))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(isSelected ? .primary : .secondary)
            Spacer(minLength: 0)
            Button {
                tabs.close(tab.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(isSelected || isHovering ? 1 : 0)
            .help("Close Tab (⌘W)")
            .accessibilityLabel("Close \(tab.title)")
        }
        .padding(.horizontal, 8)
        .frame(width: width, height: 28)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Color.primary.opacity(isSelected ? 0.12 : isHovering ? 0.06 : 0))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(Color.accentColor, lineWidth: 2)
                .opacity(isDropTarget ? 1 : 0)
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture { tabs.selectedID = tab.id }
        // Drag a tab left or right to change the order
        .draggable(Self.dragPrefix + tab.id.uuidString) {
            Text(tab.title).font(.system(size: 12)).padding(6)
        }
        .dropDestination(for: String.self) { items, _ in
            isDropTarget = false
            guard let item = items.first, item.hasPrefix(Self.dragPrefix),
                  let id = UUID(uuidString: String(item.dropFirst(Self.dragPrefix.count))) else { return false }
            tabs.moveTab(id, to: tab.id)
            return true
        } isTargeted: { isDropTarget = $0 }
        .help(tab.url.path)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Document controls

private struct DocumentControls: View {
    @EnvironmentObject private var tabs: TabsModel
    @ObservedObject var model: PDFViewModel
    @State private var pageField = ""
    @FocusState private var focusedField: BarField?

    var body: some View {
        HStack(spacing: 2) {
            Button(action: model.previousPage) {
                Label("Previous Page", systemImage: "chevron.up")
            }
            .help("Previous Page (←)")
            .disabled(model.currentPage <= 1)

            TextField("", text: $pageField)
                .textFieldStyle(.roundedBorder)
                .frame(width: 40)
                .multilineTextAlignment(.center)
                .focused($focusedField, equals: .page)
                .onSubmit {
                    if let n = Int(pageField) { model.goToPage(n) }
                    pageField = "\(model.currentPage)"
                }
            Text("/ \(model.pageCount)")
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .fixedSize()
                .padding(.horizontal, 2)

            Button(action: model.nextPage) {
                Label("Next Page", systemImage: "chevron.down")
            }
            .help("Next Page (→)")
            .disabled(model.currentPage >= model.pageCount)

            BarDivider()

            Button(action: model.zoomOut) {
                Label("Zoom Out", systemImage: "minus.magnifyingglass")
            }
            .help("Zoom Out (⌘−)")

            Button(action: model.zoomIn) {
                Label("Zoom In", systemImage: "plus.magnifyingglass")
            }
            .help("Zoom In (⌘=)")

            BarDivider()

            Button(action: model.fitWidth) {
                Label("Fit Width", systemImage: "arrow.left.and.right.square")
            }
            .symbolVariant(model.fitMode == .width ? .fill : .none)
            .help("Fit Width (⌘2)")

            Button(action: model.fitPage) {
                Label("Fit Page", systemImage: "arrow.up.and.down.square")
            }
            .symbolVariant(model.fitMode == .page ? .fill : .none)
            .help("Fit Page (⌘0)")

            Button(action: model.actualSize) {
                Label("Actual Size", systemImage: "1.magnifyingglass")
            }
            .help("Actual Size 100% (⌘1)")

            Menu {
                Picker("Layout", selection: $model.layout) {
                    ForEach(PageLayout.allCases) { layout in
                        Label(layout.title, systemImage: layout.systemImage).tag(layout)
                    }
                }
                .pickerStyle(.inline)

                Divider()

                Button {
                    model.rotate(by: -90)
                } label: {
                    Label("Rotate Left", systemImage: "rotate.left")
                }

                Button {
                    model.rotate(by: 90)
                } label: {
                    Label("Rotate Right", systemImage: "rotate.right")
                }
            } label: {
                Image(systemName: model.layout.systemImage)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 40)
            .help("Layout and rotation")
            .accessibilityLabel("Layout")

            Menu {
                DocumentMenu(model: model)
            } label: {
                Image(systemName: "doc.badge.gearshape")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 32)
            .disabled(!model.canEdit)
            .help("Pages, saving and export")
            .accessibilityLabel("Document")

            Button(action: model.exportJPEG) {
                Label("Export as JPG", systemImage: "photo.on.rectangle")
            }
            .disabled(model.exportProgress != nil)
            .help("Export every page as a JPG image (⌘E)")

            Button(action: tabs.startPresentation) {
                Label("Full Screen Mode", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            .help("Full Screen Mode (⌘L)")

            BarDivider()

            TextField("Search", text: $model.searchText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 150)
                .focused($focusedField, equals: .search)
                .onSubmit { model.nextResult() }
                .onChange(of: model.searchText) { model.search() }
        }
        .buttonStyle(BarButtonStyle())
        .onAppear { pageField = "\(model.currentPage)" }
        .onChange(of: model.currentPage) { pageField = "\(model.currentPage)" }
        // "Search" and "Go to Page…" in the menu bar
        .onChange(of: model.focusRequest) {
            guard let field = model.focusRequest else { return }
            focusedField = field
            model.focusRequest = nil
        }
    }
}

/// Page edits for the current page, saving and export.
private struct DocumentMenu: View {
    @ObservedObject var model: PDFViewModel

    var body: some View {
        let n = model.currentPage
        Button("Save") { model.save() }
            .disabled(!model.isDirty)
        Button("Save As…") { model.saveAs() }
        Button("Undo", action: model.undo)
            .disabled(!model.canUndo)
        Divider()
        Button("Insert Blank Page After Page \(n)") { model.insertBlankPage(after: n) }
        Button("Insert Pages from PDF After Page \(n)…") {
            model.insertPDFs(after: n, message: "Choose the PDFs to insert")
        }
        Button("Merge PDFs at End…", action: model.mergePDFs)
        Button("Delete Page \(n)") { model.deletePage(n) }
            .disabled(model.pageCount <= 1)
        Divider()
        Button("Rotate Page \(n) Left") { model.rotatePage(n, by: -90) }
        Button("Rotate Page \(n) Right") { model.rotatePage(n, by: 90) }
        Divider()
        Button("Extract Pages to New PDF…") { model.extractPagesPrompt() }
        Button("Split into Single Pages…", action: model.splitPages)
        Divider()
        Button("Export to Word…", action: model.exportWord)
        Button("Export as JPG…", action: model.exportJPEG)
    }
}

// MARK: - Styling

private struct BarDivider: View {
    var body: some View {
        Divider().frame(height: 18).padding(.horizontal, 4)
    }
}

struct BarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        BarButton(configuration: configuration)
    }

    private struct BarButton: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 14))
                .frame(width: 28, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.primary.opacity(configuration.isPressed ? 0.15 : isHovering && isEnabled ? 0.07 : 0))
                )
                .foregroundStyle(isEnabled ? .primary : .tertiary)
                .contentShape(Rectangle())
                .onHover { isHovering = $0 }
        }
    }
}
