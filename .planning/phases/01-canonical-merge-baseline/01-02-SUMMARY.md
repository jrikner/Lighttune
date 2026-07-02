---
phase: 01-canonical-merge-baseline
plan: 02
subsystem: docs
tags: [readme, version, config]
requires:
  - phase: 01-canonical-merge-baseline
    provides: cherry-picked v0.5 codebase on main
provides:
  - v0.5.0-replan version strings aligned
  - Truthful README and config path documentation
affects: [phase-6, operators]
tech-stack:
  added: []
  patterns: [plugin-root config.json, Patch API docs only]
key-files:
  modified: [README.md, plugin.xml, lua/SekonicCalibrator.lua, sekonic-bridge/server.py, data/config.json.example, .gitignore]
key-decisions:
  - "plugin.xml Version 0.5.0 (semver-safe); replan in Lua/README/bridge status"
patterns-established:
  - "config.json lives at plugin root, not data/"
requirements-completed: [BASE-02, BASE-03]
coverage:
  - id: D1
    description: "v0.5.0-replan version label in Lua, README, bridge /status"
    requirement: BASE-02
    verification:
      - kind: other
        ref: "grep v0.5.0-replan lua/SekonicCalibrator.lua README.md sekonic-bridge/server.py"
        status: pass
  - id: D2
    description: "README honesty — no false upload/GDTF/curl-on-console claims"
    requirement: BASE-02
    verification:
      - kind: other
        ref: "! grep community_upload README.md; Patch API + bridge_ip present"
        status: pass
  - id: D3
    description: "config.json plugin-root path documented and gitignored"
    requirement: BASE-03
    verification:
      - kind: other
        ref: "grep config.json .gitignore; plugin root in README and config example"
        status: pass
duration: 20min
completed: 2026-07-01
status: complete
---

# Phase 1 Plan 02 Summary

**Docs and manifests now match the v0.5.0-replan codebase on main.**

## Accomplishments

- Unified `v0.5.0-replan` labeling across Lua header, README, bridge `/status`; `plugin.xml` at `0.5.0`
- README rewritten: bridge workflow, Patch API only, manual fallback, Pi-terminal curl examples
- `config.json` copy path fixed to plugin root; `.gitignore` updated

## Deviations

- `plugin.xml` uses `0.5.0` not `0.5.0-replan` per MA3 semver discretion in CONTEXT.md
