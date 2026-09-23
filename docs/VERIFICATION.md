# Verification status

Development checkpoint: 2026-09-22, KDCustom 0.4.1 (build 9). The native controller is implemented and being exercised on one Apple Silicon Mac with one K40. This is not a claim of full firmware parity or a published release.

## Observed in the installed app

- Accessibility, Input Monitoring, Bluetooth, and login-item registration remain available across signed updates.
- USB connects and a software reconnect returns to ready in the production app. The earlier standalone USB/BLE probes captured all eight keys, both group buttons, and both directions of both dials; the user confirmed all eight OLED labels and their physical ordering.
- Foreground Finder activation selects its dedicated profile. Automatic mode restores that profile's selected group, while other applications use the global fallback. Manual lock keeps a chosen profile/group active; editing a profile does not activate it.
- MCP discovery, configuration reads, atomic edits, and stale-revision rejection work through the installed stdio helper and private GUI bridge. Changes appear in the native editor.
- On installed build 9, the neutral output window receives balanced Command+Up, repeated Down while Command remains held until idle, a delayed macro after physical release, and cancellation that releases Space and suppresses a queued key. These checks use private-process delivery to the app itself. They do not test Rive or prove every application's handling of synthetic events.
- The shortcut recorder captures Command+Up without an unwanted Fn modifier. New text steps remain editable as local drafts until valid; completed text saves through the shared service.
- Closing and reopening the diagnostic window works. Light and dark settings render. The supplied photo's translucent highlights have a rim-only backing; the source image remains unchanged. Direction icons and physical button outlines were inspected in the installed app. Portrait uses a large device beside the editor; landscape places it above the editor. At 270 degrees, the dials are below the readable OLED, matching the user comparison.
- The reversible Huion handoff was exercised: Return to Huion stopped and paused KDCustom, and launched Huion; Use KDCustom stopped Huion and reconnected USB. The saved Huion configuration hash was unchanged.
- Sleep readback is displayed as 15 minutes on the acceptance device. Huion documents 15/30/60/90-minute options, but timing has not been measured and the fifth firmware value remains unmapped.

## Local delivery

The installed `/Applications/Keydial Studio.app` is version **0.4.1 (9)** with bundle identity `life.mograph.KeydialStudio`. Its Developer ID signature, stapled ticket, and Gatekeeper acceptance were verified after installation. The separately notarized and stapled installer is `release/Keydial Studio-0.4.1-build9-macOS.dmg` (local, ignored by Git).

SHA-256: `76e46649bdc54a4e61f936cfc86bcd1ea02731adf02e6fe9df3c8757f65b1e0f`.

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
- Final user visual review, login after an actual logout/reboot, and a hands-on background-control check remain acceptance gates. Packaging is complete.
