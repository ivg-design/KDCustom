import Foundation

@main
enum RiveArrowBurstTests {
    static func main() {
        let context = RiveShortcutBuffer.Context(pid: 55, profile: "rive", revision: "a", group: "2", focusToken: "field")
        let nextField = RiveShortcutBuffer.Context(pid: 55, profile: "rive", revision: "a", group: "2", focusToken: "other")
        let up = SmartShortcut(keyCode: 126)
        let down = SmartShortcut(keyCode: 125, modifiers: .command)
        var burst = RiveArrowBurst()
        var events: [RiveArrowBurst.Event] = []
        let emit: (RiveArrowBurst.Event) -> Bool = { events.append($0); return true }
        precondition(burst.step(up, context: context, now: 10, emit: emit))
        for n in 1...10 {
            precondition(burst.step(up, context: context, now: 10 + Double(n) * 0.02, emit: emit))
        }
        precondition(events.count == 11 && events.allSatisfy(\.down), "Exactly one down per detent")
        precondition(!events[0].isRepeat && events.dropFirst().allSatisfy(\.isRepeat), "Held-arrow repeat semantics")
        burst.tick(now: 10.24, emit: emit)
        precondition(events.count == 11, "Tick never generates additional increments")
        burst.tick(now: 10.3, emit: emit)
        precondition(events.count == 12 && events.last?.down == false, "Idle releases once")
        burst.tick(now: 11, emit: emit)
        precondition(events.count == 12, "Idle release is not repeated")
        precondition(burst.step(up, context: context, now: 12, emit: emit))
        precondition(burst.step(down, context: context, now: 12.02, emit: emit))
        precondition(events.suffix(2).map(\.keyCode) == [126, 125] &&
                     events.suffix(2).map(\.down) == [false, true] &&
                     events.last?.modifiers == .command && events.last?.isRepeat == false,
                     "Direction/modifier changes release the old key before the new down")
        precondition(burst.step(down, context: nextField, now: 12.04, emit: emit))
        precondition(events.suffix(2).map(\.down) == [false, true] && events.last?.isRepeat == false,
                     "A new context never inherits a held repeat")
        precondition(burst.end(emit: emit)); let count = events.count
        precondition(burst.end(emit: emit) && events.count == count, "Cancellation releases exactly once")
        precondition(burst.step(up, context: context, now: 13, emit: emit))
        precondition(!burst.step(up, context: context, now: 13.02, emit: { event in
            events.append(event); return !event.down
        }))
        precondition(events.last?.down == false, "Rejected repeat attempts release the owned arrow")
        let rejectedCount = events.count
        precondition(!burst.step(.init(keyCode: 36), context: context, now: 14, emit: emit))
        precondition(events.count == rejectedCount, "Enter and other keys cannot enter this path")
        precondition(!burst.step(up, context: context, now: .nan, emit: emit))
        precondition(burst.step(up, context: context, now: 15, emit: emit))
        precondition(!burst.end(emit: { _ in false }), "Failed release stays owned for cleanup retry")
        precondition(burst.end(emit: emit) && events.last?.down == false)
        print("RiveArrowBurstTests passed")
    }
}
