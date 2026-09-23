import ApplicationServices
import Foundation

/// Passive observation reads only accessibility metadata. An explicit dial
/// adjustment may read and write a numeric AXValue on the same focused element;
/// field values never leave the worker or enter the snapshot.
@MainActor
final class FocusedInputObserver {
    var onChange: ((FocusSnapshot) -> Void)?

    private var pid: pid_t?
    private var bundleIdentifier: String?
    private var enabled = false
    private var generation: UInt64 = 0
    private var focusEpoch: UInt64 = 0
    private var snapshot = FocusSnapshot()
    private let numericLease = NumericAdjustmentLease()
    private let worker: FocusAXWorker

    init() {
        worker = FocusAXWorker(lease: numericLease)
        worker.onResult = { [weak self] generation, epoch, candidate in
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation,
                      self.focusEpoch == epoch, self.enabled else { return }
                // Deliver unchanged polls too: the caller uses them to renew
                // freshness, while comparing equality before changing routes.
                self.snapshot = candidate
                if candidate.kind == .unavailable || candidate.kind == .secure {
                    self.numericLease.invalidate()
                } else {
                    self.numericLease.publish(generation: generation, epoch: epoch,
                                              token: candidate.token)
                }
                self.onChange?(candidate)
            }
        }
        worker.onFocusNotification = { [weak self] notificationGeneration in
            guard let self, self.generation == notificationGeneration else { return }
            self.invalidateForFocusChange()
        }
    }

    deinit {
        numericLease.invalidate()
        worker.configure(pid: nil, bundleIdentifier: nil, generation: 0,
                         unavailable: FocusSnapshot())
    }

    func observe(pid: pid_t?, bundleIdentifier: String?, enabled: Bool) {
        let valid = enabled && (pid ?? 0) > 0
        guard self.pid != pid || self.bundleIdentifier != bundleIdentifier || self.enabled != valid else { return }
        self.pid = pid
        self.bundleIdentifier = bundleIdentifier
        self.enabled = valid
        generation &+= 1
        focusEpoch = 0
        publishUnavailable()
        worker.configure(pid: valid ? pid : nil, bundleIdentifier: bundleIdentifier,
                         generation: generation, unavailable: snapshot)
    }

    func stop() {
        numericLease.invalidate()
        observe(pid: nil, bundleIdentifier: nil, enabled: false)
    }

    /// Immediately revokes queued and pre-write requests without discarding
    /// the currently observed focus. A later dial step may use the same token.
    func cancelNumericAdjustments() {
        numericLease.cancelPending()
    }

    func adjustNumeric(token: String, delta: Double, allowTextField: Bool,
                       completion: @escaping @MainActor (NumericAdjustmentResult) -> Void) {
        guard enabled, snapshot.token == token,
              snapshot.kind != .unavailable, snapshot.kind != .secure else {
            completion(.cancelled); return
        }
        guard snapshot.kind == .numeric || (snapshot.kind == .text && allowTextField) else {
            completion(.unsupported); return
        }
        guard NumericAdjustment.validDelta(delta) else { completion(.failed); return }
        guard let ticket = numericLease.reserve(generation: generation, epoch: focusEpoch,
                                                token: token) else {
            completion(.cancelled); return
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.5
        worker.adjustNumeric(ticket: ticket, delta: delta, deadline: deadline,
                             completion: completion)
    }

    private func invalidateForFocusChange() {
        guard enabled else { return }
        focusEpoch &+= 1
        publishUnavailable()
        worker.focusChanged(epoch: focusEpoch, unavailable: snapshot)
    }

    private func publishUnavailable() {
        numericLease.invalidate()
        let empty = FocusSnapshot()
        snapshot = empty
        onChange?(empty)
    }
}

/// Main-thread invalidation is synchronous even when an AX call occupies the
/// serial worker. At most four dial requests can be queued or in flight.
private final class NumericAdjustmentLease: @unchecked Sendable {
    struct Ticket: Sendable {
        let generation: UInt64
        let epoch: UInt64
        let token: String
        let revision: UInt64
    }

