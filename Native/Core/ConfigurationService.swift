import Foundation

enum ConfigurationServiceError: Error, LocalizedError, Equatable {
    case staleRevision
    case invalid(String)
    case notFound(String)
    case protectedGlobalProfile
    case unsupportedOperation(String)
    case reentrantMutation

    var errorDescription: String? {
        switch self {
        case .staleRevision:
            "Configuration changed. Read the current revision and retry."
        case let .invalid(reason):
            "Invalid configuration edit: \(reason)"
        case let .notFound(item):
            "Configuration item not found: \(item)"
        case .protectedGlobalProfile:
            "The global fallback profile cannot be deleted or assigned an application."
        case let .unsupportedOperation(operation):
            "Unsupported configuration operation: \(operation)"
        case .reentrantMutation:
            "Configuration changes cannot be made from an onChange callback."
        }
    }
}

/// Sole in-process authority for KeydialDocument. Callers serialize all access
/// on one executor (the GUI uses the main thread); this service never runs its
/// own queue, performs device I/O, or executes a configured action.
final class ConfigurationService {
    private let store: ProfileStore
    private(set) var document: KeydialDocument
    private(set) var revision: String
    var onChange: ((KeydialDocument, String) -> Void)?

    private var isNotifying = false

    init(store: ProfileStore = ProfileStore(),
         onChange: ((KeydialDocument, String) -> Void)? = nil) throws {
        self.store = store
        self.document = try store.load()
        self.revision = UUID().uuidString
        self.onChange = onChange
    }

    /// The GUI uses this for reviewed imports, reset, and backup restoration.
    /// The replacement follows the same validation, one-save, revision, and
    /// publication path as MCP edits.
    @discardableResult
    func replaceDocument(_ replacement: KeydialDocument, expectedRevision: String) throws -> String {
        let (_, newRevision) = try commit(expectedRevision: expectedRevision) { candidate in
            candidate = replacement
            return [:]
        }
        return newRevision
    }

    /// Dispatches configuration operations from the MCP bridge. Runtime and
    /// device operations belong to the app's separate router.
    func handle(operation: String, arguments: [String: Any]) throws -> [String: Any] {
        switch operation {
        case "profiles.list":
            try expect(arguments, required: [], allowed: [])
            let profiles: [[String: Any]] = document.profiles.map { profile in
                [
                    "id": profile.id,
                    "name": profile.name,
                    "appBundleIdentifier": profile.appBundleIdentifier as Any? ?? NSNull(),
                    "selectedGroupID": profile.selectedGroupID
                ]
            }
            return ["revision": revision, "globalProfileID": document.globalProfileID,
                    "profiles": profiles]
        case "profiles.get":
            try expect(arguments, required: ["profileId"], allowed: ["profileId"])
            let id = try string(arguments, "profileId")
            guard let profile = document.profiles.first(where: { $0.id == id }) else {
                throw ConfigurationServiceError.notFound("profile \(id)")
            }
            return ["revision": revision, "profile": try jsonObject(profile)]
        case "groups.list":
            try expect(arguments, required: ["profileId"], allowed: ["profileId"])
            let id = try string(arguments, "profileId")
            guard let profile = document.profiles.first(where: { $0.id == id }) else {
                throw ConfigurationServiceError.notFound("profile \(id)")
            }
            return [
                "revision": revision,
                "profileId": id,
                "selectedGroupID": profile.selectedGroupID,
                "groups": profile.groups.map { ["id": $0.id, "name": $0.name] }
            ]
        case "contextRules.list":
            try expect(arguments, required: ["profileId"], allowed: ["profileId"])
            let id = try string(arguments, "profileId")
            guard let profile = document.profiles.first(where: { $0.id == id }) else {
                throw ConfigurationServiceError.notFound("profile \(id)")
            }
            return ["revision": revision, "profileId": id,
                    "rules": try profile.contextRules.map { try jsonObject($0) }]
        case "bindings.get":
            try expect(arguments, required: ["profileId", "groupId", "controlId"],
                       allowed: ["profileId", "groupId", "controlId"])
            let profileID = try string(arguments, "profileId")
            let groupID = try string(arguments, "groupId")
            let control = try controlID(arguments, "controlId")
            guard let profile = document.profiles.first(where: { $0.id == profileID }) else {
                throw ConfigurationServiceError.notFound("profile \(profileID)")
            }
            guard let group = profile.groups.first(where: { $0.id == groupID }) else {
                throw ConfigurationServiceError.notFound("group \(groupID)")
            }
            guard let binding = group.binding(for: control) else {
                throw ConfigurationServiceError.notFound("control \(control.rawValue)")
            }
            return ["revision": revision, "profileId": profileID, "groupId": groupID,
                    "binding": try jsonObject(binding)]
        case "configuration.applyBatch":
            try expect(arguments, required: ["expectedRevision", "operations"],
                       allowed: ["expectedRevision", "operations"])
            let expected = try string(arguments, "expectedRevision")
            guard let operations = arguments["operations"] as? [[String: Any]],
                  (1...32).contains(operations.count) else {
                throw ConfigurationServiceError.invalid("operations must contain 1–32 objects")
            }
            let (results, newRevision) = try commit(expectedRevision: expected) { candidate in
                var results: [[String: Any]] = []
                for entry in operations {
                    guard Set(entry.keys) == Set(["name", "arguments"]),
                          let toolName = entry["name"] as? String,
                          let operation = Self.batchOperation(for: toolName),
                          let args = entry["arguments"] as? [String: Any] else {
                        throw ConfigurationServiceError.invalid("Unknown or malformed batch operation")
                    }
                    results.append(try apply(operation: operation, arguments: args,
                                             to: &candidate, inBatch: true))
                }
                return ["results": results]
            }
            return results.merging(["revision": newRevision]) { _, new in new }
        case "profiles.create", "profiles.update", "profiles.delete",
             "groups.rename", "groups.select", "bindings.set",
             "contextRules.set", "contextRules.delete", "contextRules.move":
            let expected = try string(arguments, "expectedRevision")
            let (result, newRevision) = try commit(expectedRevision: expected) { candidate in
                try apply(operation: operation, arguments: arguments,
                          to: &candidate, inBatch: false)
            }
            return result.merging(["revision": newRevision]) { _, new in new }
        default:
            throw ConfigurationServiceError.unsupportedOperation(operation)
        }
    }

