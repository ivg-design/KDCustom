import Foundation

/// A caller-reviewed correlation between Huion config indices and physical controls.
/// The repository verifies physical HID/OLED order, but not this config-index correlation.
struct HuionControlMapping: Equatable, Sendable {
    /// Physical buttons 1...8 (top row, then bottom row) to HKeys key0...key7.
    let buttonConfigIndexByPhysicalButton: [Int: Int]
    /// Physical dial 1 (inner) and 2 (outer) to MKeys MKey0...MKey1.
    let dialConfigIndexByPhysicalDial: [Int: Int]
    /// Direction of Huion Custom.KeyL, explicitly confirmed by the caller.
    let leftEntryIsCounterclockwise: Bool

    init(buttonConfigIndexByPhysicalButton: [Int: Int],
         dialConfigIndexByPhysicalDial: [Int: Int],
         leftEntryIsCounterclockwise: Bool) {
        self.buttonConfigIndexByPhysicalButton = buttonConfigIndexByPhysicalButton
        self.dialConfigIndexByPhysicalDial = dialConfigIndexByPhysicalDial
        self.leftEntryIsCounterclockwise = leftEntryIsCounterclockwise
    }

    var isValid: Bool {
        buttonConfigIndexByPhysicalButton.allSatisfy { (1...8).contains($0.key) && (0...7).contains($0.value) } &&
        Set(buttonConfigIndexByPhysicalButton.values).count == buttonConfigIndexByPhysicalButton.count &&
        dialConfigIndexByPhysicalDial.allSatisfy { (1...2).contains($0.key) && (0...1).contains($0.value) } &&
        Set(dialConfigIndexByPhysicalDial.values).count == dialConfigIndexByPhysicalDial.count
    }
}

struct HuionImportWarning: Equatable, Sendable {
    let location: String
    let message: String
}

struct HuionImportResult: Sendable {
    let document: KeydialDocument
    let warnings: [HuionImportWarning]
    let unresolvedAppPaths: [String]
    let importedActions: Int
    let skippedActions: Int
    let requiresPhysicalMapping: Bool
    /// The caller must show the report and obtain review before applying this candidate.
    let requiresReview: Bool
}

enum HuionImportError: Error, LocalizedError, Equatable {
    case fileTooLarge
    case invalidJSON
    case unsupportedDeviceSchema
    case invalidControlMapping

    var errorDescription: String? {
        switch self {
        case .fileTooLarge: "Huion settings exceed the 8 MB import limit."
        case .invalidJSON: "Huion settings are not valid JSON with optional trailing NUL bytes."
        case .unsupportedDeviceSchema: "The Huion settings do not contain a HUION_T221 device profile."
        case .invalidControlMapping: "The reviewed Huion control mapping has duplicate or out-of-range indices."
        }
    }
}

/// Read-only importer for the observed EKeySetting.dt JSON shape. It never writes vendor data.
struct HuionImporter {
    static let maximumFileBytes = 8 * 1024 * 1024

    func importDocument(from url: URL, mapping: HuionControlMapping? = nil,
                        resolvedBundleIDs: [String: String] = [:]) throws -> HuionImportResult {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        if let size = attributes[.size] as? NSNumber, size.intValue > Self.maximumFileBytes {
            throw HuionImportError.fileTooLarge
        }
        return try importData(Data(contentsOf: url), mapping: mapping,
                              resolvedBundleIDs: resolvedBundleIDs)
    }

