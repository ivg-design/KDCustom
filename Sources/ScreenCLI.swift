import Foundation
import IOKit

@main struct ScreenCLI {
    static func emit(_ value: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        print(String(data: data, encoding: .utf8)!)
    }
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        do {
            var info = K40USBDeviceInfo()
            let preflight = K40USBPreflight(0, &info)
            if args == ["--preflight"] {
                emit(["operation": "read_only_preflight", "status": String(format: "0x%08x", UInt32(bitPattern: preflight)),
                      "locationID": info.locationID, "vendorID": info.vendorID, "productID": info.productID])
                exit(preflight == kIOReturnSuccess ? 0 : 1)
            }
            if args == ["--enter-control-mode"] {
                guard preflight == kIOReturnSuccess else {
                    emit(["operation": "enter_control_mode", "error": "K40 preflight failed"]); exit(1)
                }
                var identity = K40USBReadControlIdentity(info.locationID)
                let raw = withUnsafeBytes(of: &identity.descriptor) { Array($0.prefix(Int(identity.descriptorLength))) }
                emit(["operation": "control_identity_C9", "utc": ISO8601DateFormatter().string(from: Date()),
                    "status": String(format: "0x%08x", UInt32(bitPattern: identity.status)), "locationID": info.locationID,
                    "descriptorHex": raw.map { String(format: "%02x", $0) }.joined(separator: " ")])
                let identityText = String(bytes: raw.filter { $0 >= 32 && $0 < 127 }, encoding: .ascii) ?? ""
                guard identity.status == kIOReturnSuccess, identityText.uppercased().contains("T221") else {
                    emit(["operation": "enter_control_mode", "error": "C9 did not establish expected T221 identity; C8 not sent"]); exit(1)
                }
                var mode = K40USBEnterControlMode(info.locationID)
                let modeRaw = withUnsafeBytes(of: &mode.descriptor) { Array($0.prefix(Int(mode.descriptorLength))) }
                emit(["operation": "control_mode_C8", "utc": ISO8601DateFormatter().string(from: Date()),
                    "status": String(format: "0x%08x", UInt32(bitPattern: mode.status)), "locationID": info.locationID,
                    "descriptorHex": modeRaw.map { String(format: "%02x", $0) }.joined(separator: " "),
                    "inputMode": "requires_new_physical_control_capture"])
                exit(mode.status == kIOReturnSuccess ? 0 : 1)
            }
            if args == ["--current-group"] {
                guard preflight == kIOReturnSuccess else {
                    emit(["operation": "query_current_group", "status": String(format: "0x%08x", UInt32(bitPattern: preflight))]); exit(1)
                }
                var result = K40USBQueryCurrentGroup(info.locationID)
                let raw = withUnsafeBytes(of: &result.descriptor) { Array($0.prefix(Int(result.descriptorLength))) }
                var out: [String: Any] = ["operation": "query_current_group", "utc": ISO8601DateFormatter().string(from: Date()),
                    "status": String(format: "0x%08x", UInt32(bitPattern: result.status)), "locationID": result.locationID,
                    "descriptorHex": raw.map { String(format: "%02x", $0) }.joined(separator: " "),
                    "descriptorLength": result.descriptorLength]
                if result.hasGroupByte != 0 { out["rawGroupByte"] = result.groupByte }
                emit(out); exit(result.status == kIOReturnSuccess ? 0 : 1)
            }
            let send = args.last == "--send"
            let params = send ? Array(args.dropLast()) : args
            let packet: [UInt8]
            if params.count == 3, params[0] == "--group", let group = Int(params[1]) {
                packet = try K40LabelPacket.group(group, text: params[2])
            } else if params.count == 4, params[0] == "--key", let group = Int(params[1]), let key = Int(params[2]) {
                packet = try K40LabelPacket.key(key, group: group, text: params[3])
            } else if params.count == 4, params[0] == "--button", let group = Int(params[1]), let button = Int(params[2]),
                      let slot = K40ButtonLayout.wireSlot(forPhysicalButton: button) {
                packet = try K40LabelPacket.key(slot, group: group, text: params[3])
            } else {
                fputs("Usage: k40-screen --preflight | --enter-control-mode | --current-group | --group 1..6 text [--send] | --key group wireSlot text [--send] | --button group physicalButton text [--send]\nPhysical buttons: top row 1–4, bottom row 5–8, dials at left. Without --send label commands print a packet preview only. Enter control mode before writing. --current-group is diagnostic only; tested firmware returns an invalid response.\n", stderr)
                exit(2)
            }
            var out: [String: Any] = ["utc": ISO8601DateFormatter().string(from: Date()), "packetHex": packet.map { String(format: "%02x", $0) }.joined(separator: " "),
                "request": ["bmRequestType": 0x21, "bRequest": 9, "wValue": 0x0316, "wIndex": 1, "wLength": 64],
                "operation": send ? "label_write" : "packet_preview", "locationID": info.locationID]
            out["transport"] = "USB_DeviceRequest"
            if send {
                guard preflight == kIOReturnSuccess else {
                    out["status"] = String(format: "0x%08x", UInt32(bitPattern: preflight))
                    emit(out); exit(1)
                }
                let result = packet.withUnsafeBufferPointer {
                    K40USBSendLabelPacket(info.locationID, $0.baseAddress!)
                }
                out["status"] = String(format: "0x%08x", UInt32(bitPattern: result.status))
                out["transferStatus"] = String(format: "0x%08x", UInt32(bitPattern: result.transferStatus))
                out["closeStatus"] = String(format: "0x%08x", UInt32(bitPattern: result.closeStatus))
                out["bytesTransferred"] = result.bytesTransferred
                out["visualResult"] = "requires_physical_confirmation"
                emit(out)
                exit(result.status == kIOReturnSuccess ? 0 : 1)
            } else { emit(out) }
        } catch {
            emit(["error": String(describing: error)]); exit(2)
        }
    }
}
