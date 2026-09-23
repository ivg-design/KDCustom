import Foundation

@main
enum SmartDialTests {
    private static func check(_ condition: Bool, _ message: String) {
        if !condition { fatalError(message) }
    }

    private static func rejectsProfile(_ message: String, _ edit: (inout ControlBinding) -> Void) {
        var document = KeydialDocument()
        let index = document.profiles[0].groups[0].controls.firstIndex { $0.controlID == .dial1CW }!
        document.profiles[0].groups[0].controls[index].dialBehavior = .smart
        document.profiles[0].groups[0].controls[index].smart = SmartDialSettings()
        edit(&document.profiles[0].groups[0].controls[index])
        do {
            try ProfileStore().validate(document)
            fatalError("Expected invalid profile: \(message)")
        } catch is ProfileStoreError {
            // Expected semantic rejection.
        } catch {
            fatalError("Unexpected error for \(message): \(error)")
        }
    }

    private static func rejectsMCP(_ message: String, _ binding: [String: Any]) {
        do {
            try MCPTools.validate(name: "kdcustom_set_binding", arguments: [
                "expectedRevision": "r1", "profileId": "global", "groupId": "group-1",
                "binding": binding
            ])
            fatalError("Expected MCP rejection: \(message)")
        } catch is MCPInputError {
            // Expected pre-dispatch rejection.
        } catch {
            fatalError("Unexpected MCP error for \(message): \(error)")
        }
    }

