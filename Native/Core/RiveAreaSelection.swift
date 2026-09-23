import CoreGraphics
import Foundation

/// Retains only a verified click surface. Flutter can keep its native editor
/// focused after a canvas click; ignore that same editor until focus or input
/// changes, without letting an older click override a newly focused field.
struct RiveAreaSelection {
    private struct Anchor {
        let pid: Int32
        let point: CGPoint
        let windowKey: UInt64
        let windowFrame: CGRect?
        let layout: RiveAreaLayout
        let suppressedFocusKey: UInt64?
        let suppressedFocusFrame: CGRect?
    }
    private var anchor: Anchor?

    mutating func reset() { anchor = nil }

    mutating func select(_ snapshot: RivePanelSnapshot, expectedPID: Int32,
                         now: TimeInterval) -> (area: InputArea?, status: String) {
        guard RiveAreaLayout.isScopedSnapshot(snapshot, expectedPID: expectedPID, now: now) else {
            anchor = nil
            return (nil, "Rive area unavailable")
        }
        let layout = RiveAreaLayout.resolve(snapshot)
        let focusFrame = snapshot.focusedNodeID.flatMap { id in
            snapshot.nodes.first { $0.id == id }?.frame
        }
        let keepsSuppressedEditor = snapshot.interactionPoint == nil &&
            snapshot.editableTextFocused && snapshot.numericTextFocused &&
            anchor?.pid == expectedPID && anchor?.suppressedFocusKey != nil &&
            anchor?.suppressedFocusKey == snapshot.focusedElementKey &&
            anchor?.suppressedFocusFrame == focusFrame &&
            anchor?.windowKey == snapshot.windowKey &&
            anchor?.windowFrame == snapshot.windowFrame
        if !keepsSuppressedEditor {
            switch RiveAreaLayout.focusedTextArea(in: snapshot, expectedPID: expectedPID, now: now) {
            case .numeric:
                anchor = nil
                return (.numeric, "Numeric field")
            case .textBlocked:
                anchor = nil
                return (nil, "Text field · no area shortcut")
            case .none: break
            }
        }
        guard let layout else { anchor = nil; return (nil, "Rive area unavailable") }
        if let point = snapshot.interactionPoint {
            guard let region = layout.area(at: point), region == .canvas || region == .timeline else {
                anchor = nil
                return (nil, "Select a Rive area")
            }
            anchor = Anchor(pid: expectedPID, point: point, windowKey: snapshot.windowKey,
                windowFrame: snapshot.windowFrame, layout: layout,
                suppressedFocusKey: snapshot.editableTextFocused ? snapshot.focusedElementKey : nil,
                suppressedFocusFrame: snapshot.editableTextFocused ? focusFrame : nil)
        }
        guard let anchor, anchor.pid == expectedPID, anchor.windowKey == snapshot.windowKey,
              anchor.windowFrame == snapshot.windowFrame, anchor.layout == layout else {
            self.anchor = nil
            return (nil, "Select a Rive area")
        }
        let area = layout.area(at: anchor.point)
        return (area, area.map { "\($0.rawValue.capitalized) · last clicked" } ?? "Select a Rive area")
    }
}
