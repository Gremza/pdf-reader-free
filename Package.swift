// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "PDFReader",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "PDFReader", path: "Sources/PDFReader")
    ]
)
