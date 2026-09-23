import Foundation

/// Fast turns accumulate as decimal runs while a text edit is in flight.
/// Direction reversals retain order because clamping can make + then - differ
/// from their net sum. Overflow is explicit; no accepted detent is discarded.
struct NumericStepBuffer {
    struct Batch {
        let delta: Double
        let detents: Int
    }
    private struct Run {
        var amount: Decimal
        var detents: Int
    }
    private var runs: [Run] = []
    private(set) var pendingCount = 0
    static let capacity = 256

    mutating func append(_ delta: Double) -> Bool {
        guard NumericAdjustment.validDelta(delta), pendingCount < Self.capacity,
              let amount = Decimal(string: String(delta), locale: Locale(identifier: "en_US_POSIX")) else { return false }
        if let last = runs.last, (last.amount > 0) == (amount > 0) {
            var left = last.amount, right = amount, total = Decimal()
            if NSDecimalAdd(&total, &left, &right, .plain) == .noError,
               NumericAdjustment.validDelta(NSDecimalNumber(decimal: total).doubleValue) {
                runs[runs.count - 1] = Run(amount: total, detents: last.detents + 1)
                pendingCount += 1
                return true
            }
        }
        runs.append(Run(amount: amount, detents: 1)); pendingCount += 1
        return true
    }

    mutating func take() -> Batch? {
        guard !runs.isEmpty else { return nil }
        let run = runs.removeFirst(); pendingCount -= run.detents
        // Parse the canonical decimal spelling; NSDecimalNumber.doubleValue
        // can produce the adjacent Double for values such as 0.11.
        let delta = Double(NSDecimalNumber(decimal: run.amount).stringValue)!
        return Batch(delta: delta, detents: run.detents)
    }

    mutating func removeAll() { runs.removeAll(); pendingCount = 0 }
}
