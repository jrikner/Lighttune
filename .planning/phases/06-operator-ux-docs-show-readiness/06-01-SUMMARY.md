---
phase: 06-operator-ux-docs-show-readiness
plan: 01
subsystem: infra
tags: [lua, config, macos, runbook, grandma3]

requires:
  - phase: 05-ma3-http-integration
    provides: bridge_client and remote measurement baseline
provides:
  - macOS onPC + local bridge runbook (primary deployment path)
  - lua/config.lua path and config.json parsing module
  - tests/test_config.lua host coverage
affects: [phase-6-wave-2, phase-6-wave-3, phase-7-uat]

tech-stack:
  added: []
  patterns:
    - "config.lua module with normalize_plugin_dir for host tests"
    - "bridge_ip 127.0.0.1 as default localhost topology"

key-files:
  created:
    - lua/config.lua
    - tests/test_config.lua
  modified:
    - README.md
    - sekonic-bridge/README.md
    - data/config.json.example
    - lua/SekonicCalibrator.lua
    - tests/run.lua

key-decisions:
  - "macOS localhost (127.0.0.1) documented before Pi stage-split topology"
  - "config module registered in load_domain_modules per D-108"

patterns-established:
  - "Path helpers centralized in config.lua; shell delegates load_config/get_data_dir"

requirements-completed: [TOP-01, UX-05]

coverage:
  - id: D1
    description: macOS onPC runbook with 127.0.0.1 bridge_ip documented before Pi sections
    requirement: TOP-01
    verification:
      - kind: other
        ref: "grep -n '127.0.0.1' README.md sekonic-bridge/README.md"
        status: pass
    human_judgment: false
  - id: D2
    description: config.lua exports get_sep, get_plugin_dir, get_data_dir, load_config with host tests
    requirement: D-105
    verification:
      - kind: unit
        ref: "tests/test_config.lua via lua5.4 tests/run.lua"
        status: pass
    human_judgment: false

duration: 45min
completed: 2026-07-02
status: complete
---

# Phase 6 Plan 01 Summary

**macOS onPC + local sekonic-bridge runbook first, config.lua extracted with host path/parse tests**

## Performance

- **Duration:** ~45 min (Wave 1)
- **Tasks:** 2
- **Files modified:** 6

## Accomplishments

- Published macOS primary deployment runbook in README and sekonic-bridge/README.md
- Set `bridge_ip: "127.0.0.1"` in config.json.example
- Extracted `lua/config.lua` with path helpers and regex config parse
- Added `tests/test_config.lua`; 169+ host tests green

## Files Created/Modified

- `lua/config.lua` — plugin path resolution and config.json parsing
- `tests/test_config.lua` — macOS/Windows path normalization and parse tests
- `README.md`, `sekonic-bridge/README.md` — macOS runbook before Pi
- `data/config.json.example` — localhost bridge_ip default

## Decisions Made

None - followed plan as specified (macOS-first topology per TOP-01).

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

None

## Next Phase Readiness

- config module ready for Wave 2 patch_api/fixture_apply extraction
- Doc grep audit passes for 127.0.0.1

---
*Phase: 06-operator-ux-docs-show-readiness*
*Completed: 2026-07-02*
