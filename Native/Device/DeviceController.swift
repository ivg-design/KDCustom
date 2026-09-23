import CoreBluetooth
import Foundation
import IOKit.hid

struct K40ControlEvent: Equatable {
    let control: ControlID
    let pressed: Bool
}

struct K40DisplayWrite: Equatable {
    let bytes: [UInt8]
    let delayAfter: TimeInterval
}

enum K40LabelPlan {
    static func make(group: KeydialGroup, slot: Int) throws -> [K40DisplayWrite] {
        var writes = [
            K40DisplayWrite(bytes: try K40LabelPacket.group(slot, text: group.name),
                            delayAfter: 1.0)
        ]
        let controls: [ControlID] = [.key1, .key2, .key3, .key4,
                                     .key5, .key6, .key7, .key8]
        for (index, control) in controls.enumerated() {
            let physical = index + 1
            let wireSlot = K40ButtonLayout.wireSlot(forPhysicalButton: physical)!
            writes.append(K40DisplayWrite(
                bytes: try K40LabelPacket.key(wireSlot, group: slot,
                                              text: group.binding(for: control)?.label ?? ""),
                delayAfter: 0.2
            ))
        }
        return writes
    }
}

/// Turns observed report-8 snapshots into edges. Unknown mask bits and packet
/// forms never generate controls. Each F1 report is one dial pulse.
struct K40ControlEdges {
    private(set) var held: Set<ControlID> = []

    mutating func consume(reportID: UInt32, bytes: [UInt8]) -> [K40ControlEvent] {
        guard case let .input(frame) = K40Decode.parse(reportID: reportID, bytes: bytes) else {
            return []
        }
        switch frame.payload {
        case let .controls(mask):
            var next: Set<ControlID> = []
            let keys: [ControlID] = [.key1, .key2, .key3, .key4,
                                     .key5, .key6, .key7, .key8]
            for (index, bit) in K40ButtonLayout.masksInRowOrder.enumerated()
                where mask & bit != 0 {
                next.insert(keys[index])
            }
            if mask & 0x1000 != 0 { next.insert(.setPrevious) }
            if mask & 0x2000 != 0 { next.insert(.setNext) }
            let order: [ControlID] = keys + [.setPrevious, .setNext]
            let releases = order.filter { held.contains($0) && !next.contains($0) }
                .map { K40ControlEvent(control: $0, pressed: false) }
            let presses = order.filter { next.contains($0) && !held.contains($0) }
                .map { K40ControlEvent(control: $0, pressed: true) }
            held = next
            return releases + presses
        case let .dial(rawDialID, rawDirection):
            let control: ControlID
            switch (rawDialID, rawDirection) {
            case (1, 1): control = .dial1CW    // inner, firmware dial 1
            case (1, 2): control = .dial1CCW
            case (2, 1): control = .dial2CW    // outer, firmware dial 2
            case (2, 2): control = .dial2CCW
            default: return []
            }
            return [K40ControlEvent(control: control, pressed: true),
                    K40ControlEvent(control: control, pressed: false)]
        case .unknown:
            return []
        }
    }

    mutating func releaseAll() -> [K40ControlEvent] {
        let order: [ControlID] = [.key1, .key2, .key3, .key4, .key5, .key6, .key7, .key8,
                                  .setPrevious, .setNext]
        let releases = order.filter { held.contains($0) }
            .map { K40ControlEvent(control: $0, pressed: false) }
        held.removeAll()
        return releases
    }
}

private final class K40USBInputSlot {
    let device: IOHIDDevice
    let registryID: UInt64
    let locationID: UInt32
    let buffer: UnsafeMutablePointer<UInt8>
    let bufferLength: Int
    var callbackContext: UnsafeMutableRawPointer?
    weak var owner: DeviceController?

    init?(device: IOHIDDevice, owner: DeviceController) {
        self.device = device
        self.owner = owner
        var identifier: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device), &identifier)
        registryID = identifier
        locationID = (IOHIDDeviceGetProperty(device, kIOHIDLocationIDKey as CFString) as? NSNumber)?
            .uint32Value ?? 0
        let reportedSize = (IOHIDDeviceGetProperty(device, kIOHIDMaxInputReportSizeKey as CFString) as? NSNumber)?
            .intValue ?? 0
        bufferLength = max(128, reportedSize)
        guard let allocated = K40HIDCallbackRegistry.allocateReportBuffer(length: bufferLength) else {
            return nil
        }
        buffer = allocated
    }
}

