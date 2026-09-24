import AppKit
import ApplicationServices
import IOKit.hidsystem
import Carbon

/// Event injection is isolated here. The observer records key states, never text.
@MainActor
final class SystemActionOutput: ActionOutput {
    static let eventMarker: Int64 = 0x4b44435553544f4d
    private let source = CGEventSource(stateID: .privateState)
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var physical = PhysicalInputState()
    private var riveArrowBurst = RiveArrowBurst()
    private(set) var observing = false
    var enabled = false
    /// Used only by the neutral in-app verifier; normal control output stays on the HID path.
    var targetProcessID: pid_t?
    /// Production output may begin only while its selected foreground process is still active.
    var expectedForegroundPID: pid_t?
    var onObservationLost: (() -> Void)?
    var onPhysicalEditingInput: (() -> Void)?
    var onPhysicalPointerDown: ((CGPoint) -> Void)?
    var onExternalNavigation: ((UInt16, Bool, Int64, UInt64) -> Void)?
    var onInjectedNavigation: ((UInt16, Bool, UInt64) -> Void)?
    var onOutput: ((String) -> Void)?

    func startObserving() {
        guard tap == nil else { return }
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged,
                                   .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                                   .otherMouseDown, .otherMouseUp, .scrollWheel]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        let context = Unmanaged.passUnretained(self).toOpaque()
        tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap,
                              options: .listenOnly, eventsOfInterest: mask,
                              callback: { _, type, event, pointer in
            guard let pointer else { return Unmanaged.passUnretained(event) }
            let owner = Unmanaged<SystemActionOutput>.fromOpaque(pointer).takeUnretainedValue()
            MainActor.assumeIsolated {
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    owner.observing = false
                    owner.seedPhysicalState()
                    owner.onObservationLost?()
                    if let tap = owner.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                    owner.seedPhysicalState()
                    owner.observing = true
                } else if event.getIntegerValueField(.eventSourceUserData) != SystemActionOutput.eventMarker {
                    let code = UInt16(clamping: event.getIntegerValueField(.keyboardEventKeycode))
                    // Establish physical ownership before cancellation can
                    // release a synthesized arrow held by the same key.
                    if type == .keyDown { owner.physical.key(code, down: true, posted: false) }
                    if type == .keyUp { owner.physical.key(code, down: false, posted: false) }
                    if type == .flagsChanged { owner.physical.modifier(code, flags: event.flags.rawValue) }
                    if [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel].contains(type) {
                        owner.endRiveArrowBurst()
                        owner.onPhysicalEditingInput?()
                    }
                    if type == .flagsChanged { owner.endRiveArrowBurst() }
                    if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(type) {
                        owner.onPhysicalPointerDown?(event.location)
                    }
                    if (type == .keyDown || type == .keyUp), [36, 48, 53, 76, 123, 124, 125, 126].contains(code) {
                        owner.onExternalNavigation?(code, type == .keyDown,
                            event.getIntegerValueField(.eventSourceUnixProcessID), event.flags.rawValue)
                    }
                    if [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                        .otherMouseDown, .otherMouseUp].contains(type) {
                        let button = UInt32(clamping: event.getIntegerValueField(.mouseEventButtonNumber))
                        owner.physical.button(button, down: [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(type), posted: false)
                    }
                }
            }
            return Unmanaged.passUnretained(event)
        }, userInfo: context)
        guard let tap else { observing = false; return }
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        seedPhysicalState()
        CGEvent.tapEnable(tap: tap, enable: true)
        observing = true
    }
    func stopObserving() {
        endRiveArrowBurst()
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        tap = nil; runLoopSource = nil; physical = PhysicalInputState(); observing = false
    }
    func seedPhysicalState() {
        physical.seed(keys: Set((UInt16(0)...UInt16(127)).filter { CGEventSource.keyState(.hidSystemState, key: $0) }),
                      buttons: Set((UInt32(0)...2).filter { CGEventSource.buttonState(.hidSystemState, button: CGMouseButton(rawValue: $0)!) }))
    }
    func physicalKeyIsDown(_ code: UInt16) -> Bool { physical.keys.contains(code) }
    func physicalMouseButtonIsDown(_ button: MouseButton) -> Bool {
        let native: CGMouseButton
        switch button {
        case .left: native = .left
        case .right: native = .right
        case .middle: native = .center
        }
        return physical.buttons.contains(native.rawValue)
    }
    private var physicalFlags: CGEventFlags {
        var flags = CGEventFlags()
        for (codes, flag) in [([UInt16(55), 54], CGEventFlags.maskCommand),
                              ([56, 60], .maskShift), ([58, 61], .maskAlternate),
                              ([59, 62], .maskControl), ([63], .maskSecondaryFn)] {
            if codes.contains(where: physical.keys.contains) { flags.insert(flag) }
        }
        // Caps lock is a toggle, not an owned hold.
        if CGEventSource.flagsState(.hidSystemState).contains(.maskAlphaShift) { flags.insert(.maskAlphaShift) }
        let sides = MacModifierFlags.encode(KeyModifiers(rawValue: flags.rawValue).intersection(.supported), heldKeys: physical.keys)
        return flags.union(CGEventFlags(rawValue: sides))
    }
    private func flags(_ modifiers: KeyModifiers, changingKey: UInt16? = nil, down: Bool = false) -> CGEventFlags {
        var held = physical.postedKeys
        if let changingKey {
            if down { held.insert(changingKey) } else { held.remove(changingKey) }
        }
        return CGEventFlags(rawValue: MacModifierFlags.encode(modifiers, heldKeys: held)).union(physicalFlags)
    }

    var physicalModifiers: KeyModifiers {
        KeyModifiers(rawValue: physicalFlags.rawValue).intersection(.supported)
    }

    /// The physical selector (for example Option) is consumed only for these
    /// marked key events. No physical modifier-up event is synthesized.
    @discardableResult
    func smartShortcut(_ shortcut: SmartShortcut) -> Bool {
        endRiveArrowBurst()
        guard enabled, !physicalKeyIsDown(shortcut.keyCode),
              ![54, 55, 56, 58, 59, 60, 61, 62, 63].contains(shortcut.keyCode) else { return false }
        let exact = CGEventFlags(rawValue: MacModifierFlags.encode(shortcut.modifiers))
            .union(physicalFlags.intersection(.maskAlphaShift))
        for _ in 0..<shortcut.repeatCount {
            guard !physicalKeyIsDown(shortcut.keyCode) else { return false }
            let down = CGEvent(keyboardEventSource: source, virtualKey: shortcut.keyCode, keyDown: true)
            down?.flags = exact
            guard post(down, summary: "Smart shortcut down") else { return false }
            // A physical press may arrive after our down event. Its eventual
            // physical release owns cleanup; do not interrupt that hold.
            guard !physicalKeyIsDown(shortcut.keyCode) else { return true }
            let up = CGEvent(keyboardEventSource: source, virtualKey: shortcut.keyCode, keyDown: false)
            up?.flags = exact
            guard post(up, summary: "Smart shortcut up", release: true) else { return false }
        }
        return true
    }

    func riveArrowShortcut(_ shortcut: SmartShortcut, context: RiveShortcutBuffer.Context) -> Bool {
        riveArrowBurst.step(shortcut, context: context, now: ProcessInfo.processInfo.systemUptime,
                            emit: emitRiveArrow)
    }
    func tickRiveArrowBurst() {
        riveArrowBurst.tick(now: ProcessInfo.processInfo.systemUptime, emit: emitRiveArrow)
    }
    func endRiveArrowBurst() { _ = riveArrowBurst.end(emit: emitRiveArrow) }

    private func emitRiveArrow(_ event: RiveArrowBurst.Event) -> Bool {
        if physicalKeyIsDown(event.keyCode) {
            guard !event.down else { return false }
            // The user's physical hold now owns the eventual up.
            physical.key(event.keyCode, down: false, posted: true)
            return true
        }
        // An independently running macro may already own this key.
        if event.down && !event.isRepeat && physical.postedKeys.contains(event.keyCode) { return false }
        let native = CGEvent(keyboardEventSource: source, virtualKey: event.keyCode, keyDown: event.down)
        native?.flags = CGEventFlags(rawValue: MacModifierFlags.encode(event.modifiers))
            .union(physicalFlags.intersection(.maskAlphaShift))
        native?.setIntegerValueField(.keyboardEventAutorepeat, value: event.isRepeat ? 1 : 0)
        return post(native, summary: event.down ? (event.isRepeat ? "Rive arrow repeat" : "Rive arrow down") : "Rive arrow up",
                    release: !event.down)
    }
    @discardableResult
    private func post(_ event: CGEvent?, summary: String, release: Bool = false) -> Bool {
        guard enabled, AXIsProcessTrusted(), let event else { return false }
        // Never begin a synthetic action in secure input, but allow cleanup of prior holds.
        guard release || !IsSecureEventInputEnabled() else { return false }
        if !release, let expectedForegroundPID,
           NSWorkspace.shared.frontmostApplication?.processIdentifier != expectedForegroundPID {
            return false
        }
        event.setIntegerValueField(.eventSourceUserData, value: Self.eventMarker)
        if let targetProcessID { event.postToPid(targetProcessID) }
        else { event.post(tap: .cghidEventTap) }
        switch event.type {
        case .keyDown, .keyUp, .flagsChanged:
            let code = UInt16(clamping: event.getIntegerValueField(.keyboardEventKeycode))
            physical.key(code, down: !release, posted: true)
            if (event.type == .keyDown || event.type == .keyUp),
               [36, 48, 53, 76, 123, 124, 125, 126].contains(code) {
                onInjectedNavigation?(code, event.type == .keyDown, event.flags.rawValue)
            }
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp:
            physical.button(UInt32(clamping: event.getIntegerValueField(.mouseEventButtonNumber)), down: !release, posted: true)
        default: break
        }
        onOutput?(summary)
        return true
    }
    @discardableResult
    func key(code: UInt16, down: Bool, modifiers: KeyModifiers) -> Bool {
        endRiveArrowBurst()
        let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
        event?.flags = flags(modifiers, changingKey: code, down: down)
        if [54, 55, 56, 58, 59, 60, 61, 62, 63].contains(code) { event?.type = .flagsChanged }
        return post(event, summary: "Key \(code) \(down ? "down" : "up")", release: !down)
    }
    func text(_ value: String) {
        _ = postText(value, flags: physicalFlags)
    }

    /// Numeric Smart selectors are not part of the text being inserted.
    /// This uses the same HID text path as ordinary text macros.
    func numericText(_ value: String) -> Bool {
        guard value.utf8.count <= 64, NumericAdjustment.equalValues(value, value),
              !physicalKeyIsDown(0) else { return false }
        return postText(value, flags: physicalFlags.intersection(.maskAlphaShift))
    }

    private func postText(_ value: String, flags: CGEventFlags) -> Bool {
        endRiveArrowBurst()
        let units = Array(value.utf16)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
            units.withUnsafeBufferPointer { event?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: $0.baseAddress) }
            event?.flags = flags
            if !post(event, summary: "Text \(down ? "down" : "up")", release: !down) { return false }
        }
        return true
    }
    @discardableResult
    func mouse(button: MouseButton, down: Bool, modifiers: KeyModifiers) -> Bool {
        endRiveArrowBurst()
        let type: CGEventType
        let native: CGMouseButton
        switch button {
        case .left: type = down ? .leftMouseDown : .leftMouseUp; native = .left
        case .right: type = down ? .rightMouseDown : .rightMouseUp; native = .right
        case .middle: type = down ? .otherMouseDown : .otherMouseUp; native = .center
        }
        let event = CGEvent(mouseEventSource: source, mouseType: type,
                            mouseCursorPosition: CGEvent(source: nil)?.location ?? .zero, mouseButton: native)
        event?.flags = flags(modifiers)
        return post(event, summary: "Mouse \(button.rawValue) \(down ? "down" : "up")", release: !down)
    }
    func scroll(horizontal: Int, vertical: Int, modifiers: KeyModifiers) {
        endRiveArrowBurst()
        let event = CGEvent(scrollWheelEvent2Source: source, units: .line, wheelCount: 2,
                            wheel1: Int32(clamping: vertical), wheel2: Int32(clamping: horizontal), wheel3: 0)
        event?.flags = flags(modifiers)
        post(event, summary: "Scroll")
    }
    func media(_ key: MediaKey) {
        endRiveArrowBurst()
        let code: Int
        switch key {
        case .volumeUp: code = 0
        case .volumeDown: code = 1
        case .mute: code = 7
        case .playPause: code = 16
        case .nextTrack: code = 17
        case .previousTrack: code = 18
        }
        for down in [true, false] {
            let event = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
                subtype: 8, data1: (code << 16) | ((down ? 0xa : 0xb) << 8), data2: -1)?.cgEvent
            if !post(event, summary: "Media \(key.rawValue)", release: !down), down { return }
        }
    }
}
