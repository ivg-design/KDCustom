import Foundation

@main
enum HuionImportTests {
    static func check(_ condition: Bool, _ message: String) {
        if !condition { fatalError(message) }
    }

    static func hkey(_ code: Int, mask: Int = 0) -> [String: Any] {
        ["EKFunc": 1, "Keys": [code], "CombKeyMask": mask, "CustomName": "",
         "Text": "", "PluginCmd": "", "PluginAppPath": "", "AppPath": "",
         "Multimedia": 0, "MouseKeyFun": 0, "ToolFun": 0, "VKeyBoardNum": 0]
    }

    static func mkey() -> [String: Any] {
        ["MKeyType": 4, "Number": 0, "Reverse": false, "CurGroupIndex": 0,
         "mapMuxFunc": ["FuncGroup_0": [
            "CurMuxFuncClass": 2,
            "Custom": ["MuxFuncClass": 2,
                       "KeyL": ["Keys": [126], "ModifyKey": 8],
                       "KeyR": ["Keys": [125], "ModifyKey": 8]]
         ]]]
    }

    static func fixture() throws -> Data {
        var groups: [String: Any] = [:]
        for index in 0..<6 {
            var keys: [String: Any] = [
                "key1": hkey(8, mask: 8),
                "key3": hkey(123, mask: 10),
                "key4": ["EKFunc": 1, "Keys": [2, 3], "CombKeyMask": 0],
                "key5": ["EKFunc": 1, "Keys": [8], "CombKeyMask": 8,
                         "PluginCmd": "synthetic-macro"],
                "key8": ["EKFunc": 65_536],
                "key9": ["EKFunc": 131_072]
            ]
            if index == 1 { keys["key1"] = ["EKFunc": 99, "Keys": [8], "CombKeyMask": 8] }
            groups[String(index)] = ["Name": "Group \(index + 1)", "HKeys": keys,
                                     "MKeys": ["MKey0": mkey()], "SKeys": NSNull()]
        }
        let app: [String: Any] = ["AppPath": "/Applications/Synthetic.app", "KeyGroup": groups]
        let device: [String: Any] = ["KeyCfgGroupNum": 2, "KeyGroup": groups, "Apps": [app]]
        var data = try JSONSerialization.data(withJSONObject: ["HUION_T221": device])
        data.append(0) // Installed EKeySetting.dt has a trailing NUL byte.
        return data
    }

    static func rejects(_ message: String, _ body: () throws -> Void) {
        do { try body(); fatalError("Expected rejection: \(message)") }
        catch is HuionImportError { }
        catch { fatalError("Unexpected \(message) error: \(error)") }
    }

    static func main() throws {
        let importer = HuionImporter()
        let source = try fixture()
        let resolved = ["/Applications/Synthetic.app": "com.example.Synthetic"]

        let preview = try importer.importData(source, resolvedBundleIDs: resolved)
        check(preview.requiresPhysicalMapping, "unreviewed physical correlation is explicit")
        check(preview.document.profiles.count == 2, "resolved app profile is retained")
        check(preview.document.globalProfile?.selectedGroupID == "group-3", "active group imported")
        check(preview.document.globalProfile?.groups[0].binding(for: .key1)?.pressActions.isEmpty == true,
              "unmapped physical button remains unassigned")
        check(preview.document.globalProfile?.groups[0].binding(for: .dial1CW)?.pressActions.isEmpty == true,
              "unmapped physical dial remains unassigned")
        check(preview.document.globalProfile?.groups[0].binding(for: .setPrevious)?.pressActions ==
                [.init(.groupChange(offset: -1))], "verified set-button function imported")
        check(preview.warnings.contains { $0.message.contains("reviewed") },
              "review requirement is reported")

        let mapping = HuionControlMapping(buttonConfigIndexByPhysicalButton: [
            1: 1, 2: 3, 3: 4, 4: 5, 5: 0, 6: 2, 7: 6, 8: 7
        ], dialConfigIndexByPhysicalDial: [1: 0, 2: 1],
                                          leftEntryIsCounterclockwise: true)
        let result = try importer.importData(source, mapping: mapping, resolvedBundleIDs: resolved)
        check(!result.requiresPhysicalMapping, "explicit mapping satisfies physical correlation")
        let group = result.document.globalProfile!.groups[0]
        check(group.binding(for: .key1)?.pressActions ==
                [.keyTap(8, modifiers: .command)], "Huion command+C maps to physical key 1")
        check(group.binding(for: .key1)?.label == "⌘C", "shortcut label generated")
        check(group.binding(for: .key2)?.pressActions ==
                [.keyTap(123, modifiers: [.command, .shift])],
              "Huion command+shift+left maps to physical key 2")
        check(group.binding(for: .key3)?.pressActions.isEmpty == true,
              "multi-key Huion construct is not approximated")
        check(result.warnings.contains { $0.location == "global.group0.key4" &&
            $0.message.contains("one supported key") }, "unsupported multi-key construct is reported")
        check(group.binding(for: .key4)?.pressActions.isEmpty == true,
              "plugin-backed macro is not approximated as a key tap")
        check(result.warnings.contains { $0.location == "global.group0.key5" &&
            $0.message.contains("PluginCmd") }, "plugin-backed macro is reported")
        check(group.binding(for: .dial1CCW)?.pressActions ==
                [.keyTap(126, modifiers: .command)], "reviewed KeyL direction maps to CCW")
        check(group.binding(for: .dial1CW)?.pressActions ==
                [.keyTap(125, modifiers: .command)], "reviewed KeyR direction maps to CW")
        check(result.document.profiles[1].appBundleIdentifier == "com.example.Synthetic",
              "explicit bundle resolution attached")
        check(result.warnings.contains { $0.message.contains("inferred") },
              "modifier mask inference remains visible before apply")
        try ProfileStore().validate(result.document)

        let partialMapping = HuionControlMapping(buttonConfigIndexByPhysicalButton: [1: 1],
            dialConfigIndexByPhysicalDial: [:], leftEntryIsCounterclockwise: true)
        let partial = try importer.importData(source, mapping: partialMapping,
                                              resolvedBundleIDs: resolved)
        check(partial.requiresPhysicalMapping, "partial physical correlation remains review-required")
        check(partial.warnings.contains { $0.message.contains("partial") },
              "partial mapping is reported")

        let unresolved = try importer.importData(source, mapping: mapping)
        check(unresolved.document.profiles.count == 1, "unresolved app profile is not guessed")
        check(unresolved.unresolvedAppPaths == ["/Applications/Synthetic.app"],
              "unresolved path returned for caller review")

        let invalidMapping = HuionControlMapping(buttonConfigIndexByPhysicalButton: [1: 0, 2: 0],
                                                 dialConfigIndexByPhysicalDial: [:],
                                                 leftEntryIsCounterclockwise: true)
        rejects("duplicate config index") {
            _ = try importer.importData(source, mapping: invalidMapping)
        }
        rejects("non-NUL trailing data") {
            _ = try importer.importData(source + Data([0, 1]), mapping: mapping)
        }

        if let privateFixture = ProcessInfo.processInfo.environment["HUION_FIXTURE_PATH"] {
            let observed = try importer.importDocument(from: URL(fileURLWithPath: privateFixture))
            check(observed.document.globalProfile?.groups.count == 6,
                  "observed file retains six groups")
            check(observed.requiresPhysicalMapping,
                  "observed file requires reviewed physical mapping")
            try ProfileStore().validate(observed.document)
            print("Private Huion fixture inspected read-only; \(observed.warnings.count) bounded warnings")
        }

        print("Keydial Huion import tests passed")
    }
}