    static func main() throws {
        let defaults = SmartDialSettings()
        check(defaults.direction == .increase && defaults.detection == .automatic && defaults.step == 1,
              "Smart dial base defaults")
        check(defaults.modifierRules.count == 2 &&
              defaults.selection(for: [])?.step == 1 &&
              defaults.selection(for: .option)?.step == 0.01 &&
              defaults.selection(for: .shift)?.step == 10,
              "Base, Option fine, and Shift coarse use exact physical modifiers")
        check(defaults.selection(for: [.option, .shift]) == nil &&
              defaults.selection(for: .command) == nil &&
              defaults.selection(for: KeyModifiers(rawValue: 1)) == nil,
              "Unconfigured or unsupported modifier combinations are inert")

        let baseShortcut = SmartShortcut(keyCode: 126, modifiers: .command, repeatCount: 2)
        let overrideShortcut = SmartShortcut(keyCode: 125, modifiers: .option, repeatCount: 3)
        let custom = SmartDialSettings(direction: .decrease, detection: .numericField,
            step: 2, shortcut: baseShortcut,
            modifierRules: [
                .init(id: "option", name: "Fine", modifiers: .option, step: 0.25),
                .init(id: "shift", name: "Coarse", modifiers: .shift, step: 20,
                      shortcut: overrideShortcut)
            ], fallbackToActions: true)
        check(custom.selection(for: []) == SmartDialSelection(step: 2, shortcut: baseShortcut) &&
              custom.selection(for: .option) == SmartDialSelection(step: 0.25, shortcut: baseShortcut) &&
              custom.selection(for: .shift) == SmartDialSelection(step: 20, shortcut: overrideShortcut),
              "Modifier rule inherits base shortcut unless it overrides it")

        let legacyRule = try JSONDecoder().decode(SmartModifierRule.self, from:
            Data(#"{"id":"legacy","name":"Fine","modifiers":524288,"step":0.01}"#.utf8))
        check(legacyRule.inheritBaseShortcut, "Old rules preserve base-shortcut inheritance")
        for code: UInt16 in [125, 126] {
            let mixed = SmartDialSettings(shortcut: SmartShortcut(keyCode: code), modifierRules: [
                .init(id: "command", name: "Tenths", modifiers: .command, step: 0.1,
                      shortcut: SmartShortcut(keyCode: code, modifiers: .command)),
                .init(id: "option", name: "Hundredths", modifiers: .option, step: 0.01,
                      inheritBaseShortcut: false),
                .init(id: "shift", name: "Tens", modifiers: .shift, step: 10,
                      shortcut: SmartShortcut(keyCode: code, modifiers: .shift)),
                .init(id: "control-shift", name: "Hundreds", modifiers: [.control, .shift], step: 100,
                      inheritBaseShortcut: false)
            ], writeMethod: .keyboard, commitWithEnter: true)
            check(mixed.selection(for: [])?.shortcut == SmartShortcut(keyCode: code) &&
                  mixed.selection(for: .command)?.shortcut == SmartShortcut(keyCode: code, modifiers: .command) &&
                  mixed.selection(for: .shift)?.shortcut == SmartShortcut(keyCode: code, modifiers: .shift),
                  "Native base, Command and Shift remain shortcut outputs in both directions")
            check(mixed.selection(for: .option) == SmartDialSelection(step: 0.01, shortcut: nil) &&
                  mixed.selection(for: [.control, .shift]) == SmartDialSelection(step: 100, shortcut: nil) &&
                  mixed.selection(for: [.command, .shift]) == nil && mixed.hasNumericOutput,
                  "Explicit numeric rules bypass the base shortcut; combinations match exactly")
            let restoredMixed = try JSONDecoder().decode(SmartDialSettings.self, from: JSONEncoder().encode(mixed))
            check(restoredMixed == mixed, "Mixed output selection survives profile persistence")
            let mixedBinding = ControlBinding(controlID: .dial2CW, dialBehavior: .smart, smart: mixed)
            let mixedObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(mixedBinding)) as! [String: Any]
            try MCPTools.validate(name: "kdcustom_set_binding", arguments: [
                "expectedRevision": "r1", "profileId": "global", "groupId": "group-1", "binding": mixedObject
            ])
            var malformed = mixedObject
            var badSmart = malformed["smart"] as! [String: Any]
            var badRules = badSmart["modifierRules"] as! [[String: Any]]
            badRules[1]["inheritBaseShortcut"] = "false"
            badSmart["modifierRules"] = badRules; malformed["smart"] = badSmart
            rejectsMCP("numeric inheritance switch must be a boolean", malformed)
        }

        var document = KeydialDocument()
        let dialIndex = document.profiles[0].groups[0].controls.firstIndex { $0.controlID == .dial1CCW }!
        document.profiles[0].groups[0].controls[dialIndex].dialBehavior = .smart
        document.profiles[0].groups[0].controls[dialIndex].smart = custom
        try ProfileStore().validate(document)
        let encoded = try JSONEncoder().encode(document)
        let decoded = try JSONDecoder().decode(KeydialDocument.self, from: encoded)
        check(decoded == document, "Smart settings and shortcuts round-trip in a full profile")

        let oldBinding = ControlBinding(controlID: .dial1CW, pressActions: [.keyTap(24)])
        let oldJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(oldBinding)) as! [String: Any]
        check(oldJSON["smart"] == nil, "Legacy-style bindings omit nil smart")
        let restored = try JSONDecoder().decode(ControlBinding.self,
            from: JSONSerialization.data(withJSONObject: oldJSON))
        check(restored.smart == nil && restored.dialBehavior == .perStep,
              "Legacy binding decodes without Smart settings")
        let partial = try JSONDecoder().decode(SmartDialSettings.self, from: Data("{}".utf8))
        check(partial == defaults, "Omitted Smart settings fields decode to defaults")
        check(partial.writeMethod == .accessibility, "Existing profiles never start typing into fields after upgrade")
        check(partial.commitMethod == .manual && partial.nativeArrowStep == 1,
              "Existing numeric profiles keep explicit commit behavior")
        let oldEnter = try JSONDecoder().decode(SmartDialSettings.self, from: Data(#"{"commitWithEnter":true}"#.utf8))
        check(oldEnter.commitMethod == .enter, "Build 20 Enter settings decode without silently changing behavior")
        var arrowSettings = defaults
        arrowSettings.writeMethod = .keyboard; arrowSettings.commitMethod = .nativeArrow
        arrowSettings.nativeArrowStep = 0.1
        let arrowData = try JSONEncoder().encode(arrowSettings)
        check(try JSONDecoder().decode(SmartDialSettings.self, from: arrowData) == arrowSettings,
              "Native commit strategy and app-specific arrow magnitude round-trip")
        let arrowObject = try JSONSerialization.jsonObject(with: arrowData) as! [String: Any]
        check(arrowObject["commitWithEnter"] == nil && arrowObject["commitMethod"] as? String == "nativeArrow",
              "New settings encode one unambiguous commit method")
        rejectsProfile("invalid native arrow magnitude") { $0.smart!.nativeArrowStep = 0 }
        var typed = custom
        typed.writeMethod = .keyboard; typed.fallbackToActions = false
        typed.commitMethod = .nativeArrow; typed.nativeArrowStep = 0.1
        let typedData = try JSONEncoder().encode(typed)
        check(try JSONDecoder().decode(SmartDialSettings.self, from: typedData) == typed,
              "Explicit keyboard numeric strategy round-trips")
        var typedBinding = document.profiles[0].groups[0].controls[dialIndex]
        typedBinding.smart = typed
        let typedObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(typedBinding)) as! [String: Any]
        try MCPTools.validate(name: "kdcustom_set_binding", arguments: [
            "expectedRevision": "r1", "profileId": "global", "groupId": "group-1", "binding": typedObject
        ])
        var tabBinding = typedBinding
        tabBinding.smart!.commitMethod = .tabReturn
        let tabData = try JSONEncoder().encode(tabBinding)
        check(try JSONDecoder().decode(ControlBinding.self, from: tabData) == tabBinding,
              "Tab-return strategy round-trips without changing the mixed rules")
        try MCPTools.validate(name: "kdcustom_set_binding", arguments: [
            "expectedRevision": "r1", "profileId": "global", "groupId": "group-1",
            "binding": try JSONSerialization.jsonObject(with: tabData)
        ])
        for (key, badValue): (String, Any) in [("commitWithEnter", true), ("commitMethod", "unknown"),
                                               ("nativeArrowStep", "1"), ("nativeArrowStep", 0),
                                               ("nativeArrowStep", 1_000_001)] {
            var malformed = typedObject
            var settings = malformed["smart"] as! [String: Any]
            settings[key] = badValue; malformed["smart"] = settings
            rejectsMCP("invalid or conflicting commit settings: \(key)", malformed)
        }
        rejectsProfile("keyboard replacement cannot fall through into macros") {
            $0.smart!.writeMethod = .keyboard; $0.smart!.fallbackToActions = true
        }

        rejectsProfile("missing settings") { $0.smart = nil }
        var buttonDocument = KeydialDocument()
        let buttonIndex = buttonDocument.profiles[0].groups[0].controls.firstIndex { $0.controlID == .key1 }!
        buttonDocument.profiles[0].groups[0].controls[buttonIndex].dialBehavior = .smart
        buttonDocument.profiles[0].groups[0].controls[buttonIndex].smart = defaults
        do {
            try ProfileStore().validate(buttonDocument)
            fatalError("Expected Smart mode rejection on a physical button")
        } catch is ProfileStoreError {
            // Smart mode is only valid on physical dials.
        }
        rejectsProfile("nonfinite base step") { $0.smart!.step = .nan }
        rejectsProfile("infinite modifier step") { $0.smart!.modifierRules[0].step = .infinity }
        rejectsProfile("too-small base step") { $0.smart!.step = 0.0000001 }
        rejectsProfile("too-large base step") { $0.smart!.step = 1_000_001 }
        rejectsProfile("duplicate trigger") {
            $0.smart!.modifierRules[1].modifiers = .option
        }
        rejectsProfile("duplicate ID") { $0.smart!.modifierRules[1].id = "option" }
        rejectsProfile("empty modifier trigger") { $0.smart!.modifierRules[0].modifiers = [] }
        rejectsProfile("unsupported modifier trigger") {
            $0.smart!.modifierRules[0].modifiers = KeyModifiers(rawValue: 1)
        }
        rejectsProfile("more than eight modifier rules") {
            $0.smart!.modifierRules = (0..<9).map { index in
                .init(id: "rule-\(index)", name: "Rule \(index)",
                      modifiers: KeyModifiers(rawValue: UInt64(1 << (index + 17))), step: 1)
            }
        }
        rejectsProfile("oversize rule name") {
            $0.smart!.modifierRules[0].name = String(repeating: "A", count: 61)
        }
        rejectsProfile("invalid base shortcut") {
            $0.smart!.shortcut = SmartShortcut(keyCode: 256, repeatCount: 101)
        }
        rejectsProfile("invalid modifier shortcut") {
            $0.smart!.modifierRules[0].shortcut = SmartShortcut(keyCode: 24,
                modifiers: KeyModifiers(rawValue: 1), repeatCount: 0)
        }
        rejectsProfile("invalid dormant Smart settings") {
            $0.dialBehavior = .perStep
            $0.smart!.step = 0
        }

        let smartBinding = document.profiles[0].groups[0].controls[dialIndex]
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(smartBinding)) as! [String: Any]
        try MCPTools.validate(name: "kdcustom_set_binding", arguments: [
            "expectedRevision": "r1", "profileId": "global", "groupId": "group-1",
            "binding": object
        ])
        let schema = MCPTools.byName["kdcustom_set_binding"]!.inputSchema
        let properties = schema["properties"] as! [String: Any]
        let smartSchema = (properties["binding"] as! [String: Any])["properties"] as! [String: Any]
        check((smartSchema["smart"] as? [String: Any])?["additionalProperties"] as? Bool == false,
              "MCP advertises a closed Smart dial object")

        var nested = object["smart"] as! [String: Any]
        nested["fieldValue"] = "secret"
        object["smart"] = nested
        rejectsMCP("unknown Smart field", object)
        nested.removeValue(forKey: "fieldValue")
        var rules = nested["modifierRules"] as! [[String: Any]]
        rules[0]["unknown"] = true
        nested["modifierRules"] = rules
        object["smart"] = nested
        rejectsMCP("unknown modifier-rule field", object)
        rules[0].removeValue(forKey: "unknown")
        rules[0]["modifiers"] = ["rawValue": KeyModifiers.option.rawValue, "extra": true]
        nested["modifierRules"] = rules
        object["smart"] = nested
        rejectsMCP("modifier flags use a numeric raw value", object)
        rules[0]["modifiers"] = KeyModifiers.option.rawValue
        nested["modifierRules"] = rules
        nested["step"] = 0
        object["smart"] = nested
        rejectsMCP("invalid Smart step", object)
        nested["step"] = 1
        object["smart"] = nested
        object.removeValue(forKey: "smart")
        rejectsMCP("Smart mode requires settings", object)
        print("Smart dial model, validation, and MCP tests passed")
    }
}
