/// The shared HID snapshot includes posted events. Only unmarked input edges
/// can establish physical ownership after the initial snapshot.
struct PhysicalInputState {
    private(set) var keys = Set<UInt16>()
    private(set) var buttons = Set<UInt32>()
    private var postedKeys = Set<UInt16>()
    private var postedButtons = Set<UInt32>()

    mutating func key(_ code: UInt16, down: Bool, posted: Bool) {
        if posted {
            if down { postedKeys.insert(code) } else { postedKeys.remove(code) }
        } else {
            if down { keys.insert(code) } else { keys.remove(code) }
        }
    }

    mutating func button(_ code: UInt32, down: Bool, posted: Bool) {
        if posted {
            if down { postedButtons.insert(code) } else { postedButtons.remove(code) }
        } else {
            if down { buttons.insert(code) } else { buttons.remove(code) }
        }
    }

    mutating func seed(keys snapshot: Set<UInt16>, buttons mouseSnapshot: Set<UInt32>) {
        // Recover after an observer interruption without adopting our own holds.
        // A previously observed physical overlap retains ownership until released.
        keys = snapshot.subtracting(postedKeys.subtracting(keys))
        buttons = mouseSnapshot.subtracting(postedButtons.subtracting(buttons))
    }
}
