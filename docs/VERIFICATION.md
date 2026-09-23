# Verification status

Development checkpoint: 2026-09-23, KDCustom 0.5.0 (installed build 18). Final packaging and isolated numeric validation completed after unlock. The native controller is implemented and being exercised on one Apple Silicon Mac with one K40. This is not a claim of full firmware parity or a published release.

## Morning dial regression and correction

The first live Rive dial test exposed a production-only key-state bug: the platform adapter treated its own injected HID downs as physical holds, skipped the corresponding ups, then blocked further Smart shortcuts. The older private-process diagnostic did not exercise this path.

Build 16 uses marker-filtered input edges for physical keyboard and mouse ownership. On the installed signed/notarized app, all seven production HID checks passed: balanced Command+Up, held Command+Down with idle release, delayed macro, cancellation, repeated plain arrows, repeated Smart Command+Up, and Smart bracket/modifier variants. Each check also verified that its keys were released in the shared HID state. The user then confirmed that both physical dials work in Rive. All profiles were byte-identical across installation.

Build 18 adds side-specific modifier flags to ordinary and Smart output, and reads physical modifier changes from the incoming event. The user confirmed that the ordinary held Command/Shift dial test now produces fine/coarse changes in Rive. The test held Command on the inner dial and Shift on the outer dial across detents, releasing after 500 ms idle. Exact numeric increments were not recorded.

The four saved Smart/brush bindings were restored after that test. The first Smart retest was only partially successful. Runtime evidence showed that clockwise Option had no matching rule; its saved fine selector was Command, and both its fine/coarse outputs were plain arrows. Those two clockwise rules were corrected through MCP while preserving the user's chosen direction and all other mappings. After correction, the user confirmed that normal, Option/fine and Shift/coarse output works in both directions. Runtime records independently show Option selecting Command+Up and Command+Down; exact numeric increment sizes were not measured. The seven-case HID diagnostic passed in build 16; build 18's additional side-bit assertions have not yet been rerun live.

## Observed in the installed app

- Accessibility, Input Monitoring, Bluetooth, and login-item registration remain available across signed updates.
- USB connects and a software reconnect returns to ready in the production app. The earlier standalone USB/BLE probes captured all eight keys, both group buttons, and both directions of both dials; the user confirmed all eight OLED labels and their physical ordering.
- Foreground Finder activation selects its dedicated profile. Automatic mode restores that profile's selected group, while other applications use the global fallback. Manual lock keeps a chosen profile/group active; editing a profile does not activate it.
- MCP discovery, configuration reads, atomic edits, and stale-revision rejection work through the installed stdio helper and private GUI bridge. Changes appear in the native editor.
- On installed builds 9 and 13, the neutral output window receives balanced Command+Up, repeated Down while Command remains held until idle, a delayed macro after physical release, and cancellation that releases Space and suppresses a queued key. These checks use private-process delivery to the app itself. They do not test Rive or prove every application's handling of synthetic events.
- The shortcut recorder captures Command+Up without an unwanted Fn modifier. New text steps remain editable as local drafts until valid; completed text saves through the shared service.
- Closing and reopening the diagnostic window works. Light and dark settings render. The supplied photo's translucent highlights have a rim-only backing; the source image remains unchanged. Direction icons and physical button outlines were inspected in the installed app. Portrait uses a large device beside the editor; landscape places it above the editor. At 270 degrees, the dials are below the readable OLED, matching the user comparison.
- The reversible Huion handoff was exercised: Return to Huion stopped and paused KDCustom, and launched Huion; Use KDCustom stopped Huion and reconnected USB. The saved Huion configuration hash was unchanged.
- Sleep readback is displayed as 15 minutes on the acceptance device. Huion documents 15/30/60/90-minute options, but timing has not been measured and the fifth firmware value remains unmapped.

## Latest 0.5.0 checks

- All 17 focused suites passed for build 18, including physical input ownership and side-specific modifier encoding. The native build passed warnings as errors and its Developer ID signature verified.
- Installed 0.5.0 retained all three permissions and USB readiness. The observed USB battery reply now displays Full. The original 14 profiles and all user mappings were compared against the pre-update snapshot and preserved; the temporary QA profile was removed.
- Installed MCP discovery returns 19 tools. Complete Smart bindings round-trip through the private bridge; focus-rule atomic batch creation, priority changes and metadata reads work. Codex's global `kdcustom` stdio entry points to the stable installed executable.
- Earlier live UI inspection confirmed sidebar app icons, revised outlines, near-edge OLED status, dial assignment labels and the compact three-step flow. Command+Down appeared directly in the shortcut field; a recorded Command+Z chord stayed visible while recording continued. Focus-rule editing left the stored default group unchanged. Final visual approval remains with the user.
- A new isolated numeric diagnostic initially exposed an own-process AppKit AX threading crash in build 10. Build 11 routes own-process AX access to the main queue and no longer crashed during the retry. The guarded numeric write did not complete while macOS reported a system notification as foreground. Build 12 adds an explicit foreground preflight and restricts the diagnostic to its disposable field identifier. After unlock, installed build 12 passed all four live isolated checks: ten 0.01 increments produce 1.1, a step of 10 produces 11.1, immediate cancellation prevents the write, and expressions remain unchanged. Actual Rive/Adobe field support remains unverified.
- Smart configuration, decimal math, unknown modifier combinations, metadata hints and engine hold ownership have deterministic tests. These do not establish target-app compatibility, physical modifier-selector behavior, or numeric write acceptance in external applications. Smart mode is opt-in; existing user bindings were not converted.

