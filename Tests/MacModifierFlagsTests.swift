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
        print("macOS modifier flag tests passed")
    }
}
