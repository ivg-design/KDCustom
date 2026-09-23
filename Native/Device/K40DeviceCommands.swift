import Foundation

/// The fixed setting indices found in the installed Huion driver's ARM64 code.
/// This file only builds requests and decodes supplied bytes; it performs no I/O.
enum K40DeviceCommands {
    enum Read: UInt8, Sendable {
        case battery = 0xd1
        case brightness = 0xd9
        case dormantTime = 0xdc
        case rotation = 0xde
    }

    enum Step: UInt8, Sendable {
        case brightnessUp = 0xd7
        case brightnessDown = 0xd8
        case dormantTimeUp = 0xda
        case dormantTimeDown = 0xdb
        case rotationNext = 0xdd
    }

    enum Transport: Equatable, Sendable { case usb, bluetooth }

    struct USBRequest: Equatable, Sendable {
        let requestType: UInt8 = 0x80
        let request: UInt8 = 0x06
        let value: UInt16
        let index: UInt16 = 0x0409
        let length: UInt16 = 128
    }

    enum Value: Equatable, Sendable {
        /// Driver display bucket; not a calibrated true percentage.
        case batteryBucket(Int)
        case brightnessLevel(Int)
        case dormantLevel(Int)
        case rotationDegrees(Int)
        case unrecognized
    }

    struct Response: Equatable, Sendable {
        let transport: Transport
        let index: Read
        let raw: [UInt8]
        let payload: [UInt8]
        let value: Value
    }

    static func usbRequest(for index: Read) -> USBRequest {
        USBRequest(value: 0x0300 | UInt16(index.rawValue))
    }

    static func usbRequest(for index: Step) -> USBRequest {
        USBRequest(value: 0x0300 | UInt16(index.rawValue))
    }

    static func bluetoothRequest(for index: Read) -> [UInt8] {
        [0xcd, index.rawValue, 0, 0, 0, 0, 0, 0]
    }

    static func bluetoothRequest(for index: Step) -> [UInt8] {
        [0xcd, index.rawValue, 0, 0, 0, 0, 0, 0]
    }

    /// The vendor driver discards two leading bytes for both transports. Its
    /// callers do not validate them; we do, so failed/foreign replies remain
    /// raw in the transport log instead of becoming a setting value.
    static func decode(_ raw: [UInt8], for index: Read, transport: Transport) -> Response? {
        guard raw.count >= 3 else { return nil }
        let declaredLength = Int(raw[0])
        guard declaredLength >= 3, declaredLength == raw.count else { return nil }
        switch transport {
        case .usb:
            guard raw[1] == 0x03 else { return nil }
        case .bluetooth:
            guard raw[1] == index.rawValue else { return nil }
        }
        let payload = Array(raw.dropFirst(2))
        // Live USB 64 00 00 00 was compared with the physical OLED at Full.
        // The older driver's status-code branch incorrectly buckets it at 80.
        // Keep this correction limited to the observed transport and payload;
        // it does not establish a linear percentage scale for other reports.
        if transport == .usb, index == .battery, payload == [100, 0, 0, 0] {
            return Response(transport: transport, index: index, raw: raw,
                            payload: payload, value: .batteryBucket(100))
        }
        return Response(transport: transport, index: index, raw: raw,
                        payload: payload, value: decodePayload(payload, for: index))
    }

    private static func decodePayload(_ payload: [UInt8], for index: Read) -> Value {
        guard let first = payload.first else { return .unrecognized }
        switch index {
        case .battery:
            guard payload.count >= 2 else { return .unrecognized }
            let second = payload[1]
            if second == 100 {
                switch first {
                case 0...20: return .batteryBucket(20)
                case 21...40: return .batteryBucket(40)
                case 41...60: return .batteryBucket(60)
                case 61...80: return .batteryBucket(80)
                case 81...100: return .batteryBucket(100)
                default: return .unrecognized
                }
            }
            switch first {
            case 1: return .batteryBucket(20)
            case 2...4: return .batteryBucket(40)
            case 5...16: return .batteryBucket(60)
            case 17...127: return .batteryBucket(80)
            case 128: return .batteryBucket(100)
            default: return .unrecognized
            }
        case .brightness:
            switch first {
            case 1: return .brightnessLevel(1)
            case 2: return .brightnessLevel(2)
            case 4: return .brightnessLevel(3)
            case 8: return .brightnessLevel(4)
            case 16: return .brightnessLevel(5)
            default: return .unrecognized
            }
        case .dormantTime:
            switch first {
            case 0x0f: return .dormantLevel(1)
            case 0x1e: return .dormantLevel(2)
            case 0x3c: return .dormantLevel(3)
            case 0x5a: return .dormantLevel(4)
            case 0x78: return .dormantLevel(5)
            default: return .unrecognized
            }
        case .rotation:
            switch first {
            // Live K40 DD/DE cycles 1,2,3,4; 4 is a full turn.
            // Retain 0 for the equivalent zero value accepted by the driver.
            case 0, 4: return .rotationDegrees(0)
            case 1: return .rotationDegrees(90)
            case 2: return .rotationDegrees(180)
            case 3: return .rotationDegrees(270)
            default: return .unrecognized
            }
        }
    }
}
