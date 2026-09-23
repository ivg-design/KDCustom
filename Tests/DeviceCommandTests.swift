import Foundation

@main
enum DeviceCommandTests {
    static func check(_ result: @autoclosure () -> Bool, _ message: String) {
        if !result() { fatalError(message) }
    }

    static func usb(_ payload: [UInt8]) -> [UInt8] {
        [UInt8(payload.count + 2), 0x03] + payload
    }

    static func ble(_ index: K40DeviceCommands.Read, _ payload: [UInt8]) -> [UInt8] {
        [UInt8(payload.count + 2), index.rawValue] + payload
    }

    static func main() {
        typealias Commands = K40DeviceCommands
        check(Commands.usbRequest(for: .brightness).value == 0x03d9, "read request index")
        check(Commands.usbRequest(for: .brightnessDown).value == 0x03d8, "step request index")
        check(Commands.bluetoothRequest(for: .dormantTimeUp) == [0xcd, 0xda, 0, 0, 0, 0, 0, 0], "BLE indexed request")

        let brightness: [(UInt8, Int)] = [(1, 1), (2, 2), (4, 3), (8, 4), (16, 5)]
        for (raw, level) in brightness {
            check(Commands.decode(usb([raw]), for: .brightness, transport: .usb)?.value == .brightnessLevel(level), "brightness mapping")
        }
        check(Commands.decode(usb([3]), for: .brightness, transport: .usb)?.value == .unrecognized, "unknown brightness retained")

        let dormant: [(UInt8, Int)] = [(0x0f, 1), (0x1e, 2), (0x3c, 3), (0x5a, 4), (0x78, 5)]
        for (raw, level) in dormant {
            check(Commands.decode(ble(.dormantTime, [raw]), for: .dormantTime, transport: .bluetooth)?.value == .dormantLevel(level), "dormant mapping")
        }
        for code in UInt8(0)...3 {
            check(Commands.decode(usb([code]), for: .rotation, transport: .usb)?.value == .rotationDegrees(Int(code) * 90), "rotation mapping")
        }
        check(Commands.decode(usb([4, 0, 0, 0]), for: .rotation, transport: .usb)?.value == .rotationDegrees(0), "live full-turn rotation normalizes to zero")
        check(Commands.decode(usb([5]), for: .rotation, transport: .usb)?.value == .unrecognized, "unknown rotation retained")

        check(Commands.decode(usb([20, 100]), for: .battery, transport: .usb)?.value == .batteryBucket(20), "battery percent threshold")
        check(Commands.decode(usb([81, 100]), for: .battery, transport: .usb)?.value == .batteryBucket(100), "battery percent upper bucket")
        check(Commands.decode(usb([0x80, 0]), for: .battery, transport: .usb)?.value == .batteryBucket(100), "battery status code")
        check(Commands.decode([6, 3, 100, 0, 0, 0], for: .battery, transport: .usb)?.value == .batteryBucket(100), "physical OLED full agrees with observed USB report")
        check(Commands.decode(ble(.battery, [100, 0, 0, 0]), for: .battery, transport: .bluetooth)?.value == .batteryBucket(80), "USB correction does not reinterpret unverified BLE status format")
        check(Commands.decode(usb([255, 100]), for: .battery, transport: .usb)?.value == .unrecognized, "battery out of range")

        // The real E8 response failed the USB descriptor check. Unrecognized
        // command replies must never initialize a native group or setting.
        let invalidE8: [UInt8] = [0xc0, 0x0e, 0x00, 0x20, 0x69, 0x01, 0x00, 0x08]
        check(Commands.decode(invalidE8, for: .brightness, transport: .usb) == nil, "invalid USB descriptor")
        check(Commands.decode([4, 0xd9, 2, 0], for: .brightness, transport: .bluetooth)?.value == .brightnessLevel(2), "BLE reply index")
        check(Commands.decode([4, 0xd8, 2, 0], for: .brightness, transport: .bluetooth) == nil, "wrong BLE index")
        check(Commands.decode([5, 0xd9, 2, 0], for: .brightness, transport: .bluetooth) == nil, "truncated BLE reply")
        print("K40 device command fixtures passed")
    }
}