    func importData(_ data: Data, mapping: HuionControlMapping? = nil,
                    resolvedBundleIDs: [String: String] = [:]) throws -> HuionImportResult {
        guard data.count <= Self.maximumFileBytes else { throw HuionImportError.fileTooLarge }
        if let mapping, !mapping.isValid { throw HuionImportError.invalidControlMapping }
        let jsonBytes = Data(data.prefix { $0 != 0 })
        guard data.dropFirst(jsonBytes.count).allSatisfy({ $0 == 0 }),
              let root = try? JSONSerialization.jsonObject(with: jsonBytes) as? [String: Any] else {
            throw HuionImportError.invalidJSON
        }
        guard let device = root["HUION_T221"] as? [String: Any] else {
            throw HuionImportError.unsupportedDeviceSchema
        }

        var context = Context(mapping: mapping)
        if mapping == nil {
            context.warn("device", "Physical button/dial correlation is unverified. Supply a reviewed HuionControlMapping before assigning their actions.")
        } else if mapping?.buttonConfigIndexByPhysicalButton.count != 8 ||
                    mapping?.dialConfigIndexByPhysicalDial.count != 2 {
            context.warn("device", "The reviewed control mapping is partial; unmapped physical controls remain unassigned.")
        }
        var global = KeydialProfile(id: "global", name: "Global")
        importGroups(from: device, into: &global, path: "global", context: &context)
        if let selected = Self.number(device["KeyCfgGroupNum"]), (0...5).contains(selected) {
            global.selectedGroupID = "group-\(selected + 1)"
        } else if device["KeyCfgGroupNum"] != nil {
            context.warn("global", "Unrecognized active group; selected Group 1 in the import candidate.")
        }

        var profiles = [global]
        var bundleIDs = Set<String>()
        var unresolvedPaths: [String] = []
        if let apps = device["Apps"] as? [[String: Any]] {
            for (index, app) in apps.prefix(127).enumerated() {
                let path = app["AppPath"] as? String ?? ""
                guard !path.isEmpty else {
                    context.warn("app[\(index)]", "Missing application path; profile was not imported.")
                    continue
                }
                let resolved = resolvedBundleIDs[path] ?? Self.bundleIdentifier(for: path)
                guard let bundleID = resolved, Self.validBundleID(bundleID) else {
                    unresolvedPaths.append(path)
                    context.warn("app[\(index)]", "Bundle identifier could not be verified from AppPath; resolve it before importing this profile.")
                    continue
                }
                guard bundleIDs.insert(bundleID).inserted else {
                    context.warn("app[\(index)]", "Duplicate bundle identifier; later profile was not imported.")
                    continue
                }
                let name = Self.profileName(for: path, index: index)
                var profile = KeydialProfile(id: "huion-app-\(index + 1)", name: name,
                                             appBundleIdentifier: bundleID)
                importGroups(from: app, into: &profile, path: "app[\(index)]", context: &context)
                profiles.append(profile)
            }
            if apps.count > 127 {
                context.warn("device.Apps", "Only the first 127 app profiles were inspected; profile limit is 128 including Global.")
            }
        } else if device["Apps"] != nil {
            context.warn("device.Apps", "Application profiles have an unsupported shape.")
        }

        let document = KeydialDocument(globalProfileID: "global", profiles: profiles)
        try ProfileStore().validate(document)
        let warnings = context.finishedWarnings
        return HuionImportResult(document: document, warnings: warnings,
                                 unresolvedAppPaths: unresolvedPaths,
                                 importedActions: context.importedActions,
                                 skippedActions: context.skippedActions,
                                 requiresPhysicalMapping: mapping?.buttonConfigIndexByPhysicalButton.count != 8 ||
                                     mapping?.dialConfigIndexByPhysicalDial.count != 2,
                                 requiresReview: !warnings.isEmpty || !unresolvedPaths.isEmpty)
    }

    private func importGroups(from source: [String: Any], into profile: inout KeydialProfile,
                              path: String, context: inout Context) {
        guard let sourceGroups = source["KeyGroup"] as? [String: Any] else {
            context.warn(path, "KeyGroup is missing; six empty groups were retained.")
            return
        }
        for groupIndex in 0..<6 {
            let groupPath = "\(path).group\(groupIndex)"
            guard let raw = sourceGroups[String(groupIndex)] as? [String: Any] else {
                context.warn(groupPath, "Group is missing; empty defaults were retained.")
                continue
            }
            if let name = raw["Name"] as? String, !name.isEmpty {
                if Self.validGroupName(name) { profile.groups[groupIndex].name = name }
                else { context.warn(groupPath, "Group name exceeds the OLED limit; default name was retained.") }
            }
            if raw["SKeys"] != nil, !(raw["SKeys"] is NSNull) {
                context.warn(groupPath, "SKeys are unsupported and were not imported.")
            }
            let hkeys = raw["HKeys"] as? [String: Any] ?? [:]
            for key in hkeys.keys.sorted() where !(0...9).contains(Int(key.dropFirst(3)) ?? -1) || !key.hasPrefix("key") {
                context.warn("\(groupPath).\(key)", "Unknown HKey entry was not imported.")
            }
            let mkeys = raw["MKeys"] as? [String: Any] ?? [:]
            for key in mkeys.keys.sorted() where key != "MKey0" && key != "MKey1" {
                context.warn("\(groupPath).\(key)", "Unknown MKey entry was not imported.")
            }
            importSetButtons(hkeys, group: &profile.groups[groupIndex], path: groupPath,
                             context: &context)
            importButtons(hkeys, group: &profile.groups[groupIndex], path: groupPath,
                          context: &context)
            importDials(mkeys,
                        group: &profile.groups[groupIndex], path: groupPath, context: &context)
        }
    }

