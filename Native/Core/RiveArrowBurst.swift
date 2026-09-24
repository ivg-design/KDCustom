import Foundation

/// One down per physical detent. Consecutive detents become repeats of a held
/// arrow; only an idle/context boundary emits its up. No timer generates downs.
struct RiveArrowBurst {
    struct Event: Equatable {
        let keyCode: UInt16
        let modifiers: KeyModifiers
        let down: Bool
        let isRepeat: Bool
    }
    private struct Held {
        let context: RiveShortcutBuffer.Context
        let shortcut: SmartShortcut
        let lastDetent: TimeInterval
    }
    private var held: Held?
    static let idleInterval: TimeInterval = 0.08

    mutating func step(_ shortcut: SmartShortcut, context: RiveShortcutBuffer.Context,
                       now: TimeInterval, emit: (Event) -> Bool) -> Bool {
        guard now.isFinite, [125, 126].contains(shortcut.keyCode), shortcut.repeatCount == 1 else {
            _ = end(emit: emit); return false
        }
        if let held, held.context != context || held.shortcut != shortcut ||
            now < held.lastDetent || now - held.lastDetent >= Self.idleInterval {
            guard end(emit: emit) else { return false }
        }
        let event = Event(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers,
                          down: true, isRepeat: held != nil)
        guard emit(event) else { _ = end(emit: emit); return false }
        held = Held(context: context, shortcut: shortcut, lastDetent: now)
        return true
    }

    @discardableResult
    mutating func end(emit: (Event) -> Bool) -> Bool {
        guard let held else { return true }
        guard emit(Event(keyCode: held.shortcut.keyCode, modifiers: held.shortcut.modifiers,
                         down: false, isRepeat: false)) else { return false }
        self.held = nil
        return true
    }

    mutating func tick(now: TimeInterval, emit: (Event) -> Bool) {
        guard let held else { return }
        if !now.isFinite || now < held.lastDetent || now - held.lastDetent >= Self.idleInterval {
            _ = end(emit: emit)
        }
    }
}
