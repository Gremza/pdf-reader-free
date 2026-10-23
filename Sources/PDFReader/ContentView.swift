import SwiftUI
import PDFKit

struct ContentView: View {
    @EnvironmentObject private var tabs: TabsModel
    var body: some View {
        VStack(spacing: 0) {
            // Full Screen Mode shows nothing but the page
            if !tabs.isPresenting {
                TopBar()
                Divider()
            }

            if let tab = tabs.selected {
                DocumentView(model: tab.model, showThumbnails: tabs.showThumbnails && !tabs.isPresenting)
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
                ThumbnailSidebar(model: model)
                    .frame(width: 150)
                Divider()
            }
            PDFKitView(pdfView: model.pdfView)
                .overlay(alignment: .bottom) { ExportProgressBadge(model: model) }
        }
    }
}

private struct ExportProgressBadge: View {
    @ObservedObject var model: PDFViewModel

    var body: some View {
        if let progress = model.exportProgress, !model.isPresenting {
            HStack(spacing: 10) {
                ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                    .frame(width: 120)
                Text("\(progress.label) \(progress.done) / \(progress.total)…")
                    .monospacedDigit()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .shadow(radius: 4, y: 1)
            .padding(.bottom, 20)
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
            Text("No PDF Open")
                .font(.title2.weight(.semibold))
            Text("Drag one or more PDFs here")
                .foregroundStyle(.secondary)
            Button("Open PDF…", action: tabs.showOpenPanel)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
