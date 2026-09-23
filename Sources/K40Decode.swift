import Foundation

/// A lossless, stateless interpretation of the K40's observed 12-byte input report 8.
/// The caller retains press history if it needs edges; a repeated E0 frame is still a
/// valid snapshot, and every F1 frame is a separate observed dial tick.
enum K40DecodeResult: Equatable {
    case input(K40InputFrame)
    case invalid(K40InvalidFrame)
}

struct K40InvalidFrame: Equatable {
    enum Reason: Equatable {
        case wrongReportID(UInt32)
        case wrongLength(Int)
        case mismatchedPrefix(UInt8)
    }

    let reason: Reason
    let reportID: UInt32
    let rawBytes: [UInt8]
}

struct K40InputFrame: Equatable {
    enum Payload: Equatable {
        /// E0 bytes 4–7 are a little-endian 32-bit control-state bitmap. No
        /// group index or key event edge is inferred from an individual frame.
        case controls(rawMask: UInt32)
        /// F1 byte 3 identifies the observed dial (1 inner, 2 outer); byte 5
        /// is an observed direction code (1 clockwise, 2 anticlockwise).
        /// Unknown dial IDs and direction codes remain raw here.
        case dial(rawDialID: UInt8, rawDirection: UInt8)
        case unknown(rawOpcode: UInt8)
    }

    let reportID: UInt32
    let rawBytes: [UInt8]
    let payload: Payload

    /// These bytes are deliberately exposed rather than assigned speculative
    /// semantic names. In the captured E0 frames, bytes 2–3 were `01 01`.
    var headerBytes: [UInt8] { Array(rawBytes[2...3]) }
    var trailingBytes: [UInt8] { Array(rawBytes[8...11]) }

    /// Physical button numbering follows the guided capture's user labels.
    /// Only these eight bits were established by the button_1…button_8 phases.
    var observedPressedButtons: [Int]? {
        guard case .controls(let mask) = payload else { return nil }
        let bitForButton = K40ButtonLayout.masksInRowOrder
        return bitForButton.enumerated().compactMap { index, bit in mask & bit != 0 ? index + 1 : nil }
    }

    /// Both set-button bits were observed, but the full raw mask is authoritative.
    var observedSetButtons: [SetButton]? {
        guard case .controls(let mask) = payload else { return nil }
        var result: [SetButton] = []
        if mask & 0x1000 != 0 { result.append(.previous) }
        if mask & 0x2000 != 0 { result.append(.next) }
        return result
    }

    enum SetButton: Equatable { case previous, next }

    /// One captured F1 report represented one turn indication. A fast turn
    /// produced multiple reports, so this never multiplies by speed or time.
    var observedDialDelta: Int? {
        guard case .dial(let dialID, let direction) = payload, dialID == 1 || dialID == 2 else { return nil }
        switch direction {
        case 1: return 1
        case 2: return -1
        default: return nil
        }
    }
}

enum K40Decode {
    static func normalizeBluetoothReport(_ bytes: [UInt8]) -> [UInt8]? {
        // Captured FFE1 frames begin 55 54 and carry the USB-shaped report
        // at offset 1. Keep the full original notification in the session log.
        guard bytes.count > 13, bytes[0] == 0x55, bytes[1] == 0x54 else { return nil }
        var report = Array(bytes[1..<13])
        report[0] = 8
        return report
    }

    static func parse(reportID: UInt32, bytes: [UInt8]) -> K40DecodeResult {
        guard reportID == 8 else {
            return .invalid(K40InvalidFrame(reason: .wrongReportID(reportID), reportID: reportID, rawBytes: bytes))
        }
        guard bytes.count == 12 else {
            return .invalid(K40InvalidFrame(reason: .wrongLength(bytes.count), reportID: reportID, rawBytes: bytes))
        }
        guard bytes[0] == 0x08 else {
            return .invalid(K40InvalidFrame(reason: .mismatchedPrefix(bytes[0]), reportID: reportID, rawBytes: bytes))
        }

        let payload: K40InputFrame.Payload
        switch bytes[1] {
        case 0xe0:
            let mask = UInt32(bytes[4]) | (UInt32(bytes[5]) << 8)
                | (UInt32(bytes[6]) << 16) | (UInt32(bytes[7]) << 24)
            payload = .controls(rawMask: mask)
        case 0xf1:
            payload = .dial(rawDialID: bytes[3], rawDirection: bytes[5])
        default:
            payload = .unknown(rawOpcode: bytes[1])
        }
        return .input(K40InputFrame(reportID: reportID, rawBytes: bytes, payload: payload))
    }
}
