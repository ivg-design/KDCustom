import Foundation

@main
enum RivePanelClassifierTests {
    private static let window = CGRect(x: 0, y: 0, width: 1000, height: 800)

    private static func node(_ id: Int, _ parent: Int?, _ role: RiveAXRole,
                             _ rect: CGRect?, _ anchors: Set<RiveChromeAnchor> = []) -> RivePanelNode {
        RivePanelNode(id: id, parentID: parent, role: role, frame: rect, anchors: anchors)
    }

    private static func snapshot(_ nodes: [RivePanelNode], focus: Int?, hit: Int? = nil,
                                 at: TimeInterval? = nil, truncated: Bool = false,
                                 frame: CGRect? = window) -> RivePanelSnapshot {
        RivePanelSnapshot(pid: 55, windowKey: 99, windowFrame: frame,
                          capturedAt: 10, focusedNodeID: focus, hitNodeID: hit,
                          interactionAt: at, nodes: nodes, truncated: truncated)
    }

    private static func classify(_ s: RivePanelSnapshot, pid: Int32 = 55,
                                 key: UInt64 = 99, now: TimeInterval = 10.1) -> RivePanelDecision {
        RivePanelClassifier.classify(s, expectedPID: pid, expectedWindowKey: key, now: now)
    }

    private static func check(_ condition: Bool, _ message: String) {
        if !condition { fatalError(message) }
    }

