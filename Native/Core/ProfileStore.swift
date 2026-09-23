import Foundation

enum ProfileStoreError: Error, LocalizedError, Equatable {
    case invalid(String)
    case unsupportedSchema(Int)
    case fileTooLarge
    case primaryMissingBackupAvailable

    var errorDescription: String? {
        switch self {
        case let .invalid(reason): "Invalid Keydial profiles: \(reason)"
        case let .unsupportedSchema(version): "Unsupported Keydial profile schema version \(version)."
        case .fileTooLarge: "The profile file exceeds the 8 MB limit."
        case .primaryMissingBackupAvailable: "The primary profile file is missing, but a backup is available. Restore it explicitly."
        }
    }
}

/// Synchronous, Foundation-only persistence. Callers serialize edits and saves on one queue.
struct ProfileStore {
    static let maximumFileBytes = 8 * 1024 * 1024
    let directoryURL: URL

    init(directoryURL: URL? = nil) {
        if let directoryURL {
            self.directoryURL = directoryURL
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.directoryURL = support.appendingPathComponent("KeydialStudio", isDirectory: true)
        }
    }

    var fileURL: URL { directoryURL.appendingPathComponent("profiles.json") }
    var backupURL: URL { directoryURL.appendingPathComponent("profiles.json.bak") }

    /// Returns a safe, blank document only when no profile data exists at all.
    func load() throws -> KeydialDocument {
        let manager = FileManager.default
        if !manager.fileExists(atPath: fileURL.path) {
            if manager.fileExists(atPath: backupURL.path) {
                throw ProfileStoreError.primaryMissingBackupAvailable
            }
            return KeydialDocument()
        }
        return try read(fileURL)
    }

    func loadBackup() throws -> KeydialDocument { try read(backupURL) }

    /// Existing primary data must be valid before a new write can rotate it to backup.
    /// A damaged file is left untouched for diagnosis or explicit recovery.
    func save(_ document: KeydialDocument) throws {
        try validate(document)
        let encoded = try encode(document)
        let manager = FileManager.default
        try manager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        if manager.fileExists(atPath: fileURL.path) {
            let existing = try limitedData(from: fileURL)
            _ = try decode(existing)
            try existing.write(to: backupURL, options: .atomic)
        }
        try encoded.write(to: fileURL, options: .atomic)
    }

    /// Restores the validated backup without rotating a corrupt primary over it.
    func restoreBackup() throws -> KeydialDocument {
        let document = try loadBackup()
        let encoded = try encode(document)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try encoded.write(to: fileURL, options: .atomic)
        return document
    }

    /// Import returns a candidate. The caller may review it before calling save.
    func importDocument(from url: URL) throws -> KeydialDocument { try read(url) }

    func exportDocument(_ document: KeydialDocument, to url: URL) throws {
        try validate(document)
        try encode(document).write(to: url, options: .atomic)
    }

    func validate(_ document: KeydialDocument) throws {
        guard document.schemaVersion == KeydialDocument.currentSchemaVersion else {
            throw ProfileStoreError.unsupportedSchema(document.schemaVersion)
        }
        guard (1...128).contains(document.profiles.count) else { throw invalid("profile count must be 1...128") }
        guard validID(document.globalProfileID) else { throw invalid("global profile ID") }
        var profileIDs = Set<String>()
        var bundleIDs = Set<String>()
        var globalCount = 0
        for profile in document.profiles {
            guard validID(profile.id), profileIDs.insert(profile.id).inserted else {
                throw invalid("empty or duplicate profile ID")
            }
            guard validName(profile.name) else { throw invalid("profile name in \(profile.id)") }
            if profile.id == document.globalProfileID {
                globalCount += 1
                guard profile.appBundleIdentifier == nil else { throw invalid("global profile cannot target an app") }
            } else {
                guard let bundle = profile.appBundleIdentifier, validBundleID(bundle), bundleIDs.insert(bundle).inserted else {
                    throw invalid("missing, malformed, or duplicate app bundle identifier in \(profile.id)")
                }
            }
            guard profile.groups.count == 6 else { throw invalid("profile \(profile.id) must have exactly six groups") }
            var groupIDs = Set<String>()
            for group in profile.groups {
                guard validID(group.id), groupIDs.insert(group.id).inserted else {
                    throw invalid("empty or duplicate group ID in \(profile.id)")
                }
                guard validGroupName(group.name) else { throw invalid("group name in \(profile.id) exceeds 58 UTF-16LE bytes or is empty") }
                guard group.controls.count == ControlID.allCases.count else {
                    throw invalid("group \(group.id) must map all \(ControlID.allCases.count) controls")
                }
                var controls = Set<ControlID>()
                for binding in group.controls {
                    guard controls.insert(binding.controlID).inserted else {
                        throw invalid("duplicate control \(binding.controlID.rawValue) in \(group.id)")
                    }
                    try validate(binding)
                }
            }
            guard groupIDs.contains(profile.selectedGroupID) else {
                throw invalid("selected group missing in \(profile.id)")
            }
            guard profile.contextRules.count <= 32 else {
                throw invalid("profile \(profile.id) has more than 32 focus rules")
            }
            if profile.id == document.globalProfileID && !profile.contextRules.isEmpty {
                throw invalid("global profile cannot have focus rules")
            }
            var ruleIDs = Set<String>()
            for rule in profile.contextRules {
                guard validID(rule.id), ruleIDs.insert(rule.id).inserted else {
                    throw invalid("empty, malformed, or duplicate focus rule ID in \(profile.id)")
                }
                guard validName(rule.name) else { throw invalid("focus rule name in \(profile.id)") }
                guard groupIDs.contains(rule.targetGroupID) else {
                    throw invalid("focus rule \(rule.id) targets a missing group")
                }
                guard rule.hasCriterion else {
                    throw invalid("focus rule \(rule.id) needs a kind, role, identifier, or label criterion")
                }
                if let kind = rule.kind, kind == .secure || kind == .unavailable {
                    throw invalid("focus rule \(rule.id) cannot target a secure or unavailable field")
                }
                guard validCriterion(rule.role, maximumBytes: 128),
                      validCriterion(rule.identifier, maximumBytes: 256),
                      validCriterion(rule.labelContains, maximumBytes: 160) else {
                    throw invalid("focus rule \(rule.id) has an empty or oversized criterion")
                }
            }
        }
        guard globalCount == 1 else { throw invalid("global fallback profile is missing") }
    }

