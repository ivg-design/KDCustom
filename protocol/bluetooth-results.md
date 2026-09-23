# K40 Bluetooth standalone capture

The completed capture is `evidence/capture-2026-09-23T00-16-21Z/events.jsonl` (154 JSONL events, 36,245 bytes, SHA-256 `259ba86ed631fc526c1ead78ced883e108423ac5d5041c8b22a841e7c3d098ca`). It began with the installed Huion process stopped and ended with `capture_stop` and `app_exit`. The Bluetooth peripheral was `Keydial Remote-365`, vendor `0x256c`, product `0x8251`, connected through the vendor GATT service. This is one standalone session, not a reconnect or persistence test.

The POC queued C9 and C8 commands to `FFE2` using WriteWithoutResponse (write type 1), and received the respective 19-byte and 20-byte replies as `FFE2` notifications. It then queued eight 64-byte screen-label writes to `FFE2`. The user confirmed that **BT1 through BT8** appeared on the device. For those wire slot numbers, the observed physical order was top row `[2, 4, 6, 8]`, bottom row `[1, 3, 5, 7]`. This is evidence for the slot-to-screen mapping, not evidence that a later row-major UI mapping has been retested. The screen confirmation is also recorded in `evidence/bluetooth/display-confirmation.json`.

During free capture, 63 `FFE1` input notifications of 14 bytes each produced 63 normalized 12-byte `report` events: 36 `E0` button/group reports and 27 `F1` dial reports. The two other notifications were the C9 and C8 replies on `FFE2`. The `E0` button-mask counts include all eight individual key bits `0x0001` through `0x0080`, plus group bits `0x1000` and `0x2000`; zero-mask releases were also present. The `F1` reports covered both dial identifiers (1 and 2), with direction bytes 1 and 2 for each. This supports raw input coverage for all eight keys, both group controls, and both dials in both directions. It does not establish operating-system shortcut output.

The original normalized `report` events in this capture incorrectly have `interface: "K40/FFE2"`. The paired raw `ble_notification` events contain the authoritative source `uuid: "FFE1"`; they are present one-for-one, so the metadata error did not discard input bytes. A later source correction records the actual characteristic UUID. One example raw frame is `55 54 e0 01 01 02 00 00 00 00 00 00 00 e4`, normalized to `08 e0 01 01 02 00 00 00 00 00 00 00`.

In the 27 BLE `F1` frames, byte 6 was `0x01` whenever the direction byte 5 was `0x01`, and `0xFF` whenever direction byte 5 was `0x02`. In the prior USB captures, byte 6 was `0x00` for both directions. The difference is observed but its semantics are unverified; the decoder should preserve the byte without treating it as a proven step count or flag.

This session does not test reconnection, a six-group label/profile workflow, label persistence after a power cycle, or restored Huion-driver behavior.

## Corrected physical label order

A subsequent session, `capture-2026-09-23T00-25-07Z`, reconnected the probe,
completed C9/C8 startup, and wrote BT1–BT8 to wire slots `[2,4,6,8,1,3,5,7]`.
The user confirmed top row BT1–BT4 and bottom row BT5–BT8, with the dials at
the left. See `evidence/bluetooth/row-order-confirmation.json`. This demonstrates
an app-level reconnect and the corrected row layout; it does not establish
recovery after Bluetooth loss or a device power cycle.

After the probe closed, both Huion processes restarted. The user confirmed
normal labels returned. The saved configuration SHA-256 remained
`91c23d8312e39b915d0ee535666496b9ff290341523490ba1cac712ae068b5fe`.
See `evidence/bluetooth/restoration.json`.
