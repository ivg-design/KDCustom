# Completed guided K40 USB input capture

Evidence: [`../evidence/capture-2026-09-22T23-35-12Z/events.jsonl`](../evidence/capture-2026-09-22T23-35-12Z/events.jsonl), SHA-256 `fbd0416e9c3a47620c2206c5cfa11931f31d2213c66ee66411e993756bcab65e`, reconciled with that session's `status.json`. The session began at `2026-09-22T23:36:10Z`, marked all 15 phases complete at `23:38:08Z`, and the capture app exited at `23:44:48Z`. These are passive raw-input observations while the installed Huion driver was still running. The closed session logged 150 JSONL rows: 112 report rows, 15 phase starts, 15 phase completions, one capture start/stop each, three device additions, one manager-open success, one session row, and one app-exit row.

Three USB HID interfaces reported vendor `0x256c`, product `0x2002`: keyboard `0001:0006`, vendor `ff00:0001`, and mouse `0001:0002`. All 112 captured reports came from the vendor interface, with callback report ID 8, length 12, and prefix `08`. There were **16 distinct raw report payloads** in the completed session: 75 `e0` control-state frames and 37 `f1` dial frames. A repeated payload is a repeated observed frame, not necessarily a new physical actuation.

## Per-phase observations

| Guided phase | Reports | Distinct nonzero signature (bytes 4–5 for E0; bytes 3 and 5 for F1) | Additional observation |
| --- | ---: | --- | --- |
| Button 1 | 4 | E0 `02 00` | Two matching press-state frames and two zero states |
| Button 2 | 5 | E0 `08 00` | Two press-state frames and three zero states |
| Button 3 | 4 | E0 `20 00` | Two press-state frames and two zero states |
| Button 4 | 4 | E0 `80 00` | Two press-state frames and two zero states |
| Button 5 | 4 | E0 `01 00` | Two press-state frames and two zero states |
| Button 6 | 4 | E0 `04 00` | Two press-state frames and two zero states |
| Button 7 | 4 | E0 `10 00` | Two press-state frames and two zero states |
| Button 8 | 4 | E0 `40 00` | Two press-state frames and two zero states |
| Inner clockwise | 9 | F1 dial ID `01`, direction `01` | Nine identical indications |
| Inner anticlockwise | 3 | F1 dial ID `01`, direction `02` | Three identical indications |
| Outer clockwise | 7 | F1 dial ID `02`, direction `01` | Seven identical indications |
| Outer anticlockwise | 9 | F1 dial ID `02`, direction `02` | Nine identical indications |
| Next group | 3 | E0 `00 20` | Two press-state frames with one zero frame between; no final zero frame in this phase |
| Previous group | 2 | E0 `00 10` | One press-state and one zero frame |
| Hold and chord | 46 | E0 `02 00`, `0a 00`, zero; F1 dial ID `02`, direction `01` | Full counts: 21 `02`, 13 `0a`, 3 zero, 9 F1. Repeated held states are expected snapshots. |

The button phases give eight distinct low-byte bits. The `0a` frame in the hold/chord phase is the combined state of guided buttons 1 and 2. The group-button masks are distinct high-byte bits (`0x2000` next, `0x1000` previous); they do not encode an observed group number. The hold/chord phase was instructed to turn the **inner** dial, but its nine F1 reports carry dial ID `02`, which matched the **outer** dial in the dedicated phases. That discrepancy remains unresolved: it may reflect which dial was turned during the mixed action, a labeling mistake, or another context effect. Do not use this mixed phase to revise the dedicated dial mapping.

The next-group phase has a second `0x2000` report only about 8 ms after its zero frame. Because no release follows it within that phase, the log does not establish a clean one-press/one-transition sequence or the resulting group index. No device-screen observation was stored in this session. `Sources/K40Decode.swift` preserves the full E0 mask and F1 dial ID/direction; its stateless snapshot interpretation handles the `0a` chord and repeated held-state frames without inventing extra press edges.

## Coverage boundary

- **Observed on USB:** all eight guided button positions produce distinct raw masks; both set buttons produce distinct masks; both dials produce distinguishable clockwise and anticlockwise F1 frames; a two-button mask occurs; the non-seizing manager opened successfully with all three interfaces.
- **Not established:** raw input after stepping through all six groups, group wraparound and group-name correspondence, OLED label writes/readback or visual screen mapping, behavior with Huion's driver stopped, USB disconnect/reconnect recovery, and Bluetooth identity/input/display transport. The initial group was not instrumented as an on-device value. The session's final status explicitly says `screenWrite: not_attempted`.
- **Precision limit:** this log counts device reports, not independently measured dial detents or decimal-value changes. Fast-turn phases yielded multiple unit-looking F1 frames, but no calibration against physical ticks or target application increments was performed. No Rive output was part of this capture.