    private let lock = NSLock()
    private var current: Ticket?
    private var revision: UInt64 = 0
    private var pending = 0

    func publish(generation: UInt64, epoch: UInt64, token: String) {
        lock.lock(); defer { lock.unlock() }
        if current?.generation == generation && current?.epoch == epoch && current?.token == token {
            return
        }
        revision &+= 1
        current = Ticket(generation: generation, epoch: epoch, token: token, revision: revision)
    }

    func invalidate() {
        lock.lock(); defer { lock.unlock() }
        revision &+= 1
        current = nil
    }

    func cancelPending() {
        lock.lock(); defer { lock.unlock() }
        revision &+= 1
        if let current {
            self.current = Ticket(generation: current.generation, epoch: current.epoch,
                                  token: current.token, revision: revision)
        }
    }

    func reserve(generation: UInt64, epoch: UInt64, token: String) -> Ticket? {
        lock.lock(); defer { lock.unlock() }
        guard let current, current.generation == generation, current.epoch == epoch,
              current.token == token, pending < 4 else { return nil }
        pending += 1
        return current
    }

    func isCurrent(_ ticket: Ticket) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return current?.generation == ticket.generation && current?.epoch == ticket.epoch &&
            current?.token == ticket.token && current?.revision == ticket.revision
    }

    func finish() {
        lock.lock(); defer { lock.unlock() }
        pending -= 1
    }
}

/// The serial queue owns the cache and polling. Remote-process AX calls run
/// there; AX calls into this app run synchronously on the main queue because
/// AppKit's own accessibility setters are main-thread-only. The worker waits
/// while the main queue borrows its state, so its cache is still serialized.
private final class FocusAXNotificationContext {
    weak var worker: FocusAXWorker?
    let generation: UInt64

    init(worker: FocusAXWorker, generation: UInt64) {
        self.worker = worker
        self.generation = generation
    }
}

private final class FocusAXWorker: @unchecked Sendable {
    var onResult: (@Sendable (UInt64, UInt64, FocusSnapshot) -> Void)?
    var onFocusNotification: (@MainActor @Sendable (UInt64) -> Void)?

    private let queue = DispatchQueue(label: "Keydial.FocusedInputAX", qos: .utility)
    private let numericLease: NumericAdjustmentLease
    private var timer: DispatchSourceTimer?
    private var app: AXUIElement?
    private var observer: AXObserver?
    private var notificationContext: UnsafeMutableRawPointer?
    private var observedPID: pid_t?
    private var bundleIdentifier: String?
    private var generation: UInt64 = 0
    private var epoch: UInt64 = 0
    private var lastElement: AXUIElement?
    private var lastSnapshot: FocusSnapshot?

    init(lease: NumericAdjustmentLease) {
        numericLease = lease
    }

    func configure(pid: pid_t?, bundleIdentifier: String?, generation: UInt64,
                   unavailable: FocusSnapshot) {
        queue.async { [self] in
            onAXThread(for: observedPID) { removeObserver() }
            timer?.cancel()
            timer = nil
            app = nil
            lastElement = nil
            lastSnapshot = unavailable
            observedPID = pid
            self.bundleIdentifier = bundleIdentifier
            self.generation = generation
            epoch = 0
            guard let pid else { return }

            onAXThread(for: pid) {
                let target = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(target, 0.15)
                app = target
                installObserver(on: target, pid: pid)
            }

            let poll = DispatchSource.makeTimerSource(queue: queue)
            poll.schedule(deadline: .now(), repeating: .milliseconds(250), leeway: .milliseconds(35))
            poll.setEventHandler { [weak self] in self?.refresh() }
            timer = poll
            poll.resume()
        }
    }

