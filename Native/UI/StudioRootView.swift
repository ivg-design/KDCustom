import SwiftUI
import AppKit

struct StudioRootView: View {
    @ObservedObject var model: StudioModel
    @State private var showSettings = false
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
        .onChange(of: model.revision) { _, _ in refreshNames() }
        .sheet(isPresented: $showSettings) { StudioSettingsView(model: model) }
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
            Image(systemName: "circle.hexagongrid.fill").font(.system(size: 24)).foregroundStyle(StudioTheme.accent)
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
            Button { showSettings = true } label: { Image(systemName: "gearshape") }
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
                                Image(systemName: profile.appBundleIdentifier == nil ? "globe" : "app")
                                    .frame(width: 19).foregroundStyle(StudioTheme.secondaryText)
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
            if portrait {
                HStack(spacing: 0) {
                    devicePreview
                        .padding(20)
                        .frame(width: max(300, geometry.size.width * 0.43))
                        .frame(maxHeight: .infinity)
                    Divider().overlay(StudioTheme.divider)
                    VStack(spacing: 0) {
                        VStack(alignment: .leading, spacing: 18) {
                            profileHeader
                            groupSelector
                            accessNotice
                        }.padding(22)
                        Divider().overlay(StudioTheme.divider)
                        inspector
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                VStack(spacing: 0) {
                    HStack(alignment: .center, spacing: 30) {
                        profileHeader.frame(maxWidth: .infinity, alignment: .leading)
                        groupSelector.frame(width: min(400, geometry.size.width * 0.44))
                    }.padding(.horizontal, 24).padding(.vertical, 18)
                    devicePreview
                        .padding(.horizontal, 24).padding(.bottom, 14)
                        .frame(height: min(geometry.size.height * 0.49, geometry.size.width * 0.476 + 65))
                    Divider().overlay(StudioTheme.divider)
                    accessNotice
                    inspector
                }
            }
        }
    }

    private var inspector: some View {
        BindingDraftEditor(binding: model.currentBinding, wide: !portrait, save: model.saveBinding)
            .id(model.selectedProfileID + "/" + model.editorGroup.id + "/" + model.selectedControl.rawValue)
    }

    private var devicePreview: some View {
        DeviceIllustration(selectedControl: model.selectedControl, activeControls: model.activeControls,
            labels: Dictionary(uniqueKeysWithValues: model.editorGroup.controls.map { ($0.controlID, $0.label) }),
            groupName: model.editorGroup.name,
            groupNumber: (model.editorProfile.groups.firstIndex(where: { $0.id == model.editorGroup.id }) ?? 0) + 1,
            orientationDegrees: model.orientationDegrees, batteryPercent: model.batteryBucket,
            connection: model.ready ? model.transport : nil, onSelect: { model.selectedControl = $0 })
    }

    private var profileHeader: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 7) {
                TextField("Profile name", text: $profileName, onCommit: { model.renameProfile(profileName) })
                    .font(StudioTheme.font(26, weight: .light)).textFieldStyle(.plain)
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
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 5) {
                ForEach(Array(model.editorProfile.groups.enumerated()), id: \.element.id) { index, group in
                    Button { model.selectGroup(group.id) } label: {
                        Text("\(index + 1)").font(StudioTheme.font(14, weight: .medium))
                            .frame(maxWidth: .infinity).frame(height: 34)
                            .background(group.id == model.editorGroup.id ? StudioTheme.accentSoft : StudioTheme.panel,
                                        in: RoundedRectangle(cornerRadius: 5))
                            .foregroundStyle(group.id == model.editorGroup.id ? StudioTheme.accent : StudioTheme.secondaryText)
                    }.buttonStyle(.plain).help(group.name).accessibilityLabel("Group \(index + 1), \(group.name)")
                }
            }
            HStack {
                Text("GROUP").font(StudioTheme.font(9, weight: .medium)).tracking(1.4).foregroundStyle(StudioTheme.mutedText)
                TextField("Group name", text: $groupName, onCommit: { model.renameGroup(groupName) })
                    .textFieldStyle(.plain).font(StudioTheme.font(13, weight: .medium))
                if model.editorProfile.id == model.effectiveProfile.id {
                    Text("ACTIVE").font(StudioTheme.font(9, weight: .medium)).tracking(1).foregroundStyle(StudioTheme.accent)
                }
            }
        }
    }

    @ViewBuilder
    private var accessNotice: some View {
        if !model.accessibilityAllowed || !model.inputAllowed || model.huionRunning {
            HStack {
                Text(model.huionRunning ? "Quit Huion Keyboard so KDCustom can connect." : "Open Settings to finish device access.")
                    .foregroundStyle(StudioTheme.secondaryText)
                Button("Open settings") { showSettings = true }.buttonStyle(.bordered)
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
                Button("Check keyboard output…") { OutputVerifier.shared.show() }
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
