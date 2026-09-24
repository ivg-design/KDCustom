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
        precondition(burst.step(up, context: context, now: 10, minimumInterval: 0, emit: emit) == .sent)
        for n in 1...10 {
            precondition(burst.step(up, context: context, now: 10 + Double(n) * 0.02, minimumInterval: 0, emit: emit) == .sent)
        }
        precondition(events.count == 11 && events.allSatisfy(\.down), "Exactly one down per detent")
        precondition(!events[0].isRepeat && events.dropFirst().allSatisfy(\.isRepeat), "Held-arrow repeat semantics")
        burst.tick(now: 10.24, emit: emit)
        precondition(events.count == 11, "Tick never generates additional increments")
        burst.tick(now: 10.3, emit: emit)
        precondition(events.count == 12 && events.last?.down == false, "Idle releases once")
        burst.tick(now: 11, emit: emit)
        precondition(events.count == 12, "Idle release is not repeated")
        precondition(burst.step(up, context: context, now: 12, minimumInterval: 0, emit: emit) == .sent)
        precondition(burst.step(down, context: context, now: 12.02, minimumInterval: 0, emit: emit) == .sent)
        precondition(events.suffix(2).map(\.keyCode) == [126, 125] &&
                     events.suffix(2).map(\.down) == [false, true] &&
                     events.last?.modifiers == .command && events.last?.isRepeat == false,
                     "Direction/modifier changes release the old key before the new down")
        precondition(burst.step(down, context: nextField, now: 12.04, minimumInterval: 0, emit: emit) == .sent)
        precondition(events.suffix(2).map(\.down) == [false, true] && events.last?.isRepeat == false,
                     "A new context never inherits a held repeat")
        precondition(burst.end(emit: emit)); let count = events.count
        precondition(burst.end(emit: emit) && events.count == count, "Cancellation releases exactly once")
        precondition(burst.step(up, context: context, now: 13, minimumInterval: 0, emit: emit) == .sent)
        precondition(burst.step(up, context: context, now: 13.02, minimumInterval: 0, emit: { event in
            events.append(event); return !event.down
        }) == .unavailable)
        precondition(events.last?.down == false, "Rejected repeat attempts release the owned arrow")
        let rejectedCount = events.count
        precondition(burst.step(.init(keyCode: 36), context: context, now: 14, minimumInterval: 0, emit: emit) == .unavailable)
        precondition(events.count == rejectedCount, "Enter and other keys cannot enter this path")
        precondition(burst.step(up, context: context, now: .nan, minimumInterval: 0, emit: emit) == .unavailable)
        precondition(burst.step(up, context: context, now: 15, minimumInterval: 0, emit: emit) == .sent)
        precondition(!burst.end(emit: { _ in false }), "Failed release stays owned for cleanup retry")
        precondition(burst.end(emit: emit) && events.last?.down == false)
        events.removeAll()
        var skipped = 0
        for n in 0...25 {
            let delivery = burst.step(up, context: context, now: 20 + Double(n) * 0.02,
                                      emit: emit)
            if delivery == .filtered { skipped += 1 }
            else { precondition(delivery == .sent) }
            burst.tick(now: 20 + Double(n) * 0.02, emit: emit)
        }
        precondition(skipped == 20 && events.count == 6 && events.allSatisfy(\.down),
                     "Production default skips excess repeats and retains a continuous hold")
        precondition(!events[0].isRepeat && events.dropFirst().allSatisfy(\.isRepeat))
        burst.tick(now: 20.6, emit: emit)
        precondition(events.count == 7 && events.last?.down == false,
                     "Stopping releases immediately after idle, without catch-up downs")
        precondition(burst.step(up, context: context, now: 21, emit: emit) == .sent)
        precondition(burst.step(up, context: context, now: 21.02, emit: emit) == .filtered)
        precondition(burst.step(down, context: context, now: 21.04, emit: emit) == .filtered)
        precondition(events.last?.down == false && events.last?.keyCode == 126,
                     "Reversal releases immediately but cannot bypass the production rate")
        precondition(burst.step(down, context: nextField, now: 21.05, emit: emit) == .filtered,
                     "Focus and context resets cannot bypass the production rate")
        precondition(burst.step(down, context: nextField, now: 21.1, emit: emit) == .sent)
        precondition(events.last?.keyCode == 125 && events.last?.isRepeat == false,
                     "First admitted detent after a reversal starts a new hold")
        precondition(burst.step(down, context: nextField, now: 21.11, minimumInterval: 0, emit: emit) == .sent,
                     "Explicit uncapped primitive retains one down per detent")
        precondition(burst.step(up, context: context, now: 22, minimumInterval: .nan, emit: emit) == .unavailable)
        // The production default is independent of a five-minute diagnostic or prior context.
        precondition(burst.step(up, context: context, now: 1000, emit: emit) == .sent)
        precondition(burst.step(up, context: context, now: 1000.02, emit: emit) == .filtered)
        precondition(burst.step(down, context: nextField, now: 1000.04, emit: emit) == .filtered)
        precondition(events.last?.down == false, "Context changes still release at the permanent rate")
        precondition(burst.step(down, context: nextField, now: 1000.1, emit: emit) == .sent)
        precondition(events.last?.modifiers == .command, "Pacing preserves configured modifiers")
        burst.tick(now: 1001, emit: emit)
        var restarted = RiveArrowBurst()
        precondition(restarted.step(up, context: context, now: 2000, emit: emit) == .sent)
        precondition(restarted.step(up, context: context, now: 2000.02, emit: emit) == .filtered,
                     "Fresh app state defaults to the permanent cap without a diagnostic")
        print("RiveArrowBurstTests passed")
    }
}
