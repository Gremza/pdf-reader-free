// Generates every app icon from Resources/AppIcon.svg. Run: swift Tools/make_icon.swift
//   Resources/AppIcon.icns, Resources/AppIcon.png  macOS (artwork on Apple's icon grid)
//   windows/src/icon.png, docs/icon.png             Windows app and website (artwork edge to edge)
//   windows/installer/pdf.ico                       Windows icon of PDF files opened with the app
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
guard let artwork = NSImage(contentsOf: root.appendingPathComponent("Resources/AppIcon.svg")) else {
    fatalError("Resources/AppIcon.svg can't be read")
}

/// macOS icons keep the artwork at 824 of 1024 points with a soft shadow, so they match the other icons in the Dock.
func render(pixels: Int, macOSGrid: Bool) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    let s = CGFloat(pixels) / 1024
    var rect = NSRect(x: 0, y: 0, width: 1024 * s, height: 1024 * s)
    if macOSGrid {
        rect = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
        shadow.shadowOffset = NSSize(width: 0, height: -12 * s)
        shadow.shadowBlurRadius = 24 * s
        shadow.set()
    }
    artwork.draw(in: rect)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func write(_ rep: NSBitmapImageRep, to path: String) throws {
    try rep.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent(path))
}

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try render(pixels: base * scale, macOSGrid: true).representation(using: .png, properties: [:])!
            .write(to: iconset.appendingPathComponent(name))
    }
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try task.run()
task.waitUntilExit()
guard task.terminationStatus == 0 else { fatalError("iconutil failed") }

try write(render(pixels: 1024, macOSGrid: true), to: "Resources/AppIcon.png")
try write(render(pixels: 1024, macOSGrid: false), to: "windows/src/icon.png")
try write(render(pixels: 256, macOSGrid: false), to: "docs/icon.png")
// MARK: - PDF file icon (Windows)

/// A white page with a folded corner and the logo on it, so PDF files don't all look like the app itself.
func renderDocument(pixels: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    let s = CGFloat(pixels) / 256
    let line = max(1, (4 * s).rounded()) // at least one whole pixel, so small sizes stay crisp
    let left = 34 * s, right = 222 * s, bottom = 8 * s, top = 248 * s, fold = 56 * s
    let page = NSBezierPath()
    page.move(to: NSPoint(x: left, y: bottom))
    page.line(to: NSPoint(x: right, y: bottom))
    page.line(to: NSPoint(x: right, y: top - fold))
    page.line(to: NSPoint(x: right - fold, y: top))
    page.line(to: NSPoint(x: left, y: top))
    page.close()
    page.lineWidth = line
    page.lineJoinStyle = .round
    NSColor.white.setFill()
    page.fill()
    NSColor(white: 0.55, alpha: 1).setStroke()
    page.stroke()
    let corner = NSBezierPath()
    corner.move(to: NSPoint(x: right - fold, y: top))
    corner.line(to: NSPoint(x: right - fold, y: top - fold))
    corner.line(to: NSPoint(x: right, y: top - fold))
    corner.lineWidth = line
    corner.lineJoinStyle = .round
    NSColor(white: 0.9, alpha: 1).setFill()
    corner.fill()
    corner.stroke()
    let logo = 136 * s
    artwork.draw(in: NSRect(x: (256 * s - logo) / 2, y: 36 * s, width: logo, height: logo))
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

/// An .ico holds PNG images; Windows picks the size it needs.
func writeICO(sizes: [Int], to path: String) throws {
    let images = sizes.map { renderDocument(pixels: $0).representation(using: .png, properties: [:])! }
    var data = Data()
    func le16(_ v: Int) { data.append(contentsOf: [UInt8(v & 0xff), UInt8(v >> 8 & 0xff)]) }
    func le32(_ v: Int) { le16(v & 0xffff); le16(v >> 16) }
    le16(0); le16(1); le16(images.count)
    var offset = 6 + 16 * images.count
    for (size, png) in zip(sizes, images) {
        data.append(contentsOf: [UInt8(size % 256), UInt8(size % 256), 0, 0]) // 256 is written as 0
        le16(1); le16(32); le32(png.count); le32(offset)
        offset += png.count
    }
    images.forEach { data.append($0) }
    try data.write(to: root.appendingPathComponent(path))
}

try writeICO(sizes: [16, 20, 24, 32, 40, 48, 64, 256], to: "windows/installer/pdf.ico")
print("OK: Resources/AppIcon.icns, Resources/AppIcon.png, windows/src/icon.png, docs/icon.png, windows/installer/pdf.ico")
