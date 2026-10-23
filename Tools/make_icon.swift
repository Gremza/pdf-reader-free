// Generates every app icon from Resources/AppIcon.svg. Run: swift Tools/make_icon.swift
//   Resources/AppIcon.icns, Resources/AppIcon.png  macOS (artwork on Apple's icon grid)
//   windows/src/icon.png, docs/icon.png             Windows app and website (artwork edge to edge)
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
print("OK: Resources/AppIcon.icns, Resources/AppIcon.png, windows/src/icon.png, docs/icon.png")
