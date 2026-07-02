# Project Research Summary

**Project:** Lighttune (SekonicCalibrator)  
**Domain:** Spectrometer-driven fixture white-point calibration on GrandMA3 for broadcast FOH  
**Researched:** 2026-07-01  
**Confidence:** HIGH

## Executive Summary

Lighttune is a **dual-runtime broadcast calibration tool**: a GrandMA3 Lua plugin at FOH orchestrates group white-balance sessions, and a Raspberry Pi HTTP bridge on stage reads a Sekonic C-7000 over USB bulk. Experts build this class of product by **respecting MA3 platform limits** (Lua 5.4 only, LuaSocket TCP with hand-built HTTP/1.0, no HTTPS, blocking UI coroutines) and **keeping a strict domain boundary** at the measurement record `{ cct, duv, cri, r9, tlci? }` between console and bridge.

The recommended approach is **not a technology pivot** but a clean-architecture replan of proven brownfield prototypes (`sekonic-remote-api-research` + `Lighttune-experimental`): modularize the monolithic Lua plugin, retain FastAPI/pyusb on the Pi, ship v0.4 table-stakes workflow unchanged, and add v1 differentiators—remote C-7000 measure, auto-loop, and history pre-fill. The Pi bridge returns raw meter fields only; all color math, goals, fixture DB, and `SetColor` apply stay on the console.

Key risks are **branch/doc drift**, **monolithic untestable Lua**, **regex JSON fragility**, **assumed closed-loop correction that is not implemented**, **HID-vs-bulk naming confusion**, and **MA3 blocking sockets freezing the UI for up to ~38s per measure**. Mitigate with a single canonical merge (P1), domain module extraction with host tests (P2–P3), bulk-first bridge setup (P4), honest UX and network runbooks (P5–P6), and mandatory real MA3 + C-7000 UAT (P7).

## Key Findings

### Recommended Stack

Retain the validated dual-runtime stack: **Lua 5.4 + GrandMA3 Object API** on console, **LuaSocket raw HTTP/1.0** for bridge calls, **Python 3.12 + FastAPI 0.115 + uvicorn 0.32 + pyusb 1.3.1** on Raspberry Pi OS Lite (Bookworm) with systemd. Do not adopt HTTPS from plugin, `io.popen`/`curl`, `socket.http`, Flask, Docker on Pi, or native Sekonic HTTP for v1.

**Core technologies:**
- **Lua 5.4 + MA3 API (GMA3 1.6+):** All FOH orchestration, UI, patch introspection, `SetColor` — only supported plugin runtime; v0.4 math and UX already validated.
- **LuaSocket (`require("socket")`) + HTTP/1.0 over TCP:** Console→bridge transport — only viable HTTP path on MA3; proven `_http_request` pattern with explicit timeouts (5s status, 38s measure).
- **FastAPI + uvicorn + pyusb on Pi:** Async REST on `:8765`, `asyncio.Lock` on `/measure`, USB bulk C-7000 protocol (skreader-derived RT1/RM0/ST/NR/RT0).
- **Host test harness:** `lua5.4` for pure Lua modules (126+ color-math assertions) + **pytest/httpx** for bridge routes; `meter_mock` for dev without hardware.

See [STACK.md](./STACK.md) for pinned versions, config files, and anti-stack choices.

### Expected Features

**Must have (table stakes):**
- **Session goals + two calibration modes** (target Kelvin vs match reference group) — broadcast FOH standard workflow.
- **Per-group inner loop** with assessment, apply via `SetColor("xyY")`, session pass/fail summary — calibration must land in the showfile.
- **Manual meter entry always** (C-700/C-800/C-7000) — bridge failures cannot block the show.
- **Local append-only fixture log** with best-value flags, history viewer, patch-derived make/model — operational memory across weeks.
- **Quality metrics** (CCT, Duv, CRI, R9, TLCI on C-7000) with broadcast rating bands and per-metric goals — shared vocabulary with README/EBU.
- **Remote C-7000 measure + bridge status/setup (v1)** — typing six numbers per attempt at FOH is unacceptable; HTTP on trusted show LAN with retry/manual fallback.

