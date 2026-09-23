import Foundation

@main
enum RiveAreaLayoutTests {
    private static let window = CGRect(x: 0, y: 30, width: 2880, height: 1590)

    private static func node(_ id: Int, _ parent: Int?, _ role: RiveAXRole,
                             _ frame: CGRect, _ anchors: Set<RiveChromeAnchor> = []) -> RivePanelNode {
        RivePanelNode(id: id, parentID: parent, role: role, frame: frame, anchors: anchors)
    }

    private static func fixture() -> [RivePanelNode] {
        [
            node(0, nil, .other, window),
            node(9, 0, .group, window, [.hierarchy, .animations]),
            node(17, 9, .group, CGRect(x: 530, y: 114, width: 2072, height: 29)),
            node(23, 17, .staticText, CGRect(x: 540, y: 118, width: 55, height: 20), [.stage]),
            node(24, 17, .staticText, CGRect(x: 2450, y: 118, width: 90, height: 20), [.zoomReadout]),
            node(18, 9, .staticText, CGRect(x: 532, y: 1322, width: 79, height: 25), [.timeReadout]),
            node(19, 9, .group, CGRect(x: 530, y: 1349, width: 340, height: 240)),
            node(27, 19, .staticText, CGRect(x: 540, y: 1355, width: 75, height: 20), [.allKeys]),
            node(20, 9, .group, CGRect(x: 561, y: 1289, width: 2041, height: 29)),
            node(21, 9, .group, CGRect(x: 530, y: 1591, width: 2072, height: 29)),
            node(25, 21, .staticText, CGRect(x: 540, y: 1595, width: 75, height: 20), [.console]),
            node(26, 21, .staticText, CGRect(x: 625, y: 1595, width: 80, height: 20), [.problems]),
            node(22, 9, .group, CGRect(x: 2604, y: 114, width: 276, height: 1506))
        ]
    }

    private static func snapshot(_ nodes: [RivePanelNode], frame: CGRect? = window,
                                 truncated: Bool = false, focus: Int? = 0,
                                 hit: Int? = 0, interactionAt: TimeInterval? = nil) -> RivePanelSnapshot {
        RivePanelSnapshot(pid: 55, windowKey: 99, windowFrame: frame, capturedAt: 10,
                          focusedNodeID: focus, hitNodeID: hit, interactionAt: interactionAt,
                          nodes: nodes, truncated: truncated)
    }

    private static func check(_ condition: Bool, _ message: String) {
        if !condition { fatalError(message) }
    }

