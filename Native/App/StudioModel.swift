import AppKit
import SwiftUI
import CoreBluetooth
import ApplicationServices
import IOKit.hid
import ServiceManagement
import Carbon

@MainActor
final class StudioModel: ObservableObject {
    @Published private(set) var document: KeydialDocument
    @Published private(set) var revision: String
    @Published var selectedProfileID: String
    @Published var selectedControl: ControlID = .dial1CW
    @Published private(set) var activeControls = Set<ControlID>()
    @Published private(set) var activeAppName = "No active app"
    @Published private(set) var activeBundleID: String?
    @Published private(set) var connection = "Connecting"
    @Published private(set) var transport = "—"
    @Published private(set) var ready = false
    @Published private(set) var accessibilityAllowed = false
    @Published private(set) var inputAllowed = false
    @Published private(set) var bluetoothAllowed = false
    @Published private(set) var loginEnabled = false
    @Published private(set) var secureInput = false
    @Published private(set) var sessionAvailable = true
    @Published private(set) var huionRunning = false
    @Published private(set) var deviceSettings: [String: String] = [:]
    @Published private(set) var recentEvents: [String] = []
    @Published var errorMessage: String?
    @Published var appearance = UserDefaults.standard.string(forKey: "appearance") ?? "dark" {
        didSet { UserDefaults.standard.set(appearance, forKey: "appearance"); applyAppearance() }
    }
    @Published private(set) var handedToHuion = false
    @Published var paused = false { didSet { refreshOutputGate(reason: "Pause changed") } }
    @Published var lockedProfileID: String? { didSet { contextChanged(reason: "Profile lock changed") } }
    var onStatusChange: (() -> Void)?
    let configuration: ConfigurationService
    let device = DeviceController()
    private let output = SystemActionOutput()
    private lazy var engine = ActionEngine(output: output)
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []
    private var bridge: LocalBridge?
    private var observedSettings: [String: [String: Any]] = [:]
    private var tickCount = 0
    private var lastEffectiveGroup: KeydialGroup?
    private var lastEffectiveProfileID: String?
    private var deviceStarted = false
    private var lastForegroundPID: pid_t?
    private var queuedGroupChange: (profile: String, revision: String, offset: Int)?

    init() throws {
        configuration = try ConfigurationService()
        document = configuration.document
        revision = configuration.revision
        selectedProfileID = configuration.document.globalProfileID
        configuration.onChange = { [weak self] document, revision in
            guard let self else { return }
            self.queuedGroupChange = nil
            self.engine.cancelAll(reason: "Configuration changed")
            self.document = document; self.revision = revision
            if !document.profiles.contains(where: { $0.id == self.selectedProfileID }) {
                self.selectedProfileID = document.globalProfileID
            }
            if let locked = self.lockedProfileID, !document.profiles.contains(where: { $0.id == locked }) {
                self.lockedProfileID = nil
            }
            self.syncEffectiveGroup()
        }
        engine.onGroupChange = { [weak self] offset in self?.queueGroupChange(offset) }
        engine.onEvent = { [weak self] in self?.record($0) }
        output.onObservationLost = { [weak self] in self?.engine.cancelAll(reason: "Input observer interrupted") }
        device.onControl = { [weak self] control, down in self?.input(control, down: down) }
        device.onStatus = { [weak self] in self?.record($0) }
        device.onConnectionChange = { [weak self] state, transport in
            guard let self else { return }
            self.engine.cancelAll(reason: "Device connection changed")
            self.activeControls.removeAll()
            self.ready = self.device.ready
            self.connection = self.ready ? "Connected" : String(describing: state).capitalized
            self.transport = transport.map { String(describing: $0).uppercased() } ?? "—"
            if self.ready {
                self.lastEffectiveGroup = nil
                self.syncEffectiveGroup()
                self.device.querySetting(.battery)
                self.device.querySetting(.rotation)
                self.device.querySetting(.dormantTime)
            }
            else { self.observedSettings.removeAll(); self.deviceSettings.removeAll() }
            self.refreshOutputGate(reason: "Device connection changed")
        }
        device.onSetting = { [weak self] response in self?.observed(response) }
    }

