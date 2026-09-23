import Foundation

enum LabelError: Error, CustomStringConvertible {
    case groupRange, keyRange, tooLong
    var description: String {
        switch self {
        case .groupRange: return "Group must be 1...6"
        case .keyRange: return "Key must be 1...8"
        case .tooLong: return "Label exceeds the observed firmware field length"
        }
    }
}

enum K40LabelPacket {
    static func group(_ group: Int, text: String) throws -> [UInt8] {
        guard (1...6).contains(group) else { throw LabelError.groupRange }
        return try encode(prefix: [0x18, 0x01, 0x05, 0x03, UInt8(group)], text: text, capacity: 58)
    }
    static func key(_ key: Int, group: Int, text: String) throws -> [UInt8] {
        guard (1...6).contains(group) else { throw LabelError.groupRange }
        guard (1...8).contains(key) else { throw LabelError.keyRange }
        return try encode(prefix: [0x18, 0x02, 0x05, 0x03, UInt8(group), 0, UInt8(key)], text: text, capacity: 56)
    }
    private static func encode(prefix: [UInt8], text: String, capacity: Int) throws -> [UInt8] {
        let bytes: [UInt8] = text.utf16.flatMap { [UInt8($0 & 0xff), UInt8($0 >> 8)] }
        guard bytes.count <= capacity else { throw LabelError.tooLong }
        var result = prefix + [UInt8(bytes.count)] + bytes
        result += Array(repeating: 0, count: 64 - result.count)
        return result
    }
}
