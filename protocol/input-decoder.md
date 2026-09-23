# K40 USB and normalized Bluetooth input decoder

`Sources/K40Decode.swift` is a stateless parser for the observed wired K40 input report. Its fixture source is `evidence/capture-2026-09-22T23-35-12Z/events.jsonl`, snapshotted while the guided capture was in progress. The report callback supplied report ID 8 and 12-byte payloads beginning with `08`; all 80 reports present at the initial snapshot came from the vendor interface `ff00:0001`. Newer log rows may extend this evidence. The decoder does not read the device, switch groups, send a shortcut, or write to the OLED.

| Byte(s) | Observed interpretation | Boundary |
| --- | --- | --- |
| 0 | `08`, matching callback report ID 8 | Other prefix/length/report ID is invalid, with bytes retained |
| 1 | `e0` control state; `f1` dial turn | Other opcode is returned as unknown, with bytes retained |
| 2 | `01` in captured frames | Preserved as raw header, no assigned meaning |
| 3 | `01` on captured E0 frames; `01` inner and `02` outer on F1 frames | E0 byte 3 is **not proven a group index**; F1 dial identity follows guided labels |
| 4–7 on E0 | Little-endian 32-bit control-state bitmap | Whole mask is returned, including unknown high bits |
| 5 on F1 | `01` clockwise, `02` anticlockwise | Unknown values remain raw; each observed F1 frame counts as one indication |
| 8–11 | Zero in captured frames | Preserved as raw trailing bytes; no meaning assumed |

The eight guided button phases yielded a single low-byte bit for each physical position: button 1=`0x02`, 2=`0x08`, 3=`0x20`, 4=`0x80`, 5=`0x01`, 6=`0x04`, 7=`0x10`, 8=`0x40`. The hold/chord phase included `0x0a` for buttons 1 and 2 together, showing that an E0 frame is a state snapshot rather than a distinct button event. Set-button phases yielded `0x00002000` for next and `0x00001000` for previous. A zero mask after a press is the released state. The caller must compare consecutive masks if it needs press/release edges; repeated held-state frames must not be counted as new presses.

The installed driver's `ZTabletObj::Parse_E0_K40` at `0x100067124` loads a 32-bit word from input offset 4, scans set bits, and calls its key handler with a selected bit index. That read-only disassembly supports parsing bytes 4–7 as one bitmap. It does not establish the semantics of every bit. In particular, the capture's group-next and group-previous labels reflect the user's guided actions, while neither the packet nor the parser asserts the resulting group number.

The F1 fixtures were `08 f1 01 01 00 01 ...` / `... 02 ...` for inner clockwise/anticlockwise and `08 f1 01 02 00 01 ...` / `... 02 ...` for outer clockwise/anticlockwise. Fast turns generated multiple identical F1 frames, not a larger magnitude field in this capture. The parser offers `+1`/`-1` only for the observed dial ID and direction pairs. It preserves the full frame so later captures can revise this model.

`K40ButtonLayout` shares the physical ordering between input masks and OLED
labels: with dials left, physical buttons 1–4 are the top row and 5–8 the bottom
row. Their one-based hardware slots are `[2, 4, 6, 8, 1, 3, 5, 7]`.

Bluetooth input arrives on `FFE1`. The observed 14-byte notifications start
`55 54`; normalization copies offsets 1–12 and replaces the first byte with
report ID 8. Full original notifications remain in the log. The adapter rejects
short frames and other prefixes. All 63 input notifications from the completed
Bluetooth capture match this shape. BLE dial byte 6 differs from USB (01/ff
versus 00); it remains uninterpreted. See [Bluetooth results](bluetooth-results.md).

Run isolated fixtures without opening the device:

```sh
/Library/Developer/CommandLineTools/usr/bin/swiftc \
  -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk \
  Sources/K40ButtonLayout.swift Sources/K40Decode.swift Tests/DecodeTests.swift -o /tmp/k40-decode-tests
/tmp/k40-decode-tests
```

The fixture suite covers every button bit, a two-button chord, releases, both set buttons, all four dial directions, an unknown high mask, an unknown opcode/dial code, truncated input, a mismatched prefix, and a wrong report ID. This is parser validation only; it does not close full six-group behavior or OLED acceptance.
