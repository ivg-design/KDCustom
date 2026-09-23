import Foundation

/// The platform adapter owns event injection. The engine only decides what to emit and when.
@MainActor
protocol ActionOutput: AnyObject {
    /// True when the platform accepted this event for posting.
    @discardableResult func key(code: UInt16, down: Bool, modifiers: KeyModifiers) -> Bool
    func text(_ value: String)
    @discardableResult func mouse(button: MouseButton, down: Bool, modifiers: KeyModifiers) -> Bool
    func scroll(horizontal: Int, vertical: Int, modifiers: KeyModifiers)
    func media(_ key: MediaKey)
    /// Used before releasing an injected key so a physically held key is not released.
    func physicalKeyIsDown(_ code: UInt16) -> Bool
    /// A physical drag takes precedence over synthesized mouse ownership.
    func physicalMouseButtonIsDown(_ button: MouseButton) -> Bool
}

extension ActionOutput {
    func physicalKeyIsDown(_ code: UInt16) -> Bool { false }
    func physicalMouseButtonIsDown(_ button: MouseButton) -> Bool { false }
}

/// A deterministic, bounded scheduler. All calls and callbacks occur on the main actor.
@MainActor
final class ActionEngine {
    var onGroupChange: ((Int) -> Void)?
    var onEvent: ((String) -> Void)?

    private enum RunKind { case press, release }

    private final class Run {
        let kind: RunKind
        let binding: ControlBinding
        let steps: [ActionStep]
        let owner: Int
        var cycle = 0
        var stepIndex = 0
        var stepRepeat = 0
        var due: TimeInterval = 0

        init(kind: RunKind, binding: ControlBinding, steps: [ActionStep], owner: Int) {
            self.kind = kind
            self.binding = binding
            self.steps = steps
            self.owner = owner
        }

        var exhausted: Bool { steps.isEmpty || cycle >= binding.macroRepeatCount }

        func takeStep(at now: TimeInterval) -> ActionStep {
            let step = steps[stepIndex]
            stepRepeat += 1
            if stepRepeat >= step.repeatCount {
                stepRepeat = 0
                stepIndex += 1
                if stepIndex >= steps.count {
                    stepIndex = 0
                    cycle += 1
                }
            }
            if case let .delay(milliseconds) = step.operation {
                due = now + Double(milliseconds) / 1_000
            }
            return step
        }
    }

    private struct Request {
        let binding: ControlBinding
        let steps: [ActionStep]
    }

    private final class State {
        let control: ControlID
        let owner: Int
        var binding: ControlBinding
        var active = false
        var closing = false
        var current: Run?
        var pending: [Request] = []
        var repeatAt: TimeInterval?

        init(control: ControlID, owner: Int, binding: ControlBinding) {
            self.control = control
            self.owner = owner
            self.binding = binding
        }
    }

    private struct DialHold {
        let owner: Int
        var modifiers: KeyModifiers
        var expiresAt: TimeInterval
    }

    private let output: ActionOutput
    private var states: [ControlID: State] = [:]
    private var dialHolds: [Int: DialHold] = [:]
    private var nextOwner = 1
    private var lastTime: TimeInterval = 0
    private var isTicking = false
    private var isCancellingAll = false

    // Each owner keeps its own holds. The shared counts stop one control from releasing another.
    private var ownerKeys: [Int: [UInt16: [KeyModifiers]]] = [:]
    private var keyCounts: [UInt16: Int] = [:]
    private var injectedCodes = Set<UInt16>()
    private var ownerMouse: [Int: [String: Int]] = [:]
    private var mouseCounts: [String: Int] = [:]
    private var injectedMouseButtons = Set<String>()
    private var ownerModifiers: [Int: [UInt64: Int]] = [:]
    private var modifierCounts: [UInt64: Int] = [:]

    init(output: ActionOutput) { self.output = output }

