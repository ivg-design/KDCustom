import AppKit
import SwiftUI

/// Invalid intermediate edits stay local so a blank text step can be completed
/// without writing an invalid configuration or showing a modal on each keystroke.
struct BindingDraftEditor: View {
    let binding: ControlBinding
    let wide: Bool
    let save: (ControlBinding) throws -> Void
    @State private var draft: ControlBinding
    @State private var validationMessage: String?

    init(binding: ControlBinding, wide: Bool = false, save: @escaping (ControlBinding) throws -> Void) {
        self.binding = binding
        self.wide = wide
        self.save = save
        _draft = State(initialValue: binding)
    }

    var body: some View {
        VStack(spacing: 0) {
            BindingEditor(binding: Binding(get: { draft }, set: { next in
                draft = next
                do { try save(next); validationMessage = nil }
                catch { validationMessage = error.localizedDescription }
            }), wide: wide)
            if let validationMessage {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Not saved yet").font(StudioTheme.font(12, weight: .medium))
                    Text(validationMessage).font(StudioTheme.font(11))
                    Button("Discard unfinished edit") { draft = binding; self.validationMessage = nil }
                        .buttonStyle(.borderless)
                }
                .foregroundStyle(StudioTheme.accent).padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(StudioTheme.panelRaised)
            }
        }
        .onChange(of: binding) { _, authoritative in
            if authoritative != draft { draft = authoritative; validationMessage = nil }
        }
    }
}

/// Inspector for one physical control. Editing changes the profile model only.
struct BindingEditor: View {
    @Binding var binding: ControlBinding
    var wide = false
    @State private var recording: StepLocation?
    @State private var recordingModifiers: KeyModifiers = []
    @State private var chordCaptureCount = 0

    private enum Lane: String { case press, release }
    private struct StepLocation: Equatable {
        let lane: Lane
        let index: Int
    }

