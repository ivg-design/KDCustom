import Foundation

enum ControlID: String, Codable, CaseIterable, Sendable {
    case key1, key2, key3, key4, key5, key6, key7, key8
    case setPrevious, setNext
    case dial1CW, dial1CCW, dial2CW, dial2CCW

    var isDial: Bool {
        switch self {
        case .dial1CW, .dial1CCW, .dial2CW, .dial2CCW: true
        default: false
        }
    }
}

struct KeyModifiers: OptionSet, Codable, Hashable, Sendable {
    let rawValue: UInt64

    init(rawValue: UInt64) { self.rawValue = rawValue }

    // These values match CGEventFlags, without importing CoreGraphics into the model.
    static let shift = Self(rawValue: 0x0002_0000)
    static let control = Self(rawValue: 0x0004_0000)
    static let option = Self(rawValue: 0x0008_0000)
    static let command = Self(rawValue: 0x0010_0000)
    static let function = Self(rawValue: 0x0080_0000)
    static let supported: Self = [.shift, .control, .option, .command, .function]
}

enum MouseButton: String, Codable, Sendable { case left, right, middle }
enum MediaKey: String, Codable, Sendable {
    case playPause, nextTrack, previousTrack, volumeUp, volumeDown, mute
}
enum ButtonBehavior: String, Codable, Sendable {
    case pressRelease, hold, toggle, repeatWhileHeld
}
enum DialBehavior: String, Codable, Sendable {
    case perStep, heldModifiers, smart
}
enum MacroRetriggerPolicy: String, Codable, Sendable {
    case queue, restart, ignoreWhileRunning
}

enum SmartDialDirection: String, Codable, Sendable { case increase, decrease }
enum SmartDialDetection: String, Codable, Sendable { case automatic, numericField }

struct SmartShortcut: Codable, Equatable, Sendable {
    var keyCode: UInt16
    var modifiers: KeyModifiers
    var repeatCount: Int

    init(keyCode: UInt16, modifiers: KeyModifiers = [], repeatCount: Int = 1) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.repeatCount = repeatCount
    }

    private enum CodingKeys: String, CodingKey { case keyCode, modifiers, repeatCount }
    init(from decoder: Decoder) throws {
        let data = try decoder.container(keyedBy: CodingKeys.self)
        keyCode = try data.decode(UInt16.self, forKey: .keyCode)
        modifiers = try data.decodeIfPresent(KeyModifiers.self, forKey: .modifiers) ?? []
        repeatCount = try data.decodeIfPresent(Int.self, forKey: .repeatCount) ?? 1
    }
}

struct SmartModifierRule: Codable, Equatable, Sendable {
    var id: String
    var name: String
    /// Exact physical modifier set required to select this rule.
    var modifiers: KeyModifiers
    var step: Double
    /// Nil inherits the setting's base shortcut, if any.
    var shortcut: SmartShortcut?

    init(id: String = UUID().uuidString, name: String, modifiers: KeyModifiers,
         step: Double, shortcut: SmartShortcut? = nil) {
        self.id = id
        self.name = name
        self.modifiers = modifiers
        self.step = step
        self.shortcut = shortcut
    }
}

struct SmartDialSelection: Equatable, Sendable {
    var step: Double
    var shortcut: SmartShortcut?
}

struct SmartDialSettings: Codable, Equatable, Sendable {
    var direction: SmartDialDirection
    var detection: SmartDialDetection
    var step: Double
    var shortcut: SmartShortcut?
    var modifierRules: [SmartModifierRule]
    var fallbackToActions: Bool

    init(direction: SmartDialDirection = .increase,
         detection: SmartDialDetection = .automatic,
         step: Double = 1,
         shortcut: SmartShortcut? = nil,
         modifierRules: [SmartModifierRule] = [
            .init(id: "option", name: "Fine", modifiers: .option, step: 0.01),
            .init(id: "shift", name: "Coarse", modifiers: .shift, step: 10)
         ],
         fallbackToActions: Bool = false) {
        self.direction = direction
        self.detection = detection
        self.step = step
        self.shortcut = shortcut
        self.modifierRules = modifierRules
        self.fallbackToActions = fallbackToActions
    }