**Should have (competitive):**
- **Auto-loop after remote measure** — converge readings without re-prompting; cap at 3 cycles then operator decision.
- **History pre-fill on group entry** — start closer to target using `recompute_best_flags()`.
- **Bridge setup wizard from console** — discover + test measure; no SSH for lighting crews.
- **Mock-improving readings** — rehearse auto-loop without C-7000 on site.

**Defer (v2+):**
- Community/cloud auto-upload, native Sekonic device HTTP, TM-30/TLMF/flicker, multi-meter fleets, HTTPS anywhere on MA3↔meter path, emitter-level per-LED calibration.

See [FEATURES.md](./FEATURES.md) for full table stakes matrix and anti-features.

### Architecture Approach

Two deployable artifacts with **MeasurementRecord JSON** as the sole cross-component contract. Lua plugin owns calibration orchestration, color math, fixture DB, and MA3 apply; Pi bridge owns USB meter I/O only. Split monolith into domain (`color_math`, `fixture_db`, `goals`), transport (`bridge_client`), integration (`patch_api`, `fixture_apply`), presentation (`ui/*`), and thin `main.lua`. Bridge refactor to `api/`, `meter/` (rename `c7000_bulk`), mock parity with `--mock-realistic`.

**Major components:**
1. **GrandMA3 Lua plugin** — session/auto-loop orchestration, goals_met, fixture_log, operator UX, LuaSocket client.
2. **sekonic-bridge (FastAPI)** — `/status`, `/measure`, `/discover`, `/capture`; MeterBackend protocol; device_config on Pi.
3. **Host + hardware test seams** — lua5.4 pure-module tests, pytest for routes/mock, console checklist, Pi+C-7000 E2E.

**Build order (architecture):** (1) canonical branch → (2) domain modules + tests → (3) config path fix → (4) bridge_client extract → (5) Python bridge cleanup (parallel) → (6) UI/calibration split → (7) Pi deploy + E2E → (8) closed-loop `get_correction` fix.

See [ARCHITECTURE.md](./ARCHITECTURE.md) for module layout, API contract, and sequence diagrams.

### Critical Pitfalls

1. **Experimental branch drift** — Two Sekonic snapshots with conflicting HID wizard, README, and drivers; pick one canonical merge with plugin.xml/README aligned. *(P1)*
2. **Monolithic plugin + duplicated tests** — ~2k-line file and copy-paste `test_color_math.lua` cause silent drift; extract require-able modules first. *(P2, P3)*
3. **Regex JSON parsing** — Fixture DB and bridge responses break on edge cases; centralize parsers with golden fixtures and operator-visible errors. *(P2, P3, P5)*
4. **Closed-loop calibration not implemented** — Auto-loop re-measures but `get_correction` ignores measured gap; document honestly or fix domain math before marketing convergence. *(P2, P6, P7)*
5. **HID naming vs USB bulk** — `meter_c7000_hid.py` and `/learn_trigger` waste operator time; rename to bulk, wizard = discover + test measure for VID `0x0A41`. *(P4)*
6. **MA3 blocking LuaSocket** — 38s `/measure` freezes UI coroutine; document, cap auto-loop, probe `socket.tcp` on target console. *(P5, P7)*
7. **Unauthenticated bridge on show LAN** — `0.0.0.0:8765` spoofing risk; VLAN/firewall, optional HMAC, operator confirmation before accept. *(P4, P5, P6)*
8. **USB protocol fragility** — skreader-derived, no hot-plug recovery, TLCI FW-dependent; pin Pi OS, golden NR fixtures, reconnect on failure. *(P4, P7)*

See [PITFALLS.md](./PITFALLS.md) for operator error paths, merge strategy traps, and phase-specific warnings.

## Implications for Roadmap

Based on research, suggested phase structure:

### Phase 1: Canonical Merge & Baseline
**Rationale:** All other work depends on one truthful source tree; wrong branch merge reintroduces HID paths and stale docs.  
**Delivers:** Single main-branch snapshot merging research bulk driver + experimental integration; aligned README, `plugin.xml`, `config.json.example`, version strings.  
**Addresses:** v0.4 baseline preserved; bridge folder present; config path documented.  
**Avoids:** Pitfall 1 (branch drift), Pitfall 11 (config path), Pitfall 12 (version drift), Pitfall 15 (dead code).

