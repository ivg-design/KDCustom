import Foundation

@main
enum RiveShortcutBufferTests {
    static func context(pid: Int32 = 55, profile: String = "rive", revision: String = "a",
                        group: String = "2", field: String = "field") -> RiveShortcutBuffer.Context {
        .init(pid: pid, profile: profile, revision: revision, group: group, focusToken: field)
    }
    static func main() {
        var buffer = RiveShortcutBuffer()
        let down = RiveShortcutBuffer.Step(control: .dial1CW, selectors: .shift,
                                          shortcut: .init(keyCode: 125, modifiers: .shift))
        let up = RiveShortcutBuffer.Step(control: .dial2CCW, selectors: .command,
                                        shortcut: .init(keyCode: 126, modifiers: .command))
        for step in [down, up, up, down] { precondition(buffer.append(step, context: context(), now: 10)) }
        precondition(buffer.take(context: context(), now: 10.08) == [down, up, up, down],
                     "Verify same field without losing direction changes or held-modifier selections")
        precondition(buffer.take(context: context(), now: 10.09).isEmpty, "No duplicate replay")
        for changed in [context(pid: 56), context(profile: "other"), context(revision: "b"),
                        context(group: "3"), context(field: "neighbor")] {
            precondition(buffer.append(down, context: context(), now: 10))
            precondition(buffer.take(context: changed, now: 10.08).isEmpty, "Context changes drop pending arrows")
        }
        for deadline in [9.9, 10.51, .nan, .infinity] {
            precondition(buffer.append(up, context: context(), now: 10))
            precondition(buffer.take(context: context(), now: deadline).isEmpty, "Invalid or old work never replays")
        }
        precondition(buffer.append(up, context: context(), now: 10))
        precondition(buffer.take(context: nil, now: 10.1).isEmpty, "Unknown/secure/unavailable route drops work")
        precondition(buffer.append(up, context: context(), now: 10))
        buffer.clear()
        precondition(buffer.take(context: context(), now: 10.1).isEmpty, "Physical input or cancellation revokes work")
        for i in 0..<RiveShortcutBuffer.capacity {
            precondition(buffer.append(i % 2 == 0 ? up : down, context: context(), now: 10))
        }
        precondition(!buffer.append(up, context: context(), now: 10), "Bound burst size")
        precondition(buffer.take(context: context(), now: 10.1).isEmpty, "Overflow cannot release a stale partial burst")
        precondition(buffer.append(up, context: context(), now: 10))
        precondition(!buffer.append(down, context: context(field: "neighbor"), now: 10.1))
        precondition(buffer.take(context: context(field: "neighbor"), now: 10.2).isEmpty,
                     "Appending on a different field cannot transfer an old burst")
        print("RiveShortcutBufferTests passed")
    }
}
