import AppKit
import ApplicationServices
import Carbon
import Foundation

/// Exercises production HID delivery with this disposable window in front.
/// It never changes profiles and stops as soon as the window loses focus.
@MainActor
final class OutputVerifier: NSObject, NSWindowDelegate {
    static let shared = OutputVerifier()
    var onRecoveredKeyState: (() -> Void)?
    private let testedCodes: [UInt16] = [0, 4, 5, 30, 33, 46, 49, 54, 55, 56, 58, 59, 60, 61, 62, 63, 125, 126]

    private struct EventSignature: Codable, Equatable {
        let kind: String
        let code: UInt16
        let command: Bool
        let shift: Bool
        let option: Bool
        let modifierSides: UInt64
    }

    private struct ObservedEvent: Codable {
        let kind: String
        let code: UInt16
        let command: Bool
        let shift: Bool
        let option: Bool
        let modifierSides: UInt64
        let seconds: Double

        var signature: EventSignature { .init(kind: kind, code: code, command: command, shift: shift, option: option, modifierSides: modifierSides) }
    }

    private struct CheckResult: Codable {
        let name: String
        let passed: Bool
        let expected: [EventSignature]
        let observed: [ObservedEvent]
        let detail: String
    }

    private struct Report: Codable {
        let generatedAt: String
        let passed: Bool
        let scope: String
        let checks: [CheckResult]
    }

    private enum Case: Int, CaseIterable {
        case commandUp, heldDial, delayedMacro, cancelledHold, smartArrows, smartCommand, smartBrush

        var name: String {
            switch self {
            case .commandUp: "Balanced Command + Up"
            case .heldDial: "Inner dial held Command + Down"
            case .delayedMacro: "Macro completes after button release"
            case .cancelledHold: "Cancellation releases Space before A"
            case .smartArrows: "Smart arrows repeat with balanced releases"
            case .smartCommand: "Smart Command + Up repeats"
            case .smartBrush: "Smart bracket shortcuts and modifiers"
            }
        }

        var duration: TimeInterval {
            switch self {
            case .commandUp: 0.30
            case .heldDial: 0.62
            case .delayedMacro: 0.75
            case .cancelledHold: 0.70
            case .smartArrows, .smartCommand, .smartBrush: 0.30
            }
        }

        var expected: [EventSignature] {
            func e(_ kind: String, _ code: UInt16, _ command: Bool = false, shift: Bool = false, option: Bool = false) -> EventSignature {
                .init(kind: kind, code: code, command: command, shift: shift, option: option,
                      modifierSides: (command ? 0x08 : 0) | (shift ? 0x02 : 0) | (option ? 0x20 : 0))
            }
            switch self {
            case .commandUp:
                return [e("down", 55, true), e("down", 126, true), e("up", 126, true), e("up", 55)]
            case .heldDial:
                return [e("down", 55, true), e("down", 125, true), e("up", 125, true),
                        e("down", 125, true), e("up", 125, true), e("up", 55)]
            case .delayedMacro:
                return [e("down", 4), e("up", 4), e("down", 5), e("up", 5)]
            case .cancelledHold:
                return [e("down", 49), e("up", 49)]
            case .smartArrows:
                return [126, 126, 125, 125].flatMap { [e("down", $0), e("up", $0)] }
            case .smartCommand:
                return [126, 126].flatMap { [e("down", $0, true), e("up", $0, true)] }
            case .smartBrush:
                return [e("down", 30), e("up", 30), e("down", 30), e("up", 30),
                        e("down", 33, option: true), e("up", 33, option: true),
                        e("down", 30, shift: true), e("up", 30, shift: true)]
            }
        }
    }

    private var window: NSWindow?
    private var receiver: MarkedEventReceiver?
    private var statusLabel: NSTextField?
    private var logView: NSTextView?
    private var runButton: NSButton?
    private var eventMonitor: Any?
    private var output: SystemActionOutput?
    private var engine: ActionEngine?
    private var timer: Timer?
    private var currentCase: Case?
    private var caseStart: TimeInterval = 0
    private var didSecondDialPulse = false
    private var didReleaseButton = false
    private var didCancelHold = false
    private var observed: [ObservedEvent] = []
    private var results: [CheckResult] = []
    private var running = false

