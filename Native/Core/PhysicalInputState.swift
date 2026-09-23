/// The shared HID snapshot includes posted events. Only unmarked input edges
/// can establish physical ownership after the initial snapshot.
struct PhysicalInputState {
    private(set) var keys = Set<UInt16>()
    private(set) var buttons = Set<UInt32>()
    private(set) var postedKeys = Set<UInt16>()
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

    mutating func modifier(_ code: UInt16, flags: UInt64) {
        // Side-specific masks from IOKit/hidsystem/IOLLEvent.h. Read the
        // event itself: the shared snapshot can still represent the previous
        // state when a head-insert HID observer receives flagsChanged.
        let pair: (left: UInt16, right: UInt16, aggregate: UInt64, leftMask: UInt64, rightMask: UInt64)
        switch code {
        case 54, 55: pair = (55, 54, 0x100000, 0x08, 0x10)
        case 56, 60: pair = (56, 60, 0x020000, 0x02, 0x04)
        case 58, 61: pair = (58, 61, 0x080000, 0x20, 0x40)
        case 59, 62: pair = (59, 62, 0x040000, 0x01, 0x2000)
        case 63: key(code, down: flags & 0x800000 != 0, posted: false); return
        default: return
        }
        if flags & pair.aggregate == 0 {
            key(pair.left, down: false, posted: false)
            key(pair.right, down: false, posted: false)
        } else if flags & (pair.leftMask | pair.rightMask) != 0 {
            key(pair.left, down: flags & pair.leftMask != 0, posted: false)
            key(pair.right, down: flags & pair.rightMask != 0, posted: false)
        } else {
            // Some virtual keyboards omit side bits. Preserve aggregate hold
            // until their flagsChanged event explicitly clears it.
            key(code, down: true, posted: false)
        }
    }

    mutating func seed(keys snapshot: Set<UInt16>, buttons mouseSnapshot: Set<UInt32>) {
        // Recover after an observer interruption without adopting our own holds.
        // A previously observed physical overlap retains ownership until released.
        keys = snapshot.subtracting(postedKeys.subtracting(keys))
        buttons = mouseSnapshot.subtracting(postedButtons.subtracting(buttons))
    }
}