    var body: some View {
        ScrollView {
            Group {
                if wide {
                    HStack(alignment: .top, spacing: 26) {
                        VStack(alignment: .leading, spacing: 18) {
                            header
                            identitySection
                            behaviorSection
                        }.frame(width: 270)
                        VStack(alignment: .leading, spacing: 18) {
                            actionSection(.press)
                            if !binding.controlID.isDial { actionSection(.release) }
                            advancedSection
                        }.frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 18) {
                        header
                        identitySection
                        behaviorSection
                        actionSection(.press)
                        if !binding.controlID.isDial { actionSection(.release) }
                        advancedSection
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 310, idealWidth: 350)
        .background(StudioTheme.panel)
        .foregroundStyle(StudioTheme.text)
        .background(ShortcutCaptureView(isRecording: recording != nil,
                                        onKey: capturedKey,
                                        onFlags: { recordingModifiers = $0 },
                                        onCancel: { recording = nil })
            .frame(width: 1, height: 1))
        .onChange(of: binding.controlID) { _, _ in recording = nil }
        .onDisappear { recording = nil }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("CONTROL INSPECTOR")
                .font(StudioTheme.font(10, weight: .bold))
                .tracking(1.6)
                .foregroundStyle(StudioTheme.accent)
            Text(binding.controlID.editorTitle)
                .font(StudioTheme.font(22, weight: .medium))
            Text("Changes are saved to this profile's selected group.")
                .font(StudioTheme.font(11))
                .foregroundStyle(StudioTheme.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var identitySection: some View {
        editorSection("Display") {
            VStack(alignment: .leading, spacing: 6) {
                Text("Control label").font(StudioTheme.font(11, weight: .medium))
                TextField("Optional OLED label", text: $binding.label)
                    .textFieldStyle(.roundedBorder)
                let bytes = binding.label.utf16.count * 2
                Text(bytes > 56 ? "This label is too long for the screen." : "Short labels are easier to read on the device.")
                    .font(StudioTheme.font(10))
                    .foregroundStyle(bytes > 56 ? Color.red : StudioTheme.mutedText)
            }
        }
    }

    private var behaviorSection: some View {
        editorSection("Input behavior") {
            if binding.controlID.isDial {
                Picker("Dial mode", selection: $binding.dialBehavior) {
                    Text("One action per detent").tag(DialBehavior.perStep)
                    Text("Hold modifiers between detents").tag(DialBehavior.heldModifiers)
                }
                .pickerStyle(.menu)
                if binding.dialBehavior == .heldModifiers {
                    modifierPicker("Held modifiers", modifiers: $binding.heldModifiers)
                    integerStepper("Release after idle", value: $binding.idleTimeoutMilliseconds,
                                   range: 20...5_000, unit: "ms", step: 10)
                    Text("Clockwise and counterclockwise share the dial's idle hold.")
                        .font(StudioTheme.font(10))
                        .foregroundStyle(StudioTheme.mutedText)
                }
            } else {
                Picker("Button mode", selection: $binding.buttonBehavior) {
                    Text("Press and release").tag(ButtonBehavior.pressRelease)
                    Text("Hold until release").tag(ButtonBehavior.hold)
                    Text("Toggle on each press").tag(ButtonBehavior.toggle)
                    Text("Repeat while held").tag(ButtonBehavior.repeatWhileHeld)
                }
                .pickerStyle(.menu)
                if binding.buttonBehavior == .repeatWhileHeld {
                    integerStepper("Repeat interval", value: $binding.repeatIntervalMilliseconds,
                                   range: 20...5_000, unit: "ms", step: 10)
                }
            }
        }
    }

    private func actionSection(_ lane: Lane) -> some View {
        let actions = lane == .press ? binding.pressActions : binding.releaseActions
        let title = lane == .press ? (binding.controlID.isDial ? "On dial step" : "On press") : "On release"
        return editorSection(title) {
            if lane == .release && binding.controlID.isDial {
                Text("Dial detents have no release edge. Stored release steps do not run.")
                    .font(StudioTheme.font(10))
                    .foregroundStyle(StudioTheme.mutedText)
            }
            if actions.isEmpty {
                Text("No actions assigned")
                    .font(StudioTheme.font(11))
                    .foregroundStyle(StudioTheme.mutedText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(StudioTheme.panelRaised, in: RoundedRectangle(cornerRadius: 7))
            }
            ForEach(actions.indices, id: \.self) { index in
                let location = StepLocation(lane: lane, index: index)
                ActionStepEditor(step: stepBinding(at: location),
                                 number: index + 1,
                                 isRecording: recording == location,
                                 recordingModifiers: recordingModifiers,
                                 onRecord: { toggleRecording(location) },
                                 onMoveUp: { moveStep(at: location, by: -1) },
                                 onMoveDown: { moveStep(at: location, by: 1) },
                                 onDelete: { deleteStep(at: location) },
                                 canMoveUp: index > 0,
                                 canMoveDown: index < actions.count - 1)
            }
            Button {
                recording = nil
                editActions(lane) { $0.append(.keyTap(0)) }
            } label: {
                Label("Add action", systemImage: "plus.circle.fill")
                    .font(StudioTheme.font(11, weight: .medium))
                    .foregroundStyle(StudioTheme.accent)
            }
            .buttonStyle(.plain)
            .disabled(actions.count >= 64)
            Text("\(actions.count) / 64 steps")
                .font(StudioTheme.font(10))
                .foregroundStyle(StudioTheme.mutedText)
        }
    }

    private var advancedSection: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                Picker("When triggered again", selection: $binding.macroRetriggerPolicy) {
                    Text("Queue").tag(MacroRetriggerPolicy.queue)
                    Text("Restart").tag(MacroRetriggerPolicy.restart)
                    Text("Ignore while running").tag(MacroRetriggerPolicy.ignoreWhileRunning)
                }
                .pickerStyle(.menu)
                integerStepper("Waiting runs", value: $binding.queueLimit,
                               range: 1...32, unit: "max")
                if binding.macroRetriggerPolicy != .queue {
                    Text("The waiting limit applies when Queue is selected.")
                        .font(StudioTheme.font(10))
                        .foregroundStyle(StudioTheme.mutedText)
                }
                integerStepper("Repeat entire macro", value: $binding.macroRepeatCount,
                               range: 1...100, unit: "times")
                let expanded = (binding.pressActions + binding.releaseActions)
                    .reduce(0) { $0 + $1.repeatCount } * binding.macroRepeatCount
                Text("Expanded work: \(expanded) / 10,000 steps")
                    .font(StudioTheme.font(10))
                    .foregroundStyle(expanded > 10_000 ? Color.red : StudioTheme.mutedText)
            }
            .padding(.top, 8)
        } label: {
            Text("Macro scheduling")
                .font(StudioTheme.font(12, weight: .medium))
                .foregroundStyle(StudioTheme.text)
        }
        .tint(StudioTheme.accent)
        .padding(11)
        .background(StudioTheme.panelRaised, in: RoundedRectangle(cornerRadius: 8))
    }

    private func editorSection<Content: View>(_ title: String,
                                              @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title.uppercased())
                    .font(StudioTheme.font(10, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(StudioTheme.secondaryText)
                Spacer()
            }
            Rectangle().fill(StudioTheme.divider).frame(height: 1)
            content()
        }
    }

    private func integerStepper(_ title: String, value: Binding<Int>, range: ClosedRange<Int>,
                                unit: String, step: Int = 1) -> some View {
        Stepper(value: value, in: range, step: step) {
            HStack {
                Text(title).foregroundStyle(StudioTheme.secondaryText)
                Spacer()
                Text("\(value.wrappedValue) \(unit)").monospacedDigit()
                    .foregroundStyle(StudioTheme.text)
            }
            .font(StudioTheme.font(11))
        }
    }

    private func modifierPicker(_ title: String, modifiers: Binding<KeyModifiers>) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(StudioTheme.font(11, weight: .medium))
            HStack(spacing: 5) {
                ForEach(ModifierChoice.allCases) { choice in
                    let selected = modifiers.wrappedValue.contains(choice.flag)
                    Button {
                        var next = modifiers.wrappedValue
                        if selected { next.remove(choice.flag) }
                        else { next.insert(choice.flag) }
                        modifiers.wrappedValue = next
                    } label: {
                        Text(choice.symbol)
                            .font(.system(size: 15, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                            .background(selected ? StudioTheme.accentSoft : StudioTheme.panel,
                                        in: RoundedRectangle(cornerRadius: 5))
                            .overlay(RoundedRectangle(cornerRadius: 5)
                                .strokeBorder(selected ? StudioTheme.accent : StudioTheme.divider))
                    }
                    .buttonStyle(.plain)
                    .help(choice.name)
                    .accessibilityLabel(choice.name)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
    }

    private func stepBinding(at location: StepLocation) -> Binding<ActionStep> {
        Binding(get: {
            let actions = location.lane == .press ? binding.pressActions : binding.releaseActions
            return actions.indices.contains(location.index) ? actions[location.index] : .keyTap(0)
        }, set: { step in
            editActions(location.lane) { actions in
                guard actions.indices.contains(location.index) else { return }
                actions[location.index] = step
            }
        })
    }

    private func editActions(_ lane: Lane, _ edit: (inout [ActionStep]) -> Void) {
        var updated = binding
        if lane == .press { edit(&updated.pressActions) }
        else { edit(&updated.releaseActions) }
        binding = updated
    }

    private func moveStep(at location: StepLocation, by delta: Int) {
        recording = nil
        editActions(location.lane) { actions in
            let destination = location.index + delta
            guard actions.indices.contains(location.index), actions.indices.contains(destination) else { return }
            actions.swapAt(location.index, destination)
        }
    }

    private func deleteStep(at location: StepLocation) {
        recording = nil
        editActions(location.lane) { actions in
            guard actions.indices.contains(location.index) else { return }
            actions.remove(at: location.index)
        }
    }

    private func toggleRecording(_ location: StepLocation) {
        recording = recording == location ? nil : location
        recordingModifiers = []
        chordCaptureCount = 0
    }

    private func capturedKey(_ code: UInt16, _ modifiers: KeyModifiers) {
        guard let location = recording else { return }
        var shouldStop = true
        var capturedChord = false
        editActions(location.lane) { actions in
            guard actions.indices.contains(location.index) else { return }
            switch actions[location.index].operation {
            case .keyDown: actions[location.index].operation = .keyDown(keyCode: code, modifiers: modifiers)
            case .keyUp: actions[location.index].operation = .keyUp(keyCode: code, modifiers: modifiers)
            case .keyTap: actions[location.index].operation = .keyTap(keyCode: code, modifiers: modifiers)
            case let .chord(existing, _):
                var codes = chordCaptureCount == 0 ? [] : existing
                if !codes.contains(code), codes.count < 8 { codes.append(code) }
                actions[location.index].operation = .chord(keyCodes: codes, modifiers: modifiers)
                shouldStop = false
                capturedChord = true
            default: break
            }
        }
        if capturedChord { chordCaptureCount += 1 }
        if shouldStop { recording = nil }
    }
}

private enum ModifierChoice: String, CaseIterable, Identifiable {
    case command, option, control, shift, function
    var id: Self { self }
    var name: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .command: "⌘"
        case .option: "⌥"
        case .control: "⌃"
        case .shift: "⇧"
        case .function: "fn"
        }
    }
    var flag: KeyModifiers {
        switch self {
        case .command: .command
        case .option: .option
        case .control: .control
        case .shift: .shift
        case .function: .function
        }
    }
}

private extension ControlID {
    var editorTitle: String {
        switch self {
        case .key1: "Key 1"
        case .key2: "Key 2"
        case .key3: "Key 3"
        case .key4: "Key 4"
        case .key5: "Key 5"
        case .key6: "Key 6"
        case .key7: "Key 7"
        case .key8: "Key 8"
        case .setPrevious: "Previous group button"
        case .setNext: "Next group button"
        case .dial1CW: "Inner dial · clockwise"
        case .dial1CCW: "Inner dial · counterclockwise"
        case .dial2CW: "Outer dial · clockwise"
        case .dial2CCW: "Outer dial · counterclockwise"
        }
    }
}

private enum EditorOperationKind: String, CaseIterable, Identifiable {
    case keyTap, keyDown, keyUp, chord, text, delay
    case mouseClick, mouseButtonDown, mouseButtonUp, scroll, media, groupChange

    var id: Self { self }
    var title: String {
        switch self {
        case .keyTap: "Key tap"
        case .keyDown: "Key down"
        case .keyUp: "Key up"
        case .chord: "Key chord"
        case .text: "Type text"
        case .delay: "Wait"
        case .mouseClick: "Mouse click"
        case .mouseButtonDown: "Mouse button down"
        case .mouseButtonUp: "Mouse button up"
        case .scroll: "Scroll"
        case .media: "Media key"
        case .groupChange: "Change group"
        }
    }
    var defaultOperation: ActionStep.Operation {
        switch self {
        case .keyTap: .keyTap(keyCode: 0, modifiers: [])
        case .keyDown: .keyDown(keyCode: 0, modifiers: [])
        case .keyUp: .keyUp(keyCode: 0, modifiers: [])
        case .chord: .chord(keyCodes: [0], modifiers: [])
        case .text: .text("")
        case .delay: .delay(milliseconds: 100)
        case .mouseClick: .mouseClick(.left)
        case .mouseButtonDown: .mouseButtonDown(.left)
        case .mouseButtonUp: .mouseButtonUp(.left)
        case .scroll: .scroll(horizontal: 0, vertical: 1)
        case .media: .media(.playPause)
        case .groupChange: .groupChange(offset: 1)
        }
    }
    init(_ operation: ActionStep.Operation) {
        switch operation {
        case .keyTap: self = .keyTap
        case .keyDown: self = .keyDown
        case .keyUp: self = .keyUp
        case .chord: self = .chord
        case .text: self = .text
        case .delay: self = .delay
        case .mouseClick: self = .mouseClick
        case .mouseButtonDown: self = .mouseButtonDown
        case .mouseButtonUp: self = .mouseButtonUp
        case .scroll: self = .scroll
        case .media: self = .media
        case .groupChange: self = .groupChange
        }
    }
}

private struct ActionStepEditor: View {
    @Binding var step: ActionStep
    let number: Int
    let isRecording: Bool
    let recordingModifiers: KeyModifiers
    let onRecord: () -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onDelete: () -> Void
    let canMoveUp: Bool
    let canMoveDown: Bool

    private let mouseButtons: [MouseButton] = [.left, .right, .middle]
    private let mediaKeys: [MediaKey] = [.playPause, .nextTrack, .previousTrack,
                                         .volumeUp, .volumeDown, .mute]

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Text(String(format: "%02d", number))
                    .font(StudioTheme.font(10, weight: .bold))
                    .foregroundStyle(StudioTheme.accent)
                    .frame(width: 20, alignment: .leading)
                Picker("Action", selection: kindBinding) {
                    ForEach(EditorOperationKind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                Spacer(minLength: 0)
                iconButton("arrow.up", help: "Move action up", enabled: canMoveUp, action: onMoveUp)
                iconButton("arrow.down", help: "Move action down", enabled: canMoveDown, action: onMoveDown)
                iconButton("trash", help: "Delete action", enabled: true, action: onDelete)
            }
            operationEditor
            Stepper(value: $step.repeatCount, in: 1...100) {
                HStack {
                    Text("Repeat step").foregroundStyle(StudioTheme.secondaryText)
                    Spacer()
                    Text("\(step.repeatCount)×").monospacedDigit()
                }
                .font(StudioTheme.font(11))
            }
        }
        .padding(10)
        .background(StudioTheme.panelRaised, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(StudioTheme.divider.opacity(0.8)))
    }

    @ViewBuilder
    private var operationEditor: some View {
        switch step.operation {
        case .keyDown, .keyUp, .keyTap:
            keyCaptureRow
            Stepper(value: keyCodeBinding, in: 0...255) {
                valueLine("Virtual key code", value: "\(keyCodeBinding.wrappedValue)")
            }
            modifierButtons(modifiers: keyModifiersBinding)
        case let .chord(codes, _):
            keyCaptureRow
            Text("Press each key while recording, then select Done.")
                .font(StudioTheme.font(10))
                .foregroundStyle(StudioTheme.mutedText)
            ForEach(codes.indices, id: \.self) { index in
                HStack(spacing: 6) {
                    Stepper(value: chordCodeBinding(index), in: 0...255) {
                        valueLine("Key \(index + 1)", value: KeyCodeName.title(codes[index]))
                    }
                    Button { removeChordCode(at: index) } label: {
                        Image(systemName: "minus.circle")
                    }
                    .disabled(codes.count == 1)
                    .help("Remove key")
                    .buttonStyle(.plain)
                }
            }
            if codes.count < 8 {
                Button("Add key") { addChordCode() }
                    .buttonStyle(.plain)
                    .foregroundStyle(StudioTheme.accent)
                    .font(StudioTheme.font(11))
            }
            modifierButtons(modifiers: keyModifiersBinding)
        case let .text(value):
            TextEditor(text: textBinding)
                .font(StudioTheme.font(11))
                .frame(height: 58)
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(StudioTheme.panel, in: RoundedRectangle(cornerRadius: 5))
            Text("\(value.utf8.count) / 1,024 UTF-8 bytes")
                .font(StudioTheme.font(10))
                .foregroundStyle(value.isEmpty || value.utf8.count > 1_024 ? Color.red : StudioTheme.mutedText)
        case .delay:
            Stepper(value: delayBinding, in: 0...60_000, step: 10) {
                valueLine("Wait", value: "\(delayBinding.wrappedValue) ms")
            }
        case .mouseClick, .mouseButtonDown, .mouseButtonUp:
            Picker("Mouse button", selection: mouseBinding) {
                ForEach(mouseButtons, id: \.self) { button in
                    Text(button.rawValue.capitalized).tag(button)
                }
            }
            .pickerStyle(.menu)
        case let .scroll(horizontal, vertical):
            Stepper(value: scrollHorizontalBinding, in: -1_200...1_200) {
                valueLine("Horizontal", value: "\(horizontal)")
            }
            Stepper(value: scrollVerticalBinding, in: -1_200...1_200) {
                valueLine("Vertical", value: "\(vertical)")
            }
            if horizontal == 0 && vertical == 0 {
                Text("Set at least one scroll direction.")
                    .font(StudioTheme.font(10))
                    .foregroundStyle(Color.red)
            }
        case .media:
            Picker("Media control", selection: mediaBinding) {
                ForEach(mediaKeys, id: \.self) { key in
                    Text(key.editorTitle).tag(key)
                }
            }
            .pickerStyle(.menu)
        case .groupChange:
            Picker("Move groups", selection: groupOffsetBinding) {
                ForEach([-5, -4, -3, -2, -1, 1, 2, 3, 4, 5], id: \.self) { offset in
                    Text(offset < 0 ? "Previous \(-offset)" : "Next \(offset)").tag(offset)
                }
            }
            .pickerStyle(.menu)
        }
    }

    private var keyCaptureRow: some View {
        HStack(spacing: 7) {
            Text(keySummary)
                .font(StudioTheme.font(11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(isRecording ? StudioTheme.accent : StudioTheme.text)
            Spacer(minLength: 0)
            Button(isRecording ? "Done" : "Record") { onRecord() }
                .buttonStyle(.bordered)
                .tint(StudioTheme.accent)
                .help(isRecording ? "Finish recording" : "Capture keys in this window")
        }
        .padding(7)
        .background(StudioTheme.panel, in: RoundedRectangle(cornerRadius: 5))
    }

    private var keySummary: String {
        if isRecording {
            let flags = KeyCodeName.modifiers(recordingModifiers)
            return flags.isEmpty ? "Press a shortcut…" : "\(flags)  Press a key…"
        }
        switch step.operation {
        case let .keyDown(code, modifiers), let .keyUp(code, modifiers), let .keyTap(code, modifiers):
            return KeyCodeName.modifiers(modifiers) + KeyCodeName.title(code)
        case let .chord(codes, modifiers):
            return KeyCodeName.modifiers(modifiers) + codes.map(KeyCodeName.title).joined(separator: " + ")
        default: return ""
        }
    }

    private func valueLine(_ title: String, value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(StudioTheme.secondaryText)
            Spacer()
            Text(value).foregroundStyle(StudioTheme.text).monospacedDigit()
        }
        .font(StudioTheme.font(11))
    }

    private func iconButton(_ systemName: String, help: String, enabled: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: systemName).frame(width: 17, height: 17) }
            .buttonStyle(.plain)
            .foregroundStyle(StudioTheme.secondaryText)
            .disabled(!enabled)
            .help(help)
            .accessibilityLabel(help)
    }

    private func modifierButtons(modifiers: Binding<KeyModifiers>) -> some View {
        HStack(spacing: 5) {
            ForEach(ModifierChoice.allCases) { choice in
                let selected = modifiers.wrappedValue.contains(choice.flag)
                Button {
                    var next = modifiers.wrappedValue
                    if selected { next.remove(choice.flag) }
                    else { next.insert(choice.flag) }
                    modifiers.wrappedValue = next
                } label: {
                    Text(choice.symbol)
                        .font(.system(size: 14, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                        .background(selected ? StudioTheme.accentSoft : StudioTheme.panel,
                                    in: RoundedRectangle(cornerRadius: 4))
                        .overlay(RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(selected ? StudioTheme.accent : StudioTheme.divider))
                }
                .buttonStyle(.plain)
                .help(choice.name)
                .accessibilityLabel(choice.name)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }

    private var kindBinding: Binding<EditorOperationKind> {
        Binding(get: { EditorOperationKind(step.operation) },
                set: { step.operation = $0.defaultOperation })
    }

    private var keyCodeBinding: Binding<Int> {
        Binding(get: {
            switch step.operation {
            case let .keyDown(code, _), let .keyUp(code, _), let .keyTap(code, _): Int(code)
            default: 0
            }
        }, set: { rewriteKey(code: UInt16(clamping: $0)) })
    }

    private var keyModifiersBinding: Binding<KeyModifiers> {
        Binding(get: {
            switch step.operation {
            case let .keyDown(_, modifiers), let .keyUp(_, modifiers),
                 let .keyTap(_, modifiers), let .chord(_, modifiers): modifiers
            default: []
            }
        }, set: { rewriteKey(modifiers: $0) })
    }

    private func rewriteKey(code: UInt16? = nil, modifiers: KeyModifiers? = nil) {
        switch step.operation {
        case let .keyDown(oldCode, oldModifiers):
            step.operation = .keyDown(keyCode: code ?? oldCode, modifiers: modifiers ?? oldModifiers)
        case let .keyUp(oldCode, oldModifiers):
            step.operation = .keyUp(keyCode: code ?? oldCode, modifiers: modifiers ?? oldModifiers)
        case let .keyTap(oldCode, oldModifiers):
            step.operation = .keyTap(keyCode: code ?? oldCode, modifiers: modifiers ?? oldModifiers)
        case let .chord(codes, oldModifiers):
            step.operation = .chord(keyCodes: codes, modifiers: modifiers ?? oldModifiers)
        default: break
        }
    }

    private func chordCodeBinding(_ index: Int) -> Binding<Int> {
        Binding(get: {
            guard case let .chord(codes, _) = step.operation, codes.indices.contains(index) else { return 0 }
            return Int(codes[index])
        }, set: { value in
            guard case let .chord(codes, modifiers) = step.operation,
                  codes.indices.contains(index) else { return }
            var next = codes
            next[index] = UInt16(clamping: value)
            step.operation = .chord(keyCodes: next, modifiers: modifiers)
        })
    }

    private func addChordCode() {
        guard case let .chord(codes, modifiers) = step.operation, codes.count < 8 else { return }
        let next = (0...255).first { !codes.contains(UInt16($0)) } ?? 0
        step.operation = .chord(keyCodes: codes + [UInt16(next)], modifiers: modifiers)
    }

    private func removeChordCode(at index: Int) {
        guard case let .chord(codes, modifiers) = step.operation,
              codes.count > 1, codes.indices.contains(index) else { return }
        var next = codes
        next.remove(at: index)
        step.operation = .chord(keyCodes: next, modifiers: modifiers)
    }

    private var textBinding: Binding<String> {
        Binding(get: { if case let .text(value) = step.operation { value } else { "" } },
                set: { step.operation = .text($0) })
    }
    private var delayBinding: Binding<Int> {
        Binding(get: { if case let .delay(value) = step.operation { value } else { 0 } },
                set: { step.operation = .delay(milliseconds: $0) })
    }
    private var mouseBinding: Binding<MouseButton> {
        Binding(get: {
            switch step.operation {
            case let .mouseClick(button), let .mouseButtonDown(button), let .mouseButtonUp(button): button
            default: .left
            }
        }, set: { button in
            switch step.operation {
            case .mouseClick: step.operation = .mouseClick(button)
            case .mouseButtonDown: step.operation = .mouseButtonDown(button)
            case .mouseButtonUp: step.operation = .mouseButtonUp(button)
            default: break
            }
        })
    }
    private var scrollHorizontalBinding: Binding<Int> {
        Binding(get: { if case let .scroll(value, _) = step.operation { value } else { 0 } },
                set: { value in
                    if case let .scroll(_, vertical) = step.operation {
                        step.operation = .scroll(horizontal: value, vertical: vertical)
                    }
                })
    }
    private var scrollVerticalBinding: Binding<Int> {
        Binding(get: { if case let .scroll(_, value) = step.operation { value } else { 0 } },
                set: { value in
                    if case let .scroll(horizontal, _) = step.operation {
                        step.operation = .scroll(horizontal: horizontal, vertical: value)
                    }
                })
    }
    private var mediaBinding: Binding<MediaKey> {
        Binding(get: { if case let .media(key) = step.operation { key } else { .playPause } },
                set: { step.operation = .media($0) })
    }
    private var groupOffsetBinding: Binding<Int> {
        Binding(get: { if case let .groupChange(offset) = step.operation { offset } else { 1 } },
                set: { step.operation = .groupChange(offset: $0) })
    }
}

private extension MediaKey {
    var editorTitle: String {
        switch self {
        case .playPause: "Play / pause"
        case .nextTrack: "Next track"
        case .previousTrack: "Previous track"
        case .volumeUp: "Volume up"
        case .volumeDown: "Volume down"
        case .mute: "Mute"
        }
    }
}

private enum KeyCodeName {
    static func modifiers(_ flags: KeyModifiers) -> String {
        ModifierChoice.allCases.filter { flags.contains($0.flag) }.map(\.symbol).joined()
    }

    static func title(_ code: UInt16) -> String {
        let names: [UInt16: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
            8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
            23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
            30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "Return",
            37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",",
            44: "/", 45: "N", 46: "M", 47: ".", 48: "Tab", 49: "Space",
            50: "`", 51: "Delete", 53: "Escape", 55: "Command", 56: "Shift",
            58: "Option", 59: "Control", 63: "Fn", 123: "←", 124: "→",
            125: "↓", 126: "↑"
        ]
        return names[code] ?? "Key \(code)"
    }
}

/// A first-responder capture surface. No event monitor or action injector is installed.
private struct ShortcutCaptureView: NSViewRepresentable {
    let isRecording: Bool
    let onKey: (UInt16, KeyModifiers) -> Void
    let onFlags: (KeyModifiers) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> ShortcutCaptureNSView {
        ShortcutCaptureNSView()
    }

    func updateNSView(_ view: ShortcutCaptureNSView, context: Context) {
        view.onKey = onKey
        view.onFlags = onFlags
        view.onCancel = onCancel
        view.isRecording = isRecording
        if isRecording { view.focusForRecording() }
        else if view.window?.firstResponder === view { view.window?.makeFirstResponder(nil) }
    }

    static func dismantleNSView(_ view: ShortcutCaptureNSView, coordinator: ()) {
        view.stopCapturing()
    }
}

private final class ShortcutCaptureNSView: NSView {
    var isRecording = false
    var onKey: ((UInt16, KeyModifiers) -> Void)?
    var onFlags: ((KeyModifiers) -> Void)?
    var onCancel: (() -> Void)?
    private weak var observedWindow: NSWindow?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let observedWindow {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification,
                                                      object: observedWindow)
        }
        observedWindow = window
        if let window {
            NotificationCenter.default.addObserver(self, selector: #selector(windowResigned),
                                                   name: NSWindow.didResignKeyNotification,
                                                   object: window)
            if isRecording { focusForRecording() }
        }
    }

    func focusForRecording() {
        guard isRecording, let window, window.isKeyWindow,
              window.firstResponder !== self else { return }
        window.makeFirstResponder(self)
    }

    func stopCapturing() {
        isRecording = false
        if let observedWindow {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification,
                                                      object: observedWindow)
        }
        observedWindow = nil
        onKey = nil
        onFlags = nil
        onCancel = nil
    }

    @objc private func windowResigned(_ notification: Notification) {
        guard isRecording else { return }
        isRecording = false
        onCancel?()
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { super.keyDown(with: event); return }
        guard !event.isARepeat else { return }
        if event.keyCode == 53 { // Escape cancels capture.
            isRecording = false
            onCancel?()
        } else {
            onKey?(event.keyCode, Self.recordedModifiers(from: event.modifierFlags))
        }
    }

    override func resignFirstResponder() -> Bool {
        let didResign = super.resignFirstResponder()
        if didResign && isRecording {
            isRecording = false
            onCancel?()
        }
        return didResign
    }

    override func flagsChanged(with event: NSEvent) {
        guard isRecording else { super.flagsChanged(with: event); return }
        onFlags?(Self.recordedModifiers(from: event.modifierFlags))
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording, event.type == .keyDown else {
            return super.performKeyEquivalent(with: event)
        }
        keyDown(with: event)
        return true
    }

    private static func recordedModifiers(from flags: NSEvent.ModifierFlags) -> KeyModifiers {
        ShortcutRecordedModifiers.from(flags,
            physicalFunctionDown: CGEventSource.keyState(.hidSystemState, key: 63))
    }
}

/// NSEvent sets `.function` for some navigation keys even without a held Fn key.
/// Only hardware Fn state is evidence that the user requested that modifier.
enum ShortcutRecordedModifiers {
    static func from(_ flags: NSEvent.ModifierFlags, physicalFunctionDown: Bool) -> KeyModifiers {
        var result: KeyModifiers = []
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.shift) { result.insert(.shift) }
        if physicalFunctionDown { result.insert(.function) }
        return result
    }
}
