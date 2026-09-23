# K40 replacement-controller feasibility

**Core USB and Bluetooth input and key-label functionality is demonstrated. Full feature parity is not yet tested.**

On 2026-09-22, a standalone native macOS POC received the K40's controls and
changed all eight OLED key labels while both Huion processes were stopped.
The user confirmed that `P1` through `P8` appeared on the device. Huion was
reopened afterward; the user confirmed the normal labels returned.
On 2026-09-23, the same POC independently captured all core controls over
Bluetooth GATT and sent eight OLED labels. The user confirmed `BT1` through
`BT8` appeared. That test established the wire-slot order; the user then
confirmed the corrected row-major layout and restoration of normal Huion labels.
Dates here are UTC; both tests occurred on September 22 in the user's timezone.

| Capability | Evidence / conclusion |
| --- | --- |
| Eight main buttons | All eight individual masks and zero/release states captured on standalone USB and Bluetooth |
| Two dials | Separate inner/outer IDs and both directions captured on standalone USB and Bluetooth |
| Two group buttons | Distinct previous/next button masks captured on standalone USB and Bluetooth |
| Held buttons / chord | Combined button state and repeated held-state frames captured in the earlier guided run with Huion running |
| Eight OLED key labels | All eight temporary labels physically confirmed on USB and Bluetooth; corrected row-major Bluetooth layout also confirmed |
| Startup without Huion | C9 then C8 enabled observed vendor input and display behavior on USB and Bluetooth |
| Restoration | Normal labels physically confirmed after both USB and Bluetooth tests; saved config SHA-256 unchanged |
| Six groups and group-name display | Packet layout recovered, encoder implemented; full group traversal and display behavior not tested |
| Reconnect / power cycle | App-level BLE reconnect succeeded for the layout retest; recovery from physical disconnection and power cycle remains untested |
| Bluetooth | GATT FFE2 C9/C8 and label writes, FFE1 raw input, all controls and eight labels observed in one standalone session |
| Rotation, brightness, sleep, battery | Driver methods located; effects and response encodings not verified |
| Production profiles / shortcut synthesis / Rive | Not tested; Rive output is outside this POC |

## What made it work

The initial label request returned USB success but produced no visible change.
Huion exit also changed the observed dial output to ordinary mouse reports.
The driver's discovery sequence sends USB string-descriptor requests C9 and C8
before opening input. Reproducing C9 yielded the valid UTF-16LE identity
`HUION_T221_250807`; C8 yielded a valid descriptor-shaped response. Afterward,
the same label request visibly worked and input arrived as vendor report 8.
The sequence is established; this experiment does not isolate which of its two
requests is responsible for each mode effect.

The working label request is the driver's 64-byte SET_REPORT control transfer:
`bmRequestType=0x21`, `bRequest=9`, `wValue=0x0316`, `wIndex=1`.
Its payload begins with `0x18`. A replacement should keep this proven startup
and transport sequence, then implement its own action mapping and profile state.
It need not modify or load Huion's installed binary.

Bluetooth uses the vendor `FFE0` service: C9/C8 replies and 64-byte label
writes use `FFE2`, while 14-byte raw input notifications arrive on `FFE1` and
normalize into 12-byte K40 reports. The initial Bluetooth display test showed
wire slots top `[2, 4, 6, 8]`, bottom `[1, 3, 5, 7]`; the shared
`K40ButtonLayout` now maps row-major physical buttons through those slots.

## Evidence

- [Standalone capture analysis](protocol/standalone-results.md): 119 vendor reports after startup, with all control families represented.
- [OLED writes](evidence/screen-test/eight-labels.jsonl) and [physical confirmation](evidence/screen-test/eight-labels-visual.json).
- [Startup requests and responses](evidence/screen-test/control-mode-entry.jsonl).
- [Restoration record](evidence/screen-test/restoration.json).
- [Bluetooth capture and display analysis](protocol/bluetooth-results.md): 63 normalized input reports and eight physically confirmed labels.
- [Corrected layout confirmation](evidence/bluetooth/row-order-confirmation.json) and [Bluetooth restoration](evidence/bluetooth/restoration.json).
- [Wire protocol](protocol/K40_LABELS.md) and [startup inspection](protocol/initialization.md).

The unchanged Huion configuration hash is
`91c23d8312e39b915d0ee535666496b9ff290341523490ba1cac712ae068b5fe`.
Raw captures and the full local backup remain on disk under `evidence/`; they
are excluded from git where noted in `.gitignore`. No release or repository
publication was performed.
