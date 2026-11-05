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
                .overlay(alignment: .bottom) {
                    ExportProgressBadge(model: model)
                    ImagePlacementBar(model: model)
                    SnapshotBar(model: model)
                }
        }
    }
}

private struct ExportProgressBadge: View {
    @ObservedObject var model: PDFViewModel

    var body: some View {
        if let progress = model.exportProgress, !model.isPresenting {
            HStack(spacing: 10) {
                if progress.total > 0 {
                    ProgressView(value: Double(progress.done), total: Double(progress.total))
                        .frame(width: 120)
                    Text("\(progress.label) \(progress.done) / \(progress.total)…")
                        .monospacedDigit()
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .frame(width: 120)
                    Text("\(progress.label)…")
                }
                if progress.canCancel {
                    Button("Cancel", action: model.cancelProgress)
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .shadow(radius: 4, y: 1)
            .padding(.bottom, 20)
        }
    }
}

/// "Add Image to Page": shown while the image is moved and resized.
private struct ImagePlacementBar: View {
    @ObservedObject var model: PDFViewModel

    var body: some View {
        if model.placingImage != nil, !model.isPresenting {
            HStack(spacing: 10) {
                Text("Drag the image to move it, or a corner to resize it.")
                Button("Cancel", action: model.cancelImagePlacement)
                    .keyboardShortcut(.cancelAction)
                Button("Place Image", action: model.placeImage)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .shadow(radius: 4, y: 1)
            .padding(.bottom, 20)
        }
    }
}

/// "Take a Snapshot": shown while the part of the page to save is dragged out.
private struct SnapshotBar: View {
    @ObservedObject var model: PDFViewModel

    var body: some View {
        if model.isTakingSnapshot, !model.isPresenting {
            HStack(spacing: 10) {
                Image(systemName: "camera")
                Text("Drag over the part of the page to save as JPG.")
                Button("Cancel", action: model.endSnapshot)
                    .keyboardShortcut(.cancelAction)
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
            HStack(spacing: 10) {
                Button("Open PDF…", action: tabs.showOpenPanel)
                    .buttonStyle(.borderedProminent)
                Button("New PDF…", action: tabs.showNewPDFPanel)
            }
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
