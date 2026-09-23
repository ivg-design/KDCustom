import AppKit
import SwiftUI

/// A rule sheet: each selector and its output share a row, with only the
/// selected rule's matching criteria expanded. Shortcuts never reserve space
/// for numeric options they do not use.
struct SmartDialEditor: View {
    @Binding var settings: SmartDialSettings
    @State private var expandedRule: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if settings.shortcut == nil {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 18) { numericOptions }
                    VStack(alignment: .leading, spacing: 8) { numericOptions }
                }.padding(.bottom, 5)
            }
            HStack {
                Text("WHEN HELD").frame(width: 112, alignment: .leading)
                Text("OUTPUT PER DETENT")
                Spacer()
            }.font(StudioTheme.font(9, weight: .bold)).tracking(1)
                .foregroundStyle(StudioTheme.secondaryText)
            ruleRow(title: "No modifiers", subtitle: "Default", shortcut: $settings.shortcut,
                    inherited: nil, step: $settings.step)
            ForEach(settings.modifierRules.indices, id: \.self) { index in
                let rule = settings.modifierRules[index]
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .center, spacing: 10) {
                        Button { expandedRule = expandedRule == rule.id ? nil : rule.id } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(KeyCodeName.modifiers(rule.modifiers)).font(StudioTheme.font(16, weight: .medium))
                                    Image(systemName: expandedRule == rule.id ? "chevron.up" : "chevron.down").font(.system(size: 8))
                                }
                                Text(rule.name).font(StudioTheme.font(10)).lineLimit(1)
                                    .foregroundStyle(StudioTheme.secondaryText)
                            }.frame(width: 112, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain).help("Edit the keyboard modifiers that select this rule")
                        SmartActionEditor(shortcut: $settings.modifierRules[index].shortcut,
                                          inherited: settings.shortcut, step: $settings.modifierRules[index].step,
                                          isRule: true)
                    }
                    if expandedRule == rule.id {
                        HStack(spacing: 10) {
                            TextField("Rule name", text: $settings.modifierRules[index].name)
                                .textFieldStyle(.roundedBorder).frame(maxWidth: 160)
                            modifierSelector($settings.modifierRules[index].modifiers)
                            Button(role: .destructive) {
                                settings.modifierRules.remove(at: index); expandedRule = nil
                            } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless).help("Delete this modifier rule")
                        }
                    }
                }.padding(10).background(StudioTheme.panelRaised, in: RoundedRectangle(cornerRadius: 5))
            }
            HStack {
                Button("Add modifier rule", systemImage: "plus") { addRule() }
                    .disabled(settings.modifierRules.count >= 8).buttonStyle(.borderless)
                    .font(StudioTheme.font(11)).foregroundStyle(StudioTheme.accent)
                Spacer()
                Text("Exact modifier match").font(StudioTheme.font(10)).foregroundStyle(StudioTheme.mutedText)
                    .help("Unassigned keyboard modifier combinations do nothing. Each dial direction is independent.")
            }.padding(.top, 3)
            if settings.shortcut == nil {
                Toggle("Use fallback actions for unsupported fields", isOn: $settings.fallbackToActions)
                    .font(StudioTheme.font(11)).padding(.top, 4)
            }
        }
    }

    @ViewBuilder private var numericOptions: some View {
        Picker("Direction", selection: $settings.direction) {
            Text("Increase").tag(SmartDialDirection.increase)
            Text("Decrease").tag(SmartDialDirection.decrease)
        }.frame(maxWidth: 210)
        Picker("Detect input", selection: $settings.detection) {
            Text("Automatic · app hints").tag(SmartDialDetection.automatic)
            Text("Numeric field override").tag(SmartDialDetection.numericField)
        }.help("Requires a writable numeric accessibility value. For custom app controls, choose a shortcut output.")
    }

    private func ruleRow(title: String, subtitle: String, shortcut: Binding<SmartShortcut?>,
                         inherited: SmartShortcut?, step: Binding<Double>) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(StudioTheme.font(12, weight: .medium))
                Text(subtitle).font(StudioTheme.font(10)).foregroundStyle(StudioTheme.secondaryText)
            }.frame(width: 112, alignment: .leading)
            SmartActionEditor(shortcut: shortcut, inherited: inherited, step: step, isRule: false)
        }.padding(10).background(StudioTheme.panelRaised, in: RoundedRectangle(cornerRadius: 5))
    }

    private func addRule() {
        let used = Set(settings.modifierRules.map { $0.modifiers.rawValue })
        let candidates: [KeyModifiers] = [.command, .control, [.option,.shift], [.command,.shift],
                                          [.control,.shift], .function, [.option,.command], [.control,.option]]
        guard let available = candidates.first(where: { !used.contains($0.rawValue) }) else { return }
        let rule = SmartModifierRule(name: "Custom", modifiers: available, step: 1)
        settings.modifierRules.append(rule); expandedRule = rule.id
    }

    private func modifierSelector(_ value: Binding<KeyModifiers>) -> some View {
        HStack(spacing: 3) {
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
        }.frame(maxWidth: 250)
    }
}

