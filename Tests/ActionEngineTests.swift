import Foundation

@MainActor
private final class RecordingOutput: ActionOutput {
    var events: [String] = []
    var physicalKeys = Set<UInt16>()
    var physicalMouseButtons = Set<String>()
    var acceptDown = true

    @discardableResult
    func key(code: UInt16, down: Bool, modifiers: KeyModifiers) -> Bool {
        if down && !acceptDown { return false }
        events.append("\(down ? "down" : "up"):\(code):\(modifiers.rawValue)")
        return true
    }
    func text(_ value: String) { events.append("text:\(value)") }
    @discardableResult
    func mouse(button: MouseButton, down: Bool, modifiers: KeyModifiers) -> Bool {
        if down && !acceptDown { return false }
        events.append("mouse:\(button.rawValue):\(down):\(modifiers.rawValue)")
        return true
    }
    func scroll(horizontal: Int, vertical: Int, modifiers: KeyModifiers) {
        events.append("scroll:\(horizontal):\(vertical):\(modifiers.rawValue)")
    }
    func media(_ key: MediaKey) { events.append("media:\(key.rawValue)") }
    func physicalKeyIsDown(_ code: UInt16) -> Bool { physicalKeys.contains(code) }
    func physicalMouseButtonIsDown(_ button: MouseButton) -> Bool {
        physicalMouseButtons.contains(button.rawValue)
    }
}

@main
@MainActor
enum ActionEngineTests {
    static func equal(_ actual: [String], _ expected: [String], _ name: String) {
        guard actual == expected else {
            fatalError("\(name): expected \(expected), got \(actual)")
        }
    }

    static func check(_ condition: Bool, _ name: String) {
        if !condition { fatalError(name) }
    }

