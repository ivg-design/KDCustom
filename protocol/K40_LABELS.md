# K40 OLED label writes

Source: ARM64 slice of the installed `HuionDriver` at
`/Applications/HuionKeyboard.app/Contents/Resources/HuionDriver.app/Contents/MacOS/HuionDriver`.
The protocol below was recovered from static inspection and then tested on USB
and Bluetooth independently of the Huion app.
The first write returned success without a visible change. After reproducing
Huion's C9/C8 startup sequence, the same request visibly changed a key label;
all eight key slots were then written as P1–P8 and confirmed by the user.
The group-name format below is statically verified but its display effect has
not been physically tested. See `../evidence/screen-test/` for transfer logs.

Bluetooth sends the same 64-byte payload to GATT characteristic `FFE2`, after
C9/C8 initialization over that characteristic. The user confirmed all eight
`BT1`–`BT8` labels. See [Bluetooth results](bluetooth-results.md).

## Physical position mapping

With the dials at the left, hardware slots run bottom/top through each column:
top row `[2, 4, 6, 8]`, bottom row `[1, 3, 5, 7]`. The probe now presents
physical buttons as top `1–4`, bottom `5–8`, using `K40ButtonLayout` for both
input masks and label destinations. The corrected Bluetooth layout was written
and physically confirmed by the user in session `capture-2026-09-23T00-25-07Z`.
`k40-screen --button group physicalButton text` uses this mapping;
`--key group wireSlot text` addresses the raw vendor slot.

## Payloads

Both methods initialize a 64-byte buffer to zero. Text is copied as UTF-16LE
code units from `QString`, without a terminating code unit in the counted text.
The byte count is clamped; values beyond the clamp are truncated.

| Offset | Group name (`K40_SetGroupName`) | Key name (`K40_SetEKeyName`) |
| --- | --- | --- |
| 0–3 | `18 01 05 03` | `18 02 05 03` |
| 4 | group index + 1 | group index + 1 |
| 5 | text byte count, max 58 | `00` |
| 6 | UTF-16LE text begins | key index + 1 |
| 7 | text continues | text byte count, max 56 |
| 8–63 | text / zero padding | UTF-16LE text / zero padding |

The methods take integer indexes and cast the incremented values to bytes. No
range check was visible inside these two setters. Callers should validate group
and key indexes independently; the static inspection does not establish device
bounds.

ARM64 function addresses: `K40_SetGroupName` at `0x100063238`, and
`K40_SetEKeyName` at `0x1000633b0`. The constant payload prefixes come from
`0x10007e560` and `0x10007e568`, respectively.

## USB transport

When a Bluetooth connection is open, each setter calls `ZBltObj::SendData`
with the 64-byte payload. Otherwise it locates a USB device using
`FindUSBInterface(0, locationID)` and issues an `IOUSBDeviceInterface300`
`DeviceRequest`. Its `IOUSBDevRequest` fields are:

| Field | Value | Meaning |
| --- | --- | --- |
| `bmRequestType` | `0x21` | host-to-device, class, interface |
| `bRequest` | `0x09` | HID `SET_REPORT` |
| `wValue` | `0x0316` | Feature report, report ID `0x16` |
| `wIndex` | `0x0001` | interface 1 |
| `wLength` | `0x0040` | 64 bytes |
| `pData` | payload above | group or key label |

The standalone `USB_SendData` function at `0x100060094` uses the same control
request fields and accepts an arbitrary buffer and length. The label setters
call the device request directly. They do not inspect its return value.

The separately observed K40 USB descriptor advertises a Feature report with
ID `0x18`, while these setters request report ID `0x16` and place `0x18` at
payload byte 0. The reason for this difference is unknown. Both label setters
and the generic `USB_SendData` helper consistently use `0x0316`, so the POC
transport reproduces that observed request exactly. An alternative HID feature-ID 0x18 experiment returned `0xe00002cd` (not open)
and was removed from the working implementation. No fallback is performed.
The original 0x0316 transfer is now physically verified after startup.

## Driver-level sequencing

`ZTabletObj::K40_ShowEKeyV` queues a worker request.
`DoK40ShowEKeyV` (`0x1000661a0`) expects JSON members `Time`, `GroupNum`,
`GroupName`, `KeyText`, and `Type`. It calls the group setter when `Type` is 0
or 1, then waits 1000 ms. It calls the key setter for each position in the
`KeyText` array when `Type` is 0 or 2, waiting 200 ms between positions. Array
positions are passed as zero-based key indexes; both setters add one in the
payload. These delays are observed vendor behavior, not a demonstrated device
requirement.

No label readback method has been identified. Visible updates to all eight key
slots were confirmed by the user. Stopping Huion changed dial reports from
vendor report 8 to standard mouse report 5; reproducing C9/C8 startup restored
vendor reports in the subsequent standalone capture.
