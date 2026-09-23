# KDCustom

A native macOS controller for the Huion Keydial Remote K40, with application
profiles, independent dial mappings, macros, and OLED labels. The replacement
app is in development; the validated hardware proof of concept is included.

The planned native UI and local MCP interface share one validated profile
model, so agents can configure the same mappings available in the app.

## Hardware proof of concept

A small native macOS probe for the Huion Keydial Remote K40 (USB `256c:2002`; Bluetooth Low Energy `256c:8251`).
It tests the two hardware questions that matter for a replacement controller:
can an independent app receive the controls, and can it write the OLED labels?
It does not emit shortcuts or test Rive.

## Result: core USB and Bluetooth control paths are feasible

With both Huion processes stopped, this POC independently captured all eight
buttons, both group buttons, and both directions of both dials. It also wrote
all eight OLED labels (`P1`–`P8`), which the user confirmed on the device.
Huion was then reopened, the normal labels returned, and its saved configuration
remained byte-for-byte unchanged.

With Huion stopped and the USB cable disconnected, the POC also connected to
the K40 vendor Bluetooth service. It captured all eight buttons, both group
buttons, and both directions of both dials. The user confirmed that temporary
`BT1`–`BT8` labels appeared on the OLED. The first Bluetooth write used wire
slot numbers; its labels appeared top row `[2, 4, 6, 8]`, bottom row
`[1, 3, 5, 7]`. The app now uses `K40ButtonLayout` to present physical buttons
in row order (top 1–4, bottom 5–8). The user confirmed this corrected layout,
then confirmed normal labels returned after Huion was reopened. The saved
Huion configuration remained byte-for-byte unchanged after the Bluetooth test.

The missing step was the vendor startup sequence: request C9 to establish the
`HUION_T221_250807` identity, then C8. The same label write had no visible effect
before that sequence. Dial input before the sequence was ordinary mouse-wheel
data; afterward it exposed separate vendor control reports. Both requests are
GET_DESCRIPTOR-shaped USB operations, but have device-mode side effects.

See [feasibility and limits](FEASIBILITY.md),
[standalone evidence](protocol/standalone-results.md), and
[Bluetooth evidence](protocol/bluetooth-results.md).
Full six-group profile behavior, reconnect and power-cycle recovery, group-name
display, rotation, brightness, sleep, and battery controls remain unverified.

## Capture app

Build with `bash scripts/build.sh`, then open `build/K40 Probe.app` in Finder.
The build uses the standalone Command Line Tools and the local Developer ID
identity already configured on this machine. No package dependencies are used.
The local app is signed but has not been notarized for distribution.
Input Monitoring must be granted to K40 Probe by the user.
Bluetooth access also requires the user's macOS Bluetooth permission.

**Start capture** runs the numbered controls sequence. **Free capture** records
any controls until **Stop capture**. Keep the probe in front when Huion is also
running, so existing shortcuts do not affect other work. The app ignores key
events in its own window; it is not a global shortcut blocker. Each launch
creates `evidence/capture-<UTC>/events.jsonl` and `status.json`. Device removal
and addition are logged, including during a reconnect. Raw packets are retained
alongside conservative decoded descriptions.

The app opens the K40 non-exclusively and does not inject keys or modify Huion
configuration. Explicit Bluetooth controls enter vendor mode and write
temporary test labels to the OLED. Repeated button-state reports are snapshots;
a controller must compare states to derive press and release transitions.

For a Bluetooth test, quit Huion, disconnect USB, and grant Bluetooth access
if macOS asks. In K40 Probe choose **Inspect Bluetooth**, then **Enable
Bluetooth controls** (C9 then C8). Choose **Free capture** to record controls;
choose **Write BT1–BT8 labels** to send temporary OLED labels. Stop capture
and quit the probe afterward, then reopen Huion to restore its labels. Both
the corrected row-order presentation and restoration were physically confirmed.

## OLED writer

Build with `bash scripts/build-screen.sh`. The script tests the label encoder.
For a standalone test, quit Huion, open K40 Probe and choose Free capture, then
run the startup sequence before using any controls or sending labels:

```sh
build/k40-screen --preflight
build/k40-screen --enter-control-mode  # C9 identity, then C8; changes device mode
build/k40-screen --key 1 1 POC          # print packet only
build/k40-screen --button 1 1 POC       # physical top-left button, packet preview
build/k40-screen --group 1 'POC group'  # print packet only
build/k40-screen --button 1 1 POC --send # write the physical top-left label
```

Group, key-slot, and physical-button arguments are one-based. `--key` addresses
wire slots 1–8; `--button group physicalButton text` maps row-major physical
buttons (top 1–4, bottom 5–8, with dials at left) through shared
`K40ButtonLayout`: physical buttons 1–8 map to wire slots
`[2, 4, 6, 8, 1, 3, 5, 7]`. Text uses UTF-16LE; the encoder rejects values exceeding the packet
capacity. The writer only accepts known label commands, checks USB identity,
opens non-exclusively, sends one vendor-derived request, and closes the handle.
No firmware-update commands, arbitrary USB requests, or fallback report IDs are sent.

Quit Huion before a controlled display test to prevent its profile refresh from
replacing the test label. Preserve the original configuration first. Relaunch
Huion to reapply its configuration, then confirm restoration on the device.
There is no implemented label readback. The original configuration is backed up locally and excluded from git.

`--current-group` retains a diagnostic E8 query found in the installed driver.
The tested firmware returned an invalid descriptor, so this result is not used
to infer group state. The abandoned HID feature-ID experiment is documented in
the evidence but is not part of the working writer.

See [OLED packet details](protocol/K40_LABELS.md),
[input decoder](protocol/input-decoder.md), and
[full capability checklist](protocol/coverage.md).

## Decoder fixture check

```sh
/Library/Developer/CommandLineTools/usr/bin/swiftc \
  -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk \
  Sources/K40ButtonLayout.swift Sources/K40Decode.swift Tests/DecodeTests.swift -o build/decode-tests
build/decode-tests
```

## Prior art

[piotrrojek/keydial-kd100](https://github.com/piotrrojek/keydial-kd100)
demonstrates a native IOKit approach for the different KD100. This POC implements
the observed K40 reports and locally inspected K40 label protocol; it is not a
claim that the KD100 project's device protocol supports the K40 screen.

## Development status

USB and Bluetooth control capture and all eight OLED key-label writes have
been physically demonstrated. The current native app entry point is a temporary
setup/capture screen; the production action engine, profile UI, and MCP are
being built. See [feasibility](FEASIBILITY.md) for proven and unverified behavior.
Raw device captures, personal Huion profiles, and local build output are not
published. References to evidence files in protocol notes refer to local tests.

KDCustom is an independent project and is not affiliated with Huion.