### Phase 2: Clean Architecture — Domain Modules
**Rationale:** Unblocks host tests and isolates bridge from color math; prerequisite for safe refactors.  
**Delivers:** `color_math.lua`, `fixture_db.lua`, `goals.lua`, hardened JSON helpers; thin orchestration path; `get_correction` gap documented or scoped.  
**Uses:** Lua 5.4 modular `require`/`dofile` on MA3; shared pure logic pattern from STACK.md.  
**Implements:** Architecture domain layer; merge order steps 1–2.  
**Avoids:** Pitfall 2 (monolith), Pitfall 3 (JSON), Pitfall 4 (closed-loop clarity), Pitfall 13 (silent pcall).

### Phase 3: Shared Test Strategy & CI
**Rationale:** Eliminate duplicated test logic before feature velocity; gate regressions on require-based imports.  
**Delivers:** `tests/run.lua`, `test_bridge_parse.lua`, pytest suite for bridge; GitHub workflow (`lua5.4` + `pytest`); golden JSON/NR fixtures.  
**Addresses:** Table stakes quality metrics and bridge parse validation.  
**Avoids:** Pitfall 9 (test duplication), mock-only false confidence (Pitfall 10 partial).

### Phase 4: Pi Bridge Production
**Rationale:** Can parallelize with P2–P3 once canonical tree exists; C-7000 remote path is v1 table stakes.  
**Delivers:** `c7000_bulk.py` rename, collapsed setup (discover + capture), `MeterBackend` protocol, systemd/image, udev VID/PID-only, `--mock-realistic`, hot-plug reconnect path.  
**Uses:** FastAPI 0.115, pyusb 1.3.1, Pi OS Bookworm pins.  
**Implements:** Bridge refactor layout; architecture phase 5.  
**Avoids:** Pitfall 5 (HID vs bulk), Pitfall 8 (USB fragility), Pitfall 7 (network exposure — bind/firewall).

### Phase 5: MA3 ↔ HTTP Integration
**Rationale:** Depends on domain modules and bridge contract; delivers core v1 differentiator.  
**Delivers:** `bridge_client.lua` extract, remote measure, Bridge Status UI, setup wizard, retry/manual/cancel flows, auto-loop (max 3) tied to `goals_met()`.  
**Uses:** LuaSocket HTTP/1.0 timeouts; `config.json` `bridge_ip`/`bridge_port`.  
**Implements:** Transport layer + calibration orchestration; architecture phases 4 and 6 (partial).  
**Avoids:** Pitfall 6 (blocking UI), Pitfall 3 (bridge parse), Pitfall 14 (patch API guards), group-name `Cmd()` injection.

### Phase 6: Operator UX, Docs & Show Readiness
**Rationale:** Broadcast ops need honest copy, runbooks, and manifest lockstep before UAT.  
**Delivers:** v0.4 workflow modularized in `ui/*` + `calibration.lua`; measurement guidance; bridge network runbook; README fixes (no false community upload/GDTF-on-disk claims); semver alignment.  
**Addresses:** All table-stakes UX, bridge status clarity, incident guidance.  
**Avoids:** Pitfall 4 (UX copy on auto-loop), Pitfall 11–12 (doc drift), operator error paths from PITFALLS.md.

### Phase 7: Console UAT & Hardware Validation
**Rationale:** Gate before ship; CI cannot run MA3 or USB hardware.  
**Delivers:** E2E on real MA3 1.6.1.3 + Pi + C-7000; `require("socket")` verification; TLCI FW matrix; closed-loop correction fix if scoped (architecture phase 8).  
**Addresses:** Success criterion — **<5 minutes per group** with minimal typing and broadcast-grade metrics.  
**Avoids:** Pitfall 6 (on-console blocking), Pitfall 8 (hardware), Pitfall 4 (UAT acceptance on correction).

### Phase Ordering Rationale

