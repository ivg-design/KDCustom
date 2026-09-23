import SwiftUI

/// Shared visual tokens for the native Keydial Studio surface.
enum StudioTheme {
    static let canvas = Color(red: 0.075, green: 0.078, blue: 0.077)
    static let panel = Color(red: 0.113, green: 0.117, blue: 0.116)
    static let panelRaised = Color(red: 0.145, green: 0.149, blue: 0.147)
    static let divider = Color(red: 0.252, green: 0.258, blue: 0.251)

    static let hardwareTop = Color(red: 0.195, green: 0.198, blue: 0.194)
    static let hardwareBottom = Color(red: 0.123, green: 0.126, blue: 0.124)
    static let hardwareEdge = Color(red: 0.323, green: 0.329, blue: 0.318)
    static let keyFace = Color(red: 0.154, green: 0.158, blue: 0.155)
    static let keyHover = Color(red: 0.218, green: 0.222, blue: 0.216)
    static let keyPressed = Color(red: 0.258, green: 0.231, blue: 0.176)
    static let display = Color(red: 0.055, green: 0.061, blue: 0.058)
    static let dialCenter = Color(red: 0.105, green: 0.108, blue: 0.107)
    static let dialMetal = Color(red: 0.455, green: 0.459, blue: 0.441)

    static let text = Color(red: 0.924, green: 0.912, blue: 0.877)
    static let secondaryText = Color(red: 0.681, green: 0.681, blue: 0.647)
    static let mutedText = Color(red: 0.476, green: 0.488, blue: 0.466)
    static let accent = Color(red: 0.823, green: 0.582, blue: 0.280)
    static let accentSoft = Color(red: 0.373, green: 0.294, blue: 0.190)

    static func font(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .custom("Helvetica Neue", size: size).weight(weight)
    }
}
