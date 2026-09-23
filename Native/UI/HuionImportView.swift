import AppKit
import SwiftUI

/// Reviews a vendor settings file without modifying it. The caller decides how to
/// apply the resulting document to the current KDCustom configuration.
struct HuionImportView: View {
    let apply: (KeydialDocument) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var sourceURL: URL?
    @State private var inventory: HuionImportResult?
    @State private var candidate: HuionImportResult?
    @State private var errorMessage: String?
    @State private var buttonIndices: [Int?] = Array(repeating: nil, count: 8)
    @State private var dialIndices: [Int?] = Array(repeating: nil, count: 2)
    @State private var leftIsCounterclockwise: Bool?
    @State private var mappingConfirmed = false
    @State private var warningsReviewed = false

    private var preview: HuionImportResult? { candidate ?? inventory }

    private var mappingComplete: Bool {
        buttonIndices.allSatisfy { $0 != nil } &&
        Set(buttonIndices.compactMap { $0 }).count == 8 &&
        dialIndices.allSatisfy { $0 != nil } &&
        Set(dialIndices.compactMap { $0 }).count == 2 &&
        leftIsCounterclockwise != nil
    }

    private var canApply: Bool {
        sourceURL != nil && mappingComplete && mappingConfirmed && warningsReviewed &&
        candidate != nil && candidate?.requiresPhysicalMapping == false
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(StudioTheme.divider).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    fileSection
                    if inventory != nil {
                        mappingSection
                        reportSection
                        confirmationSection
                    }
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            Rectangle().fill(StudioTheme.divider).frame(height: 1)
            footer
        }
        .frame(minWidth: 660, idealWidth: 750, minHeight: 560, idealHeight: 700)
        .background(StudioTheme.canvas)
        .foregroundStyle(StudioTheme.text)
        .font(StudioTheme.font(12))
        .tint(StudioTheme.accent)
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "square.and.arrow.down.on.square")
                .font(.system(size: 23))
                .foregroundStyle(StudioTheme.accent)
            VStack(alignment: .leading, spacing: 5) {
                Text("IMPORT HUION SETTINGS")
                    .font(StudioTheme.font(10, weight: .bold))
                    .tracking(1.5)
                    .foregroundStyle(StudioTheme.accent)
                Text("Review controls before import")
                    .font(StudioTheme.font(22, weight: .medium))
                Text("The Huion file is read only. Unsupported actions and unresolved apps stay unassigned.")
                    .foregroundStyle(StudioTheme.secondaryText)
            }
            Spacer(minLength: 0)
        }
        .padding(22)
    }

    private var fileSection: some View {
        section("1 · SOURCE FILE") {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(sourceURL?.lastPathComponent ?? "No file selected")
                        .font(StudioTheme.font(13, weight: .medium))
                    Text(sourceURL?.path ?? "Choose the installed EKeySetting.dt file or a copy of it.")
                        .foregroundStyle(StudioTheme.secondaryText)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 8)
                Button(sourceURL == nil ? "Choose file…" : "Change file…", action: chooseFile)
                    .buttonStyle(.bordered)
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var mappingSection: some View {
        section("2 · MATCH PHYSICAL CONTROLS") {
            Text("Huion's config-key indices have not been verified against the physical buttons and dials. Choose each correlation from your device or known layout. Each config key can be used once.")
                .foregroundStyle(StudioTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .top, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("PHYSICAL BUTTONS").font(StudioTheme.font(10, weight: .bold))
                        .tracking(1).foregroundStyle(StudioTheme.accent)
                    ForEach(0..<8, id: \.self) { index in
                        HStack {
                            Text("Button \(index + 1)")
                                .frame(width: 88, alignment: .leading)
                            Picker("Button \(index + 1) config key", selection: $buttonIndices[index]) {
                                Text("Choose HKey").tag(Optional<Int>.none)
                                ForEach(0..<8, id: \.self) { value in
                                    Text("key\(value)").tag(Optional(value))
                                }
                            }
                            .labelsHidden()
                            .frame(maxWidth: 140)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("PHYSICAL DIALS").font(StudioTheme.font(10, weight: .bold))
                        .tracking(1).foregroundStyle(StudioTheme.accent)
                    ForEach(0..<2, id: \.self) { index in
                        HStack {
                            Text(index == 0 ? "Dial 1 · inner" : "Dial 2 · outer")
                                .frame(width: 110, alignment: .leading)
                            Picker("Dial \(index + 1) config key", selection: $dialIndices[index]) {
                                Text("Choose MKey").tag(Optional<Int>.none)
                                ForEach(0..<2, id: \.self) { value in
                                    Text("MKey\(value)").tag(Optional(value))
                                }
                            }
                            .labelsHidden()
                            .frame(maxWidth: 140)
                        }
                    }
                    Text("DIAL DIRECTION").font(StudioTheme.font(10, weight: .bold))
                        .tracking(1).foregroundStyle(StudioTheme.accent)
                        .padding(.top, 8)
                    Picker("Huion KeyL means", selection: $leftIsCounterclockwise) {
                        Text("Choose direction").tag(Optional<Bool>.none)
                        Text("Counterclockwise").tag(Optional(true))
                        Text("Clockwise").tag(Optional(false))
                    }
                    .frame(maxWidth: 260)
                    Text("KeyR is assigned the opposite direction.")
                        .font(StudioTheme.font(10))
                        .foregroundStyle(StudioTheme.secondaryText)
                    Button("Fill numbered candidate") {
                        buttonIndices = (0..<8).map(Optional.some)
                        dialIndices = (0..<2).map(Optional.some)
                        invalidateMapping()
                    }
                    .buttonStyle(.borderless)
                    .help("Fills key0…key7 and MKey0…MKey1 in number order. You must still verify and confirm this correlation.")
                    .padding(.top, 5)
                }
            }
            .onChange(of: buttonIndices) { _, _ in invalidateMapping() }
            .onChange(of: dialIndices) { _, _ in invalidateMapping() }
            .onChange(of: leftIsCounterclockwise) { _, _ in invalidateMapping() }

            if !mappingComplete {
                Text("Select eight different HKeys, two different MKeys, and the direction of KeyL.")
                    .foregroundStyle(StudioTheme.accent)
            }
            Toggle("I verified this physical-to-Huion mapping, including KeyL direction.",
                   isOn: $mappingConfirmed)
                .disabled(!mappingComplete)
                .onChange(of: mappingConfirmed) { _, confirmed in
                    if confirmed { buildCandidate() }
                    else { candidate = nil; warningsReviewed = false }
                }
        }
    }

    private var reportSection: some View {
        section("3 · IMPORT REPORT") {
            if let preview {
                Text(candidate == nil ? "Inventory only · physical controls remain unassigned" :
                        "Mapped candidate · review every omission before applying")
                    .font(StudioTheme.font(12, weight: .medium))
                    .foregroundStyle(candidate == nil ? StudioTheme.accent : StudioTheme.text)
                HStack(spacing: 18) {
                    metric("Profiles", preview.document.profiles.count)
                    metric("Imported actions", preview.importedActions)
                    metric("Skipped actions", preview.skippedActions)
                    metric("Warnings", preview.warnings.count)
                    metric("Unresolved apps", preview.unresolvedAppPaths.count)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if !preview.unresolvedAppPaths.isEmpty {
                    Text("UNRESOLVED APPLICATIONS")
                        .font(StudioTheme.font(10, weight: .bold))
                        .tracking(1).foregroundStyle(StudioTheme.accent)
                    Text("These profiles were omitted because their bundle IDs could not be verified:")
                        .foregroundStyle(StudioTheme.secondaryText)
                    ForEach(Array(preview.unresolvedAppPaths.enumerated()), id: \.offset) { _, path in
                        Text(path).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                Text("WARNINGS AND OMISSIONS")
                    .font(StudioTheme.font(10, weight: .bold))
                    .tracking(1).foregroundStyle(StudioTheme.accent)
                if preview.warnings.isEmpty {
                    Text("No importer warnings.").foregroundStyle(StudioTheme.secondaryText)
                } else {
                    ForEach(Array(preview.warnings.enumerated()), id: \.offset) { _, warning in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(warning.location)
                                .font(StudioTheme.font(10, weight: .medium))
                                .foregroundStyle(StudioTheme.accent)
                                .textSelection(.enabled)
                            Text(warning.message)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                    }
                }
            }
        }
    }

    private var confirmationSection: some View {
        section("4 · CONFIRM REVIEW") {
            Text("The mapped candidate may omit unsupported shortcuts and unresolved app profiles. Applying passes this candidate to KDCustom for the final profile replacement review.")
                .foregroundStyle(StudioTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("I reviewed the full warning list, skipped actions, and unresolved apps.",
                   isOn: $warningsReviewed)
                .disabled(candidate == nil)
        }
    }

    private var footer: some View {
        HStack {
            Text(canApply ? "Ready for final profile review" : "Import remains read only until both reviews are confirmed")
                .font(StudioTheme.font(11))
                .foregroundStyle(StudioTheme.secondaryText)
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Apply reviewed candidate") {
                guard canApply, let candidate else { return }
                apply(candidate.document)
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canApply)
        }
        .padding(18)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(StudioTheme.font(11, weight: .bold))
                .tracking(1.1).foregroundStyle(StudioTheme.accent)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StudioTheme.panel, in: RoundedRectangle(cornerRadius: 9))
    }

    private func metric(_ title: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(value)").font(StudioTheme.font(18, weight: .medium))
            Text(title).font(StudioTheme.font(10)).foregroundStyle(StudioTheme.secondaryText)
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.title = "Choose Huion EKeySetting.dt"
        panel.message = "Select the Huion settings file to inspect. KDCustom will not modify it."
        panel.allowedContentTypes = [.data]
        panel.allowsOtherFileTypes = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.nameFieldStringValue = "EKeySetting.dt"
        for directory in [
            "/Library/Application Support/HuionTablet",
            "/Library/Application Support/Huion",
            NSHomeDirectory() + "/Library/Application Support/HuionTablet",
            NSHomeDirectory() + "/Library/Application Support/Huion"
        ] where FileManager.default.fileExists(atPath: directory + "/EKeySetting.dt") {
            panel.directoryURL = URL(fileURLWithPath: directory, isDirectory: true)
            break
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        sourceURL = url
        candidate = nil
        inventory = nil
        errorMessage = nil
        mappingConfirmed = false
        warningsReviewed = false
        do { inventory = try HuionImporter().importDocument(from: url) }
        catch { errorMessage = error.localizedDescription }
    }

    private func invalidateMapping() {
        mappingConfirmed = false
        warningsReviewed = false
        candidate = nil
        errorMessage = nil
    }

    private func buildCandidate() {
        guard let sourceURL, mappingComplete, let leftIsCounterclockwise else { return }
        let mapping = HuionControlMapping(
            buttonConfigIndexByPhysicalButton: Dictionary(uniqueKeysWithValues:
                (1...8).compactMap { physical in buttonIndices[physical - 1].map { (physical, $0) } }),
            dialConfigIndexByPhysicalDial: Dictionary(uniqueKeysWithValues:
                (1...2).compactMap { physical in dialIndices[physical - 1].map { (physical, $0) } }),
            leftEntryIsCounterclockwise: leftIsCounterclockwise)
        do {
            candidate = try HuionImporter().importDocument(from: sourceURL, mapping: mapping)
            warningsReviewed = false
            errorMessage = nil
        } catch {
            candidate = nil
            mappingConfirmed = false
            errorMessage = error.localizedDescription
        }
    }
}
