import Foundation

@main
enum DecodeTests {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }

    static func frame(_ hex: String) -> [UInt8] {
        hex.split(separator: " ").map { UInt8($0, radix: 16)! }
    }

    static func decoded(_ hex: String) -> K40InputFrame {
        guard case .input(let result) = K40Decode.parse(reportID: 8, bytes: frame(hex)) else {
            fatalError("Expected captured input frame: \(hex)")
        }
        return result
    }

    static func main() {
        check(K40ButtonLayout.wireSlotsInRowOrder == [2,4,6,8,1,3,5,7], "user-confirmed OLED slot order")
        check(K40ButtonLayout.wireSlot(forPhysicalButton: 0) == nil && K40ButtonLayout.wireSlot(forPhysicalButton: 9) == nil, "layout bounds")
        let bleButton = frame("55 54 e0 01 01 02 00 00 00 00 00 00 00 e4")
        check(K40Decode.normalizeBluetoothReport(bleButton) == frame("08 e0 01 01 02 00 00 00 00 00 00 00"), "live FFE1 normalization")
        check(K40Decode.normalizeBluetoothReport(Array(bleButton.prefix(13))) == nil, "truncated BLE packet")
        check(K40Decode.normalizeBluetoothReport(frame("13 c9 48 55 49 4f 4e 5f 54 32 32 31 5f 32 35 30 38 30 31")) == nil, "command response is not control input")
        // Actual button_1 and button_2 capture, including the combined held
        // state from the hold_and_chord phase. The decoder must retain both.
        let button1 = decoded("08 e0 01 01 02 00 00 00 00 00 00 00")
        check(button1.observedPressedButtons == [1], "button 1 fixture")
        let chord = decoded("08 e0 01 01 0a 00 00 00 00 00 00 00")
        check(chord.observedPressedButtons == [1, 2], "combined button state")
        check(chord.payload == .controls(rawMask: 0x0a), "full raw mask")
        let release = decoded("08 e0 01 01 00 00 00 00 00 00 00 00")
        check(release.observedPressedButtons == [], "release is empty state")
        for (button, byte) in [(1, "02"), (2, "08"), (3, "20"), (4, "80"),
                               (5, "01"), (6, "04"), (7, "10"), (8, "40")] {
            let pressed = decoded("08 e0 01 01 \(byte) 00 00 00 00 00 00 00")
            check(pressed.observedPressedButtons == [button], "captured button \(button)")
        }

        // A group-button press occupies the high byte of the mask, not the
        // eight-key bitmap. Its subsequent all-zero frame is a release.
        let next = decoded("08 e0 01 01 00 20 00 00 00 00 00 00")
        check(next.observedSetButtons == [.next], "next set button")
        check(next.observedPressedButtons == [], "next is not a press key")
        let previous = decoded("08 e0 01 01 00 10 00 00 00 00 00 00")
        check(previous.observedSetButtons == [.previous], "previous set button")
        let unknownMaskBit = decoded("08 e0 01 01 00 00 01 80 00 00 00 00")
        check(unknownMaskBit.payload == .controls(rawMask: 0x80010000), "unknown high control bits preserved")
        check(unknownMaskBit.observedPressedButtons == [] && unknownMaskBit.observedSetButtons == [], "unknown bits carry no guessed semantic")

        let innerCW = decoded("08 f1 01 01 00 01 00 00 00 00 00 00")
        let innerCCW = decoded("08 f1 01 01 00 02 00 00 00 00 00 00")
        let outerCW = decoded("08 f1 01 02 00 01 00 00 00 00 00 00")
        let outerCCW = decoded("08 f1 01 02 00 02 00 00 00 00 00 00")
        check(innerCW.payload == .dial(rawDialID: 1, rawDirection: 1) && innerCW.observedDialDelta == 1, "inner clockwise")
        check(innerCCW.observedDialDelta == -1 && outerCW.observedDialDelta == 1 && outerCCW.observedDialDelta == -1, "four dial directions")

        // Future firmware or a different interface must not be silently
        // interpreted as an observed K40 command. Unknown bytes round-trip.
        let unknown = decoded("08 aa 7f 03 12 34 56 78 90 ab cd ef")
        check(unknown.payload == .unknown(rawOpcode: 0xaa), "unknown opcode")
        check(unknown.rawBytes == frame("08 aa 7f 03 12 34 56 78 90 ab cd ef"), "unknown raw bytes preserved")
        let unknownDial = decoded("08 f1 01 03 00 07 00 00 00 00 00 00")
        check(unknownDial.observedDialDelta == nil && unknownDial.payload == .dial(rawDialID: 3, rawDirection: 7), "unknown dial semantics withheld")

        check(K40Decode.parse(reportID: 8, bytes: [0x08, 0xe0]) ==
            .invalid(K40InvalidFrame(reason: .wrongLength(2), reportID: 8, rawBytes: [0x08, 0xe0])), "truncation")
        let wrongPrefix = frame("09 e0 01 01 02 00 00 00 00 00 00 00")
        check(K40Decode.parse(reportID: 8, bytes: wrongPrefix) ==
            .invalid(K40InvalidFrame(reason: .mismatchedPrefix(9), reportID: 8, rawBytes: wrongPrefix)), "prefix mismatch")
        check(K40Decode.parse(reportID: 3, bytes: button1.rawBytes) ==
            .invalid(K40InvalidFrame(reason: .wrongReportID(3), reportID: 3, rawBytes: button1.rawBytes)), "wrong report ID")

        print("K40 decoder fixtures passed")
    }
}
