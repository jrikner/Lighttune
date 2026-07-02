# Feature Landscape

**Domain:** Spectrometer-driven fixture white-point calibration on GrandMA3 for broadcast FOH  
**Project:** Lighttune (SekonicCalibrator) — brownfield replan v0.4 → v1 + Pi bridge  
**Researched:** 2026-07-01  
**Confidence:** HIGH for table stakes (validated in v0.4 + README); MEDIUM for differentiators (v0.5 experimental, not merged)

---

## Table Stakes

Features broadcast FOH crews expect. Missing any of these makes the tool feel incomplete or untrustworthy for TV/live production.

### Calibration workflow

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| **Session goals set once** | Operators calibrate many groups per session; repeating targets wastes time | Low | Target Kelvin, Duv default 0.000, CRI/R9/TLCI thresholds — collected at session start (v0.4) |
| **Two calibration modes** | Broadcast shows mix fixed daylight targets and “match the key” workflows | Med | **Calibrate to target** (e.g. 5600 K) and **Match to reference group** (measure reference first, apply to all others) — v0.4 validated |
| **Per-group inner loop** | White point drifts with gel, dimming, and LED thermal state; one shot is rarely enough | Low | Re-measure → assess → apply until operator accepts group before advancing — v0.4 |
| **Group selection from patch** | FOH thinks in MA3 groups, not DMX addresses | Low | `Cmd('Group …')` + patch-derived make/model — v0.4 |
| **Apply correction on console** | Calibration must land in the showfile, not a sidecar spreadsheet | Med | `SetColor("xyY")` with HSB fallback for fixtures without xyY — v0.4 |
| **Session summary with pass/fail** | LD needs audit trail before going to air | Low | End table: each group, readings, Δ Kelvin, goal met/not met — v0.4 |
| **Incident measurement guidance** | Wrong meter technique invalidates every reading | Low | Dome-up, subject position — documented in README; optional in-plugin reminder is table stakes for first-time users |
| **Cancel / skip group without corrupting session** | Shows run on time; stuck groups cannot block the rig | Low | Skip or accept-with-warning paths — v0.4 `ask_group_done` pattern |

### Meter integration

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| **Sekonic C-700 / C-800 / C-7000 support** | Dominant handheld spectromasters on broadcast stages | Med | Model picker at session start; TLCI auto-disabled for C-700/C-800 — v0.4 |
| **Manual measurement entry (always)** | Bridge fails, wrong VLAN, dead Pi, or operator preference | Low | CCT, Duv, CRI, R9, TLCI (C-7000 only) via MessageBox — v0.4; **must remain** when v1 adds remote path (PROJECT.md) |
| **Meter-appropriate field set** | Showing TLCI goals on a C-700 insults operator trust | Low | Conditional TLCI input/goals by `METER_C700` vs `METER_C7000` — v0.4 |
| **Reading validation / clamping** | Garbage in → wrong `SetColor` on air | Low | CCT 1667–25000 K, Duv ±0.02, CRI/R9 0–100 — v0.4 constants |
| **Remote trigger from FOH (v1)** | Typing six numbers per attempt at the desk is unacceptable for C-7000 shows | High | Pi bridge `POST /measure` → JSON; manual fallback on timeout/error — v0.5 experimental, v1 active requirement |

### Fixture DB

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| **Local append-only fixture log** | Shows revisit same fixtures across weeks; history is operational data | Med | `fixture_log.json` per make/model/kelvin — v0.4 |
| **Best-value flags per metric** | Operators need “what worked best last time,” not raw log noise | Med | `best_cri`, `best_r9`, `best_tlci`, `best_duv` recomputed after each append — v0.4 |
| **Contributor label** | Multi-operator shops need provenance | Low | `config.json` → `github_username` or `"local"` — v0.4 |
| **In-console history viewer** | Lookup without starting a calibration session | Med | Search by make/model, ★ on bests — v0.4 main menu |
| **Local JSON export only** | Data leaves the console via file copy, not network APIs MA3 cannot do | Low | Plain JSON shareable manually — aligns with PROJECT.md out-of-scope |

### Operator UX

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| **Main menu: calibrate vs history** | Two distinct operator intents | Low | v0.4 |
| **Auto make/model from patch** | Eliminates typo-driven DB fragmentation | Low | MA3 Patch API; manual fallback when patch incomplete — v0.4 |
| **Feature-aware correction hints** | “Adjust Tint” on a fixture with no Tint channel wastes time on air | Med | Tint, CTB, CTO, ColorWheel from `DataPool → Groups → FixtureType → DMXModes` — v0.4 |
| **Conditional gel hints** | Physical gel is last resort but real on broadcast rigs | Med | Only when color wheel slots, no Tint channel, or \|Duv\| > 0.020 — v0.4 |
| **Quality assessment screen before apply** | Operator must see delta and ratings before committing | Med | `show_assessment()` with pass/fail per metric — v0.4 |
| **GDTF nominal CCT/CRI as context** | Compares measurement to manufacturer claim at a glance | Low | From FixtureType when available — v0.4 (in-memory patch, not disk GDTF) |
| **Advanced Duv target** | Some productions intentionally off-locus | Low | Default 0.000; optional custom — v0.4 |
| **Clear bridge status (v1)** | Remote path fails silently → operators revert to typing | Med | Bridge Status menu, connectivity, setup flags — v0.5 experimental |

