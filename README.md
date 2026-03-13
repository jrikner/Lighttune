# SekonicCalibrator

**Lighttune v0.3 — GrandMA3 Lua Plugin**

Calibrate fixture groups on your GrandMA3 console using measurements from a
**Sekonic C-700, C-800, or C-7000 spectromaster**. Designed for TV and broadcast
productions where colour accuracy and consistency across groups is critical.

---

## Overview

The plugin walks you through a measurement-driven calibration workflow:

1. Choose your Sekonic meter model (C-700/C-800 or C-7000)
2. Set session goals once: target Kelvin, CRI / R9 / TLCI goals, calibration mode
3. Select a fixture group — make/model are read automatically from the MA3 patch
4. Enter Sekonic readings (CCT, Duv, CRI, R9, and TLCI if C-7000)
5. Review the quality assessment, correction, and physical hints
6. Apply — the plugin sets the corrected chromaticity on the group
7. Re-measure and repeat until happy with the group
8. Move to the next group
9. End-of-session summary shows all groups and goal pass/fail

Calibration data is saved locally in a structured fixture database and
optionally uploaded to a per-user community file on GitHub.

---

## Features

| Feature | Description |
|---|---|
| **Two calibration modes** | Calibrate all groups to a set Kelvin target, or measure a reference group first and match everything else to it |
| **Sekonic C-700/C-800 support** | TLCI input/goals are automatically disabled for meters that don't provide TLCI |
| **CRI / R9 / TLCI goals** | Track each metric individually — set a minimum threshold or "as high as possible" |
| **Gel correction hints** | When Duv is off, the assessment suggests the correct filter (1/8 → Full Plus/Minus Green) |
| **Feature-aware console hints** | GDTF capabilities are read automatically — Tint channel, CTB, CTO, and color wheel corrections are only suggested when the fixture actually supports them |
| **Fixture name from patch** | Make/model are auto-read from the MA3 patch for the selected group (manual fallback available) |
| **Advanced Duv target** | Default 0.000 (neutral); optional custom Duv target for special production requirements |
| **Per-group inner loop** | Re-measure and re-apply as many times as needed before moving to the next group |
| **Session summary** | End-of-session table listing every group, its readings, Δ Kelvin, and goal pass/fail |
| **Fixture database** | Per-metric best-value upsert: each (make, model, kelvin) record stores the best CRI, R9, TLCI, and Duv ever measured — only updated when a new reading is better |
| **Community database** | Optionally upload your fixture data to a per-user JSON file on GitHub for community reference |

---

## Requirements

- GrandMA3 console (software v1.6 or later recommended)
- Sekonic C-700, C-800, or C-7000 spectromaster
- Fixture groups configured in your showfile
- `curl` available on the console OS (required for community upload only)
- `unzip` available (required for GDTF capability detection only)

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

| Model | CCT | Duv | CRI (Ra) | R9 | TLCI |
|---|---|---|---|---|---|
| C-700 | ✓ | ✓ | ✓ | ✓ | — |
| C-800 | ✓ | ✓ | ✓ | ✓ | — |
| C-7000 | ✓ | ✓ | ✓ | ✓ | ✓ |

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

## GDTF Capability Detection

When a fixture make/model is identified (from the MA3 patch or entered manually),
the plugin looks for a matching GDTF file in the GrandMA3 library:

```
~/MALightingTechnology/gma3_library/gdtf/
```

If found, the GDTF is read to detect which colour attributes the fixture
supports. Correction hints in the assessment screen are then tailored to what
the fixture can actually do:

| Capability detected | Hint shown |
|---|---|
| `Tint` DMX attribute | Suggest adjusting Tint channel to correct Duv |
| `CTB` attribute | Suggest using CTB to reduce CCT |
| `CTO` attribute | Suggest using CTO to raise CCT |
| Color wheel with correction slots | Suggest checking color wheel slots |

Gel hints (physical external filters) are always shown regardless of GDTF data.

---

## Fixture Database

After calibrating each group, the plugin saves a measurement record to the local
fixture database:
```
SekonicCalibrator/data/fixture_log.json
```

### Schema

Each record represents one fixture type at one tested Kelvin. Per-metric, only
the **best value ever measured** is kept (CRI/R9/TLCI: higher is better;
Duv: closer to zero is better):

```json
[
  {
    "make": "Aputure",
    "model": "600X Pro",
    "kelvin": 5600,
    "cri":  { "value": 95, "params": "5572K Duv:+0.0030", "date": "2026-03-13", "contributor": "jrikner" },
    "r9":   { "value": 88, "params": "5572K Duv:+0.0030", "date": "2026-03-13", "contributor": "jrikner" },
    "tlci": { "value": 91, "params": "5572K Duv:+0.0030", "date": "2026-03-13", "contributor": "jrikner" },
    "duv":  { "value": 0.003, "params": "5572K Duv:+0.0030", "date": "2026-03-13", "contributor": "jrikner" }
  }
]
```

**Upsert rules:**
- Same make + model + kelvin → only update a metric if the new value is better
- New kelvin for an existing fixture → add as a new record
- Local file is sorted: make A→Z, then model A→Z, then kelvin low→high

---

## Community Fixture Database

### Enabling GitHub Upload

1. Create a **GitHub personal access token** with `contents: write` permission:
   `https://github.com/settings/tokens`

2. Copy `data/config.json.example` to `data/config.json` in the plugin folder
   and fill in your details:
   ```json
   {
     "github_token":    "ghp_your_token_here",
     "github_username": "your_github_username"
   }
   ```

3. The plugin will upload each fixture record to your personal file under
   `data/community/{username}.json` in this repository.

Community files are sorted: GitHub usernames A→Z, then within each user's file:
make A→Z → model A→Z → kelvin low→high.

`config.json` is listed in `.gitignore` and will never be committed.

---

## Colour Math Notes

- **CCT → xy** via Kang et al. (2002) piecewise cubic, valid 1667 K–25 000 K
- **Duv correction** by shifting v' in CIE 1976 u'v' space (Δv' = ΔDuv × 1.5)
- **SetColor** uses `"xyY"` for precision; falls back to `"HSB"` for fixtures
  that don't support the xyY colour model (brightness preserved at 1.0)

---

## Running the Unit Tests

```bash
lua5.4 test_color_math.lua
```

Expected: `118 passed, 0 failed`

---

## License

MIT — free to use and modify.

Part of the [Lighttune](https://github.com/jrikner/Lighttune-0.1) project.
