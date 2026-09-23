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
    @Published var selectedProfileID: String { didSet { editingContextGroupID = nil } }
    @Published var editingContextGroupID: String?
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
    private var recentDialDecisions: [[String: Any]] = []
    @Published var errorMessage: String?
    @Published var showingSettings = false
    @Published var showingContextRules = false
    @Published private(set) var focusedInput = FocusSnapshot()
    @Published private(set) var lastExternalFocus: FocusSnapshot?
    @Published private(set) var lastExternalFocusAt: Date?
    @Published private(set) var panelInspectionStatus = "Panel inspection is off"
    @Published private(set) var inputAreaStatus = "Area detection is off"
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
    private let focusObserver = FocusedInputObserver()
    private let panelDiagnostics = RivePanelDiagnostics()
    private let inputAreaObserver = RiveInputAreaObserver()
    private var lastObservedArea: InputArea?
    private var focusConfirmedAt: TimeInterval = 0
    private var appIcons: [String: NSImage] = [:]
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
    private struct TypedNumericContext: Equatable {
        let token: String
        let revision: String
        let profile: String
        let pid: pid_t?
        let allowText: Bool
        let commitMethod: NumericCommitMethod
        let nativeArrowStep: Double
    }
    private var typedNumericContext: TypedNumericContext?
    private var typedNumericJob: UUID?
    private var typedNumericSteps = NumericStepBuffer()
    @Published private var numericReselectionPID: pid_t?
    private var physicalEditingEpoch: UInt64 = 0

    init() throws {
        configuration = try ConfigurationService()
        document = configuration.document
        revision = configuration.revision
        selectedProfileID = configuration.document.globalProfileID
        configuration.onChange = { [weak self] document, revision in
            guard let self else { return }
            self.queuedGroupChange = nil
            self.cancelActions(reason: "Configuration changed")
            self.inputAreaObserver.reset()
            self.document = document; self.revision = revision
            if !document.profiles.contains(where: { $0.id == self.selectedProfileID }) {
                self.selectedProfileID = document.globalProfileID
            }
            if let locked = self.lockedProfileID, !document.profiles.contains(where: { $0.id == locked }) {
                self.lockedProfileID = nil
            }
            self.syncEffectiveGroup()
            self.observeFocus()
        }
        engine.onGroupChange = { [weak self] offset in self?.queueGroupChange(offset) }
        engine.onEvent = { [weak self] in self?.record($0) }
        output.onObservationLost = { [weak self] in self?.cancelActions(reason: "Input observer interrupted") }
        output.onPhysicalEditingInput = { [weak self] in
            guard let self else { return }
            self.physicalEditingEpoch &+= 1
            self.inputAreaObserver.physicalInput()
            self.cancelNumericWork()
            if self.numericReselectionPID == NSWorkspace.shared.frontmostApplication?.processIdentifier {
                self.numericReselectionPID = nil
                self.onStatusChange?()
            }
        }
        output.onPhysicalPointerDown = { [weak self] point in
            self?.panelDiagnostics.pointerDown(point)
            self?.inputAreaObserver.pointerDown(point)
        }
        output.onExternalNavigation = { [weak self] code, down, source, flags in
            guard let self, self.activeBundleID == "app.rive.editor" else { return }
            self.panelDiagnostics.note("externalNavigation", "key=\(code) \(down ? "down" : "up") source=\(source) flags=\(flags)")
        }
        output.onInjectedNavigation = { [weak self] code, down, flags in
            guard let self, self.activeBundleID == "app.rive.editor" else { return }
            self.panelDiagnostics.note("injectedNavigation", "key=\(code) \(down ? "down" : "up") flags=\(flags)")
        }
        output.onOutput = { [weak self] event in
            guard let self, self.activeBundleID == "app.rive.editor" else { return }
            self.panelDiagnostics.note("output", event)
        }
        panelDiagnostics.onChange = { [weak self] in self?.panelInspectionStatus = $0 }
        inputAreaObserver.shouldDeferCapture = { [weak self] in
            guard let self else { return false }
            return self.typedNumericJob != nil || self.focusObserver.defersAreaObservation
        }
        inputAreaObserver.onChange = { [weak self] area, status in
            guard let self else { return }
            if self.lastObservedArea != area {
                self.cancelActions(reason: "Rive area changed")
                self.lastObservedArea = area
            }
            self.inputAreaStatus = status
            self.onStatusChange?()
        }
        focusObserver.onWindowChange = { [weak self] in self?.inputAreaObserver.reset() }
        focusObserver.setKeyboardOutput(output)
        device.onControl = { [weak self] control, down in self?.input(control, down: down) }
        device.onStatus = { [weak self] in self?.record($0) }
        device.onConnectionChange = { [weak self] state, transport in
            guard let self else { return }
            self.cancelActions(reason: "Device connection changed")
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
        focusObserver.onChange = { [weak self] in self?.focusChanged($0) }
    }

    var editorProfile: KeydialProfile { document.profiles.first { $0.id == selectedProfileID } ?? document.profiles[0] }
    var editorGroup: KeydialGroup {
        if let id = editingContextGroupID, let group = editorProfile.groups.first(where: { $0.id == id }) { return group }
        return editorProfile.selectedGroup ?? editorProfile.groups[0]
    }
    var effectiveProfile: KeydialProfile { document.effectiveProfile(bundleIdentifier: activeBundleID, lockedProfileID: lockedProfileID)! }
    var effectiveGroup: KeydialGroup { effectiveProfile.selectedGroup ?? effectiveProfile.groups[0] }
    var currentBinding: ControlBinding { editorGroup.binding(for: selectedControl)! }
    private var usesAreaRules: Bool {
        activeBundleID == "app.rive.editor" && effectiveProfile.appBundleIdentifier == activeBundleID &&
            effectiveProfile.contextRules.contains { $0.enabled && $0.area != nil }
    }
    var currentInputArea: InputArea? { usesAreaRules ? inputAreaObserver.currentArea : nil }
    var activeContextRule: FocusRule? {
        effectiveProfile.matchingRule(for: focusedInput, area: currentInputArea)
    }
    var focusStatus: String {
        if let rule = activeContextRule { return "Dials · \(rule.name)" }
        if usesAreaRules { return "Dials · \(inputAreaStatus)" }
        switch focusedInput.kind {
        case .unavailable: return "Dials · app defaults"
        case .secure: return "Protected input · app defaults"
        default: return "\(focusedInput.kind.rawValue.capitalized) control · app defaults"
        }
    }
    var outputStatus: String {
        if paused { return "Paused" }
        if huionRunning { return "Quit Huion to connect" }
        if !sessionAvailable { return "Session locked" }
        if secureInput { return "Secure input active" }
        if focusedInput.kind == .secure { return "Protected input active" }
        if !accessibilityAllowed || !inputAllowed { return "Permissions needed" }
        if !ready { return "Waiting for device" }
        if lastForegroundPID == nil || activeBundleID == nil { return "Waiting for active app" }
        if activeBundleID == Bundle.main.bundleIdentifier { return "Editing · output suspended" }
        if !output.observing { return "Input observer unavailable" }
        if numericReselectionPID != nil && numericReselectionPID == lastForegroundPID {
            return "Select the numeric field again"
        }
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
                self.expireFocusIfNeeded()
                let secure = IsSecureEventInputEnabled()
                if secure != self.secureInput {
                    self.cancelActions(reason: "Secure input changed")
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
        panelDiagnostics.stop()
        inputAreaObserver.configure(pid: nil, enabled: false)
        cancelActions(reason: "App closing")
        focusObserver.stop()
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
        cancelActions(reason: "Session changed")
        sessionAvailable = available
        refreshOutputGate(reason: "Session changed")
        if !available { panelDiagnostics.stop(); device.stop(); deviceStarted = false }
        else { reconcileDevice(); foregroundChanged(NSWorkspace.shared.frontmostApplication) }
    }
    private func foregroundChanged(_ app: NSRunningApplication?) {
        if lastForegroundPID != app?.processIdentifier {
            cancelActions(reason: "Foreground application changed")
            activeControls.removeAll()
        }
        lastForegroundPID = app?.processIdentifier
        output.expectedForegroundPID = app?.processIdentifier
        activeAppName = app?.localizedName ?? "No active app"
        activeBundleID = app?.bundleIdentifier
        panelDiagnostics.foregroundChanged(app)
        observeFocus()
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
        cancelActions(reason: reason)
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
    private func cancelActions(reason: String) {
        panelDiagnostics.note("cancel", reason)
        cancelNumericWork()
        engine.cancelAll(reason: reason)
    }
    private func cancelNumericWork() {
        typedNumericSteps.removeAll()
        typedNumericContext = nil
        typedNumericJob = nil
        focusObserver.cancelNumericAdjustments()
    }
    func recoverDiagnosticKeyState() { output.seedPhysicalState() }
    func startPanelInspection() {
        guard accessibilityAllowed, sessionAvailable, !secureInput else {
            panelInspectionStatus = "Panel inspection requires Accessibility and an unlocked session"
            return
        }
        panelDiagnostics.start()
    }
    func stopPanelInspection() { panelDiagnostics.stop() }
    private func input(_ control: ControlID, down: Bool) {
        reconcileForeground()
        expireFocusIfNeeded()
        if activeBundleID == "app.rive.editor" {
            panelDiagnostics.note("device", "\(control.rawValue) \(down ? "down" : "up") modifiers=\(output.physicalModifiers.rawValue)")
        }
        if down { activeControls.insert(control) } else if !control.isDial { activeControls.remove(control) }
        if control.isDial {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in self?.activeControls.remove(control) }
        }
        guard !IsSecureEventInputEnabled(), output.enabled else { return }
        let area = currentInputArea
        if control.isDial && usesAreaRules &&
            effectiveProfile.matchingRule(for: focusedInput, area: area) == nil {
            if down { record("Dial · select a recognized Rive area") }
            return
        }
        guard let binding = effectiveProfile.binding(for: control, focus: focusedInput,
                                                     area: area) else { return }
        if control.isDial && binding.dialBehavior == .smart {
            if down { smartDial(binding) }
            return
        }
        cancelNumericWork()
        engine.handle(control: control, isDown: down, binding: binding, now: ProcessInfo.processInfo.systemUptime)
    }
    private func smartDial(_ binding: ControlBinding) {
        engine.prepareSmartDial(binding.controlID)
        guard numericReselectionPID == nil || numericReselectionPID != lastForegroundPID else {
            record("Smart · select the numeric field again before turning")
            return
        }
        let modifiers = output.physicalModifiers
        guard let settings = binding.smart,
              let choice = settings.selection(for: modifiers) else {
            cancelNumericWork()
            recordDialDecision(binding.controlID, modifiers: modifiers, shortcut: nil, result: "No matching modifier rule")
            return
        }
        if let shortcut = choice.shortcut {
            cancelNumericWork()
            let sent = output.smartShortcut(shortcut)
            recordDialDecision(binding.controlID, modifiers: modifiers, shortcut: shortcut,
                               result: sent ? "Shortcut sent" : "Shortcut unavailable")
            record(sent ? "Smart · custom shortcut sent" : "Smart · shortcut unavailable")
            return
        }
        let focus = focusedInput
        recordDialDecision(binding.controlID, modifiers: modifiers, shortcut: nil, result: "Numeric selected")
        if focus.kind == .unavailable {
            if settings.fallbackToActions {
                var fallback = binding; fallback.dialBehavior = .perStep
                engine.handle(control: binding.controlID, isDown: true, binding: fallback,
                              now: ProcessInfo.processInfo.systemUptime)
            } else { record("Smart · no identified input; no action") }
            return
        }
        let expectedRevision = revision
        let expectedProfile = effectiveProfile.id
        let expectedPID = lastForegroundPID
        let delta = settings.direction == .increase ? choice.step : -choice.step
        let allowText = SmartDialHeuristics.allowsTextField(focus, detection: settings.detection)
        if settings.writeMethod == .keyboard {
            let context = TypedNumericContext(token: focus.token, revision: expectedRevision,
                profile: expectedProfile, pid: expectedPID, allowText: allowText,
                commitMethod: settings.commitMethod, nativeArrowStep: settings.nativeArrowStep)
            if typedNumericContext != context {
                cancelNumericWork(); typedNumericContext = context
            }
            guard typedNumericSteps.append(delta) else {
                record("Smart · numeric queue full; step not accepted"); return
            }
            drainTypedNumeric()
            return
        }
        if typedNumericContext != nil { cancelNumericWork() }
        focusObserver.adjustNumeric(token: focus.token, delta: delta, allowTextField: allowText) { [weak self] result in
            guard let self else { return }
            self.reconcileForeground()
            guard self.output.enabled, self.revision == expectedRevision,
                  self.effectiveProfile.id == expectedProfile, self.lastForegroundPID == expectedPID,
                  self.focusedInput.token == focus.token else { return }
            switch result {
            case .applied: self.record("Smart · numeric adjustment accepted")
            case .unsupported:
                if settings.fallbackToActions {
                    var fallback = binding
                    fallback.dialBehavior = .perStep
                    self.engine.handle(control: binding.controlID, isDown: true, binding: fallback,
                                       now: ProcessInfo.processInfo.systemUptime)
                    self.record("Smart · configured fallback")
                } else { self.record("Smart · field unavailable; no action") }
            case .cancelled: break
            case .failed: self.record("Smart · app did not confirm adjustment; no fallback sent")
            case .focusRestoreFailed: self.record("Smart · field focus could not be restored")
            case .draftNotConfirmed: self.record("Smart · draft not confirmed; arrow not sent")
            case .arrowCommitNotConfirmed: self.record("Smart · native arrow result not confirmed; stopped")
            case .tabAdvanceNotConfirmed: self.record("Smart · Tab sent; next field not identified; stopped")
            case .tabReturnNotConfirmed: self.record("Smart · Tab return not confirmed; stopped")
            }
        }
    }
    private func drainTypedNumeric() {
        guard typedNumericJob == nil, let context = typedNumericContext,
              let batch = typedNumericSteps.take() else { return }
        let job = UUID(); typedNumericJob = job
        let physicalEpoch = physicalEditingEpoch
        focusObserver.adjustNumeric(token: context.token, delta: batch.delta,
            allowTextField: context.allowText, writeMethod: .keyboard,
            commitMethod: context.commitMethod, nativeArrowStep: context.nativeArrowStep) { [weak self] result in
            guard let self else { return }
            self.reconcileForeground()
            // An AX notification can cancel the job just after a failed Tab
            // transaction ends. Keep the failure latch even in that case,
            // unless real editing input or application/configuration changed.
            if result.needsFieldReselection, self.physicalEditingEpoch == physicalEpoch,
               self.revision == context.revision, self.effectiveProfile.id == context.profile,
               self.lastForegroundPID == context.pid {
                self.numericReselectionPID = context.pid
                self.onStatusChange?()
                if self.typedNumericJob != job {
                    self.cancelNumericWork()
                    self.record("Smart · apply not confirmed; select the numeric field again")
                }
            }
            guard self.typedNumericJob == job else { return }
            guard self.output.enabled, self.typedNumericContext == context,
                  self.revision == context.revision, self.effectiveProfile.id == context.profile,
                  self.lastForegroundPID == context.pid, self.focusedInput.token == context.token else {
                self.cancelNumericWork(); return
            }
            self.typedNumericJob = nil
            switch result {
            case .applied:
                self.record("Smart · numeric text updated (\(batch.detents) detents)")
                self.drainTypedNumeric()
            case .unsupported:
                self.cancelNumericWork(); self.record("Smart · readable numeric text field required")
            case .failed:
                self.cancelNumericWork(); self.record("Smart · text replacement not confirmed; stopped")
            case .focusRestoreFailed:
                self.cancelNumericWork(); self.record("Smart · value submitted; field focus could not be restored")
            case .draftNotConfirmed:
                self.cancelNumericWork(); self.record("Smart · draft not confirmed; arrow not sent")
            case .arrowCommitNotConfirmed:
                self.cancelNumericWork(); self.record("Smart · native arrow result not confirmed; stopped")
            case .tabAdvanceNotConfirmed:
                self.cancelNumericWork(); self.record("Smart · Tab sent; next field not identified; stopped")
            case .tabReturnNotConfirmed:
                self.cancelNumericWork(); self.record("Smart · Tab return not confirmed; stopped")
            case .cancelled: self.cancelNumericWork()
            }
        }
    }
    private func recordDialDecision(_ control: ControlID, modifiers: KeyModifiers, shortcut: SmartShortcut?, result: String) {
        recentDialDecisions.append(["control": control.rawValue, "selectorModifiers": modifiers.rawValue,
                                   "keyCode": shortcut?.keyCode as Any? ?? NSNull(),
                                   "outputModifiers": shortcut?.modifiers.rawValue as Any? ?? NSNull(),
                                   "result": result, "profileId": effectiveProfile.id,
                                   "at": ISO8601DateFormatter().string(from: Date())])
        if recentDialDecisions.count > 8 { recentDialDecisions.removeFirst() }
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
            focusedInput.kind != .secure &&
            accessibilityAllowed && inputAllowed && output.observing && lastForegroundPID != nil &&
            activeBundleID != nil && activeBundleID != Bundle.main.bundleIdentifier
        if output.enabled && !enabled { queuedGroupChange = nil; cancelActions(reason: reason) }
        output.enabled = enabled
        observeFocus()
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
        if (!accessibility || secure) && panelDiagnostics.armed { panelDiagnostics.stop() }
        if secure != secureInput { cancelActions(reason: "Secure input changed"); secureInput = secure }
        let huion = NSWorkspace.shared.runningApplications.contains {
            ($0.bundleIdentifier?.lowercased().contains("huion") == true) ||
            ($0.localizedName?.lowercased().contains("huion") == true)
        }
        if huionRunning != huion { huionRunning = huion }
        if inputAllowed && accessibilityAllowed && !output.observing { output.startObserving() }
        if wasAllowed && !inputAllowed { cancelActions(reason: "Input permission revoked"); output.stopObserving() }
        refreshOutputGate(reason: "Runtime access changed")
        observeFocus()
        reconcileDevice()
    }

    private func observeFocus() {
        let appHasProfile = document.profiles.contains { $0.appBundleIdentifier == activeBundleID && activeBundleID != nil }
        let needsSmart = effectiveGroup.controls.contains { $0.dialBehavior == .smart }
        focusObserver.observe(pid: lastForegroundPID, bundleIdentifier: activeBundleID,
            enabled: accessibilityAllowed && !secureInput && sessionAvailable && (appHasProfile || needsSmart) &&
                activeBundleID != Bundle.main.bundleIdentifier)
        inputAreaObserver.configure(pid: lastForegroundPID,
            enabled: usesAreaRules && output.enabled && accessibilityAllowed && !secureInput && sessionAvailable)
    }
    private func focusChanged(_ snapshot: FocusSnapshot) {
        focusConfirmedAt = ProcessInfo.processInfo.systemUptime
        guard snapshot != focusedInput else { return }
        inputAreaObserver.focusChanged()
        if activeBundleID == "app.rive.editor" {
            panelDiagnostics.note("focus", "\(snapshot.kind.rawValue) · \(snapshot.role ?? "unavailable")")
        }
        cancelActions(reason: "Focused control changed")
        activeControls.removeAll()
        focusedInput = snapshot
        if snapshot.kind != .unavailable && snapshot.kind != .secure {
            lastExternalFocus = snapshot
            lastExternalFocusAt = Date()
        }
        refreshOutputGate(reason: "Focused control changed")
    }
    private func expireFocusIfNeeded() {
        if focusedInput.kind != .unavailable && ProcessInfo.processInfo.systemUptime - focusConfirmedAt > 0.8 {
            focusChanged(FocusSnapshot())
        }
    }
    func saveContextRule(_ rule: FocusRule) throws {
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(rule)) as! [String: Any]
        _ = try configuration.handle(operation: "contextRules.set", arguments: ["profileId": editorProfile.id,
            "rule": object, "expectedRevision": revision])
    }
    func deleteContextRule(_ id: String) { perform("contextRules.delete", ["profileId": editorProfile.id, "ruleId": id]) }
    func moveContextRule(_ id: String, direction: String) { perform("contextRules.move", ["profileId": editorProfile.id, "ruleId": id, "direction": direction]) }
    func icon(for profile: KeydialProfile) -> NSImage? {
        guard let bundle = profile.appBundleIdentifier else { return nil }
        if let icon = appIcons[bundle] { return icon }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        appIcons[bundle] = icon
        return icon
    }
    func selectActiveGroup(_ id: String) { perform("groups.select", ["profileId": effectiveProfile.id, "groupId": id]) }
    private func reconcileDevice() {
        if !huionRunning && !handedToHuion && inputAllowed && sessionAvailable {
            if !deviceStarted { deviceStarted = true; device.start() }
        } else if deviceStarted {
            cancelActions(reason: "Device access suspended")
            device.stop(); deviceStarted = false
        }
    }
    func emergencyRelease() {
        cancelActions(reason: "Emergency release")
        activeControls.removeAll()
        record("All synthesized holds released; pending macros canceled")
    }
    func reconnect() {
        cancelActions(reason: "Reconnect requested")
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
    func selectGroup(_ id: String) { editingContextGroupID = nil; perform("groups.select", ["profileId": editorProfile.id, "groupId": id]) }
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
        candidate.profiles[index].contextRules = []
        editingContextGroupID = nil
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
        cancelActions(reason: "Return to Huion")
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
        case .batteryBucket(let v): value = v; display = v == 100 ? "Full" : "Approx. \(v)%"
        case .brightnessLevel(let v): value = v; display = "Level \(v)"
        case .dormantLevel(let v):
            value = v
            // Huion documents minutes for these four raw timeout values. The
            // fifth firmware value (120) is not mapped to its documented None option.
            if let minutes = [1: 15, 2: 30, 3: 60, 4: 90][v] { display = "\(minutes) min" }
            else { display = "Unmapped timeout (raw 120)" }
        case .rotationDegrees(let v): value = v; display = "\(v)°"
        case .unrecognized: value = nil; display = "Unrecognized"
        }
        deviceSettings[name] = display
        observedSettings[name] = ["availability": value == nil ? "unrecognized" : "available",
                                 "value": value as Any? ?? NSNull(), "observedAt": ISO8601DateFormatter().string(from: Date()),
                                 "raw": response.raw]
    }
    func record(_ event: String) {
        if event.hasPrefix("Smart ·") { panelDiagnostics.note("smart", event) }
        recentEvents.append(event)
        if recentEvents.count > 100 { recentEvents.removeFirst(recentEvents.count - 100) }
    }
    private func handleAgent(_ operation: String, arguments: [String: Any]) throws -> [String: Any] {
        switch operation {
        case "runtime.focus":
            guard Set(arguments.keys).isSubset(of: ["panelCapture"]) else { throw MCPInputError(reason: "Unexpected focus arguments") }
            if let raw = arguments["panelCapture"] {
                guard let command = raw as? String else { throw MCPInputError(reason: "panelCapture must be start or stop") }
                switch command {
                case "start": startPanelInspection()
                case "stop": panelDiagnostics.stop()
                default: throw MCPInputError(reason: "panelCapture must be start or stop")
                }
            }
            expireFocusIfNeeded()
            let current = try JSONSerialization.jsonObject(with: JSONEncoder().encode(focusedInput))
            let last: Any = try lastExternalFocus.map { try JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) } ?? NSNull()
            return ["current": current, "lastObserved": last, "rivePanelDiagnostics": panelDiagnostics.read(),
                    "area": currentInputArea?.rawValue as Any? ?? NSNull(), "areaStatus": inputAreaStatus,
                    "lastObservedAt": lastExternalFocusAt.map { ISO8601DateFormatter().string(from: $0) } as Any? ?? NSNull(),
                    "matchedRuleId": activeContextRule?.id as Any? ?? NSNull(),
                    "dialGroupId": activeContextRule?.targetGroupID ?? effectiveGroup.id,
                    "note": "Field contents are not exposed. Opt-in Rive area detection checks only whether focused nonsecure text is numeric; values stay inside the AX worker. Last observed is historical, not the current routing target."]
        case "runtime.get":
            guard arguments.isEmpty else { throw MCPInputError(reason: "Unexpected runtime arguments") }
            return ["revision": revision, "activeApp": activeAppName,
                    "activeBundleIdentifier": activeBundleID as Any? ?? NSNull(),
                    "effectiveProfileId": effectiveProfile.id, "effectiveGroupId": effectiveGroup.id,
                    "lockedProfileId": lockedProfileID as Any? ?? NSNull(), "paused": paused,
                    "dialDiagnostics": ["physicalModifiers": output.physicalModifiers.rawValue,
                                        "recentDecisions": recentDialDecisions,
                                        "recentSmartEvents": Array(recentEvents.filter { $0.hasPrefix("Smart ·") }.suffix(20))],
                    "outputStatus": outputStatus, "device": ["state": connection, "transport": transport, "ready": ready],
                    "inputArea": currentInputArea?.rawValue as Any? ?? NSNull(), "inputAreaStatus": inputAreaStatus,
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
