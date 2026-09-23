import Foundation

/// Only the result crosses back from an explicit AX numeric edit. The value
/// itself is never delivered to the app model, logs, or MCP bridge.
enum NumericAdjustmentResult: Sendable {
    case applied
    case unsupported
    case cancelled
    case failed
    case focusRestoreFailed
    case draftNotConfirmed
    case arrowCommitNotConfirmed
    case tabAdvanceNotConfirmed
    case tabReturnNotConfirmed

    /// These outcomes follow an attempted keyboard write or commit. A later
    /// detent must not silently continue in a field reached by a failed return.
    var needsFieldReselection: Bool {
        switch self {
        case .failed, .focusRestoreFailed, .draftNotConfirmed, .arrowCommitNotConfirmed,
             .tabAdvanceNotConfirmed, .tabReturnNotConfirmed: return true
        case .applied, .unsupported, .cancelled: return false
        }
    }
}

/// Pure, bounded arithmetic for an explicitly requested dial adjustment.
/// AX strings must contain a plain decimal only; units, expressions, grouping
/// separators and exponents have app-specific meaning and are left untouched.
enum NumericAdjustment {
    struct ArrowCommitPlan: Equatable {
        let draft: String
        let keyCode: UInt16
    }
    static let maximumMagnitude = 1_000_000_000_000.0
    static let maximumDelta = 1_000_000.0
    private static let decimalLocale = Locale(identifier: "en_US_POSIX")

    static func validDelta(_ delta: Double) -> Bool {
        delta.isFinite && delta != 0 && abs(delta) <= maximumDelta &&
            trustedDecimal(delta) != nil
    }

    static func equalValues(_ first: String, _ second: String) -> Bool {
        guard let a = plainDecimal(first.trimmingCharacters(in: .whitespacesAndNewlines)),
              let b = plainDecimal(second.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return a == b
    }

    /// Compensate for exactly one native arrow step. Both the draft and final
    /// value must fit the known bounds; never silently clamp the draft.
    static func arrowCommitPlan(target: String, step: Double,
                                minimum: Double? = nil, maximum: Double? = nil) -> ArrowCommitPlan? {
        guard step > 0, validDelta(step), equalValues(target, target) else { return nil }
        for (offset, key): (Double, UInt16) in [(step, 125), (-step, 126)] {
            guard let draft = adjustedString(target, delta: offset),
                  let boundedDraft = adjustedString(target, delta: offset, minimum: minimum, maximum: maximum),
                  equalValues(draft, boundedDraft),
                  let final = adjustedString(draft, delta: -offset, minimum: minimum, maximum: maximum),
                  equalValues(final, target) else { continue }
            return ArrowCommitPlan(draft: draft, keyCode: key)
        }
        return nil
    }

    static func adjustedString(_ original: String, delta: Double,
                               minimum: Double? = nil, maximum: Double? = nil) -> String? {
        let trimmed = original.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let current = plainDecimal(trimmed),
              let next = adjusted(current, delta: delta, minimum: minimum, maximum: maximum)
        else { return nil }
        return NSDecimalNumber(decimal: next).stringValue
    }

    static func adjustedNumber(_ original: NSNumber, delta: Double,
                               minimum: Double? = nil, maximum: Double? = nil) -> NSNumber? {
        let value = original.doubleValue
        guard value.isFinite, abs(value) <= maximumMagnitude,
              let current = Decimal(string: original.stringValue, locale: decimalLocale),
              let next = adjusted(current, delta: delta, minimum: minimum, maximum: maximum)
        else { return nil }
        let text = NSDecimalNumber(decimal: next).stringValue
        guard let converted = Double(text), converted.isFinite else { return nil }
        return NSNumber(value: converted)
    }

    private static func adjusted(_ current: Decimal, delta: Double,
                                 minimum: Double?, maximum: Double?) -> Decimal? {
        guard validDelta(delta),
              let step = trustedDecimal(delta),
              let lower = decimalBound(minimum), let upper = decimalBound(maximum) else { return nil }
        if let lower, let upper, lower > upper { return nil }
        var left = current
        var right = step
        var sum = Decimal()
        guard NSDecimalAdd(&sum, &left, &right, .plain) == .noError else { return nil }
        if let lower, sum < lower { sum = lower }
        if let upper, sum > upper { sum = upper }
        let converted = NSDecimalNumber(decimal: sum).doubleValue
        guard converted.isFinite, abs(converted) <= maximumMagnitude else { return nil }
        return sum
    }

    /// An absent bound is valid; a present nonfinite or excessive bound is not.
    private static func decimalBound(_ value: Double?) -> Decimal?? {
        guard let value else { return .some(nil) }
        guard value.isFinite, abs(value) <= maximumMagnitude,
              let decimal = trustedDecimal(value) else { return nil }
        return .some(decimal)
    }

    /// The spelling here comes from a finite Double, not an untrusted AX
    /// string. Foundation's Decimal parser accepts its scientific notation;
    /// the separate AX string parser below deliberately does not.
    private static func trustedDecimal(_ value: Double) -> Decimal? {
        guard value.isFinite, abs(value) <= maximumMagnitude,
              let decimal = Decimal(string: String(value), locale: decimalLocale),
              value == 0 || decimal != 0 else { return nil }
        return decimal
    }

    private static func plainDecimal(_ text: String) -> Decimal? {
        let bytes = Array(text.utf8)
        guard !bytes.isEmpty, bytes.count <= 64 else { return nil }
        var index = 0
        if bytes[0] == 43 || bytes[0] == 45 { index = 1 }
        var digits = 0
        var fractionDigits = 0
        var dotSeen = false
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 46 && !dotSeen {
                dotSeen = true
            } else if (48...57).contains(byte) {
                digits += 1
                if dotSeen { fractionDigits += 1 }
            } else {
                return nil
            }
            index += 1
        }
        guard digits > 0, digits <= 18, fractionDigits <= 12,
              let result = Decimal(string: text, locale: decimalLocale),
              abs(NSDecimalNumber(decimal: result).doubleValue) <= maximumMagnitude else { return nil }
        return result
    }
}
