import AppKit
import ApplicationServices
import Carbon

/// Exercises the real AX adapter on disposable fields in this process only.
/// It has no route to user documents, profiles, or external applications.
@MainActor
final class SmartInputVerifier: NSObject, NSWindowDelegate {
    static let shared = SmartInputVerifier()
    private var window: NSWindow?
    private var field: NSTextField?
    private var status: NSTextField?
    private var runButton: NSButton?
    private var observer: FocusedInputObserver?
    private var timer: Timer?
    private var token: String?
    private var running = false
    private var readyToBegin = false
    private var checks: [[String: Any]] = []

    func show() {
        if let window { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 280),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "KDCustom · Smart input check"
        window.isReleasedWhenClosed = false
        window.delegate = self
        let root = NSView(frame: NSRect(x: 0,y: 0,width: 540,height: 280))
        let title = NSTextField(labelWithString: "Smart numeric input")
        title.font = .systemFont(ofSize: 20, weight: .medium); title.frame = NSRect(x: 24,y: 230,width: 490,height: 30)
        let note = NSTextField(wrappingLabelWithString: "Tests a disposable field in KDCustom. This checks the AX adapter, not Rive or Adobe field support. Keep this window in front.")
        note.frame = NSRect(x: 24,y: 174,width: 490,height: 46)
        let field = NSTextField(string: "1")
        field.identifier = NSUserInterfaceItemIdentifier("kdcustom-smart-test-number")
        field.setAccessibilityIdentifier("kdcustom-smart-test-number")
        field.setAccessibilityLabel("Test number")
        field.frame = NSRect(x: 24,y: 122,width: 210,height: 30)
        let status = NSTextField(wrappingLabelWithString: "Ready for an isolated numeric check.")
        status.frame = NSRect(x: 24,y: 62,width: 490,height: 46)
        let button = NSButton(title: "Run check", target: self, action: #selector(run))
        button.frame = NSRect(x: 24,y: 20,width: 130,height: 30)
        for view in [title, note, field, status, button] { root.addSubview(view) }
        window.contentView = root
        self.window = window; self.field = field; self.status = status; self.runButton = button
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func run() {
        guard !running, AXIsProcessTrusted(), !IsSecureEventInputEnabled(), let window, let field else { return }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() else {
            status?.stringValue = "Bring this window to the foreground, then run again. No field was changed."
            return
        }
        checks = []; running = true; readyToBegin = true; token = nil; runButton?.isEnabled = false
        field.stringValue = "1"; window.makeFirstResponder(field)
        status?.stringValue = "Waiting for this test field…"
        let observer = FocusedInputObserver()
        self.observer = observer
        observer.onChange = { [weak self] focus in
            guard let self, self.running, focus.kind == .text || focus.kind == .numeric,
                  focus.identifier == "kdcustom-smart-test-number" else { return }
            self.token = focus.token
            if self.readyToBegin {
                self.readyToBegin = false
                self.adjust(times: 10, delta: 0.01) { [weak self] in self?.checkDecimal() }
            }
        }
        observer.observe(pid: getpid(), bundleIdentifier: Bundle.main.bundleIdentifier, enabled: true)
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.running else { return }
                if self.window?.isKeyWindow != true || IsSecureEventInputEnabled() {
                    self.finish("Stopped: window focus or Secure Input changed.")
                } else if ProcessInfo.processInfo.systemUptime > deadline {
                    self.finish("Timed out waiting for an accessibility result.")
                }
            }
        }
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    private func adjust(times: Int, delta: Double, done: @escaping @MainActor () -> Void) {
        guard running, let token else { return }
        if times == 0 { done(); return }
        observer?.adjustNumeric(token: token, delta: delta, allowTextField: true) { [weak self] result in
            guard let self, self.running else { return }
            guard case .applied = result else { self.finish("Numeric check stopped: \(result). No fallback was sent."); return }
            self.adjust(times: times - 1, delta: delta, done: done)
        }
    }
    private func checkDecimal() {
        add("Ten increments of 0.01", field?.stringValue == "1.1")
        adjust(times: 1, delta: 10) { [weak self] in
            guard let self, self.running, let field = self.field, let token = self.token else { return }
            self.add("One increment of 10", field.stringValue == "11.1")
            self.observer?.adjustNumeric(token: token, delta: 20, allowTextField: true) { [weak self] result in
                guard let self, self.running else { return }
                if case .cancelled = result { self.add("Immediate cancellation", self.field?.stringValue == "11.1") }
                else { self.add("Immediate cancellation", false) }
                self.checkTextRejection()
            }
            self.observer?.cancelNumericAdjustments()
        }
    }
    private func checkTextRejection() {
        guard running, let field, let token else { return }
        field.stringValue = "2 + 2"
        observer?.adjustNumeric(token: token, delta: 1, allowTextField: true) { [weak self] result in
            guard let self, self.running else { return }
            if case .unsupported = result { self.add("Expressions left unchanged", self.field?.stringValue == "2 + 2") }
            else { self.add("Expressions left unchanged", false) }
            self.finish(self.checks.allSatisfy { $0["passed"] as? Bool == true } ? "All 4 Smart input checks passed." : "A Smart input check failed.")
        }
    }
    private func add(_ name: String, _ passed: Bool) { checks.append(["name": name, "passed": passed]) }
    private func finish(_ message: String) {
        running = false; readyToBegin = false
        observer?.stop(); observer = nil
        timer?.invalidate(); timer = nil
        runButton?.isEnabled = true; status?.stringValue = message
        let report: [String: Any] = ["scope": "Private disposable AppKit field only", "message": message,
            "checks": checks, "passed": checks.count == 4 && checks.allSatisfy { $0["passed"] as? Bool == true },
            "generatedAt": ISO8601DateFormatter().string(from: Date())]
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/KeydialStudio/smart-input-check.json")
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url, options: .atomic)
        }
    }
    func windowWillClose(_ notification: Notification) {
        if running { finish("Stopped: test window closed.") }
        window = nil; field = nil; status = nil; runButton = nil
    }
}