    private enum CodingKeys: String, CodingKey {
        case direction, detection, step, shortcut, modifierRules, fallbackToActions
    }
    init(from decoder: Decoder) throws {
        let data = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Self()
        direction = try data.decodeIfPresent(SmartDialDirection.self, forKey: .direction) ?? defaults.direction
        detection = try data.decodeIfPresent(SmartDialDetection.self, forKey: .detection) ?? defaults.detection
        step = try data.decodeIfPresent(Double.self, forKey: .step) ?? defaults.step
        shortcut = try data.decodeIfPresent(SmartShortcut.self, forKey: .shortcut)
        modifierRules = try data.decodeIfPresent([SmartModifierRule].self, forKey: .modifierRules) ?? defaults.modifierRules
        fallbackToActions = try data.decodeIfPresent(Bool.self, forKey: .fallbackToActions) ?? defaults.fallbackToActions
    }

    /// Unsupported combinations are deliberately inert; they never degrade to
    /// the base action or a partially matching modifier rule.
    func selection(for physicalModifiers: KeyModifiers) -> SmartDialSelection? {
        guard physicalModifiers.subtracting(.supported).isEmpty else { return nil }
        if physicalModifiers.isEmpty { return SmartDialSelection(step: step, shortcut: shortcut) }
        guard let rule = modifierRules.first(where: { $0.modifiers == physicalModifiers }) else { return nil }
        return SmartDialSelection(step: rule.step, shortcut: rule.shortcut ?? shortcut)
    }
}

/// One action repeated a finite number of times. A sequence is a flat array of steps.
struct ActionStep: Codable, Equatable, Sendable {
    enum Operation: Equatable, Sendable {
        case keyDown(keyCode: UInt16, modifiers: KeyModifiers)
        case keyUp(keyCode: UInt16, modifiers: KeyModifiers)
        case keyTap(keyCode: UInt16, modifiers: KeyModifiers)
        case chord(keyCodes: [UInt16], modifiers: KeyModifiers)
        case text(String)
        case delay(milliseconds: Int)
        case mouseButtonDown(MouseButton)
        case mouseButtonUp(MouseButton)
        case mouseClick(MouseButton)
        case scroll(horizontal: Int, vertical: Int)
        case media(MediaKey)
        case groupChange(offset: Int)
    }

    var operation: Operation
    var repeatCount: Int

    init(_ operation: Operation, repeatCount: Int = 1) {
        self.operation = operation
        self.repeatCount = repeatCount
    }

    static func keyTap(_ code: UInt16, modifiers: KeyModifiers = [], repeatCount: Int = 1) -> Self {
        .init(.keyTap(keyCode: code, modifiers: modifiers), repeatCount: repeatCount)
    }

    static func chord(_ codes: [UInt16], modifiers: KeyModifiers = [], repeatCount: Int = 1) -> Self {
        .init(.chord(keyCodes: codes, modifiers: modifiers), repeatCount: repeatCount)
    }

    private enum CodingKeys: String, CodingKey {
        case kind, repeatCount, keyCode, keyCodes, modifiers, text, milliseconds
        case mouseButton, horizontal, vertical, mediaKey, offset
    }
    private enum Kind: String, Codable {
        case keyDown, keyUp, keyTap, chord, text, delay
        case mouseButtonDown, mouseButtonUp, mouseClick, scroll, media, groupChange
    }

    init(from decoder: Decoder) throws {
        let data = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try data.decode(Kind.self, forKey: .kind)
        repeatCount = try data.decode(Int.self, forKey: .repeatCount)
        switch kind {
        case .keyDown:
            operation = .keyDown(keyCode: try data.decode(UInt16.self, forKey: .keyCode),
                                 modifiers: try data.decode(KeyModifiers.self, forKey: .modifiers))
        case .keyUp:
            operation = .keyUp(keyCode: try data.decode(UInt16.self, forKey: .keyCode),
                               modifiers: try data.decode(KeyModifiers.self, forKey: .modifiers))
        case .keyTap:
            operation = .keyTap(keyCode: try data.decode(UInt16.self, forKey: .keyCode),
                                modifiers: try data.decode(KeyModifiers.self, forKey: .modifiers))
        case .chord:
            operation = .chord(keyCodes: try data.decode([UInt16].self, forKey: .keyCodes),
                               modifiers: try data.decode(KeyModifiers.self, forKey: .modifiers))
        case .text: operation = .text(try data.decode(String.self, forKey: .text))
        case .delay: operation = .delay(milliseconds: try data.decode(Int.self, forKey: .milliseconds))
        case .mouseButtonDown:
            operation = .mouseButtonDown(try data.decode(MouseButton.self, forKey: .mouseButton))
        case .mouseButtonUp:
            operation = .mouseButtonUp(try data.decode(MouseButton.self, forKey: .mouseButton))
        case .mouseClick:
            operation = .mouseClick(try data.decode(MouseButton.self, forKey: .mouseButton))
        case .scroll:
            operation = .scroll(horizontal: try data.decode(Int.self, forKey: .horizontal),
                                vertical: try data.decode(Int.self, forKey: .vertical))
        case .media: operation = .media(try data.decode(MediaKey.self, forKey: .mediaKey))
        case .groupChange: operation = .groupChange(offset: try data.decode(Int.self, forKey: .offset))
        }
    }

