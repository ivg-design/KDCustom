import SwiftUI
import AppKit

struct StudioRootView: View {
    @ObservedObject var model: StudioModel
    @State private var profileName = ""
    @State private var groupName = ""
    @State private var confirmDelete = false
    @State private var showHuionImport = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().overlay(StudioTheme.divider)
            HStack(spacing: 0) {
                sidebar.frame(width: 205)
                Divider().overlay(StudioTheme.divider)
                workspace.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider().overlay(StudioTheme.divider)
            footer
        }
        .background(StudioTheme.canvas).foregroundStyle(StudioTheme.text)
        .font(StudioTheme.font(13)).tint(StudioTheme.accent)
        .preferredColorScheme(model.colorScheme)
        .frame(minWidth: 1050, minHeight: 680)
        .onAppear { refreshNames() }
        .onChange(of: model.selectedProfileID) { _, _ in refreshNames() }
        .onChange(of: model.editingContextGroupID) { _, _ in refreshNames() }
        .onChange(of: model.revision) { _, _ in refreshNames() }
        .sheet(isPresented: $model.showingSettings) { StudioSettingsView(model: model) }
        .sheet(isPresented: $model.showingContextRules) { FocusRulesView(model: model) }
        .sheet(isPresented: $showHuionImport) { HuionImportView(apply: model.importHuion) }
        .alert("KDCustom", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
        .confirmationDialog("Delete \(model.editorProfile.name)?", isPresented: $confirmDelete) {
            Button("Delete profile", role: .destructive) { model.deleteProfile() }
        } message: { Text("The global fallback profile stays available. A backup of the previous configuration is kept.") }
    }
    private func refreshNames() { profileName = model.editorProfile.name; groupName = model.editorGroup.name }
    private var toolbar: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text("KDCustom").font(StudioTheme.font(19, weight: .medium))
                Text("KEYDIAL CONTROL STUDIO").font(StudioTheme.font(9, weight: .medium)).tracking(1.8).foregroundStyle(StudioTheme.secondaryText)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(model.activeAppName).font(StudioTheme.font(12, weight: .medium))
                Text("\(model.effectiveProfile.name) / \(model.effectiveGroup.name)")
                    .font(StudioTheme.font(11)).foregroundStyle(StudioTheme.secondaryText)
            }
            Button { model.paused.toggle() } label: {
                Label(model.paused ? "Resume" : "Pause", systemImage: model.paused ? "play.fill" : "pause.fill")
            }.buttonStyle(.bordered).help("Suspend all shortcut output")
            Button { model.showingContextRules = true } label: { Label("Intelligent dials", systemImage: "scope") }
                .buttonStyle(.bordered)
            Button { model.showingSettings = true } label: { Image(systemName: "gearshape") }
                .buttonStyle(.borderless).font(.system(size: 18)).help("Settings and connection")
                .accessibilityLabel("Settings and connection")
        }.padding(.horizontal, 22).frame(height: 73)
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("PROFILES").tracking(1.7).font(StudioTheme.font(10, weight: .medium)).foregroundStyle(StudioTheme.secondaryText)
                Spacer()
                Button { model.addApplicationProfile() } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless).help("Add an application profile").accessibilityLabel("Add an application profile")
            }.padding(18)
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(model.document.profiles, id: \.id) { profile in
                        Button { model.selectedProfileID = profile.id } label: {
                            HStack(spacing: 10) {
                                if let icon = model.icon(for: profile) {
                                    Image(nsImage: icon).resizable().scaledToFit().frame(width: 24, height: 24)
                                } else {
                                    Image(systemName: profile.appBundleIdentifier == nil ? "globe" : "app")
                                        .frame(width: 24, height: 24).foregroundStyle(StudioTheme.secondaryText)
                                }
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(profile.name).font(StudioTheme.font(13, weight: .medium)).lineLimit(1)
                                    Text(profile.appBundleIdentifier == nil ? "Fallback for every app" : profile.appBundleIdentifier!)
                                        .font(StudioTheme.font(9)).foregroundStyle(StudioTheme.secondaryText).lineLimit(1)
                                }
                                Spacer(minLength: 1)
                                if model.effectiveProfile.id == profile.id {
                                    Circle().fill(StudioTheme.accent).frame(width: 5, height: 5).help("Active profile")
                                }
                            }.padding(.horizontal, 10).padding(.vertical, 12)
                                .background(model.selectedProfileID == profile.id ? StudioTheme.panelRaised : .clear,
                                            in: RoundedRectangle(cornerRadius: 6))
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }.padding(.horizontal, 8)
            }
            VStack(alignment: .leading, spacing: 10) {
                Text(model.lockedProfileID == nil ? "Follows the active app" : "Profile locked")
                    .font(StudioTheme.font(11, weight: .medium))
                Text(model.lockedProfileID == nil ?
                     "Choose an app to edit its controls. Switching apps activates its profile automatically." :
                     "The locked profile stays active across apps. You can edit other profiles without activating them.")
                    .font(StudioTheme.font(11)).foregroundStyle(StudioTheme.secondaryText).fixedSize(horizontal: false, vertical: true)
                Button(model.lockedProfileID == nil ? "Lock to this profile" : "Use automatic detection") {
                    model.lockedProfileID = model.lockedProfileID == nil ? model.editorProfile.id : nil
                }.buttonStyle(.borderless).foregroundStyle(StudioTheme.accent)
                Divider()
                Menu("Profile files") {
                    Button("Duplicate for another app…") { model.duplicateProfile() }
                    Button("Reset this profile…") { model.resetProfile() }
                    Divider()
                    Button("Import from Huion…") { showHuionImport = true }
                    Button("Import profiles…") { model.importProfiles() }
                    Button("Export profiles…") { model.exportProfiles() }
                    Button("Restore previous backup") { model.restoreBackup() }
                }.menuStyle(.borderlessButton)
            }.padding(18)
        }.background(StudioTheme.panel)
    }
    private var portrait: Bool { !model.orientationDegrees.isMultiple(of: 180) }

    private var workspace: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                HStack(spacing: 24) {
                    profileHeader
                    VStack(alignment: .leading, spacing: 3) {
                        Text("GROUP NAME").font(StudioTheme.font(9, weight: .medium)).tracking(1)
                            .foregroundStyle(StudioTheme.mutedText)
                        TextField("Group name", text: $groupName, onCommit: { model.renameGroup(groupName) })
                            .textFieldStyle(.plain).font(StudioTheme.font(13, weight: .medium))
                    }.frame(width: 170)
                }.padding(.horizontal, 20).padding(.vertical, 12)
                Divider().overlay(StudioTheme.divider)
                accessNotice
                if portrait {
                    HStack(spacing: 0) {
                        groupSelector.padding(.horizontal, 10)
                        devicePreview.frame(width: min(260, max(190, geometry.size.width * 0.24)))
                            .padding(.vertical, 16)
                        dialSelector.frame(width: 116).padding(.horizontal, 10)
                        Divider().overlay(StudioTheme.divider)
                        inspector
                    }
                } else {
                    HStack(spacing: 16) {
                        groupSelector
                        devicePreview
                        dialSelector.frame(width: 146)
                    }
                    .padding(.horizontal, 18).padding(.vertical, 10)
                    .frame(height: min(250, max(225, geometry.size.height * 0.31)))
                    Divider().overlay(StudioTheme.divider)
                    inspector
                }
            }
        }
    }

    private var dialSelector: some View {
        VStack(alignment: .leading, spacing: 12) {
            dialControls("INNER · 1", controls: [.dial1CCW, .dial1CW])
            dialControls("OUTER · 2", controls: [.dial2CCW, .dial2CW])
        }
    }

    private func dialControls(_ title: String, controls: [ControlID]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(StudioTheme.font(9, weight: .bold)).tracking(1)
                .foregroundStyle(StudioTheme.secondaryText)
            ForEach(controls, id: \.self) { control in
                let clockwise = control == .dial1CW || control == .dial2CW
                let selected = model.selectedControl == control
                let label = model.editorGroup.binding(for: control)?.label ?? ""
                Button { model.selectedControl = control } label: {
                    HStack(spacing: 8) {
                        Image(systemName: clockwise ? "arrow.clockwise" : "arrow.counterclockwise")
                            .font(.system(size: 18, weight: .medium)).frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(clockwise ? "CW" : "CCW").font(StudioTheme.font(11, weight: .medium))
                            Text(label.isEmpty ? "Unassigned" : label).font(StudioTheme.font(10))
                                .foregroundStyle(selected ? StudioTheme.accent : StudioTheme.secondaryText).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }.padding(.horizontal, 8).frame(height: 39)
                        .background(selected ? StudioTheme.accentSoft : StudioTheme.panelRaised,
                                    in: RoundedRectangle(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(
                            model.activeControls.contains(control) ? StudioTheme.accent : .clear))
                        .foregroundStyle(selected ? StudioTheme.accent : StudioTheme.text)
                }.buttonStyle(.plain).help("\(title) \(clockwise ? "clockwise" : "counterclockwise"): \(label)")
                    .accessibilityLabel("\(title) \(clockwise ? "clockwise" : "counterclockwise"), \(label)")
            }
        }
    }

    private var inspector: some View {
        VStack(spacing: 0) {
            if model.editingContextGroupID != nil {
                HStack {
                    Text("Editing context dial group · default remains \(model.editorProfile.selectedGroup?.name ?? "Group 1")")
                    Spacer()
                    Button("Back to default") { model.editingContextGroupID = nil }
                }.font(StudioTheme.font(11)).foregroundStyle(StudioTheme.accent).padding(10)
            }
            BindingDraftEditor(binding: model.currentBinding, wide: true, save: model.saveBinding)
                .id(model.selectedProfileID + "/" + model.editorGroup.id + "/" + model.selectedControl.rawValue)
        }
    }

    private var devicePreview: some View {
        let base = model.editorProfile.selectedGroup ?? model.editorProfile.groups[0]
        let preview = model.editingContextGroupID == nil ? model.editorGroup : base
        let labels = preview.controls.map { control in
            let source = control.controlID.isDial ? model.editorGroup.binding(for: control.controlID) ?? control : control
            return (source.controlID, source.label)
        }
        return DeviceIllustration(selectedControl: model.selectedControl, activeControls: model.activeControls,
            labels: Dictionary(uniqueKeysWithValues: labels),
            groupName: preview.name,
            groupNumber: (model.editorProfile.groups.firstIndex(where: { $0.id == preview.id }) ?? 0) + 1,
            orientationDegrees: model.orientationDegrees, batteryPercent: model.batteryBucket, showDirectionControls: false,
            connection: model.ready ? model.transport : nil, onSelect: {
                if model.editingContextGroupID != nil && !$0.isDial { model.editingContextGroupID = nil }
                model.selectedControl = $0
            })
    }

    private var profileHeader: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 7) {
                TextField("Profile name", text: $profileName, onCommit: { model.renameProfile(profileName) })
                    .font(StudioTheme.font(21, weight: .medium)).textFieldStyle(.plain)
                Text(model.editorProfile.appBundleIdentifier ?? "Default controls for applications without their own profile")
                    .font(StudioTheme.font(11)).foregroundStyle(StudioTheme.secondaryText).lineLimit(2)
            }
            Spacer(minLength: 4)
            if model.editorProfile.id != model.document.globalProfileID {
                Button { confirmDelete = true } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless).foregroundStyle(StudioTheme.mutedText).help("Delete this profile")
            }
        }
    }

    private var groupSelector: some View {
        VStack(spacing: 4) {
            Text("GROUP").font(StudioTheme.font(8, weight: .bold)).tracking(0.8)
                .foregroundStyle(StudioTheme.secondaryText).padding(.bottom, 3)
            ForEach(Array(model.editorProfile.groups.enumerated()), id: \.element.id) { index, group in
                Button { model.selectGroup(group.id) } label: {
                    Text("\(index + 1)").font(StudioTheme.font(13, weight: .medium))
                        .frame(width: 38, height: 27)
                        .background(group.id == model.editorGroup.id ? StudioTheme.accentSoft : StudioTheme.panel,
                                    in: RoundedRectangle(cornerRadius: 5))
                        .foregroundStyle(group.id == model.editorGroup.id ? StudioTheme.accent : StudioTheme.secondaryText)
                }.buttonStyle(.plain).help(group.name).accessibilityLabel("Group \(index + 1), \(group.name)")
            }
        }.frame(width: 42)
    }

    @ViewBuilder
    private var accessNotice: some View {
        if !model.accessibilityAllowed || !model.inputAllowed || model.huionRunning {
            HStack {
                Text(model.huionRunning ? "Quit Huion Keyboard so KDCustom can connect." : "Open Settings to finish device access.")
                    .foregroundStyle(StudioTheme.secondaryText)
                Button("Open settings") { model.showingSettings = true }.buttonStyle(.bordered)
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(StudioTheme.panel)
        }
    }
    private var footer: some View {
        HStack(spacing: 8) {
            Circle().fill(model.ready ? StudioTheme.accent : StudioTheme.mutedText).frame(width: 6, height: 6)
            Text("\(model.connection) · \(model.transport)")
            if let battery = model.deviceSettings["battery"] { Text("· \(battery)") }
            Spacer()
            Text(model.outputStatus)
        }.font(StudioTheme.font(10)).foregroundStyle(StudioTheme.secondaryText).padding(.horizontal, 18).frame(height: 31)
    }
}

