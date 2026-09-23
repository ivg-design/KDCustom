import CoreGraphics
import Foundation

enum RiveFocusedTextAreaDecision: Equatable, Sendable {
    case numeric, textBlocked, none
}

/// Geometric input regions derived only from local, recognized Rive chrome.
/// This is a candidate for a fresh, scoped snapshot; the caller owns PID,
/// window, age, focused-input, and click/focus agreement checks.
struct RiveAreaLayout: Equatable, Sendable {
    let canvas: CGRect
    let timeline: CGRect?
    let lists: [CGRect]

    /// Reuse this gate before numeric decisions and before geometric routing.
    /// The caller supplies the foreground PID, optional previously verified
    /// focused-window key, and current monotonic uptime.
    static func isScopedSnapshot(_ snapshot: RivePanelSnapshot, expectedPID: Int32,
                                 expectedWindowKey: UInt64? = nil, now: TimeInterval) -> Bool {
        guard expectedPID > 0, snapshot.pid == expectedPID,
              expectedWindowKey.map({ $0 == snapshot.windowKey }) ?? true,
              now.isFinite, snapshot.capturedAt.isFinite,
              now >= snapshot.capturedAt,
              now - snapshot.capturedAt <= RivePanelClassifier.snapshotLifetime else { return false }
        if let interactionAt = snapshot.interactionAt {
            guard interactionAt.isFinite, now >= interactionAt,
                  now - interactionAt <= RivePanelClassifier.interactionLifetime else { return false }
        }
        return structurallyScoped(snapshot)
    }

    /// A verified current click outside a still-focused native Flutter text
    /// field can release stale focus. A stored click anchor cannot do so.
    static func focusedTextArea(in snapshot: RivePanelSnapshot, expectedPID: Int32,
                                expectedWindowKey: UInt64? = nil,
                                now: TimeInterval) -> RiveFocusedTextAreaDecision {
        guard isScopedSnapshot(snapshot, expectedPID: expectedPID,
                               expectedWindowKey: expectedWindowKey, now: now),
              snapshot.editableTextFocused,
              let focusedID = snapshot.focusedNodeID,
              let focused = snapshot.nodes.first(where: { $0.id == focusedID }),
              focused.role == .textField || focused.role == .textArea else { return .none }
        if let point = snapshot.interactionPoint, snapshot.interactionAt != nil {
            if snapshot.numericTextFocused {
                if let frame = focused.frame, valid(frame), frame.contains(point) {
                    return .numeric
                }
                // Flutter's focused native editor may keep stale, broad bounds
                // while its semantic sibling exposes the clicked numeric cell.
                // The value is never inspected on that sibling.
                let byID = Dictionary(uniqueKeysWithValues: snapshot.nodes.map { ($0.id, $0) })
                guard let rootID = snapshot.nodes.first(where: { $0.parentID == nil })?.id else {
                    return .textBlocked
                }
                if snapshot.nodes.contains(where: { node in
                    (node.role == .textField || node.role == .textArea) &&
                    validPath(node.id, rootID: rootID, byID: byID) &&
                    node.frame.map { valid($0) &&
                        snapshot.windowFrame?.contains($0) == true && $0.contains(point) } == true
                }) {
                    return .numeric
                }
                // Only a derived Stage or Timeline body confirms that a click
                // outside the editor should release stale numeric focus.
                guard let layout = resolve(snapshot),
                      let area = layout.area(at: point),
                      area == .canvas || area == .timeline else { return .textBlocked }
                return .none
            }
            return .textBlocked
        }
        return snapshot.numericTextFocused ? .numeric : .textBlocked
    }

    func area(at point: CGPoint) -> InputArea? {
        guard point.x.isFinite, point.y.isFinite else { return nil }
        if let timeline, timeline.contains(point) { return .timeline }
        if canvas.contains(point) { return .canvas }
        if lists.contains(where: { $0.contains(point) }) { return .list }
        return nil
    }

