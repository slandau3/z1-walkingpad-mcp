# WalkingPad Z1 — BLE Wire Protocol Specification

Authoritative spec for the KingSmith WalkingPad Z1 (BLE name `KS-HD-Z1D`,
firmware V0.0.6), verified on hardware 2026-07-30. Both implementations in
this repo — the Python core (`src/z1_walkingpad_mcp/`) and the macOS app
(`macos/`) — follow this document. If they disagree with it, the document
wins (it is what the pad does).

Derived from the [duttke.de Web Bluetooth implementation](https://www.duttke.de/en/walkingpad/)
and from blutter disassembly of the KS Fit Android app (v5.9.10 / v6.0.7).
See `docs/reverse-engineering.md` for how this was figured out.

## The unlock gate (read this first)

The Z1 speaks standard Bluetooth SIG **FTMS** (Fitness Machine Service,
`0x1826`) for control and telemetry — but **everything is gated behind a
vendor unlock handshake** on the KingSmith supplement service. Until the
unlock frame lands:

- every FTMS Control Point (`0x2AD9`) write is silently ignored (write acks,
  no indication, no action), and
- the pad emits **zero** notifications on any characteristic.

After the pad answers `71 80`, FTMS behaves like the textbook spec and
notifications flow. There is no bonding, no pairing, no MTU requirement —
the name-derived unlock token is the entire auth mechanism. (The KS Fit app
is explicitly anti-pairing: its troubleshooting text tells users to *unpair*
the treadmill from the OS Bluetooth settings.)

## GATT map

| UUID | Props | Purpose |
|---|---|---|
| `00001826-…` (FTMS) | service | standard fitness machine service |
| `00002acc-…` | read | fitness machine features |
| `00002ad4-…` | read | supported speed range (u16 LE ×2, km/h×100) → **1.6–6.4 km/h** |
| `00002acd-…` | notify | treadmill data (telemetry) |
| `00002ada-…` | notify | fitness machine status (04 started, 02 stopped, …) |
| `00002ad9-…` | write, indicate | **FTMS control point** (start/stop/speed) |
| `24e2521c-f63b-48ed-85be-c5330a00fdf7` | service | KingSmith supplement service |
| `24e2521c-…-c5330b00fdf7` | notify | supplement **read** channel |
| `24e2521c-…-c5330d00fdf7` | write, write-no-rsp | supplement **write** channel |
| `0000180a-…` + `00002a2*-…` | read | device information (firmware `V0.0.6`) |
| `0xFFC0`/`0xFFF0`, `0xFF00` | — | JieLi-chip OTA, **do not touch** |

## Supplement (vendor) channel

Frame format, both directions:

```
[cmd0, cmd1, len, data[len], checksum]     checksum = sum(all prior bytes) & 0xFF
```

Rules:

- All writes go to `…d00fdf7` as **write without response**. (Some firmware
  silently drops write-with-response on this characteristic.)
- **Subscribe to `…b00fdf7` notifications before writing anything.**
- Pace vendor writes **≥ 400 ms** apart; faster writes are dropped.
- Responses are awaited on the notify characteristic, ~3 s timeout.
- Never send frames starting with `0xE8` (OTA mode — brick risk).

### Unlock

```
send:  71 00 05 01 <T0 T1 T2 T3> CC
reply: 71 80 00 CC                       (success; cmd1=0x80)
```

`T` = unlock code, little-endian u32 = `LE32(last 4 chars of BLE name) + 1`.
For `KS-HD-Z1D`: last4 = `-Z1D` = bytes `2D 5A 31 44` → `LE32 = 0x44315A2D`
→ `+1 = 0x44315A2E` → LE bytes `2E 5A 31 44`:

```
71 00 05 01 2e 5a 31 44 74
```

The unlock write is fire-and-forget: success arrives as the `71 80`
notification (allow ~10 s; in practice it answers in <100 ms). The KS Fit
app uses a different request frame for the same handshake
(`E2 00 0A RR <BE32(name[-4:])+RR as LE> CC`, RR random) and gets the same
`71 80` reply; firmware V0.0.6 is confirmed to accept the `0x71` form, which
is what both implementations here use.

### After unlock: session init

1. **SYS_INFO** — `71 01 08 <unix-time LE32> <user-id LE32=0> CC` →
   reply `71 81`, data: protocol version u16, model u16, caps u32
   (Z1: proto 3, caps `0x10f`).
2. **SETTING_GET (all)** — `72 00 01 00 73` → reply `72 80`, data is 4-byte
   records `[propId, error, valLo, valHi]` (value u16 LE; skip `error != 0`).
3. Optionally **FUNC_INFO** — `75 00 00 75` → reply `75 80` (method bitmaps).

The pad works even if these post-unlock exchanges are skipped — but the KS
Fit app performs them, and the property dump is useful (see below).

### Properties observed on the Z1

| ID | Meaning | Notes |
|---|---|---|
| 1 | units / screen language | `0x0003` on our unit |
| 2 | auto-stop | bit15 enabled, low bits seconds |
| 4 | motor version | `5` |
| 5 | last device error | `0` = no error |
| 6 | child lock | `0` = off |
| 8 | switches | bit1 buzzer, bit3 interaction light |
| 10 | device mode | bits 5–7: 0=manual 1=auto 2=sleep |

Property write: `72 01 03 <id> <lo> <hi> CC` → reply `72 81`, `data[1]=0` OK.
Unsolicited property pushes arrive as `72 50` with 3-byte records
`[id, lo, hi]`. Exercise-record events arrive as `73 50` (on start/stop),
fault records as `73 51`.

**Not exposed by this firmware:** display/panel configuration (the LED
screen cycling is RF-remote only), heart rate (no sensor), calories (no
energy bit in telemetry — compute locally, see below), incline (fixed).

## FTMS control (post-unlock)

Control point `0x2AD9`, write **with** response, pace ≥ 400 ms. Every command
answers an indication `[0x80, request-op, result, params…]`:

| result | meaning |
|---|---|
| 1 | success |
| 2 | op not supported |
| 3 | invalid parameter |
| 4 | failed |
| 5 | control not permitted → re-send `0x00` and retry once |

Commands:

| op | bytes | effect |
|---|---|---|
| Request Control | `00` | required once before any command |
| Start/Resume | `07` | belt ramps to minimum speed (1.6 km/h) |
| Stop/Pause | `08 01` stop · `08 02` pause | |
| Set Target Speed | `02 <u16 LE, km/h×100>` | e.g. 2.5 km/h = `02 fa 00` |
| Reset | `01` | |

Typical session: `00` → `07` → `02 …` (any number of times) → `08 01`.

## Vendor control tunnel (0x77) — alternative control path

The supplement channel can also carry belt commands (used as a fallback by
the duttke.de implementation when the control point fails). Frame
`77 01 <len> <op> <params…> CC` → reply `77 81`, `data[0]` = op, `data[1]` =
status (0 or 0x81 = OK). Ops mirror FTMS:

| command | frame |
|---|---|
| start | `77 01 01 07 7F` |
| stop | `77 01 02 08 01 82` (note: param 1 here vs 2 on FTMS) |
| set speed | `77 01 03 02 <u16 LE km/h×100> CC` |

Not needed on the Z1 (FTMS control point works post-unlock) but part of the
known protocol surface.

## Machine status (`0x2ADA`, notify)

`04` started · `02` user stop/pause · `01` safety-key stop · `05` speed
changed · `0xFF` control lost. Useful for belt state when no treadmill-data
frames flow (belt fully stopped).

## Telemetry (`0x2ACD`)

Standard FTMS treadmill data: flags u16 LE, then fields in flag order.
Observed on the Z1: flags `0x2404` = distance + elapsed time + steps, plus
instantaneous speed (flag bit 0 clear).

| flag bit | field | format |
|---|---|---|
| 0 (clear) | instantaneous speed | u16, km/h×100 |
| 2 | total distance | u24, meters |
| 10 | elapsed time | u16, seconds |
| **13** | **step count** | u16 — **KingSmith extension** |

Frames arrive ~1/second while the belt runs. Distance/steps accumulate
under load (walking). Counters persist across BLE connections while the
pad's session is open, and reset when the pad finalizes a session (Stop)
or on its own schedule — clients display them as-is (pad-as-master).

**Step accuracy note:** the pad's step counter (belt/motor dynamics) is the
canonical step source. Both clients relay the raw pad step counter exactly as
reported — for live status, session summaries, persistence, and exports — so
the UI stays responsive and totals always match the pad. No client-side
estimation or correction is applied to any step total. Distance and elapsed
time are likewise exact and used as-is.

## Calories (computed locally)

The pad reports no energy data. We estimate with the **ACSM walking
metabolic equation** (level grade), the exercise-physiology standard:

```
VO2 (ml/kg/min) = 0.1 × speed(m/min) + 3.5
kcal/min        = VO2 × weight_kg / 200        (5 kcal per L O2)
```

Continuous in speed — no bucket interpolation. Best validated around
3–6 km/h; classic validation error is ~2.0–2.6 ml/kg/min and a 2021 field
study found ~13% overprediction for unloaded walking — treat the number as
±10–15%. Chosen over the Compendium MET table because research shows the
fixed MET buckets misclassify intensity at exactly these slow speeds
(PubMed 35876127, 2022). Weight defaults to 75 kg (`Z1_WEIGHT_KG` in
Python, in-app setting on macOS).