    private func importSetButtons(_ hkeys: [String: Any], group: inout KeydialGroup,
                                  path: String, context: inout Context) {
        for (key, control, function, offset) in [
            ("key8", ControlID.setPrevious, 65_536, -1),
            ("key9", ControlID.setNext, 131_072, 1)
        ] {
            let location = "\(path).\(key)"
            let index = group.controls.firstIndex { $0.controlID == control }!
            group.controls[index].pressActions = []
            guard let entry = hkeys[key] as? [String: Any] else { continue }
            let ordinarySetButton = entry["CombKeyMask"] == nil ||
                Self.number(entry["CombKeyMask"]) == 0
            let ordinaryKeys = entry["Keys"] == nil || (entry["Keys"] as? [Int]) == [0]
            if Self.number(entry["EKFunc"]) == function, ordinarySetButton, ordinaryKeys {
                group.controls[index].pressActions = [.init(.groupChange(offset: offset))]
                context.importedActions += 1
            } else {
                context.skippedActions += 1
                context.warn(location, "Set-button entry differs from the observed group-change code; left unassigned.")
            }
        }
    }

    private func importButtons(_ hkeys: [String: Any], group: inout KeydialGroup,
                               path: String, context: inout Context) {
        guard let mapping = context.mapping else {
            let count = (0...7).filter { hkeys["key\($0)"] != nil }.count
            if count > 0 {
                context.skippedActions += count
                context.warn(path, "\(count) HKey entries need a reviewed config-index-to-physical-button mapping; all eight buttons remain unassigned.")
                for configIndex in 0...7 {
                    let key = "key\(configIndex)"
                    if let entry = hkeys[key] as? [String: Any] {
                        _ = Self.keyboardShortcut(entry, location: "\(path).\(key)", context: &context)
                    } else if hkeys[key] != nil {
                        context.warn("\(path).\(key)", "HKey entry has an unsupported shape.")
                    }
                }
            }
            return
        }
        for physicalButton in 1...8 {
            guard let configIndex = mapping.buttonConfigIndexByPhysicalButton[physicalButton] else {
                continue
            }
            let key = "key\(configIndex)"
            guard let entry = hkeys[key] as? [String: Any] else { continue }
            let location = "\(path).\(key)"
            guard let shortcut = Self.keyboardShortcut(entry, location: location, context: &context) else {
                context.skippedActions += 1
                continue
            }
            let control = ControlID(rawValue: "key\(physicalButton)")!
            let index = group.controls.firstIndex { $0.controlID == control }!
            group.controls[index].pressActions = [.keyTap(shortcut.code, modifiers: shortcut.modifiers)]
            group.controls[index].label = shortcut.label
            context.importedActions += 1
        }
    }