    private override init() { super.init() }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            window.makeFirstResponder(receiver)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 480),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered,
                              defer: false)
        window.title = "KDCustom · Output check"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 580, height: 390)
        window.delegate = self
        let root = NSView(frame: window.contentView?.bounds ?? .zero)
        root.autoresizingMask = [.width, .height]
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(calibratedWhite: 0.09, alpha: 1).cgColor
        window.contentView = root

        let title = NSTextField(labelWithString: "Keyboard output check")
        title.font = .systemFont(ofSize: 20, weight: .medium)
        title.textColor = .white
        let explanation = NSTextField(wrappingLabelWithString:
            "Runs seven checks through normal HID delivery into this disposable window. Stops if focus changes. This does not prove Rive behavior. Release all physical keys before running.")
        explanation.textColor = NSColor(calibratedWhite: 0.72, alpha: 1)
        explanation.font = .systemFont(ofSize: 12)
        let button = NSButton(title: "Run check", target: self, action: #selector(runCheck))
        button.bezelStyle = .rounded
        let reset = NSButton(title: "Reset stuck test keys", target: self, action: #selector(resetTestKeys))
        reset.bezelStyle = .rounded
        reset.toolTip = "Release all physical keyboard keys first. Clears only keys used by this diagnostic."
        let status = NSTextField(labelWithString: "Ready · Accessibility permission required")
        status.font = .systemFont(ofSize: 12, weight: .medium)
        status.textColor = NSColor(calibratedRed: 0.82, green: 0.59, blue: 0.29, alpha: 1)
        let receiver = MarkedEventReceiver(frame: .zero)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let log = NSTextView(frame: NSRect(x: 0, y: 0, width: 630, height: 280))
        log.isEditable = false
        log.isSelectable = false
        log.isVerticallyResizable = true
        log.isHorizontallyResizable = false
        log.autoresizingMask = [.width]
        log.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        log.textColor = .white
        log.backgroundColor = NSColor(calibratedWhite: 0.13, alpha: 1)
        log.string = "Only events bearing KDCustom's output marker appear here.\n"
        scroll.documentView = log

        for view in [title, explanation, button, reset, status, receiver, scroll] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 22),
            explanation.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 9),
            explanation.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            explanation.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -22),
            button.topAnchor.constraint(equalTo: explanation.bottomAnchor, constant: 15),
            button.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            reset.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            reset.leadingAnchor.constraint(equalTo: button.trailingAnchor, constant: 14),
            status.topAnchor.constraint(equalTo: button.bottomAnchor, constant: 8),
            status.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            status.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -22),
            receiver.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 8),
            receiver.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            receiver.widthAnchor.constraint(equalToConstant: 1),
            receiver.heightAnchor.constraint(equalToConstant: 1),
            scroll.topAnchor.constraint(equalTo: receiver.bottomAnchor, constant: 5),
            scroll.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -22),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20)
        ])
        self.window = window
        self.receiver = receiver
        statusLabel = status
        logView = log
        runButton = button
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeFirstResponder(receiver)
    }

    @objc private func resetTestKeys() {
        guard !running, window?.isKeyWindow == true,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid(),
              AXIsProcessTrusted(), !IsSecureEventInputEnabled() else { return }
        let stuck = testedCodes.filter { CGEventSource.keyState(.hidSystemState, key: $0) }
        let recovery = SystemActionOutput()
        recovery.enabled = true
        for code in stuck { recovery.key(code: code, down: false, modifiers: []) }
        recovery.enabled = false
        append(stuck.isEmpty ? "No stuck test keys." : "Cleared \(stuck.count) stuck test keys.")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.onRecoveredKeyState?()
            let remaining = self?.testedCodes.filter { CGEventSource.keyState(.hidSystemState, key: $0) } ?? []
            self?.statusLabel?.stringValue = remaining.isEmpty ? "No stuck test keys · ready to run" : "Some test keys are still held"
        }
    }

    @objc private func runCheck() {
        guard !running, let window, window.isKeyWindow else { return }
        guard AXIsProcessTrusted(), !IsSecureEventInputEnabled() else {
            let detail = "Accessibility permission is required and Secure Input must be off."
            statusLabel?.stringValue = detail
            append(detail)
            writeReport(checks: [.init(name: "Preflight", passed: false, expected: [],
                                       observed: [], detail: detail)])
            return
        }
        guard !testedCodes.contains(where: { CGEventSource.keyState(.hidSystemState, key: $0) }) else {
            let detail = "Release physical keyboard keys used by the check, then retry."
            statusLabel?.stringValue = detail
            append(detail)
            writeReport(checks: [.init(name: "Preflight", passed: false, expected: [],
                                       observed: [], detail: detail)])
            return
        }

        results.removeAll()
        observed.removeAll()
        running = true
        runButton?.isEnabled = false
        logView?.string = "Production HID delivery, disposable window target: \(getpid()). Starting checks.\n"
        let output = SystemActionOutput()
        output.expectedForegroundPID = getpid()
        output.startObserving()
        guard output.observing else {
            output.stopObserving()
            running = false
            runButton?.isEnabled = true
            statusLabel?.stringValue = "Input Monitoring is required for the output check."
            return
        }
        output.enabled = true
        self.output = output
        engine = ActionEngine(output: output)
        // AppKit does not route Command-key keyUp events to an ordinary
        // responder. Observe at the application boundary before that filtering.
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                guard let self, self.running, self.window?.isKeyWindow == true,
                      event.cgEvent?.getIntegerValueField(.eventSourceUserData) == SystemActionOutput.eventMarker else { return false }
                self.receive(event)
                return true
            }
            return consumed ? nil : event
        }
        window.makeFirstResponder(receiver)
        start(.commandUp)
        let timer = Timer(timeInterval: 0.005, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.advance() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func start(_ test: Case) {
        guard running, let engine else { return }
        currentCase = test
        observed.removeAll()
        didSecondDialPulse = false
        didReleaseButton = false
        didCancelHold = false
        caseStart = ProcessInfo.processInfo.systemUptime
        statusLabel?.stringValue = "Running · \(test.name)"
        append("\n\(test.name)")
        switch test {
        case .commandUp:
            let binding = ControlBinding(controlID: .key1,
                                         pressActions: [.keyTap(126, modifiers: .command)])
            engine.handle(control: .key1, isDown: true, binding: binding, now: caseStart)
            engine.handle(control: .key1, isDown: false, binding: binding, now: caseStart)
        case .heldDial:
            let binding = ControlBinding(controlID: .dial1CW,
                                         pressActions: [.keyTap(125)],
                                         dialBehavior: .heldModifiers,
                                         heldModifiers: .command,
                                         idleTimeoutMilliseconds: 250)
            engine.handle(control: .dial1CW, isDown: true, binding: binding, now: caseStart)
        case .delayedMacro:
            let binding = ControlBinding(controlID: .key2,
                                         pressActions: [.keyTap(4), .init(.delay(milliseconds: 500)),
                                                        .keyTap(5)])
            engine.handle(control: .key2, isDown: true, binding: binding, now: caseStart)
        case .cancelledHold:
            let binding = ControlBinding(controlID: .key3,
                                         pressActions: [.init(.keyDown(keyCode: 49, modifiers: [])),
                                                        .init(.delay(milliseconds: 500)), .keyTap(0)],
                                         buttonBehavior: .hold)
            engine.handle(control: .key3, isDown: true, binding: binding, now: caseStart)
        case .smartArrows:
            output?.smartShortcut(.init(keyCode: 126, repeatCount: 2))
            output?.smartShortcut(.init(keyCode: 125, repeatCount: 2))
        case .smartCommand:
            output?.smartShortcut(.init(keyCode: 126, modifiers: .command, repeatCount: 2))
        case .smartBrush:
            output?.smartShortcut(.init(keyCode: 30, repeatCount: 2))
            output?.smartShortcut(.init(keyCode: 33, modifiers: .option))
            output?.smartShortcut(.init(keyCode: 30, modifiers: .shift))
        }
    }

    private func advance() {
        guard running, let test = currentCase, let engine else { return }
        guard window?.isKeyWindow == true, AXIsProcessTrusted(), !IsSecureEventInputEnabled() else {
            stop(detail: "Window focus, Accessibility permission, or Secure Input changed; check stopped.")
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = now - caseStart
        switch test {
        case .commandUp: break
        case .heldDial where elapsed >= 0.08 && !didSecondDialPulse:
            didSecondDialPulse = true
            let binding = ControlBinding(controlID: .dial1CW,
                                         pressActions: [.keyTap(125)], dialBehavior: .heldModifiers,
                                         heldModifiers: .command, idleTimeoutMilliseconds: 250)
            engine.handle(control: .dial1CW, isDown: true, binding: binding, now: now)
        case .delayedMacro where elapsed >= 0.02 && !didReleaseButton:
            didReleaseButton = true
            let binding = ControlBinding(controlID: .key2)
            engine.handle(control: .key2, isDown: false, binding: binding, now: now)
        case .cancelledHold where elapsed >= 0.10 && !didCancelHold:
            didCancelHold = true
            engine.cancelAll(reason: "Output verifier cancellation check")
        default: break
        }
        engine.tick(now: now)
        guard elapsed >= test.duration else { return }
        let expected = test.expected
        let actual = observed.map(\.signature)
        var passed = actual == expected
        var detail = passed ? "Observed the exact marked-event sequence." :
            "Marked-event sequence differed from the expected key/down/up and Command flags."
        let testedCodes = Set(expected.map(\.code))
        if testedCodes.contains(where: { CGEventSource.keyState(.hidSystemState, key: $0) }) {
            passed = false
            detail = "A tested key remained down in the shared HID state."
        }
        if test == .delayedMacro, let first = observed.first(where: { $0.code == 4 && $0.kind == "down" }),
           let second = observed.first(where: { $0.code == 5 && $0.kind == "down" }) {
            if second.seconds - first.seconds < 0.45 {
                passed = false
                detail = "Second macro key arrived before the 500 ms delay."
            }
        }
        results.append(.init(name: test.name, passed: passed, expected: expected,
                             observed: observed, detail: detail))
        append("\(passed ? "PASS" : "FAIL") · \(detail)")
        engine.cancelAll(reason: "Output verifier case boundary")
        if let next = Case(rawValue: test.rawValue + 1) { start(next) }
        else { stop(detail: nil) }
    }

    private func receive(_ event: NSEvent) {
        guard running, currentCase != nil,
              event.cgEvent?.getIntegerValueField(.eventSourceUserData) == SystemActionOutput.eventMarker else { return }
        let kind: String
        switch event.type {
        case .keyDown: kind = "down"
        case .keyUp: kind = "up"
        case .flagsChanged: kind = event.modifierFlags.contains(.command) ? "down" : "up"
        default: return
        }
        let item = ObservedEvent(kind: kind, code: event.keyCode,
                                 command: event.modifierFlags.contains(.command),
                                 shift: event.modifierFlags.contains(.shift),
                                 option: event.modifierFlags.contains(.option),
                                 modifierSides: UInt64(event.modifierFlags.rawValue) & MacModifierFlags.sideMask,
                                 seconds: ProcessInfo.processInfo.systemUptime - caseStart)
        observed.append(item)
        append("  \(kind) · key \(item.code) · Command \(item.command ? "on" : "off") · sides 0x\(String(item.modifierSides, radix: 16))")
    }

    private func stop(detail: String?) {
        guard running else { return }
        timer?.invalidate(); timer = nil
        engine?.cancelAll(reason: "Output verifier stopped")
        output?.enabled = false
        output?.stopObserving()
        output = nil; engine = nil
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        if let detail {
            results.append(.init(name: currentCase?.name ?? "Interrupted", passed: false,
                                 expected: currentCase?.expected ?? [], observed: observed,
                                 detail: detail))
            append(detail)
        }
        currentCase = nil
        running = false
        runButton?.isEnabled = true
        let passed = !results.isEmpty && results.allSatisfy(\.passed)
        statusLabel?.stringValue = passed ? "Passed · HID delivery into diagnostic window" : "Failed · inspect event log"
        writeReport(checks: results)
    }

    private func writeReport(checks: [CheckResult]) {
        let report = Report(generatedAt: ISO8601DateFormatter().string(from: Date()),
                            passed: !checks.isEmpty && checks.allSatisfy(\.passed) && checks.count == Case.allCases.count,
                            scope: "Production HID delivery into a disposable KDCustom window; not Rive/Adobe behavior or physical device capture.",
                            checks: checks)
        do {
            let directory = ProfileStore().directoryURL
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: directory.appendingPathComponent("output-check.json"), options: .atomic)
            append("Report: \(directory.appendingPathComponent("output-check.json").path)")
        } catch { append("Could not write report: \(error.localizedDescription)") }
    }

    private func append(_ line: String) {
        guard let logView else { return }
        logView.string += line + "\n"
        logView.scrollToEndOfDocument(nil)
    }

    func windowDidResignKey(_ notification: Notification) {
        stop(detail: "Verifier window lost focus.")
    }

    func windowWillClose(_ notification: Notification) {
        stop(detail: "Verifier window closed.")
        // Keep the reusable window alive through AppKit's close callback.
    }
}

/// First responder for the private PID target. Unmarked physical events are
/// ignored and never recorded. Command shortcuts are consumed before menus.
@MainActor
private final class MarkedEventReceiver: NSView {
    var onMarkedEvent: ((NSEvent) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard marked(event) else { return false }
        onMarkedEvent?(event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        if marked(event) { onMarkedEvent?(event) }
    }

    override func keyUp(with event: NSEvent) {
        if marked(event) { onMarkedEvent?(event) }
    }

    override func flagsChanged(with event: NSEvent) {
        if marked(event) { onMarkedEvent?(event) }
    }

    private func marked(_ event: NSEvent) -> Bool {
        event.cgEvent?.getIntegerValueField(.eventSourceUserData) == SystemActionOutput.eventMarker
    }
}