### Bridge / Pi (v1 table stakes for C-7000 remote path)

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| **HTTP on trusted show LAN** | MA3 has no HTTPS; Pi is the network adapter for USB meter | High | FastAPI `:8765`, LuaSocket HTTP/1.0 — architecture validated on experimental branch |
| **C-7000 USB driver on Pi** | v1 topology is meter-on-stage, console-at-FOH | High | pyusb bulk protocol (`RT1`/`RM0`/`ST`/`NR`/`RT0`) — sekonic-bridge |
| **`/status` health endpoint** | Pre-flight before going group-by-group | Low | connected, device_configured, last_error — v0.5 |
| **Setup / discovery on Pi** | USB enumeration differs per rig | Med | `GET /discover`, `POST /capture`; C-7000 skips HID trigger learn — v0.5 |
| **Mock meter for dev** | Cannot block plugin work on every laptop without hardware | Low | `server.py --mock` — v0.5 |
| **Concurrent measure rejection** | Two operators triggering one meter causes bad reads | Low | HTTP 409 + asyncio lock — v0.5 |
| **Retry / manual fallback on bridge error** | Show must continue when Pi reboots | Med | MessageBox: retry, enter manually, cancel — v0.5 pattern |
| **`config.json` bridge_ip / bridge_port** | Static show-network addressing is normal on VLAN | Low | Default port 8765 — v0.5 |

### Quality metrics (CCT / Duv / CRI / R9 / TLCI)

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| **CCT as primary white-point axis** | Broadcast standard language is Kelvin (3200 tungsten, 5600 daylight) | Low | Kang et al. 2002 → xy; goal typically ±150 K in auto-loop (v0.5) |
| **Duv (Δuv) green–magenta** | Camera sees green/magenta shift CCT alone misses | Low | u′v′ correction; gel hint thresholds aligned to README bands — v0.4 |
| **Per-metric goals: min or maximize** | Rigs differ: some chase max R9, others need only floor | Med | `GOAL_MIN` / `GOAL_MAX` / `GOAL_SKIP` per CRI, R9, TLCI — v0.4 |
| **Broadcast-aligned rating bands** | Operators need shared vocabulary with README/EBU | Low | CRI ≥95 excellent / ≥90 good; R9 ≥90/80/50; TLCI ≥90/75/50 — v0.4 `QUALITY` constants |
| **TLCI on C-7000** | EBU R137 / Tech 3355: CRI alone is insufficient for camera workflows | Med | Session goal + assessment; disabled for C-700/C-800 — v0.4 |
| **R9 tracked separately from CRI** | High Ra can hide poor reds (skin, costumes) — NHK/SMPTE broadcast guidance | Low | Dedicated goal and rating — v0.4; default goal prompt 80 for R9 |
| **Chromatic correction independent of spectral goals** | xyY fixes white point; CRI/R9/TLCI are measured quality, not DMX parameters | Med | Correction from CCT+Duv; spectral metrics gate “accept group” — v0.4 design |

---

## Differentiators

Features that set Lighttune apart from “spreadsheet + manual SetColor” or generic MA3 emitter editing. Not universally expected, but drive the **<5 minute per group** core value (PROJECT.md).

| Feature | Value Proposition | Complexity | Notes |
|---------|-------------------|------------|-------|
| **Remote measure from FOH** | Operator at desk triggers stage meter; zero walk-out per iteration | High | Pi bridge + LuaSocket client; v0.5 experimental → v1 deliverable |
| **Auto-loop after remote measure** | CCT/Duv converge without re-prompting mode or re-typing | Med | Attempt 1: remote/manual choice; attempts 2+: auto `bridge_fetch_measurement`; `goals_met()` drives exit; max 3 cycles then Accept/Try Again/Skip — v0.5 |
| **History pre-fill before first measure** | Best-known correction applied immediately; first reading starts closer to target | Med | `recompute_best_flags()` + pre-apply on group entry — v0.4 validated |
| **Integrated broadcast workflow in one plugin** | vs. GDTF Builder emitter editing (per-LED, per-DMX curve) — different problem, but Lighttune wins on **group white balance during prep** | Med | MA3 forum default is emitter-level GDTF work; Lighttune is session-oriented group calibration |
| **Session-level spectral goals with pass/fail** | vs. meter-only logging apps with no console apply | Med | v0.4 |
| **Bridge setup wizard from console** | Reduces Pi-side SSH for lighting crews | Med | Discover/capture/learn from plugin — v0.5 |
| **Mock-improving readings for training** | Rehearse auto-loop without C-7000 on site | Low | v0.5 `MockMeter` |