    /// Buttons use down/up edges; dials use one down pulse per detent.
    func handle(control: ControlID, isDown: Bool, binding: ControlBinding, now: TimeInterval) {
        guard now.isFinite, !isCancellingAll else { return }
        let time = max(now, lastTime)
        tick(now: time)
        guard binding.controlID == control else {
            onEvent?("ignored mismatched binding for \(control.rawValue)")
            return
        }

        if control.isDial {
            guard isDown else { return }
            let state = stateFor(control, binding: binding)
            state.binding = binding
            enqueuePress(on: state, binding: binding)
        } else if isDown {
            if let existing = states[control], existing.closing,
               let run = existing.current, case .release = run.kind {
                cancel(control: control)
            }
            let state = stateFor(control, binding: binding)
            if state.active {
                if state.binding.buttonBehavior == .toggle {
                    close(state)
                    tick(now: time)
                }
                return
            }
            state.binding = binding
            state.active = true
            state.closing = false
            enqueuePress(on: state, binding: binding)
            if binding.buttonBehavior == .repeatWhileHeld {
                state.repeatAt = time + Double(binding.repeatIntervalMilliseconds) / 1_000
            }
        } else if let state = states[control], state.active {
            if state.binding.buttonBehavior != .toggle { close(state) }
        }
        tick(now: time)
    }

    func tick(now: TimeInterval) {
        guard now.isFinite, !isTicking, !isCancellingAll else { return }
        let time = max(now, lastTime)
        lastTime = time
        isTicking = true
        defer { isTicking = false }

        for dial in dialHolds.keys.sorted() {
            if let hold = dialHolds[dial], time >= hold.expiresAt {
                releaseModifiers(hold.modifiers, owner: hold.owner)
                dialHolds.removeValue(forKey: dial)
            }
        }

        var remaining = 256
        for control in ControlID.allCases {
            guard remaining > 0, let state = states[control] else { continue }
            if state.active, state.binding.buttonBehavior == .repeatWhileHeld,
               let repeatAt = state.repeatAt, time >= repeatAt,
               state.current == nil, state.pending.isEmpty {
                enqueuePress(on: state, binding: state.binding)
                state.repeatAt = time + Double(state.binding.repeatIntervalMilliseconds) / 1_000
            }
            var perControl = 0
            while remaining > 0, perControl < 64, states[control] === state {
                if state.current == nil {
                    if !state.pending.isEmpty {
                        let request = state.pending.removeFirst()
                        state.current = makeRun(.press, request.binding, request.steps)
                    } else if state.closing, state.binding.buttonBehavior == .pressRelease {
                        state.current = makeRun(.release, state.binding, state.binding.releaseActions)
                    } else {
                        if state.closing || (control.isDial && !state.active) {
                            releaseOwner(state.owner)
                            states.removeValue(forKey: control)
                        }
                        break
                    }
                }
                guard let run = state.current, time >= run.due else { break }
                if run.exhausted {
                    finish(run, on: state)
                    continue
                }
                let step = run.takeStep(at: time)
                remaining -= 1
                perControl += 1
                if state.control.isDial {
                    if case .delay = step.operation { /* Hold begins with an emitted step. */ }
                    else { updateDialHold(for: state.control, binding: run.binding, at: time) }
                }
                execute(step.operation, owner: run.owner, sessionOwner: state.owner)
            }
        }
    }

    func cancelAll(reason: String) {
        guard !isCancellingAll else { return }
        isCancellingAll = true
        defer { isCancellingAll = false }
        for control in ControlID.allCases { cancel(control: control) }
        for dial in dialHolds.keys.sorted() {
            if let hold = dialHolds.removeValue(forKey: dial) {
                releaseModifiers(hold.modifiers, owner: hold.owner)
            }
        }
        onEvent?("cancel all: \(reason)")
    }

    func cancel(control: ControlID) {
        if let state = states.removeValue(forKey: control) {
            if let run = state.current { releaseOwner(run.owner) }
            releaseOwner(state.owner)
        }
        if let dial = dialNumber(for: control), let hold = dialHolds.removeValue(forKey: dial) {
            releaseModifiers(hold.modifiers, owner: hold.owner)
        }
    }

    private func stateFor(_ control: ControlID, binding: ControlBinding) -> State {
        if let state = states[control] { return state }
        let state = State(control: control, owner: allocateOwner(), binding: binding)
        states[control] = state
        return state
    }

