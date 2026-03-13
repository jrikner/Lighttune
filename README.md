# SekonicCalibrator

**Lighttune v0.1 — GrandMA3 Lua Plugin**

Calibrate fixture groups on your GrandMA3 console using measurements from a
**Sekonic C-7000 spectromaster**. Designed for TV and broadcast productions
where colour accuracy and consistency across groups is critical.

---

## Overview

The plugin walks you through a measurement-driven calibration workflow:

1. Select a fixture group
2. Enter your **target** colour temperature (Kelvin) and Duv
3. Enter the **measured** values from your Sekonic C-7000: CCT, Duv, CRI, R9
4. Review the quality assessment and calculated correction
5. Apply — the plugin sets the corrected chromaticity directly on the group
6. Repeat for the next group

The colour correction is applied as a precise CIE 1931 xyY chromaticity value
using GrandMA3's `SetColor` API. Fixtures that do not support xyY fall back
automatically to an HSB approximation.

---

## Requirements

- GrandMA3 console (software v1.6 or later recommended)
- Sekonic C-7000 spectromaster
- Fixture groups configured in your showfile
- Lua 5.4 (bundled with GrandMA3)

---

## Installation

1. Copy the entire `SekonicCalibrator/` folder into the GrandMA3 plugin
   library on your console or show computer:

   **Windows:**
   ```
   C:\ProgramData\MALightingTechnology\gma3_library\datapools\plugins\SekonicCalibrator\
   ```

   **macOS / Linux (show computer):**
   ```
   ~/MALightingTechnology/gma3_library/datapools/plugins/SekonicCalibrator/
   ```

2. On the GrandMA3 console, open the **Plugin Pool**:
   `Menu → Pools → Plugin`

3. Press **Import** and select `SekonicCalibrator`.

4. The plugin will appear in the Plugin Pool. Assign it to a macro key or
   executor for quick access.

5. To run: double-tap the plugin entry in the Plugin Pool, or execute via a
   macro with `Plugin "SekonicCalibrator"`.

---

## How to Take Measurements with the Sekonic C-7000

1. Set the meter to **Incident** mode (dome up).
2. Position the meter at the subject position, dome pointing toward the
   lighting grid.
3. Press **Measure**.
4. On the results screen, note:
   - **Tcp** — Correlated Colour Temperature (CCT) in Kelvin
   - **Δuv** — Deviation from the Planckian locus (shown as `Duv` or
     `Deviation`). Positive = green shift, negative = magenta shift.
   - **CRI Ra** — General Colour Rendering Index
   - **R9** — Deep red rendering (found under the extended CRI values R1–R15)

---

## Understanding the Readings

### CCT (Kelvin)
Correlated Colour Temperature. Describes how warm (low K) or cool (high K)
the white light appears.

| Value | Description |
|-------|-------------|
| 2700–3200 K | Tungsten / warm |
| 4000–4500 K | Fluorescent |
| 5500–5600 K | Daylight / HMI |
| 6000–6500 K | Overcast daylight |

### Duv (Δuv) — Green-Magenta Shift
Distance from the Planckian (black-body) locus in the CIE 1960 uv colour
space. Even two lights with identical CCT can look very different on camera
if their Duv values differ.

| Duv | Appearance |
|-----|------------|
| +0.006 to +0.020 | Visible green cast |
| −0.003 to +0.003 | Neutral / on-locus |
| −0.020 to −0.006 | Visible magenta cast |

### CRI (Ra) — Colour Rendering Index
How accurately the light renders a standard set of 8 test colours compared
to a reference source. Scale 0–100.

| CRI | Broadcast rating |
|-----|-----------------|
| ≥ 95 | Excellent — broadcast ready |
| 90–94 | Good — professional standard |
| 80–89 | Acceptable |
| < 80 | Poor — not recommended |

### R9 — Deep Red Rendering
A single-colour score for saturated red. Critical for skin tones, red
costumes, and props on camera. Often low on fixtures with high overall CRI.

| R9 | Broadcast rating |
|----|-----------------|
| ≥ 90 | Excellent |
| 80–89 | Good |
| 50–79 | Acceptable |
| < 50 | Poor — reds appear dull/brown on camera |

---

## Colour Math Notes

The plugin converts your CCT + Duv readings to a precise CIE 1931 xy
chromaticity point using the following method:

1. **CCT → Planckian locus xy** via the Kang et al. (2002) piecewise cubic
   approximation. Valid range: 1667 K – 25 000 K.

2. **Duv correction** — the target and measured points are each shifted off
   the Planckian locus by their respective Duv values in the CIE 1976 u'v'
   colour space (v' shift = Duv × 1.5, accounting for the 1960↔1976
   scaling). The resulting target xy is sent to `SetColor("xyY", …)`.

3. **HSB fallback** — if the fixture does not accept xyY, the xy chromaticity
   is converted via the IEC 61966-2-1 sRGB matrix (D65) to HSB and applied
   via `SetColor("HSB", …)`. Hue and saturation are preserved; brightness is
   left at full so the operator retains intensity control.

---

## Limitations

- CRI and R9 are quality indicators only — the plugin cannot improve a
  fixture's spectral output, only adjust its white point.
- The HSB fallback is an approximation; highly saturated chromaticities may
  be clamped.
- The Kang et al. approximation has ~2 K accuracy near range boundaries.
- One group is calibrated per run (loop through as many groups as needed).
- The plugin does not adjust fixture intensity (Y value).

---

## Running the Unit Tests

The `test_color_math.lua` file contains standalone Lua 5.4 tests for all
colour math functions. It does not require GrandMA3.

```bash
lua5.4 test_color_math.lua
```

Expected output: `52 passed, 0 failed`

---

## License

MIT — see [LICENSE](LICENSE) if present, otherwise free to use and modify.

---

## Project

Part of the [Lighttune](https://github.com/jrikner/Lighttune-0.1) project.
