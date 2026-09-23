import Foundation

@main
enum ConfigurationServiceTests {
    static func check(_ condition: Bool, _ message: String) {
        if !condition { fatalError(message) }
    }

    static func rejects(_ message: String, _ body: () throws -> Void) {
        do {
            try body()
            fatalError("Expected rejection: \(message)")
        } catch is ConfigurationServiceError {
            // Expected.
        } catch is ProfileStoreError {
            // Candidate failed authoritative document validation.
        } catch {
            fatalError("Unexpected error for \(message): \(error)")
        }
    }

    static func main() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kdcustom-configuration-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProfileStore(directoryURL: directory)
        var notifications = 0
        let service = try ConfigurationService(store: store) { document, revision in
            notifications += 1
            check(!revision.isEmpty && document.globalProfile != nil,
                  "callback sees committed document and revision")
        }
        let originalRevision = service.revision
        let listing = try service.handle(operation: "profiles.list", arguments: [:])
        check(listing["revision"] as? String == originalRevision,
              "profile list includes current revision")
        check(JSONSerialization.isValidJSONObject(listing),
              "read results can be returned as MCP structured content")
        check((listing["profiles"] as? [[String: Any]])?.count == 1,
              "fresh service has the global profile")

        let created = try service.handle(operation: "profiles.create", arguments: [
            "expectedRevision": originalRevision,
            "profileId": "rive-app",
            "name": "Rive",
            "appBundleIdentifier": "app.rive.Rive"
        ])
        check(created["profileId"] as? String == "rive-app", "create returns profile ID")
        check(service.revision != originalRevision && notifications == 1,
              "create publishes one new revision")
        check(try store.load().profiles.count == 2, "create is persisted")
        let createdRevision = service.revision

        rejects("stale revision") {
            _ = try service.handle(operation: "groups.rename", arguments: [
                "expectedRevision": originalRevision,
                "profileId": "rive-app", "groupId": "group-1", "name": "Editing"
            ])
        }
        check(service.revision == createdRevision && notifications == 1,
              "stale edit does not publish")

        rejects("global deletion") {
            _ = try service.handle(operation: "profiles.delete", arguments: [
                "expectedRevision": service.revision, "profileId": "global"
            ])
        }
        rejects("global app retarget") {
            _ = try service.handle(operation: "profiles.update", arguments: [
                "expectedRevision": service.revision, "profileId": "global",
                "appBundleIdentifier": "app.example.Bad"
            ])
        }
        check(service.document.globalProfile?.appBundleIdentifier == nil &&
              service.document.profiles.count == 2,
              "global fallback remains protected")

        let updated = try service.handle(operation: "profiles.update", arguments: [
            "expectedRevision": service.revision,
            "profileId": "rive-app", "name": "Rive Editor"
        ])
        check(updated["revision"] as? String == service.revision &&
              service.document.profiles[1].name == "Rive Editor",
              "profile update commits and returns revision")

