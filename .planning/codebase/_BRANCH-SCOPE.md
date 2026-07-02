# Branch Scope for Codebase Mapping

**Generated:** 2026-07-01  
**Purpose:** Reference for mapper agents — analyze ALL branches, not just the checked-out tree.

## Branches to analyze

| Branch | Tip commit | Sekonic relevance |
|--------|------------|-------------------|
| `origin/claude/lighttune-main` | df95d17 | **Production baseline** — SekonicCalibrator v0.4, manual meter entry only |
| `origin/claude/sekonic-remote-api-research-HdMTl` | 5cc8bf8 | **Latest Sekonic work** — v0.5 Lua plugin + full `sekonic-bridge/` Python server |
| `origin/Lighttune-experimental` | 83f74b8 | Merged sekonic remote API (PR #2) — same as research branch minus minor diffs |
| `origin/cursor/setup-dev-environment-4246` | 48ad527 | Dev env notes + sekonic-bridge |
| `cursor/install-gsd-core-342d` | (current) | GSD tooling + `.planning/codebase/` only |

## Files added on Sekonic branches (not on lighttune-main)

```
sekonic-bridge/README.md
sekonic-bridge/build-image.sh
sekonic-bridge/discover_device.py
sekonic-bridge/meter_c7000_hid.py
sekonic-bridge/meter_mock.py
sekonic-bridge/requirements.txt
sekonic-bridge/sekonic-bridge.service
sekonic-bridge/server.py
sekonic-bridge/setup-pi.sh
sekonic-bridge/start.sh
```

## Key deltas on Sekonic branches

- `lua/SekonicCalibrator.lua`: v0.4 → v0.5 — bridge HTTP client, auto-loop calibration, USB discovery UI
- `data/config.json.example`: adds `bridge_ip`, `bridge_port`, `auto_loop`
- `README.md`: documents remote bridge workflow

## How to read files from other branches

```bash
git show origin/claude/sekonic-remote-api-research-HdMTl:lua/SekonicCalibrator.lua
git show origin/claude/sekonic-remote-api-research-HdMTl:sekonic-bridge/server.py
git diff origin/claude/lighttune-main origin/claude/sekonic-remote-api-research-HdMTl
```

## Merge status

Sekonic remote API is on `Lighttune-experimental` and `sekonic-remote-api-research-HdMTl` but **not yet merged** into `claude/lighttune-main`.