    private func importDials(_ mkeys: [String: Any], group: inout KeydialGroup,
                             path: String, context: inout Context) {
        guard let mapping = context.mapping else {
            if !mkeys.isEmpty {
                context.skippedActions += mkeys.count * 2
                context.warn(path, "Dial config indices and left/right direction need a reviewed mapping; dial actions remain unassigned.")
                for configIndex in 0...1 {
                    let key = "MKey\(configIndex)"
                    guard let entry = mkeys[key] as? [String: Any] else { continue }
                    let selected = Self.number(entry["CurGroupIndex"])
                    let mux = entry["mapMuxFunc"] as? [String: Any]
                    let selectedGroup = selected.flatMap { mux?["FuncGroup_\($0)"] as? [String: Any] }
                    if Self.number(selectedGroup?["CurMuxFuncClass"]) != 2 {
                        context.warn("\(path).\(key)",
                                     "Dial uses a default, app-specific, or unresolved function class; only explicit Custom shortcuts can be imported.")
                    }
                }
            }
            return
        }
        for physicalDial in 1...2 {
            guard let configIndex = mapping.dialConfigIndexByPhysicalDial[physicalDial],
                  let entry = mkeys["MKey\(configIndex)"] as? [String: Any] else { continue }
            let location = "\(path).MKey\(configIndex)"
            guard Self.number(entry["MKeyType"]) == 4,
                  Self.number(entry["Number"]) == configIndex,
                  entry["Reverse"] as? Bool == false,
                  entry["Sensibility"] == nil || Self.number(entry["Sensibility"]) == 1,
                  let selected = Self.number(entry["CurGroupIndex"]),
                  let mux = entry["mapMuxFunc"] as? [String: Any],
                  let selectedGroup = mux["FuncGroup_\(selected)"] as? [String: Any],
                  Self.number(selectedGroup["CurMuxFuncClass"]) == 2,
                  let custom = selectedGroup["Custom"] as? [String: Any],
                  Self.number(custom["MuxFuncClass"]) == 2 else {
                context.skippedActions += 2
                context.warn(location, "Only explicit non-reversed Custom dial shortcuts are supported; this dial was left unassigned.")
                continue
            }
            let leftControl: ControlID = physicalDial == 1 ? .dial1CCW : .dial2CCW
            let rightControl: ControlID = physicalDial == 1 ? .dial1CW : .dial2CW
            for (side, control) in [
                ("KeyL", mapping.leftEntryIsCounterclockwise ? leftControl : rightControl),
                ("KeyR", mapping.leftEntryIsCounterclockwise ? rightControl : leftControl)
            ] {
                guard let rawShortcut = custom[side] as? [String: Any],
                      let shortcut = Self.dialShortcut(rawShortcut,
                                                       location: "\(location).\(side)",
                                                       context: &context) else {
                    context.skippedActions += 1
                    continue
                }
                let index = group.controls.firstIndex { $0.controlID == control }!
                group.controls[index].pressActions = [.keyTap(shortcut.code, modifiers: shortcut.modifiers)]
                group.controls[index].label = shortcut.label
                context.importedActions += 1
            }
        }
    }

    private struct Shortcut {
        let code: UInt16
        let modifiers: KeyModifiers
        let label: String
    }

    private static func keyboardShortcut(_ entry: [String: Any], location: String,
                                         context: inout Context) -> Shortcut? {
        guard number(entry["EKFunc"]) == 1 else {
            context.warn(location, "Unsupported Huion function code; button left unassigned.")
            return nil
        }
        for field in ["Text", "PluginCmd", "PluginAppPath", "AppPath"] {
            if let value = entry[field] as? String, !value.isEmpty {
                context.warn(location, "\(field) adds unsupported behavior; button left unassigned.")
                return nil
            }
        }
        for field in ["Multimedia", "MouseKeyFun", "ToolFun", "VKeyBoardNum"] {
            if let value = number(entry[field]), value != 0 {
                context.warn(location, "\(field) is nonzero; button left unassigned.")
                return nil
            }
        }
        guard let codes = entry["Keys"] as? [Int], codes.count == 1,
              (0...254).contains(codes[0]),
              let modifiers = decodeModifierMask(number(entry["CombKeyMask"]),
                                                  location: location, context: &context) else {
            context.warn(location, "Expected one supported key code and modifier mask; button left unassigned.")
            return nil
        }
        let code = UInt16(codes[0])
        let custom = entry["CustomName"] as? String ?? ""
        return Shortcut(code: code, modifiers: modifiers,
                        label: label(customName: custom, code: code, modifiers: modifiers,
                                     location: location, context: &context))
    }