    private func commit(expectedRevision: String,
                        edit: (inout KeydialDocument) throws -> [String: Any]) throws
        -> ([String: Any], String) {
        guard !isNotifying else { throw ConfigurationServiceError.reentrantMutation }
        guard expectedRevision == revision else { throw ConfigurationServiceError.staleRevision }
        var candidate = document
        let result = try edit(&candidate)
        try store.validate(candidate)
        try store.save(candidate)
        let newRevision = UUID().uuidString
        document = candidate
        revision = newRevision
        isNotifying = true
        defer { isNotifying = false }
        onChange?(candidate, newRevision)
        return (result, newRevision)
    }

    private func apply(operation: String, arguments: [String: Any],
                       to candidate: inout KeydialDocument,
                       inBatch: Bool) throws -> [String: Any] {
        let revisionKey: Set<String> = inBatch ? [] : ["expectedRevision"]
        switch operation {
        case "profiles.create":
            try expect(arguments, required: Set(["name", "appBundleIdentifier"]).union(revisionKey),
                       allowed: Set(["name", "appBundleIdentifier", "profileId"]).union(revisionKey))
            let name = try string(arguments, "name")
            let bundle = try string(arguments, "appBundleIdentifier")
            let id = try optionalString(arguments, "profileId") ?? UUID().uuidString
            candidate.profiles.append(KeydialProfile(id: id, name: name,
                                                      appBundleIdentifier: bundle))
            return ["profileId": id]
        case "profiles.update":
            try expect(arguments, required: Set(["profileId"]).union(revisionKey),
                       allowed: Set(["profileId", "name", "appBundleIdentifier"]).union(revisionKey))
            let id = try string(arguments, "profileId")
            guard let index = candidate.profiles.firstIndex(where: { $0.id == id }) else {
                throw ConfigurationServiceError.notFound("profile \(id)")
            }
            let name = try optionalString(arguments, "name")
            let bundle = try optionalString(arguments, "appBundleIdentifier")
            guard name != nil || bundle != nil else {
                throw ConfigurationServiceError.invalid("Supply name or appBundleIdentifier")
            }
            if id == candidate.globalProfileID && bundle != nil {
                throw ConfigurationServiceError.protectedGlobalProfile
            }
            if let name { candidate.profiles[index].name = name }
            if let bundle { candidate.profiles[index].appBundleIdentifier = bundle }
            return ["profileId": id]
        case "profiles.delete":
            try expect(arguments, required: Set(["profileId"]).union(revisionKey),
                       allowed: Set(["profileId"]).union(revisionKey))
            let id = try string(arguments, "profileId")
            guard id != candidate.globalProfileID else {
                throw ConfigurationServiceError.protectedGlobalProfile
            }
            guard let index = candidate.profiles.firstIndex(where: { $0.id == id }) else {
                throw ConfigurationServiceError.notFound("profile \(id)")
            }
            candidate.profiles.remove(at: index)
            return ["profileId": id]
        case "groups.rename":
            try expect(arguments, required: Set(["profileId", "groupId", "name"]).union(revisionKey),
                       allowed: Set(["profileId", "groupId", "name"]).union(revisionKey))
            let profileID = try string(arguments, "profileId")
            let groupID = try string(arguments, "groupId")
            let name = try string(arguments, "name")
            let profileIndex = try indexOfProfile(profileID, in: candidate)
            guard let groupIndex = candidate.profiles[profileIndex].groups.firstIndex(where: { $0.id == groupID }) else {
                throw ConfigurationServiceError.notFound("group \(groupID)")
            }
            candidate.profiles[profileIndex].groups[groupIndex].name = name
            return ["profileId": profileID, "groupId": groupID]
        case "groups.select":
            try expect(arguments, required: Set(["profileId", "groupId"]).union(revisionKey),
                       allowed: Set(["profileId", "groupId"]).union(revisionKey))
            let profileID = try string(arguments, "profileId")
            let groupID = try string(arguments, "groupId")
            let profileIndex = try indexOfProfile(profileID, in: candidate)
            guard candidate.profiles[profileIndex].groups.contains(where: { $0.id == groupID }) else {
                throw ConfigurationServiceError.notFound("group \(groupID)")
            }
            candidate.profiles[profileIndex].selectedGroupID = groupID
            return ["profileId": profileID, "groupId": groupID]
        case "bindings.set":
            try expect(arguments, required: Set(["profileId", "groupId", "binding"]).union(revisionKey),
                       allowed: Set(["profileId", "groupId", "binding"]).union(revisionKey))
            let profileID = try string(arguments, "profileId")
            let groupID = try string(arguments, "groupId")
            guard let raw = arguments["binding"] as? [String: Any],
                  JSONSerialization.isValidJSONObject(raw) else {
                throw ConfigurationServiceError.invalid("binding must be a JSON object")
            }
            let requiredFields: Set<String> = [
                "controlID", "label", "pressActions", "releaseActions", "buttonBehavior",
                "dialBehavior", "repeatIntervalMilliseconds", "heldModifiers",
                "idleTimeoutMilliseconds", "macroRetriggerPolicy", "queueLimit", "macroRepeatCount"
            ]
            guard requiredFields.isSubset(of: Set(raw.keys)),
                  Set(raw.keys).isSubset(of: requiredFields.union(["smart"])) else {
                throw ConfigurationServiceError.invalid("binding must contain all ControlBinding fields")
            }
            let binding: ControlBinding
            do {
                let data = try JSONSerialization.data(withJSONObject: raw)
                binding = try JSONDecoder().decode(ControlBinding.self, from: data)
            } catch {
                throw ConfigurationServiceError.invalid("Cannot decode ControlBinding: \(error.localizedDescription)")
            }
            let profileIndex = try indexOfProfile(profileID, in: candidate)
            guard let groupIndex = candidate.profiles[profileIndex].groups.firstIndex(where: { $0.id == groupID }) else {
                throw ConfigurationServiceError.notFound("group \(groupID)")
            }
            guard let controlIndex = candidate.profiles[profileIndex].groups[groupIndex].controls
                .firstIndex(where: { $0.controlID == binding.controlID }) else {
                throw ConfigurationServiceError.notFound("control \(binding.controlID.rawValue)")
            }
            candidate.profiles[profileIndex].groups[groupIndex].controls[controlIndex] = binding
            return ["profileId": profileID, "groupId": groupID,
                    "controlId": binding.controlID.rawValue]
        case "contextRules.set":
            try expect(arguments, required: Set(["profileId", "rule"]).union(revisionKey),
                       allowed: Set(["profileId", "rule"]).union(revisionKey))
            let profileID = try string(arguments, "profileId")
            let profileIndex = try indexOfProfile(profileID, in: candidate)
            guard profileID != candidate.globalProfileID else {
                throw ConfigurationServiceError.invalid("Focus rules require an application profile")
            }
            guard let raw = arguments["rule"] as? [String: Any],
                  JSONSerialization.isValidJSONObject(raw) else {
                throw ConfigurationServiceError.invalid("rule must be a JSON object")
            }
            let required: Set<String> = ["id", "name", "enabled", "targetGroupID"]
            let allowed = required.union(["kind", "area", "role", "identifier", "labelContains"])
            guard required.isSubset(of: Set(raw.keys)), Set(raw.keys).isSubset(of: allowed) else {
                throw ConfigurationServiceError.invalid("Focus rule has missing or unexpected fields")
            }
            let rule: FocusRule
            do {
                rule = try JSONDecoder().decode(FocusRule.self,
                                                from: JSONSerialization.data(withJSONObject: raw))
            } catch {
                throw ConfigurationServiceError.invalid("Cannot decode FocusRule: \(error.localizedDescription)")
            }
            if let index = candidate.profiles[profileIndex].contextRules.firstIndex(where: { $0.id == rule.id }) {
                candidate.profiles[profileIndex].contextRules[index] = rule
            } else {
                candidate.profiles[profileIndex].contextRules.append(rule)
            }
            return ["profileId": profileID, "ruleId": rule.id]
        case "contextRules.move":
            let keys: Set<String> = ["profileId", "ruleId", "direction"]
            try expect(arguments, required: keys.union(revisionKey), allowed: keys.union(revisionKey))
            let profileID = try string(arguments, "profileId")
            let ruleID = try string(arguments, "ruleId")
            let direction = try string(arguments, "direction")
            guard direction == "up" || direction == "down" else { throw ConfigurationServiceError.invalid("direction must be up or down") }
            let p = try indexOfProfile(profileID, in: candidate)
            guard let index = candidate.profiles[p].contextRules.firstIndex(where: { $0.id == ruleID }) else {
                throw ConfigurationServiceError.notFound("focus rule \(ruleID)")
            }
            let target = index + (direction == "up" ? -1 : 1)
            guard candidate.profiles[p].contextRules.indices.contains(target) else {
                throw ConfigurationServiceError.invalid("Rule is already at this end of the list")
            }
            candidate.profiles[p].contextRules.swapAt(index, target)
            return ["profileId": profileID, "ruleId": ruleID]
        case "contextRules.delete":
            try expect(arguments, required: Set(["profileId", "ruleId"]).union(revisionKey),
                       allowed: Set(["profileId", "ruleId"]).union(revisionKey))
            let profileID = try string(arguments, "profileId")
            let ruleID = try string(arguments, "ruleId")
            let profileIndex = try indexOfProfile(profileID, in: candidate)
            guard profileID != candidate.globalProfileID else {
                throw ConfigurationServiceError.invalid("Focus rules require an application profile")
            }
            guard let ruleIndex = candidate.profiles[profileIndex].contextRules.firstIndex(where: { $0.id == ruleID }) else {
                throw ConfigurationServiceError.notFound("focus rule \(ruleID)")
            }
            candidate.profiles[profileIndex].contextRules.remove(at: ruleIndex)
            return ["profileId": profileID, "ruleId": ruleID]
        default:
            throw ConfigurationServiceError.unsupportedOperation(operation)
        }
    }

