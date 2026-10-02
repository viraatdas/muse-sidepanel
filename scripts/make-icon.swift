// Renders Resources/AppIcon.icns. Run: swift scripts/make-icon.swift
import AppKit

func render(_ pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(pixels) / 1024
    let tile = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let shape = NSBezierPath(roundedRect: tile, xRadius: 186 * s, yRadius: 186 * s)
    NSGradient(colors: [NSColor(red: 0.36, green: 0.30, blue: 0.96, alpha: 1),
                        NSColor(red: 0.07, green: 0.09, blue: 0.24, alpha: 1)])!.draw(in: shape, angle: -70)

    // A window outline with the side panel filled in.
    let window = NSRect(x: 262 * s, y: 312 * s, width: 500 * s, height: 400 * s)
    let outline = NSBezierPath(roundedRect: window, xRadius: 64 * s, yRadius: 64 * s)
    outline.lineWidth = 34 * s
    NSColor.white.withAlphaComponent(0.55).setStroke()
    outline.stroke()
    let panel = NSRect(x: 560 * s, y: 356 * s, width: 158 * s, height: 312 * s)
    NSColor.white.setFill()
    NSBezierPath(roundedRect: panel, xRadius: 36 * s, yRadius: 36 * s).fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("build/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    try render(points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try render(points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
