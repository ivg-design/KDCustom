import AppKit
import SwiftUI

/// Semantic UI colors follow the window appearance. Device materials remain
/// fixed so the hardware illustration reads as the same object in both modes.
enum StudioTheme {
    private static func rgb(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> NSColor {
        NSColor(calibratedRed: red, green: green, blue: blue, alpha: 1)
    }

    private static func semantic(_ name: String, dark: NSColor, light: NSColor) -> Color {
        Color(nsColor: NSColor(name: NSColor.Name("KDCustom.\(name)")) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    static let canvas = semantic("canvas", dark: rgb(0.075, 0.078, 0.077), light: rgb(0.946, 0.941, 0.921))
    static let panel = semantic("panel", dark: rgb(0.113, 0.117, 0.116), light: rgb(0.983, 0.979, 0.963))
    static let panelRaised = semantic("panelRaised", dark: rgb(0.145, 0.149, 0.147), light: rgb(0.899, 0.892, 0.862))
    static let divider = semantic("divider", dark: rgb(0.252, 0.258, 0.251), light: rgb(0.779, 0.773, 0.734))

    static let text = semantic("text", dark: rgb(0.924, 0.912, 0.877), light: rgb(0.113, 0.139, 0.122))
    static let secondaryText = semantic("secondaryText", dark: rgb(0.681, 0.681, 0.647), light: rgb(0.314, 0.361, 0.329))
    static let mutedText = semantic("mutedText", dark: rgb(0.476, 0.488, 0.466), light: rgb(0.441, 0.480, 0.441))
    static let accent = semantic("accent", dark: rgb(0.823, 0.582, 0.280), light: rgb(0.596, 0.338, 0.090))
    static let accentSoft = semantic("accentSoft", dark: rgb(0.373, 0.294, 0.190), light: rgb(0.918, 0.831, 0.681))

    // Fixed physical-device palette, including the OLED text.
    static let hardwareTop = Color(red: 0.195, green: 0.198, blue: 0.194)
    static let hardwareBottom = Color(red: 0.123, green: 0.126, blue: 0.124)
    static let hardwareEdge = Color(red: 0.323, green: 0.329, blue: 0.318)
    static let keyFace = Color(red: 0.154, green: 0.158, blue: 0.155)
    static let keyHover = Color(red: 0.218, green: 0.222, blue: 0.216)
    static let keyPressed = Color(red: 0.258, green: 0.231, blue: 0.176)
    static let display = Color(red: 0.055, green: 0.061, blue: 0.058)
    static let displayText = Color(red: 0.924, green: 0.912, blue: 0.877)
    static let displaySecondaryText = Color(red: 0.681, green: 0.681, blue: 0.647)
    static let dialCenter = Color(red: 0.105, green: 0.108, blue: 0.107)
    static let dialMetal = Color(red: 0.455, green: 0.459, blue: 0.441)

    static func font(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .custom("Helvetica Neue", size: size).weight(weight)
    }
}
