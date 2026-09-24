import Foundation

/// Classifies a focused Rive field for native shortcut routing only. This does
/// not parse a replacement value or authorize the typed-numeric write path.
enum RiveNumericText {
    enum Format: String, Sendable { case decimal, percent, degrees }

    static func format(_ text: String) -> Format? {
        guard text.utf8.count <= 128 else { return nil }
        var number = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let format: Format
        if number.hasSuffix("%") { format = .percent; number.removeLast() }
        else if number.hasSuffix("°") { format = .degrees; number.removeLast() }
        else { format = .decimal }
        number = number.trimmingCharacters(in: .whitespaces)
        if number.hasPrefix("−") { number.replaceSubrange(number.startIndex...number.startIndex, with: "-") }
        return NumericAdjustment.equalValues(number, number) ? format : nil
    }
}