    private func validate(_ binding: ControlBinding) throws {
        guard binding.label.utf16.count * 2 <= 56, !binding.label.contains("\0") else {
            throw invalid("control label in \(binding.controlID.rawValue) exceeds 56 UTF-16LE bytes")
        }
        guard binding.pressActions.count <= 64, binding.releaseActions.count <= 64 else {
            throw invalid("too many action steps in \(binding.controlID.rawValue)")
        }
        guard (1...32).contains(binding.queueLimit) else {
            throw invalid("macro queue limit must be 1...32 in \(binding.controlID.rawValue)")
        }
        guard (1...100).contains(binding.macroRepeatCount) else {
            throw invalid("macro repeat count must be 1...100 in \(binding.controlID.rawValue)")
        }
        guard (20...5_000).contains(binding.repeatIntervalMilliseconds),
              (20...5_000).contains(binding.idleTimeoutMilliseconds) else {
            throw invalid("repeat interval or dial idle timeout in \(binding.controlID.rawValue)")
        }
        guard binding.heldModifiers.subtracting(.supported).isEmpty else {
            throw invalid("unsupported held modifier in \(binding.controlID.rawValue)")
        }
        if !binding.controlID.isDial && binding.dialBehavior != .perStep {
            throw invalid("dial behavior on button \(binding.controlID.rawValue)")
        }
        if binding.controlID.isDial && binding.buttonBehavior != .pressRelease {
            throw invalid("button behavior on dial \(binding.controlID.rawValue)")
        }
        if binding.dialBehavior == .smart && binding.smart == nil {
            throw invalid("smart dial settings are missing in \(binding.controlID.rawValue)")
        }
        // Dormant settings must remain valid so switching modes cannot activate
        // malformed shortcuts or numeric steps from a previously saved draft.
        if let smart = binding.smart { try validate(smart, for: binding.controlID) }
        for step in binding.pressActions + binding.releaseActions { try validate(step) }
        let expandedSteps = (binding.pressActions + binding.releaseActions).reduce(0) { $0 + $1.repeatCount }
        guard expandedSteps * binding.macroRepeatCount <= 10_000 else {
            throw invalid("expanded macro exceeds 10000 steps in \(binding.controlID.rawValue)")
        }
    }

    private func validate(_ smart: SmartDialSettings, for control: ControlID) throws {
        guard smart.writeMethod != .keyboard || !smart.fallbackToActions else {
            throw ProfileStoreError.invalid("Keyboard numeric input cannot use fallback actions")
        }
        guard validSmartStep(smart.step) else {
            throw invalid("smart step must be finite and 0.000001...1000000 in \(control.rawValue)")
        }
        if let shortcut = smart.shortcut { try validate(shortcut, for: control) }
        guard smart.modifierRules.count <= 8 else {
            throw invalid("smart dial has more than eight modifier rules in \(control.rawValue)")
        }
        var ids = Set<String>()
        var triggers = Set<KeyModifiers>()
        for rule in smart.modifierRules {
            guard validID(rule.id), ids.insert(rule.id).inserted else {
                throw invalid("smart modifier rule ID is malformed or duplicated in \(control.rawValue)")
            }
            guard (1...60).contains(rule.name.count), rule.name.utf8.count <= 120,
                  !rule.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !rule.name.contains("\0") else {
                throw invalid("smart modifier rule name is empty or too long in \(control.rawValue)")
            }
            guard !rule.modifiers.isEmpty,
                  rule.modifiers.subtracting(.supported).isEmpty,
                  triggers.insert(rule.modifiers).inserted else {
                throw invalid("smart modifier trigger is empty, unsupported, or duplicated in \(control.rawValue)")
            }
            guard validSmartStep(rule.step) else {
                throw invalid("smart modifier step must be finite and 0.000001...1000000 in \(control.rawValue)")
            }
            if let shortcut = rule.shortcut { try validate(shortcut, for: control) }
        }
    }

