import Foundation

@main
enum ProfileStoreTests {
    static func check(_ condition: Bool, _ message: String) {
        if !condition { fatalError(message) }
    }

    static func rejects(_ message: String, _ body: () throws -> Void) {
        do {
            try body()
            fatalError("Expected rejection: \(message)")
        } catch is ProfileStoreError {
            // Expected validation error.
        } catch is DecodingError {
            // Expected malformed JSON/schema rejection.
        } catch {
            fatalError("Unexpected error for \(message): \(error)")
        }
    }

    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("keydial-profile-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProfileStore(directoryURL: directory)
        var document = try store.load()
        check(document.globalProfile?.groups.count == 6, "blank document has six groups")
        check(document.globalProfile?.selectedGroupID == "group-1", "default selected group")
        check(document.globalProfile?.groups.allSatisfy({ $0.controls.count == ControlID.allCases.count }) == true,
              "all controls are individually present")
        check(document.globalProfile?.groups.allSatisfy({ group in
            group.binding(for: .setPrevious)?.pressActions == [.init(.groupChange(offset: -1))] &&
            group.binding(for: .setNext)?.pressActions == [.init(.groupChange(offset: 1))] &&
            group.controls.filter { $0.controlID != .setPrevious && $0.controlID != .setNext }
                .allSatisfy { $0.pressActions.isEmpty && $0.releaseActions.isEmpty }
        }) == true, "only the set buttons change groups by default")

        var app = KeydialProfile(name: "Rive", appBundleIdentifier: "app.rive.Rive")
        app.selectedGroupID = "group-4"
        app.groups[3].name = "Timeline"
        let bindingIndex = app.groups[3].controls.firstIndex { $0.controlID == .dial1CW }!
        app.groups[3].controls[bindingIndex].label = "Zoom"
        app.groups[3].controls[bindingIndex].pressActions = [
            .keyTap(24, modifiers: [.command], repeatCount: 2),
            .init(.delay(milliseconds: 25)),
            .chord([123, 124], modifiers: [.shift]),
            .init(.text("hello")),
            .init(.mouseClick(.left)),
            .init(.scroll(horizontal: 0, vertical: 1)),
            .init(.media(.playPause)),
            .init(.keyDown(keyCode: 55, modifiers: [])),
            .init(.keyUp(keyCode: 55, modifiers: [])),
            .init(.mouseButtonDown(.right)),
            .init(.mouseButtonUp(.right))
        ]
        app.groups[3].controls[bindingIndex].dialBehavior = .heldModifiers
        app.groups[3].controls[bindingIndex].heldModifiers = .command
        app.groups[3].controls[bindingIndex].idleTimeoutMilliseconds = 300
        app.groups[3].controls[bindingIndex].macroRetriggerPolicy = .restart
        app.groups[3].controls[bindingIndex].queueLimit = 12
        app.groups[3].controls[bindingIndex].macroRepeatCount = 3
        let nextIndex = app.groups[3].controls.firstIndex { $0.controlID == .setNext }!
        app.groups[3].controls[nextIndex].pressActions = [.init(.groupChange(offset: 2))]
        app.contextRules = [FocusRule(id: "numeric-input", name: "Numeric fields",
                                      targetGroupID: "group-4", kind: .numeric,
                                      role: "AXTextField")]
        document.profiles.append(app)
        try store.save(document)
        check(try store.load() == document, "save/load round trip")
        check(try store.load().effectiveProfile(bundleIdentifier: "app.rive.Rive")?.id == app.id,
              "bundle identifier selects app profile")
        check(try store.load().effectiveProfile(bundleIdentifier: "other.app")?.id == "global",
              "unmatched application falls back globally")
        check(try store.load().effectiveProfile(bundleIdentifier: "other.app", lockedProfileID: app.id)?.id == app.id,
              "manual lock overrides app detection")

        let exportURL = directory.appendingPathComponent("export.json")
        try store.exportDocument(document, to: exportURL)
        check(try store.importDocument(from: exportURL) == document, "export/import round trip")
        let originalData = try Data(contentsOf: store.fileURL)

        // Old schema-1 documents omitted the scheduling keys; they still load with defaults.
        var legacyJSON = try JSONSerialization.jsonObject(with: originalData) as! [String: Any]
        var legacyProfiles = legacyJSON["profiles"] as! [[String: Any]]
        for profileIndex in legacyProfiles.indices {
            var profile = legacyProfiles[profileIndex]
            var groups = profile["groups"] as! [[String: Any]]
            for groupIndex in groups.indices {
                var group = groups[groupIndex]
                var controls = group["controls"] as! [[String: Any]]
                for controlIndex in controls.indices {
                    controls[controlIndex].removeValue(forKey: "macroRetriggerPolicy")
                    controls[controlIndex].removeValue(forKey: "queueLimit")
                    controls[controlIndex].removeValue(forKey: "macroRepeatCount")
                }
                group["controls"] = controls
                groups[groupIndex] = group
            }
            profile["groups"] = groups
            profile.removeValue(forKey: "contextRules")
            legacyProfiles[profileIndex] = profile
        }
        legacyJSON["profiles"] = legacyProfiles
        let legacyURL = directory.appendingPathComponent("legacy.json")
        try JSONSerialization.data(withJSONObject: legacyJSON).write(to: legacyURL)
        let legacy = try store.importDocument(from: legacyURL)
        check(legacy.profiles.flatMap(\.groups).flatMap(\.controls).allSatisfy {
            $0.macroRetriggerPolicy == .queue && $0.queueLimit == 8 && $0.macroRepeatCount == 1
        } && legacy.profiles.allSatisfy { $0.contextRules.isEmpty },
              "legacy documents receive scheduling and focus-rule defaults")

        var invalid = document
        invalid.schemaVersion = 99
        rejects("future schema") { try store.validate(invalid) }
        invalid = document
        invalid.profiles.append(app)
        rejects("duplicate profile ID") { try store.validate(invalid) }
        invalid = document
        invalid.profiles[1].id = "another-profile"
        invalid.profiles[1].appBundleIdentifier = nil
        rejects("non-global profile without bundle ID") { try store.validate(invalid) }
        invalid = document
        invalid.profiles[0].groups.removeLast()
        rejects("must have six groups") { try store.validate(invalid) }
        invalid = document
        invalid.profiles[1].groups[0].controls[0].controlID = .key2
        rejects("duplicate control ID") { try store.validate(invalid) }
        invalid = document
        invalid.profiles[1].selectedGroupID = "missing"
        rejects("missing selected group") { try store.validate(invalid) }
        invalid = document
        invalid.profiles[1].groups[3].controls[bindingIndex].pressActions[0].repeatCount = 101
        rejects("unbounded repeat") { try store.validate(invalid) }
        invalid = document
        invalid.profiles[1].groups[3].controls[bindingIndex].queueLimit = 0
        rejects("queue limit below minimum") { try store.validate(invalid) }
        invalid.profiles[1].groups[3].controls[bindingIndex].queueLimit = 33
        rejects("queue limit above maximum") { try store.validate(invalid) }
        invalid = document
        invalid.profiles[1].groups[3].controls[bindingIndex].macroRepeatCount = 101
        rejects("macro repeat above maximum") { try store.validate(invalid) }
        invalid = document
        invalid.profiles[1].groups[3].controls[nextIndex].pressActions = [.init(.groupChange(offset: 0))]
        rejects("zero group offset") { try store.validate(invalid) }
        invalid.profiles[1].groups[3].controls[nextIndex].pressActions = [.init(.groupChange(offset: 6))]
        rejects("group offset beyond six groups") { try store.validate(invalid) }
        invalid = document
        invalid.profiles[1].groups[3].controls[bindingIndex].label = String(repeating: "😀", count: 15)
        rejects("label over 56 UTF-16LE bytes") { try store.validate(invalid) }
        invalid = document
        invalid.profiles[1].groups[3].name = String(repeating: "😀", count: 15)
        rejects("group name over 58 UTF-16LE bytes") { try store.validate(invalid) }
        invalid = document
        invalid.profiles[1].groups[3].controls[bindingIndex].pressActions =
            Array(repeating: .keyTap(24, repeatCount: 100), count: 64)
        invalid.profiles[1].groups[3].controls[bindingIndex].macroRepeatCount = 2
        rejects("expanded macro over 10000 steps") { try store.validate(invalid) }
        invalid = document
        invalid.profiles[0].contextRules = app.contextRules
        rejects("global focus rule") { try store.validate(invalid) }
        invalid = document
        invalid.profiles[1].contextRules[0].kind = nil
        invalid.profiles[1].contextRules[0].role = nil
        rejects("focus rule without criterion") { try store.validate(invalid) }
        invalid = document
        invalid.profiles[1].contextRules[0].targetGroupID = "missing"
        rejects("focus rule missing target group") { try store.validate(invalid) }
        invalid = document
        invalid.profiles[1].contextRules.append(app.contextRules[0])
        rejects("duplicate focus rule ID") { try store.validate(invalid) }
        invalid = document
        invalid.profiles[1].contextRules = (0...32).map {
            FocusRule(id: "rule-\($0)", name: "Rule \($0)", targetGroupID: "group-1", kind: .text)
        }
        rejects("more than 32 focus rules") { try store.validate(invalid) }
        invalid = document
        invalid.profiles[1].contextRules[0].kind = .secure
        rejects("secure focus rule") { try store.validate(invalid) }
        invalid = document
        invalid.profiles[1].contextRules[0].identifier = String(repeating: "x", count: 257)
        rejects("oversized focus identifier") { try store.validate(invalid) }

        let futureJSON = String(data: originalData, encoding: .utf8)!.replacingOccurrences(
            of: "\"schemaVersion\" : 1", with: "\"schemaVersion\" : 99")
        let futureURL = directory.appendingPathComponent("future.json")
        try Data(futureJSON.utf8).write(to: futureURL)
        rejects("future import version") { try _ = store.importDocument(from: futureURL) }
        check(try Data(contentsOf: store.fileURL) == originalData, "failed import preserves saved data")

        // A second valid save retains the previous primary as a recovery copy.
        var next = document
        next.profiles[1].name = "Rive Updated"
        try store.save(next)
        check(try store.loadBackup() == document, "backup is previous valid document")
        try Data("{broken".utf8).write(to: store.fileURL)
        rejects("corrupt primary") { try _ = store.load() }
        rejects("save refuses to overwrite corrupt primary") { try store.save(next) }
        check(try store.restoreBackup() == document, "explicit backup recovery")
        check(try store.load() == document, "restored primary is valid")

        print("Keydial profile store tests passed")
    }
}