final class K40HIDCallbackContext {
    weak var owner: DeviceController?
    let generation: Int

    init(owner: DeviceController, generation: Int) {
        self.owner = owner
        self.generation = generation
    }
}

/// IOKit receives an opaque integer token, never an unretained Swift object.
/// Revoking a token makes an already-queued callback harmless. HID may still
/// write to its preallocated report buffer after unregistering a callback, so
/// those buffers remain valid for the process lifetime. The fixed cap bounds
/// this storage to 512 KiB across repeated reconnects.
enum K40HIDCallbackRegistry {
    private static var nextToken: UInt = 1
    private static var active: [UInt: AnyObject] = [:]
    private static var reportBuffers: [UnsafeMutablePointer<UInt8>] = []
    private static let maximumBuffers = 1024
    private static let maximumReportLength = 512

    static func register(_ target: AnyObject) -> UnsafeMutableRawPointer {
        precondition(Thread.isMainThread)
        precondition(nextToken < UInt.max)
        let token = nextToken
        nextToken += 1
        active[token] = target
        return UnsafeMutableRawPointer(bitPattern: token)!
    }

    static func resolve<T: AnyObject>(_ context: UnsafeMutableRawPointer?, as type: T.Type) -> T? {
        precondition(Thread.isMainThread)
        guard let context else { return nil }
        return active[UInt(bitPattern: context)] as? T
    }

    static func unregister(_ context: UnsafeMutableRawPointer?) {
        precondition(Thread.isMainThread)
        guard let context else { return }
        active.removeValue(forKey: UInt(bitPattern: context))
    }

    static func allocateReportBuffer(length: Int) -> UnsafeMutablePointer<UInt8>? {
        precondition(Thread.isMainThread)
        guard (1...maximumReportLength).contains(length),
              reportBuffers.count < maximumBuffers else { return nil }
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: length)
        buffer.initialize(repeating: 0, count: length)
        reportBuffers.append(buffer)
        return buffer
    }
}

/// Owns one active K40 vendor transport and publishes normalized controls.
/// All public methods and callbacks run on the main thread. USB control
/// transfers use one private serial worker and return to main before publishing.
final class DeviceController {
    enum Transport: String { case usb, bluetooth }
    enum State: String { case stopped, disconnected, connecting, ready }

    var onControl: (ControlID, Bool) -> Void = { _, _ in }
    var onConnectionChange: (State, Transport?) -> Void = { _, _ in }
    var onStatus: (String) -> Void = { _ in }
    var onSetting: (K40DeviceCommands.Response) -> Void = { _ in }

    private(set) var state: State = .stopped
    private(set) var transport: Transport?
    var ready: Bool { state == .ready }

    private let usbWorker = DispatchQueue(label: "KDCustom.K40USB.transfer")
    private var manager: IOHIDManager?
    private var managerContext: UnsafeMutableRawPointer?
    private var slots: [UInt64: K40USBInputSlot] = [:]
    private var selectedUSBID: UInt64?
    private var usbAttempts = 0
    private var usbExhausted = false
    private var bluetooth: K40Bluetooth?
    private var bluetoothRetries = 0
    private var restartingBluetooth = false
    private var retryWork: DispatchWorkItem?
    private var inputEdges = K40ControlEdges()
    private var ioGeneration = 0
    private var labelGeneration = 0
    private var labelSending = false
    private var activeLabelGeneration: Int?
    private var labelIndex = 0
    private var labelWrites: [K40DisplayWrite] = []
    private var desiredGroup: (group: KeydialGroup, slot: Int)?
    private var running = false
    private var lifecycleGeneration = 0

