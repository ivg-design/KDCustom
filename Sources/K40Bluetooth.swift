import Foundation
import CoreBluetooth

// Only the observed K40 name and vendor service are selected. The standard
// Bluetooth keyboard interface does not expose the independent vendor controls.
final class K40Bluetooth: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var onEvent: ([String: Any]) -> Void = { _ in }
    var onStatus: (String) -> Void = { _ in }
    var onInput: ([UInt8], String) -> Void = { _, _ in }
    var onConnectionChange: (Bool) -> Void = { _ in }
    var onControlReady: (Bool) -> Void = { _ in }
    var onSettingResponse: (UInt8, [UInt8]) -> Void = { _, _ in }
    var onFailure: (String) -> Void = { _ in }
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var pendingDisconnect: CBPeripheral?
    private var inputCharacteristic: CBCharacteristic?
    private var io: CBCharacteristic?
    private var scanTimeout: Timer?
    private var commandTimeout: Timer?
    private var writeTimeout: Timer?
    private var flowControlTimeout: Timer?
    private var connectionTimeout: Timer?
    private var pendingDisconnectTimeout: Timer?
    private var expectedCommand: UInt8?
    private var sentCommand: UInt8?
    private var queue: [(Data, String, TimeInterval)] = []
    private var waitingForResponse = false
    private var pumping = false
    private var generation = UUID()
    private var wantsConnection = false
    private var timedOutCommands: Set<UInt8> = []
    private(set) var ready = false
    private(set) var initialized = false
    private let serviceID = CBUUID(string: "FFE0")
    private let inputID = CBUUID(string: "FFE1")
    private let ioID = CBUUID(string: "FFE2")

    private func status(_ message: String) {
        onStatus(message); onEvent(["kind": "ble_status", "message": message])
    }
    func inspect() {
        wantsConnection = true
        guard pendingDisconnect == nil else {
            status("Waiting for the previous Bluetooth connection to close")
            return
        }
        guard peripheral == nil else { status("Bluetooth device already selected"); return }
        if central == nil {
            status("Starting Bluetooth access · macOS may require permission")
            central = CBCentralManager(delegate: self, queue: .main)
        }
        else if central?.state == .poweredOn { findDevice() }
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard self.central === central else { return }
        onEvent(["kind": "ble_manager", "state": central.state.rawValue, "authorization": CBManager.authorization.rawValue])
        if central.state == .poweredOn {
            if wantsConnection { findDevice() }
            return
        }
        let message = "Bluetooth manager state \(central.state.rawValue); authorization \(CBManager.authorization.rawValue)"
        if central.state == .poweredOff || central.state == .unauthorized || central.state == .unsupported {
            let wasConnecting = wantsConnection
            wantsConnection = false
            central.stopScan()
            scanTimeout?.invalidate()
            if peripheral != nil { resetLink() }
            status(message)
            if wasConnecting { onFailure(message) }
        } else {
            // Unknown/resetting can be transient while CoreBluetooth starts.
            status(message)
        }
    }
    private func findDevice() {
        guard wantsConnection, pendingDisconnect == nil,
              let central = central, peripheral == nil else { return }
        let connected = central.retrieveConnectedPeripherals(withServices: [serviceID])
            .filter { $0.name == "Keydial Remote-365" }
        if let target = connected.first { select(target); return }
        status("Looking for Keydial Remote-365 on its vendor Bluetooth service…")
        central.scanForPeripherals(withServices: [serviceID], options: nil)
        scanTimeout?.invalidate()
        scanTimeout = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in
            guard let self = self, self.wantsConnection, self.peripheral == nil else { return }
            self.central?.stopScan()
            self.wantsConnection = false
            let message = "K40 vendor service not found; no other device selected"
            self.status(message); self.onFailure(message)
        }
    }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard self.central === central else { return }
        let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
        guard wantsConnection, name == "Keydial Remote-365" else { return }
        select(peripheral)
    }
    private func select(_ device: CBPeripheral) {
        guard wantsConnection, pendingDisconnect == nil, peripheral == nil else { return }
        central?.stopScan(); scanTimeout?.invalidate()
        peripheral = device; device.delegate = self
        status("Connecting to K40 vendor service…")
        central?.connect(device, options: nil)
        connectionTimeout?.invalidate()
        connectionTimeout = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in
            guard let self = self, !self.ready else { return }
            self.failLink("Bluetooth connection or discovery timed out; Inspect Bluetooth can retry")
        }
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard self.central === central, isCurrent(peripheral) else { return }
        status("K40 connected · inspecting vendor service")
        peripheral.discoverServices([serviceID])
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard self.central === central, isCurrent(peripheral) else { return }
        wantsConnection = false
        resetLink()
        let message = "Bluetooth connection failed: \(error?.localizedDescription ?? "unknown error")"
        status(message); onFailure(message)
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard self.central === central else { return }
        if pendingDisconnect === peripheral {
            finishPendingDisconnect(peripheral)
            return
        }
        guard isCurrent(peripheral) else { return }
        wantsConnection = false
        resetLink()
        let message = "K40 Bluetooth disconnected\(error.map { ": \($0.localizedDescription)" } ?? "")"
        status(message); onFailure(message)
    }
    private func failLink(_ message: String) {
        wantsConnection = false
        if let peripheral = peripheral { beginDisconnect(peripheral) }
        resetLink(); status(message); onFailure(message)
    }

    private func beginDisconnect(_ device: CBPeripheral) {
        pendingDisconnect = device
        central?.cancelPeripheralConnection(device)
        pendingDisconnectTimeout?.invalidate()
        pendingDisconnectTimeout = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self, weak device] _ in
            guard let self, let device, self.pendingDisconnect === device else { return }
            self.finishPendingDisconnect(device)
        }
    }
    private func finishPendingDisconnect(_ device: CBPeripheral) {
        guard pendingDisconnect === device else { return }
        pendingDisconnect = nil
        pendingDisconnectTimeout?.invalidate(); pendingDisconnectTimeout = nil
        // A late callback from the old central cannot reset a new link to the
        // same peripheral UUID. Detach its peripheral delegate as well.
        device.delegate = nil
        central?.stopScan()
        central?.delegate = nil
        central = nil
        if wantsConnection { inspect() }
    }
    private func resetLink() {
        let wasReady = ready
        let wasInitialized = initialized
        peripheral = nil; inputCharacteristic = nil; io = nil; ready = false; initialized = false
        expectedCommand = nil; sentCommand = nil; commandTimeout?.invalidate(); writeTimeout?.invalidate()
        flowControlTimeout?.invalidate(); flowControlTimeout = nil
        connectionTimeout?.invalidate(); queue.removeAll(); waitingForResponse = false; pumping = false; generation = UUID()
        timedOutCommands.removeAll()
        if wasInitialized { onControlReady(false) }
        if wasReady { onConnectionChange(false) }
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard isCurrent(peripheral) else { return }
        if let error = error { failLink("Service discovery failed: \(error.localizedDescription)"); return }
        guard let service = peripheral.services?.first(where: { $0.uuid == serviceID }) else {
            failLink("K40 vendor service FFE0 unavailable"); return
        }
        peripheral.discoverCharacteristics([inputID, ioID], for: service)
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard isCurrent(peripheral) else { return }
        if let error = error { failLink("Characteristic discovery failed: \(error.localizedDescription)"); return }
        for c in service.characteristics ?? [] {
            onEvent(["kind": "ble_characteristic", "uuid": c.uuid.uuidString, "properties": c.properties.rawValue,
                     "maximumWriteWithResponse": peripheral.maximumWriteValueLength(for: .withResponse),
                     "maximumWriteWithoutResponse": peripheral.maximumWriteValueLength(for: .withoutResponse)])
            if c.uuid == inputID { inputCharacteristic = c }
            if c.uuid == ioID { io = c }
            if c.uuid == inputID || c.uuid == ioID { peripheral.setNotifyValue(true, for: c) }
        }
        if inputCharacteristic == nil || io == nil { failLink("K40 FFE1/FFE2 characteristics missing") }
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard isCurrent(peripheral) else { return }
        onEvent(["kind": "ble_notify_state", "uuid": characteristic.uuid.uuidString, "enabled": characteristic.isNotifying,
                 "error": error?.localizedDescription ?? ""])
        if let error {
            failLink("Bluetooth notifications failed: \(error.localizedDescription)")
            return
        }
        if (characteristic.uuid == inputID || characteristic.uuid == ioID),
           !characteristic.isNotifying {
            failLink("Bluetooth vendor notifications were disabled")
            return
        }
        let wasReady = ready
        ready = inputCharacteristic?.isNotifying == true && io?.isNotifying == true
        if wasReady && !ready {
            failLink("Bluetooth vendor notifications are no longer ready")
            return
        }
        if ready && !wasReady {
            connectionTimeout?.invalidate()
            onConnectionChange(true)
            status("Bluetooth ready · enable controls to run the K40 startup sequence")
        }
    }
    func enterControlMode() {
        guard ready, expectedCommand == nil, queue.isEmpty, !waitingForResponse, !pumping else {
            status("Bluetooth is not ready for startup"); return
        }
        initialized = false
        request(0xc9)
    }
    private func request(_ index: UInt8) {
        expectedCommand = index
        sentCommand = nil
        commandTimeout?.invalidate()
        commandTimeout = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
            guard let self = self, self.expectedCommand == index else { return }
            self.expectedCommand = nil; self.sentCommand = nil
            let message = "Bluetooth command response timed out for \(String(index, radix: 16))"
            self.status(message)
            if index == 0xc9 || index == 0xc8 {
                self.queue.removeAll()
                self.onFailure(message)
            } else {
                // Replies carry only the command index, with no request nonce.
                // Avoid matching a late reply to another request for this index.
                self.timedOutCommands.insert(index)
                self.pump()
            }
        }
        enqueue([0xcd, index, 0, 0, 0, 0, 0, 0], label: "startup_\(String(index, radix: 16))")
    }
    func writeTestLabels() {
        guard ready, initialized, expectedCommand == nil, queue.isEmpty, !waitingForResponse else {
            status("Enable Bluetooth controls before the label test"); return
        }
        do {
            for button in 1...8 {
                let slot = K40ButtonLayout.wireSlot(forPhysicalButton: button)!
                enqueue(try K40LabelPacket.key(slot, group: 1, text: "BT\(button)"), label: "label_BT\(button)_wireSlot\(slot)")
            }
        } catch { status("Label encoding failed: \(error)") }
    }
    func querySetting(_ index: UInt8) {
        let known: Set<UInt8> = [0xd1, 0xd7, 0xd8, 0xd9, 0xda, 0xdb, 0xdc, 0xdd, 0xde, 0xe8]
        guard known.contains(index), !timedOutCommands.contains(index), ready, initialized,
              expectedCommand == nil, queue.isEmpty, !waitingForResponse, !pumping else {
            status("Device is not ready for this setting command"); return
        }
        request(index)
    }
    /// Production API: only observed setting reads and one-step adjustments.
    @discardableResult
    func sendKnownSetting(_ index: UInt8) -> Bool {
        let known: Set<UInt8> = [0xd1, 0xd7, 0xd8, 0xd9, 0xda, 0xdb, 0xdc, 0xdd, 0xde]
        guard known.contains(index), !timedOutCommands.contains(index),
              ready, initialized, expectedCommand == nil,
              queue.isEmpty, !waitingForResponse, !pumping else { return false }
        if [UInt8(0xd7), 0xd8, 0xda, 0xdb, 0xdd].contains(index) {
            // Step commands change the device but need no readback value.
            // Some firmware sends no reply, so do not occupy the reply slot.
            enqueue([0xcd, index, 0, 0, 0, 0, 0, 0], label: "setting_step_\(String(index, radix: 16))")
        } else {
            request(index)
        }
        return true
    }
    /// Accepts only the existing 64-byte K40 label packet forms.
    @discardableResult
    func sendLabelPacket(_ bytes: [UInt8], delayAfter: TimeInterval, label: String) -> Bool {
        guard ready, initialized, Self.isKnownLabelPacket(bytes),
              (0.2...1.0).contains(delayAfter) else { return false }
        enqueue(bytes, label: "prod_label_\(label)", delayAfter: delayAfter)
        return true
    }
    func cancelQueuedLabels() {
        queue.removeAll { $0.1.hasPrefix("prod_label_") }
    }
    private static func isKnownLabelPacket(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 64, bytes[0] == 0x18, bytes[2] == 0x05,
              bytes[3] == 0x03, (1...6).contains(bytes[4]) else { return false }
        let start: Int
        let count: Int
        if bytes[1] == 0x01 {
            start = 6
            count = Int(bytes[5])
            guard count <= 58 else { return false }
        } else if bytes[1] == 0x02, bytes[5] == 0,
                  (1...8).contains(bytes[6]) {
            start = 8
            count = Int(bytes[7])
            guard count <= 56 else { return false }
        } else {
            return false
        }
        return count.isMultiple(of: 2) &&
            bytes[(start + count)...].allSatisfy { $0 == 0 }
    }
    func writeGroupTest(_ group: Int) {
        guard (1...6).contains(group), ready, initialized, expectedCommand == nil,
              queue.isEmpty, !waitingForResponse, !pumping else {
            status("Device is busy; retry group test when ready"); return
        }
        do {
            enqueue(try K40LabelPacket.group(group, text: "GROUP \(group)"), label: "group_name_\(group)")
            for button in 1...8 {
                let slot = K40ButtonLayout.wireSlot(forPhysicalButton: button)!
                enqueue(try K40LabelPacket.key(slot, group: group, text: "G\(group) K\(button)"), label: "group_\(group)_key_\(button)")
            }
        } catch { status("Group label encoding failed: \(error)") }
    }
    private func enqueue(_ bytes: [UInt8], label: String, delayAfter: TimeInterval = 0.22) {
        queue.append((Data(bytes), label, delayAfter)); pump()
    }
    private func pump() {
        guard !pumping, !waitingForResponse, !queue.isEmpty, let peripheral = peripheral, let io = io, ready else { return }
        if expectedCommand != nil && !queue[0].1.hasPrefix("startup_") { return }
        let type: CBCharacteristicWriteType = io.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        guard type == .withoutResponse || io.properties.contains(.write) else { status("FFE2 has no supported write property"); return }
        if type == .withoutResponse && !peripheral.canSendWriteWithoutResponse {
            if flowControlTimeout == nil {
                let blockedGeneration = generation
                flowControlTimeout = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
                    guard let self, self.generation == blockedGeneration,
                          !self.queue.isEmpty else { return }
                    self.failLink("Bluetooth write flow control timed out")
                }
            }
            return
        }
        flowControlTimeout?.invalidate(); flowControlTimeout = nil
        let item = queue.removeFirst()
        guard item.0.count <= peripheral.maximumWriteValueLength(for: type) else {
            queue.removeAll(); status("Bluetooth write capacity is smaller than the known packet; no fragmentation attempted"); return
        }
        pumping = true
        waitingForResponse = type == .withResponse
        if item.0.count == 8, item.0.first == 0xcd { sentCommand = item.0[1] }
        onEvent(["kind": "ble_write_queued", "label": item.1, "writeType": type.rawValue,
                 "hex": item.0.map { String(format: "%02x", $0) }.joined(separator: " ")])
        peripheral.writeValue(item.0, for: io, type: type)
        let writeGeneration = generation
        if waitingForResponse {
            writeTimeout?.invalidate()
            writeTimeout = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
                guard let self = self, self.generation == writeGeneration, self.waitingForResponse else { return }
                self.failLink("Bluetooth write acknowledgement timed out")
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + item.2) { [weak self] in
            guard let self = self, self.generation == writeGeneration else { return }
            self.pumping = false; self.pump()
        }
    }
    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        guard isCurrent(peripheral) else { return }
        pump()
    }
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard isCurrent(peripheral), characteristic.uuid == ioID else { return }
        waitingForResponse = false
        writeTimeout?.invalidate()
        onEvent(["kind": "ble_write_response", "uuid": characteristic.uuid.uuidString, "error": error?.localizedDescription ?? ""])
        if let error = error {
            let message = "Bluetooth write failed: \(error.localizedDescription)"
            failLink(message)
        }
        else { pump() }
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard isCurrent(peripheral) else { return }
        guard let data = characteristic.value, error == nil else {
            status("Bluetooth notification error: \(error?.localizedDescription ?? "no data")"); return
        }
        let bytes = [UInt8](data)
        onEvent(["kind": "ble_notification", "uuid": characteristic.uuid.uuidString,
                 "hex": bytes.map { String(format: "%02x", $0) }.joined(separator: " ")])
        // Live K40 firmware returns C9 on FFE2. Route by the fresh command key,
        // rather than assuming a characteristic alone determines packet type.
        if characteristic.uuid == ioID, let index = expectedCommand,
           Self.matchesCommandReply(bytes, index: index) {
            // The vendor response key is byte 1. Ignore unrelated notifications
            // and short ACKs rather than treating the first notification as data.
            guard sentCommand == index else { return }
            expectedCommand = nil; commandTimeout?.invalidate()
            if index == 0xc9 {
                let ascii = String(bytes: bytes.filter { $0 >= 32 && $0 < 127 }, encoding: .ascii) ?? ""
                guard ascii.uppercased().contains("T221") else {
                    let message = "Bluetooth C9 response did not identify T221; startup stopped"
                    status(message); onFailure(message); return
                }
                request(0xc8)
            } else if index == 0xc8 {
                guard !bytes.isEmpty else { status("Empty Bluetooth C8 response"); return }
                initialized = true; onControlReady(true)
                status("Bluetooth controls enabled · capture inputs or write BT1–BT8")
            } else {
                onSettingResponse(index, bytes)
                onEvent(["kind": "ble_setting_response", "command": Int(index), "hex": bytes.map { String(format: "%02x", $0) }.joined(separator: " ")])
                status("Setting \(String(index, radix: 16)): \(bytes.map { String(format: "%02x", $0) }.joined(separator: " "))")
            }
        } else if characteristic.uuid == inputID, let input = K40Decode.normalizeBluetoothReport(bytes) {
            // Exact framing used by the installed driver's BLE input path.
            // The original notification remains in the log before normalization.
            if input[1] != 0xd1 { onInput(input, characteristic.uuid.uuidString) }
        }
    }
    func close() {
        wantsConnection = false
        scanTimeout?.invalidate(); commandTimeout?.invalidate(); writeTimeout?.invalidate(); connectionTimeout?.invalidate(); central?.stopScan()
        if let peripheral = peripheral { beginDisconnect(peripheral) }
        resetLink()
    }

    private func isCurrent(_ candidate: CBPeripheral) -> Bool {
        wantsConnection && peripheral === candidate
    }

    static func matchesCommandReply(_ bytes: [UInt8], index: UInt8) -> Bool {
        guard bytes.count >= 3, Int(bytes[0]) == bytes.count, bytes[1] == index else {
            return false
        }
        switch index {
        case 0xc9: return bytes.count >= 19
        case 0xc8: return bytes.count >= 20
        default: return true
        }
    }
}
