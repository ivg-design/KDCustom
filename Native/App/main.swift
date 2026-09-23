import AppKit
import Foundation
import IOKit
import IOKit.hid
import ApplicationServices
import ServiceManagement
import CoreBluetooth

// A deliberately device-scoped probe. No global keyboard tap or key injection.
let repoPath = Bundle.main.object(forInfoDictionaryKey: "ProbeRepositoryPath") as? String
    ?? FileManager.default.currentDirectoryPath

struct CaptureStep {
    let id: String
    let title: String
    let instruction: String
}

let steps: [CaptureStep] = (1...8).map {
    CaptureStep(id: "button_\($0)", title: "Button \($0) of 8",
        instruction: "Press and release button \($0) twice. Number the four buttons along one side from the dial outward as 1–4, then the other side from the dial outward as 5–8. Click Next when done.")
} + [
    CaptureStep(id: "inner_cw", title: "Inner dial · clockwise", instruction: "Turn only the INNER dial clockwise by three slow clicks, then one faster turn. Click Next when done."),
    CaptureStep(id: "inner_ccw", title: "Inner dial · anticlockwise", instruction: "Turn only the INNER dial anticlockwise by three slow clicks, then one faster turn. Click Next when done."),
    CaptureStep(id: "outer_cw", title: "Outer dial · clockwise", instruction: "Turn only the OUTER dial clockwise by three slow clicks, then one faster turn. Click Next when done."),
    CaptureStep(id: "outer_ccw", title: "Outer dial · anticlockwise", instruction: "Turn only the OUTER dial anticlockwise by three slow clicks, then one faster turn. Click Next when done."),
    CaptureStep(id: "group_next", title: "Next group", instruction: "Press the NEXT GROUP button once. Note the group shown on the remote. Click Next when done."),
    CaptureStep(id: "group_previous", title: "Previous group", instruction: "Press the PREVIOUS GROUP button once, returning to the original group. Click Next when done."),
    CaptureStep(id: "hold_and_chord", title: "Hold + another control", instruction: "Hold button 1 for two seconds. While holding it, press button 2 and turn the inner dial one click. Release both. Click Finish when done.")
]

final class SessionLog {
    let directory: URL
    let file: FileHandle
    private(set) var rawCounts: [String: Int] = [:]
    private(set) var signatures: [String: Set<String>] = [:]
    private(set) var events = 0

    init() throws {
        let name = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        directory = URL(fileURLWithPath: repoPath).appendingPathComponent("evidence/native-setup-\(name)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("events.jsonl")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        file = try FileHandle(forWritingTo: url)
    }
    deinit { try? file.close() }

    func append(_ values: [String: Any]) {
        var row = values
        row["utc"] = ISO8601DateFormatter().string(from: Date())
        row["monotonicSeconds"] = ProcessInfo.processInfo.systemUptime
        if let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) {
            try? file.write(contentsOf: data + Data([10]))
        }
        events += 1
        if values["kind"] as? String == "report", let phase = values["phase"] as? String {
            rawCounts[phase, default: 0] += 1
            let signature = "\(values["interface"] ?? "?")/\(values["reportID"] ?? "?")/\(values["hex"] ?? "?")"
            signatures[phase, default: []].insert(signature)
        }
    }

    func status(_ state: [String: Any]) {
        var out = state
        out["sessionDirectory"] = directory.path
        out["countsByPhase"] = rawCounts
        out["uniqueReportsByPhase"] = signatures.mapValues { $0.sorted() }
        out["eventCount"] = events
        if let data = try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: directory.appendingPathComponent("status.json"), options: .atomic)
        }
    }
}

final class DeviceSlot {
    let device: IOHIDDevice
    let id: String
    let name: String
    let transport: String
    let page: Int
    let usage: Int
    let product: Int
    let buffer: UnsafeMutablePointer<UInt8>
    let bufferLength: Int
    weak var owner: Probe?