    private static func batchOperation(for toolName: String) -> String? {
        [
            "kdcustom_create_profile": "profiles.create",
            "kdcustom_update_profile": "profiles.update",
            "kdcustom_delete_profile": "profiles.delete",
            "kdcustom_rename_group": "groups.rename",
            "kdcustom_select_group": "groups.select",
            "kdcustom_set_binding": "bindings.set",
            "kdcustom_set_context_rule": "contextRules.set",
            "kdcustom_delete_context_rule": "contextRules.delete",
            "kdcustom_move_context_rule": "contextRules.move"
        ][toolName]
    }

    private func indexOfProfile(_ id: String, in document: KeydialDocument) throws -> Int {
        guard let index = document.profiles.firstIndex(where: { $0.id == id }) else {
            throw ConfigurationServiceError.notFound("profile \(id)")
        }
        return index
    }

    private func controlID(_ values: [String: Any], _ key: String) throws -> ControlID {
        let raw = try string(values, key)
        guard let control = ControlID(rawValue: raw) else {
            throw ConfigurationServiceError.invalid("Unknown controlId \(raw)")
        }
        return control
    }

    private func string(_ values: [String: Any], _ key: String) throws -> String {
        guard let value = values[key] as? String,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConfigurationServiceError.invalid("\(key) must be a nonempty string")
        }
        return value
    }

    private func optionalString(_ values: [String: Any], _ key: String) throws -> String? {
        guard values[key] != nil else { return nil }
        return try string(values, key)
    }

    private func expect(_ values: [String: Any], required: Set<String>,
                        allowed: Set<String>) throws {
        guard required.isSubset(of: Set(values.keys)),
              Set(values.keys).isSubset(of: allowed) else {
            throw ConfigurationServiceError.invalid("Missing or unexpected arguments")
        }
    }

    private func jsonObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ConfigurationServiceError.invalid("Cannot encode configuration object")
        }
        return object
    }
}
