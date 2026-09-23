import Foundation

/// Conservative metadata hints. A hint permits a strict numeric AX value check;
/// it is never itself evidence that a text field is writable or numeric.
enum SmartDialHeuristics {
    static func allowsTextField(_ focus: FocusSnapshot, detection: SmartDialDetection) -> Bool {
        guard focus.kind == .text else { return false }
        if detection == .numericField { return true }
        guard let bundle = focus.bundleIdentifier?.lowercased(),
              bundle == "app.rive.editor" || bundle == "app.rive.ea-editor" || bundle.hasPrefix("app.rive.editor.") ||
              bundle.hasPrefix("com.adobe.") else { return false }
        let names: Set<String> = ["x", "y", "z", "w", "h", "width", "height", "rotation", "angle",
            "opacity", "scale", "scale x", "scale y", "position x", "position y", "position z",
            "size", "font size", "stroke width", "radius", "corner radius", "tracking", "leading"]
        return [focus.label, focus.identifier].compactMap { $0 }.contains {
            let normalized = $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            return names.contains(normalized)
        }
    }
}
