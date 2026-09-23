#!/usr/bin/env swift
import AppKit
import Foundation

// Original AppKit vector artwork for the native app icon. No device photo,
// vendor mark, or external asset is used.
private func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(calibratedRed: red, green: green, blue: blue, alpha: alpha)
}

private let graphite = color(0.075, 0.082, 0.080)
private let plate = color(0.132, 0.143, 0.139)
private let edge = color(0.262, 0.279, 0.270)
private let amber = color(0.850, 0.591, 0.257)
private let amberShade = color(0.483, 0.316, 0.145)

private func rounded(_ rect: NSRect, radius: CGFloat, fill: NSColor, stroke: NSColor? = nil,
                     lineWidth: CGFloat = 1) {
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    fill.setFill()
    path.fill()
    if let stroke {
        path.lineWidth = lineWidth
        stroke.setStroke()
        path.stroke()
    }
}

private func circle(center: NSPoint, radius: CGFloat, fill: NSColor) {
    let path = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius,
                                         width: radius * 2, height: radius * 2))
    fill.setFill()
    path.fill()
}

private func ring(center: NSPoint, radius: CGFloat, width: CGFloat, stroke: NSColor) {
    let path = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius,
                                         width: radius * 2, height: radius * 2))
    path.lineWidth = width
    stroke.setStroke()
    path.stroke()
}

private func render(_ size: Int) throws -> Data {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                       bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                       isPlanar: false, colorSpaceName: .deviceRGB,
                                       bytesPerRow: 0, bitsPerPixel: 0),
          let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw NSError(domain: "KDCustomIcon", code: 1)
    }
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = graphics
    graphics.shouldAntialias = true
    graphics.imageInterpolation = .high
    let transform = NSAffineTransform()
    transform.scale(by: CGFloat(size) / 1024)
    transform.concat()

    rounded(NSRect(x: 30, y: 30, width: 964, height: 964), radius: 214,
            fill: graphite, stroke: color(0.329, 0.339, 0.319), lineWidth: 9)
    rounded(NSRect(x: 74, y: 140, width: 876, height: 744), radius: 92,
            fill: plate, stroke: edge, lineWidth: 8)

    let dial = NSPoint(x: 338, y: 510)
    circle(center: dial, radius: 235, fill: color(0.090, 0.101, 0.098))
    ring(center: dial, radius: 225, width: 19, stroke: color(0.363, 0.374, 0.354))
    ring(center: dial, radius: 195, width: 31, stroke: amberShade)
    ring(center: dial, radius: 193, width: 15, stroke: amber)
    ring(center: dial, radius: 153, width: 9, stroke: color(0.480, 0.490, 0.461))
    circle(center: dial, radius: 130, fill: color(0.166, 0.177, 0.170))
    ring(center: dial, radius: 111, width: 8, stroke: color(0.315, 0.330, 0.311))
    circle(center: dial, radius: 77, fill: color(0.110, 0.121, 0.117))
    ring(center: dial, radius: 76, width: 6, stroke: color(0.424, 0.431, 0.404))
    circle(center: dial, radius: 15, fill: amber)
    rounded(NSRect(x: 326, y: 713, width: 24, height: 38), radius: 9, fill: amber)

    // Four keys above and below a slim OLED, echoing the K40's physical layout.
    let keyX: [CGFloat] = [582, 666, 750, 834]
    for (index, x) in keyX.enumerated() {
        for y: CGFloat in [627, 316] {
            rounded(NSRect(x: x, y: y, width: 65, height: 75), radius: 13,
                    fill: color(0.092, 0.103, 0.099),
                    stroke: color(0.349, 0.362, 0.342), lineWidth: 5)
            rounded(NSRect(x: x + 16, y: y + 27, width: 33, height: 8), radius: 4,
                    fill: index == 0 && y == 627 ? amber : color(0.514, 0.527, 0.489))
        }
    }
    rounded(NSRect(x: 576, y: 448, width: 329, height: 119), radius: 18,
            fill: color(0.044, 0.057, 0.052),
            stroke: color(0.366, 0.379, 0.350), lineWidth: 5)
    rounded(NSRect(x: 604, y: 528, width: 172, height: 9), radius: 4.5, fill: amber)
    for x: CGFloat in [604, 679, 754, 829] {
        rounded(NSRect(x: x, y: 478, width: 47, height: 12), radius: 5,
                fill: color(0.683, 0.664, 0.567))
    }

    graphics.flushGraphics()
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "KDCustomIcon", code: 2)
    }
    return data
}

private let sizes: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024)
]

let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let destination = repository.appendingPathComponent("Resources/AppIcon.icns")
let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("KDCustom-icon-\(UUID().uuidString)")
let iconset = temporary.appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }
for (name, size) in sizes {
    try render(size).write(to: iconset.appendingPathComponent(name), options: .atomic)
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", "-o", destination.path, iconset.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    throw NSError(domain: "KDCustomIcon", code: Int(iconutil.terminationStatus))
}
print(destination.path)
