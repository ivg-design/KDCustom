import Foundation

@main
enum NumericAdjustmentTests {
    static func check(_ condition: Bool, _ message: String) {
        if !condition { fatalError(message) }
    }

    static func main() {
        var value = "0"
        for _ in 0..<10 {
            value = NumericAdjustment.adjustedString(value, delta: 0.01)!
        }
        check(value == "0.1", "ten hundredth steps are decimal-exact")
        check(NumericAdjustment.adjustedString(" \t-1.25\n", delta: 0.01) == "-1.24",
              "signed plain decimal with surrounding whitespace is accepted")
        check(NumericAdjustment.adjustedString(".5", delta: -0.01) == "0.49",
              "leading decimal point is accepted")
        check(NumericAdjustment.adjustedString("5.", delta: -0.5) == "4.5",
              "trailing decimal point is accepted")
        check(NumericAdjustment.adjustedString("9.99", delta: 1, minimum: 0, maximum: 10) == "10",
              "advertised maximum clamps output")
        check(NumericAdjustment.adjustedString("-9.99", delta: -1, minimum: -10, maximum: 10) == "-10",
              "advertised minimum clamps output")
        check(NumericAdjustment.adjustedNumber(NSNumber(value: 0.1), delta: 0.01)?.doubleValue == 0.11,
              "CFNumber-shaped input uses decimal calculation")
        check(NumericAdjustment.validDelta(0.000001) &&
              NumericAdjustment.adjustedString("1", delta: 0.000001) == "1.000001",
              "permitted fine step works when Double stringifies with an exponent")
        check(NumericAdjustment.adjustedNumber(NSNumber(value: 0.000001), delta: 0.000001)?.doubleValue == 0.000002,
              "small CFNumber-shaped values are converted without partial parsing")
        check(NumericAdjustment.adjustedNumber(NSNumber(value: 0.000001), delta: -0.000001,
                                               minimum: 0.0000005, maximum: 0.000002)?.doubleValue == 0.0000005 &&
              NumericAdjustment.adjustedString("0.000001", delta: 0.000001,
                                                minimum: 0.0000005, maximum: 0.0000015) == "0.0000015",
              "small advertised bounds clamp numeric and string values")

        for ambiguous in ["", "-", ".", "1+2", "1e3", "1,000", "12 px", "0.5%", "NaN", "∞", "1\n2"] {
            check(NumericAdjustment.adjustedString(ambiguous, delta: 1) == nil,
                  "ambiguous field content is rejected: \(ambiguous)")
        }
        check(NumericAdjustment.adjustedString("1", delta: .infinity) == nil &&
              NumericAdjustment.adjustedString("1", delta: .nan) == nil &&
              NumericAdjustment.adjustedString("1", delta: 0) == nil &&
              NumericAdjustment.adjustedString("1", delta: 1_000_001) == nil,
              "nonfinite, zero and excessive deltas are rejected")
        check(NumericAdjustment.adjustedString("1", delta: 1, minimum: 2, maximum: 1) == nil &&
              NumericAdjustment.adjustedString("1", delta: 1, minimum: .nan) == nil,
              "invalid bounds never produce a write")
        check(NumericAdjustment.adjustedString("1e-6", delta: 0.000001) == nil,
              "scientific notation in external AX field strings stays unsupported")
        check(NumericAdjustment.adjustedString(String(repeating: "9", count: 19), delta: 1) == nil,
              "high precision or magnitude input is rejected")
        check(NumericAdjustment.arrowCommitPlan(target: "0.02", step: 1) ==
              .init(draft: "1.02", keyCode: 125), "Down commits a compensated hundredth draft")
        check(NumericAdjustment.arrowCommitPlan(target: "-1.001", step: 0.1) ==
              .init(draft: "-0.901", keyCode: 125), "negative fine values compensate exactly")
        check(NumericAdjustment.arrowCommitPlan(target: "10", step: 1, minimum: 0, maximum: 10) ==
              .init(draft: "9", keyCode: 126), "near maximum use Up without clamping the draft")
        check(NumericAdjustment.arrowCommitPlan(target: "0", step: 1, minimum: 0, maximum: 10) ==
              .init(draft: "1", keyCode: 125), "near minimum Down remains valid")
        check(NumericAdjustment.arrowCommitPlan(target: "0.5", step: 1, minimum: 0, maximum: 1) == nil,
              "a range too narrow for compensation is rejected before typing")
        for badStep in [0.0, -1, .nan, .infinity, 1_000_001] {
            check(NumericAdjustment.arrowCommitPlan(target: "1", step: badStep) == nil,
                  "invalid native step is rejected")
        }
        check(NumericAdjustment.arrowCommitPlan(target: "1 px", step: 1) == nil &&
              NumericAdjustment.arrowCommitPlan(target: "1", step: 1, minimum: 2, maximum: 1) == nil &&
              NumericAdjustment.arrowCommitPlan(target: "1", step: 1, maximum: .nan) == nil,
              "ambiguous target and invalid bounds never produce a plan")
        var committed = "0"
        for delta in Array(repeating: 0.01, count: 100) + Array(repeating: -0.01, count: 100) {
            let target = NumericAdjustment.adjustedString(committed, delta: delta)!
            let plan = NumericAdjustment.arrowCommitPlan(target: target, step: 1)!
            committed = NumericAdjustment.adjustedString(plan.draft, delta: plan.keyCode == 125 ? -1 : 1)!
            check(NumericAdjustment.equalValues(committed, target), "native arrow produces the exact target")
        }
        check(committed == "0", "repeated compensated hundredths do not accumulate drift")
        print("NumericAdjustmentTests passed")
    }
}