    static func main() {
        let nodes = fixture()
        let layout = RiveAreaLayout.resolve(snapshot(nodes))
        check(RiveAreaLayout.isScopedSnapshot(snapshot(nodes), expectedPID: 55,
                                              expectedWindowKey: 99, now: 10.1) &&
              !RiveAreaLayout.isScopedSnapshot(snapshot(nodes), expectedPID: 56, now: 10.1) &&
              !RiveAreaLayout.isScopedSnapshot(snapshot(nodes), expectedPID: 55,
                                               expectedWindowKey: 100, now: 10.1) &&
              !RiveAreaLayout.isScopedSnapshot(snapshot(nodes), expectedPID: 55, now: 11),
              "scope gate requires current PID, window key, and fresh capture")
        check(layout?.canvas == CGRect(x: 530, y: 143, width: 2072, height: 1146) &&
              layout?.timeline == CGRect(x: 530, y: 1289, width: 2072, height: 302) &&
              layout?.lists == [], "live chrome bounds derive canvas and timeline without canvas AX content")
        check(layout?.area(at: CGPoint(x: 835, y: 730)) == .canvas &&
              layout?.area(at: CGPoint(x: 835, y: 1400)) == .timeline &&
              layout?.area(at: CGPoint(x: 835, y: 130)) == nil &&
              layout?.area(at: CGPoint(x: 835, y: 1600)) == nil &&
              layout?.area(at: CGPoint(x: 200, y: 730)) == nil &&
              layout?.area(at: CGPoint(x: 2700, y: 730)) == nil,
              "only derived interior regions classify, excluding toolbar, footer, and sidebars")
        check(layout?.area(at: CGPoint(x: CGFloat.nan, y: 730)) == nil &&
              layout?.area(at: CGPoint(x: 835, y: 730)) != .numeric,
              "invalid points and numeric editing never receive a geometry route")

        // Build29: AX inserts equal-frame groups around the Stage, tab bar,
        // Console, and All Keys list; its focused native field can be detached
        // from the semantic text field under the same inspector.
        var wrapped = nodes.map { item -> RivePanelNode in
            let parents = [23: 30, 24: 30, 25: 31, 26: 31, 27: 33]
            return RivePanelNode(id: item.id, parentID: parents[item.id] ?? item.parentID,
                                 role: item.role, frame: item.frame, anchors: item.anchors)
        }
        wrapped.append(node(30, 17, .group, CGRect(x: 530, y: 114, width: 2072, height: 29)))
        wrapped.append(node(31, 21, .group, CGRect(x: 530, y: 1591, width: 2072, height: 29)))
        wrapped.append(node(32, 20, .group, CGRect(x: 561, y: 1289, width: 2041, height: 29)))
        wrapped.append(node(33, 19, .group, CGRect(x: 530, y: 1349, width: 340, height: 240)))
        wrapped.append(node(34, 0, .textField, CGRect(x: 2605, y: 245, width: 268, height: 33)))
        wrapped.append(node(35, 22, .textField, CGRect(x: 2707, y: 191, width: 39, height: 17)))
        check(RiveAreaLayout.resolve(snapshot(wrapped, focus: 34)) == layout,
              "equal-frame ancestor wrappers collapse to the outer local strip")
        var detachedNumeric = snapshot(wrapped, focus: 34, hit: 0, interactionAt: 10)
        detachedNumeric.editableTextFocused = true
        detachedNumeric.numericTextFocused = true
        detachedNumeric.interactionPoint = CGPoint(x: 2725, y: 192)
        check(RiveAreaLayout.focusedTextArea(in: detachedNumeric, expectedPID: 55,
                                             now: 10.1) == .numeric,
              "a fresh click in a nonsecure semantic field retains numeric native focus")
        let orphanSemantic = wrapped.map { item -> RivePanelNode in
            guard item.id == 35 else { return item }
            return RivePanelNode(id: item.id, parentID: 99, role: item.role,
                                 frame: item.frame, anchors: item.anchors)
        }
        var orphanClick = snapshot(orphanSemantic, focus: 34, hit: 0, interactionAt: 10)
        orphanClick.editableTextFocused = true
        orphanClick.numericTextFocused = true
        orphanClick.interactionPoint = CGPoint(x: 2725, y: 192)
        check(RiveAreaLayout.focusedTextArea(in: orphanClick, expectedPID: 55,
                                             now: 10.1) == .textBlocked,
              "an orphan text node cannot impersonate a semantic field in the focused window")
        detachedNumeric.interactionPoint = CGPoint(x: 835, y: 730)
        check(RiveAreaLayout.focusedTextArea(in: detachedNumeric, expectedPID: 55,
                                             now: 10.1) == .none,
              "only confirmed canvas geometry can override stale numeric focus")
        detachedNumeric.interactionPoint = CGPoint(x: 2700, y: 730)
        check(RiveAreaLayout.focusedTextArea(in: detachedNumeric, expectedPID: 55,
                                             now: 10.1) == .textBlocked,
              "an unknown click blocks both numeric and area output")
        var trulyDuplicate = wrapped
        trulyDuplicate.append(node(36, 9, .group, CGRect(x: 530, y: 114, width: 2072, height: 29),
                                   [.stage, .zoomReadout]))
        check(RiveAreaLayout.resolve(snapshot(trulyDuplicate, focus: 34)) == nil,
              "equal-frame independent Stage candidates remain ambiguous")

        let transform = CGAffineTransform(a: 0.8, b: 0, c: 0, d: 0.8, tx: 100, ty: 60)
        let moved = nodes.map { node(node: $0, frame: $0.frame?.applying(transform)) }
        let movedWindow = window.applying(transform)
        let movedLayout = RiveAreaLayout.resolve(snapshot(moved, frame: movedWindow))
        check(movedLayout?.canvas == layout?.canvas.applying(transform) &&
              movedLayout?.timeline == layout?.timeline?.applying(transform) &&
              movedLayout?.area(at: CGPoint(x: 835, y: 730).applying(transform)) == .canvas,
              "regions follow a moved and resized window rather than screen constants")

        let design = nodes.filter { ![18, 19, 20, 27].contains($0.id) }
        let designLayout = RiveAreaLayout.resolve(snapshot(design))
        check(designLayout?.timeline == nil &&
              designLayout?.canvas == CGRect(x: 530, y: 143, width: 2072, height: 1448) &&
              designLayout?.area(at: CGPoint(x: 835, y: 1400)) == .canvas,
              "Design mode uses Stage and Console chrome without inventing a timeline")
        let missedTimelineTokens = nodes.filter { ![18, 19, 27].contains($0.id) }
        check(RiveAreaLayout.resolve(snapshot(missedTimelineTokens)) == nil,
              "an unlabelled interior timeline strip cannot be misclassified as Design canvas")

        for missing in [24, 25, 26, 18, 20, 27] {
            check(RiveAreaLayout.resolve(snapshot(nodes.filter { $0.id != missing })) == nil,
                  "missing required local chrome or timeline boundary fails closed: \(missing)")
        }
        var duplicatedStage = nodes
        duplicatedStage.append(node(30, 9, .group, CGRect(x: 530, y: 150, width: 2072, height: 29),
                                    [.stage, .zoomReadout]))
        check(RiveAreaLayout.resolve(snapshot(duplicatedStage)) == nil,
              "duplicate Stage strips are ambiguous")
        var duplicatedTime = nodes
        duplicatedTime.append(node(34, 9, .staticText,
                                   CGRect(x: 620, y: 1322, width: 79, height: 25), [.timeReadout]))
        check(RiveAreaLayout.resolve(snapshot(duplicatedTime)) == nil,
              "duplicate time anchors are ambiguous")
        var duplicatedTabs = nodes
        duplicatedTabs.append(node(31, 9, .group, CGRect(x: 550, y: 1288, width: 2052, height: 30)))
        check(RiveAreaLayout.resolve(snapshot(duplicatedTabs)) == nil,
              "overlapping candidate timeline tabs are ambiguous")
        var rootWrapper = nodes
        rootWrapper.append(node(32, 9, .group, CGRect(x: 50, y: 40, width: 2780, height: 1550),
                                [.stage, .zoomReadout, .console, .problems]))
        check(RiveAreaLayout.resolve(snapshot(rootWrapper)) == layout,
              "large mixed Flutter wrappers cannot masquerade as local strips")
        var overlay = nodes
        overlay.append(node(33, 9, .popover, CGRect(x: 900, y: 400, width: 300, height: 200)))
        check(RiveAreaLayout.resolve(snapshot(overlay)) == nil,
              "an overlapping popover prevents a route")
        var pathOverlay = nodes
        pathOverlay.append(node(33, 9, .menu, CGRect(x: 50, y: 300, width: 200, height: 150)))
        check(RiveAreaLayout.resolve(snapshot(pathOverlay, focus: 33)) == nil &&
              RiveAreaLayout.resolve(snapshot(pathOverlay, hit: 33)) == nil &&
              !RiveAreaLayout.isScopedSnapshot(snapshot(pathOverlay), expectedPID: 55, now: 10.1),
              "focused or hit overlay paths block layout even outside the canvas body")
        var securePath = nodes
        securePath.append(node(33, 9, .secureText, CGRect(x: 50, y: 300, width: 200, height: 20)))
        check(RiveAreaLayout.resolve(snapshot(securePath, focus: 33)) == nil,
              "secure text on the focus path blocks layout")
        check(!RiveAreaLayout.isScopedSnapshot(snapshot(nodes, focus: nil), expectedPID: 55, now: 10.1) &&
              !RiveAreaLayout.isScopedSnapshot(snapshot(nodes, focus: 99), expectedPID: 55, now: 10.1) &&
              !RiveAreaLayout.isScopedSnapshot(snapshot(nodes, hit: 99), expectedPID: 55, now: 10.1),
              "missing focus and broken focus or hit ancestry fail closed")
        var textNodes = nodes
        textNodes.append(node(40, 0, .textField, CGRect(x: 2700, y: 400, width: 39, height: 17)))
        var textSnapshot = snapshot(textNodes, focus: 40, hit: 40)
        textSnapshot.editableTextFocused = true
        textSnapshot.numericTextFocused = true
        check(RiveAreaLayout.focusedTextArea(in: textSnapshot, expectedPID: 55,
                                             now: 10.1) == .numeric,
              "fresh numeric focus wins without a fresh outside click")
        textSnapshot.numericTextFocused = false
        check(RiveAreaLayout.focusedTextArea(in: textSnapshot, expectedPID: 55,
                                             now: 10.1) == .textBlocked,
              "nonnumeric editable text blocks area shortcuts")
        textSnapshot.numericTextFocused = true
        var clickedText = snapshot(textNodes, focus: 40, hit: 40, interactionAt: 10)
        clickedText.editableTextFocused = true
        clickedText.numericTextFocused = true
        clickedText.interactionPoint = CGPoint(x: 835, y: 730)
        check(RiveAreaLayout.focusedTextArea(in: clickedText, expectedPID: 55,
                                             now: 10.1) == .none,
              "only a current verified outside click can release stale numeric focus")
        clickedText.interactionPoint = CGPoint(x: 2710, y: 407)
        check(RiveAreaLayout.focusedTextArea(in: clickedText, expectedPID: 55,
                                             now: 10.1) == .numeric,
              "clicking within the numeric field preserves numeric precedence")
        clickedText.interactionPoint = nil
        check(RiveAreaLayout.focusedTextArea(in: clickedText, expectedPID: 55,
                                             now: 10.1) == .none,
              "a partial click sample cannot authorize numeric or area routing")
        var outside = nodes
        outside[2] = node(17, 9, .group, CGRect(x: 530, y: -20, width: 2072, height: 29))
        check(RiveAreaLayout.resolve(snapshot(outside)) == nil &&
              RiveAreaLayout.resolve(snapshot(nodes, truncated: true)) == nil &&
              RiveAreaLayout.resolve(snapshot(nodes, frame: nil)) == nil,
              "malformed, truncated, or missing-window geometry fails closed")
        print("RiveAreaLayoutTests passed")
    }

    private static func node(node existing: RivePanelNode, frame: CGRect?) -> RivePanelNode {
        RivePanelNode(id: existing.id, parentID: existing.parentID, role: existing.role,
                      frame: frame, anchors: existing.anchors)
    }
}
