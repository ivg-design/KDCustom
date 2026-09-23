import Foundation

@main
enum NumericAdjustmentLeaseTests {
    static func main() {
        let lease = NumericAdjustmentLease()
        let now = ProcessInfo.processInfo.systemUptime
        lease.publish(generation: 1, epoch: 2, token: "field")
        let ticket = lease.reserve(generation: 1, epoch: 2, token: "field")!
        precondition(!lease.defersFocusNotifications())
        precondition(lease.beginFocusRestoration(ticket, deadline: now + 10))
        precondition(lease.defersFocusNotifications(now: now + 1))
        precondition(!lease.defersFocusNotifications(now: now + 11), "Focus deferral is bounded")
        lease.cancelPending()
        precondition(!lease.isCurrent(ticket) && !lease.defersFocusNotifications(),
                     "Physical editing cancels restoration immediately")
        precondition(!lease.beginFocusRestoration(ticket, deadline: now + 10))
        lease.finish()

        let next = lease.reserve(generation: 1, epoch: 2, token: "field")!
        precondition(lease.beginFocusRestoration(next, deadline: now + 10))
        lease.endFocusRestoration(ticket)
        precondition(lease.defersFocusNotifications(), "Old completion cannot close newer restoration")
        lease.endFocusRestoration(next)
        precondition(!lease.defersFocusNotifications() && lease.isCurrent(next))
        precondition(lease.beginFocusRestoration(next, deadline: now + 10))
        lease.invalidate()
        precondition(!lease.defersFocusNotifications() && !lease.isCurrent(next),
                     "App, session and focus invalidation revoke restoration")
        lease.finish()

        lease.publish(generation: 2, epoch: 0, token: "other")
        let other = lease.reserve(generation: 2, epoch: 0, token: "other")!
        precondition(!lease.beginFocusRestoration(other, deadline: now - 1))
        precondition(lease.beginFocusRestoration(other, deadline: now + 10))
        lease.publish(generation: 2, epoch: 0, token: "different-field")
        precondition(!lease.defersFocusNotifications() && !lease.isCurrent(other))
        lease.finish()
        print("NumericAdjustmentLease tests passed")
    }
}