    static func main() {
        let chrome = RiveChromeAnchor.recognizeLines(
            "private filename\nHierarchy\nStage\n100%\nuser object", role: .group)
        check(chrome == [.hierarchy, .stage], "combined group labels retain only exact chrome lines")
        check(RiveChromeAnchor.recognizeLines("100%", role: .staticText) == [.zoomReadout],
              "static zoom readout retains only a token, never its number")
        check(RiveChromeAnchor.recognizeLines("100%", role: .textField).isEmpty &&
              RiveChromeAnchor.recognizeLines("Scene Stage 100%", role: .staticText).isEmpty,
              "editable and mixed user text is never interpreted as zoom chrome")

        let stage = [
            node(0, nil, .other, window),
            node(1, 0, .group, CGRect(x: 200, y: 100, width: 650, height: 500)),
            node(2, 1, .staticText, CGRect(x: 220, y: 110, width: 60, height: 20), [.stage]),
            node(3, 1, .staticText, CGRect(x: 770, y: 110, width: 50, height: 20), [.zoomReadout]),
            node(4, 1, .group, CGRect(x: 240, y: 160, width: 500, height: 400))
        ]
        let stageBoth = classify(snapshot(stage, focus: 4, hit: 4, at: 10))
        check(stageBoth.automaticPanel == .canvas && stageBoth.confidence == .corroborated,
              "stage anchor plus zoom and matching focus/hit identify canvas")
        let stageHitOnly = classify(snapshot(stage, focus: 0, hit: 4, at: 10))
        check(stageHitOnly.lastInteractedPanel == .canvas && stageHitOnly.automaticPanel == nil,
              "click-only canvas evidence is diagnostic, not an automatic route")
        check(classify(snapshot(Array(stage.dropLast()), focus: 1)).automaticPanel == .canvas,
              "a focused bounded Stage container can identify canvas")

        let inspector = [
            node(0, nil, .other, window),
            node(1, 0, .group, CGRect(x: 760, y: 80, width: 230, height: 670)),
            node(2, 1, .group, CGRect(x: 770, y: 180, width: 200, height: 80), [.computedTransform]),
            node(3, 1, .staticText, CGRect(x: 775, y: 300, width: 90, height: 20), [.constraints]),
            node(4, 1, .textField, CGRect(x: 850, y: 360, width: 90, height: 28))
        ]
        check(classify(snapshot(inspector, focus: 4)).automaticPanel == .inspector,
              "local inspector chrome and focused field identify inspector, without field value")

        let hierarchy = [
            node(0, nil, .other, window),
            node(1, 0, .group, CGRect(x: 0, y: 80, width: 230, height: 650)),
            node(2, 1, .button, CGRect(x: 10, y: 90, width: 80, height: 25), [.hierarchy]),
            node(3, 1, .outline, CGRect(x: 10, y: 130, width: 210, height: 580)),
            node(4, 3, .staticText, CGRect(x: 20, y: 150, width: 100, height: 20))
        ]
        check(classify(snapshot(hierarchy, focus: 4)).automaticPanel == .hierarchy,
              "hierarchy needs a chrome button and an outline-like structure")
        var fakeHierarchy = hierarchy
        fakeHierarchy[2] = node(2, 1, .staticText, CGRect(x: 10, y: 90, width: 80, height: 25), [.hierarchy])
        check(classify(snapshot(fakeHierarchy, focus: 4)).automaticPanel == nil,
              "a user text named Hierarchy does not identify a panel")

        let timeline = [
            node(0, nil, .other, window),
            node(1, 0, .group, CGRect(x: 240, y: 600, width: 700, height: 190)),
            node(2, 1, .staticText, CGRect(x: 250, y: 610, width: 70, height: 20), [.timeline]),
            node(3, 1, .staticText, CGRect(x: 800, y: 610, width: 65, height: 20), [.current]),
            node(4, 1, .group, CGRect(x: 260, y: 650, width: 640, height: 130))
        ]
        check(classify(snapshot(timeline, focus: 4)).automaticPanel == .timeline,
              "timeline needs its own title and temporal chrome in a bounded region")

        let rootOnly = [node(0, nil, .group, window, [.hierarchy, .timeline, .stage,
                                                        .computedTransform, .zoomReadout])]
        check(classify(snapshot(rootOnly, focus: 0)).automaticPanel == nil,
              "combined whole-window Flutter label cannot route a panel")
        check(classify(snapshot(stage, focus: 4, hit: 4, at: 10), pid: 56).reason == .scopeMismatch &&
              classify(snapshot(stage, focus: 4), key: 100).reason == .scopeMismatch,
              "PID and focused-window identity must match")
        check(classify(snapshot(stage, focus: 4), now: 11).reason == .stale,
              "expired probe cannot route")
        check(classify(snapshot(stage, focus: 4, truncated: true)).automaticPanel == nil &&
              classify(snapshot(stage, focus: 4, frame: nil)).automaticPanel == nil,
              "truncated or geometry-free trees fail closed")

        let mixed = stage + [
            node(5, 0, .group, CGRect(x: 0, y: 0, width: 190, height: 500)),
            node(6, 5, .staticText, CGRect(x: 10, y: 10, width: 100, height: 20), [.computedTransform]),
            node(7, 5, .staticText, CGRect(x: 10, y: 40, width: 100, height: 20), [.constraints]),
            node(8, 5, .textField, CGRect(x: 20, y: 80, width: 100, height: 25))
        ]
        let conflict = classify(snapshot(mixed, focus: 8, hit: 4, at: 10))
        check(conflict.focusedPanel == .inspector && conflict.lastInteractedPanel == .canvas &&
              conflict.automaticPanel == nil, "stale focus and new click cannot force a route")
        var overlay = stage
        overlay.append(node(5, 1, .popover, CGRect(x: 300, y: 200, width: 200, height: 180)))
        overlay.append(node(6, 5, .button, CGRect(x: 320, y: 220, width: 80, height: 30)))
        check(classify(snapshot(overlay, focus: 6, hit: 6, at: 10)).automaticPanel == nil,
              "popover over canvas cannot inherit the canvas route")
        var badGeometry = stage
        badGeometry[1] = node(1, 0, .group, CGRect(x: -100, y: 100, width: 650, height: 500))
        check(classify(snapshot(badGeometry, focus: 4)).automaticPanel == nil,
              "panel geometry outside focused window is rejected")
        var conflictingChrome = stage
        conflictingChrome.append(node(5, 1, .staticText,
                                      CGRect(x: 300, y: 110, width: 80, height: 20), [.timeline]))
        check(classify(snapshot(conflictingChrome, focus: 4)).automaticPanel == nil,
              "one container with anchors from multiple panels is ambiguous")
        check(classify(snapshot(stage, focus: 4, hit: 4, at: 8)).automaticPanel == nil,
              "expired pointer evidence cannot silently fall back to old focus")
        print("RivePanelClassifierTests passed")
    }
}
