import AppKit
import ApplicationServices
import Foundation

struct RivePointerSample: Sendable {
    let pidAtMouseDown: pid_t
    /// AX uses top-left-relative global screen coordinates.
    let screenPoint: CGPoint
    let happenedAt: TimeInterval
}

/// Read-only, bounded AX sampling for an already-frontmost Rive editor. Call
/// from a serial background AX worker, not the main actor. This collector does
/// not install a monitor, enable semantics, capture pixels, or route actions.
final class RivePanelProbe {
    private let maxNodes = 128
    private let maxDepth = 8
    private let maxDuration: TimeInterval = 0.16
    private let perMessageTimeout: Float = 0.04
    /// Accessed only from the caller's serial background AX queue.
    private var activeDeadline: TimeInterval = 0

    func collect(rivePID: pid_t, pointer: RivePointerSample? = nil) -> RivePanelSnapshot? {
        guard !Thread.isMainThread, rivePID > 0,
              NSRunningApplication(processIdentifier: rivePID)?.bundleIdentifier == "app.rive.editor"
        else { return nil }
        let start = ProcessInfo.processInfo.systemUptime
        let deadline = start + maxDuration
        activeDeadline = deadline
        let system = AXUIElementCreateSystemWide()
        guard let frontmost = element(kAXFocusedApplicationAttribute as CFString, from: system),
              elementPID(frontmost) == rivePID,
              ProcessInfo.processInfo.systemUptime < deadline else { return nil }

        let app = AXUIElementCreateApplication(rivePID)
        AXUIElementSetMessagingTimeout(app, perMessageTimeout)
        guard let window = element(kAXFocusedWindowAttribute as CFString, from: app),
              elementPID(window) == rivePID,
              ProcessInfo.processInfo.systemUptime < deadline else { return nil }
        AXUIElementSetMessagingTimeout(window, perMessageTimeout)
        let windowFrame = frame(of: window)

        let focused: AXUIElement?
        if let candidate = element(kAXFocusedUIElementAttribute as CFString, from: app),
           elementPID(candidate) == rivePID,
           belongs(candidate, to: window, deadline: deadline) {
            focused = candidate
        } else {
            focused = nil
        }

        var hit: AXUIElement?
        var interactionAt: TimeInterval?
        if let pointer, pointer.pidAtMouseDown == rivePID,
           pointer.happenedAt <= start,
           start - pointer.happenedAt <= RivePanelClassifier.interactionLifetime,
           let windowFrame, windowFrame.contains(pointer.screenPoint),
           prepare(app) {
            var candidate: AXUIElement?
            if AXUIElementCopyElementAtPosition(app, Float(pointer.screenPoint.x),
                                                Float(pointer.screenPoint.y), &candidate) == .success,
               let candidate, elementPID(candidate) == rivePID,
               belongs(candidate, to: window, deadline: deadline) {
                hit = candidate
                interactionAt = pointer.happenedAt
            }
        }

        // Keep AXUIElement references only inside this method. The returned
        // tree contains sanitized roles, allowlisted chrome tokens, and frames.
        var elements: [AXUIElement] = [window]
        var nodes: [RivePanelNode] = [RivePanelNode(id: 0, parentID: nil, role: sanitizedRole(of: window),
                                                   frame: windowFrame, anchors: [])]
        var truncated = false
        // Collect the two verified paths first, then inspect only their local
        // panel-sized ancestor groups. A whole-window walk is too large and
        // would mix unrelated editor panels and user-authored scene content.
        let focusedID = appendPath(to: focused, window: window, deadline: deadline,
                                   elements: &elements, nodes: &nodes, truncated: &truncated)
        let hitID = appendPath(to: hit, window: window, deadline: deadline,
                               elements: &elements, nodes: &nodes, truncated: &truncated)
        if let windowFrame, !truncated {
            let seeds = [focusedID, hitID].compactMap { $0 }
            var roots = Set<Int>()
            for seed in seeds {
                var current: Int? = seed
                while let id = current {
                    let node = nodes[id]
                    if node.role == .group, let frame = node.frame,
                       frame.width * frame.height <= windowFrame.width * windowFrame.height * 0.65,
                       frame.width * frame.height >= windowFrame.width * windowFrame.height * 0.01 {
                        roots.insert(id)
                    }
                    current = node.parentID
                }
            }
            // Smallest regions first; a large scene tree cannot starve an
            // inspector or stage subtree that already contains the hit.
            for rootID in roots.sorted(by: {
                let left = nodes[$0].frame!, right = nodes[$1].frame!
                return left.width * left.height < right.width * right.height
            }) {
                var level = 0
                var parent = nodes[rootID].parentID
                while let id = parent, level <= maxDepth {
                    level += 1
                    parent = nodes[id].parentID
                }
                var pending: [(Int, Int)] = [(rootID, level)]
                var expanded = Set<Int>()
                while !pending.isEmpty {
                    guard nodes.count < maxNodes,
                          ProcessInfo.processInfo.systemUptime < deadline else {
                        truncated = true
                        break
                    }
                    let (parentID, depth) = pending.removeFirst()
                    if !expanded.insert(parentID).inserted { continue }
                    let children = childElements(of: elements[parentID])
                    if depth >= maxDepth {
                        if !children.isEmpty { truncated = true }
                        continue
                    }
                    for child in children {
                        guard nodes.count < maxNodes,
                              ProcessInfo.processInfo.systemUptime < deadline else {
                            truncated = true
                            break
                        }
                        if let known = elements.firstIndex(where: { CFEqual($0, child) }) {
                            pending.append((known, depth + 1))
                            continue
                        }
                        AXUIElementSetMessagingTimeout(child, perMessageTimeout)
                        let id = nodes.count
                        let role = sanitizedRole(of: child)
                        elements.append(child)
                        nodes.append(RivePanelNode(id: id, parentID: parentID, role: role,
                                                   frame: frame(of: child),
                                                   anchors: anchors(of: child, role: role)))
                        pending.append((id, depth + 1))
                    }
                    if truncated { break }
                }
                if truncated { break }
            }
        }
        // A delayed AX response can cross an app/window switch. Discard the
        // whole result unless the same Rive PID and focused window still own it.
        guard let finalFrontmost = element(kAXFocusedApplicationAttribute as CFString, from: system),
              elementPID(finalFrontmost) == rivePID,
              let finalWindow = element(kAXFocusedWindowAttribute as CFString, from: app),
              CFEqual(finalWindow, window),
              ProcessInfo.processInfo.systemUptime < deadline else { return nil }
        return RivePanelSnapshot(pid: rivePID, windowKey: UInt64(CFHash(window)),
                                 windowFrame: windowFrame, capturedAt: ProcessInfo.processInfo.systemUptime,
                                 focusedNodeID: focusedID, hitNodeID: hitID,
                                 interactionAt: interactionAt, nodes: nodes, truncated: truncated)
    }

