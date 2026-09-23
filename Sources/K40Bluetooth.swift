import Foundation
import CoreBluetooth

// Only the observed K40 name and vendor service are selected. The standard
// Bluetooth keyboard interface does not expose the independent vendor controls.
final class K40Bluetooth: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var onEvent: ([String: Any]) -> Void = { _ in }
    var onStatus: (String) -> Void = { _ in }
    var onInput: ([UInt8], String) -> Void = { _, _ in }
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var inputCharacteristic: CBCharacteristic?
    private var io: CBCharacteristic?
    private var scanTimeout: Timer?
    private var commandTimeout: Timer?
    private var writeTimeout: Timer?
    private var connectionTimeout: Timer?
    private var expectedCommand: UInt8?
    private var sentCommand: UInt8?
    private var queue: [(Data, String)] = []
    private var waitingForResponse = false
    private var pumping = false
    private var generation = UUID()
    private(set) var ready = false
    private(set) var initialized = false
    private let serviceID = CBUUID(string: "FFE0")
    private let inputID = CBUUID(string: "FFE1")
    private let ioID = CBUUID(string: "FFE2")

    private func status(_ message: String) {
        onStatus(message); onEvent(["kind": "ble_status", "message": message])
    }
    func inspect() {
        guard peripheral == nil else { status("Bluetooth device already selected"); return }
        if central == nil {
            status("Starting Bluetooth access · macOS may require permission")
            central = CBCentralManager(delegate: self, queue: .main)
        }
        else if central?.state == .poweredOn { findDevice() }
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        onEvent(["kind": "ble_manager", "state": central.state.rawValue, "authorization": CBManager.authorization.rawValue])
        if central.state == .poweredOn { findDevice() }
        else { status("Bluetooth manager state \(central.state.rawValue); authorization \(CBManager.authorization.rawValue)") }
    }
    private func findDevice() {
        guard let central = central, peripheral == nil else { return }
        let connected = central.retrieveConnectedPeripherals(withServices: [serviceID])
            .filter { $0.name == "Keydial Remote-365" }
        if let target = connected.first { select(target); return }
        status("Looking for Keydial Remote-365 on its vendor Bluetooth service…")
        central.scanForPeripherals(withServices: [serviceID], options: nil)
        scanTimeout?.invalidate()
        scanTimeout = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in
            guard let self = self, self.peripheral == nil else { return }
            self.central?.stopScan(); self.status("K40 vendor service not found; no other device selected")
        }
    }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
        guard name == "Keydial Remote-365" else { return }
        select(peripheral)
    }
    private func select(_ device: CBPeripheral) {
        guard peripheral == nil else { return }
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
        status("K40 connected · inspecting vendor service")
        peripheral.discoverServices([serviceID])
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        resetLink(); status("Bluetooth connection failed: \(error?.localizedDescription ?? "unknown error")")
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard self.peripheral?.identifier == peripheral.identifier else { return }
        resetLink(); status("K40 Bluetooth disconnected\(error.map { ": \($0.localizedDescription)" } ?? "")")
    }
    private func failLink(_ message: String) {
        if let peripheral = peripheral { central?.cancelPeripheralConnection(peripheral) }
        resetLink(); status(message)
    }
    private func resetLink() {
        peripheral = nil; inputCharacteristic = nil; io = nil; ready = false; initialized = false
        expectedCommand = nil; sentCommand = nil; commandTimeout?.invalidate(); writeTimeout?.invalidate()
        connectionTimeout?.invalidate(); queue.removeAll(); waitingForResponse = false; pumping = false; generation = UUID()
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error { failLink("Service discovery failed: \(error.localizedDescription)"); return }
        guard let service = peripheral.services?.first(where: { $0.uuid == serviceID }) else {
            failLink("K40 vendor service FFE0 unavailable"); return
        }
        peripheral.discoverCharacteristics([inputID, ioID], for: service)
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
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
        onEvent(["kind": "ble_notify_state", "uuid": characteristic.uuid.uuidString, "enabled": characteristic.isNotifying,
                 "error": error?.localizedDescription ?? ""])
        ready = inputCharacteristic?.isNotifying == true && io?.isNotifying == true
        if ready { connectionTimeout?.invalidate(); status("Bluetooth ready · enable controls to run the K40 startup sequence") }
        else if let error = error { failLink("Bluetooth notifications failed: \(error.localizedDescription)") }
    }
    func enterControlMode() {
        guard ready, expectedCommand == nil, queue.isEmpty, !waitingForResponse else {
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
            self.expectedCommand = nil; self.sentCommand = nil; self.queue.removeAll()
            self.status("Bluetooth startup response timed out for \(String(index, radix: 16))")
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
        guard known.contains(index), ready, initialized, expectedCommand == nil, queue.isEmpty, !waitingForResponse else { status("Device is not ready for this setting command"); return }
        request(index)
    }
    func writeGroupTest(_ group: Int) {
        guard (1...6).contains(group), ready, initialized, expectedCommand == nil, queue.isEmpty, !waitingForResponse else { status("Device is busy; retry group test when ready"); return }
        do {
            enqueue(try K40LabelPacket.group(group, text: "GROUP \(group)"), label: "group_name_\(group)")
            for button in 1...8 {
                let slot = K40ButtonLayout.wireSlot(forPhysicalButton: button)!
                enqueue(try K40LabelPacket.key(slot, group: group, text: "G\(group) K\(button)"), label: "group_\(group)_key_\(button)")
            }
        } catch { status("Group label encoding failed: \(error)") }
    }
    private func enqueue(_ bytes: [UInt8], label: String) {
        queue.append((Data(bytes), label)); pump()
    }
    private func pump() {
        guard !pumping, !waitingForResponse, !queue.isEmpty, let peripheral = peripheral, let io = io, ready else { return }
        let type: CBCharacteristicWriteType = io.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        guard type == .withoutResponse || io.properties.contains(.write) else { status("FFE2 has no supported write property"); return }
        if type == .withoutResponse && !peripheral.canSendWriteWithoutResponse { return }
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
                self.waitingForResponse = false; self.queue.removeAll(); self.status("Bluetooth write acknowledgement timed out")
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [weak self] in
            guard let self = self, self.generation == writeGeneration else { return }
            self.pumping = false; self.pump()
        }
    }
    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) { pump() }
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        waitingForResponse = false
        writeTimeout?.invalidate()
        onEvent(["kind": "ble_write_response", "uuid": characteristic.uuid.uuidString, "error": error?.localizedDescription ?? ""])
        if let error = error { queue.removeAll(); status("Bluetooth write failed: \(error.localizedDescription)") }
        else { pump() }
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value, error == nil else {
            status("Bluetooth notification error: \(error?.localizedDescription ?? "no data")"); return
        }
        let bytes = [UInt8](data)
        onEvent(["kind": "ble_notification", "uuid": characteristic.uuid.uuidString,
                 "hex": bytes.map { String(format: "%02x", $0) }.joined(separator: " ")])
        // Live K40 firmware returns C9 on FFE2. Route by the fresh command key,
        // rather than assuming a characteristic alone determines packet type.
        if let index = expectedCommand, bytes.count >= 2, bytes[1] == index {
            // The vendor response key is byte 1. Ignore unrelated notifications
            // and short ACKs rather than treating the first notification as data.
            guard sentCommand == index, bytes.count >= (index == 0xc9 || index == 0xc8 ? 18 : 3), bytes[1] == index else { return }
            if index == 0xc9 && bytes.count <= 18 { return }
            expectedCommand = nil; commandTimeout?.invalidate()
            if index == 0xc9 {
                let ascii = String(bytes: bytes.filter { $0 >= 32 && $0 < 127 }, encoding: .ascii) ?? ""
                guard ascii.uppercased().contains("T221") else { status("Bluetooth C9 response did not identify T221; startup stopped"); return }
                request(0xc8)
            } else if index == 0xc8 {
                guard !bytes.isEmpty else { status("Empty Bluetooth C8 response"); return }
                initialized = true; status("Bluetooth controls enabled · capture inputs or write BT1–BT8")
            } else {
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
        scanTimeout?.invalidate(); commandTimeout?.invalidate(); writeTimeout?.invalidate(); connectionTimeout?.invalidate(); central?.stopScan()
        queue.removeAll(); ready = false; initialized = false
        if let peripheral = peripheral { central?.cancelPeripheralConnection(peripheral) }
    }
}