    private func validate(_ shortcut: SmartShortcut, for control: ControlID) throws {
        guard shortcut.keyCode <= 255, (1...100).contains(shortcut.repeatCount),
              shortcut.modifiers.subtracting(.supported).isEmpty else {
            throw invalid("smart shortcut key, modifiers, or repeat count in \(control.rawValue)")
        }
    }

    private func validSmartStep(_ step: Double) -> Bool {
        step.isFinite && (0.000_001...1_000_000).contains(step)
    }

    private func validate(_ step: ActionStep) throws {
        guard (1...100).contains(step.repeatCount) else { throw invalid("action repeat count must be 1...100") }
        switch step.operation {
        case let .keyDown(code, modifiers), let .keyUp(code, modifiers), let .keyTap(code, modifiers):
            guard code <= 255, modifiers.subtracting(.supported).isEmpty else {
                throw invalid("key code or modifiers")
            }
        case let .chord(codes, modifiers):
            guard (1...8).contains(codes.count), Set(codes).count == codes.count,
                  codes.allSatisfy({ $0 <= 255 }), modifiers.subtracting(.supported).isEmpty else {
                throw invalid("chord keys or modifiers")
            }
        case let .text(value):
            guard !value.isEmpty, value.utf8.count <= 1_024, !value.contains("\0") else {
                throw invalid("text action must be 1...1024 UTF-8 bytes")
            }
        case let .delay(milliseconds):
            guard (0...60_000).contains(milliseconds) else { throw invalid("delay must be 0...60000 ms") }
        case .mouseButtonDown, .mouseButtonUp, .mouseClick, .media: break
        case let .scroll(horizontal, vertical):
            guard (-1_200...1_200).contains(horizontal), (-1_200...1_200).contains(vertical),
                  horizontal != 0 || vertical != 0 else { throw invalid("scroll amount") }
        case let .groupChange(offset):
            guard (-5...5).contains(offset), offset != 0 else { throw invalid("group change offset must be -5...-1 or 1...5") }
        }
    }

    private func read(_ url: URL) throws -> KeydialDocument { try decode(limitedData(from: url)) }

    private func limitedData(from url: URL) throws -> Data {
        let data = try Data(contentsOf: url)
        guard data.count <= Self.maximumFileBytes else { throw ProfileStoreError.fileTooLarge }
        return data
    }

    private func decode(_ data: Data) throws -> KeydialDocument {
        // Decode the version before the full graph so future formats report a precise error.
        struct Header: Decodable { let schemaVersion: Int }
        let decoder = JSONDecoder()
        let version = try decoder.decode(Header.self, from: data).schemaVersion
        guard version == KeydialDocument.currentSchemaVersion else { throw ProfileStoreError.unsupportedSchema(version) }
        let document = try decoder.decode(KeydialDocument.self, from: data)
        try validate(document)
        return document
    }

    private func encode(_ document: KeydialDocument) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(document)
        guard data.count <= Self.maximumFileBytes else { throw ProfileStoreError.fileTooLarge }
        return data
    }

    private func validID(_ id: String) -> Bool {
        guard (1...80).contains(id.utf8.count) else { return false }
        return id.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.").contains($0)
        }
    }

    private func validName(_ name: String) -> Bool {
        (1...80).contains(name.utf8.count) && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !name.contains("\0")
    }

    private func validCriterion(_ value: String?, maximumBytes: Int) -> Bool {
        guard let value else { return true }
        return (1...maximumBytes).contains(value.utf8.count) &&
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !value.contains("\0")
    }

    private func validGroupName(_ name: String) -> Bool {
        (1...58).contains(name.utf16.count * 2) &&
            !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !name.contains("\0")
    }

    private func validBundleID(_ id: String) -> Bool {
        id.contains(".") && validID(id) && !id.hasPrefix(".") && !id.hasSuffix(".") && !id.contains("..")
    }

    private func invalid(_ reason: String) -> ProfileStoreError { .invalid(reason) }
}