    private func appendPath(to target: AXUIElement?, window: AXUIElement, deadline: TimeInterval,
                            elements: inout [AXUIElement], nodes: inout [RivePanelNode],
                            truncated: inout Bool) -> Int? {
        guard let target else { return nil }
        if let known = elements.firstIndex(where: { CFEqual($0, target) }) { return known }
        var path: [AXUIElement] = []
        var current: AXUIElement? = target
        while let item = current, path.count < maxDepth,
              ProcessInfo.processInfo.systemUptime < deadline {
            if CFEqual(item, window) { break }
            path.append(item)
            current = element(kAXParentAttribute as CFString, from: item)
        }
        guard let current, CFEqual(current, window),
              nodes.count + path.count <= maxNodes,
              ProcessInfo.processInfo.systemUptime < deadline else {
            truncated = true
            return nil
        }
        var parentID = elements.firstIndex(where: { CFEqual($0, window) })
        for item in path.reversed() {
            if let known = elements.firstIndex(where: { CFEqual($0, item) }) {
                parentID = known
                continue
            }
            AXUIElementSetMessagingTimeout(item, perMessageTimeout)
            let id = nodes.count
            let role = sanitizedRole(of: item)
            elements.append(item)
            nodes.append(RivePanelNode(id: id, parentID: parentID, role: role,
                                       frame: frame(of: item), anchors: anchors(of: item, role: role)))
            parentID = id
        }
        return parentID
    }

