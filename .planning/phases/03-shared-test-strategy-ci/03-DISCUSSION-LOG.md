# Phase 3: Shared Test Strategy & CI - Discussion Log

> **Audit trail only.** Decisions captured in CONTEXT.md.

**Date:** 2026-07-02
**Phase:** 3-Shared Test Strategy & CI
**Note:** Context inferred from ROADMAP + Phase 2 outcomes (no `/gsd-discuss-phase 3` session)

---

## Host test layout

| Option | Selected |
|--------|----------|
| tests/run.lua + split test_*.lua | ✓ |
| Keep monolithic root file only | |
| Move everything to tests/ without root wrapper | |

## Bridge CI scope

| Option | Selected |
|--------|----------|
| /status, /measure, /discover only | ✓ |
| Include /capture and /learn_trigger | |

## CI platform

| Option | Selected |
|--------|----------|
| GitHub Actions ubuntu-latest | ✓ |
| Self-hosted Pi runner | |