    init(_ device: IOHIDDevice, owner: Probe) {
        self.device = device
        self.owner = owner
        func int(_ key: String) -> Int { (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue ?? 0 }
        func string(_ key: String) -> String { IOHIDDeviceGetProperty(device, key as CFString) as? String ?? "unknown" }
        name = string(kIOHIDProductKey)
        transport = string(kIOHIDTransportKey)
        page = int(kIOHIDPrimaryUsagePageKey)
        usage = int(kIOHIDPrimaryUsageKey)
        product = int(kIOHIDProductIDKey)
        var registryID: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device), &registryID)
        id = String(format: "%llx/%04x:%04x", registryID, page, usage)
        bufferLength = max(128, int(kIOHIDMaxInputReportSizeKey))
        buffer = .allocate(capacity: bufferLength)
        buffer.initialize(repeating: 0, count: bufferLength)
    }
    deinit { buffer.deallocate() }
    var details: [String: Any] {
        var result: [String: Any] = ["id": id, "name": name, "transport": transport,
            "vendorID": 0x256c, "productID": product, "usagePage": page, "usage": usage]
        if let descriptor = IOHIDDeviceGetProperty(device, kIOHIDReportDescriptorKey as CFString) as? Data {
            result["reportDescriptorHex"] = descriptor.map { String(format: "%02x", $0) }.joined()
        }
        return result
    }
}

