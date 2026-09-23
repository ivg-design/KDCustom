#!/usr/bin/env swift
import AppKit
import Foundation

// Packaging only: generated master artwork is retained unchanged.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
guard let master = NSImage(contentsOf: root.appendingPathComponent("Resources/AppIcon-generated.png")) else { fatalError("Missing generated icon master") }
func png(size: Int, draw: () -> Void) -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGraphicsContext.current?.imageInterpolation = .high
    draw()
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}
let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("KDCustom-icon-\(UUID().uuidString)")
let iconset = temporary.appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }
for (name, size) in [("16x16",16),("16x16@2x",32),("32x32",32),("32x32@2x",64),
                     ("128x128",128),("128x128@2x",256),("256x256",256),("256x256@2x",512),
                     ("512x512",512),("512x512@2x",1024)] {
    try png(size: size) {
        master.draw(in: NSRect(x: 0,y: 0,width: size,height: size))
    }.write(to: iconset.appendingPathComponent("icon_\(name).png"))
}
let iconutil = Process(); iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c","icns","-o",root.appendingPathComponent("Resources/AppIcon.icns").path,iconset.path]
try iconutil.run(); iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
// Original small-scale template mark, designed to match the generated dial motif.
// macOS applies light/dark menu-bar tint; no baked color or tile background.
for scale in [1,2] {
    let data = png(size: 18 * scale) {
        let transform = NSAffineTransform(); transform.scale(by: CGFloat(scale)); transform.concat()
        NSColor.black.setStroke(); NSColor.black.setFill()
        for radius: CGFloat in [6.3,4.2] {
            let path = NSBezierPath(ovalIn: NSRect(x: 9-radius,y: 10-radius,width: radius*2,height: radius*2))
            path.lineWidth = 1.35; path.stroke()
        }
        let notch = NSBezierPath(); notch.move(to: NSPoint(x:12,y:13)); notch.line(to:NSPoint(x:14,y:15))
        notch.lineWidth=2; notch.lineCapStyle = .round; notch.stroke()
        for x: CGFloat in [3,11] {
            NSBezierPath(roundedRect:NSRect(x:x,y:0.5,width:4,height:2),xRadius:0.7,yRadius:0.7).fill()
        }
    }
    try data.write(to: root.appendingPathComponent("Resources/MenuBarTemplate\(scale == 2 ? "@2x" : "").png"))
}
print("AppIcon.icns and 18pt menu-bar templates packaged.")
