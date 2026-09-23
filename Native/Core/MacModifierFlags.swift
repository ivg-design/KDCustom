/// macOS key events need both aggregate and side-specific modifier bits.
/// AppKit's contains(.command) accepts aggregate-only events, while Flutter's
/// macOS key responder synchronizes modifier keys from the side bits.
enum MacModifierFlags {
    static let sideMask: UInt64 = 0x207f
    static func encode(_ modifiers: KeyModifiers, heldKeys: Set<UInt16> = []) -> UInt64 {
        var flags = modifiers.rawValue
        let pairs: [(KeyModifiers, UInt16, UInt16, UInt64, UInt64)] = [
            (.command, 55, 54, 0x08, 0x10), (.shift, 56, 60, 0x02, 0x04),
            (.option, 58, 61, 0x20, 0x40), (.control, 59, 62, 0x01, 0x2000)
        ]
        for (modifier, left, right, leftFlag, rightFlag) in pairs where modifiers.contains(modifier) {
            if heldKeys.contains(right) { flags |= rightFlag }
            if heldKeys.contains(left) || !heldKeys.contains(right) { flags |= leftFlag }
        }
        return flags
    }
}
