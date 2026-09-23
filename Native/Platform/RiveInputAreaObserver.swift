import AppKit
import ApplicationServices
import Carbon
import Foundation

/// Opt-in Rive area observation. A click identifies the interaction surface;
/// repeated snapshots verify its window and current layout before using it.
/// Only an area enum crosses this boundary, never a numeric field value.
@MainActor
final class RiveInputAreaObserver {
    var onChange: ((InputArea?, String) -> Void)?
    var shouldDeferCapture: (() -> Bool)?
    private let queue = DispatchQueue(label: "Keydial.RiveInputArea", qos: .utility)
    private var pid: pid_t?
    private var generation = UUID()
    private var timer: Timer?
    private var busy = false
    private var pendingClick: RivePointerSample?
    private var selection = RiveAreaSelection()
    private var area: InputArea?
    private var confirmedAt: TimeInterval = 0
    private var status = "Area detection is off"

    var currentArea: InputArea? {
        guard pid == NSWorkspace.shared.frontmostApplication?.processIdentifier,
              ProcessInfo.processInfo.systemUptime - confirmedAt <= 0.9 else { return nil }
        return area
    }

    func configure(pid: pid_t?, enabled: Bool) {
        let next = enabled ? pid : nil
        guard self.pid != next else { return }
        self.pid = next
        generation = UUID(); pendingClick = nil; selection.reset()
        timer?.invalidate(); timer = nil
        publish(nil, next == nil ? "Area detection is off" : "Select a Rive area")
        guard next != nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.capture() }
        }
        capture()
    }

    /// Called before observing a new physical click or key. Modifier flags do
    /// not invalidate the area, so held shortcut selectors keep working.
    func physicalInput() {
        guard pid != nil else { return }
        generation = UUID(); pendingClick = nil; selection.reset()
        publish(nil, "Checking Rive area")
    }

    func pointerDown(_ point: CGPoint) {
        guard let pid, pid == NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
        pendingClick = RivePointerSample(pidAtMouseDown: pid, screenPoint: point,
                                        happenedAt: ProcessInfo.processInfo.systemUptime)
        let token = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.generation == token else { return }
            self.capture()
        }
    }

    func focusChanged() {
        guard pid != nil else { return }
        // Preserve the click that caused a transient AX focus notification.
        if pendingClick == nil { selection.reset(); generation = UUID() }
        publish(nil, "Checking Rive area")
    }

    func reset() {
        generation = UUID(); selection.reset(); pendingClick = nil
        publish(nil, pid == nil ? "Area detection is off" : "Select a Rive area")
    }

    private func publish(_ next: InputArea?, _ detail: String) {
        confirmedAt = ProcessInfo.processInfo.systemUptime
        guard area != next || status != detail else { return }
        area = next; status = detail; onChange?(next, detail)
    }

    private func capture() {
        guard shouldDeferCapture?() != true, !busy, let pid, AXIsProcessTrusted(), !IsSecureEventInputEnabled(),
              pid == NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
        busy = true
        let token = generation, click = pendingClick
        queue.async { [weak self] in
            let snapshot = RivePanelProbe().collect(rivePID: pid, pointer: click, inspectNumericText: true)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.busy = false
                guard self.shouldDeferCapture?() != true, self.generation == token, self.pid == pid,
                      pid == NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
                guard let snapshot else {
                    self.selection.reset()
                    self.publish(nil, "Rive area unavailable")
                    return
                }
                let decision = self.selection.select(snapshot, expectedPID: pid,
                    now: ProcessInfo.processInfo.systemUptime)
                self.pendingClick = nil
                self.publish(decision.area, decision.status)
            }
        }
    }
}
