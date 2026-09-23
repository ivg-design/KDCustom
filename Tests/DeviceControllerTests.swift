import Foundation

@main
enum DeviceControllerTests {
    static func check(_ condition: Bool, _ message: String) {
        if !condition { fatalError(message) }
    }

    static func e0(_ mask: UInt32) -> [UInt8] {
        [0x08, 0xe0, 0x01, 0x01,
         UInt8(mask & 0xff), UInt8((mask >> 8) & 0xff),
         UInt8((mask >> 16) & 0xff), UInt8((mask >> 24) & 0xff),
         0, 0, 0, 0]
    }

    static func f1(dial: UInt8, direction: UInt8) -> [UInt8] {
        [0x08, 0xf1, 0x01, dial, 0, direction, 0, 0, 0, 0, 0, 0]
    }

    static func main() throws {
        var edges = K40ControlEdges()
        check(edges.consume(reportID: 8, bytes: e0(0x0002)) ==
              [K40ControlEvent(control: .key1, pressed: true)],
              "physical top-left key uses bit 0x02")
        check(edges.consume(reportID: 8, bytes: e0(0x0002)).isEmpty,
              "repeated held snapshots do not re-press")
        check(edges.consume(reportID: 8, bytes: e0(0x000a)) ==
              [K40ControlEvent(control: .key2, pressed: true)],
              "chord transition presses only newly held key")
        check(edges.consume(reportID: 8, bytes: e0(0x2008)) ==
              [K40ControlEvent(control: .key1, pressed: false),
               K40ControlEvent(control: .setNext, pressed: true)],
              "state transition releases and presses in deterministic order")
        check(edges.consume(reportID: 8, bytes: e0(0x1000)) ==
              [K40ControlEvent(control: .key2, pressed: false),
               K40ControlEvent(control: .setNext, pressed: false),
               K40ControlEvent(control: .setPrevious, pressed: true)],
              "both observed group buttons map independently")
        check(edges.consume(reportID: 8, bytes: e0(0x80001000)).isEmpty,
              "unknown high mask bits do not become controls")
        check(edges.consume(reportID: 8, bytes: f1(dial: 1, direction: 1)) ==
              [K40ControlEvent(control: .dial1CW, pressed: true),
               K40ControlEvent(control: .dial1CW, pressed: false)],
              "inner clockwise report is a pulse")
        check(edges.consume(reportID: 8, bytes: f1(dial: 1, direction: 2)).first?.control == .dial1CCW,
              "inner counterclockwise mapping")
        check(edges.consume(reportID: 8, bytes: f1(dial: 2, direction: 1)).first?.control == .dial2CW,
              "outer clockwise mapping")
        check(edges.consume(reportID: 8, bytes: f1(dial: 2, direction: 2)).first?.control == .dial2CCW,
              "outer counterclockwise mapping")
        check(edges.consume(reportID: 8, bytes: f1(dial: 3, direction: 1)).isEmpty,
              "unknown dial is ignored")
        check(edges.consume(reportID: 8, bytes: f1(dial: 1, direction: 3)).isEmpty,
              "unknown direction is ignored")
        check(edges.consume(reportID: 5, bytes: e0(0)).isEmpty &&
              edges.consume(reportID: 8, bytes: [0x08]).isEmpty,
              "other reports and truncated frames are ignored")
        check(edges.releaseAll() == [K40ControlEvent(control: .setPrevious, pressed: false)] &&
              edges.held.isEmpty && edges.releaseAll().isEmpty,
              "disconnect releases exactly the held controls once")

        let c9 = [UInt8(19), 0xc9] + Array(repeating: UInt8(0), count: 17)
        let c8 = [UInt8(20), 0xc8] + Array(repeating: UInt8(0), count: 18)
        check(K40Bluetooth.matchesCommandReply(c9, index: 0xc9) &&
              K40Bluetooth.matchesCommandReply(c8, index: 0xc8),
              "startup replies require complete declared frames")
        check(!K40Bluetooth.matchesCommandReply([0x03, 0xc9, 0x00], index: 0xc9) &&
              !K40Bluetooth.matchesCommandReply([0x06, 0xd1, 0x63], index: 0xd1) &&
              !K40Bluetooth.matchesCommandReply([0x06, 0xd1, 0x63, 0x64, 0, 0], index: 0xde) &&
              K40Bluetooth.matchesCommandReply([0x06, 0xd1, 0x63, 0x64, 0, 0], index: 0xd1),
              "short acknowledgements, partial replies, and wrong command indices are ignored")

        let oldCallbackTarget = NSObject()
        let staleContext = K40HIDCallbackRegistry.register(oldCallbackTarget)
        check(K40HIDCallbackRegistry.resolve(staleContext, as: NSObject.self) === oldCallbackTarget,
              "active HID callback token resolves its target")
        K40HIDCallbackRegistry.unregister(staleContext)
        let newCallbackTarget = NSObject()
        let currentContext = K40HIDCallbackRegistry.register(newCallbackTarget)
        check(K40HIDCallbackRegistry.resolve(staleContext, as: NSObject.self) == nil &&
              K40HIDCallbackRegistry.resolve(currentContext, as: NSObject.self) === newCallbackTarget &&
              staleContext != currentContext,
              "a queued stale HID callback cannot resolve a new registration")
        K40HIDCallbackRegistry.unregister(currentContext)
        check(K40HIDCallbackRegistry.allocateReportBuffer(length: 513) == nil,
              "oversized HID input reports cannot exceed bounded persistent storage")

        var group = KeydialGroup(id: "group-1", name: "GROUP 1")
        let keys: [ControlID] = [.key1, .key2, .key3, .key4,
                                 .key5, .key6, .key7, .key8]
        for (index, key) in keys.enumerated() {
            let position = group.controls.firstIndex { $0.controlID == key }!
            group.controls[position].label = "K\(index + 1)"
        }
        let writes = try K40LabelPlan.make(group: group, slot: 1)
        check(writes.count == 9 && writes[0].delayAfter == 1.0 &&
              writes.dropFirst().allSatisfy { $0.delayAfter == 0.2 },
              "group and all eight keys use observed vendor spacing")
        check(writes[0].bytes[1] == 0x01 && writes[0].bytes[4] == 1 &&
              writes[0].bytes[5] == 14,
              "group-name packet is first and encodes UTF-16LE text")
        for index in 1...8 {
            let packet = writes[index].bytes
            check(packet.count == 64 && packet[1] == 0x02 && packet[4] == 1 &&
                  packet[6] == UInt8(K40ButtonLayout.wireSlotsInRowOrder[index - 1]) &&
                  packet[8] == UInt8(Character("K").asciiValue!) &&
                  packet[10] == UInt8(Character(String(index)).asciiValue!),
                  "physical key \(index) targets its observed wire slot and label")
        }
        do {
            _ = try K40LabelPlan.make(group: group, slot: 7)
            fatalError("Out-of-range group slot was accepted")
        } catch LabelError.groupRange {
            // Expected.
        }
        print("DeviceControllerTests passed")
    }
}
