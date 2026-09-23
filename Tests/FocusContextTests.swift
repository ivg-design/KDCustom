import Foundation

@main
enum FocusContextTests {
    static func check(_ condition: Bool, _ message: String) {
        if !condition { fatalError(message) }
    }

    static func main() {
        var profile = KeydialProfile(id: "editor", name: "Editor",
                                     appBundleIdentifier: "app.example.Editor")
        let normalDial = profile.groups[0].controls.firstIndex { $0.controlID == .dial1CW }!
        let normalKey = profile.groups[0].controls.firstIndex { $0.controlID == .key1 }!
        let alternateDial = profile.groups[1].controls.firstIndex { $0.controlID == .dial1CW }!
        let alternateKey = profile.groups[1].controls.firstIndex { $0.controlID == .key1 }!
        profile.groups[0].controls[normalDial].label = "Normal dial"
        profile.groups[0].controls[normalKey].label = "Normal key"
        profile.groups[1].controls[alternateDial].label = "Numeric dial"
        profile.groups[1].controls[alternateKey].label = "Other key"
        profile.contextRules = [
            FocusRule(id: "disabled", name: "Disabled", enabled: false,
                      targetGroupID: "group-2", kind: .numeric),
            FocusRule(id: "numeric", name: "Numbers", targetGroupID: "group-2",
                      kind: .numeric, role: "AXTextField"),
            FocusRule(id: "later", name: "Later", targetGroupID: "group-3",
                      kind: .numeric)
        ]
        let numeric = FocusSnapshot(bundleIdentifier: "app.example.Editor",
                                    role: "AXTextField", kind: .numeric)
        check(profile.matchingRule(for: numeric)?.id == "numeric",
              "first enabled matching rule wins in stored order")
        check(profile.binding(for: .dial1CW, focus: numeric)?.label == "Numeric dial" &&
              profile.binding(for: .key1, focus: numeric)?.label == "Normal key",
              "focus rule replaces dial binding only; button stays in selected group")
        check(profile.matchingRule(for: FocusSnapshot(bundleIdentifier: "other.app",
                                                       role: "AXTextField", kind: .numeric)) == nil,
              "rule never crosses application bundle boundaries")
        check(profile.matchingRule(for: FocusSnapshot(bundleIdentifier: "app.example.Editor",
                                                       role: "AXTextField", kind: .secure)) == nil &&
              profile.matchingRule(for: FocusSnapshot(bundleIdentifier: "app.example.Editor",
                                                       role: "AXTextField", kind: .unavailable)) == nil,
              "secure and unavailable focus never selects a rule")
        check(profile.binding(for: .dial1CW,
                                  focus: FocusSnapshot(bundleIdentifier: "app.example.Editor",
                                                       kind: .text))?.label == "Normal dial",
              "unmatched focus falls back to selected group")

        let labelRule = FocusRule(id: "label", name: "Labeled", targetGroupID: "group-2",
                                  labelContains: "amount")
        check(labelRule.matches(FocusSnapshot(label: "Total AMOUNT", kind: .numeric)) &&
              !labelRule.matches(FocusSnapshot(label: "Quantity", kind: .numeric)),
              "label criterion matches a case-insensitive substring only")
        let global = KeydialProfile(id: "global", name: "Global",
                                    contextRules: [FocusRule(id: "global-rule", name: "Rule",
                                                             targetGroupID: "group-2", kind: .numeric)])
        check(global.matchingRule(for: numeric) == nil,
              "global fallback cannot match application-specific focus")
        print("FocusContextTests passed")
    }
}
