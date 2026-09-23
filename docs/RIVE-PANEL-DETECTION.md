# Rive active-area dial routing

## Status

Automatic routing is implemented behind optional area rules, but **end-to-end Rive acceptance is pending**. No migration enables these rules. The tested Rive profile retains its working native numeric shortcuts; typed numeric auto-apply remains disabled by user decision.

The live build28 capture reached Rive's panel siblings behind six full-window Flutter wrappers. A blank canvas click still returned the full window as its accessibility hit target. Build29 collected the local Stage, timeline and Console chrome. That capture exposed identical nested wrappers around headers and a native text editor whose frame differed from the clicked semantic numeric field. Build30 handles both cases. Replaying the saved sanitized geometry resolves canvas and timeline bounds and recognizes the numeric click; this replay normalizes timestamps and is **not** a fresh live interaction test.

## Requested behavior

| Area | Dial preset | Validation |
| --- | --- | --- |
| Canvas | Zoom in/out | Preset prepared; live routing pending |
| Timeline | Previous/next frame; Shift for ten frames | Preset prepared; live routing pending |
| Numeric field | Native arrows: ±1, Command ±0.1, Shift ±10 | Shortcuts previously confirmed by user; area switching pending |
| Hierarchy/property lists | Scroll | Secondary; not implemented |
| Numeric label under pointer | Emulate drag scrubbing | Optional; not implemented |

Both dials and both directions are independently configurable. Area rules borrow only the target group's four dial bindings. The selected group, its screen labels, and physical button assignments stay unchanged.

Rive documents `+`/`-` for stage zoom and `,`/`.` for single-frame playhead steps, with Shift for ten frames. Option with timeline punctuation moves selected keys; Command skips between keys. The prepared timeline preset uses exact-modifier Smart shortcuts and leaves unsupported modifier combinations inert, preventing physical modifiers from silently changing the command. These mappings still require target-app acceptance. See [Rive keyboard shortcuts](https://rive.app/docs/editor/keyboard-shortcuts) and [timeline](https://rive.app/docs/editor/animate-mode/timeline).

## Detection

`RivePanelProbe` samples the already-frontmost Rive process on a serial background queue. It verifies process/window scope before and after reading, follows only window-sized wrappers during initial discovery, then samples selected local chrome. Bounds remain 160 nodes, 48 discovery nodes, wrapper depth 12, absolute depth 18 and 400 ms overall; timeout, truncation and incomplete ancestry invalidate a route.

Only allowlisted built-in chrome tokens, roles and geometry survive the collector. Combined root labels cannot identify a pane by themselves. `RiveAreaLayout` requires local Stage plus zoom, Console plus Problems, and—when present—a time readout, All Keys list and nearby timeline tab strip. It collapses ancestor/descendant wrappers with identical frames but rejects independent duplicates. Missing temporal tokens with a remaining broad interior strip are ambiguous; the strip is not treated as canvas.

The blank canvas has no separate accessible object, so `RiveAreaSelection` uses the most recent verified physical click inside these freshly derived regions. It rechecks layout/window identity on later samples. A fresh numeric focus outranks an older click. When a verified canvas/timeline click leaves the same native text editor reported as focused, only that editor identity/frame is suppressed. Physical input, focus/window notifications, profile/session changes or changed layout revoke this state. AX element-key stability and the transition timing still need live validation.

A numeric field can be a detached native Flutter editor or a semantic text field with different bounds. With opt-in area observation, the worker checks whether focused nonsecure text parses as a number and retains only a boolean. A fresh click on a same-window semantic text field can corroborate numeric focus despite differing native-editor geometry. Nonnumeric text, menus, sheets, dialogs, secure input and unrecognized clicks block area shortcuts. New focused fields are not inferred from panel position alone.

`RiveInputAreaObserver` runs only for an exact Rive profile with enabled area rules and normal output permissions. Current results expire; app/window/input boundaries revoke them. It defers polling during an in-flight typed numeric transaction so that operation's temporary focus cannot cancel itself. This does not enable typed numeric output in the Rive profile.

`FocusRule.area` is optional and shares UI/MCP validation. All supplied area/kind/role/identifier/label conditions must match, in first-match order. When Rive area rules are enabled, an unmatched dial pauses instead of emitting default arrow keys into an unknown surface. A separately matching ordinary focus rule remains eligible. Existing profiles without area rules keep their behavior.

## Diagnostic and privacy

The Intelligent dials sheet or `kdcustom_get_focused_input` with `panelCapture: "start"` arms a five-minute read-only diagnostic. It samples after Rive activation or physical clicks; `panelCapture: "stop"` ends it early. Results include a bounded event history and the last ten sanitized structural captures. They are historical evidence, never an instruction to execute a shortcut.

No raw field value, user object/document name, selected text or screenshot is returned, logged or persisted. Field contents used for the numeric boolean are discarded in the AX worker. External keyboard observations retain only navigation-key codes, not typed characters. Raw local evidence remains ignored by Git.

A separate daemon would use the same macOS accessibility and event APIs without gaining Rive-internal state. The classifier therefore stays inside the existing controller and its permission/lifecycle boundaries. Apple documents [AX attributes](https://developer.apple.com/documentation/applicationservices/carbon_accessibility/attributes), [hit testing](https://developer.apple.com/documentation/applicationservices/1462077-axuielementcopyelementatposition) and [notifications](https://developer.apple.com/documentation/applicationservices/axnotificationconstants_h). Flutter's upstream implementation is a useful reference, but is not proof of the exact Rive-bundled version.

The observed Rive MCP surface exposes file and scene-selection state, not a verified active-panel feed. A selected object or active file is different from the panel receiving input. No private Rive API or undocumented accessibility setting is used. See [Rive MCP](https://rive.app/docs/editor/ai/mcp).

## Remaining acceptance

Fixtures cover the observed header wrappers and detached-editor geometry, stale/mismatched scopes, ambiguous chrome, overlays, numeric priority, unchanged stale-editor suppression, nonnumeric editing and layout changes. They do not establish target-app shortcut delivery.

When the user returns, capture canvas → timeline → numeric transitions, then enable the prepared rules for a controlled physical dial check. Verify both directions, supported/unsupported modifiers, leaving a numeric field, resize/mode/window/app changes, and recovery from an unknown region. Fast dial rotation previously caused field focus loss and remains a separate unresolved report; normal physical arrow repeat did not reproduce it. No further typed numeric auto-apply experiments are planned for Rive.
