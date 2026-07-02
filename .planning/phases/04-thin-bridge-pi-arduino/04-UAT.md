---
status: testing
phase: 4-thin-bridge-pi-arduino
source: [04-VERIFICATION.md]
started: 2026-07-02
updated: 2026-07-02
---

## Current Test

number: 1
name: In-plugin Bridge Setup wizard (discover → capture → learn_trigger)
expected: |
  Main menu → Bridge Setup completes all steps; Bridge Status shows
  device_configured, protocol_captured, trigger_discovered true.
awaiting: user response

## Tests

### 1. Bridge Setup wizard
expected: Discover finds meter; capture succeeds; learn_trigger returns success; status flags true
result: [pending]

### 2. Bridge Status screen
expected: Main menu → Bridge Status shows connected meter and setup flags
result: [pending]

### 3. Optional auth with matching keys
expected: With BRIDGE_API_KEY on Pi and bridge_api_key in plugin config, wizard and measure work
result: [pending]

## Summary

total: 3
passed: 0
issues: 0
pending: 3
skipped: 0
blocked: 0

## Gaps