    func encode(to encoder: Encoder) throws {
        var data = encoder.container(keyedBy: CodingKeys.self)
        try data.encode(repeatCount, forKey: .repeatCount)
        switch operation {
        case let .keyDown(code, modifiers):
            try data.encode(Kind.keyDown, forKey: .kind)
            try data.encode(code, forKey: .keyCode)
            try data.encode(modifiers, forKey: .modifiers)
        case let .keyUp(code, modifiers):
            try data.encode(Kind.keyUp, forKey: .kind)
            try data.encode(code, forKey: .keyCode)
            try data.encode(modifiers, forKey: .modifiers)
        case let .keyTap(code, modifiers):
            try data.encode(Kind.keyTap, forKey: .kind)
            try data.encode(code, forKey: .keyCode)
            try data.encode(modifiers, forKey: .modifiers)
        case let .chord(codes, modifiers):
            try data.encode(Kind.chord, forKey: .kind)
            try data.encode(codes, forKey: .keyCodes)
            try data.encode(modifiers, forKey: .modifiers)
        case let .text(value):
            try data.encode(Kind.text, forKey: .kind)
            try data.encode(value, forKey: .text)
        case let .delay(milliseconds):
            try data.encode(Kind.delay, forKey: .kind)
            try data.encode(milliseconds, forKey: .milliseconds)
        case let .mouseButtonDown(button):
            try data.encode(Kind.mouseButtonDown, forKey: .kind)
            try data.encode(button, forKey: .mouseButton)
        case let .mouseButtonUp(button):
            try data.encode(Kind.mouseButtonUp, forKey: .kind)
            try data.encode(button, forKey: .mouseButton)
        case let .mouseClick(button):
            try data.encode(Kind.mouseClick, forKey: .kind)
            try data.encode(button, forKey: .mouseButton)
        case let .scroll(horizontal, vertical):
            try data.encode(Kind.scroll, forKey: .kind)
            try data.encode(horizontal, forKey: .horizontal)
            try data.encode(vertical, forKey: .vertical)
        case let .media(key):
            try data.encode(Kind.media, forKey: .kind)
            try data.encode(key, forKey: .mediaKey)
        case let .groupChange(offset):
            try data.encode(Kind.groupChange, forKey: .kind)
            try data.encode(offset, forKey: .offset)
        }
    }
}

struct ControlBinding: Codable, Equatable, Sendable {
    var controlID: ControlID
    var label: String
    var pressActions: [ActionStep]
    var releaseActions: [ActionStep]
    var buttonBehavior: ButtonBehavior
    var dialBehavior: DialBehavior
    var repeatIntervalMilliseconds: Int
    var heldModifiers: KeyModifiers
    var idleTimeoutMilliseconds: Int
    var macroRetriggerPolicy: MacroRetriggerPolicy
    var queueLimit: Int
    var macroRepeatCount: Int
    var smart: SmartDialSettings?

    init(controlID: ControlID, label: String = "", pressActions: [ActionStep] = [],
         releaseActions: [ActionStep] = [], buttonBehavior: ButtonBehavior = .pressRelease,
         dialBehavior: DialBehavior = .perStep, repeatIntervalMilliseconds: Int = 100,
         heldModifiers: KeyModifiers = [], idleTimeoutMilliseconds: Int = 250,
         macroRetriggerPolicy: MacroRetriggerPolicy = .queue, queueLimit: Int = 8,
         macroRepeatCount: Int = 1, smart: SmartDialSettings? = nil) {
        self.controlID = controlID
        self.label = label
        self.pressActions = pressActions
        self.releaseActions = releaseActions
        self.buttonBehavior = buttonBehavior
        self.dialBehavior = dialBehavior
        self.repeatIntervalMilliseconds = repeatIntervalMilliseconds
        self.heldModifiers = heldModifiers
        self.idleTimeoutMilliseconds = idleTimeoutMilliseconds
        self.macroRetriggerPolicy = macroRetriggerPolicy
        self.queueLimit = queueLimit
        self.macroRepeatCount = macroRepeatCount
        self.smart = smart
    }

