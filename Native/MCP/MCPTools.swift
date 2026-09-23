import Foundation

struct MCPInputError: Error, LocalizedError {
    let reason: String
    var errorDescription: String? { reason }
}

struct MCPToolDefinition {
    let name: String
    let operation: String
    let title: String
    let description: String
    let inputSchema: [String: Any]
    let readOnly: Bool
    let destructive: Bool
    let idempotent: Bool

    var listing: [String: Any] {
        [
            "name": name,
            "title": title,
            "description": description,
            "inputSchema": inputSchema,
            "annotations": [
                "title": title,
                "readOnlyHint": readOnly,
                "destructiveHint": destructive,
                "idempotentHint": idempotent,
                "openWorldHint": false
            ]
        ]
    }
}

enum MCPTools {
    static let protocolVersion = "2025-11-25"
    static let maxMessageBytes = 4 * 1024 * 1024

    static let all: [MCPToolDefinition] = [
        tool("kdcustom_list_profiles", "profiles.list", "List profiles",
             "List profiles and the current opaque configuration revision.", empty, readOnly: true),
        tool("kdcustom_get_profile", "profiles.get", "Get profile",
             "Read one profile, including its six groups and all control bindings.",
             object(["profileId": string], required: ["profileId"]), readOnly: true),
        tool("kdcustom_create_profile", "profiles.create", "Create app profile",
             "Create a six-group application profile. The app generates an ID unless profileId is supplied.",
             object(["expectedRevision": string, "profileId": string, "name": string,
                     "appBundleIdentifier": string],
                    required: ["expectedRevision", "name", "appBundleIdentifier"]),
             readOnly: false, destructive: false),
        tool("kdcustom_update_profile", "profiles.update", "Update app profile",
             "Change the name or app bundle identifier of an existing application profile.",
             object(["expectedRevision": string, "profileId": string, "name": string,
                     "appBundleIdentifier": string],
                    required: ["expectedRevision", "profileId"]),
             readOnly: false),
        tool("kdcustom_delete_profile", "profiles.delete", "Delete app profile",
             "Delete an application profile. The global fallback profile cannot be deleted.",
             object(["expectedRevision": string, "profileId": string],
                    required: ["expectedRevision", "profileId"]),
             readOnly: false),
        tool("kdcustom_list_groups", "groups.list", "List groups",
             "Read the six groups and selected group of a profile.",
             object(["profileId": string], required: ["profileId"]), readOnly: true),
        tool("kdcustom_rename_group", "groups.rename", "Rename group",
             "Set one group's display name.",
             object(["expectedRevision": string, "profileId": string, "groupId": string,
                     "name": string],
                    required: ["expectedRevision", "profileId", "groupId", "name"]),
             readOnly: false),
        tool("kdcustom_select_group", "groups.select", "Select group",
             "Set the selected group within a profile. This does not activate that profile.",
             object(["expectedRevision": string, "profileId": string, "groupId": string],
                    required: ["expectedRevision", "profileId", "groupId"]),
             readOnly: false),
        tool("kdcustom_get_binding", "bindings.get", "Get binding",
             "Read the complete binding for one physical key, group button, or dial direction.",
             object(["profileId": string, "groupId": string, "controlId": controlIDSchema],
                    required: ["profileId", "groupId", "controlId"]),
             readOnly: true),
        tool("kdcustom_set_binding", "bindings.set", "Set binding",
             "Replace one complete ControlBinding, including press/release macro steps and behavior.",
             object(["expectedRevision": string, "profileId": string, "groupId": string,
                     "binding": bindingSchema],
                    required: ["expectedRevision", "profileId", "groupId", "binding"]),
             readOnly: false),
        tool("kdcustom_apply_batch", "configuration.applyBatch", "Apply configuration batch",
             "Atomically validate and commit 1–32 profile, group, or binding edits against one revision.",
             object(["expectedRevision": string,
                     "operations": ["type": "array", "minItems": 1, "maxItems": 32,
                                    "items": object(["name": ["type": "string", "enum": batchNames],
                                                     "arguments": ["type": "object"]],
                                                    required: ["name", "arguments"])]],
                    required: ["expectedRevision", "operations"]),
             readOnly: false),
        tool("kdcustom_get_runtime", "runtime.get", "Get runtime",
             "Read active app, effective profile, device connection, and permissions as observed by the app.",
             empty, readOnly: true),
        tool("kdcustom_get_device_settings", "device.getSettings", "Get observed device settings",
             "Read cached settings with availability and observation time; unavailable is distinct from zero.",
             empty, readOnly: true),
        tool("kdcustom_query_device_setting", "device.querySetting", "Query device setting",
             "Request a known K40 setting from the connected device: battery, brightness, sleep, or rotation.",
             object(["setting": ["type": "string",
                                 "enum": ["battery", "brightness", "sleep", "rotation"]]],
                    required: ["setting"]),
             readOnly: false, destructive: false)
    ]

