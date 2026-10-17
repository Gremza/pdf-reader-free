import SwiftUI

/// The single top row: traffic lights, tabs on the left, document controls on the right.
struct TopBar: View {
    static let height: CGFloat = 40

    @EnvironmentObject private var tabs: TabsModel
    @Binding var showThumbnails: Bool

    var body: some View {
        HStack(spacing: 6) {
            Color.clear.frame(width: tabs.isFullScreen ? 4 : 72)

            Button {
                withAnimation { showThumbnails.toggle() }
            } label: {
                Label("Miniaturat", systemImage: "sidebar.left")
            }
            .buttonStyle(BarButtonStyle())
            .help("Shfaq/fshih miniaturat")
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
                    TabItem(tab: tab, isSelected: tab.id == tabs.selectedID, width: layout.tabWidth)
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
                    .help("Tabs të tjerë")
                }

                Button(action: tabs.showOpenPanel) {
                    Label("Hap PDF", systemImage: "plus")
                }
                .buttonStyle(BarButtonStyle())
                .help("Hap PDF (⌘O)")
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
    let isSelected: Bool
    let width: CGFloat
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.fill")
                .font(.system(size: 11))
                .foregroundStyle(.red)
            Text(tab.title)
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
            .help("Mbyll tab-in (⌘W)")
            .accessibilityLabel("Mbyll \(tab.title)")
        }
        .padding(.horizontal, 8)
        .frame(width: width, height: 28)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Color.primary.opacity(isSelected ? 0.12 : isHovering ? 0.06 : 0))
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture { tabs.selectedID = tab.id }
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
    @FocusState private var searchFocused: Bool

    var body: some View {
        HStack(spacing: 2) {
            Button(action: model.previousPage) {
                Label("Faqja e mëparshme", systemImage: "chevron.up")
            }
            .keyboardShortcut(.upArrow, modifiers: .command)
            .disabled(model.currentPage <= 1)

            TextField("", text: $pageField)
                .textFieldStyle(.roundedBorder)
                .frame(width: 40)
                .multilineTextAlignment(.center)
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
                Label("Faqja tjetër", systemImage: "chevron.down")
            }
            .keyboardShortcut(.downArrow, modifiers: .command)
            .disabled(model.currentPage >= model.pageCount)

            BarDivider()

            Button(action: model.zoomOut) {
                Label("Zvogëlo", systemImage: "minus.magnifyingglass")
            }
            .keyboardShortcut("-", modifiers: .command)
            .help("Zvogëlo (⌘−)")

            Button(action: model.zoomIn) {
                Label("Zmadho", systemImage: "plus.magnifyingglass")
            }
            .keyboardShortcut("+", modifiers: .command)
            .help("Zmadho (⌘+)")

            BarDivider()

            Button(action: model.fitWidth) {
                Label("Gjerësia e plotë", systemImage: "arrow.left.and.right.square")
            }
            .symbolVariant(model.fitMode == .width ? .fill : .none)
            .keyboardShortcut("1", modifiers: .command)
            .help("Gjerësia e plotë (⌘1)")

            Button(action: model.fitPage) {
                Label("Faqja e plotë", systemImage: "arrow.up.and.down.square")
            }
            .symbolVariant(model.fitMode == .page ? .fill : .none)
            .keyboardShortcut("2", modifiers: .command)
            .help("Faqja e plotë (⌘2)")

            Button(action: model.actualSize) {
                Label("Madhësia reale", systemImage: "1.magnifyingglass")
            }
            .keyboardShortcut("0", modifiers: .command)
            .help("Madhësia reale 100% (⌘0)")

            Menu {
                Picker("Pamja", selection: $model.layout) {
                    ForEach(PageLayout.allCases) { layout in
                        Label(layout.title, systemImage: layout.systemImage).tag(layout)
                    }
                }
                .pickerStyle(.inline)

                Divider()

                Button {
                    model.rotate(by: -90)
                } label: {
                    Label("Rrotullo majtas", systemImage: "rotate.left")
                }
                .keyboardShortcut("l", modifiers: .command)

                Button {
                    model.rotate(by: 90)
                } label: {
                    Label("Rrotullo djathtas", systemImage: "rotate.right")
                }
                .keyboardShortcut("r", modifiers: .command)
            } label: {
                Image(systemName: model.layout.systemImage)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 40)
            .help("Mënyra e shfaqjes dhe rrotullimi")
            .accessibilityLabel("Pamja")

            Button(action: tabs.toggleFullScreen) {
                Label(tabs.isFullScreen ? "Dil nga ekrani i plotë" : "Ekran i plotë",
                      systemImage: tabs.isFullScreen
                          ? "arrow.down.right.and.arrow.up.left"
                          : "arrow.up.left.and.arrow.down.right")
            }
            .keyboardShortcut("f", modifiers: [.command, .control])
            .help("Ekran i plotë (⌃⌘F)")

            BarDivider()

            TextField("Kërko", text: $model.searchText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 150)
                .focused($searchFocused)
                .onSubmit { model.nextResult() }
                .onChange(of: model.searchText) { model.search() }

            // Hidden button so ⌘F focuses the search field
            Button("") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .buttonStyle(BarButtonStyle())
        .onAppear { pageField = "\(model.currentPage)" }
        .onChange(of: model.currentPage) { pageField = "\(model.currentPage)" }
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
