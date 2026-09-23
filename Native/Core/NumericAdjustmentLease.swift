import Foundation

/// Main-thread invalidation is synchronous even when an AX call occupies the
/// serial worker. At most four dial requests can be queued or in flight.
final class NumericAdjustmentLease: @unchecked Sendable {
    struct Ticket: Sendable {
        let generation: UInt64
        let epoch: UInt64
        let token: String
        let revision: UInt64
    }

    private let lock = NSLock()
    private var current: Ticket?
    private var revision: UInt64 = 0
    private var pending = 0
    private var restoration: (ticket: Ticket, deadline: TimeInterval)?

    func publish(generation: UInt64, epoch: UInt64, token: String) {
        lock.lock(); defer { lock.unlock() }
        if current?.generation == generation && current?.epoch == epoch && current?.token == token {
            return
        }
        revision &+= 1
        restoration = nil
        current = Ticket(generation: generation, epoch: epoch, token: token, revision: revision)
    }

    func invalidate() {
        lock.lock(); defer { lock.unlock() }
        revision &+= 1
        restoration = nil
        current = nil
    }

    func cancelPending() {
        lock.lock(); defer { lock.unlock() }
        revision &+= 1
        restoration = nil
        if let current {
            self.current = Ticket(generation: current.generation, epoch: current.epoch,
                                  token: current.token, revision: revision)
        }
    }

    func reserve(generation: UInt64, epoch: UInt64, token: String) -> Ticket? {
        lock.lock(); defer { lock.unlock() }
        guard let current, current.generation == generation, current.epoch == epoch,
              current.token == token, pending < 4 else { return nil }
        pending += 1
        return current
    }

    func isCurrent(_ ticket: Ticket) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return matches(ticket)
    }

    private func matches(_ ticket: Ticket) -> Bool {
        return current?.generation == ticket.generation && current?.epoch == ticket.epoch &&
            current?.token == ticket.token && current?.revision == ticket.revision
    }

    /// Only the bounded Enter/refocus operation may defer its own AX focus
    /// notifications. Physical input and app/session changes still revoke it.
    func beginFocusRestoration(_ ticket: Ticket, deadline: TimeInterval) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard matches(ticket), deadline > ProcessInfo.processInfo.systemUptime else { return false }
        restoration = (ticket, deadline)
        return true
    }

    func defersFocusNotifications(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let restoration else { return false }
        return now <= restoration.deadline && matches(restoration.ticket)
    }

    func endFocusRestoration(_ ticket: Ticket) {
        lock.lock(); defer { lock.unlock() }
        if restoration?.ticket.revision == ticket.revision { restoration = nil }
    }

    func finish() {
        lock.lock(); defer { lock.unlock() }
        pending -= 1
    }
}
