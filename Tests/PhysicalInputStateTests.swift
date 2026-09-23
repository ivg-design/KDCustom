@main
enum PhysicalInputStateTests {
    static func main() {
        var state = PhysicalInputState()
        state.seed(keys: [55], buttons: [0])
        precondition(state.keys == [55] && state.buttons == [0])
        state.key(55, down: false, posted: false)
        state.button(0, down: false, posted: false)
        // Regression: posting a down changes the OS snapshot, but must not
        // make ActionEngine or Smart output suppress the matching key-up.
        state.key(126, down: true, posted: true)
        state.button(0, down: true, posted: true)
        precondition(state.keys.isEmpty && state.buttons.isEmpty)
        state.seed(keys: [126], buttons: [0])
        precondition(state.keys.isEmpty && state.buttons.isEmpty)
        // A real press during an injected hold still owns the release.
        state.key(126, down: true, posted: false)
        state.button(0, down: true, posted: false)
        state.seed(keys: [126], buttons: [0])
        precondition(state.keys == [126] && state.buttons == [0])
        state.key(126, down: false, posted: true)
        state.button(0, down: false, posted: true)
        precondition(state.keys == [126] && state.buttons == [0])
        state.key(126, down: false, posted: false)
        state.button(0, down: false, posted: false)
        precondition(state.keys.isEmpty && state.buttons.isEmpty)
        // Idle snapshots seed real holds; left/right modifiers are distinct.
        state.seed(keys: [54, 55], buttons: [1])
        state.key(55, down: false, posted: false)
        precondition(state.keys == [54] && state.buttons == [1])
        state.seed(keys: [], buttons: [])
        precondition(state.keys.isEmpty && state.buttons.isEmpty)
        print("PhysicalInputState tests passed")
    }
}