    var editorProfile: KeydialProfile { document.profiles.first { $0.id == selectedProfileID } ?? document.profiles[0] }
    var editorGroup: KeydialGroup { editorProfile.selectedGroup ?? editorProfile.groups[0] }
    var effectiveProfile: KeydialProfile { document.effectiveProfile(bundleIdentifier: activeBundleID, lockedProfileID: lockedProfileID)! }
    var effectiveGroup: KeydialGroup { effectiveProfile.selectedGroup ?? effectiveProfile.groups[0] }
    var currentBinding: ControlBinding { editorGroup.binding(for: selectedControl)! }
    var outputStatus: String {
        if paused { return "Paused" }
        if huionRunning { return "Quit Huion to connect" }
        if !sessionAvailable { return "Session locked" }
        if secureInput { return "Secure input active" }
        if !accessibilityAllowed || !inputAllowed { return "Permissions needed" }
        if !ready { return "Waiting for device" }
        if lastForegroundPID == nil || activeBundleID == nil { return "Waiting for active app" }
        if activeBundleID == Bundle.main.bundleIdentifier { return "Editing · output suspended" }
        if !output.observing { return "Input observer unavailable" }
        return "Ready"
    }

    func start() {
        applyAppearance()
        checkPermissions()
        foregroundChanged(NSWorkspace.shared.frontmostApplication)
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated { self?.foregroundChanged(note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication) }
        })
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setSessionAvailable(false) }
            })
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setSessionAvailable(true) }
            })
        }
        let distributed = DistributedNotificationCenter.default()
        for (name, available) in [("com.apple.screenIsLocked", false), ("com.apple.screenIsUnlocked", true)] {
            distributedObservers.append(distributed.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setSessionAvailable(available) }
            })
        }
        timer = Timer(timeInterval: 0.01, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.reconcileForeground()
                let secure = IsSecureEventInputEnabled()
                if secure != self.secureInput {
                    self.engine.cancelAll(reason: "Secure input changed")
                    self.secureInput = secure
                    self.refreshOutputGate(reason: "Secure input changed")
                }
                self.engine.tick(now: ProcessInfo.processInfo.systemUptime)
                self.tickCount += 1
                if self.tickCount % 50 == 0 { self.checkPermissions() }
            }
        }
        RunLoop.main.add(timer!, forMode: .common)
        let bridge = LocalBridge { [weak self] operation, arguments in
            try DispatchQueue.main.sync {
                guard let self else { throw LocalBridgeError(message: "KDCustom is closing") }
                return try self.handleAgent(operation, arguments: arguments)
            }
        }
        do { try bridge.start(); self.bridge = bridge }
        catch { errorMessage = error.localizedDescription; record("Agent bridge: \(error.localizedDescription)") }
        reconcileDevice()
    }
    func stop() {
        engine.cancelAll(reason: "App closing")
        output.enabled = false
        output.stopObserving()
        timer?.invalidate(); timer = nil
        device.stop(); deviceStarted = false
        bridge?.stop(); bridge = nil
        for item in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(item) }
        for item in observers { NotificationCenter.default.removeObserver(item) }
        for item in distributedObservers { DistributedNotificationCenter.default().removeObserver(item) }
        workspaceObservers.removeAll(); observers.removeAll(); distributedObservers.removeAll()
    }
    private func setSessionAvailable(_ available: Bool) {
        engine.cancelAll(reason: "Session changed")
        sessionAvailable = available
        refreshOutputGate(reason: "Session changed")
        if !available { device.stop(); deviceStarted = false }
        else { reconcileDevice(); foregroundChanged(NSWorkspace.shared.frontmostApplication) }
    }
    private func foregroundChanged(_ app: NSRunningApplication?) {
        if lastForegroundPID != app?.processIdentifier {
            engine.cancelAll(reason: "Foreground application changed")
            activeControls.removeAll()
        }
        lastForegroundPID = app?.processIdentifier
        output.expectedForegroundPID = app?.processIdentifier
        activeAppName = app?.localizedName ?? "No active app"
        activeBundleID = app?.bundleIdentifier
        contextChanged(reason: "Foreground application changed")
    }
    private func reconcileForeground() {
        let app = NSWorkspace.shared.frontmostApplication
        if lastForegroundPID != app?.processIdentifier || activeBundleID != app?.bundleIdentifier {
            foregroundChanged(app)
        }
    }
    private func contextChanged(reason: String) {
        queuedGroupChange = nil
        engine.cancelAll(reason: reason)
        syncEffectiveGroup()
        refreshOutputGate(reason: reason)
    }
    private func syncEffectiveGroup() {
        let profile = effectiveProfile; let group = effectiveGroup
        guard lastEffectiveProfileID != profile.id || lastEffectiveGroup != group else { return }
        lastEffectiveProfileID = profile.id; lastEffectiveGroup = group
        guard let index = profile.groups.firstIndex(where: { $0.id == group.id }) else { return }
        device.setGroup(group, slot: index + 1)
        onStatusChange?()
    }
    private func input(_ control: ControlID, down: Bool) {
        reconcileForeground()
        if down { activeControls.insert(control) } else if !control.isDial { activeControls.remove(control) }
        if control.isDial {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in self?.activeControls.remove(control) }
        }
        guard !IsSecureEventInputEnabled(), output.enabled, let binding = effectiveGroup.binding(for: control) else { return }
        engine.handle(control: control, isDown: down, binding: binding, now: ProcessInfo.processInfo.systemUptime)
    }
    private func queueGroupChange(_ offset: Int) {
        if let pending = queuedGroupChange, pending.profile == effectiveProfile.id, pending.revision == revision {
            queuedGroupChange = (pending.profile, pending.revision, (pending.offset + offset) % 6)
            return
        }
        queuedGroupChange = (effectiveProfile.id, revision, offset)
        DispatchQueue.main.async { [weak self] in
            guard let self, let pending = self.queuedGroupChange else { return }
            self.queuedGroupChange = nil
            guard self.effectiveProfile.id == pending.profile, self.revision == pending.revision else { return }
            self.changeActiveGroup(pending.offset)
        }
    }
    private func changeActiveGroup(_ offset: Int) {
        let profile = effectiveProfile
        guard let index = profile.groups.firstIndex(where: { $0.id == profile.selectedGroupID }) else { return }
        let group = profile.groups[(index + offset + 12) % 6]
        perform("groups.select", ["profileId": profile.id, "groupId": group.id])
    }
    private func refreshOutputGate(reason: String) {
        let enabled = !paused && !huionRunning && !handedToHuion && sessionAvailable && !secureInput && ready &&
            accessibilityAllowed && inputAllowed && output.observing && lastForegroundPID != nil &&
            activeBundleID != nil && activeBundleID != Bundle.main.bundleIdentifier
        if output.enabled && !enabled { queuedGroupChange = nil; engine.cancelAll(reason: reason) }
        output.enabled = enabled
        onStatusChange?()
    }
    func checkPermissions() {
        let wasAllowed = inputAllowed
        let accessibility = AXIsProcessTrusted()
        let input = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
        let bluetooth = CBManager.authorization == .allowedAlways
        let login = SMAppService.mainApp.status == .enabled
        if accessibilityAllowed != accessibility { accessibilityAllowed = accessibility }
        if inputAllowed != input { inputAllowed = input }
        if bluetoothAllowed != bluetooth { bluetoothAllowed = bluetooth }
        if loginEnabled != login { loginEnabled = login }
        let secure = IsSecureEventInputEnabled()
        if secure != secureInput { engine.cancelAll(reason: "Secure input changed"); secureInput = secure }
        let huion = NSWorkspace.shared.runningApplications.contains {
            ($0.bundleIdentifier?.lowercased().contains("huion") == true) ||
            ($0.localizedName?.lowercased().contains("huion") == true)
        }
        if huionRunning != huion { huionRunning = huion }
        if inputAllowed && accessibilityAllowed && !output.observing { output.startObserving() }
        if wasAllowed && !inputAllowed { engine.cancelAll(reason: "Input permission revoked"); output.stopObserving() }
        refreshOutputGate(reason: "Runtime access changed")
        reconcileDevice()
    }
    private func reconcileDevice() {
        if !huionRunning && !handedToHuion && inputAllowed && sessionAvailable {
            if !deviceStarted { deviceStarted = true; device.start() }
        } else if deviceStarted {
            engine.cancelAll(reason: "Device access suspended")
            device.stop(); deviceStarted = false
        }
    }
    func emergencyRelease() {
        engine.cancelAll(reason: "Emergency release")
        activeControls.removeAll()
        record("All synthesized holds released; pending macros canceled")
    }
    func reconnect() {
        engine.cancelAll(reason: "Reconnect requested")
        device.stop(); deviceStarted = false; reconcileDevice()
    }
    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        openPrivacy("Privacy_Accessibility")
    }
    func openPrivacy(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(url) }
    }
    func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            checkPermissions()
        } catch { errorMessage = error.localizedDescription }
    }
    func saveBinding(_ binding: ControlBinding) throws {
        let data = try JSONEncoder().encode(binding)
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        _ = try configuration.handle(operation: "bindings.set", arguments: ["profileId": editorProfile.id,
            "groupId": editorGroup.id, "binding": object, "expectedRevision": revision])
    }
    func selectGroup(_ id: String) { perform("groups.select", ["profileId": editorProfile.id, "groupId": id]) }
    func renameGroup(_ name: String) { perform("groups.rename", ["profileId": editorProfile.id, "groupId": editorGroup.id, "name": name]) }
    func renameProfile(_ name: String) { perform("profiles.update", ["profileId": editorProfile.id, "name": name]) }
    func deleteProfile() { perform("profiles.delete", ["profileId": editorProfile.id]) }
    func addApplicationProfile() {
        let panel = NSOpenPanel()
        panel.title = "Choose an application for this profile"
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let bundle = Bundle(url: url), let identifier = bundle.bundleIdentifier else { return }
        if let existing = document.profiles.first(where: { $0.appBundleIdentifier == identifier }) {
            selectedProfileID = existing.id; return
        }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String) ??
            (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? url.deletingPathExtension().lastPathComponent
        let id = UUID().uuidString
        perform("profiles.create", ["profileId": id, "name": name, "appBundleIdentifier": identifier])
        if document.profiles.contains(where: { $0.id == id }) { selectedProfileID = id }
    }
    func perform(_ operation: String, _ arguments: [String: Any]) {
        do {
            var arguments = arguments; arguments["expectedRevision"] = revision
            _ = try configuration.handle(operation: operation, arguments: arguments)
        } catch { errorMessage = error.localizedDescription }
    }
    func exportProfiles() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "KDCustom-profiles.json"; panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try ProfileStore().exportDocument(document, to: url) }
        catch { errorMessage = error.localizedDescription }
    }
    func importProfiles() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let candidate = try ProfileStore().importDocument(from: url)
            let alert = NSAlert(); alert.messageText = "Replace profiles with this import?"
            alert.informativeText = "\(candidate.profiles.count) profiles will replace the current configuration. Your previous configuration is saved as a backup."
            alert.addButton(withTitle: "Import"); alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            try configuration.replaceDocument(candidate, expectedRevision: revision)
        } catch { errorMessage = error.localizedDescription }
    }
    func restoreBackup() {
        do { try configuration.replaceDocument(ProfileStore().loadBackup(), expectedRevision: revision) }
        catch { errorMessage = error.localizedDescription }
    }
    func query(_ setting: K40DeviceCommands.Read) { device.querySetting(setting) }
    func step(_ setting: K40DeviceCommands.Step) {
        device.stepSetting(setting)
        let query: K40DeviceCommands.Read
        switch setting {
        case .rotationNext: query = .rotation
        case .dormantTimeUp, .dormantTimeDown: query = .dormantTime
        case .brightnessUp, .brightnessDown: query = .brightness
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.device.querySetting(query) }
    }
    var colorScheme: ColorScheme? { appearance == "light" ? .light : appearance == "dark" ? .dark : nil }
    var orientationDegrees: Int {
        (observedSettings["rotation"]?["value"] as? Int) ?? 180
    }
    var batteryBucket: Int? { observedSettings["battery"]?["value"] as? Int }
    private func applyAppearance() {
        NSApp.appearance = appearance == "dark" ? NSAppearance(named: .darkAqua) :
            appearance == "light" ? NSAppearance(named: .aqua) : nil
    }
    func resetProfile() {
        var candidate = document
        guard let index = candidate.profiles.firstIndex(where: { $0.id == editorProfile.id }) else { return }
        let alert = NSAlert(); alert.messageText = "Reset this profile?"
        alert.informativeText = "All six groups will return to empty mappings. The current configuration is kept as a backup."
        alert.addButton(withTitle: "Reset"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        candidate.profiles[index].groups = KeydialProfile(name: "Default").groups
        candidate.profiles[index].selectedGroupID = "group-1"
        replace(candidate)
    }
    func duplicateProfile() {
        let panel = NSOpenPanel(); panel.title = "Copy this profile to another application"
        panel.allowedContentTypes = [.application]; panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url, let bundle = Bundle(url: url), let identifier = bundle.bundleIdentifier else { return }
        guard !document.profiles.contains(where: { $0.appBundleIdentifier == identifier }) else {
            errorMessage = "This application already has a profile. Export or edit that profile before replacing it."; return
        }
        var profile = editorProfile
        profile.id = UUID().uuidString; profile.appBundleIdentifier = identifier
        profile.name = (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? url.deletingPathExtension().lastPathComponent
        var candidate = document; candidate.profiles.append(profile)
        replace(candidate)
        if document.profiles.contains(where: { $0.id == profile.id }) { selectedProfileID = profile.id }
    }
    func replace(_ candidate: KeydialDocument) {
        do { try configuration.replaceDocument(candidate, expectedRevision: revision) }
        catch { errorMessage = error.localizedDescription }
    }
    func importHuion(_ candidate: KeydialDocument) {
        let alert = NSAlert(); alert.messageText = "Apply the reviewed Huion import?"
        alert.informativeText = "This replaces KDCustom's profiles with the reviewed candidate. A backup is kept. Huion's settings stay untouched."
        alert.addButton(withTitle: "Apply"); alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { replace(candidate) }
    }
    func exportDiagnostics() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "KDCustom-diagnostics.json"; panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let runtime = try handleAgent("runtime.get", arguments: [:])
            let data = try JSONSerialization.data(withJSONObject: ["version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown", "runtime": runtime,
                "settings": observedSettings, "events": recentEvents,
                "generatedAt": ISO8601DateFormatter().string(from: Date())], options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic)
        } catch { errorMessage = error.localizedDescription }
    }
    func useKDCustom() {
        handedToHuion = false
        for app in NSWorkspace.shared.runningApplications where
            app.bundleIdentifier?.lowercased().contains("huion") == true ||
            app.localizedName?.lowercased().contains("huion") == true {
            _ = app.terminate()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.checkPermissions() }
    }
    func returnToHuion() {
        engine.cancelAll(reason: "Return to Huion")
        handedToHuion = true; paused = true
        device.stop(); deviceStarted = false
        let url = URL(fileURLWithPath: "/Applications/HuionKeyboard.app")
        guard FileManager.default.fileExists(atPath: url.path) else { errorMessage = "Huion Keyboard is not installed at its usual location."; return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init()) { _, error in
            if let error { DispatchQueue.main.async { [weak self] in self?.errorMessage = error.localizedDescription } }
        }
    }
    private func observed(_ response: K40DeviceCommands.Response) {
        let name: String
        switch response.index {
        case .battery: name = "battery"
        case .brightness: name = "brightness"
        case .dormantTime: name = "sleep"
        case .rotation: name = "rotation"
        }
        let value: Int?; let display: String
        switch response.value {
        case .batteryBucket(let v): value = v; display = "\(v)% bucket"
        case .brightnessLevel(let v): value = v; display = "Level \(v)"
        case .dormantLevel(let v): value = v; display = "Level \(v)"
        case .rotationDegrees(let v): value = v; display = "\(v)°"
        case .unrecognized: value = nil; display = "Unrecognized"
        }
        deviceSettings[name] = display
        observedSettings[name] = ["availability": value == nil ? "unrecognized" : "available",
                                 "value": value as Any? ?? NSNull(), "observedAt": ISO8601DateFormatter().string(from: Date()),
                                 "raw": response.raw]
    }
    func record(_ event: String) {
        recentEvents.append(event)
        if recentEvents.count > 100 { recentEvents.removeFirst(recentEvents.count - 100) }
    }
    private func handleAgent(_ operation: String, arguments: [String: Any]) throws -> [String: Any] {
        switch operation {
        case "runtime.get":
            guard arguments.isEmpty else { throw MCPInputError(reason: "Unexpected runtime arguments") }
            return ["revision": revision, "activeApp": activeAppName,
                    "activeBundleIdentifier": activeBundleID as Any? ?? NSNull(),
                    "effectiveProfileId": effectiveProfile.id, "effectiveGroupId": effectiveGroup.id,
                    "lockedProfileId": lockedProfileID as Any? ?? NSNull(), "paused": paused,
                    "outputStatus": outputStatus, "device": ["state": connection, "transport": transport, "ready": ready],
                    "permissions": ["accessibility": accessibilityAllowed, "inputMonitoring": inputAllowed, "bluetooth": bluetoothAllowed]]
        case "device.getSettings":
            guard arguments.isEmpty else { throw MCPInputError(reason: "Unexpected settings arguments") }
            return ["settings": ["battery", "brightness", "sleep", "rotation"].reduce(into: [String: Any]()) { result, name in
                result[name] = observedSettings[name] ?? ["availability": "unavailable"]
            }]
        case "device.querySetting":
            guard Set(arguments.keys) == ["setting"], let name = arguments["setting"] as? String,
                  let setting = ["battery": K40DeviceCommands.Read.battery, "brightness": .brightness,
                                 "sleep": .dormantTime, "rotation": .rotation][name] else {
                throw MCPInputError(reason: "Unknown device setting")
            }
            guard ready else { throw MCPInputError(reason: "Device is disconnected") }
            device.querySetting(setting)
            return ["requested": name, "availability": "pending"]
        default: return try configuration.handle(operation: operation, arguments: arguments)
        }
    }
}
