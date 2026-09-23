# Remaining K40 control paths: static inspection

Source: ARM64 slice of the installed `HuionDriver`, inspected without executing
its device commands. The label packet write is documented separately in
`K40_LABELS.md`. This note covers readback, mode and screen controls that may
matter to a replacement controller. Symbol names and addresses refer to this
installed driver version.

## Indexed-string read transport

`ZTabletConnectObj::GetIndexedString(unsigned int, unsigned char *, unsigned
int)` at `0x1000621a4` uses Bluetooth `ZBltObj::RequestInfo` when Bluetooth is
open. On USB it issues an `IOUSBDeviceInterface300::DeviceRequest` with
`bmRequestType=0x80`, `bRequest=0x06` (GET_DESCRIPTOR),
`wValue=0x0300 | index`, `wIndex=0x0409`, and the supplied maximum byte length.
After a successful USB request it removes the first two returned descriptor
bytes. Several vendor controls use this read-shaped request; their side effects
cannot be inferred from the USB request name alone.

| Driver method (ARM64 address) | Observed indexed-string use | Static conclusion |
| --- | --- | --- |
| `QueryCurKeyGroupIndex` `0x1000626c8` | `0xE8`, 128-byte buffer | The driver returns the first byte after removing two bytes. Live K40 USB response was not a valid string descriptor; no current-group readback is established. |
| `QueryBattery` `0x1000625d0` | `0xD1` | Battery/status readback exists; response mapping needs capture. |
| `QueryBrightness` `0x1000629d4` | `0xD9` | Brightness readback exists. |
| `SetBrightness` `0x100062734`, `Brightness_Up` `0x100062a8c`, `Brightness_Down` `0x100062b00` | `0xD7` and `0xD9` | Vendor uses a multi-step sequence with queries and 100 ms waits, not a decoded direct label-style packet. Setter clamps its requested level to 1–5. |
| `QueryDormantTime` `0x100062e58` | `0xDC` | Sleep/dormant-time readback exists. |
| `SetDormantTime` `0x100062b74`, `DormantTime_Up` `0x100062f08`, `DormantTime_Down` `0x100062f7c` | `0xDA`, `0xDB`, `0xDC` | Vendor uses a multi-step sequence with 100 ms waits; exact response-to-duration mapping needs capture. |
| `QueryRotateDegree` `0x100063058` | `0xDE` | Screen rotation readback exists. |
| `SetRotateDegree` `0x1000630e0`, `RotateDegree` `0x100062ff0` | `0xDD` and `0xDE` | Setter accepts 0, 90, 180, and 270 degrees, then performs repeated indexed-string requests with 100 ms waits. Exact screen effect and response encoding need capture. |

## Group selection and initialization

`ZTranslateTabletEvent::DoKeyGroup` (`0x1000574a0`) and
`DoKeyGroupIndexUpOrDown` (`0x10005758c`) call
`ZTabletObj::OnSelectKeyGroup` (`0x100068f14`) and
`OnKeyGroupIndexUpOrDown` (`0x100069234`). In the inspected paths, those object
methods construct JSON commands for `ZCmd::PostCmd` rather than directly
issuing the USB label request. A dedicated USB group-selection setter was not
identified in the `ZTabletConnectObj` symbol set. The hardware may select
groups itself, or the UI/another path may do so; static inspection does not
settle that behavior. The attempted `0xE8` query returned 128 bytes beginning `c0 0e 00 20 69 01
00 08`, with an invalid descriptor header. The POC now preserves these bytes
without interpreting them as a group. A user-supplied photo independently
showed group 1.

`ZTabletConnectObj::Connect` (`0x100061420`) registers an IOHID input report
callback with a 14-byte report buffer; `Connect_HID` (`0x100061580`) provides
the HID setup path. No K40-specific initialization or reset call was seen in
the two label setters before their 64-byte send. This establishes that their
code path does not require an explicit preamble there; it does not prove that
all devices accept writes immediately after enumeration.

The next evidence needed for full screen mapping is a captured sequence of
button presses, group changes, OLED state, and indexed-string responses. A
successful IOKit transfer confirms transport completion; visible OLED change
must be confirmed on the device.