    func start() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !running else { return }
        running = true
        lifecycleGeneration += 1
        let lifecycle = lifecycleGeneration
        bluetoothRetries = 0
        configureBluetooth()
        openUSBManager()
        // Let HID matching report an already-connected USB device first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.lifecycleGeneration == lifecycle else { return }
            self.startBluetoothIfNeeded()
        }
    }

    func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard running else { return }
        running = false
        lifecycleGeneration += 1
        retryWork?.cancel(); retryWork = nil
        deactivate()
        bluetooth?.close()
        bluetooth = nil
        if let manager {
            for slot in slots.values {
                IOHIDDeviceRegisterInputReportCallback(slot.device, slot.buffer,
                                                       slot.bufferLength, nil, nil)
                K40HIDCallbackRegistry.unregister(slot.callbackContext)
                slot.callbackContext = nil
            }
            IOHIDManagerRegisterDeviceMatchingCallback(manager, nil, nil)
            IOHIDManagerRegisterDeviceRemovalCallback(manager, nil, nil)
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(),
                                              CFRunLoopMode.commonModes.rawValue)
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        manager = nil
        K40HIDCallbackRegistry.unregister(managerContext)
        managerContext = nil
        slots.removeAll()
        selectedUSBID = nil
        setState(.stopped, transport: nil)
        // A queued callback can carry its old token, but lookup now fails.
        // Its report buffer remains allocated in the bounded registry.
    }

    /// Latest group wins. The group packet is followed by physical top 1–4,
    /// bottom 5–8 using their observed alternating wire slots.
    func setGroup(_ group: KeydialGroup, slot: Int) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard (1...6).contains(slot) else {
            onStatus("Group slot must be 1…6")
            return
        }
        desiredGroup = (group, slot)
        labelGeneration += 1
        bluetooth?.cancelQueuedLabels()
        if !labelSending { beginLabelSync() }
    }

    func querySetting(_ read: K40DeviceCommands.Read) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard ready else { onStatus("Device setting unavailable: K40 is not ready"); return }
        switch transport {
        case .usb:
            let location = selectedSlot?.locationID ?? 0
            let generation = ioGeneration
            usbWorker.async { [weak self] in
                guard let self, self.canExecuteUSB(generation) else { return }
                let result = K40USBSettingCommand(location, read.rawValue)
                let raw = Self.descriptorBytes(result)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.ioGeneration == generation,
                          self.transport == .usb, self.ready else { return }
                    guard result.status == kIOReturnSuccess,
                          let setting = K40DeviceCommands.decode(raw, for: read, transport: .usb) else {
                        self.onStatus("USB \(read) setting unavailable or reply invalid")
                        return
                    }
                    self.onSetting(setting)
                }
            }
        case .bluetooth:
            if bluetooth?.sendKnownSetting(read.rawValue) != true {
                onStatus("Bluetooth setting query unavailable or busy")
            }
        case nil:
            onStatus("Device setting unavailable: no active transport")
        }
    }

    func stepSetting(_ step: K40DeviceCommands.Step) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard ready else { onStatus("Device setting step unavailable: K40 is not ready"); return }
        switch transport {
        case .usb:
            let location = selectedSlot?.locationID ?? 0
            let generation = ioGeneration
            usbWorker.async { [weak self] in
                guard let self, self.canExecuteUSB(generation) else { return }
                let result = K40USBSettingCommand(location, step.rawValue)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.ioGeneration == generation,
                          self.transport == .usb, self.ready else { return }
                    if result.status != kIOReturnSuccess {
                        self.onStatus("USB \(step) step failed: \(Self.hex(result.status))")
                    }
                }
            }
        case .bluetooth:
            if bluetooth?.sendKnownSetting(step.rawValue) != true {
                onStatus("Bluetooth setting step unavailable or busy")
            }
        case nil:
            onStatus("Device setting step unavailable: no active transport")
        }
    }

    private var selectedSlot: K40USBInputSlot? {
        selectedUSBID.flatMap { slots[$0] }
    }

    private func canExecuteUSB(_ generation: Int, registryID: UInt64? = nil) -> Bool {
        dispatchPrecondition(condition: .notOnQueue(.main))
        return DispatchQueue.main.sync {
            running && ioGeneration == generation && transport == .usb &&
                (registryID == nil || selectedUSBID == registryID)
        }
    }

    private func setState(_ new: State, transport newTransport: Transport?) {
        let changed = state != new || transport != newTransport
        state = new
        transport = newTransport
        if changed { onConnectionChange(new, newTransport) }
    }

    private func deactivate() {
        ioGeneration += 1
        labelGeneration += 1
        labelSending = false
        activeLabelGeneration = nil
        labelIndex = 0
        labelWrites.removeAll()
        bluetooth?.cancelQueuedLabels()
        for event in inputEdges.releaseAll() { onControl(event.control, event.pressed) }
    }

    private func openUSBManager() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager
        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDVendorIDKey: 0x256c, kIOHIDProductIDKey: 0x2002
        ] as CFDictionary)
        let callbackContext = K40HIDCallbackContext(owner: self, generation: lifecycleGeneration)
        let context = K40HIDCallbackRegistry.register(callbackContext)
        managerContext = context
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, result, _, device in
            guard let callback = K40HIDCallbackRegistry.resolve(context,
                                                               as: K40HIDCallbackContext.self) else { return }
            callback.owner?.usbAdded(device, result: result, generation: callback.generation)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let callback = K40HIDCallbackRegistry.resolve(context,
                                                               as: K40HIDCallbackContext.self) else { return }
            callback.owner?.usbRemoved(device, generation: callback.generation)
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(),
                                         CFRunLoopMode.commonModes.rawValue)
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if result != kIOReturnSuccess {
            onStatus("USB HID unavailable: \(Self.hex(result))")
        }
    }

    private func usbAdded(_ device: IOHIDDevice, result: IOReturn, generation: Int) {
        guard running, generation == lifecycleGeneration, result == kIOReturnSuccess else { return }
        let page = (IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsagePageKey as CFString) as? NSNumber)?
            .intValue ?? 0
        let usage = (IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsageKey as CFString) as? NSNumber)?
            .intValue ?? 0
        let transportName = IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String
        guard page == 0xff00, usage == 1, transportName == "USB" else { return }
        let reportedSize = (IOHIDDeviceGetProperty(device, kIOHIDMaxInputReportSizeKey as CFString) as? NSNumber)?
            .intValue ?? 0
        guard reportedSize <= 512 else {
            onStatus("USB HID input report exceeds the supported 512-byte buffer; Bluetooth remains available")
            return
        }
        var identifier: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device), &identifier)
        guard slots[identifier] == nil else { return }
        guard let slot = K40USBInputSlot(device: device, owner: self) else {
            onStatus("USB HID callback storage exhausted; restart KDCustom to restore USB detection")
            return
        }
        guard slots[slot.registryID] == nil else { return }
        slots[slot.registryID] = slot
        let context = K40HIDCallbackRegistry.register(slot)
        slot.callbackContext = context
        IOHIDDeviceRegisterInputReportCallback(device, slot.buffer, slot.bufferLength,
                                               { context, result, _, _, reportID, report, length in
            guard let slot = K40HIDCallbackRegistry.resolve(context, as: K40USBInputSlot.self),
                  result == kIOReturnSuccess, length >= 0, length <= slot.bufferLength else { return }
            slot.owner?.usbInput(slot, reportID: reportID,
                                 bytes: Array(UnsafeBufferPointer(start: report, count: length)))
        }, context)
        if selectedUSBID == nil || usbExhausted {
            activateUSB(slot)
        }
    }

    private func usbRemoved(_ device: IOHIDDevice, generation: Int) {
        guard running, generation == lifecycleGeneration else { return }
        let removed = slots.values.filter { CFEqual($0.device, device) }
        for slot in removed {
            IOHIDDeviceRegisterInputReportCallback(slot.device, slot.buffer,
                                                   slot.bufferLength, nil, nil)
            K40HIDCallbackRegistry.unregister(slot.callbackContext)
            slot.callbackContext = nil
            slots.removeValue(forKey: slot.registryID)
        }
        guard removed.contains(where: { $0.registryID == selectedUSBID }) else { return }
        if usbExhausted && transport == .bluetooth {
            selectedUSBID = nil
            usbExhausted = false
            return
        }
        deactivate()
        selectedUSBID = nil
        usbExhausted = false
        setState(.disconnected, transport: nil)
        if let next = slots.values.sorted(by: { $0.registryID < $1.registryID }).first {
            activateUSB(next)
        } else {
            startBluetoothIfNeeded()
        }
    }

    private func activateUSB(_ slot: K40USBInputSlot) {
        deactivate()
        restartingBluetooth = true
        bluetooth?.close()
        restartingBluetooth = false
        retryWork?.cancel(); retryWork = nil
        selectedUSBID = slot.registryID
        usbAttempts = 0
        usbExhausted = false
        setState(.connecting, transport: .usb)
        onStatus("K40 USB vendor interface found; validating T221 identity")
        beginUSBHandshake()
    }

    private func beginUSBHandshake() {
        guard running, let slot = selectedSlot, !usbExhausted else { return }
        usbAttempts += 1
        let generation = ioGeneration
        let location = slot.locationID
        usbWorker.async { [weak self] in
            guard let self, self.canExecuteUSB(generation, registryID: slot.registryID) else { return }
            let identity = K40USBReadControlIdentity(location)
            let identityBytes = Self.descriptorBytes(identity)
            let validIdentity = identity.status == kIOReturnSuccess &&
                Self.validT221Identity(identityBytes)
            guard self.canExecuteUSB(generation, registryID: slot.registryID) else { return }
            let mode = validIdentity ? K40USBEnterControlMode(location) : nil
            let validMode = mode.map {
                $0.status == kIOReturnSuccess && Self.validDescriptor(Self.descriptorBytes($0))
            } ?? false
            DispatchQueue.main.async { [weak self] in
                guard let self, self.running, self.ioGeneration == generation,
                      self.selectedUSBID == slot.registryID else { return }
                if validMode {
                    self.usbAttempts = 0
                    self.setState(.ready, transport: .usb)
                    self.onStatus("K40 USB controls ready")
                    self.beginLabelSync()
                } else {
                    let phase = validIdentity ? "C8" : "C9 identity"
                    self.onStatus("K40 USB \(phase) validation failed")
                    self.retryUSBHandshake()
                }
            }
        }
    }

    private func retryUSBHandshake() {
        guard usbAttempts < 3 else {
            usbExhausted = true
            deactivate()
            setState(.disconnected, transport: nil)
            onStatus("K40 USB initialization exhausted after three attempts")
            startBluetoothIfNeeded()
            return
        }
        let delay = Double(1 << (usbAttempts - 1)) * 0.5
        let generation = ioGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.ioGeneration == generation,
                  self.transport == .usb else { return }
            self.beginUSBHandshake()
        }
    }

    private func usbInput(_ slot: K40USBInputSlot, reportID: UInt32, bytes: [UInt8]) {
        guard running, ready, transport == .usb,
              selectedUSBID == slot.registryID,
              slots[slot.registryID] === slot else { return }
        for event in inputEdges.consume(reportID: reportID, bytes: bytes) {
            onControl(event.control, event.pressed)
        }
    }

    private func configureBluetooth() {
        let bluetooth = K40Bluetooth()
        self.bluetooth = bluetooth
        bluetooth.onStatus = { [weak self, weak bluetooth] message in
            guard let self, let bluetooth, self.bluetooth === bluetooth, self.running else { return }
            self.onStatus(message)
        }
        bluetooth.onInput = { [weak self, weak bluetooth] bytes, _ in
            guard let self, let bluetooth, self.bluetooth === bluetooth,
                  self.running, self.ready, self.transport == .bluetooth else { return }
            for event in self.inputEdges.consume(reportID: 8, bytes: bytes) {
                self.onControl(event.control, event.pressed)
            }
        }
        bluetooth.onConnectionChange = { [weak self, weak bluetooth] connected in
            guard let self, let bluetooth, self.bluetooth === bluetooth, self.running else { return }
            if connected {
                if self.selectedUSBID == nil || self.usbExhausted {
                    bluetooth.enterControlMode()
                }
            } else if self.transport == .bluetooth {
                self.deactivate()
                self.setState(.disconnected, transport: nil)
                if !self.restartingBluetooth { self.scheduleBluetoothRetry() }
            }
        }
        bluetooth.onControlReady = { [weak self, weak bluetooth] initialized in
            guard let self, let bluetooth, self.bluetooth === bluetooth, self.running else { return }
            if initialized && (self.selectedUSBID == nil || self.usbExhausted) {
                self.retryWork?.cancel(); self.retryWork = nil
                self.bluetoothRetries = 0
                self.setState(.ready, transport: .bluetooth)
                self.beginLabelSync()
            } else if !initialized && self.transport == .bluetooth && self.ready {
                self.deactivate()
                self.setState(.disconnected, transport: nil)
                if !self.restartingBluetooth { self.scheduleBluetoothRetry() }
            }
        }
        bluetooth.onSettingResponse = { [weak self, weak bluetooth] index, bytes in
            guard let self, let bluetooth, self.bluetooth === bluetooth,
                  self.running, self.ready, self.transport == .bluetooth,
                  let read = K40DeviceCommands.Read(rawValue: index) else { return }
            if let response = K40DeviceCommands.decode(bytes, for: read, transport: .bluetooth) {
                self.onSetting(response)
            } else {
                self.onStatus("Bluetooth \(read) reply invalid")
            }
        }
        bluetooth.onFailure = { [weak self, weak bluetooth] message in
            guard let self, let bluetooth, self.bluetooth === bluetooth,
                  self.running,
                  self.selectedUSBID == nil || self.usbExhausted else { return }
            self.onStatus(message)
            self.scheduleBluetoothRetry()
        }
    }

    private func startBluetoothIfNeeded() {
        guard running, selectedUSBID == nil || usbExhausted else { return }
        if bluetooth?.initialized == true {
            setState(.ready, transport: .bluetooth)
            beginLabelSync()
            return
        }
        setState(.connecting, transport: .bluetooth)
        bluetooth?.inspect()
    }

    private func scheduleBluetoothRetry() {
        guard running, selectedUSBID == nil || usbExhausted,
              retryWork == nil else { return }
        let delay: Double
        if bluetoothRetries < 4 {
            bluetoothRetries += 1
            delay = Double(1 << (bluetoothRetries - 1))
        } else {
            delay = 60
            onStatus("K40 Bluetooth will retry in 60 seconds while disconnected")
        }
        let lifecycle = lifecycleGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.running, self.lifecycleGeneration == lifecycle else { return }
            self.retryWork = nil
            self.restartingBluetooth = true
            self.bluetooth?.close()
            self.restartingBluetooth = false
            self.startBluetoothIfNeeded()
        }
        retryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func beginLabelSync() {
        guard ready, let desiredGroup, !labelSending else { return }
        do {
            labelWrites = try K40LabelPlan.make(group: desiredGroup.group,
                                                slot: desiredGroup.slot)
        } catch {
            onStatus("K40 label encoding failed: \(error)")
            return
        }
        labelIndex = 0
        sendNextLabel(generation: labelGeneration)
    }

    private func sendNextLabel(generation: Int) {
        guard running, ready, generation == labelGeneration,
              labelIndex < labelWrites.count else { return }
        let write = labelWrites[labelIndex]
        let packet = write.bytes
        let delay = write.delayAfter
        labelSending = true
        activeLabelGeneration = generation
        let currentIndex = labelIndex
        switch transport {
        case .usb:
            let location = selectedSlot?.locationID ?? 0
            let io = ioGeneration
            usbWorker.async { [weak self] in
                guard let self, self.canExecuteUSB(io) else { return }
                let result = packet.withUnsafeBufferPointer { buffer in
                    K40USBSendLabelPacket(location, buffer.baseAddress!)
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.ioGeneration == io else { return }
                    if result.status != kIOReturnSuccess {
                        self.onStatus("USB label transfer failed: \(Self.hex(result.status))")
                    }
                    self.finishLabel(index: currentIndex, generation: generation,
                                     delay: delay, succeeded: result.status == kIOReturnSuccess)
                }
            }
        case .bluetooth:
            let accepted = bluetooth?.sendLabelPacket(packet, delayAfter: delay,
                                                       label: "\(packet[4])-\(currentIndex)") == true
            finishLabel(index: currentIndex, generation: generation,
                        delay: delay, succeeded: accepted)
        case nil:
            labelSending = false
        }
    }

    private func finishLabel(index: Int, generation: Int, delay: TimeInterval,
                             succeeded: Bool) {
        guard running, activeLabelGeneration == generation else { return }
        if !succeeded {
            labelSending = false
            activeLabelGeneration = nil
            if generation == labelGeneration {
                onStatus("K40 label sync paused; device write unavailable")
            } else {
                beginLabelSync()
            }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.running,
                  self.activeLabelGeneration == generation else { return }
            self.labelSending = false
            self.activeLabelGeneration = nil
            if generation != self.labelGeneration {
                self.beginLabelSync()
            } else if index + 1 < self.labelWrites.count {
                self.labelIndex = index + 1
                self.sendNextLabel(generation: generation)
            }
        }
    }

    private static func descriptorBytes(_ result: K40USBGroupQueryResult) -> [UInt8] {
        let count = min(Int(result.descriptorLength), 128)
        return withUnsafeBytes(of: result.descriptor) { Array($0.prefix(count)) }
    }

    private static func validDescriptor(_ bytes: [UInt8]) -> Bool {
        bytes.count >= 3 && bytes[1] == 0x03 && Int(bytes[0]) >= 3 &&
            Int(bytes[0]) <= bytes.count
    }

    private static func validT221Identity(_ bytes: [UInt8]) -> Bool {
        guard validDescriptor(bytes), Int(bytes[0]).isMultiple(of: 2) else { return false }
        let length = Int(bytes[0])
        let codeUnits = stride(from: 2, to: length, by: 2).map {
            UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8
        }
        return String(decoding: codeUnits, as: UTF16.self).uppercased().contains("T221")
    }

    private static func hex(_ status: IOReturn) -> String {
        String(format: "0x%08x", UInt32(bitPattern: status))
    }
}