    func focusChanged(epoch: UInt64, unavailable: FocusSnapshot) {
        queue.async { [self] in
            self.epoch = epoch
            lastElement = nil
            lastSnapshot = unavailable
            refresh()
        }
    }

    func adjustNumeric(ticket: NumericAdjustmentLease.Ticket, delta: Double,
                       deadline: TimeInterval,
                       completion: @escaping @MainActor (NumericAdjustmentResult) -> Void) {
        queue.async { [self] in
            let result = onAXThread(for: observedPID) {
                performNumericAdjustment(ticket: ticket, delta: delta, deadline: deadline)
            }
            numericLease.finish()
            Task { @MainActor in completion(result) }
        }
    }

    /// Called only from the worker queue. All app-owned AX access, including
    /// passive inspection and notification registration, uses AppKit's queue.
    /// The main actor never waits synchronously for this worker.
    private func onAXThread<T>(for pid: pid_t?, _ operation: () -> T) -> T {
        guard pid == getpid() else { return operation() }
        return DispatchQueue.main.sync(execute: operation)
    }

    private func performNumericAdjustment(ticket: NumericAdjustmentLease.Ticket, delta: Double,
                                          deadline: TimeInterval) -> NumericAdjustmentResult {
        guard numericLease.isCurrent(ticket),
              ProcessInfo.processInfo.systemUptime <= deadline,
              generation == ticket.generation, epoch == ticket.epoch,
              lastSnapshot?.token == ticket.token,
              let focused = lastElement, let app, let pid = observedPID else { return .cancelled }

        AXUIElementSetMessagingTimeout(focused, 0.12)
        guard hasExpectedFocus(focused, app: app, pid: pid, deadline: deadline) else { return .cancelled }
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(focused, kAXValueAttribute as CFString, &settable) == .success,
              settable.boolValue else { return .unsupported }
        guard numericLease.isCurrent(ticket), ProcessInfo.processInfo.systemUptime <= deadline else {
            return .cancelled
        }

        // AXValue is read only for this explicit dial request. No value is
        // copied into a FocusSnapshot, completion, event record, or persistence.
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused, kAXValueAttribute as CFString, &rawValue) == .success,
              let rawValue else { return .unsupported }
        let lower = readBound(kAXMinValueAttribute as CFString, from: focused)
        let upper = readBound(kAXMaxValueAttribute as CFString, from: focused)
        guard case let .valid(minimum) = lower, case let .valid(maximum) = upper else {
            return .unsupported
        }
        let replacement: CFTypeRef
        if CFGetTypeID(rawValue) == CFNumberGetTypeID(), let number = rawValue as? NSNumber,
           let adjusted = NumericAdjustment.adjustedNumber(number, delta: delta,
                                                           minimum: minimum, maximum: maximum) {
            replacement = adjusted
        } else if CFGetTypeID(rawValue) == CFStringGetTypeID(), let text = rawValue as? String,
                  let adjusted = NumericAdjustment.adjustedString(text, delta: delta,
                                                                  minimum: minimum, maximum: maximum) {
            replacement = adjusted as CFString
        } else {
            return .unsupported
        }
        // This second identity check is adjacent to the write. A notification,
        // app switch or explicit cancellation revokes the ticket immediately.
        guard numericLease.isCurrent(ticket),
              hasExpectedFocus(focused, app: app, pid: pid, deadline: deadline),
              numericLease.isCurrent(ticket),
              ProcessInfo.processInfo.systemUptime <= deadline else { return .cancelled }
        let status = AXUIElementSetAttributeValue(focused, kAXValueAttribute as CFString,
                                                  replacement)
        return status == .success ? .applied : .failed
    }

    private enum BoundRead {
        case valid(Double?)
        case invalid
    }

    private func readBound(_ attribute: CFString, from element: AXUIElement) -> BoundRead {
        var raw: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute, &raw)
        if status == .attributeUnsupported || status == .noValue || status == .notImplemented {
            return .valid(nil)
        }
        guard status == .success, let raw, CFGetTypeID(raw) == CFNumberGetTypeID(),
              let number = raw as? NSNumber, number.doubleValue.isFinite,
              abs(number.doubleValue) <= NumericAdjustment.maximumMagnitude else { return .invalid }
        return .valid(number.doubleValue)
    }

    private func hasExpectedFocus(_ focused: AXUIElement, app: AXUIElement, pid: pid_t,
                                  deadline: TimeInterval) -> Bool {
        guard ProcessInfo.processInfo.systemUptime <= deadline else { return false }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.12)
        var frontmost: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedApplicationAttribute as CFString,
                                            &frontmost) == .success,
              let frontmost, CFGetTypeID(frontmost) == AXUIElementGetTypeID() else { return false }
        var frontmostPID: pid_t = 0
        guard AXUIElementGetPid(frontmost as! AXUIElement, &frontmostPID) == .success,
              frontmostPID == pid,
              ProcessInfo.processInfo.systemUptime <= deadline else { return false }
        var current: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString,
                                            &current) == .success,
              let current, CFGetTypeID(current) == AXUIElementGetTypeID(),
              CFEqual(current, focused),
              ProcessInfo.processInfo.systemUptime <= deadline else { return false }
        return true
    }

    private func installObserver(on app: AXUIElement, pid: pid_t) {
        var created: AXObserver?
        let callback: AXObserverCallback = { _, _, _, context in
            guard let context else { return }
            let payload = Unmanaged<FocusAXNotificationContext>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { payload.worker?.onFocusNotification?(payload.generation) }
        }
        guard AXObserverCreate(pid, callback, &created) == .success,
              let created else { return }
        let context = Unmanaged.passRetained(
            FocusAXNotificationContext(worker: self, generation: generation)
        ).toOpaque()
        let status = AXObserverAddNotification(created, app,
                                               kAXFocusedUIElementChangedNotification as CFString,
                                               context)
        guard status == .success else {
            Unmanaged<FocusAXNotificationContext>.fromOpaque(context).release()
            return
        }
        observer = created
        notificationContext = context
        let source = AXObserverGetRunLoopSource(created)
        DispatchQueue.main.async {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
    }

    private func removeObserver() {
        guard let observer, let app else { return }
        // Removing the run-loop source on the same main queue as installation
        // keeps the callback context alive until delivery is impossible.
        _ = AXObserverRemoveNotification(observer, app,
                                         kAXFocusedUIElementChangedNotification as CFString)
        let source = AXObserverGetRunLoopSource(observer)
        let context = notificationContext
        notificationContext = nil
        DispatchQueue.main.async {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            if let context {
                Unmanaged<FocusAXNotificationContext>.fromOpaque(context).release()
            }
        }
        self.observer = nil
    }

    private func refresh() {
        guard let app, let observedPID else { return }
        let currentGeneration = generation
        let currentEpoch = epoch
        let deadline = ProcessInfo.processInfo.systemUptime + 0.5
        var candidate = onAXThread(for: observedPID) {
            inspectFocusedElement(in: app, pid: observedPID, deadline: deadline)
        }
        if ProcessInfo.processInfo.systemUptime > deadline {
            candidate = unavailable()
        }
        onResult?(currentGeneration, currentEpoch, candidate)
    }

    private func inspectFocusedElement(in app: AXUIElement, pid: pid_t,
                                       deadline: TimeInterval) -> FocusSnapshot {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else {
            return unavailable()
        }
        let focused = raw as! AXUIElement
        var elementPID: pid_t = 0
        guard AXUIElementGetPid(focused, &elementPID) == .success, elementPID == pid else {
            return unavailable()
        }
        AXUIElementSetMessagingTimeout(focused, 0.15)
        guard let role = stringAttribute(kAXRoleAttribute as CFString, from: focused) else {
            return unavailable()
        }
        var rawSubrole: CFTypeRef?
        let subroleStatus = AXUIElementCopyAttributeValue(focused, kAXSubroleAttribute as CFString,
                                                          &rawSubrole)
        guard subroleStatus == .success || subroleStatus == .noValue
                || subroleStatus == .attributeUnsupported || subroleStatus == .notImplemented
        else { return unavailable() }
        if subroleStatus == .success,
           (rawSubrole == nil || CFGetTypeID(rawSubrole!) != CFStringGetTypeID()) {
            return unavailable()
        }
        let subrole = rawSubrole.flatMap { CFGetTypeID($0) == CFStringGetTypeID() ? $0 as? String : nil }
        guard ProcessInfo.processInfo.systemUptime <= deadline else { return unavailable() }
        let secure = subrole == (kAXSecureTextFieldSubrole as String)
        let kind: FocusKind
        if secure {
            kind = .secure
        } else if role == (kAXSliderRole as String) || role == (kAXIncrementorRole as String)
                    || hasIncrementActions(focused) || hasNumericBoundsAndIncrement(focused) {
            kind = .numeric
        } else if role == (kAXTextFieldRole as String) || role == (kAXTextAreaRole as String) {
            kind = .text
        } else {
            kind = .other
        }
        guard ProcessInfo.processInfo.systemUptime <= deadline else { return unavailable() }
        let identifier = secure ? nil : stringAttribute(kAXIdentifierAttribute as CFString, from: focused).map(capped)
        let label = secure ? nil : (stringAttribute(kAXTitleAttribute as CFString, from: focused)
                                    ?? stringAttribute(kAXDescriptionAttribute as CFString, from: focused)).map(capped)
        guard ProcessInfo.processInfo.systemUptime <= deadline else { return unavailable() }
        let sameElement = lastElement.map { CFEqual($0, focused) } ?? false
        let sameMetadata = lastSnapshot.map {
            $0.bundleIdentifier == bundleIdentifier && $0.role == role && $0.subrole == subrole
                && $0.identifier == identifier && $0.label == label && $0.kind == kind
        } ?? false
        let token = sameElement && sameMetadata ? lastSnapshot!.token : UUID().uuidString
        let next = FocusSnapshot(token: token, bundleIdentifier: bundleIdentifier, role: role,
                                 subrole: subrole, identifier: identifier, label: label, kind: kind)
        lastElement = focused
        lastSnapshot = next
        return next
    }

    private func capped(_ value: String) -> String {
        String(value.prefix(256))
    }

    private func unavailable() -> FocusSnapshot {
        lastElement = nil
        if let lastSnapshot, lastSnapshot.kind == .unavailable { return lastSnapshot }
        let next = FocusSnapshot()
        lastSnapshot = next
        return next
    }

    private func stringAttribute(_ name: CFString, from element: AXUIElement) -> String? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &raw) == .success,
              let raw, CFGetTypeID(raw) == CFStringGetTypeID() else { return nil }
        return raw as? String
    }

    private func numericAttribute(_ name: CFString, from element: AXUIElement) -> Double? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &raw) == .success,
              let raw, CFGetTypeID(raw) == CFNumberGetTypeID() else { return nil }
        return (raw as? NSNumber)?.doubleValue
    }

    private func hasNumericBoundsAndIncrement(_ element: AXUIElement) -> Bool {
        guard let min = numericAttribute(kAXMinValueAttribute as CFString, from: element),
              let max = numericAttribute(kAXMaxValueAttribute as CFString, from: element),
              let increment = numericAttribute(kAXValueIncrementAttribute as CFString, from: element)
        else { return false }
        return min.isFinite && max.isFinite && increment.isFinite && min < max && increment > 0
    }

    private func hasIncrementActions(_ element: AXUIElement) -> Bool {
        var raw: CFArray?
        guard AXUIElementCopyActionNames(element, &raw) == .success,
              let names = raw as? [String] else { return false }
        return names.contains(kAXIncrementAction as String) || names.contains(kAXDecrementAction as String)
    }
}
