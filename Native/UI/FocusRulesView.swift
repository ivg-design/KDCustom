import SwiftUI

/// Rules choose the four dial bindings from a group, without changing its buttons
/// or the profile's remembered default group.
struct FocusRulesView: View {
    @ObservedObject var model: StudioModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: FocusRule?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Intelligent dials").font(StudioTheme.font(25, weight: .light))
                    Text("Match a focused control, then use its dial assignments.")
                        .foregroundStyle(StudioTheme.secondaryText)
                }
                Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            Picker("Application profile", selection: $model.selectedProfileID) {
                ForEach(model.document.profiles.filter { $0.appBundleIdentifier != nil }, id: \.id) {
                    Text($0.name).tag($0.id)
                }
            }
            observation
            Divider()
            if model.editorProfile.appBundleIdentifier == nil {
                Text("Add an application profile to create focused-input rules. Global bindings remain the fallback.")
            } else {
                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("RULES · FIRST MATCH WINS").font(StudioTheme.font(10, weight: .medium))
                            .foregroundStyle(StudioTheme.secondaryText)
                        ScrollView {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(model.editorProfile.contextRules, id: \.id) { rule in
                                    Button {
                                        draft = rule; error = nil
                                    } label: {
                                        HStack {
                                            Circle().fill(rule.enabled ? StudioTheme.accent : StudioTheme.mutedText).frame(width: 5,height: 5)
                                            Text(rule.name).lineLimit(2)
                                            Spacer()
                                        }.padding(9).background(draft?.id == rule.id ? StudioTheme.accentSoft : Color.clear,
                                            in: RoundedRectangle(cornerRadius: 5))
                                    }.buttonStyle(.plain)
                                }
                            }
                        }
                        Button("Add numeric rule") {
                            draft = FocusRule(name: "Numeric fields", enabled: false,
                                targetGroupID: model.editorProfile.groups[1].id, kind: .numeric)
                            error = nil
                        }
                        Button("Learn last focused input") { learn() }
                            .disabled(!canLearn)
                        HStack {
                            Button { if let id = draft?.id { model.moveContextRule(id, direction: "up") } } label: { Image(systemName: "arrow.up") }
                                .help("Higher rule priority").disabled(selectedIndex == nil || selectedIndex == 0)
                            Button { if let id = draft?.id { model.moveContextRule(id, direction: "down") } } label: { Image(systemName: "arrow.down") }
                                .help("Lower rule priority").disabled(selectedIndex == nil || selectedIndex == model.editorProfile.contextRules.count - 1)
                        }
                    }.frame(width: 210)
                    Divider()
                    ScrollView {
                        if let value = draft {
                            editor(value)
                        } else {
                            Text("Create a rule for numeric controls, or click a field in the target app and return here to learn its identifier or label.")
                                .foregroundStyle(StudioTheme.secondaryText).padding(.vertical, 16)
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Text("Only dials change. Buttons and the default group stay the same. Unidentified controls use the app's default dial bindings. Focus matching reads metadata only; Smart mode reads numeric values when adjusting them.")
                .font(StudioTheme.font(11)).foregroundStyle(StudioTheme.secondaryText)
        }
        .padding(24).frame(width: 800, height: 620)
        .background(StudioTheme.canvas).foregroundStyle(StudioTheme.text)
        .tint(StudioTheme.accent)
        .onAppear {
            if model.editorProfile.appBundleIdentifier == nil,
               let profile = model.document.profiles.first(where: { $0.appBundleIdentifier != nil }) {
                model.selectedProfileID = profile.id
            }
        }
        .onChange(of: model.selectedProfileID) { _, _ in draft = nil; error = nil }
    }

    private var canLearn: Bool {
        guard let last = model.lastExternalFocus else { return false }
        return last.bundleIdentifier == model.editorProfile.appBundleIdentifier &&
            (last.identifier?.isEmpty == false || last.label?.isEmpty == false) &&
            last.kind != .secure && last.kind != .unavailable
    }
    private var selectedIndex: Int? { model.editorProfile.contextRules.firstIndex { $0.id == draft?.id } }
    private var observation: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("LAST OBSERVED INPUT").font(StudioTheme.font(10, weight: .medium)).tracking(1)
                Spacer()
                if let date = model.lastExternalFocusAt {
                    Text(date, style: .time).font(StudioTheme.font(11)).foregroundStyle(StudioTheme.mutedText)
                }
            }
            if let last = model.lastExternalFocus {
                Text("\(last.bundleIdentifier ?? "Unknown app") · \(last.role ?? "Unknown control") · \(last.kind.rawValue)")
                    .font(StudioTheme.font(12))
                Text(last.label ?? last.identifier ?? "This app exposes no field label or identifier.")
                    .font(StudioTheme.font(11)).foregroundStyle(StudioTheme.secondaryText).lineLimit(2)
            } else {
                Text("Click a field in Rive or an Adobe app with a profile, then return here. Custom canvas controls may not expose a field.")
                    .font(StudioTheme.font(12)).foregroundStyle(StudioTheme.secondaryText)
            }
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(StudioTheme.panel, in: RoundedRectangle(cornerRadius: 8))
    }
    private func editor(_ value: FocusRule) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField("Rule name", text: string(\.name)).textFieldStyle(.roundedBorder)
            Toggle("Enabled", isOn: Binding(get: { draft?.enabled ?? false }, set: { draft?.enabled = $0 }))
            Picker("Control type", selection: Binding(get: { draft?.kind?.rawValue ?? "any" }, set: {
                draft?.kind = $0 == "any" ? nil : FocusKind(rawValue: $0)
            })) {
                Text("Any identified control").tag("any")
                Text("Numeric / slider").tag(FocusKind.numeric.rawValue)
                Text("Text field").tag(FocusKind.text.rawValue)
                Text("Other control").tag(FocusKind.other.rawValue)
            }
            TextField("Role (optional)", text: optional(\.role)).textFieldStyle(.roundedBorder)
            TextField("Exact control identifier (optional)", text: optional(\.identifier)).textFieldStyle(.roundedBorder)
            TextField("Label contains (optional)", text: optional(\.labelContains)).textFieldStyle(.roundedBorder)
            Text("All specified conditions must match. Numeric detection uses advertised control capabilities; it does not inspect the typed value.")
                .font(StudioTheme.font(11)).foregroundStyle(StudioTheme.secondaryText)
            Picker("Use dial bindings from", selection: string(\.targetGroupID)) {
                ForEach(Array(model.editorProfile.groups.enumerated()), id: \.element.id) { index, group in
                    Text("\(index + 1) · \(group.name)").tag(group.id)
                }
            }
            Text("Configure the target group's four dial directions before enabling this rule.")
                .font(StudioTheme.font(11)).foregroundStyle(StudioTheme.secondaryText)
            if let error { Text(error).font(StudioTheme.font(11)).foregroundStyle(StudioTheme.accent) }
            HStack {
                Button("Save rule") { save() }.buttonStyle(.borderedProminent)
                Button("Edit dial actions") {
                    guard save() else { return }
                    model.editingContextGroupID = value.targetGroupID
                    model.selectedControl = .dial1CW
                    dismiss()
                }
                Spacer()
                if model.editorProfile.contextRules.contains(where: { $0.id == value.id }) {
                    Button("Delete", role: .destructive) { model.deleteContextRule(value.id); draft = nil }
                }
            }
        }.padding(.trailing, 6)
    }
    private func string(_ key: WritableKeyPath<FocusRule, String>) -> Binding<String> {
        Binding(get: { draft?[keyPath: key] ?? "" }, set: { draft?[keyPath: key] = $0 })
    }
    private func optional(_ key: WritableKeyPath<FocusRule, String?>) -> Binding<String> {
        Binding(get: { draft?[keyPath: key] ?? "" }, set: { draft?[keyPath: key] = $0.isEmpty ? nil : $0 })
    }
    private func learn() {
        guard canLearn, let last = model.lastExternalFocus else { return }
        draft = FocusRule(name: String((last.label ?? "Focused field").prefix(70)), enabled: false,
            targetGroupID: model.editorProfile.groups[1].id, role: last.role,
            identifier: last.identifier, labelContains: last.identifier == nil ? last.label : nil)
        error = nil
    }
    @discardableResult private func save() -> Bool {
        guard let draft else { return false }
        do { try model.saveContextRule(draft); error = nil; return true }
        catch { self.error = error.localizedDescription; return false }
    }
}