    private static func dialShortcut(_ entry: [String: Any], location: String,
                                     context: inout Context) -> Shortcut? {
        guard let codes = entry["Keys"] as? [Int], codes.count == 1,
              (0...254).contains(codes[0]),
              let modifiers = decodeModifierMask(number(entry["ModifyKey"]),
                                                  location: location, context: &context) else {
            context.warn(location, "Dial direction has no single supported key shortcut; left unassigned.")
            return nil
        }
        let code = UInt16(codes[0])
        return Shortcut(code: code, modifiers: modifiers,
                        label: label(customName: "", code: code, modifiers: modifiers,
                                     location: location, context: &context))
    }

    private static func decodeModifierMask(_ mask: Int?, location: String,
                                           context: inout Context) -> KeyModifiers? {
        switch mask {
        case 0: return []
        case 8:
            context.inferredModifierMask = true
            return .command
        case 10:
            context.inferredModifierMask = true
            return [.command, .shift]
        case 4:
            context.inferredModifierMask = true
            return .option
        default:
            context.warn(location, "Modifier mask \(mask.map(String.init) ?? "missing") is not verified; shortcut left unassigned.")
            return nil
        }
    }

    private static func label(customName: String, code: UInt16, modifiers: KeyModifiers,
                              location: String, context: inout Context) -> String {
        if !customName.isEmpty {
            if validControlLabel(customName) { return customName }
            context.warn(location, "Custom label exceeds 56 UTF-16LE bytes; generated shortcut label used.")
        }
        var prefix = ""
        if modifiers.contains(.command) { prefix += "⌘" }
        if modifiers.contains(.shift) { prefix += "⇧" }
        if modifiers.contains(.option) { prefix += "⌥" }
        return prefix + (keyNames[code] ?? "Key \(code)")
    }

    private static let keyNames: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
        8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
        16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
        23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
        31: "O", 32: "U", 34: "I", 35: "P", 36: "Return", 37: "L",
        38: "J", 40: "K", 45: "N", 46: "M", 48: "Tab", 49: "Space",
        51: "Delete", 53: "Escape", 123: "←", 124: "→", 125: "↓", 126: "↑"
    ]

    private static func number(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, String(cString: number.objCType) != "c",
              number.doubleValue.isFinite, number.doubleValue == Double(number.intValue) else { return nil }
        return number.intValue
    }

    private static func bundleIdentifier(for path: String) -> String? {
        guard path.hasPrefix("/"), path.hasSuffix(".app") else { return nil }
        return Bundle(url: URL(fileURLWithPath: path))?.bundleIdentifier
    }

    private static func profileName(for path: String, index: Int) -> String {
        let stem = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        return (1...80).contains(stem.utf8.count) && !stem.contains("\0") &&
            !stem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? stem : "Imported App \(index + 1)"
    }

    private static func validBundleID(_ value: String) -> Bool {
        value.contains(".") && !value.hasPrefix(".") && !value.hasSuffix(".") &&
        !value.contains("..") && (1...80).contains(value.utf8.count) &&
        value.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.").contains($0)
        }
    }

    private static func validGroupName(_ name: String) -> Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !name.contains("\0") && name.utf16.count * 2 <= 58
    }

    private static func validControlLabel(_ label: String) -> Bool {
        !label.contains("\0") && label.utf16.count * 2 <= 56
    }

    private struct Context {
        let mapping: HuionControlMapping?
        var warnings: [HuionImportWarning] = []
        var omittedWarnings = 0
        var importedActions = 0
        var skippedActions = 0
        var inferredModifierMask = false

        mutating func warn(_ location: String, _ message: String) {
            if warnings.count < 256 { warnings.append(.init(location: location, message: message)) }
            else { omittedWarnings += 1 }
        }

        var finishedWarnings: [HuionImportWarning] {
            var result = warnings
            if inferredModifierMask {
                result.insert(.init(location: "device",
                                    message: "Huion modifier masks 8/10/4 were inferred from the installed shortcut examples; review these shortcuts before applying."), at: 0)
            }
            if omittedWarnings > 0 {
                result.append(.init(location: "device", message: "\(omittedWarnings) additional import warnings omitted."))
            }
            return result
        }
    }
}