final class Probe: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    var statusLabel: NSTextField!
    var phaseLabel: NSTextField!
    var instructions: NSTextField!
    var summaryLabel: NSTextField!
    var nextButton: NSButton!
    var startButton: NSButton!
    var freeButton: NSButton!
    var logView: NSTextView!
    var screenLabel: NSTextField!
    var manager: IOHIDManager?
    var slots: [DeviceSlot] = []
    var retiredSlots: [DeviceSlot] = [] // Keep callback buffers alive until manager closes.
    var session: SessionLog!
    var phaseIndex = -1
    var recording = false
    var freeCapture = false
    var finished = false
    var health = "Not connected"
    var accessAllowed = false
    var lastReport = ""
    var messages: [String] = []
    var bluetooth: K40Bluetooth!

    func applicationDidFinishLaunching(_ notification: Notification) {
        do { session = try SessionLog() }
        catch { NSApp.presentError(error); NSApp.terminate(nil); return }
        makeUI()
        bluetooth = K40Bluetooth()
        bluetooth.onEvent = { [weak self] row in self?.session.append(row) }
        bluetooth.onStatus = { [weak self] message in
            self?.screenLabel.stringValue = message
            self?.addMessage(message)
            self?.updateStatus()
        }
        bluetooth.onInput = { [weak self] bytes, characteristic in
            self?.recordReport(interface: "K40/\(characteristic)", transport: "Bluetooth GATT", page: 0xff00, usage: 1, reportID: 8, bytes: bytes)
        }
        session.append(["kind": "session", "version": "0.3.0", "scope": "K40 USB and Bluetooth controls plus explicit label tests", "exclusive": false])
        openManager()
        checkPermissions()
        NSApp.activate(ignoringOtherApps: true)
    }

    func text(_ string: String, size: CGFloat, bold: Bool = false) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: string)
        field.font = bold ? .systemFont(ofSize: size, weight: .semibold) : .systemFont(ofSize: size)
        field.maximumNumberOfLines = 0
        return field
    }
    func button(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        return b
    }
    func makeUI() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1020, height: 1000),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Keydial Studio · Device setup"
        window.delegate = self
        window.minSize = NSSize(width: 780, height: 640)
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = window.contentView!
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24)
        ])
        stack.addArrangedSubview(text("Keydial Studio · setup", size: 25, bold: true))
        stack.addArrangedSubview(text("This probe reads only the Huion K40. Capture does not remap keys. The explicit Bluetooth controls can enter device control mode and write temporary test labels.", size: 13))
        statusLabel = text("Checking device access…", size: 14, bold: true)
        stack.addArrangedSubview(statusLabel)
        let accessRow = NSStackView(views: [button("Open Input Monitoring", #selector(openPrivacy)), button("Retry device access", #selector(retry)), button("Open evidence folder", #selector(showEvidence))])
        accessRow.spacing = 8
        stack.addArrangedSubview(accessRow)
        let permissions = NSStackView(views: [button("Allow Accessibility", #selector(requestAccessibility)), button("Check permissions", #selector(checkPermissions)), button("Enable launch at login", #selector(enableLogin))])
        permissions.spacing = 8
        stack.addArrangedSubview(permissions)
        phaseLabel = text("Ready for a guided capture", size: 20, bold: true)
        stack.addArrangedSubview(phaseLabel)
        instructions = text("Keep this window in front while testing so existing Huion shortcuts do not change your work. Click Start capture when device access is ready.", size: 15)
        instructions.heightAnchor.constraint(greaterThanOrEqualToConstant: 58).isActive = true
        stack.addArrangedSubview(instructions)
        startButton = button("Start capture", #selector(begin))
        nextButton = button("Next test →", #selector(nextStep))
        nextButton.isEnabled = false
        freeButton = button("Free capture", #selector(beginFree))
        let captureRow = NSStackView(views: [startButton, nextButton, freeButton, button("Stop capture", #selector(stop))])
        captureRow.spacing = 8
        stack.addArrangedSubview(captureRow)
        summaryLabel = text("No reports captured yet.", size: 13)
        stack.addArrangedSubview(summaryLabel)
        screenLabel = text("Screen labels: use the separate k40-screen tool. Transfer logs and physical-display results are stored separately from this input capture.", size: 13)
        stack.addArrangedSubview(screenLabel)
        let bluetoothRow = NSStackView(views: [button("Inspect Bluetooth", #selector(inspectBluetooth)), button("Enable Bluetooth controls", #selector(enableBluetooth)), button("Write BT1–BT8 labels", #selector(writeBluetoothLabels))])
        bluetoothRow.spacing = 8
        stack.addArrangedSubview(bluetoothRow)
        let settings = NSStackView(views: [button("Read battery", #selector(readBattery)), button("Read brightness", #selector(readBrightness)), button("Read sleep", #selector(readSleep)), button("Read rotation", #selector(readRotation))])
        settings.spacing = 8
        stack.addArrangedSubview(settings)
        let display = NSStackView(views: [button("Show group 1", #selector(showGroupOne)), button("Show group 2", #selector(showGroupTwo)), button("Brightness +1", #selector(brightnessUp)), button("Brightness −1", #selector(brightnessDown)), button("Rotate +90°", #selector(rotateOnce))])
        display.spacing = 8
        stack.addArrangedSubview(display)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        logView = NSTextView()
        logView.isEditable = false
        logView.isSelectable = true
        logView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        logView.autoresizingMask = [.width]
        logView.textContainer?.widthTracksTextView = true
        scroll.documentView = logView
        stack.addArrangedSubview(scroll)
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        let footer = text("Evidence: \(session.directory.path)", size: 11)
        footer.textColor = .secondaryLabelColor
        stack.addArrangedSubview(footer)
        let menu = NSMenu()
        let appItem = NSMenuItem()
        menu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Keydial Studio", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        NSApp.mainMenu = menu
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    @objc func openPrivacy() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
    }
    @objc func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    @objc func checkPermissions() {
        let row: [String: Any] = ["kind": "permissions", "accessibility": AXIsProcessTrusted(), "inputMonitoring": IOHIDCheckAccess(kIOHIDRequestTypeListenEvent).rawValue, "bluetooth": CBManager.authorization.rawValue, "loginItem": SMAppService.mainApp.status.rawValue]
        session.append(row)
        addMessage("Accessibility: \(AXIsProcessTrusted() ? "allowed" : "needed") · Bluetooth: \(CBManager.authorization.rawValue) · Login: \(SMAppService.mainApp.status.rawValue)")
        updateStatus()
    }
    @objc func enableLogin() {
        do { try SMAppService.mainApp.register(); addMessage("Launch at login registered") }
        catch { addMessage("Launch at login: \(error.localizedDescription)") }
        checkPermissions()
    }
    @objc func readBattery() { bluetooth.querySetting(0xd1) }
    @objc func readBrightness() { bluetooth.querySetting(0xd9) }
    @objc func readSleep() { bluetooth.querySetting(0xdc) }
    @objc func readRotation() { bluetooth.querySetting(0xde) }
    @objc func brightnessUp() { bluetooth.querySetting(0xd7) }
    @objc func brightnessDown() { bluetooth.querySetting(0xd8) }
    @objc func rotateOnce() { bluetooth.querySetting(0xdd) }
    @objc func showGroupOne() { bluetooth.writeGroupTest(1) }
    @objc func showGroupTwo() { bluetooth.writeGroupTest(2) }
    @objc func showEvidence() { NSWorkspace.shared.open(session.directory) }
    @objc func retry() { closeManager(); openManager() }
    @objc func inspectBluetooth() { bluetooth.inspect() }
    @objc func enableBluetooth() { bluetooth.enterControlMode() }
    @objc func writeBluetoothLabels() { bluetooth.writeTestLabels() }
    @objc func begin() {
        guard accessAllowed && !slots.isEmpty else { addMessage("Capture access is not ready. Grant Input Monitoring, then retry."); return }
        phaseIndex = 0; recording = true; finished = false; freeCapture = false
        startButton.isEnabled = false; nextButton.isEnabled = true
        session.append(["kind": "capture_start"])
        showStep()
    }
    @objc func beginFree() {
        guard accessAllowed && !slots.isEmpty && !recording else { return }
        phaseIndex = -1; recording = true; finished = false; freeCapture = true
        startButton.isEnabled = false; nextButton.isEnabled = false
        phaseLabel.stringValue = "Free capture · all K40 controls"
        instructions.stringValue = "Use any buttons and both dials. Raw reports and decoded controls are saved until you click Stop capture. Device reconnects are logged too."
        session.append(["kind": "capture_start", "mode": "free_capture"])
        updateStatus()
    }
    @objc func nextStep() {
        guard recording else { return }
        session.append(["kind": "phase_complete", "phase": currentPhase])
        phaseIndex += 1
        if phaseIndex >= steps.count {
            finished = true
            stop()
            phaseLabel.stringValue = "Guided capture finished"
            instructions.stringValue = "The raw reports and per-control summary are saved. Tell Codex you are done; we will check distinct control signals and any missing events."
            updateStatus()
        } else { showStep() }
    }
    @objc func stop() {
        if recording { session.append(["kind": "capture_stop", "finished": finished]) }
        recording = false
        nextButton.isEnabled = false
        startButton.isEnabled = !finished
        if !finished { phaseLabel.stringValue = "Capture stopped" }
        updateStatus()
    }
    var currentPhase: String {
        if freeCapture { return "free_capture" }
        return phaseIndex >= 0 && phaseIndex < steps.count ? steps[phaseIndex].id : "idle"
    }
    func showStep() {
        let s = steps[phaseIndex]
        phaseLabel.stringValue = "\(phaseIndex + 1)/\(steps.count) · \(s.title)"
        instructions.stringValue = s.instruction
        nextButton.title = phaseIndex == steps.count - 1 ? "Finish capture" : "Next test →"
        session.append(["kind": "phase_start", "phase": s.id, "instruction": s.instruction])
        updateStatus()
    }
    func addMessage(_ message: String) {
        messages.append(message)
        if messages.count > 120 { messages.removeFirst(messages.count - 120) }
        logView.string = messages.joined(separator: "\n")
        logView.scrollToEndOfDocument(nil)
    }
    func updateStatus() {
        statusLabel.stringValue = health
        if !recording { startButton.isEnabled = accessAllowed && !slots.isEmpty && !finished }
        freeButton.isEnabled = accessAllowed && !slots.isEmpty && !recording
        let total = session.rawCounts.values.reduce(0, +)
        let current = session.rawCounts[currentPhase] ?? 0
        summaryLabel.stringValue = "\(total) raw reports · \(current) in this step · \(session.signatures[currentPhase]?.count ?? 0) distinct packets in this step"
        session.status(["health": health, "recording": recording, "finished": finished,
            "phase": currentPhase, "phaseIndex": phaseIndex, "lastReport": lastReport,
            "interfaces": slots.map { $0.details }, "inputAccessAllowed": accessAllowed,
            "bluetoothReady": bluetooth?.ready ?? false, "bluetoothInitialized": bluetooth?.initialized ?? false,
            "screenStatus": screenLabel.stringValue,
            "screenWrite": "see_ble_write_events_or_USB_CLI_evidence"])
    }
    func openManager() {
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = m
        // Both identities were observed locally. BLE vendor input uses FFE1,
        // while the Bluetooth HID interface exposes ordinary keyboard/mouse reports.
        IOHIDManagerSetDeviceMatchingMultiple(m, [
            [kIOHIDVendorIDKey: 0x256c, kIOHIDProductIDKey: 0x2002],
            [kIOHIDVendorIDKey: 0x256c, kIOHIDProductIDKey: 0x8251]
        ] as CFArray)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(m, { context, result, _, device in
            guard let context = context else { return }
            Unmanaged<Probe>.fromOpaque(context).takeUnretainedValue().deviceAdded(device, result: result)
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(m, { context, _, _, device in
            guard let context = context else { return }
            let p = Unmanaged<Probe>.fromOpaque(context).takeUnretainedValue()
            let removed = p.slots.filter { CFEqual($0.device, device) }
            p.retiredSlots.append(contentsOf: removed)
            p.slots.removeAll { CFEqual($0.device, device) }
            p.session.append(["kind": "device_removed", "interfaces": removed.map { $0.id }])
            p.health = "\(p.slots.count) K40 interfaces connected"
            p.updateStatus()
        }, ctx)
        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let result = IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone))
        accessAllowed = result == kIOReturnSuccess
        let code = String(format: "0x%08x", UInt32(bitPattern: result))
        session.append(["kind": "manager_open", "result": code])
        if result == kIOReturnSuccess { health = "Device access opened · waiting for K40 interfaces" }
        else if result == kIOReturnNotPermitted { health = "Input Monitoring required · enable Keydial Studio, then quit and reopen it" }
        else if result == kIOReturnExclusiveAccess { health = "K40 is busy · another driver has exclusive access" }
        else { health = "Device access failed: \(code)" }
        addMessage(health)
        updateStatus()
    }
    func deviceAdded(_ device: IOHIDDevice, result: IOReturn) {
        guard result == kIOReturnSuccess else { return }
        if slots.contains(where: { CFEqual($0.device, device) }) { return }
        let slot = DeviceSlot(device, owner: self)
        slots.append(slot)
        session.append(["kind": "device_added", "device": slot.details])
        let ctx = Unmanaged.passUnretained(slot).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, slot.buffer, slot.bufferLength, { context, result, _, type, reportID, report, length in
            guard let context = context, result == kIOReturnSuccess, length >= 0 else { return }
            let s = Unmanaged<DeviceSlot>.fromOpaque(context).takeUnretainedValue()
            s.owner?.received(s, type: type, reportID: reportID, bytes: Array(UnsafeBufferPointer(start: report, count: length)))
        }, ctx)
        if accessAllowed { health = "\(slots.count) K40 interfaces connected · passive capture ready" }
        addMessage("Connected \(slot.transport) \(slot.id) \(slot.name)")
        updateStatus()
    }
    func received(_ slot: DeviceSlot, type: IOHIDReportType, reportID: UInt32, bytes: [UInt8]) {
        recordReport(interface: slot.id, transport: slot.transport, page: slot.page, usage: slot.usage, reportID: reportID, bytes: bytes, reportType: type.rawValue)
    }
    func recordReport(interface: String, transport: String, page: Int, usage: Int, reportID: UInt32, bytes: [UInt8], reportType: UInt32 = 0) {
        guard recording else { return }
        let hex = bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
        var decoded = "unclassified"
        if page == 0xff00, case .input(let frame) = K40Decode.parse(reportID: reportID, bytes: bytes) {
            switch frame.payload {
            case .controls(let mask):
                let buttons = frame.observedPressedButtons ?? []
                let groups = (frame.observedSetButtons ?? []).map { $0 == .next ? "next" : "previous" }
                decoded = "buttons=\(buttons) groupButtons=\(groups) mask=\(String(format: "0x%08x", mask))"
            case .dial(let dial, let direction):
                let name = dial == 1 ? "inner" : (dial == 2 ? "outer" : "unknown(\(dial))")
                decoded = "dial=\(name) direction=\(direction == 1 ? "CW" : (direction == 2 ? "CCW" : "unknown(\(direction))"))"
            case .unknown(let opcode): decoded = "unknown opcode \(String(opcode, radix: 16))"
            }
        }
        session.append(["kind": "report", "phase": currentPhase, "interface": interface, "decoded": decoded,
            "transport": transport, "usagePage": page, "usage": usage,
            "reportID": reportID, "reportType": reportType, "length": bytes.count, "hex": hex])
        lastReport = "\(currentPhase) · \(decoded) · \(hex)"
        addMessage(lastReport)
        updateStatus()
    }
    func closeManager() {
        guard let m = manager else { return }
        for slot in slots + retiredSlots {
            IOHIDDeviceRegisterInputReportCallback(slot.device, slot.buffer, slot.bufferLength, nil, nil)
        }
        IOHIDManagerUnscheduleFromRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerClose(m, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = nil; slots.removeAll(); retiredSlots.removeAll(); accessAllowed = false
    }
    func windowWillClose(_ notification: Notification) { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) {
        stop()
        bluetooth?.close()
        closeManager()
        session.append(["kind": "app_exit"])
        updateStatus()
    }
}

final class ProbeApplication: NSApplication {
    override func sendEvent(_ event: NSEvent) {
        // Existing Huion-generated shortcuts must not activate UI or modify other apps
        // while the probe window is frontmost. The raw HID callbacks still receive data.
        if keyWindow != nil && [.keyDown, .keyUp, .flagsChanged].contains(event.type) {
            if event.type == .keyDown && event.modifierFlags.contains(.command)
                && event.charactersIgnoringModifiers == "q" { terminate(nil) }
            return
        }
        super.sendEvent(event)
    }
}

let app = ProbeApplication.shared
let delegate = Probe()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
