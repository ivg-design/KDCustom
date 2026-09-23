# K40 device settings: installed-driver static analysis

This is a read-only analysis of the ARM64 slice of `/Applications/HuionKeyboard.app/Contents/Resources/HuionDriver.app/Contents/MacOS/HuionDriver` on 2026-09-22. Addresses identify this installed binary. It establishes the driver's command order and decoding, not successful settings changes on a physical K40. Live responses and screen changes still need capture. No setting command was sent during this analysis.

## Transport and response offset

Every setting method below calls `ZTabletConnectObj::GetIndexedString` at `0x1000621a4` with an index and a 128-byte buffer. On USB it sends `bmRequestType=0x80`, `bRequest=0x06`, `wValue=0x0300 | index`, `wIndex=0x0409`, `wLength=128` through `IOUSBDeviceInterface300::DeviceRequest`. On Bluetooth, `ZBltObj::RequestInfo` writes `CD <index> 00 00 00 00 00 00` to `FFE2` and receives the reply on `FFE2`. The caller's setting buffer starts at **raw response offset 2** on either transport: `GetIndexedString` removes the first two bytes. Its callers do not check the returned success flag or actual length before reading the buffer, which they initialized to zero. A replacement must retain transport status, raw bytes, and actual length; a zero buffer after failure is not a measured zero setting.

The USB C9 response was a valid UTF-16LE string descriptor, and the Bluetooth C9/C8 replies used `[length, index, payload...]`. Settings replies have not yet been captured. Validate framing for the transport and index before decoding. In particular, the previously observed USB E8 response began `c0 0e 00 20 69 01 00 08`, so the driver's unchecked offset-2 read cannot establish the group number.

## Exact setting commands and driver decode

All offsets in this table refer to the payload **after** the two-byte transport prefix (raw offset 2 on USB/BLE). Unrecognized values should remain raw/unknown in the replacement.

| Setting | Query index and method | Payload decode in driver | Single-step index and method |
| --- | --- | --- | --- |
| Battery | `D1`, `QueryBattery` `0x1000625d0` | Uses payload bytes 0 and 1; see below. Returns a displayed 20/40/60/80/100 bucket, not a proven true percentage. | None found here. |
| Brightness | `D9`, `QueryBrightness` `0x1000629d4` | Payload byte 0: `01→1`, `02→2`, `04→3`, `08→4`, `10→5`; any other value → 0/unknown. | `D7` up, `Brightness_Up` `0x100062a8c`; `D8` down, `Brightness_Down` `0x100062b00`. Each method returns true only when its post-prefix payload byte 0 is `01`. |
| Dormant/sleep | `DC`, `QueryDormantTime` `0x100062e58` | Payload byte 0: `0F→1`, `1E→2`, `3C→3`, `5A→4`, `78→5`; any other value → 0/unknown. Values are 15, 30, 60, 90, 120 numerically; the unit and observed screen effect still need live confirmation. | `DA` up, `DormantTime_Up` `0x100062f08`; `DB` down, `DormantTime_Down` `0x100062f7c`. Each returns true only for post-prefix payload byte 0 `01`. |
| Rotation | `DE`, `QueryRotateDegree` `0x100063058` | Payload byte 0 `00/01/02/03` → `0°/90°/180°/270°`; values above `03` → 0 in the driver, but should be unknown to a replacement. | `DD` advances one step, `RotateDegree` `0x100062ff0`. It discards the reply. The direction and wrap behavior need live confirmation. |

`QueryBattery` has two code paths. When payload byte 1 equals decimal 100 (`0x64`), it buckets payload byte 0 as `0–20→20`, `21–40→40`, `41–60→60`, `61–80→80`, `81–100→100`; `101–255` fall back to 20. Otherwise it treats payload byte 0 as a status code: `01→20`, `02–04→40`, `05–10 hex→60`, `11–7F hex→80`, `80 hex→100`, and other values → 20. The meaning of the second byte and these buckets is not independently established. Preserve both bytes and avoid presenting this as calibrated battery percentage until compared to device behavior.

## Driver setter sequences

`SetBrightness` (`0x100062734`) clamps its target to levels 1–5, queries `D9`, and returns immediately when its decoded level already matches. Otherwise it chooses a repeated `D7` or `D8` path, querying `D9` after every step, with at most 11 steps. `SetDormantTime` (`0x100062b74`) constrains its requested level for the initial comparison to 0–4, queries `DC`, and repeatedly sends `DA` or `DB` followed by `DC`, also bounded at 11 steps. The driver's dormant level range is internally inconsistent with `QueryDormantTime` returning 1–5; the standalone replacement should not copy that setter blindly. For these two settings the driver sleeps 100 ms after each step **only when BLE is open**.

`SetRotateDegree` (`0x1000630e0`) accepts absolute magnitudes 0, 90, 180, or 270 degrees, queries `DE`, then repeats `DD`, sleeps 100 ms, and requeries `DE` until it matches or reaches 11 steps. Unlike brightness and dormant time, this sleep is unconditional. The driver does not send the requested degree as a payload; all three settings use indexed-string requests as commands.

The single-step methods give the most bounded physical test: after C9/C8 control-mode entry, capture `D9`, `DC`, `DE`, and `D1` raw replies and visible values; issue **one** `D7` or `D8`, `DA` or `DB`, or `DD` at a time; then requery the corresponding read index and visually check the screen. Record transfer status, raw response bytes, actual length, and the screen state both before and after. Use the opposite step to restore brightness or dormant time once its direction is observed. Rotation has no reverse command identified in this block; restore by bounded `DD` steps only after the readback and physical sequence establish its cycle. Do not try arbitrary indices or repeat on an unrecognized response.

## Group selection boundary

`QueryCurKeyGroupIndex` (`0x1000626c8`) requests `E8` and returns post-prefix payload byte 0 without validating it. The live USB response was not a valid string descriptor and resembled firmware data. Do not use `E8` to initialize or correct native group state. Report-8 group-button bits `0x1000` (previous) and `0x2000` (next) were physically captured, but the startup group, wrap behavior, and whether the device or host owns selection remain unverified. Track the input events and expose group state as unverified until synchronized by a physical observation. Explicit label packets can still address groups 1–6.
