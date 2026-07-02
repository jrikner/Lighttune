# SekonicCalibrator

**Lighttune v0.5.0-replan — GrandMA3 Lua Plugin**

Calibrate fixture groups on your GrandMA3 console using measurements from a
**Sekonic C-700, C-800, or C-7000 spectromaster**. Designed for TV and broadcast
productions where colour accuracy and consistency across groups is critical.

v0.5.0-replan adds a **Raspberry Pi HTTP bridge** so a C-7000 on stage can be
triggered from FOH over the show LAN. Manual meter entry remains available for
all supported meters.

---

## Overview

The plugin walks you through a measurement-driven calibration workflow:

1. Choose from the main menu: **Start Calibration**, **View Fixture History**, or **Bridge Status**
2. Choose your Sekonic meter model (C-700/C-800 or C-7000)
3. Set session goals once: target Kelvin, CRI / R9 / TLCI goals, calibration mode
4. Select a fixture group — make/model are read automatically from the MA3 patch
5. If historical data exists for the fixture, pre-apply the best known correction
6. Measure: enter Sekonic readings manually **or** trigger remote C-7000 via the Pi bridge
7. Review the quality assessment, correction, and feature-aware hints
8. Apply — the plugin sets the corrected chromaticity on the group
9. Re-measure and repeat until happy with the group
10. Move to the next group
11. End-of-session summary shows all groups and goal pass/fail

Calibration data is saved locally in `data/fixture_log.json`. Share the file
manually if you want to contribute fixture data to others.

---

## Features

| Feature | Description |
|---|---|
| **Two calibration modes** | Calibrate all groups to a set Kelvin target, or measure a reference group first and match everything else to it |
| **Sekonic C-700/C-800 support** | TLCI input/goals are automatically disabled for meters that don't provide TLCI |
| **Remote C-7000 measurement** | When `bridge_ip` is set, trigger the stage meter from FOH over HTTP (Pi bridge on show LAN) |
| **Manual meter fallback** | Always available when the bridge is offline or for C-700/C-800 |
| **Auto-loop calibration** | With bridge active, up to 3 apply/measure cycles until goals are met |
| **CRI / R9 / TLCI goals** | Track each metric individually — set a minimum threshold or "as high as possible" |
| **Conditional gel hints** | Gel suggestions only shown when the fixture has color-wheel filter slots, or when no Tint channel is available (physical gel is the only option), or when deviation is extreme (> ±0.020) |
| **Feature-aware console hints** | Fixture capabilities from the **MA3 Patch API** — Tint, CTB, CTO, and color wheel hints only when supported |
| **Fixture name from patch** | Make/model are auto-read from the MA3 patch for the selected group (manual fallback available) |
| **Patch manufacturer data** | Nominal CCT and CRI from FixtureType metadata (Patch API — no on-disk GDTF file access) |
| **Historical pre-fill** | Before the first measurement, if the fixture database contains prior data, the best known correction is pre-applied to the group |
| **Advanced Duv target** | Default 0.000 (neutral); optional custom Duv target for special production requirements |
| **Per-group inner loop** | Re-measure and re-apply as many times as needed before moving to the next group |
| **Session summary** | End-of-session table listing every group, its readings, Δ Kelvin, and goal pass/fail |
| **Fixture database** | Append-only: every measurement is kept; ★ marks the best CRI, R9, TLCI, and Duv entry per fixture/kelvin combination |
| **In-console history viewer** | Browse previous measurements directly from the plugin's main menu |
| **Bridge setup wizard** | Discover USB meter on Pi, verify protocol, optional trigger learning (from plugin main menu) |

---

## Requirements

- GrandMA3 console (software v1.6 or later recommended)
- Sekonic C-700, C-800, or C-7000 spectromaster
- Fixture groups configured in your showfile
- **Remote C-7000 (optional):** Raspberry Pi on the show LAN running `sekonic-bridge`, USB to C-7000, console and Pi reachable on the same network

---

## Installation

1. Copy the entire `SekonicCalibrator/` folder into the GrandMA3 plugin library:

   **Windows:**
   ```
   C:\ProgramData\MALightingTechnology\gma3_library\datapools\plugins\SekonicCalibrator\
   ```

   **macOS / Linux (show computer):**
   ```
   ~/MALightingTechnology/gma3_library/datapools/plugins/SekonicCalibrator/
   ```

2. In GrandMA3: `Menu → Plugin Pool → Import → SekonicCalibrator`

3. Assign to a macro key or executor, then run by double-tapping the plugin entry.

4. **Optional — remote C-7000:** Deploy `sekonic-bridge/` to a Raspberry Pi (see `sekonic-bridge/README.md`), then create `config.json` at the **plugin root** with `bridge_ip` and `bridge_port`.