        let binding = ControlBinding(controlID: .dial2CCW, label: "Zoom out",
                                     pressActions: [.keyTap(27, modifiers: [.command])])
        let bindingObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(binding)) as! [String: Any]
        let setResult = try service.handle(operation: "bindings.set", arguments: [
            "expectedRevision": service.revision,
            "profileId": "rive-app", "groupId": "group-3", "binding": bindingObject
        ])
        check(setResult["controlId"] as? String == "dial2CCW", "set returns control ID")
        let fetched = try service.handle(operation: "bindings.get", arguments: [
            "profileId": "rive-app", "groupId": "group-3", "controlId": "dial2CCW"
        ])
        let fetchedBinding = fetched["binding"] as? [String: Any]
        check(fetchedBinding?["label"] as? String == "Zoom out" &&
              fetched["revision"] as? String == service.revision,
              "binding read includes complete committed binding and revision")

        let smart = SmartDialSettings(direction: .decrease, detection: .numericField,
            step: 1.5, shortcut: SmartShortcut(keyCode: 126, modifiers: .command, repeatCount: 2),
            modifierRules: [
                .init(id: "fine", name: "Fine", modifiers: .option, step: 0.01),
                .init(id: "coarse", name: "Coarse", modifiers: .shift, step: 10,
                      shortcut: SmartShortcut(keyCode: 125, repeatCount: 3))
            ], fallbackToActions: true)
        let smartBinding = ControlBinding(controlID: .dial2CCW, label: "Smart zoom",
            pressActions: [.keyTap(27, modifiers: .command)], dialBehavior: .smart, smart: smart)
        let smartObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(smartBinding)) as! [String: Any]
        let beforeSmartRevision = service.revision
        _ = try service.handle(operation: "bindings.set", arguments: [
            "expectedRevision": beforeSmartRevision, "profileId": "rive-app", "groupId": "group-3",
            "binding": smartObject
        ])
        let readSmart = try service.handle(operation: "bindings.get", arguments: [
            "profileId": "rive-app", "groupId": "group-3", "controlId": "dial2CCW"
        ])
        let readSmartObject = readSmart["binding"] as! [String: Any]
        let decodedSmart = try JSONDecoder().decode(ControlBinding.self,
            from: JSONSerialization.data(withJSONObject: readSmartObject))
        let persistedSmart = try store.load().profiles[1].groups[2].binding(for: .dial2CCW)
        check(decodedSmart == smartBinding &&
              persistedSmart == smartBinding,
              "complete Smart dial binding is committed, read, and persisted")
        rejects("stale Smart binding edit") {
            _ = try service.handle(operation: "bindings.set", arguments: [
                "expectedRevision": beforeSmartRevision, "profileId": "rive-app",
                "groupId": "group-3", "binding": smartObject
            ])
        }
        check(service.revision == (readSmart["revision"] as? String) &&
              service.document.profiles[1].groups[2].binding(for: .dial2CCW) == smartBinding,
              "stale Smart edit leaves the committed binding and revision unchanged")
        let beforeInvalidSmart = service.document
        let beforeInvalidSmartRevision = service.revision
        let beforeInvalidSmartDisk = try Data(contentsOf: store.fileURL)
        let beforeInvalidSmartBackup = try Data(contentsOf: store.backupURL)
        let beforeInvalidSmartNotifications = notifications
        var invalidSmart = smartObject
        var malformedSettings = invalidSmart["smart"] as! [String: Any]
        malformedSettings["step"] = 0
        invalidSmart["smart"] = malformedSettings
        rejects("invalid Smart binding rolls back an atomic batch") {
            _ = try service.handle(operation: "configuration.applyBatch", arguments: [
                "expectedRevision": service.revision,
                "operations": [
                    ["name": "kdcustom_rename_group",
                     "arguments": ["profileId": "rive-app", "groupId": "group-3",
                                   "name": "Should not persist"]],
                    ["name": "kdcustom_set_binding",
                     "arguments": ["profileId": "rive-app", "groupId": "group-3",
                                   "binding": invalidSmart]]
                ]
            ])
        }
        let afterInvalidSmartDisk = try Data(contentsOf: store.fileURL)
        let afterInvalidSmartBackup = try Data(contentsOf: store.backupURL)
        check(service.document == beforeInvalidSmart &&
              service.revision == beforeInvalidSmartRevision &&
              afterInvalidSmartDisk == beforeInvalidSmartDisk &&
              afterInvalidSmartBackup == beforeInvalidSmartBackup &&
              notifications == beforeInvalidSmartNotifications,
              "invalid Smart batch leaves document, revision, primary, backup, and callbacks unchanged")

        let rule = FocusRule(id: "numeric-focus", name: "Numeric fields",
                             targetGroupID: "group-3", kind: .numeric)
        let ruleObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(rule)) as! [String: Any]
        let ruleSet = try service.handle(operation: "contextRules.set", arguments: [
            "expectedRevision": service.revision, "profileId": "rive-app", "rule": ruleObject
        ])
        let rules = try service.handle(operation: "contextRules.list", arguments: ["profileId": "rive-app"])
        check(ruleSet["ruleId"] as? String == "numeric-focus" &&
              (rules["rules"] as? [[String: Any]])?.count == 1 &&
              rules["revision"] as? String == service.revision,
              "focus rule set and ordered list share the authoritative revision")
        let areaRule = FocusRule(id: "canvas-area", name: "Canvas", targetGroupID: "group-3",
                                 area: .canvas)
        let areaRuleObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(areaRule)) as! [String: Any]
        _ = try service.handle(operation: "contextRules.set", arguments: [
            "expectedRevision": service.revision, "profileId": "rive-app", "rule": areaRuleObject
        ])
        let persistedArea = try store.load().profiles[1].contextRules.last?.area
        check(service.document.profiles[1].contextRules.last?.area == .canvas &&
              persistedArea == .canvas,
              "area-only rule validates and persists through the shared configuration service")
        let areaRevision = service.revision
        var invalidAreaRule = areaRuleObject
        invalidAreaRule["area"] = "unknown"
        rejects("unknown active area") {
            _ = try service.handle(operation: "contextRules.set", arguments: [
                "expectedRevision": areaRevision, "profileId": "rive-app", "rule": invalidAreaRule
            ])
        }
        check(service.revision == areaRevision &&
              service.document.profiles[1].contextRules.last?.area == .canvas,
              "unknown area leaves the stored rule and revision unchanged")
        _ = try service.handle(operation: "contextRules.delete", arguments: [
            "expectedRevision": service.revision, "profileId": "rive-app", "ruleId": "canvas-area"
        ])
        let ruleRevision = service.revision
        rejects("stale focus rule edit") {
            _ = try service.handle(operation: "contextRules.set", arguments: [
                "expectedRevision": createdRevision, "profileId": "rive-app", "rule": ruleObject
            ])
        }
        rejects("global focus rule edit") {
            _ = try service.handle(operation: "contextRules.set", arguments: [
                "expectedRevision": ruleRevision, "profileId": "global", "rule": ruleObject
            ])
        }
        check(service.revision == ruleRevision &&
              service.document.profiles[1].contextRules.count == 1,
              "rejected rule edits leave memory and revision unchanged")

        let beforeInvalid = service.document
        let beforeInvalidRevision = service.revision
        let beforeInvalidDisk = try Data(contentsOf: store.fileURL)
        let beforeInvalidBackup = try Data(contentsOf: store.backupURL)
        let beforeInvalidNotifications = notifications
        var invalidBinding = bindingObject
        invalidBinding["macroRepeatCount"] = 0
        rejects("invalid atomic batch") {
            _ = try service.handle(operation: "configuration.applyBatch", arguments: [
                "expectedRevision": service.revision,
                "operations": [
                    ["name": "kdcustom_rename_group",
                     "arguments": ["profileId": "rive-app", "groupId": "group-3",
                                   "name": "Should roll back"]],
                    ["name": "kdcustom_set_binding",
                     "arguments": ["profileId": "rive-app", "groupId": "group-3",
                                   "binding": invalidBinding]]
                ]
            ])
        }
        let afterInvalidDisk = try Data(contentsOf: store.fileURL)
        let afterInvalidBackup = try Data(contentsOf: store.backupURL)
        check(service.document == beforeInvalid &&
              service.revision == beforeInvalidRevision &&
              afterInvalidDisk == beforeInvalidDisk &&
              afterInvalidBackup == beforeInvalidBackup &&
              notifications == beforeInvalidNotifications,
              "invalid batch changes neither memory, revision, disk, nor callbacks")
        var invalidRule = ruleObject
        invalidRule["targetGroupID"] = "missing"
        rejects("invalid focus rule rolls back earlier batch edit") {
            _ = try service.handle(operation: "configuration.applyBatch", arguments: [
                "expectedRevision": service.revision,
                "operations": [
                    ["name": "kdcustom_rename_group",
                     "arguments": ["profileId": "rive-app", "groupId": "group-3",
                                   "name": "Should roll back again"]],
                    ["name": "kdcustom_set_context_rule",
                     "arguments": ["profileId": "rive-app", "rule": invalidRule]]
                ]
            ])
        }
        let afterInvalidFocusDisk = try Data(contentsOf: store.fileURL)
        check(service.document == beforeInvalid && service.revision == beforeInvalidRevision &&
              afterInvalidFocusDisk == beforeInvalidDisk &&
              notifications == beforeInvalidNotifications,
              "invalid focus batch also rolls back document, disk, and publication")

        let preBatchDisk = try Data(contentsOf: store.fileURL)
        let batchResult = try service.handle(operation: "configuration.applyBatch", arguments: [
            "expectedRevision": service.revision,
            "operations": [
                ["name": "kdcustom_rename_group",
                 "arguments": ["profileId": "rive-app", "groupId": "group-3",
                               "name": "Timeline"]],
                ["name": "kdcustom_select_group",
                 "arguments": ["profileId": "rive-app", "groupId": "group-3"]],
                ["name": "kdcustom_set_context_rule",
                 "arguments": ["profileId": "rive-app", "rule": [
                    "id": "text-focus", "name": "Text fields", "enabled": true,
                    "targetGroupID": "group-2", "kind": "text"
                 ]]]
            ]
        ])
        check((batchResult["results"] as? [[String: Any]])?.count == 3 &&
              service.document.profiles[1].selectedGroupID == "group-3" &&
              service.document.profiles[1].groups[2].name == "Timeline" &&
              service.document.profiles[1].contextRules.map(\.id) == ["numeric-focus", "text-focus"],
              "valid batch applies group and focus-rule edits")
        check(try Data(contentsOf: store.backupURL) == preBatchDisk &&
              notifications == beforeInvalidNotifications + 1,
              "valid batch persists once and publishes once")

        let beforeMove = service.revision
        _ = try service.handle(operation: "contextRules.move", arguments: ["expectedRevision": beforeMove,
            "profileId": "rive-app", "ruleId": "text-focus", "direction": "up"])
        check(service.document.profiles[1].contextRules.map(\.id) == ["text-focus", "numeric-focus"],
              "moving rule changes persisted first-match priority")
        rejects("stale move") {
            _ = try service.handle(operation: "contextRules.move", arguments: ["expectedRevision": beforeMove,
                "profileId": "rive-app", "ruleId": "text-focus", "direction": "down"])
        }
        let beforeReplacement = service.revision
        var replacement = service.document
        replacement.profiles[1].name = "Restored"
        let replacementRevision = try service.replaceDocument(replacement,
                                                              expectedRevision: beforeReplacement)
        let loadedReplacement = try store.load()
        check(replacementRevision == service.revision &&
              replacementRevision != beforeReplacement &&
              loadedReplacement.profiles[1].name == "Restored",
              "GUI replacement follows the same save and revision path")
        rejects("stale replacement") {
            _ = try service.replaceDocument(replacement, expectedRevision: beforeReplacement)
        }
        var invalidDocument = service.document
        invalidDocument.profiles.removeAll { $0.id == "global" }
        let beforeInvalidReplacement = service.revision
        let beforeInvalidReplacementDisk = try Data(contentsOf: store.fileURL)
        rejects("invalid replacement") {
            _ = try service.replaceDocument(invalidDocument,
                                            expectedRevision: beforeInvalidReplacement)
        }
        let afterInvalidReplacementDisk = try Data(contentsOf: store.fileURL)
        check(service.revision == beforeInvalidReplacement &&
              afterInvalidReplacementDisk == beforeInvalidReplacementDisk,
              "invalid GUI replacement rolls back")

        var sawReentrantError = false
        service.onChange = { _, currentRevision in
            let read = try? service.handle(operation: "profiles.list", arguments: [:])
            check(read?["revision"] as? String == currentRevision,
                  "onChange may read committed state")
            do {
                _ = try service.handle(operation: "groups.rename", arguments: [
                    "expectedRevision": currentRevision,
                    "profileId": "rive-app", "groupId": "group-1", "name": "Nested"
                ])
            } catch ConfigurationServiceError.reentrantMutation {
                sawReentrantError = true
            } catch {
                fatalError("Unexpected reentrant error: \(error)")
            }
        }
        _ = try service.handle(operation: "groups.select", arguments: [
            "expectedRevision": service.revision,
            "profileId": "rive-app", "groupId": "group-2"
        ])
        check(sawReentrantError &&
              service.document.profiles[1].groups[0].name != "Nested",
              "reentrant callback cannot perform a second mutation")

        let deletedRule = try service.handle(operation: "contextRules.delete", arguments: [
            "expectedRevision": service.revision, "profileId": "rive-app", "ruleId": "numeric-focus"
        ])
        check(deletedRule["ruleId"] as? String == "numeric-focus" &&
              service.document.profiles[1].contextRules.map(\.id) == ["text-focus"],
              "focus rule delete removes only the requested rule")

        let deletion = try service.handle(operation: "profiles.delete", arguments: [
            "expectedRevision": service.revision, "profileId": "rive-app"
        ])
        let afterDeletion = try store.load()
        check(deletion["profileId"] as? String == "rive-app" &&
              service.document.profiles.count == 1 &&
              afterDeletion.profiles.count == 1,
              "non-global profile deletion persists")

        print("ConfigurationServiceTests passed")
    }
}