private struct StudioSettingsView: View {
    @ObservedObject var model: StudioModel
    @Environment(\.dismiss) private var dismiss
    @State private var showDiagnostics = false
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("Settings").font(StudioTheme.font(25, weight: .light))
                Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            Form {
                Section("Appearance") {
                    Picker("Theme", selection: $model.appearance) {
                        Text("Dark graphite").tag("dark")
                        Text("Light").tag("light")
                        Text("Follow macOS").tag("system")
                    }
                }
                Section("Device access") {
                    permission("Accessibility", allowed: model.accessibilityAllowed) { model.requestAccessibility() }
                    permission("Input Monitoring", allowed: model.inputAllowed) { model.openPrivacy("Privacy_ListenEvent") }
                    permission("Bluetooth", allowed: model.bluetoothAllowed) { model.openPrivacy("Privacy_Bluetooth") }
                    HStack {
                        Text("\(model.connection) · \(model.transport)"); Spacer()
                        Button("Reconnect") { model.reconnect() }
                    }
                    HStack {
                        Button("Use KDCustom") { model.useKDCustom() }
                        Button("Return to Huion") { model.returnToHuion() }
                        Spacer()
                        Button("Release all holds") { model.emergencyRelease() }
                    }
                    Toggle("Start at login", isOn: Binding(get: { model.loginEnabled }, set: { model.setLogin($0) }))
                    Text("Closing the window keeps controls active in the menu bar. Pause or Quit to stop shortcut output.")
                        .font(StudioTheme.font(11)).foregroundStyle(StudioTheme.secondaryText)
                }
                Section("Screen and battery") {
                    HStack { Text("Battery"); Spacer(); Text(model.deviceSettings["battery"] ?? "Not read"); Button("Read") { model.query(.battery) } }
                    HStack { Text("Rotation"); Spacer(); Text(model.deviceSettings["rotation"] ?? "Not read"); Button("Read") { model.query(.rotation) }; Button("Rotate 90°") { model.step(.rotationNext) } }
                    HStack { Text("Sleep"); Spacer(); Text(model.deviceSettings["sleep"] ?? "Not read"); Button("Read") { model.query(.dormantTime) }; Button("−") { model.step(.dormantTimeDown) }; Button("+") { model.step(.dormantTimeUp) } }
                    if model.deviceSettings["brightness"] != nil {
                        HStack { Text("Brightness"); Spacer(); Text(model.deviceSettings["brightness"]!); Button("−") { model.step(.brightnessDown) }; Button("+") { model.step(.brightnessUp) } }
                    }
                }
                Section("Agent configuration · MCP") {
                    Text("Agents can create app profiles and set every button, dial direction, macro, and label. Keep KDCustom open while using its tools.")
                        .font(StudioTheme.font(12)).foregroundStyle(StudioTheme.secondaryText)
                    Button("Copy MCP configuration") {
                        let config = ["mcpServers": ["kdcustom": ["command": Bundle.main.executablePath ?? "", "args": ["--mcp"]] as [String: Any]]]
                        if let data = try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys]), let string = String(data: data, encoding: .utf8) {
                            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(string, forType: .string)
                        }
                    }
                }
                Button("Check keyboard output…") {
                    model.showingSettings = false
                    OutputVerifier.shared.onRecoveredKeyState = { [weak model] in model?.recoverDiagnosticKeyState() }
                    DispatchQueue.main.async { OutputVerifier.shared.show() }
                }
                Button("Check Smart numeric input…") {
                    model.showingSettings = false
                    DispatchQueue.main.async { SmartInputVerifier.shared.show() }
                }
                Button("Export diagnostics…") { model.exportDiagnostics() }
                DisclosureGroup("Connection diagnostics", isExpanded: $showDiagnostics) {
                    ScrollView {
                        Text(model.recentEvents.suffix(25).joined(separator: "\n"))
                            .font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(height: 130)
                }
            }.formStyle(.grouped)
        }.padding(24).frame(width: 650, height: 780).background(StudioTheme.canvas).preferredColorScheme(model.colorScheme).tint(StudioTheme.accent)
    }
    private func permission(_ name: String, allowed: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: allowed ? "checkmark.circle.fill" : "circle").foregroundStyle(allowed ? StudioTheme.accent : StudioTheme.mutedText)
            Text(name); Spacer(); Text(allowed ? "Allowed" : "Required").foregroundStyle(StudioTheme.secondaryText)
            if !allowed { Button("Open", action: action) }
        }
    }
}