    static func resolve(_ snapshot: RivePanelSnapshot) -> RiveAreaLayout? {
        guard structurallyScoped(snapshot), let window = snapshot.windowFrame else { return nil }
        let byID = Dictionary(uniqueKeysWithValues: snapshot.nodes.map { ($0.id, $0) })

        // Combined, window-sized Flutter groups can contain every panel name.
        // Only narrow sibling strips with both local chrome tokens can bound
        // the otherwise inaccessible canvas surface.
        let stage = single(collapseEqualFrameWrappers(snapshot.nodes.filter {
            strip($0, in: window) &&
            localAnchors(in: $0, nodes: snapshot.nodes, byID: byID)
                .isSuperset(of: [.stage, .zoomReadout])
        }, byID: byID))
        let footer = single(collapseEqualFrameWrappers(snapshot.nodes.filter {
            strip($0, in: window) &&
            localAnchors(in: $0, nodes: snapshot.nodes, byID: byID)
                .isSuperset(of: [.console, .problems])
        }, byID: byID))
        guard let stage, let footer, let parent = stage.parentID,
              footer.parentID == parent, let top = stage.frame, let bottom = footer.frame,
              aligned(top, bottom, window: window),
              top.maxY < bottom.minY,
              bottom.minY - top.maxY > window.height * 0.1 else { return nil }

        let left = max(top.minX, bottom.minX)
        let right = min(top.maxX, bottom.maxX)
        guard right > left else { return nil }
        let band = CGRect(x: left, y: top.maxY, width: right - left,
                          height: bottom.minY - top.maxY)

        let times = snapshot.nodes.filter {
            $0.anchors.contains(.timeReadout) && $0.role == .staticText &&
            $0.parentID == parent &&
            $0.frame.map { valid($0) && band.contains($0) } == true
        }
        let keyLists = snapshot.nodes.filter { node in
            guard node.role == .group, node.parentID == parent,
                  let frame = node.frame, valid(frame), window.contains(frame),
                  frame.minX >= left - window.width * 0.02,
                  frame.minX <= left + window.width * 0.02,
                  frame.minY > top.maxY, frame.maxY <= bottom.minY,
                  frame.width < window.width * 0.35,
                  frame.height < window.height * 0.5 else { return false }
            return localAnchors(in: node, nodes: snapshot.nodes, byID: byID,
                                role: .staticText).contains(.allKeys)
        }
        let interiorStrips = snapshot.nodes.filter { node in
            guard node.id != stage.id, node.id != footer.id,
                  node.parentID == parent, strip(node, in: window),
                  let frame = node.frame,
                  aligned(frame, top, window: window) else { return false }
            return frame.minY > top.maxY && frame.maxY < bottom.minY
        }
        let timeline: CGRect?
        if keyLists.isEmpty && times.isEmpty {
            // An unlabelled broad strip can be a timeline header whose child
            // tokens were missed. It cannot be absorbed into Design canvas.
            guard interiorStrips.isEmpty else { return nil }
            timeline = nil // Design mode, with no timeline chrome.
        } else {
            guard let keyList = single(keyLists), let time = single(times),
                  let listFrame = keyList.frame, let timeFrame = time.frame,
                  timeFrame.minX >= left, timeFrame.maxX <= right,
                  listFrame.minY >= timeFrame.maxY - window.height * 0.005,
                  listFrame.minY - timeFrame.maxY <= window.height * 0.035,
                  timeFrame.maxY < bottom.minY,
                  let tab = single(interiorStrips.filter { node in
                      guard let frame = node.frame else { return false }
                      return frame.minY > top.maxY && frame.maxY <= timeFrame.minY &&
                          timeFrame.minY - frame.maxY <= window.height * 0.035
                  }), let tabFrame = tab.frame,
                  bottom.minY - tabFrame.minY > window.height * 0.05 else { return nil }
            timeline = CGRect(x: left, y: tabFrame.minY, width: right - left,
                              height: bottom.minY - tabFrame.minY)
        }

        let canvasBottom = timeline?.minY ?? bottom.minY
        guard canvasBottom > top.maxY,
              canvasBottom - top.maxY > window.height * 0.05 else { return nil }
        let canvas = CGRect(x: left, y: top.maxY, width: right - left,
                            height: canvasBottom - top.maxY)

        return RiveAreaLayout(canvas: canvas, timeline: timeline, lists: [])
    }

