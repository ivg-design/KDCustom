# K40 capture and display coverage

This is the acceptance inventory for the USB and Bluetooth proof of concept. Core input reports and key-label writes have been decoded and independently exercised on both transports; the remaining rows distinguish observed behavior from full feature parity. The exact installed control and display settings, including all six groups under the default and Rive app profile, are in [`../evidence/baseline-config.json`](../evidence/baseline-config.json). Its SHA-256 identifies the original `EKeySetting.dt`; the JSON is an extracted evidence snapshot, not an importable driver backup.

## Source boundaries

- Huion's [K40 manual](https://driverdl.huion.com/instruction/Keydial_Remote/User_Manual_Keydial_Remote_K40_EN.pdf), pp. 2–4, describes eight programmable press keys per group, two programmable dials, two set buttons for previous/next group, six groups, and an OLED with group name, key values, connection, battery, sleep, and charging states. Dial functions are configurable, but the manual says their values are not displayed in real time.
- The same manual, pp. 5–6, supports USB and Bluetooth connection. Huion's [K40 FAQ](https://support.huion.com/en/support/solutions/articles/44002649782-keydial-remote-k40-faq) says a computer USB connection switches the device to wired mode. This POC separately observed USB VID `0x256c` / PID `0x2002` and Bluetooth Low Energy VID `0x256c` / PID `0x8251`. The Bluetooth GATT command, input, and display evidence is recorded in [bluetooth-results.md](bluetooth-results.md); the USB report layout alone was not used to infer Bluetooth behavior.
- The manual, pp. 16–20, describes app-specific presets, six independent groups, configurable key names, dial reverse/custom/mouse/multimedia modes, and display rotation. The installed configuration currently has a default set and one `/Applications/Rive.app` profile; groups 0–2 are named, while 3–5 have no populated eight-key assignment. Treat empty entries as unconfigured, not as hardware absent.

## Control inventory

| Control | Capture target | Display target |
| --- | --- | --- |
| Eight press keys | Distinct down/up for each physical key; repeat/hold behavior where emitted | Group-specific key label/value for each position |
| Previous and next set buttons | Distinct presses and releases; resulting group index with wraparound | Group number and configured group name, including empty groups |
| Left and right dials | Clockwise and anticlockwise reports separately, with sign/magnitude and slow/fast turns | Configured group state; no claim of live dial-value display |
| Power/Bluetooth selector | Record connection changes and USB reconnection behavior manually; do not assign a keyboard event without evidence | Connection icon and battery/charging state if observable |
| OLED | Record any screen feature report/write as raw bytes before interpreting fields | Group-name flash, key-value view, idle/home, rotation, sleep/wake, and USB/Bluetooth status as applicable |

The configuration's `key0`–`key7` are the eight configurable press-key entries; `key8` and `key9` carry set-button function codes `65536` and `131072` in populated groups. Configuration indices are distinct from raw HID button-mask bits and OLED wire slots. The observed physical layout with dials at left is top row wire slots `[2, 4, 6, 8]`, bottom row `[1, 3, 5, 7]`; `K40ButtonLayout` maps physical buttons top 1–4 then bottom 5–8 to those slots. `MKey0` and `MKey1` are the two dial settings. Both dials in the installed Rive group 0 have custom left/right entries with `ModifyKey: 8` and arrow key values 126/125; this records the baseline, not an intended POC output.

## Minimal human capture sequence

1. Start with the wired USB connection and note the current displayed group, orientation, USB icon, and battery/charging indicator. Record the raw input and feature reports alongside the tester's monotonic timestamps. Leave the Huion settings file unchanged.
2. In group 0, press and release each of the eight physical keys one at a time, pausing between keys. Hold one key briefly to distinguish a single edge from repeated reports. Label observed physical positions from the device face, then correlate them with configuration indices only after evidence agrees.
3. Turn each dial one slow detent clockwise and anticlockwise, then several faster detents in each direction. Capture both dials independently and check whether one report represents one or multiple detents. Avoid changing any application value during this capture-only POC.
4. Press next set once; record the raw button transition, group index/name, and OLED result. Repeat through all six groups. In each group, capture the eight keys and both dial directions at least once, including unconfigured groups, so physical-control coverage is separated from configured actions. Press previous set once to verify reverse traversal and wraparound.
5. Exercise an OLED update for each populated group in the proof of concept, then visually compare the shown group name and eight key labels with `baseline-config.json`. Check that empty/null group names are displayed safely. Change rotation only if the POC has a proven reversible display command; otherwise mark it untested.
6. Disconnect and reconnect USB and verify recovery of input capture and display state. Separately repeat Bluetooth control, label, and restoration tests after disconnect/reconnect and power cycle; the completed single-session Bluetooth capture does not establish recovery.

## Acceptance record

- [x] Unique raw signature or an explicitly documented ambiguity for all eight press keys, both set buttons, and both directions of both dials.
- [ ] Press/release, hold/repeat, slow/fast dial, group transition, and wraparound observations include timestamps and raw bytes.
- [ ] Six-group mapping reconciles the installed default and Rive profile without treating empty groups as missing controls.
- [ ] OLED group name/index, eight labels, and connection/battery states are visually verified against the device after display writes; dial values are only claimed if actually observed.
- [x] Standalone USB and Bluetooth sessions each capture all eight keys, two group buttons, and both directions of both dials; all eight temporary key labels were physically confirmed on both transports.
- [x] Corrected row-major Bluetooth label write is physically confirmed, followed by Bluetooth Huion restoration.
- [ ] USB and Bluetooth reconnect recover cleanly; power-cycle behavior is recorded.
- [x] The installed Huion configuration file still hashes to `91c23d8312e39b915d0ee535666496b9ff290341523490ba1cac712ae068b5fe` after capture, or any change is explicitly recorded before using this baseline for restoration.


## Actual POC result

See [USB standalone results](standalone-results.md),
[Bluetooth standalone results](bluetooth-results.md), and
[FEASIBILITY](../FEASIBILITY.md). Core input and all eight key-label slots passed
on both transports. Six-group behavior, group-name display, rotation,
brightness, sleep, battery, reconnect/power cycle, and production profile and
shortcut behavior remain unverified. Rive output is outside this POC.
