# KDCustom

KDCustom is an independent native macOS 14+ controller for the Huion Keydial Remote K40. The SwiftUI studio edits application-specific profiles, six groups per profile, eight keys, two group buttons, and both directions of both dials. It supports shortcuts, held keys, bounded macros, mouse/scroll/media actions, and temporary OLED key labels. Closing the studio window leaves the user-session controller running in the menu bar.

The app detects the foreground application's bundle identifier and uses its profile, with a global fallback. A manual profile lock is available in the studio and menu bar. Editing a profile does not activate it. On context changes, pause, disconnect, sleep, or shutdown, the action engine cancels pending work and releases its synthesized holds. The native UI includes an interactive device photo, direction-specific dial selection, a macro editor, light/dark appearance, profile import/export and backup restoration, diagnostics export, and an optional login launch. The supplied device photo is unchanged; the app icon is original vector artwork.

## Build and run

On the acceptance Mac, use the standalone Command Line Tools and a local Developer ID Application signing identity:

```sh
bash scripts/test.sh
bash scripts/build-native.sh --install
open '/Applications/Keydial Studio.app'
```

Omit `--install` to build only `build/Keydial Studio.app`; `--install` copies that signed app to the stable `/Applications/Keydial Studio.app` path. Its bundle identifier is `life.mograph.KeydialStudio`; use that installed copy for macOS permissions, login launch, and the MCP command path. The script's `--setup` option selects the legacy setup/capture entry point. No package dependencies or kernel extension are required. The local app is signed but **not notarized or packaged for distribution**.

Grant Accessibility and Input Monitoring to the installed app before expecting shortcut output. Bluetooth permission is needed for the BLE transport. The app checks these permissions in Settings. To avoid competing device control, it suspends its device connection while Huion is running; Settings offers **Use KDCustom** and **Return to Huion**. Returning pauses KDCustom, stops its device controller, and launches `/Applications/HuionKeyboard.app` if present, without changing Huion's saved configuration. Resume KDCustom explicitly after switching back.

Profiles are stored at `~/Library/Application Support/KeydialStudio/profiles.json` with a previous validated version at `profiles.json.bak`. Importing a KDCustom JSON file replaces the document only after review and schema validation. **Import from Huion** reads a selected `EKeySetting.dt` without writing it. Because Huion configuration indices have not been proven to match physical keys, that flow requires a reviewed eight-key/two-dial mapping and direction choice, shows skipped actions and unresolved applications, and asks for final confirmation before replacing KDCustom profiles.

## Agent configuration

The installed app and its MCP helper use the same in-memory configuration service and revision. Keep the app running, then use **Settings → Copy MCP configuration** or configure the installed executable with `--mcp` as described in [docs/MCP.md](docs/MCP.md). The helper does not claim the device, write profile files independently, or execute shortcuts. It connects to the running app through an owner-only local Unix socket; there is no public network listener.

## Hardware evidence and limits

The earlier standalone USB and BLE tests captured all eight physical keys, both group buttons, and both directions of both dials. Temporary labels for all eight keys were visible on the OLED on both transports. Physical top-row keys 1–4 and bottom-row keys 5–8 map to vendor wire slots `[2, 4, 6, 8, 1, 3, 5, 7]`; firmware dial 1 is inner and dial 2 is outer. Vendor mode uses the observed C9 identity check followed by C8. These results establish input and label feasibility, not acceptance of every assembled-app workflow. See [USB evidence](protocol/standalone-results.md), [BLE evidence](protocol/bluetooth-results.md), [input decoding](protocol/input-decoder.md), and [OLED packets](protocol/K40_LABELS.md).

The physical OLED shows a **circled group number 1–6** and eight key-text slots. Custom group names remain useful inside KDCustom, but display of an arbitrary group name on this firmware has **not** been proven. The UI preview reflows the key slots when rotation changes; it is a preview, not a claim that arbitrary graphics can be written to the OLED.

Battery is shown as the device's decoded display bucket, not a calibrated percentage. Battery and sleep reads and rotation behavior have been physically observed; the sleep values' time units are unconfirmed. Brightness readback (`D9`) timed out twice in live BLE checks, so brightness remains unsupported/unverified and its UI controls are hidden unless valid readback is observed. Charging-state decoding and a full six-group/profile OLED comparison remain open. Automated tests cover parsing, persistence, action scheduling, and transport logic, but production reconnect, power-cycle, sleep/wake, modifier-overlap, and rapid app-switch stress acceptance on the installed app remain to be completed. No unconditional cleanup is promised after an abrupt process kill.

## Standalone probes

The historical capture tool remains available with `bash scripts/build.sh` (`build/K40 Probe.app`). The OLED CLI can be built with `bash scripts/build-screen.sh`. These tools are for directed protocol checks, separate from normal KDCustom operation. Quit Huion before a controlled display test and restore it afterward. The CLI prints packets unless `--send` is specified; `--enter-control-mode` changes device mode:

```sh
build/k40-screen --preflight
build/k40-screen --enter-control-mode
build/k40-screen --button 1 1 POC
```

Raw captures, personal Huion profiles, and local build output are excluded from the public repository. KDCustom is not affiliated with Huion. The [KD100 open-source controller](https://github.com/piotrrojek/keydial-kd100) is prior art for IOKit integration, not evidence that its protocol controls the K40 screen.
