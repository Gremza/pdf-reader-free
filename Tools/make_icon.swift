// Generates Resources/AppIcon.icns. Run: swift Tools/make_icon.swift
import AppKit

func drawIcon(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024

    // Background squircle (macOS grid: 824pt body inside 1024 canvas)
    let bgRect = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let bg = NSBezierPath(roundedRect: bgRect, xRadius: 185 * s, yRadius: 185 * s)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowOffset = NSSize(width: 0, height: -12 * s)
    shadow.shadowBlurRadius = 24 * s
    shadow.set()
    NSColor(red: 0.85, green: 0.12, blue: 0.15, alpha: 1).setFill()
    bg.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: NSColor(red: 0.98, green: 0.30, blue: 0.27, alpha: 1),
               ending: NSColor(red: 0.74, green: 0.07, blue: 0.13, alpha: 1))!
        .draw(in: bg, angle: -90)

    // Document page with folded corner
    let page = NSRect(x: 290 * s, y: 215 * s, width: 444 * s, height: 580 * s)
    let fold = 120 * s
    let doc = NSBezierPath()
    doc.move(to: NSPoint(x: page.minX, y: page.minY))
    doc.line(to: NSPoint(x: page.maxX, y: page.minY))
    doc.line(to: NSPoint(x: page.maxX, y: page.maxY - fold))
    doc.line(to: NSPoint(x: page.maxX - fold, y: page.maxY))
    doc.line(to: NSPoint(x: page.minX, y: page.maxY))
    doc.close()
    NSGraphicsContext.saveGraphicsState()
    let pageShadow = NSShadow()
    pageShadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
    pageShadow.shadowOffset = NSSize(width: 0, height: -8 * s)
    pageShadow.shadowBlurRadius = 20 * s
    pageShadow.set()
    NSColor.white.setFill()
    doc.fill()
    NSGraphicsContext.restoreGraphicsState()

    let corner = NSBezierPath()
    corner.move(to: NSPoint(x: page.maxX - fold, y: page.maxY))
    corner.line(to: NSPoint(x: page.maxX - fold, y: page.maxY - fold))
    corner.line(to: NSPoint(x: page.maxX, y: page.maxY - fold))
    corner.close()
    NSColor(white: 0.82, alpha: 1).setFill()
    corner.fill()

    // Text lines
    NSColor(white: 0.85, alpha: 1).setFill()
    for (i, w) in [300.0, 340, 260].enumerated() {
        let y = page.maxY - 175 * s - CGFloat(i) * 52 * s
        NSBezierPath(roundedRect: NSRect(x: page.minX + 52 * s, y: y, width: CGFloat(w) * s, height: 22 * s),
                     xRadius: 11 * s, yRadius: 11 * s).fill()
    }

    // "PDF" label
    let pdfAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 150 * s, weight: .black),
        .foregroundColor: NSColor(red: 0.85, green: 0.12, blue: 0.15, alpha: 1),
        .kern: 4 * s,
    ]
    let pdf = NSAttributedString(string: "PDF", attributes: pdfAttrs)
    let pdfSize = pdf.size()
    pdf.draw(at: NSPoint(x: page.midX - pdfSize.width / 2, y: page.minY + 70 * s))

    // "FREE" ribbon badge
    let badge = NSRect(x: 560 * s, y: 150 * s, width: 300 * s, height: 120 * s)
    let badgePath = NSBezierPath(roundedRect: badge, xRadius: 60 * s, yRadius: 60 * s)
    NSGraphicsContext.saveGraphicsState()
    let badgeShadow = NSShadow()
    badgeShadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    badgeShadow.shadowOffset = NSSize(width: 0, height: -6 * s)
    badgeShadow.shadowBlurRadius = 14 * s
    badgeShadow.set()
    NSColor(red: 0.13, green: 0.73, blue: 0.40, alpha: 1).setFill()
    badgePath.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: NSColor(red: 0.25, green: 0.84, blue: 0.48, alpha: 1),
               ending: NSColor(red: 0.08, green: 0.62, blue: 0.33, alpha: 1))!
        .draw(in: badgePath, angle: -90)
    NSColor.white.setStroke()
    badgePath.lineWidth = 8 * s
    badgePath.stroke()

    let freeAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 74 * s, weight: .heavy),
        .foregroundColor: NSColor.white,
        .kern: 3 * s,
    ]
    let free = NSAttributedString(string: "FREE", attributes: freeAttrs)
    let freeSize = free.size()
    free.draw(at: NSPoint(x: badge.midX - freeSize.width / 2, y: badge.midY - freeSize.height / 2))

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try drawIcon(size: CGFloat(px)).representation(using: .png, properties: [:])!
            .write(to: iconset.appendingPathComponent(name))
    }
}
try drawIcon(size: 1024).representation(using: .png, properties: [:])!
    .write(to: root.appendingPathComponent("Resources/AppIcon.png"))

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try task.run()
task.waitUntilExit()
print(task.terminationStatus == 0 ? "OK: Resources/AppIcon.icns" : "iconutil failed")
