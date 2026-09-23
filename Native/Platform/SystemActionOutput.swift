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
    private var physicalKeys = Set<UInt16>()
    private(set) var observing = false
    var enabled = false
    /// Used only by the neutral in-app verifier; normal control output stays on the HID path.
    var targetProcessID: pid_t?
    /// Production output may begin only while its selected foreground process is still active.
    var expectedForegroundPID: pid_t?
    var onObservationLost: (() -> Void)?
    var onOutput: ((String) -> Void)?

    func startObserving() {
        guard tap == nil else { return }
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged]
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
                    if type == .keyDown { owner.physicalKeys.insert(code) }
                    if type == .keyUp { owner.physicalKeys.remove(code) }
                    if type == .flagsChanged {
                        // HID state distinguishes left/right modifiers sharing one aggregate flag.
                        if CGEventSource.keyState(.hidSystemState, key: code) {
                            owner.physicalKeys.insert(code)
                        } else { owner.physicalKeys.remove(code) }
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
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        tap = nil; runLoopSource = nil; physicalKeys.removeAll(); observing = false
    }
    private func seedPhysicalState() {
        physicalKeys = Set((UInt16(0)...UInt16(127)).filter { CGEventSource.keyState(.hidSystemState, key: $0) })
    }
    func physicalKeyIsDown(_ code: UInt16) -> Bool { CGEventSource.keyState(.hidSystemState, key: code) }
    func physicalMouseButtonIsDown(_ button: MouseButton) -> Bool {
        let native: CGMouseButton
        switch button {
        case .left: native = .left
        case .right: native = .right
        case .middle: native = .center
        }
        return CGEventSource.buttonState(.hidSystemState, button: native)
    }
    private var physicalFlags: CGEventFlags {
        var flags = CGEventFlags()
        for (codes, flag) in [([UInt16(55), 54], CGEventFlags.maskCommand),
                              ([56, 60], .maskShift), ([58, 61], .maskAlternate),
                              ([59, 62], .maskControl), ([63], .maskSecondaryFn)] {
            if codes.contains(where: physicalKeys.contains) { flags.insert(flag) }
        }
        // Caps lock is a toggle, not an owned hold.
        if CGEventSource.flagsState(.hidSystemState).contains(.maskAlphaShift) { flags.insert(.maskAlphaShift) }
        return flags
    }
    private func flags(_ modifiers: KeyModifiers) -> CGEventFlags {
        CGEventFlags(rawValue: modifiers.rawValue).union(physicalFlags)
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
        onOutput?(summary)
        return true
    }
    @discardableResult
    func key(code: UInt16, down: Bool, modifiers: KeyModifiers) -> Bool {
        let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
        event?.flags = flags(modifiers)
        if [54, 55, 56, 58, 59, 60, 61, 62, 63].contains(code) { event?.type = .flagsChanged }
        return post(event, summary: "Key \(code) \(down ? "down" : "up")", release: !down)
    }
    func text(_ value: String) {
        let units = Array(value.utf16)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
            units.withUnsafeBufferPointer { event?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: $0.baseAddress) }
            event?.flags = physicalFlags
            if !post(event, summary: "Text \(down ? "down" : "up")", release: !down), down { return }
        }
    }
    @discardableResult
    func mouse(button: MouseButton, down: Bool, modifiers: KeyModifiers) -> Bool {
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
        let event = CGEvent(scrollWheelEvent2Source: source, units: .line, wheelCount: 2,
                            wheel1: Int32(clamping: vertical), wheel2: Int32(clamping: horizontal), wheel3: 0)
        event?.flags = flags(modifiers)
        post(event, summary: "Scroll")
    }
    func media(_ key: MediaKey) {
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