    static let byName = Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0) })
    static let batchNames = [
        "kdcustom_create_profile", "kdcustom_update_profile", "kdcustom_delete_profile",
        "kdcustom_rename_group", "kdcustom_select_group", "kdcustom_set_binding"
    ]

    static func validate(name: String, arguments: [String: Any], inBatch: Bool = false) throws {
        guard let tool = byName[name] else { throw MCPInputError(reason: "Unknown tool: \(name)") }
        let required = Set(tool.inputSchema["required"] as? [String] ?? [])
        let properties = Set((tool.inputSchema["properties"] as? [String: Any] ?? [:]).keys)
        let allowed = inBatch ? properties.subtracting(["expectedRevision"]) : properties
        let needed = inBatch ? required.subtracting(["expectedRevision"]) : required
        guard needed.isSubset(of: Set(arguments.keys)),
              Set(arguments.keys).isSubset(of: allowed) else {
            throw MCPInputError(reason: "Missing or unexpected arguments for \(name)")
        }
        if inBatch && !batchNames.contains(name) {
            throw MCPInputError(reason: "Tool is not valid in an atomic configuration batch")
        }
        for (key, value) in arguments where key != "binding" && key != "operations" {
            guard let string = value as? String, !string.isEmpty else {
                throw MCPInputError(reason: "\(key) must be a nonempty string")
            }
            if key == "expectedRevision" && string.utf8.count > 128 {
                throw MCPInputError(reason: "expectedRevision is too long")
            }
            if ["profileId", "groupId"].contains(key) && string.utf8.count > 80 {
                throw MCPInputError(reason: "\(key) is too long")
            }
            if key == "controlId" && ControlID(rawValue: string) == nil {
                throw MCPInputError(reason: "Unknown controlId")
            }
            if key == "setting" && !["battery", "brightness", "sleep", "rotation"].contains(string) {
                throw MCPInputError(reason: "Unknown device setting")
            }
        }
        if name == "kdcustom_update_profile" &&
            arguments["name"] == nil && arguments["appBundleIdentifier"] == nil {
            throw MCPInputError(reason: "Supply name or appBundleIdentifier")
        }
        if let name = arguments["name"] as? String {
            if arguments["groupId"] != nil {
                guard name.utf16.count * 2 <= 58 else {
                    throw MCPInputError(reason: "Group name exceeds 58 UTF-16LE bytes")
                }
            } else if name.utf8.count > 80 {
                throw MCPInputError(reason: "Profile name exceeds 80 UTF-8 bytes")
            }
        }
        if name == "kdcustom_set_binding" {
            guard let binding = arguments["binding"] as? [String: Any] else {
                throw MCPInputError(reason: "binding must be an object")
            }
            try validateBinding(binding)
        }
        if name == "kdcustom_apply_batch" {
            guard let operations = arguments["operations"] as? [[String: Any]],
                  (1...32).contains(operations.count) else {
                throw MCPInputError(reason: "operations must contain 1–32 objects")
            }
            for operation in operations {
                guard Set(operation.keys) == ["name", "arguments"],
                      let nestedName = operation["name"] as? String,
                      let nestedArguments = operation["arguments"] as? [String: Any] else {
                    throw MCPInputError(reason: "Each operation needs name and arguments")
                }
                try validate(name: nestedName, arguments: nestedArguments, inBatch: true)
            }
        }
    }

    private static func validateBinding(_ object: [String: Any]) throws {
        let keys: Set<String> = [
            "controlID", "label", "pressActions", "releaseActions", "buttonBehavior",
            "dialBehavior", "repeatIntervalMilliseconds", "heldModifiers",
            "idleTimeoutMilliseconds", "macroRetriggerPolicy", "queueLimit", "macroRepeatCount"
        ]
        guard Set(object.keys) == keys else {
            throw MCPInputError(reason: "binding must contain every ControlBinding field exactly once")
        }
        for actionKey in ["pressActions", "releaseActions"] {
            guard let actions = object[actionKey] as? [[String: Any]] else {
                throw MCPInputError(reason: "\(actionKey) must be an array of action steps")
            }
            for action in actions {
                guard let kind = action["kind"] as? String,
                      let expected = actionKeys[kind],
                      Set(action.keys) == expected else {
                    throw MCPInputError(reason: "Action step fields do not match its kind")
                }
            }
        }
        guard JSONSerialization.isValidJSONObject(object) else {
            throw MCPInputError(reason: "binding is not valid JSON")
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: object)
            let binding = try JSONDecoder().decode(ControlBinding.self, from: data)
            var document = KeydialDocument()
            document.profiles[0].groups[0].controls.removeAll { $0.controlID == binding.controlID }
            document.profiles[0].groups[0].controls.append(binding)
            try ProfileStore().validate(document)
        } catch {
            throw MCPInputError(reason: "Invalid ControlBinding: \(error.localizedDescription)")
        }
    }

    private static let actionKeys: [String: Set<String>] = {
        let base: Set<String> = ["kind", "repeatCount"]
        return [
            "keyDown": base.union(["keyCode", "modifiers"]),
            "keyUp": base.union(["keyCode", "modifiers"]),
            "keyTap": base.union(["keyCode", "modifiers"]),
            "chord": base.union(["keyCodes", "modifiers"]),
            "text": base.union(["text"]),
            "delay": base.union(["milliseconds"]),
            "mouseButtonDown": base.union(["mouseButton"]),
            "mouseButtonUp": base.union(["mouseButton"]),
            "mouseClick": base.union(["mouseButton"]),
            "scroll": base.union(["horizontal", "vertical"]),
            "media": base.union(["mediaKey"]),
            "groupChange": base.union(["offset"])
        ]
    }()

    private static let string: [String: Any] = ["type": "string", "minLength": 1]
    private static let empty = object([:])
    private static let controlIDSchema: [String: Any] = [
        "type": "string", "enum": ControlID.allCases.map(\.rawValue)
    ]
    private static let modifierSchema = object(
        ["rawValue": ["type": "integer", "minimum": 0]], required: ["rawValue"]
    )
    private static let stepSchema: [String: Any] = [
        "oneOf": actionKeys.map { kind, keys in
            var properties: [String: Any] = [
                "kind": ["const": kind],
                "repeatCount": ["type": "integer", "minimum": 1, "maximum": 100]
            ]
            for key in keys.subtracting(["kind", "repeatCount"]) {
                switch key {
                case "modifiers": properties[key] = modifierSchema
                case "keyCodes":
                    properties[key] = ["type": "array", "minItems": 1, "maxItems": 8,
                                       "uniqueItems": true,
                                       "items": ["type": "integer", "minimum": 0, "maximum": 255]]
                case "keyCode": properties[key] = ["type": "integer", "minimum": 0, "maximum": 255]
                case "milliseconds": properties[key] = ["type": "integer", "minimum": 0, "maximum": 60000]
                case "text": properties[key] = ["type": "string", "minLength": 1, "maxLength": 1024]
                case "mouseButton": properties[key] = ["type": "string", "enum": ["left", "right", "middle"]]
                case "mediaKey":
                    properties[key] = ["type": "string",
                                       "enum": ["playPause", "nextTrack", "previousTrack",
                                                "volumeUp", "volumeDown", "mute"]]
                default: properties[key] = ["type": "integer"]
                }
            }
            return object(properties, required: Array(keys).sorted())
        }
    ]
    private static let bindingSchema = object([
        "controlID": controlIDSchema,
        "label": ["type": "string", "description": "At most 56 UTF-16LE bytes"],
        "pressActions": ["type": "array", "maxItems": 64, "items": stepSchema],
        "releaseActions": ["type": "array", "maxItems": 64, "items": stepSchema],
        "buttonBehavior": ["type": "string", "enum": ["pressRelease", "hold", "toggle", "repeatWhileHeld"]],
        "dialBehavior": ["type": "string", "enum": ["perStep", "heldModifiers"]],
        "repeatIntervalMilliseconds": ["type": "integer", "minimum": 20, "maximum": 5000],
        "heldModifiers": modifierSchema,
        "idleTimeoutMilliseconds": ["type": "integer", "minimum": 20, "maximum": 5000],
        "macroRetriggerPolicy": ["type": "string", "enum": ["queue", "restart", "ignoreWhileRunning"]],
        "queueLimit": ["type": "integer", "minimum": 1, "maximum": 32],
        "macroRepeatCount": ["type": "integer", "minimum": 1, "maximum": 100]
    ], required: [
        "controlID", "label", "pressActions", "releaseActions", "buttonBehavior",
        "dialBehavior", "repeatIntervalMilliseconds", "heldModifiers",
        "idleTimeoutMilliseconds", "macroRetriggerPolicy", "queueLimit", "macroRepeatCount"
    ])

    private static func object(_ properties: [String: Any], required: [String] = []) -> [String: Any] {
        var result: [String: Any] = [
            "type": "object",
            "properties": properties,
            "additionalProperties": false
        ]
        if !required.isEmpty { result["required"] = required }
        return result
    }

    private static func tool(_ name: String, _ operation: String, _ title: String,
                             _ description: String, _ inputSchema: [String: Any],
                             readOnly: Bool, destructive: Bool = true,
                             idempotent: Bool = false) -> MCPToolDefinition {
        MCPToolDefinition(name: name, operation: operation, title: title,
                          description: description, inputSchema: inputSchema,
                          readOnly: readOnly, destructive: destructive,
                          idempotent: idempotent || readOnly)
    }
}
