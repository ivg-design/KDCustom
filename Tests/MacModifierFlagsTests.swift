@main
enum MacModifierFlagsTests {
    static func main() {
        // These side bits are the ones Flutter's macOS responder consumes.
        precondition(MacModifierFlags.encode(.command) == 0x100008)
        precondition(MacModifierFlags.encode(.shift) == 0x020002)
        precondition(MacModifierFlags.encode(.option) == 0x080020)
        precondition(MacModifierFlags.encode(.control) == 0x040001)
        precondition(MacModifierFlags.encode([.command, .shift]) == 0x12000a)
        precondition(MacModifierFlags.encode(.command, heldKeys: [54]) == 0x100010)
        precondition(MacModifierFlags.encode(.command, heldKeys: [54, 55]) == 0x100018)
        precondition(MacModifierFlags.encode([], heldKeys: [55]) == 0)
        precondition(MacModifierFlags.encode(.function) == 0x800000)
        // Physical reference: plain 0xa00100, Command 0xb00108. The 0x100
        // non-coalescing bit is not a keyboard modifier and is not copied.
        for arrow in UInt16(123)...UInt16(126) {
            precondition(MacModifierFlags.identifyingArrow(arrow, flags: 0) == 0xa00000)
            precondition(MacModifierFlags.identifyingArrow(arrow,
                flags: MacModifierFlags.encode(.command)) == 0xb00008)
            precondition(MacModifierFlags.identifyingArrow(arrow,
                flags: MacModifierFlags.encode(.shift)) == 0xa20002)
            precondition(MacModifierFlags.identifyingArrow(arrow, flags: 0xa00000) == 0xa00000)
        }
        precondition(MacModifierFlags.identifyingArrow(0, flags: 0x100008) == 0x100008)
        precondition(MacModifierFlags.identifyingArrow(36, flags: 0) == 0)
        print("macOS modifier flag tests passed")
    }
}