**Defer (not differentiators for v1):** TLMF mixed-source matching (EBU), TM-30 Rf/Rg, flicker/PWM analysis, multi-meter fleets, native Sekonic HTTP (research only).

---

## Anti-Features

Features to explicitly **not** build — they fail on MA3, mislead operators, or conflict with broadcast ops reality.

| Anti-Feature | Why Avoid | What to Do Instead |
|--------------|-----------|-------------------|
| **HTTPS / TLS from GrandMA3 plugin** | MA3 Lua runtime does not support HTTPS; fighting the platform blocks ship | Plain HTTP to Pi on private show VLAN; document trust boundary (PROJECT.md out-of-scope) |
| **Automatic GitHub / community upload from console** | No HTTPS; `curl` dependency fragile; show IT blocks outbound git | Local `fixture_log.json` only; manual PR/issue with file export (PROJECT.md; remove false README claims in v1) |
| **`io.popen` / `os.execute` / shell HTTP** | Unavailable or unreliable in MA3 sandbox | LuaSocket TCP + hand-built HTTP/1.0 (v0.5 Section 2c) |
| **Reading GDTF files from disk via shell** | `unzip`/`io.popen` not viable on console | MA3 Patch API in-memory GDTF attributes — v0.4 approach |
| **Emitter-level per-LED calibration inside plugin** | Scope explosion; MA3 GDTF Builder is the right tool for SPD/emitter curves | Stay focused on **group xyY white balance** from integrated readings |
| **Forcing remote-only when bridge configured** | Pi/Wi-Fi/USB failures are routine on load-in | Always offer manual entry; remote is default path, not exclusive |
| **Unbounded auto-loop** | Runaway DMX changes during live prep | Cap cycles (v0.5: 3), then operator decision |
| **TLS or OAuth on bridge** | Adds ops burden; lighting VLAN is physically controlled | Bind to show LAN; no secrets in git; `config.json` local |
| **iOS USB direct to C-7000** | Wrong platform and support surface | WebRemote + plugin at FOH (PROJECT.md out-of-scope) |
| **Replacing spectrometer with colorimeter-only path** | Colorimeters miss LED SPD quirks; broadcast expects spectrometer readings | Sekonic spectromaster family only |
| **Silent failure on bridge timeout** | Operators assume rig is calibrated when it is not | Explicit error UX: retry / manual / cancel |
| **Overwrite fixture history** | Destroys audit trail for “what changed since last week” | Append-only + best flags — v0.4 |

---

## Feature Dependencies

```
Meter model selection → TLCI fields enabled/disabled
Session goals (Kelvin, Duv, CRI/R9/TLCI) → goals_met() / assessment / session summary
Patch group + make/model → fixture DB key (make, model, kelvin)
Fixture DB best flags → history pre-fill on group entry
bridge_ip in config → remote measure option → auto-loop (remote mode only)
Reference mode → reference group measurement → target CCT/Duv for all other groups
Remote measure → Pi bridge running + C-7000 USB → POST /measure
Manual fallback → independent of bridge (always available)
```

---

## MVP Recommendation (v1 broadcast FOH)

**Ship table stakes from v0.4 unchanged**, plus **three differentiators**:

1. Remote C-7000 measure from plugin (Pi bridge)
2. Auto-loop when in remote mode and goals not met
3. History pre-fill (already in v0.4 — keep prominent in default path)

**Prioritize in phase order:**

1. Calibration workflow + quality metrics + manual meter path (v0.4 baseline, modularized)
2. Fixture DB + history viewer + pre-fill
3. Bridge/Pi + remote measure + status/setup UX
4. Auto-loop tied to `goals_met()` thresholds

**Defer:**

- Community auto-upload and any cloud sync
- Native Sekonic HTTP (topology research only)
- TM-30 / TLMF / flicker metrics
- HTTPS anywhere on the MA3 ↔ meter path

**Success criterion:** Operator at FOH calibrates a fixture group in **under five minutes** with **minimal typing**, hitting **broadcast-grade** CCT/Duv and optional CRI/R9/TLCI floors — without sacrificing accuracy for speed (PROJECT.md core value).

---

## Sources

| Source | Confidence | Used for |
|--------|------------|----------|
| `.planning/PROJECT.md`, `README.md`, `.planning/codebase/ARCHITECTURE.md` | HIGH | Validated v0.4 features, v1 scope, anti-features, bridge topology |
| `lua/SekonicCalibrator.lua` (v0.4 in tree) | HIGH | Quality bands, goals, modes, DB schema |
| EBU Tech 3355 / R137 (TLCI-2012, TLMF-2013) | HIGH | TLCI rationale vs CRI for television |
| MA Lighting Forum — color calibration / emitter threads | MEDIUM | Ecosystem context (emitter vs group calibration) |
| Broadcast procurement guides (CRI/R9/TLCI floors) | MEDIUM | Metric threshold table stakes alignment with README |
