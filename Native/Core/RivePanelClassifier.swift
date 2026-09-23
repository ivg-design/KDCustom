import CoreGraphics
import Foundation

/// A candidate for editor chrome only. Numeric editing remains owned by the
/// focused-input worker; no result here authorizes a numeric write.
enum RivePanelKind: String, Hashable, Sendable {
    case hierarchy, timeline, inspector, canvas
}

enum RiveAXRole: Equatable, Sendable {
    case group, staticText, button, outline, list, table, textField, textArea
    case menu, popover, dialog, sheet, secureText, other
}

/// Only exact built-in chrome terms survive collection. Never retain a raw AX
/// label, text value, file name, object name, or document value in a snapshot.
enum RiveChromeAnchor: String, Hashable, Sendable {
    case hierarchy, timeline, animations, current, duration, snapKeys, playbackSpeed
    case stage, zoomReadout
    case designBackground, animateBackground, defaultInterpolation, scripting
    case computedTransform, constraints, drawOrder, blend

    static func recognizeLines(_ raw: String, role: RiveAXRole) -> Set<RiveChromeAnchor> {
        Set(raw.components(separatedBy: .newlines).compactMap { line in
            let normalized = line.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: ":"))
                .lowercased()
            if role == .staticText, normalized.count <= 8, normalized.hasSuffix("%"),
               let number = Double(normalized.dropLast()), number.isFinite,
               (1...3200).contains(number) {
                return .zoomReadout
            }
            return recognizeLine(normalized)
        })
    }

    private static func recognizeLine(_ normalized: String) -> RiveChromeAnchor? {
        switch normalized {
        case "hierarchy": return .hierarchy
        case "timeline": return .timeline
        case "animations": return .animations
        case "current": return .current
        case "duration": return .duration
        case "snap keys": return .snapKeys
        case "playback speed": return .playbackSpeed
        case "stage": return .stage
        case "design background": return .designBackground
        case "animate background": return .animateBackground
        case "default interpolation": return .defaultInterpolation
        case "scripting": return .scripting
        case "computed transform": return .computedTransform
        case "constraints": return .constraints
        case "draw order": return .drawOrder
        case "blend": return .blend
        default: return nil
        }
    }

    var panel: RivePanelKind {
        switch self {
        case .hierarchy: return .hierarchy
        case .timeline, .animations, .current, .duration, .snapKeys, .playbackSpeed: return .timeline
        case .stage, .zoomReadout: return .canvas
        case .designBackground, .animateBackground, .defaultInterpolation, .scripting,
             .computedTransform, .constraints, .drawOrder, .blend: return .inspector
        }
    }
}

struct RivePanelNode: Sendable {
    let id: Int
    let parentID: Int?
    let role: RiveAXRole
    let frame: CGRect?
    let anchors: Set<RiveChromeAnchor>
}

/// Window key is an ephemeral AX-element hash, useful only with a fresh probe.
/// A caller must additionally invalidate on foreground/window changes.
struct RivePanelSnapshot: Sendable {
    let pid: Int32
    let windowKey: UInt64
    let windowFrame: CGRect?
    let capturedAt: TimeInterval
    let focusedNodeID: Int?
    let hitNodeID: Int?
    let interactionAt: TimeInterval?
    let nodes: [RivePanelNode]
    let truncated: Bool
}

enum RivePanelConfidence: Equatable, Sendable {
    case none, focus, corroborated
}

enum RivePanelReason: Equatable, Sendable {
    case matchedFocus, matchedFocusAndClick, ambiguous, stale, scopeMismatch, shallowTree
}

struct RivePanelDecision: Sendable {
    let focusedPanel: RivePanelKind?
    let lastInteractedPanel: RivePanelKind?
    /// Only this field is eligible for future automatic dial routing.
    let automaticPanel: RivePanelKind?
    let confidence: RivePanelConfidence
    let reason: RivePanelReason
}

enum RivePanelClassifier {
    static let snapshotLifetime: TimeInterval = 0.5
    static let interactionLifetime: TimeInterval = 0.75