    private func belongs(_ item: AXUIElement, to window: AXUIElement,
                         deadline: TimeInterval) -> Bool {
        if let owner = element(kAXWindowAttribute as CFString, from: item) {
            return CFEqual(owner, window)
        }
        var current: AXUIElement? = item
        for _ in 0...maxDepth {
            guard let next = current, ProcessInfo.processInfo.systemUptime < deadline else { return false }
            if CFEqual(next, window) { return true }
            current = element(kAXParentAttribute as CFString, from: next)
        }
        return false
    }

    private func element(_ name: CFString, from owner: AXUIElement) -> AXUIElement? {
        var raw: CFTypeRef?
        guard prepare(owner), AXUIElementCopyAttributeValue(owner, name, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return (raw as! AXUIElement)
    }

    private func elementPID(_ item: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        return AXUIElementGetPid(item, &pid) == .success ? pid : nil
    }

    private func childElements(of item: AXUIElement) -> [AXUIElement] {
        var raw: CFTypeRef?
        guard prepare(item), AXUIElementCopyAttributeValue(item, kAXChildrenAttribute as CFString, &raw) == .success,
              let children = raw as? [AXUIElement] else { return [] }
        return children
    }

    private func sanitizedRole(of item: AXUIElement) -> RiveAXRole {
        if string(kAXSubroleAttribute as CFString, from: item) == "AXSecureTextField" {
            return .secureText
        }
        switch string(kAXRoleAttribute as CFString, from: item) {
        case "AXGroup": return .group
        case "AXStaticText": return .staticText
        case "AXButton": return .button
        case "AXOutline": return .outline
        case "AXList": return .list
        case "AXTable": return .table
        case "AXTextField": return .textField
        case "AXTextArea": return .textArea
        case "AXMenu": return .menu
        case "AXPopover": return .popover
        case "AXDialog": return .dialog
        case "AXSheet": return .sheet
        default: return .other
        }
    }

    private func anchors(of item: AXUIElement, role: RiveAXRole) -> Set<RiveChromeAnchor> {
        // AXValue is read only for static text. Never inspect editable values.
        guard role == .group || role == .staticText || role == .button else { return [] }
        var found = Set<RiveChromeAnchor>()
        for name in [kAXTitleAttribute, kAXDescriptionAttribute] {
            if let raw = string(name as CFString, from: item) {
                found.formUnion(RiveChromeAnchor.recognizeLines(raw, role: role))
            }
        }
        if role == .staticText,
           let raw = string(kAXValueAttribute as CFString, from: item) {
            found.formUnion(RiveChromeAnchor.recognizeLines(raw, role: role))
        }
        return found
    }

    private func string(_ name: CFString, from item: AXUIElement) -> String? {
        var raw: CFTypeRef?
        guard prepare(item), AXUIElementCopyAttributeValue(item, name, &raw) == .success,
              let raw, CFGetTypeID(raw) == CFStringGetTypeID() else { return nil }
        return raw as? String
    }

    private func frame(of item: AXUIElement) -> CGRect? {
        var rawPosition: CFTypeRef?
        var rawSize: CFTypeRef?
        guard prepare(item), AXUIElementCopyAttributeValue(item, kAXPositionAttribute as CFString,
                                            &rawPosition) == .success,
              prepare(item), AXUIElementCopyAttributeValue(item, kAXSizeAttribute as CFString,
                                            &rawSize) == .success,
              let rawPosition, let rawSize,
              CFGetTypeID(rawPosition) == AXValueGetTypeID(),
              CFGetTypeID(rawSize) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(rawPosition as! AXValue, .cgPoint, &origin),
              AXValueGetValue(rawSize as! AXValue, .cgSize, &size),
              origin.x.isFinite, origin.y.isFinite,
              size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else { return nil }
        return CGRect(origin: origin, size: size)
    }

    private func prepare(_ item: AXUIElement) -> Bool {
        let remaining = activeDeadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { return false }
        AXUIElementSetMessagingTimeout(item, Float(min(Double(perMessageTimeout), remaining)))
        return true
    }
}