private struct SmartActionEditor: View {
    @Binding var shortcut: SmartShortcut?
    let inherited: SmartShortcut?
    @Binding var step: Double
    let isRule: Bool
    @State private var recording = false
    @State private var held: KeyModifiers = []

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { mode.frame(width: 93); value; if shortcut != nil { repeatCount } }
            VStack(alignment: .leading, spacing: 6) {
                HStack { mode; Spacer(); if shortcut != nil { repeatCount } }
                value
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ShortcutCaptureView(isRecording: recording, onKey: { code, modifiers in
            shortcut = SmartShortcut(keyCode: code, modifiers: modifiers, repeatCount: shortcut?.repeatCount ?? 1)
            recording = false
        }, onFlags: { held = $0 }, onCancel: { recording = false }).frame(width: 1, height: 1))
        .onDisappear { recording = false }
    }

    private var mode: some View {
        Picker("Output type", selection: Binding(get: { shortcut != nil }, set: { enabled in
            recording = false
            shortcut = enabled ? (inherited ?? SmartShortcut(keyCode: 126)) : nil
        })) {
            Text(isRule && inherited != nil ? "Inherit" : "Numeric").tag(false)
            Text("Shortcut").tag(true)
        }.labelsHidden().pickerStyle(.menu).font(StudioTheme.font(11))
    }

    @ViewBuilder private var value: some View {
        if let shortcut {
            HStack(spacing: 8) {
                Text(recording ? (held.isEmpty ? "Press shortcut…" : "\(KeyCodeName.modifiers(held)) …")
                     : KeyCodeName.modifiers(shortcut.modifiers) + KeyCodeName.title(shortcut.keyCode))
                    .font(StudioTheme.font(16, weight: .medium)).lineLimit(1)
                    .foregroundStyle(recording ? StudioTheme.accent : StudioTheme.text)
                Spacer(minLength: 4)
                Button(recording ? "Cancel" : "Record") { held = []; recording.toggle() }
                    .buttonStyle(.borderless).font(StudioTheme.font(11))
            }.padding(.horizontal, 9).frame(minWidth: 145, minHeight: 32)
                .background(StudioTheme.panel, in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(recording ? StudioTheme.accent : StudioTheme.divider))
                .help("Sends this exact shortcut; the held selector modifiers are consumed for this event.")
        } else if let inherited {
            Text("Base: \(KeyCodeName.modifiers(inherited.modifiers))\(KeyCodeName.title(inherited.keyCode))")
                .font(StudioTheme.font(13, weight: .medium)).frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(spacing: 8) {
                Text("Step").font(StudioTheme.font(11)).foregroundStyle(StudioTheme.secondaryText)
                TextField("1", value: $step, format: .number.precision(.fractionLength(0...6)))
                    .textFieldStyle(.roundedBorder).frame(width: 90)
                Spacer(minLength: 0)
            }
        }
    }

    private var repeatCount: some View {
        Stepper("\(shortcut?.repeatCount ?? 1)×", value: Binding(get: { shortcut?.repeatCount ?? 1 },
                    set: { shortcut?.repeatCount = $0 }), in: 1...100)
            .font(StudioTheme.font(11)).fixedSize().help("Repeat shortcut per detent")
    }
}