    private enum CodingKeys: String, CodingKey {
        case controlID, label, pressActions, releaseActions, buttonBehavior, dialBehavior
        case repeatIntervalMilliseconds, heldModifiers, idleTimeoutMilliseconds
        case macroRetriggerPolicy, queueLimit, macroRepeatCount, smart
    }

    init(from decoder: Decoder) throws {
        let data = try decoder.container(keyedBy: CodingKeys.self)
        controlID = try data.decode(ControlID.self, forKey: .controlID)
        label = try data.decode(String.self, forKey: .label)
        pressActions = try data.decode([ActionStep].self, forKey: .pressActions)
        releaseActions = try data.decode([ActionStep].self, forKey: .releaseActions)
        buttonBehavior = try data.decode(ButtonBehavior.self, forKey: .buttonBehavior)
        dialBehavior = try data.decode(DialBehavior.self, forKey: .dialBehavior)
        repeatIntervalMilliseconds = try data.decode(Int.self, forKey: .repeatIntervalMilliseconds)
        heldModifiers = try data.decode(KeyModifiers.self, forKey: .heldModifiers)
        idleTimeoutMilliseconds = try data.decode(Int.self, forKey: .idleTimeoutMilliseconds)
        // Schema 1 files predating macro scheduling retain their original behavior.
        macroRetriggerPolicy = try data.decodeIfPresent(MacroRetriggerPolicy.self, forKey: .macroRetriggerPolicy) ?? .queue
        queueLimit = try data.decodeIfPresent(Int.self, forKey: .queueLimit) ?? 8
        macroRepeatCount = try data.decodeIfPresent(Int.self, forKey: .macroRepeatCount) ?? 1
        smart = try data.decodeIfPresent(SmartDialSettings.self, forKey: .smart)
    }
}

struct KeydialGroup: Codable, Equatable, Sendable {
    var id: String
    var name: String
    var controls: [ControlBinding]

    init(id: String, name: String, controls: [ControlBinding] = ControlID.allCases.map { controlID in
        switch controlID {
        case .setPrevious:
            ControlBinding(controlID: controlID, pressActions: [.init(.groupChange(offset: -1))])
        case .setNext:
            ControlBinding(controlID: controlID, pressActions: [.init(.groupChange(offset: 1))])
        default:
            ControlBinding(controlID: controlID)
        }
    }) {
        self.id = id
        self.name = name
        self.controls = controls
    }

    func binding(for controlID: ControlID) -> ControlBinding? {
        controls.first { $0.controlID == controlID }
    }
}

enum FocusKind: String, Codable, CaseIterable, Sendable {
    case unavailable, secure, numeric, text, other
}

/// Only focus metadata used for rule selection. Field values and selected text
/// never enter the profile document or the runtime snapshot.
struct FocusSnapshot: Codable, Equatable, Sendable {
    var token: String
    var bundleIdentifier: String?
    var role: String?
    var subrole: String?
    var identifier: String?
    var label: String?
    var kind: FocusKind

    init(token: String = UUID().uuidString, bundleIdentifier: String? = nil,
         role: String? = nil, subrole: String? = nil, identifier: String? = nil,
         label: String? = nil, kind: FocusKind = .unavailable) {
        self.token = token
        self.bundleIdentifier = bundleIdentifier
        self.role = role
        self.subrole = subrole
        self.identifier = identifier
        self.label = label
        self.kind = kind
    }
}

struct FocusRule: Codable, Equatable, Sendable {
    var id: String
    var name: String
    var enabled: Bool
    var targetGroupID: String
    var kind: FocusKind?
    var role: String?
    var identifier: String?
    var labelContains: String?

