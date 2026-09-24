import Foundation

/// Rive numeric arrows use the physically validated keyboard repeat rate.
/// Excess detents are discarded without catch-up. No timer generates downs.
struct RiveArrowBurst {
    enum Delivery { case sent, filtered, unavailable }
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
    private var lastEmission: TimeInterval?
    static let repeatLimitHz: Double = 12
    static let minimumInterval: TimeInterval = 1.0 / repeatLimitHz
    static let idleInterval: TimeInterval = 0.08

    mutating func step(_ shortcut: SmartShortcut, context: RiveShortcutBuffer.Context,
                       now: TimeInterval, minimumInterval: TimeInterval = Self.minimumInterval,
                       emit: (Event) -> Bool) -> Delivery {
        guard now.isFinite, minimumInterval.isFinite, minimumInterval >= 0,
              [125, 126].contains(shortcut.keyCode), shortcut.repeatCount == 1 else {
            _ = end(emit: emit); return .unavailable
        }
        if let held, held.context != context || held.shortcut != shortcut ||
            now < held.lastDetent || now - held.lastDetent >= Self.idleInterval {
            guard end(emit: emit) else { return .unavailable }
        }
        if minimumInterval > 0, let lastEmission, now - lastEmission < minimumInterval {
            // Rotation continues: retain the hold, but never replay skipped
            // detents after stopping or changing direction/modifier/context.
            if held != nil {
                held = Held(context: context, shortcut: shortcut, lastDetent: now)
            }
            return .filtered
        }
        let event = Event(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers,
                          down: true, isRepeat: held != nil)
        guard emit(event) else { _ = end(emit: emit); return .unavailable }
        held = Held(context: context, shortcut: shortcut, lastDetent: now)
        lastEmission = now
        return .sent
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