- **P1 first** — Without canonical merge, every subsequent phase builds on the wrong baseline (HID wizard, missing bridge, contradictory README).
- **P2 → P3 before P5** — Domain extraction and shared tests prevent bridge work from corrupting color math and enable safe JSON/parser changes.
- **P4 parallel with P2–P4** — Python bridge cleanup does not require Lua UI split but needs P1 tree.
- **P5 after P2–P4** — Remote measure needs stable contract, parsers, and production bridge.
- **P6 wraps UX/docs** — After integration paths exist so copy matches behavior (especially auto-loop and config paths).
- **P7 last** — Validates blocking UI, USB, patch API, and correction math on real hardware; cannot be substituted by mock.

### Research Flags

Phases likely needing deeper research during planning:
- **Phase 2:** MA3 multi-file `require` packaging on target `DataVersion 1.6.1.3` — verify `package.path` vs `dofile` fallback before locking module split.
- **Phase 5:** MA3 LuaSocket availability and optimal timeout/yield strategy for blocking `/measure` on physical console.
- **Phase 7:** TLCI field presence across C-7000 firmware versions; closed-loop correction algorithm (measured→target delta in xy/uv).

Phases with standard patterns (skip research-phase):
- **Phase 3:** Host lua5.4 + pytest CI — established pattern documented in TESTING.md.
- **Phase 4:** FastAPI route structure, pyusb bulk sequence — prototype complete; execution not discovery.
- **Phase 6:** v0.4 UX patterns — validated; modularization not redesign.

## Confidence Assessment

| Area | Confidence | Notes |
|------|------------|-------|
| Stack | HIGH | Brownfield prototypes validated; MA3 Lua 5.4/LuaSocket constraints confirmed in docs and code |
| Features | HIGH | v0.4 table stakes validated in tree; v1 remote/auto-loop MEDIUM until merged and UAT |
| Architecture | HIGH | Two-component boundary and build order clear; MA3 `require` packaging MEDIUM until console verify |
| Pitfalls | HIGH | Grounded in CONCERNS.md, experimental branches, and MA forum blocking behavior |

**Overall confidence:** HIGH

### Gaps to Address

- **MA3 multi-file module loading:** Verify on console during Phase 2 planning; fallback to `dofile` if `require` paths differ.
- **Closed-loop correction math:** Decide implement vs document-before-ship during Phase 2/7; auto-loop value depends on this.
- **C-7000 TLCI by firmware:** Golden NR fixtures and `--mock-realistic` during Phase 4; hardware matrix in Phase 7.
- **Optional bridge HMAC:** Defer unless show IT requires; document VLAN-only trust model for v1.

## Sources

### Primary (HIGH confidence)
- `.planning/PROJECT.md` — v1 scope, topology, constraints, success criteria
- `.planning/codebase/STACK.md`, `ARCHITECTURE.md`, `INTEGRATIONS.md`, `TESTING.md`, `CONCERNS.md` — brownfield inventory
- `origin/claude/sekonic-remote-api-research-HdMTl` / `origin/Lighttune-experimental` — validated HTTP client, bridge server, USB protocol
- [MA Lighting — What is Lua (GMA3)](https://help.malighting.com/grandMA3/2.2/HTML/lua.html) — Lua 5.4.6 on MA3
- [kinglevel/skreader](https://github.com/kinglevel/skreader) — C-7000 USB bulk command sequence

### Secondary (MEDIUM confidence)
- [MA Lighting Forum — Non-blocking plugins / LuaSocket](https://forum.malighting.com/forum/thread/7973-non-blocking-plugins/) — GMA3 coroutine UI blocking
- EBU Tech 3355 / R137 — TLCI rationale for broadcast
- MA Lighting Forum — emitter vs group calibration ecosystem context

### Tertiary (LOW confidence)
- Native Sekonic on-device HTTP — deferred; topology option 2 only

### Detailed research documents
- [STACK.md](./STACK.md) — Technology stack
- [FEATURES.md](./FEATURES.md) — Feature landscape
- [ARCHITECTURE.md](./ARCHITECTURE.md) — Architecture patterns
- [PITFALLS.md](./PITFALLS.md) — Domain pitfalls

---
*Research completed: 2026-07-01*  
*Ready for roadmap: yes*