    init(id: String = UUID().uuidString, name: String, enabled: Bool = true,
         targetGroupID: String, kind: FocusKind? = nil, role: String? = nil,
         identifier: String? = nil, labelContains: String? = nil) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.targetGroupID = targetGroupID
        self.kind = kind
        self.role = role
        self.identifier = identifier
        self.labelContains = labelContains
    }

    var hasCriterion: Bool {
        kind != nil || role != nil || identifier != nil || labelContains != nil
    }

    func matches(_ snapshot: FocusSnapshot) -> Bool {
        guard enabled, snapshot.kind != .unavailable, snapshot.kind != .secure,
              hasCriterion else { return false }
        if let kind, kind != snapshot.kind { return false }
        if let role, role != snapshot.role { return false }
        if let identifier, identifier != snapshot.identifier { return false }
        if let labelContains {
            guard let label = snapshot.label,
                  label.range(of: labelContains, options: [.caseInsensitive, .diacriticInsensitive]) != nil else {
                return false
            }
        }
        return true
    }
}

struct KeydialProfile: Codable, Equatable, Sendable {
    var id: String
    var name: String
    /// Nil for the global fallback. Non-nil profiles match this exact bundle identifier.
    var appBundleIdentifier: String?
    var selectedGroupID: String
    var groups: [KeydialGroup]
    var contextRules: [FocusRule]

    init(id: String = UUID().uuidString, name: String, appBundleIdentifier: String? = nil,
         selectedGroupID: String = "group-1", groups: [KeydialGroup] = (1...6).map { KeydialGroup(id: "group-\($0)", name: "Group \($0)") },
         contextRules: [FocusRule] = []) {
        self.id = id
        self.name = name
        self.appBundleIdentifier = appBundleIdentifier
        self.selectedGroupID = selectedGroupID
        self.groups = groups
        self.contextRules = contextRules
    }

    var selectedGroup: KeydialGroup? { groups.first { $0.id == selectedGroupID } }

    /// Rule order is priority. Only an exact app profile can override its four
    /// dial bindings; the selected group's button bindings remain authoritative.
    func matchingRule(for snapshot: FocusSnapshot) -> FocusRule? {
        guard let appBundleIdentifier, snapshot.bundleIdentifier == appBundleIdentifier,
              snapshot.kind != .secure, snapshot.kind != .unavailable else { return nil }
        return contextRules.first { $0.matches(snapshot) }
    }

    func binding(for control: ControlID, focus: FocusSnapshot) -> ControlBinding? {
        let normal = selectedGroup?.binding(for: control)
        guard control.isDial, let rule = matchingRule(for: focus),
              let group = groups.first(where: { $0.id == rule.targetGroupID }) else { return normal }
        return group.binding(for: control) ?? normal
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, appBundleIdentifier, selectedGroupID, groups, contextRules
    }

    init(from decoder: Decoder) throws {
        let data = try decoder.container(keyedBy: CodingKeys.self)
        id = try data.decode(String.self, forKey: .id)
        name = try data.decode(String.self, forKey: .name)
        appBundleIdentifier = try data.decodeIfPresent(String.self, forKey: .appBundleIdentifier)
        selectedGroupID = try data.decode(String.self, forKey: .selectedGroupID)
        groups = try data.decode([KeydialGroup].self, forKey: .groups)
        contextRules = try data.decodeIfPresent([FocusRule].self, forKey: .contextRules) ?? []
    }
}

struct KeydialDocument: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1
    var schemaVersion: Int
    var globalProfileID: String
    var profiles: [KeydialProfile]

    init(schemaVersion: Int = Self.currentSchemaVersion, globalProfileID: String = "global",
         profiles: [KeydialProfile] = [KeydialProfile(id: "global", name: "Global")]) {
        self.schemaVersion = schemaVersion
        self.globalProfileID = globalProfileID
        self.profiles = profiles
    }

    var globalProfile: KeydialProfile? { profiles.first { $0.id == globalProfileID } }

    /// Pure profile lookup. A runtime manual lock takes precedence; editing does not activate a profile.
    func effectiveProfile(bundleIdentifier: String?, lockedProfileID: String? = nil) -> KeydialProfile? {
        if let lockedProfileID, let locked = profiles.first(where: { $0.id == lockedProfileID }) { return locked }
        if let bundleIdentifier,
           let match = profiles.first(where: { $0.appBundleIdentifier == bundleIdentifier }) { return match }
        return globalProfile
    }
}
