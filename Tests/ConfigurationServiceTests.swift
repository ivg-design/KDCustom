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

        let preBatchDisk = try Data(contentsOf: store.fileURL)
        let batchResult = try service.handle(operation: "configuration.applyBatch", arguments: [
            "expectedRevision": service.revision,
            "operations": [
                ["name": "kdcustom_rename_group",
                 "arguments": ["profileId": "rive-app", "groupId": "group-3",
                               "name": "Timeline"]],
                ["name": "kdcustom_select_group",
                 "arguments": ["profileId": "rive-app", "groupId": "group-3"]]
            ]
        ])
        check((batchResult["results"] as? [[String: Any]])?.count == 2 &&
              service.document.profiles[1].selectedGroupID == "group-3" &&
              service.document.profiles[1].groups[2].name == "Timeline",
              "valid batch applies both edits")
        check(try Data(contentsOf: store.backupURL) == preBatchDisk &&
              notifications == beforeInvalidNotifications + 1,
              "valid batch persists once and publishes once")

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