    private func allocateOwner() -> Int {
        defer { nextOwner += 1 }
        return nextOwner
    }

    private func makeRun(_ kind: RunKind, _ binding: ControlBinding, _ steps: [ActionStep]) -> Run {
        Run(kind: kind, binding: binding, steps: steps, owner: allocateOwner())
    }

    private func enqueuePress(on state: State, binding: ControlBinding) {
        let request = Request(binding: binding, steps: binding.pressActions)
        if state.current == nil, state.pending.isEmpty {
            state.current = makeRun(.press, binding, request.steps)
            return
        }
        switch binding.macroRetriggerPolicy {
        case .queue:
            if state.pending.count < binding.queueLimit { state.pending.append(request) }
            else { onEvent?("macro queue full: \(state.control.rawValue)") }
        case .restart:
            if let run = state.current { releaseOwner(run.owner) }
            state.pending.removeAll()
            state.current = makeRun(.press, binding, request.steps)
        case .ignoreWhileRunning:
            onEvent?("macro retrigger ignored: \(state.control.rawValue)")
        }
    }

    private func close(_ state: State) {
        state.active = false
        state.closing = true
        state.repeatAt = nil
        if state.binding.buttonBehavior == .pressRelease {
            // A tap may finish its finite press macro after the physical button is up.
            // Pending retriggers remain bounded by the binding's queue limit.
            return
        }
        state.pending.removeAll()
        if let run = state.current { releaseOwner(run.owner) }
        // A hold or toggle ends at the physical edge, even if releaseActions
        // contains a delay. Release actions may synthesize fresh holds explicitly.
        releaseOwner(state.owner)
        state.current = makeRun(.release, state.binding, state.binding.releaseActions)
    }

    private func finish(_ run: Run, on state: State) {
        if run.kind == .press, !state.control.isDial,
           (state.active || (state.closing && state.binding.buttonBehavior == .pressRelease)) {
            transferOwner(run.owner, to: state.owner)
        } else {
            releaseOwner(run.owner)
        }
        state.current = nil
        if run.kind == .release {
            releaseOwner(state.owner)
            states.removeValue(forKey: state.control)
        }
    }

    private func execute(_ operation: ActionStep.Operation, owner: Int, sessionOwner: Int) {
        switch operation {
        case let .keyDown(code, modifiers): acquireKey(code, modifiers: modifiers, owner: owner)
        case let .keyUp(code, _):
            if !releaseKey(code, owner: owner) { _ = releaseKey(code, owner: sessionOwner) }
        case let .keyTap(code, modifiers):
            acquireKey(code, modifiers: modifiers, owner: owner)
            _ = releaseKey(code, owner: owner)
        case let .chord(codes, modifiers):
            acquireModifiers(modifiers, owner: owner)
            for code in codes { acquireKey(code, modifiers: [], owner: owner) }
            for code in codes.reversed() { _ = releaseKey(code, owner: owner) }
            releaseModifiers(modifiers, owner: owner)
        case let .text(value): output.text(value)
        case .delay: break
        case let .mouseButtonDown(button): acquireMouse(button, owner: owner)
        case let .mouseButtonUp(button):
            if !releaseMouse(button, owner: owner) { _ = releaseMouse(button, owner: sessionOwner) }
        case let .mouseClick(button):
            acquireMouse(button, owner: owner)
            _ = releaseMouse(button, owner: owner)
        case let .scroll(horizontal, vertical):
            output.scroll(horizontal: horizontal, vertical: vertical, modifiers: activeModifiers)
        case let .media(key): output.media(key)
        case let .groupChange(offset): onGroupChange?(offset)
        }
    }