---

## Configuration

Copy `data/config.json.example` to **`config.json` at the plugin root** (same
directory as `plugin.xml`, **not** inside `data/`):

```json
{
  "github_username": "your_github_username",
  "bridge_ip":       "192.168.1.50",
  "bridge_port":     8765
}
```

| Field | Purpose |
|---|---|
| `github_username` | Stored as `contributor` in `data/fixture_log.json` (optional) |
| `bridge_ip` | Pi bridge IP on show LAN — enables remote measure and auto-loop when set |
| `bridge_port` | Bridge HTTP port (default **8765** if omitted) |

`config.json` is gitignored and must never contain secrets committed to git.

Runtime data paths stay under `data/`:
- `data/fixture_log.json` — append-only fixture history
- `data/measurements/` — reserved for future use

---

## Remote Measurement (C-7000 + Pi Bridge)

When `bridge_ip` is configured:

1. Open the plugin → **Bridge Status** to verify connection
2. During calibration, choose **remote measure** when prompted (manual entry always available)
3. The plugin calls the Pi over **HTTP/1.0 (LuaSocket TCP)** — no HTTPS on GrandMA3
4. On failure: retry remote, enter values manually, or cancel

**Bridge setup commands** (`curl`, USB discovery) run on the **Pi terminal**, not on the GrandMA3 console. Example from the Pi:

```bash
curl http://localhost:8765/status
curl -X POST http://localhost:8765/measure
```

See `sekonic-bridge/README.md` for Pi deployment, mock mode (`--mock`), and USB setup.

---

## Calibration Modes

### Calibrate to Target
Standard mode. Set a target Kelvin (e.g., 5600K) and optionally a target Duv
(default 0.000). Every group is corrected to this fixed target.

### Match to Reference Group
Use when you have one fixture group that defines the "correct" look — for
example, existing HMIs or a fixed key light that can't be adjusted. The plugin
measures the reference group's CCT and Duv first, then uses those values as the
correction target for all other groups.

---

## Supported Sekonic Meters

| Model | CCT | Duv | CRI (Ra) | R9 | TLCI | Remote via bridge |
|---|---|---|---|---|---|---|
| C-700 | ✓ | ✓ | ✓ | ✓ | — | Manual entry only |
| C-800 | ✓ | ✓ | ✓ | ✓ | — | Manual entry only |
| C-7000 | ✓ | ✓ | ✓ | ✓ | ✓ | Pi bridge or manual |

Select your meter at the start of each session. The plugin automatically disables
TLCI input and goals when C-700 or C-800 is selected.

---

## How to Take Measurements with the Sekonic

1. Set the meter to **Incident** mode (dome up).
2. Position the meter at the subject position, dome toward the lighting grid.
3. Press **Measure**.
4. Note the following from the results screen:

   | Reading | Where on the meter | Description |
   |---|---|---|
   | **CCT (Tcp)** | Main display | Correlated Colour Temperature in Kelvin |
   | **Duv (Δuv)** | "Deviation" field | Distance from Planckian locus (+green / -magenta) |
   | **CRI Ra** | CRI screen | General Colour Rendering Index |
   | **R9** | CRI screen → R1–R15 | Deep red rendering value |
   | **TLCI** | TLCI/TLMF screen (C-7000 only) | Television Lighting Consistency Index |

For C-7000 with bridge configured, you can trigger measurement from the console
instead of typing values manually.

---

## Understanding the Readings

### CCT (Kelvin)
| Value | Description |
|---|---|
| 2700–3200 K | Tungsten / warm |
| 4000–4500 K | Fluorescent |
| 5500–5600 K | Daylight / HMI |
| 6000–6500 K | Overcast daylight |

### Duv — Green-Magenta Shift
| Duv | Appearance | Gel correction |
|---|---|---|
| > +0.016 | Strong green cast | Full Minus Green |
| +0.010 to +0.016 | Noticeable green | 1/2 Minus Green |
| +0.006 to +0.010 | Slight green | 1/4 Minus Green |
| +0.003 to +0.006 | Minor green tint | 1/8 Minus Green |
| −0.003 to +0.003 | Neutral (on-locus) | No correction needed |
| −0.006 to −0.003 | Minor magenta | 1/8 Plus Green |
| −0.010 to −0.006 | Slight magenta | 1/4 Plus Green |
| −0.016 to −0.010 | Noticeable magenta | 1/2 Plus Green |
| < −0.016 | Strong magenta cast | Full Plus Green |

Gel hints are only shown when:
- The fixture has colour-wheel filter slots (detected via Patch API), **or**
- The fixture has no Tint DMX channel (physical gel is the only correction option), **or**
- The Duv deviation exceeds ±0.020 (beyond the typical Tint channel range)

