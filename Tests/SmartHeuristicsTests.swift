import Foundation
@main enum SmartHeuristicsTests {
    static func main() {
        func allows(_ bundle: String, _ label: String, kind: FocusKind = .text, mode: SmartDialDetection = .automatic) -> Bool {
            SmartDialHeuristics.allowsTextField(FocusSnapshot(bundleIdentifier: bundle, label: label, kind: kind), detection: mode)
        }
        precondition(allows("app.rive.editor", "Width"))
        precondition(allows("app.rive.ea-editor", "Height"))
        precondition(allows("com.adobe.AfterEffects", "Opacity"))
        precondition(!allows("app.rive.editor", "Project width name"))
        precondition(!allows("other.app", "Width"))
        precondition(!allows("app.rive.editor", "Width", kind: .secure, mode: .numericField))
        precondition(allows("custom.app", "Custom parameter", mode: .numericField))
        print("SmartHeuristicsTests passed")
    }
}