    private static let modifierBits: [UInt64] = [
        KeyModifiers.shift.rawValue, KeyModifiers.control.rawValue, KeyModifiers.option.rawValue,
        KeyModifiers.command.rawValue, KeyModifiers.function.rawValue
    ]
    // Native virtual key codes from the macOS HIToolbox Events.h header.
    private static let modifierCodes: [UInt64: UInt16] = [
        KeyModifiers.shift.rawValue: 0x38, KeyModifiers.control.rawValue: 0x3B,
        KeyModifiers.option.rawValue: 0x3A, KeyModifiers.command.rawValue: 0x37,
        KeyModifiers.function.rawValue: 0x3F
    ]
    private static let directModifierBits: [UInt16: UInt64] = [
        0x37: KeyModifiers.command.rawValue, 0x36: KeyModifiers.command.rawValue,
        0x38: KeyModifiers.shift.rawValue, 0x3C: KeyModifiers.shift.rawValue,
        0x3A: KeyModifiers.option.rawValue, 0x3D: KeyModifiers.option.rawValue,
        0x3B: KeyModifiers.control.rawValue, 0x3E: KeyModifiers.control.rawValue,
        0x3F: KeyModifiers.function.rawValue
    ]

    private func ownedCount(for code: UInt16) -> Int {
        let modifierCount = Self.modifierCodes.first { $0.value == code }
            .map { modifierCounts[$0.key, default: 0] } ?? 0
        return keyCounts[code, default: 0] + modifierCount
    }

    private var activeModifiers: KeyModifiers {
        let abstractBits = modifierCounts.reduce(UInt64(0)) { $0 | ($1.value > 0 ? $1.key : 0) }
        let directBits = keyCounts.reduce(UInt64(0)) { partial, entry in
            partial | (entry.value > 0 ? Self.directModifierBits[entry.key, default: 0] : 0)
        }
        return KeyModifiers(rawValue: abstractBits | directBits)
    }

    private func acquireModifiers(_ modifiers: KeyModifiers, owner: Int) {
        for bit in Self.modifierBits where modifiers.rawValue & bit != 0 {
            let code = Self.modifierCodes[bit]!
            ownerModifiers[owner, default: [:]][bit, default: 0] += 1
            modifierCounts[bit, default: 0] += 1
            if !injectedCodes.contains(code), !output.physicalKeyIsDown(code),
               output.key(code: code, down: true, modifiers: activeModifiers) {
                injectedCodes.insert(code)
            }
        }
    }

    private func releaseModifiers(_ modifiers: KeyModifiers, owner: Int) {
        for bit in Self.modifierBits where modifiers.rawValue & bit != 0 {
            guard let held = ownerModifiers[owner]?[bit], held > 0 else { continue }
            if held == 1 { ownerModifiers[owner]?.removeValue(forKey: bit) }
            else { ownerModifiers[owner]?[bit] = held - 1 }
            let total = modifierCounts[bit, default: 0] - 1
            if total <= 0 { modifierCounts.removeValue(forKey: bit) }
            else { modifierCounts[bit] = total }
            let code = Self.modifierCodes[bit]!
            if ownedCount(for: code) == 0, injectedCodes.remove(code) != nil,
               !output.physicalKeyIsDown(code) {
                output.key(code: code, down: false, modifiers: activeModifiers)
            }
        }
        if ownerModifiers[owner]?.isEmpty == true { ownerModifiers.removeValue(forKey: owner) }
    }

    private func acquireKey(_ code: UInt16, modifiers: KeyModifiers, owner: Int) {
        acquireModifiers(modifiers, owner: owner)
        ownerKeys[owner, default: [:]][code, default: []].append(modifiers)
        keyCounts[code, default: 0] += 1
        if !injectedCodes.contains(code), !output.physicalKeyIsDown(code),
           output.key(code: code, down: true, modifiers: activeModifiers) {
            injectedCodes.insert(code)
        }
    }

    @discardableResult
    private func releaseKey(_ code: UInt16, owner: Int) -> Bool {
        guard var holds = ownerKeys[owner]?[code], let modifiers = holds.popLast() else { return false }
        if holds.isEmpty { ownerKeys[owner]?.removeValue(forKey: code) }
        else { ownerKeys[owner]?[code] = holds }
        if ownerKeys[owner]?.isEmpty == true { ownerKeys.removeValue(forKey: owner) }
        let remaining = keyCounts[code, default: 0] - 1
        if remaining <= 0 { keyCounts.removeValue(forKey: code) }
        else { keyCounts[code] = remaining }
        if ownedCount(for: code) == 0, injectedCodes.remove(code) != nil,
           !output.physicalKeyIsDown(code) {
            output.key(code: code, down: false, modifiers: activeModifiers)
        }
        releaseModifiers(modifiers, owner: owner)
        return true
    }

