enum K40ButtonLayout {
    // Observed with dials at the left: firmware slots alternate bottom/top
    // in each column. Present buttons to the user as top 1–4, bottom 5–8.
    static let wireSlotsInRowOrder = [2, 4, 6, 8, 1, 3, 5, 7]

    static func wireSlot(forPhysicalButton button: Int) -> Int? {
        guard (1...8).contains(button) else { return nil }
        return wireSlotsInRowOrder[button - 1]
    }

    static var masksInRowOrder: [UInt32] {
        wireSlotsInRowOrder.map { UInt32(1) << ($0 - 1) }
    }
}