### CRI (Ra) — Colour Rendering Index

| CRI | Broadcast rating |
|---|---|
| ≥ 95 | Excellent — broadcast ready |
| 90–94 | Good — professional standard |
| 80–89 | Acceptable |
| < 80 | Poor — not recommended |

### R9 — Deep Red Rendering
Critical for skin tones, red costumes, and props on camera.

| R9 | Rating |
|---|---|
| ≥ 90 | Excellent |
| 80–89 | Good |
| 50–79 | Acceptable |
| < 50 | Poor — reds appear dull/brown on camera |

### TLCI — Television Lighting Consistency Index
Broadcast-camera-specific rating (EBU standard). More relevant than CRI for
3-chip video cameras. Available on Sekonic C-7000 only.

| TLCI | Rating |
|---|---|
| ≥ 90 | Excellent — television ready |
| 75–89 | Good — minimal correction needed |
| 50–74 | Acceptable — correction required |
| < 50 | Poor — not suitable for broadcast |

---

## Fixture Capability Detection

The plugin reads fixture colour capabilities directly from the **MA3 Patch API**
(`DataPool → Groups → FixtureType → DMXModes → DMXChannels → LogicalChannels`).
GrandMA3 already has GDTF attribute data parsed in memory — **no on-disk GDTF
file access** (and `io.popen` / shell commands are not available in GrandMA3
Lua).

Correction hints in the assessment screen are tailored to what the fixture can
actually do:

| Capability detected | Hint shown |
|---|---|
| `Tint` DMX attribute | Suggest adjusting Tint channel to correct Duv |
| `CTB` attribute | Suggest using CTB to reduce CCT |
| `CTO` attribute | Suggest using CTO to raise CCT |
| `ColorWheel` attribute | Suggest checking color wheel for correction filter slots |
| Manufacturer CCT / CRI on FixtureType | Shown as reference when entering measurements |

Gel hints (physical external filters) are always shown when no Tint channel is
available, and as a fallback option when a colour wheel is present.

---

## Fixture Database

After calibrating each group, the plugin saves a measurement record to:
```
SekonicCalibrator/data/fixture_log.json
```

### Schema

The database is **append-only**: every measurement is kept as a separate record.
Best-value flags (`best_cri`, `best_r9`, `best_tlci`, `best_duv`) are
recomputed after every new entry and mark which record holds the best value for
each metric within a given fixture + Kelvin combination:

```json
[
  {
    "make": "Aputure",
    "model": "600X Pro",
    "kelvin": 5600,
    "date": "2026-03-13",
    "contributor": "jrikner",
    "cct": 5572,
    "duv": 0.0030,
    "cri": 95,
    "r9": 88,
    "tlci": 91,
    "best_cri": true,
    "best_r9": true,
    "best_tlci": true,
    "best_duv": true
  }
]
```

**Rules:**
- Every measurement is always appended — nothing is overwritten
- `best_*` flags are omitted when false (only written when `true`)
- Records are sorted: make A→Z, then model A→Z, then kelvin low→high, then date old→new

---

## In-Console Fixture History Viewer

From the plugin's main menu, select **View Fixture History** to browse all
previously recorded measurements without starting a calibration session.

- Search by make or model name (partial match)
- Results are grouped by Kelvin, with ★ marking the best value for each metric
- Shows all historical entries so you can track how a fixture performs over time

---

## Colour Math Notes

- **CCT → xy** via Kang et al. (2002) piecewise cubic, valid 1667 K–25 000 K
- **Duv correction** by shifting v' in CIE 1976 u'v' space (Δv' = ΔDuv × 1.5)
- **SetColor** uses `"xyY"` for precision; falls back to `"HSB"` for fixtures
  that don't support the xyY colour model (brightness preserved at 1.0)

---

## Running the Unit Tests

Primary host test entry point:

```bash
lua5.4 tests/run.lua
```

Backward-compatible alias (delegates to `tests/run.lua`):

```bash
lua5.4 test_color_math.lua
```

Expected: **133+ passed, 0 failed** (ROADMAP minimum: 126+).

### Bridge route tests (mock meter, no USB)

```bash
python3 -m venv .venv
.venv/bin/pip install -r sekonic-bridge/requirements.txt -r sekonic-bridge/requirements-dev.txt
.venv/bin/pytest tests/test_bridge_routes.py -v
```

### Continuous integration

GitHub Actions workflow [`.github/workflows/ci.yml`](.github/workflows/ci.yml) runs both suites on push and pull request to `claude/lighttune-main` and `cursor/**` branches. No console, Pi hardware, or USB devices are required in CI.

---

## License

MIT — free to use and modify.

Part of the [Lighttune](https://github.com/jrikner/Lighttune-0.1) project.
