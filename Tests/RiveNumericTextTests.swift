import Foundation

@main
enum RiveNumericTextTests {
    static func main() {
        let accepted: [(String, RiveNumericText.Format)] = [
            ("1", .decimal), ("-.5", .decimal), (" 100% ", .percent),
            ("0.01 %", .percent), ("−25.5°", .degrees), ("+360 °", .degrees),
            ("50\u{00a0}%", .percent), ("0°", .degrees)
        ]
        for (text, format) in accepted {
            precondition(RiveNumericText.format(text) == format, "Recognize native numeric format")
        }
        for text in ["", "%", "°", "1%%", "1%°", "1 degree", "Scale 100%", "1 + 2°",
                     "1e3%", "NaN°", "1,000%", "1\n2%", "1% text", String(repeating: "1", count: 129)] {
            precondition(RiveNumericText.format(text) == nil, "Reject ambiguous nonnumeric text")
        }
        for text in ["100%", "45°", "−25.5°"] {
            precondition(NumericAdjustment.adjustedString(text, delta: 1) == nil,
                         "Recognition must not enable typed replacement of unit-bearing values")
        }
        print("RiveNumericTextTests passed")
    }
}