    static func classify(_ snapshot: RivePanelSnapshot, expectedPID: Int32,
                         expectedWindowKey: UInt64, now: TimeInterval) -> RivePanelDecision {
        guard snapshot.pid == expectedPID, snapshot.windowKey == expectedWindowKey,
              snapshot.pid > 0, snapshot.windowKey != 0 else {
            return decision(reason: .scopeMismatch)
        }
        guard now >= snapshot.capturedAt, now - snapshot.capturedAt <= snapshotLifetime else {
            return decision(reason: .stale)
        }
        guard !snapshot.truncated, let window = snapshot.windowFrame,
              valid(window), !snapshot.nodes.isEmpty else {
            return decision(reason: .shallowTree)
        }
        let focused = panel(at: snapshot.focusedNodeID, in: snapshot, window: window)
        let interacted: RivePanelKind?
        if let at = snapshot.interactionAt, now >= at,
           now - at <= interactionLifetime {
            interacted = panel(at: snapshot.hitNodeID, in: snapshot, window: window)
        } else {
            interacted = nil
        }

        if let focused, let interacted {
            guard focused == interacted else {
                return RivePanelDecision(focusedPanel: focused, lastInteractedPanel: interacted,
                                         automaticPanel: nil, confidence: .none, reason: .ambiguous)
            }
            return RivePanelDecision(focusedPanel: focused, lastInteractedPanel: interacted,
                                     automaticPanel: focused, confidence: .corroborated,
                                     reason: .matchedFocusAndClick)
        }
        if let focused, snapshot.interactionAt == nil {
            return RivePanelDecision(focusedPanel: focused, lastInteractedPanel: nil,
                                     automaticPanel: focused, confidence: .focus, reason: .matchedFocus)
        }
        // A recent click can disagree with stale AX focus. Expose it for
        // diagnostics but do not turn it into an automatic keyboard route.
        return RivePanelDecision(focusedPanel: focused, lastInteractedPanel: interacted,
                                 automaticPanel: nil, confidence: .none, reason: .ambiguous)
    }

    private static func decision(reason: RivePanelReason) -> RivePanelDecision {
        RivePanelDecision(focusedPanel: nil, lastInteractedPanel: nil,
                          automaticPanel: nil, confidence: .none, reason: reason)
    }

    private static func panel(at nodeID: Int?, in snapshot: RivePanelSnapshot,
                              window: CGRect) -> RivePanelKind? {
        guard let nodeID, let target = snapshot.nodes.first(where: { $0.id == nodeID }),
              let targetFrame = target.frame, valid(targetFrame), window.contains(targetFrame) else {
            return nil
        }
        let byID = Dictionary(uniqueKeysWithValues: snapshot.nodes.map { ($0.id, $0) })
        var candidates: [(panel: RivePanelKind, area: CGFloat)] = []
        var ancestor: RivePanelNode? = target
        var seen = Set<Int>()
        while let node = ancestor, seen.insert(node.id).inserted {
            if node.role == .menu || node.role == .popover || node.role == .dialog ||
               node.role == .sheet || node.role == .secureText { return nil }
            if node.role == .group, let frame = node.frame, valid(frame),
               window.contains(frame), frame.contains(targetFrame),
               frame.width * frame.height <= window.width * window.height * 0.65,
               frame.width * frame.height >= window.width * window.height * 0.01,
               let panel = uniquePanel(in: node.id, nodes: snapshot.nodes) {
                candidates.append((panel, frame.width * frame.height))
            }
            ancestor = node.parentID.flatMap { byID[$0] }
        }
        guard let smallest = candidates.min(by: { $0.area < $1.area }) else { return nil }
        return smallest.panel
    }

    private static func uniquePanel(in root: Int, nodes: [RivePanelNode]) -> RivePanelKind? {
        let byID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        func isDescendant(_ id: Int) -> Bool {
            var current: Int? = id
            var seen = Set<Int>()
            while let next = current, seen.insert(next).inserted {
                if next == root { return true }
                current = byID[next]?.parentID
            }
            return false
        }
        let descendants = nodes.filter { isDescendant($0.id) }
        let anchors = Set(descendants.flatMap(\.anchors))
        let panels = Set(anchors.map(\.panel))
        guard panels.count == 1, let panel = panels.first else { return nil }
        switch panel {
        case .hierarchy:
            guard descendants.contains(where: {
                $0.anchors.contains(.hierarchy) && $0.role == .button
            }), descendants.contains(where: {
                $0.role == .outline || $0.role == .list || $0.role == .table
            }) else { return nil }
        case .timeline:
            guard anchors.contains(.timeline),
                  !anchors.intersection([.current, .duration, .snapKeys, .playbackSpeed]).isEmpty else { return nil }
        case .inspector:
            guard anchors.count >= 2 else { return nil }
        case .canvas:
            guard anchors.contains(.stage),
                  anchors.contains(.zoomReadout) else { return nil }
        }
        return panel
    }

    private static func valid(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite && rect.width.isFinite && rect.height.isFinite &&
            rect.width > 0 && rect.height > 0
    }
}