    private func acquireMouse(_ button: MouseButton, owner: Int) {
        let key = button.rawValue
        ownerMouse[owner, default: [:]][key, default: 0] += 1
        mouseCounts[key, default: 0] += 1
        if !injectedMouseButtons.contains(key), !output.physicalMouseButtonIsDown(button),
           output.mouse(button: button, down: true, modifiers: activeModifiers) {
            injectedMouseButtons.insert(key)
        }
    }

    @discardableResult
    private func releaseMouse(_ button: MouseButton, owner: Int) -> Bool {
        let key = button.rawValue
        guard let held = ownerMouse[owner]?[key], held > 0 else { return false }
        if held == 1 { ownerMouse[owner]?.removeValue(forKey: key) }
        else { ownerMouse[owner]?[key] = held - 1 }
        if ownerMouse[owner]?.isEmpty == true { ownerMouse.removeValue(forKey: owner) }
        let remaining = mouseCounts[key, default: 0] - 1
        if remaining <= 0 {
            mouseCounts.removeValue(forKey: key)
            if injectedMouseButtons.remove(key) != nil,
               !output.physicalMouseButtonIsDown(button) {
                output.mouse(button: button, down: false, modifiers: activeModifiers)
            }
        } else { mouseCounts[key] = remaining }
        return true
    }

    private func releaseOwner(_ owner: Int) {
        for code in (ownerKeys[owner] ?? [:]).keys.sorted() {
            while releaseKey(code, owner: owner) { }
        }
        for raw in (ownerMouse[owner] ?? [:]).keys.sorted() {
            if let button = MouseButton(rawValue: raw) {
                while releaseMouse(button, owner: owner) { }
            }
        }
        for bit in (ownerModifiers[owner] ?? [:]).keys.sorted() {
            while ownerModifiers[owner]?[bit] != nil {
                releaseModifiers(KeyModifiers(rawValue: bit), owner: owner)
            }
        }
    }

    private func transferOwner(_ source: Int, to destination: Int) {
        for (code, holds) in ownerKeys.removeValue(forKey: source) ?? [:] {
            ownerKeys[destination, default: [:]][code, default: []].append(contentsOf: holds)
        }
        for (button, count) in ownerMouse.removeValue(forKey: source) ?? [:] {
            ownerMouse[destination, default: [:]][button, default: 0] += count
        }
        for (bit, count) in ownerModifiers.removeValue(forKey: source) ?? [:] {
            ownerModifiers[destination, default: [:]][bit, default: 0] += count
        }
    }

    private func dialNumber(for control: ControlID) -> Int? {
        switch control {
        case .dial1CW, .dial1CCW: 1
        case .dial2CW, .dial2CCW: 2
        default: nil
        }
    }

    private func updateDialHold(for control: ControlID, binding: ControlBinding, at now: TimeInterval) {
        guard let dial = dialNumber(for: control) else { return }
        let wanted: KeyModifiers = binding.dialBehavior == .heldModifiers ? binding.heldModifiers : []
        if var hold = dialHolds[dial] {
            let removed = hold.modifiers.subtracting(wanted)
            let added = wanted.subtracting(hold.modifiers)
            releaseModifiers(removed, owner: hold.owner)
            acquireModifiers(added, owner: hold.owner)
            hold.modifiers = wanted
            hold.expiresAt = now + Double(binding.idleTimeoutMilliseconds) / 1_000
            if wanted.isEmpty { dialHolds.removeValue(forKey: dial) }
            else { dialHolds[dial] = hold }
        } else if !wanted.isEmpty {
            let owner = allocateOwner()
            acquireModifiers(wanted, owner: owner)
            dialHolds[dial] = DialHold(owner: owner, modifiers: wanted,
                                       expiresAt: now + Double(binding.idleTimeoutMilliseconds) / 1_000)
        }
    }
}
