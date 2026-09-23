import Foundation

@main
struct RiveAreaSelectionTests {
    static let window = CGRect(x: 0, y: 30, width: 1000, height: 800)
    static func node(_ id: Int, _ parent: Int?, _ role: RiveAXRole, _ frame: CGRect,
                     _ anchors: Set<RiveChromeAnchor> = []) -> RivePanelNode {
        RivePanelNode(id: id, parentID: parent, role: role, frame: frame, anchors: anchors)
    }
    static func sample(click: CGPoint? = nil, key: UInt64 = 10,
                       field: CGRect = CGRect(x: 820, y: 200, width: 150, height: 25),
                       numeric: Bool = true, movedLayout: Bool = false, pid: Int32 = 55) -> RivePanelSnapshot {
        var s = RivePanelSnapshot(pid: pid, windowKey: 99, windowFrame: window,
            capturedAt: 10, focusedNodeID: 1, hitNodeID: click == nil ? nil : 0,
            interactionAt: click == nil ? nil : 9.9, nodes: [
                node(0, nil, .other, window),
                node(1, 0, .textField, field),
                node(2, 0, .group, window),
                node(3, 2, .group, CGRect(x: 200, y: movedLayout ? 110 : 100, width: 600, height: 25), [.stage, .zoomReadout]),
                node(4, 2, .group, CGRect(x: 200, y: 790, width: 600, height: 25), [.console, .problems]),
                node(5, 2, .textField, CGRect(x: 850, y: 150, width: 40, height: 20))
            ], truncated: false)
        s.interactionPoint = click
        s.focusedElementKey = key
        s.editableTextFocused = true
        s.numericTextFocused = numeric
        return s
    }
    static func check(_ condition: Bool, _ message: String) {
        if !condition { fatalError(message) }
    }
    static func main() {
        var state = RiveAreaSelection()
        let canvas = CGPoint(x: 400, y: 400)
        check(state.select(sample(click: canvas), expectedPID: 55, now: 10.1).area == .canvas,
              "fresh canvas click releases a stale native editor")
        check(state.select(sample(), expectedPID: 55, now: 10.1).area == .canvas,
              "same stale editor cannot bounce a canvas route back to numeric on the next poll")
        check(state.select(sample(numeric: false), expectedPID: 55, now: 10.1).area == nil,
              "same editor becoming nonnumeric blocks a previously latched canvas route")
        _ = state.select(sample(click: canvas), expectedPID: 55, now: 10.1)
        check(state.select(sample(pid: 56), expectedPID: 56, now: 10.1).area == .numeric,
              "new process cannot inherit a stale editor suppression or canvas anchor")
        _ = state.select(sample(click: canvas), expectedPID: 55, now: 10.1)
        check(state.select(sample(key: 11), expectedPID: 55, now: 10.1).area == .numeric,
              "a newly focused editor wins over an older canvas click")
        _ = state.select(sample(click: canvas), expectedPID: 55, now: 10.1)
        check(state.select(sample(field: CGRect(x: 850, y: 260, width: 40, height: 20)), expectedPID: 55, now: 10.1).area == .numeric,
              "new field geometry wins even if Flutter reuses its native editor identity")
        _ = state.select(sample(click: canvas), expectedPID: 55, now: 10.1)
        state.reset()
        check(state.select(sample(), expectedPID: 55, now: 10.1).area == .numeric,
              "physical or focus notification resets the stale editor exception")
        _ = state.select(sample(click: canvas), expectedPID: 55, now: 10.1)
        check(state.select(sample(movedLayout: true), expectedPID: 55, now: 10.1).area == nil,
              "layout change requires new area selection")
        check(state.select(sample(click: CGPoint(x: 860, y: 160)), expectedPID: 55, now: 10.1).area == .numeric,
              "semantic field click works despite detached native editor bounds")
        check(state.select(sample(click: CGPoint(x: 100, y: 400)), expectedPID: 55, now: 10.1).area == nil,
              "unrecognized area cannot retain numeric or canvas routing")
        check(state.select(sample(numeric: false), expectedPID: 55, now: 10.1).area == nil,
              "nonnumeric editing does not emit area shortcuts")
        _ = state.select(sample(click: canvas), expectedPID: 55, now: 10.1)
        check(state.select(sample(), expectedPID: 56, now: 10.1).area == nil &&
              state.select(sample(), expectedPID: 55, now: 12).area == nil,
              "mismatched process and stale snapshots revoke routes")
        print("RiveAreaSelectionTests passed")
    }
}