    private static func structurallyScoped(_ snapshot: RivePanelSnapshot) -> Bool {
        guard snapshot.pid > 0, snapshot.windowKey != 0, !snapshot.truncated,
              let window = snapshot.windowFrame, valid(window),
              !snapshot.nodes.isEmpty, snapshot.nodes.count <= 160,
              Set(snapshot.nodes.map(\.id)).count == snapshot.nodes.count,
              let focusID = snapshot.focusedNodeID else { return false }
        let roots = snapshot.nodes.filter { $0.parentID == nil }
        guard roots.count == 1, roots[0].frame == window else { return false }
        let byID = Dictionary(uniqueKeysWithValues: snapshot.nodes.map { ($0.id, $0) })
        guard validPath(focusID, rootID: roots[0].id, byID: byID),
              snapshot.hitNodeID.map({ validPath($0, rootID: roots[0].id, byID: byID) }) ?? true else {
            return false
        }
        if snapshot.interactionPoint != nil || snapshot.interactionAt != nil {
            guard snapshot.interactionPoint != nil, snapshot.interactionAt != nil,
                  snapshot.hitNodeID != nil,
                  let point = snapshot.interactionPoint,
                  point.x.isFinite, point.y.isFinite, window.contains(point) else { return false }
        }
        // AX may report an overlay as a sibling rather than on the focused
        // path. Any observed in-window overlay makes both numeric and area
        // decisions unsafe until a fresh unobscured capture arrives.
        return !snapshot.nodes.contains { node in
            switch node.role {
            case .menu, .popover, .dialog, .sheet:
                return node.frame.map { !valid($0) || $0.intersects(window) } ?? true
            default: return false
            }
        }
    }

    private static func single(_ nodes: [RivePanelNode]) -> RivePanelNode? {
        nodes.count == 1 ? nodes[0] : nil
    }

    private static func collapseEqualFrameWrappers(_ candidates: [RivePanelNode],
                                                    byID: [Int: RivePanelNode]) -> [RivePanelNode] {
        candidates.filter { node in
            !candidates.contains { other in
                guard other.id != node.id, other.frame == node.frame else { return false }
                var parent = node.parentID
                var seen = Set<Int>()
                while let id = parent, seen.insert(id).inserted {
                    if id == other.id { return true }
                    parent = byID[id]?.parentID
                }
                return false
            }
        }
    }

    private static func validPath(_ nodeID: Int, rootID: Int,
                                  byID: [Int: RivePanelNode]) -> Bool {
        var current: Int? = nodeID
        var seen = Set<Int>()
        while let id = current {
            guard seen.insert(id).inserted, let node = byID[id] else { return false }
            switch node.role {
            case .menu, .popover, .dialog, .sheet, .secureText: return false
            default:
                if id == rootID { return node.parentID == nil }
                current = node.parentID
            }
        }
        return false
    }

    private static func localAnchors(in root: RivePanelNode, nodes: [RivePanelNode],
                                     byID: [Int: RivePanelNode],
                                     role: RiveAXRole? = nil) -> Set<RiveChromeAnchor> {
        guard let bounds = root.frame else { return [] }
        return Set(nodes.filter { node in
            if let role, node.role != role { return false }
            guard let frame = node.frame, valid(frame), bounds.contains(frame) else { return false }
            var current: Int? = node.id
            var seen = Set<Int>()
            while let id = current, seen.insert(id).inserted {
                if id == root.id { return true }
                current = byID[id]?.parentID
            }
            return false
        }.flatMap(\.anchors))
    }

    private static func strip(_ node: RivePanelNode, in window: CGRect) -> Bool {
        guard node.role == .group, let frame = node.frame, valid(frame),
              window.contains(frame) else { return false }
        return frame.width >= window.width * 0.25 &&
            frame.width < window.width * 0.9 &&
            frame.height < window.height * 0.08 &&
            frame.width > frame.height * 5
    }

    private static func aligned(_ a: CGRect, _ b: CGRect, window: CGRect) -> Bool {
        let tolerance = window.width * 0.025
        return abs(a.minX - b.minX) <= tolerance &&
            abs(a.maxX - b.maxX) <= tolerance
    }

    private static func valid(_ rect: CGRect) -> Bool {
        rect.minX.isFinite && rect.minY.isFinite && rect.width.isFinite &&
            rect.height.isFinite && rect.width > 0 && rect.height > 0
    }
}
