import Foundation

/// Detents arriving during AX focus verification may run only after the exact
/// original route is confirmed. Never replay across a field or input boundary.
struct RiveShortcutBuffer {
    struct Context: Equatable {
        let pid: Int32
        let profile: String
        let revision: String
        let group: String
        let focusToken: String
    }
    struct Step: Equatable {
        let control: ControlID
        let selectors: KeyModifiers
        let shortcut: SmartShortcut
    }
    private var context: Context?
    private var startedAt: TimeInterval?
    private var steps: [Step] = []
    static let lifetime: TimeInterval = 0.5
    static let capacity = 64

    mutating func clear() { context = nil; startedAt = nil; steps.removeAll() }

    mutating func append(_ step: Step, context: Context, now: TimeInterval) -> Bool {
        guard now.isFinite else { clear(); return false }
        if let startedAt, (now < startedAt || now - startedAt > Self.lifetime || self.context != context) {
            clear(); return false
        }
        guard steps.count < Self.capacity else { clear(); return false }
        self.context = context
        if startedAt == nil { startedAt = now }
        steps.append(step)
        return true
    }

    mutating func take(context: Context?, now: TimeInterval) -> [Step] {
        defer { clear() }
        guard let context, self.context == context, let startedAt, now.isFinite,
              now >= startedAt, now - startedAt <= Self.lifetime else { return [] }
        return steps
    }
}