    static func main() {
        let command = KeyModifiers.command.rawValue
        let shift = KeyModifiers.shift.rawValue

        do {
            let output = RecordingOutput()
            let engine = ActionEngine(output: output)
            let binding = ControlBinding(controlID: .key1, pressActions: [
                .keyTap(24, repeatCount: 2), .init(.delay(milliseconds: 10)), .init(.text("done"))
            ], macroRepeatCount: 2)
            engine.handle(control: .key1, isDown: true, binding: binding, now: 0)
            equal(output.events, ["down:24:0", "up:24:0", "down:24:0", "up:24:0"],
                  "step repeats before delay")
            engine.tick(now: 0.009)
            check(output.events.count == 4, "delay does not complete early")
            engine.tick(now: 0.01)
            equal(output.events, ["down:24:0", "up:24:0", "down:24:0", "up:24:0", "text:done",
                                  "down:24:0", "up:24:0", "down:24:0", "up:24:0"],
                  "macro repeat starts after delay")
            engine.tick(now: 0.02)
            check(output.events.last == "text:done" && output.events.count == 10,
                  "second macro cycle completes")
            engine.handle(control: .key1, isDown: false, binding: binding, now: 0.03)
        }

        do {
            let output = RecordingOutput()
            let engine = ActionEngine(output: output)
            let binding = ControlBinding(controlID: .key1, pressActions: [
                .keyTap(4), .init(.delay(milliseconds: 500)), .keyTap(5)
            ], releaseActions: [.init(.text("released"))])
            engine.handle(control: .key1, isDown: true, binding: binding, now: 0)
            engine.handle(control: .key1, isDown: false, binding: binding, now: 0.01)
            engine.tick(now: 0.49)
            equal(output.events, ["down:4:0", "up:4:0"],
                  "pressRelease tap keeps finite delayed macro pending")
            engine.tick(now: 0.5)
            equal(output.events, ["down:4:0", "up:4:0", "down:5:0", "up:5:0", "text:released"],
                  "release actions run after the complete press macro")
        }

        do {
            let output = RecordingOutput()
            let engine = ActionEngine(output: output)
            let binding = ControlBinding(controlID: .key1, pressActions: [
                .init(.text("A")), .init(.delay(milliseconds: 100)), .init(.text("B"))
            ], releaseActions: [.init(.text("released"))], queueLimit: 1)
            engine.handle(control: .key1, isDown: true, binding: binding, now: 0)
            engine.handle(control: .key1, isDown: false, binding: binding, now: 0.01)
            engine.handle(control: .key1, isDown: true, binding: binding, now: 0.02)
            engine.handle(control: .key1, isDown: false, binding: binding, now: 0.03)
            engine.tick(now: 0.1)
            equal(output.events, ["text:A", "text:B", "text:A"],
                  "quick second press queues behind a closing pressRelease macro")
            engine.tick(now: 0.2)
            equal(output.events, ["text:A", "text:B", "text:A", "text:B", "text:released"],
                  "queued press finishes before release actions")
        }

        do {
            let output = RecordingOutput()
            let engine = ActionEngine(output: output)
            let hold = ControlBinding(controlID: .key1,
                                      pressActions: [.init(.keyDown(keyCode: 4, modifiers: .command))],
                                      releaseActions: [.init(.keyUp(keyCode: 4, modifiers: .command))])
            let tap = ControlBinding(controlID: .key2, pressActions: [.keyTap(24, modifiers: .command)])
            engine.handle(control: .key1, isDown: true, binding: hold, now: 0)
            engine.handle(control: .key2, isDown: true, binding: tap, now: 0)
            engine.handle(control: .key2, isDown: false, binding: tap, now: 0.01)
            engine.handle(control: .key1, isDown: false, binding: hold, now: 0.02)
            equal(output.events, ["down:55:\(command)", "down:4:\(command)",
                                  "down:24:\(command)", "up:24:\(command)",
                                  "up:4:\(command)", "up:55:0"],
                  "shared command survives another control's tap and release")
        }

        do {
            let output = RecordingOutput()
            let engine = ActionEngine(output: output)
            let first = ControlBinding(controlID: .key1,
                                       pressActions: [.init(.keyDown(keyCode: 4, modifiers: []))])
            let second = ControlBinding(controlID: .key2,
                                        pressActions: [.init(.keyDown(keyCode: 4, modifiers: []))])
            engine.handle(control: .key1, isDown: true, binding: first, now: 0)
            engine.handle(control: .key2, isDown: true, binding: second, now: 0)
            engine.cancel(control: .key1)
            equal(output.events, ["down:4:0"], "first owner cannot release shared key")
            engine.cancel(control: .key2)
            equal(output.events, ["down:4:0", "up:4:0"], "last owner releases shared key")
        }

        do {
            let output = RecordingOutput()
            let engine = ActionEngine(output: output)
            let explicitCommand = ControlBinding(controlID: .key1,
                pressActions: [.init(.keyDown(keyCode: 55, modifiers: []))])
            let chord = ControlBinding(controlID: .key2,
                pressActions: [.keyTap(24, modifiers: .command)])
            engine.handle(control: .key1, isDown: true, binding: explicitCommand, now: 0)
            engine.handle(control: .key2, isDown: true, binding: chord, now: 0)
            engine.cancel(control: .key2)
            equal(output.events, ["down:55:\(command)", "down:24:\(command)", "up:24:\(command)"],
                  "modifier flag does not release an explicitly held modifier key")
            engine.cancel(control: .key1)
            equal(output.events.last.map { [$0] } ?? [], ["up:55:0"],
                  "last modifier key owner releases it")
        }

        do {
            let output = RecordingOutput()
            let engine = ActionEngine(output: output)
            let direct = ControlBinding(controlID: .key1, pressActions: [
                .init(.keyDown(keyCode: 55, modifiers: [])), .keyTap(123),
                .init(.keyUp(keyCode: 55, modifiers: []))
            ])
            engine.handle(control: .key1, isDown: true, binding: direct, now: 0)
            equal(output.events, ["down:55:\(command)", "down:123:\(command)",
                                  "up:123:\(command)", "up:55:0"],
                  "explicit Command key carries flags into following arrow")

            let rightOutput = RecordingOutput()
            let rightEngine = ActionEngine(output: rightOutput)
            let right = ControlBinding(controlID: .key2, pressActions: [
                .init(.keyDown(keyCode: 54, modifiers: [])), .keyTap(124),
                .init(.keyUp(keyCode: 54, modifiers: []))
            ])
            rightEngine.handle(control: .key2, isDown: true, binding: right, now: 0)
            equal(rightOutput.events, ["down:54:\(command)", "down:124:\(command)",
                                       "up:124:\(command)", "up:54:0"],
                  "right Command key also contributes Command flags")

            let chordOutput = RecordingOutput()
            let chordEngine = ActionEngine(output: chordOutput)
            let chord = ControlBinding(controlID: .key3,
                                       pressActions: [.chord([55, 123])])
            chordEngine.handle(control: .key3, isDown: true, binding: chord, now: 0)
            equal(chordOutput.events, ["down:55:\(command)", "down:123:\(command)",
                                       "up:123:\(command)", "up:55:0"],
                  "chord with explicit modifier applies flags before arrow")
        }

        do {
            let output = RecordingOutput()
            let engine = ActionEngine(output: output)
            let binding = ControlBinding(controlID: .key1, pressActions: [
                .init(.keyDown(keyCode: 4, modifiers: .shift)),
                .init(.delay(milliseconds: 100)), .init(.text("stale"))
            ])
            engine.handle(control: .key1, isDown: true, binding: binding, now: 0)
            engine.cancelAll(reason: "profile changed")
            engine.tick(now: 1)
            equal(output.events, ["down:56:\(shift)", "down:4:\(shift)",
                                  "up:4:\(shift)", "up:56:0"],
                  "cancel releases only owned holds and drops delayed actions")
        }

        do {
            let output = RecordingOutput()
            let engine = ActionEngine(output: output)
            let hold = ControlBinding(controlID: .key1, pressActions: [
                .init(.keyDown(keyCode: 4, modifiers: [])),
                .init(.delay(milliseconds: 500)), .init(.text("stale"))
            ], releaseActions: [.init(.text("off"))], buttonBehavior: .hold)
            engine.handle(control: .key1, isDown: true, binding: hold, now: 0)
            engine.handle(control: .key1, isDown: false, binding: hold, now: 0.01)
            engine.tick(now: 1)
            equal(output.events, ["down:4:0", "up:4:0", "text:off"],
                  "hold release cancels delayed press work and releases its key")

            let pendingOutput = RecordingOutput()
            let pending = ActionEngine(output: pendingOutput)
            let pressRelease = ControlBinding(controlID: .key1, pressActions: [
                .init(.keyDown(keyCode: 4, modifiers: [])),
                .init(.delay(milliseconds: 500)), .init(.text("stale"))
            ])
            pending.handle(control: .key1, isDown: true, binding: pressRelease, now: 0)
            pending.handle(control: .key1, isDown: false, binding: pressRelease, now: 0.01)
            pending.cancelAll(reason: "profile switched")
            pending.tick(now: 1)
            equal(pendingOutput.events, ["down:4:0", "up:4:0"],
                  "cancelAll still interrupts a released pressRelease macro immediately")
        }

        do {
            let output = RecordingOutput()
            let engine = ActionEngine(output: output)
            let held = ControlBinding(controlID: .key1,
                pressActions: [.init(.keyDown(keyCode: 49, modifiers: .command))],
                releaseActions: [.init(.delay(milliseconds: 500)), .init(.text("after"))],
                buttonBehavior: .hold)
            engine.handle(control: .key1, isDown: true, binding: held, now: 0)
            engine.handle(control: .key1, isDown: false, binding: held, now: 0.01)
            equal(output.events, ["down:55:\(command)", "down:49:\(command)",
                                  "up:49:\(command)", "up:55:0"],
                  "completed hold releases keys at button-up before delayed release actions")
            engine.tick(now: 0.51)
            check(output.events.last == "text:after", "delayed release actions still complete")

            let toggledOutput = RecordingOutput()
            let toggled = ActionEngine(output: toggledOutput)
            let toggle = ControlBinding(controlID: .key2,
                pressActions: [.init(.keyDown(keyCode: 49, modifiers: []))],
                releaseActions: [.init(.delay(milliseconds: 500))], buttonBehavior: .toggle)
            toggled.handle(control: .key2, isDown: true, binding: toggle, now: 0)
            toggled.handle(control: .key2, isDown: false, binding: toggle, now: 0.01)
            toggled.handle(control: .key2, isDown: true, binding: toggle, now: 0.02)
            equal(toggledOutput.events, ["down:49:0", "up:49:0"],
                  "toggle-off releases owner before delayed release actions")
        }

        do {
            let output = RecordingOutput()
            output.acceptDown = false
            let engine = ActionEngine(output: output)
            let tap = ControlBinding(controlID: .key1,
                pressActions: [.keyTap(4, modifiers: .command), .init(.mouseClick(.left))])
            engine.handle(control: .key1, isDown: true, binding: tap, now: 0)
            engine.handle(control: .key1, isDown: false, binding: tap, now: 0.01)
            equal(output.events, [], "rejected key, modifier, and mouse downs emit no orphan ups")

            let held = ControlBinding(controlID: .key2,
                pressActions: [.init(.keyDown(keyCode: 49, modifiers: []))])
            engine.handle(control: .key2, isDown: true, binding: held, now: 0.02)
            output.acceptDown = true
            let second = ControlBinding(controlID: .key3, pressActions: [.keyTap(49)])
            engine.handle(control: .key3, isDown: true, binding: second, now: 0.03)
            equal(output.events, ["down:49:0"],
                  "later owner retries a down that was previously rejected")
            engine.cancelAll(reason: "test")
            equal(output.events, ["down:49:0", "up:49:0"],
                  "accepted retried down gets one final up")
        }

        do {
            let output = RecordingOutput()
            let engine = ActionEngine(output: output)
            var changes = 0
            engine.onGroupChange = { [weak engine] _ in
                changes += 1
                engine?.cancelAll(reason: "group callback")
            }
            let binding = ControlBinding(controlID: .key1, pressActions: [
                .init(.keyDown(keyCode: 4, modifiers: [])),
                .init(.groupChange(offset: 1)), .init(.text("stale"))
            ])
            engine.handle(control: .key1, isDown: true, binding: binding, now: 0)
            engine.tick(now: 1)
            equal(output.events, ["down:4:0", "up:4:0"],
                  "reentrant group callback cancellation drops subsequent steps and holds")
            check(changes == 1, "group callback runs once")
            var logs = 0
            engine.onEvent = { [weak engine] _ in
                logs += 1
                engine?.cancelAll(reason: "nested log callback")
            }
            engine.cancelAll(reason: "outer")
            check(logs == 1, "cancelAll log callback cannot recursively cancel forever")
        }

        do {
            let output = RecordingOutput()
            let engine = ActionEngine(output: output)
            let binding = ControlBinding(controlID: .dial1CW, pressActions: [
                .init(.text("A")), .init(.delay(milliseconds: 10)), .init(.text("B"))
            ], queueLimit: 1)
            engine.handle(control: .dial1CW, isDown: true, binding: binding, now: 0)
            engine.handle(control: .dial1CW, isDown: true, binding: binding, now: 0.001)
            engine.handle(control: .dial1CW, isDown: true, binding: binding, now: 0.002)
            engine.tick(now: 0.01)
            engine.tick(now: 0.02)
            equal(output.events, ["text:A", "text:B", "text:A", "text:B"],
                  "queue admits one waiting run and drops excess")

            let restartOutput = RecordingOutput()
            let restart = ActionEngine(output: restartOutput)
            var restartBinding = binding
            restartBinding.macroRetriggerPolicy = .restart
            restart.handle(control: .dial1CW, isDown: true, binding: restartBinding, now: 0)
            restart.handle(control: .dial1CW, isDown: true, binding: restartBinding, now: 0.001)
            restart.tick(now: 0.01)
            equal(restartOutput.events, ["text:A", "text:A"], "restart invalidates old delay")
            restart.tick(now: 0.011)
            equal(restartOutput.events, ["text:A", "text:A", "text:B"], "restarted run completes")

            let ignoreOutput = RecordingOutput()
            let ignore = ActionEngine(output: ignoreOutput)
            var ignoreBinding = binding
            ignoreBinding.macroRetriggerPolicy = .ignoreWhileRunning
            ignore.handle(control: .dial1CW, isDown: true, binding: ignoreBinding, now: 0)
            ignore.handle(control: .dial1CW, isDown: true, binding: ignoreBinding, now: 0.001)
            ignore.tick(now: 0.01)
            equal(ignoreOutput.events, ["text:A", "text:B"], "ignore policy discards retrigger")
        }

        do {
            let output = RecordingOutput()
            let engine = ActionEngine(output: output)
            let cw = ControlBinding(controlID: .dial1CW, pressActions: [.keyTap(24)],
                                    dialBehavior: .heldModifiers, heldModifiers: .command,
                                    idleTimeoutMilliseconds: 250)
            let ccw = ControlBinding(controlID: .dial1CCW, pressActions: [.keyTap(25)],
                                     dialBehavior: .heldModifiers, heldModifiers: .shift,
                                     idleTimeoutMilliseconds: 250)
            engine.handle(control: .dial1CW, isDown: true, binding: cw, now: 0)
            engine.handle(control: .dial1CCW, isDown: true, binding: ccw, now: 0.1)
            engine.tick(now: 0.35)
            let plain = ControlBinding(controlID: .key1, pressActions: [.keyTap(26)])
            engine.handle(control: .key1, isDown: true, binding: plain, now: 0.36)
            equal(output.events, ["down:55:\(command)", "down:24:\(command)", "up:24:\(command)",
                                  "up:55:0", "down:56:\(shift)", "down:25:\(shift)",
                                  "up:25:\(shift)", "up:56:0", "down:26:0", "up:26:0"],
                  "dial directions share one idle modifier hold and switch cleanly")
        }

        do {
            let output = RecordingOutput()
            let engine = ActionEngine(output: output)
            let button = ControlBinding(controlID: .key1,
                pressActions: [.init(.keyDown(keyCode: 49, modifiers: .command))],
                buttonBehavior: .hold)
            let clockwise = ControlBinding(controlID: .dial1CW,
                pressActions: [.keyTap(24), .init(.delay(milliseconds: 500)),
                               .init(.text("stale clockwise"))],
                dialBehavior: .heldModifiers, heldModifiers: .shift,
                idleTimeoutMilliseconds: 1_000)
            let counterclockwise = ControlBinding(controlID: .dial1CCW,
                pressActions: [.init(.delay(milliseconds: 500)),
                               .init(.text("stale counterclockwise"))],
                dialBehavior: .heldModifiers, heldModifiers: .shift,
                idleTimeoutMilliseconds: 1_000, queueLimit: 2)
            engine.handle(control: .key1, isDown: true, binding: button, now: 0)
            engine.handle(control: .dial1CW, isDown: true, binding: clockwise, now: 0.01)
            engine.handle(control: .dial1CCW, isDown: true, binding: counterclockwise, now: 0.02)
            engine.handle(control: .dial1CCW, isDown: true, binding: counterclockwise, now: 0.03)
            let before = ["down:55:\(command)", "down:49:\(command)",
                          "down:56:\(command | shift)", "down:24:\(command | shift)",
                          "up:24:\(command | shift)"]
            equal(output.events, before, "opposite direction is queued while inner dial holds Shift")
            engine.prepareSmartDial(.dial2CW)
            equal(output.events, before, "preparing the other physical dial leaves inner work untouched")
            engine.prepareSmartDial(.dial1CW)
            equal(output.events, before + ["up:56:\(command)"],
                  "Smart detent releases inner dial's idle Shift without releasing button Command or Space")
            engine.tick(now: 2)
            equal(output.events, before + ["up:56:\(command)"],
                  "Smart detent cancels both directions' delayed and queued work")
            engine.handle(control: .key1, isDown: false, binding: button, now: 2.01)
            equal(output.events, before + ["up:56:\(command)", "up:49:\(command)", "up:55:0"],
                  "remaining button hold releases normally and balances all synthesized keys")
        }

        do {
            let output = RecordingOutput()
            let engine = ActionEngine(output: output)
            let binding = ControlBinding(controlID: .dial1CW,
                pressActions: [.init(.keyDown(keyCode: 4, modifiers: .command))])
            engine.handle(control: .dial1CW, isDown: true, binding: binding, now: 0)
            equal(output.events, ["down:55:\(command)", "down:4:\(command)",
                                  "up:4:\(command)", "up:55:0"],
                  "dial macro completion releases dangling synthetic key and modifier holds")
        }

        do {
            let output = RecordingOutput()
            let engine = ActionEngine(output: output)
            var offsets: [Int] = []
            engine.onGroupChange = { offsets.append($0) }
            let remapped = ControlBinding(controlID: .setNext,
                                          pressActions: [.init(.groupChange(offset: 2))])
            engine.handle(control: .setNext, isDown: true, binding: remapped, now: 0)
            check(offsets == [2], "group change uses binding offset")
            engine.handle(control: .setNext, isDown: false, binding: remapped, now: 0.01)
        }

        do {
            let output = RecordingOutput()
            let engine = ActionEngine(output: output)
            output.physicalKeys.insert(4)
            let binding = ControlBinding(controlID: .key1, pressActions: [.keyTap(4)])
            engine.handle(control: .key1, isDown: true, binding: binding, now: 0)
            equal(output.events, [], "physical key overlap suppresses synthetic release")
            engine.handle(control: .key1, isDown: false, binding: binding, now: 0.01)
            output.physicalKeys.remove(4)
            engine.handle(control: .key1, isDown: true, binding: binding, now: 0.02)
            equal(output.events, ["down:4:0", "up:4:0"], "tap works after physical key releases")
        }

        do {
            let output = RecordingOutput()
            let engine = ActionEngine(output: output)
            let binding = ControlBinding(controlID: .key1,
                pressActions: [.init(.keyDown(keyCode: 4, modifiers: []))])
            engine.handle(control: .key1, isDown: true, binding: binding, now: 0)
            output.physicalKeys.insert(4)
            engine.cancel(control: .key1)
            equal(output.events, ["down:4:0"],
                  "release query does not send key up over a physical hold")
        }

        do {
            let output = RecordingOutput()
            let engine = ActionEngine(output: output)
            let click = ControlBinding(controlID: .key1,
                                       pressActions: [.init(.mouseClick(.left))])
            output.physicalMouseButtons.insert(MouseButton.left.rawValue)
            engine.handle(control: .key1, isDown: true, binding: click, now: 0)
            engine.handle(control: .key1, isDown: false, binding: click, now: 0.01)
            equal(output.events, [], "synthetic click cannot interrupt an existing physical drag")
            output.physicalMouseButtons.remove(MouseButton.left.rawValue)
            engine.handle(control: .key1, isDown: true, binding: click, now: 0.02)
            engine.handle(control: .key1, isDown: false, binding: click, now: 0.03)
            equal(output.events, ["mouse:left:true:0", "mouse:left:false:0"],
                  "click works after the physical button is released")

            let held = ControlBinding(controlID: .key2,
                                     pressActions: [.init(.mouseButtonDown(.left))])
            engine.handle(control: .key2, isDown: true, binding: held, now: 0.04)
            output.physicalMouseButtons.insert(MouseButton.left.rawValue)
            engine.cancel(control: .key2)
            equal(output.events, ["mouse:left:true:0", "mouse:left:false:0", "mouse:left:true:0"],
                  "cancel does not send mouse-up over a later physical drag")
        }

        do {
            let output = RecordingOutput()
            let engine = ActionEngine(output: output)
            let toggle = ControlBinding(controlID: .key1,
                pressActions: [.init(.keyDown(keyCode: 4, modifiers: []))],
                buttonBehavior: .toggle)
            engine.handle(control: .key1, isDown: true, binding: toggle, now: 0)
            engine.handle(control: .key1, isDown: false, binding: toggle, now: 0.01)
            check(output.events == ["down:4:0"], "toggle ignores button up")
            engine.handle(control: .key1, isDown: true, binding: toggle, now: 0.02)
            equal(output.events, ["down:4:0", "up:4:0"], "second toggle down releases hold")
        }

        do {
            let output = RecordingOutput()
            let engine = ActionEngine(output: output)
            let binding = ControlBinding(controlID: .key1, pressActions: [.init(.text("R"))],
                                         buttonBehavior: .repeatWhileHeld,
                                         repeatIntervalMilliseconds: 100)
            engine.handle(control: .key1, isDown: true, binding: binding, now: 0)
            engine.tick(now: 0.35)
            engine.tick(now: 0.35)
            engine.tick(now: 0.45)
            engine.handle(control: .key1, isDown: false, binding: binding, now: 0.46)
            engine.tick(now: 10)
            equal(output.events, ["text:R", "text:R", "text:R"],
                  "repeat while held emits no missed-time backlog and stops at release")
        }

        do {
            let output = RecordingOutput()
            let engine = ActionEngine(output: output)
            let binding = ControlBinding(controlID: .dial2CW,
                                         pressActions: [.init(.text("x"), repeatCount: 100)],
                                         macroRepeatCount: 100)
            engine.handle(control: .dial2CW, isDown: true, binding: binding, now: 0)
            check(output.events.count == 64, "handle work is capped per control")
            engine.tick(now: 0)
            check(output.events.count == 128, "next tick resumes bounded work")
            engine.cancelAll(reason: "test complete")
            engine.tick(now: 1)
            check(output.events.count == 128, "cancel stops remaining expanded macro")
        }

        print("Keydial action engine tests passed")
    }
}
