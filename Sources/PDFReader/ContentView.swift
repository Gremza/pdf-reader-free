import SwiftUI
import PDFKit

struct ContentView: View {
    @EnvironmentObject private var tabs: TabsModel
    @State private var showThumbnails = true

    var body: some View {
        VStack(spacing: 0) {
            TopBar(showThumbnails: $showThumbnails)
            Divider()

            if let tab = tabs.selected {
                DocumentView(model: tab.model, showThumbnails: showThumbnails)
                    .id(tab.id)
            } else {
                EmptyState()
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 860, minHeight: 500)
        .background(WindowChrome(tabs: tabs))
        .dropDestination(for: URL.self) { urls, _ in
            let pdfs = urls.filter { $0.pathExtension.lowercased() == "pdf" }
            tabs.open(pdfs)
            return !pdfs.isEmpty
        }
    }
}

private struct DocumentView: View {
    let model: PDFViewModel
    let showThumbnails: Bool

    var body: some View {
        HStack(spacing: 0) {
            if showThumbnails {
                ThumbnailView(pdfView: model.pdfView)
                    .frame(width: 150)
                Divider()
            }
            PDFKitView(pdfView: model.pdfView)
        }
    }
}

private struct EmptyState: View {
    @EnvironmentObject private var tabs: TabsModel

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "doc.richtext")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.secondary)
            Text("Asnjë PDF i hapur")
                .font(.title2.weight(.semibold))
            Text("Tërhiq një ose më shumë PDF këtu")
                .foregroundStyle(.secondary)
            Button("Hap PDF…", action: tabs.showOpenPanel)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
