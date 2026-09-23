# Installed driver connection and label-send path (static inspection)

This note describes the ARM64 slice of the installed `HuionDriver`; it does not claim that a USB transfer changed the K40 display. Addresses refer to this binary. Inspection was read-only.

`ZTabletConnectObj::Connect` (`0x100061420`) selects Bluetooth only when the saved device transport field is nonzero. Its USB/HID branch schedules the `IOHIDDevice` and registers a 14-byte input-report callback; it sends no vendor command. `Connect_HID` (`0x100061580`) performs the same callback setup. `DisConnect` (`0x100061150`) clears the connected flag, closes Bluetooth if present, and empties the queue. The `ZTabletConnectObj` constructor (`0x100060f64`) copies the device record and initializes state without a vendor-mode write.

There are relevant requests **outside** `Connect`: during HID discovery, `ZDevDetector::GetRDCode_HID` (`0x100060b50`) calls `USB_GetRDCode` (`0x100060194`), which issues a read-shaped `GET_DESCRIPTOR` request for string index `0xC9` (`bmRequestType=0x80`, `bRequest=6`, `wValue=0x03C9`, `wIndex=0x0409`, `wLength=128`). `GetTabletInfo_HID` (`0x100060bdc`) similarly calls `USB_GetTabletInfo` (`0x100060700`) at index `0xC8` (`wValue=0x03C8`, otherwise the same request). `ZDevMng::OnDeviceMatching` (`0x100051670`) calls C9 first, requires successful parsing of RD code `T221` and a valid customer code, then calls C8. Only after C8 succeeds does it construct the tablet object and call `StartReadData` (`0x100051958`). There is no sleep or repeated indexed-string request in this detector block. `StartReadData` queues a read request; the disconnected read loop waits one second before `Connect`. The read-shaped requests do not exclude device-side mode effects; whether C9 or C8 enters vendor-report mode is unverified. Preserve raw responses while testing, since the driver's generic response parser strips two bytes without checking for a well-formed USB string header.

On object destruction, `ZTabletObj::~ZTabletObj` (`0x100064444`) issues `GetIndexedString(0xCD)` for all OEM codes except `OEM24`; for `OEM24`, it uses `0xD5`. These requests occur after worker shutdown and before destruction of the `ZTabletConnectObj`. They are concrete shutdown-time commands and possible mode-exit commands, not proven semantics. In a capture taken after the Huion app quit, dial turns produced mouse report `05 00 00 00 00 00 ff/01/00` instead of vendor report 8. This timing is consistent with a mode change but does not isolate which exit action caused it.

The screen-label operation is a separate work request. `K40_ShowEKeyV` (`0x100066130`) enqueues request `0x65`; `DoK40ShowEKeyV` (`0x1000661a0`) handles it. Its JSON payload must include `Time`, `GroupNum`, `GroupName`, and `KeyText`. For `Type` 0 or 1, it calls `K40_SetGroupName` and sleeps 1000 ms. For `Type` 0 or 2, it calls `K40_SetEKeyName` for each element of `KeyText`, sleeping 200 ms after each. This is the installed driver's upload sequence, not proof that the sleeps or whole batch are firmware requirements.

Both label setters (`0x100063238`, `0x1000633b0`) send their 64-byte payload through `ZBltObj::SendData` only when a Bluetooth object exists **and** `HasOpenedBLE` is true. Otherwise they call `FindUSBInterface(0, storedLocationID)` and issue `IOUSBDeviceInterface300::DeviceRequest` with `bmRequestType=0x21`, `bRequest=0x09`, `wValue=0x0316`, `wIndex=1`, and `wLength=64`. The second lookup argument comes from the `LocationID` placed in `sDevItem` during device matching (`0x1000518a8–0x1000518c4`). They do not use `IOHIDDeviceSetReport`; that symbol is absent from the binary imports. The HID descriptor's feature report ID `0x18` may support another transport, but that route is not evidenced by this driver. Neither setter checks the device-request return code before returning, so a completed host call alone is not evidence that an OLED label was accepted or shown.

The `0xE8` indexed-string request is **not validated** as K40 group readback. A live 128-byte response began `c0 0e 00 20 69 01 00 08 ...`, consistent with a Cortex firmware vector table and not a USB string-descriptor header. Do not interpret byte zero after stripping two bytes as a group index from that response. The `0xC8`, `0xC9`, `0xCD`, and `0xD5` responses have not been captured and validated here.

## Live reproduction

With both Huion processes stopped, the POC reproduced C9 then C8 at
2026-09-22T23:54:09Z. Both USB requests returned success. C9 was a valid USB
UTF-16LE string descriptor containing `HUION_T221_250807`; C8 returned
`14 03 01 00 00 01 00 00 00 00 00 00 00 0e 00 80 40 00 32 10`.
These establish the identity/transport sequence, not the resulting input mode.
The subsequent standalone capture established all eight button masks, both group
buttons, and both directions of both dials as vendor report 8. Evidence is in
`../evidence/screen-test/control-mode-entry.jsonl`.

A key label was resent after that sequence using the legacy driver request;
transfer and close both returned success. The user confirmed POC appeared, then confirmed all eight labels P1–P8.
A second E8 query still returned the invalid descriptor-shaped data, so it is
not used to infer the group even after the startup sequence.
