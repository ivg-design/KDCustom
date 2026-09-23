import AppKit
import SwiftUI

struct SmartDialEditor: View {
    @Binding var settings: SmartDialSettings
    @State private var expandedRule: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Direction", selection: $settings.direction) {
                Text("Increase").tag(SmartDialDirection.increase)
                Text("Decrease").tag(SmartDialDirection.decrease)
            }
            Picker("Detect input", selection: $settings.detection) {
                Text("Automatic · app + control hints").tag(SmartDialDetection.automatic)
                Text("Numeric field · explicit override").tag(SmartDialDetection.numericField)
            }
            Text("Automatic uses numeric controls and known field labels in Rive and Adobe apps. A field must expose a writable numeric value. Use a shortcut override for custom controls.")
                .font(StudioTheme.font(10)).foregroundStyle(StudioTheme.secondaryText)
            VStack(alignment: .leading, spacing: 9) {
                Text("NO MODIFIERS").font(StudioTheme.font(10, weight: .bold)).foregroundStyle(StudioTheme.accent)
                numericStep($settings.step)
                SmartShortcutEditor(shortcut: $settings.shortcut, inherited: nil)
            }.padding(10).background(StudioTheme.panelRaised, in: RoundedRectangle(cornerRadius: 6))
            Text("WHILE HOLDING ON KEYBOARD").font(StudioTheme.font(10, weight: .bold)).foregroundStyle(StudioTheme.secondaryText)
            ForEach(settings.modifierRules.indices, id: \.self) { index in
                let rule = settings.modifierRules[index]
                VStack(alignment: .leading, spacing: 9) {
                    Button {
                        expandedRule = expandedRule == rule.id ? nil : rule.id
                    } label: {
                        HStack {
                            Text(KeyCodeName.modifiers(rule.modifiers)).font(StudioTheme.font(15, weight: .medium)).frame(minWidth: 30)
                            Text(rule.name).font(StudioTheme.font(11))
                            Spacer()
                            Text(rule.shortcut.map { KeyCodeName.modifiers($0.modifiers) + KeyCodeName.title($0.keyCode) } ?? "\(rule.step.formatted())")
                                .font(StudioTheme.font(11, weight: .medium)).foregroundStyle(StudioTheme.accent)
                            Image(systemName: expandedRule == rule.id ? "chevron.up" : "chevron.down").font(.system(size: 9))
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    if expandedRule == rule.id {
                        TextField("Name", text: $settings.modifierRules[index].name).textFieldStyle(.roundedBorder)
                        modifierSelector($settings.modifierRules[index].modifiers)
                        numericStep($settings.modifierRules[index].step)
                        SmartShortcutEditor(shortcut: $settings.modifierRules[index].shortcut, inherited: settings.shortcut)
                        Button("Remove modifier rule", role: .destructive) {
                            settings.modifierRules.remove(at: index); expandedRule = nil
                        }.font(StudioTheme.font(10))
                    }
                }.padding(10).background(StudioTheme.panelRaised, in: RoundedRectangle(cornerRadius: 6))
            }
            Button("Add modifier rule") {
                let used = Set(settings.modifierRules.map { $0.modifiers.rawValue })
                let candidates: [KeyModifiers] = [.command, .control, [.option,.shift], [.command,.shift], [.control,.shift], .function, [.option,.command], [.control,.option]]
                guard let available = candidates.first(where: { !used.contains($0.rawValue) }) else { return }
                let rule = SmartModifierRule(name: "Custom", modifiers: available, step: 1)
                settings.modifierRules.append(rule); expandedRule = rule.id
            }.disabled(settings.modifierRules.count >= 8).font(StudioTheme.font(11))
            Text("Modifier combinations match exactly. Unassigned combinations do nothing. Each dial direction has its own settings.")
                .font(StudioTheme.font(10)).foregroundStyle(StudioTheme.mutedText)
            Toggle("Use fallback actions when the field is unsupported", isOn: $settings.fallbackToActions)
                .font(StudioTheme.font(11))
            Text(settings.fallbackToActions
                 ? "The action flow below runs only when no numeric write was attempted. It preserves physically held modifiers."
                 : "Unsupported fields do nothing. Numeric contents are never logged or shared with agents.")
                .font(StudioTheme.font(10)).foregroundStyle(StudioTheme.mutedText)
        }
    }
    private func numericStep(_ value: Binding<Double>) -> some View {
        HStack {
            Text("Numeric step").font(StudioTheme.font(11))
            Spacer()
            TextField("1", value: value, format: .number.precision(.fractionLength(0...6)))
                .textFieldStyle(.roundedBorder).frame(width: 85).multilineTextAlignment(.trailing)
        }
    }
    private func modifierSelector(_ value: Binding<KeyModifiers>) -> some View {
        HStack(spacing: 4) {
            ForEach([KeyModifiers.command, .option, .control, .shift, .function], id: \.rawValue) { flag in
                Button {
                    var next = value.wrappedValue
                    if next.contains(flag) { next.remove(flag) } else { next.insert(flag) }
                    value.wrappedValue = next
                } label: {
                    Text(KeyCodeName.modifiers(flag)).font(StudioTheme.font(14))
                        .frame(maxWidth: .infinity, minHeight: 25)
                        .background(value.wrappedValue.contains(flag) ? StudioTheme.accentSoft : StudioTheme.panel,
                                    in: RoundedRectangle(cornerRadius: 4))
                }.buttonStyle(.plain)
            }
        }
    }
}

private struct SmartShortcutEditor: View {
    @Binding var shortcut: SmartShortcut?
    let inherited: SmartShortcut?
    @State private var recording = false
    @State private var held: KeyModifiers = []
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Toggle("Shortcut override", isOn: Binding(get: { shortcut != nil }, set: {
                recording = false; shortcut = $0 ? SmartShortcut(keyCode: 126) : nil
            })).font(StudioTheme.font(11))
            if let value = shortcut {
                HStack {
                    Text(recording ? (held.isEmpty ? "Press a shortcut…" : "\(KeyCodeName.modifiers(held)) Press a key…")
                         : KeyCodeName.modifiers(value.modifiers) + KeyCodeName.title(value.keyCode))
                        .font(StudioTheme.font(15, weight: .medium)).foregroundStyle(recording ? StudioTheme.accent : StudioTheme.text)
                    Spacer(minLength: 3)
                    Button(recording ? "Cancel" : "Record") { held = []; recording.toggle() }
                }.padding(8).background(StudioTheme.panel, in: RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(recording ? StudioTheme.accent : StudioTheme.divider))
                Stepper("Repeat \(value.repeatCount)×", value: Binding(get: { shortcut?.repeatCount ?? 1 }, set: { shortcut?.repeatCount = $0 }), in: 1...100)
                    .font(StudioTheme.font(10))
                Text("Sends exactly this shortcut. Held selector modifiers are omitted from these events. Numeric step is unused.")
                    .font(StudioTheme.font(10)).foregroundStyle(StudioTheme.mutedText)
            } else if let inherited {
                Text("Uses base shortcut \(KeyCodeName.modifiers(inherited.modifiers))\(KeyCodeName.title(inherited.keyCode)).")
                    .font(StudioTheme.font(10)).foregroundStyle(StudioTheme.mutedText)
            }
        }
        .background(ShortcutCaptureView(isRecording: recording, onKey: { code, modifiers in
            shortcut = SmartShortcut(keyCode: code, modifiers: modifiers, repeatCount: shortcut?.repeatCount ?? 1)
            recording = false
        }, onFlags: { held = $0 }, onCancel: { recording = false }).frame(width: 1,height: 1))
        .onDisappear { recording = false }
    }
}
