# Standalone USB control-mode and screen test (live evidence)

This record uses `evidence/screen-test/` and the completed `evidence/capture-2026-09-22T23-44-52Z/events.jsonl` (SHA-256 `595c7a3f54fc20855aa3f3315a5338ddb95e6367605f7ada8975598f017e89f1`, 44,527 bytes). The capture stopped at 23:57:40 UTC and the POC exited at 23:57:41 UTC. The test was performed with the Huion app closed; the Huion app was reopened after capture ended.

## Entry sequence and display

Before the control-mode requests, physical dial turns in the standalone capture produced seven-byte mouse report 5 frames (`05 00 00 00 00 00 ff/01/00`); no vendor report 8 was observed in that interval. At 23:54:09 UTC, the POC sent the installed driver's discovery sequence to the selected USB `LocationID` (`68157440`): string-descriptor request index `0xC9`, followed by `0xC8`. Both returned status zero. C9 returned a well-formed UTF-16LE descriptor spelling `HUION_T221_250807`; C8 returned a 20-byte descriptor beginning `14 03 01 00 00 01 ...`. Their raw bytes are in `screen-test/control-mode-entry.jsonl`.

After C9/C8, the same capture received 12-byte vendor input report 8 frames; the first logged vendor frame was at 23:55:07 UTC. A later legacy USB `DeviceRequest` label write returned status zero and 64 transferred bytes; the user then confirmed that `POC` appeared on the K40. The same transport sent eight indexed test labels, `P1` through `P8`, with eight successful 64-byte transfers in `screen-test/eight-labels.jsonl`. The user explicitly confirmed seeing **all eight** on the device (`screen-test/eight-labels-visual.json`). This visual confirmation is separate from input-report evidence.

The earlier no-init conclusion was limited to `ZTabletConnectObj::Connect` and its label setters. It omitted discovery's C9/C8 requests. In this standalone test, the C9/C8 sequence preceded both the return of vendor report 8 and visible OLED label acceptance. The observation establishes the sequence as effective here; it does not isolate which request causes either state change or prove a periodic heartbeat. Earlier E8 readback returned bytes resembling a firmware vector table, so E8 remains unsuitable as a validated group-index read.

## Standalone input coverage

The vendor interface produced both `E0` control-state and `F1` dial frames. The capture contains individual E0 masks `0x01`, `0x02`, `0x04`, `0x08`, `0x10`, `0x20`, `0x40`, and `0x80`, matching all eight physical key bits established in the guided capture. The final four masks (`0x02`, `0x08`, `0x20`, `0x80`) appeared at 23:56:57–23:57:00 UTC during the user's last-four-key sequence. It also contains both group-switch masks `0x1000` and `0x2000`. F1 frames include both directions for both dial IDs: inner `01`/`02`, outer `01`/`02` at the direction byte. These are observed raw controls, not a claim that every group profile or application mapping was exercised.

The final file has 136 report rows: 17 report-5 rows before vendor mode and 119 report-8 rows (62 E0 and 57 F1). Screen writes are separately logged and do not imply a saved Huion configuration change. A later standalone reconnect/exit check, Bluetooth, and per-group display mapping remain outside this USB run.
