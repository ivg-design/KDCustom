import AppKit
import ApplicationServices
import Carbon
import Foundation

/// An explicitly armed, short-lived diagnostic. It never selects a profile or
/// sends input. Snapshots contain only the probe's sanitized structural data.
@MainActor
final class RivePanelDiagnostics {
    var onChange: ((String) -> Void)?
    private let queue = DispatchQueue(label: "Keydial.RivePanelProbe", qos: .utility)
    private var expiresAt: TimeInterval = 0
    private var session = UUID()
    private var request = UUID()
    private var pending: DispatchWorkItem?
    private var latest: RivePanelSnapshot?
    private var history: [[String: Any]] = []
    private var events: [[String: Any]] = []
    private var captureCount = 0
    private var lastScheduled: TimeInterval = 0
    private var previousPID: pid_t?

    var armed: Bool { ProcessInfo.processInfo.systemUptime < expiresAt }

    func start() {
        session = UUID(); request = UUID(); pending?.cancel()
        expiresAt = ProcessInfo.processInfo.systemUptime + 120
        latest = nil; history = []; events = []; captureCount = 0; lastScheduled = 0
        onChange?("Observing Rive for 2 minutes · click a panel or field")
        let current = session
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self] in
            guard let self, self.session == current else { return }
            self.stop()
        }
        capture()
    }

    func stop() {
        expiresAt = 0; request = UUID(); pending?.cancel(); pending = nil
        onChange?("Inspection stopped · last results retained")
    }

    func foregroundChanged(_ app: NSRunningApplication?) {
        guard previousPID != app?.processIdentifier else { return }
        previousPID = app?.processIdentifier
        request = UUID(); pending?.cancel()
        note("foreground", app?.bundleIdentifier == "app.rive.editor" ? "Rive" : "Other app")
        if app?.bundleIdentifier == "app.rive.editor" { capture() }
    }

    func pointerDown(_ point: CGPoint) {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier == "app.rive.editor" else { return }
        let pointer = RivePointerSample(pidAtMouseDown: app.processIdentifier,
            screenPoint: point, happenedAt: ProcessInfo.processInfo.systemUptime)
        note("pointer", "Mouse down in Rive")
        capture(pointer: pointer)
    }

    /// Call with program-defined state labels only, never document/input text.
    func note(_ category: String, _ detail: String) {
        guard armed else { return }
        events.append(["uptime": ProcessInfo.processInfo.systemUptime,
                       "category": category, "detail": detail])
        if events.count > 400 { events.removeFirst(events.count - 400) }
    }

    private func capture(pointer: RivePointerSample? = nil) {
        guard armed, captureCount < 30, AXIsProcessTrusted(), !IsSecureEventInputEnabled(),
              let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier == "app.rive.editor" else { return }
        let now = ProcessInfo.processInfo.systemUptime
        // Coalesce clicks rather than queue AX work behind a drag or double click.
        pending?.cancel(); request = UUID()
        let token = request, currentSession = session, pid = app.processIdentifier
        let delay = max(0.12, lastScheduled + 0.3 - now)
        lastScheduled = now + delay
        let work = DispatchWorkItem { [weak self] in
            let snapshot = RivePanelProbe().collect(rivePID: pid, pointer: pointer)
            Task { @MainActor [weak self] in
                guard let self, self.armed, self.session == currentSession,
                      self.request == token else { return }
                self.captureCount += 1
                guard let snapshot else {
                    self.note("probe", "Unavailable or budget/scope check failed")
                    self.onChange?("Rive inspection unavailable · no route changed")
                    return
                }
                self.latest = snapshot
                let decision = RivePanelClassifier.classify(snapshot, expectedPID: pid,
                    expectedWindowKey: snapshot.windowKey, now: ProcessInfo.processInfo.systemUptime)
                let summary: [String: Any] = ["uptime": snapshot.capturedAt,
                    "focusedPanel": decision.focusedPanel?.rawValue as Any? ?? NSNull(),
                    "lastInteractedPanel": decision.lastInteractedPanel?.rawValue as Any? ?? NSNull(),
                    "candidate": decision.automaticPanel?.rawValue as Any? ?? NSNull(),
                    "reason": String(describing: decision.reason), "nodes": snapshot.nodes.count,
                    "truncated": snapshot.truncated]
                self.history.append(summary)
                self.onChange?("Last capture: \(decision.lastInteractedPanel?.rawValue ?? decision.focusedPanel?.rawValue ?? "unknown") · \(snapshot.nodes.count) AX nodes · diagnostics only")
            }
        }
        pending = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func read() -> [String: Any] {
        var result: [String: Any] = ["armed": armed,
            "remainingSeconds": max(0, expiresAt - ProcessInfo.processInfo.systemUptime),
            "history": history, "events": events,
            "note": "Historical diagnostic snapshots only; not an active route. No input values, document strings, screenshots, or profile changes."]
        if let snapshot = latest {
            func rect(_ value: CGRect?) -> Any {
                guard let value else { return NSNull() }
                return ["x": value.minX, "y": value.minY, "width": value.width, "height": value.height]
            }
            result["latest"] = ["pid": snapshot.pid, "windowKey": snapshot.windowKey,
                "capturedUptime": snapshot.capturedAt, "windowFrame": rect(snapshot.windowFrame),
                "focusedNodeID": snapshot.focusedNodeID as Any? ?? NSNull(),
                "hitNodeID": snapshot.hitNodeID as Any? ?? NSNull(), "truncated": snapshot.truncated,
                "nodes": snapshot.nodes.map { node in
                    ["id": node.id, "parentID": node.parentID as Any? ?? NSNull(),
                     "role": String(describing: node.role), "frame": rect(node.frame),
                     "anchors": node.anchors.map(\.rawValue).sorted()] as [String: Any]
                }]
        }
        return result
    }
}