## Local delivery

The previously completed `/Applications/Keydial Studio.app` package was version **0.4.1 (9)** with bundle identity `life.mograph.KeydialStudio`. Its Developer ID signature, stapled ticket, and Gatekeeper acceptance were verified after installation. The separately notarized and stapled installer is `release/Keydial Studio-0.4.1-build9-macOS.dmg` (local, ignored by Git).

SHA-256: `76e46649bdc54a4e61f936cfc86bcd1ea02731adf02e6fe9df3c8757f65b1e0f`.

The existing notarization credential worked after unlock without any credential changes. Build 12 was notarized, stapled, installed, and accepted by Gatekeeper; the separately notarized installer also validated. The user then reported the generic Dock icon. Build 13 explicitly loads the bundled icon at startup and refreshes the installed app registration; a subsequent About-panel correction uses the same runtime icon instead of its separate cached default. The toolbar icon rendered correctly in build 13 and the About icon in build 14. The user confirmed that the Dock now shows the dark dial icon after restart. No global icon caches were deleted or system processes restarted.

The previous icon-acceptance app was **0.5.0 (14)**. Its signature, stapled ticket and Gatekeeper acceptance were verified after a clean quit/install. USB is ready and all three permissions remain allowed. Installed MCP discovery returns 19 tools. The 14-profile configuration is byte-identical to the snapshot immediately before installation, including the user edits made that morning. Runtime inspection observed Rive as foreground and its profile selected automatically without a manual profile lock.

Build 18 is installed after a clean quit, signed, notarized, stapled and accepted by Gatekeeper. Its configuration was byte-identical across installation; subsequent Smart test edits were applied separately through MCP. The redesigned landscape authoring UI and full-width Smart rule rows were inspected live, with group/dial side rails, a smaller device preview, collapsed fallback actions, and distinct inner-disc/outer-rim selection. The portrait layout was also inspected live at 270 degrees and device rotation was restored to 180 degrees. The new wrapping multi-step macro flow still needs its own visual acceptance.

The latest separately notarized and stapled installer currently remains `release/Keydial Studio-0.5.0-build14-macOS.dmg`. SHA-256: `fdda57fa84b5caeec72277e46407192d8183b661ff3210811daa92333dca45b9`.

Eleven overnight snapshots between 03:29 and 08:37 UTC saw the same app process under session lock, with output suspended and the device stopped as intended. These are sampled observations, not continuous hardware acceptance. The Mac was unlocked when checked at 08:53 UTC.

The source repository is public; no binary GitHub release has been published. The package is a tested acceptance build, with the hardware limits below still open.

## Automated coverage

Run `bash scripts/test.sh`. Focused suites cover input decoding, label packet limits, known device commands, profile validation and persistence, modifier and mouse ownership, delayed macros and cancellation, rejected output, configuration revision checks and atomic batches, conservative Huion import, MCP parsing, local bridge behavior, device-controller logic, and shortcut-recording modifier normalization.

These tests use deterministic fixtures and sinks where appropriate. They do not replace a physical key press, Bluetooth disconnect, or OLED comparison. Production builds treat Swift warnings as errors.

## Remaining acceptance and hardware limits

- Production Bluetooth power-cycle and USB/BLE arbitration under repeated unplug/replug, sleep/wake, and rapid application switching need extended device acceptance.
- Physical keyboard and mouse overlap has engine regression coverage, but the assembled controller still needs hands-on overlap testing.
- A complete six-group/profile OLED comparison and portrait/reversed physical slot ordering remain to be checked. The circled group number is firmware-rendered; arbitrary group-name text or graphics are not established capabilities.
- Battery is a vendor display bucket. Charging state and the fifth sleep timeout value are not decoded conclusively. The documented timeout units are minutes; actual timed sleep behavior remains untested.
- Brightness readback timed out twice over BLE; no brightness mutation was attempted. Treat brightness as unsupported until evidence changes.
- Abrupt process termination has no independently verified watchdog guarantee for synthesized holds. Pause, emergency release, normal exit, and observed context boundaries have explicit cleanup.
- Final user visual review, login after an actual logout/reboot, and a hands-on background-control check remain acceptance gates. Target-application Smart numeric acceptance remains open; the isolated AppKit diagnostic is narrower evidence.

## Modifier format investigation

The ordinary aggregate-only Command/Shift test still changed Rive numeric values by 1, independently of Smart routing. Rive's installed package contains Flutter. Flutter's macOS [modifier map](https://github.com/flutter/flutter/blob/master/engine/src/flutter/shell/platform/darwin/macos/framework/Source/KeyCodeMap.g.mm#L217-L235) uses side-specific modifier flags; its [key responder](https://github.com/flutter/flutter/blob/master/engine/src/flutter/shell/platform/darwin/macos/framework/Source/FlutterEmbedderKeyResponder.mm) synchronizes those flags on key events. The previous adapter supplied only the aggregate flags checked by AppKit, explaining why the earlier neutral check was insufficient evidence.

Build 18 adds side-specific flags to ordinary and Smart output, preserves the side of physical modifiers, and verifies side flags in the HID diagnostic. Unit cases cover left/right and combined modifiers and releases. The user confirmed the ordinary held Command/Shift test works in Rive after installing build 18. Exact numeric increments were not recorded. The saved Smart mappings were then restored for a separate physical Option/Shift selector test; its configuration correction and pending retest are recorded above.
