# Phase 5: MA3 ↔ HTTP Integration — Research

**Researched:** 2026-07-02  
**Phase:** 5  
**Confidence:** HIGH (brownfield — behavior exists in monolith; extraction + test seam)

## Summary

Phase 5 is a **refactor-and-harden** phase, not greenfield. `lua/SekonicCalibrator.lua` Section 2c already implements remote measure, setup wizard HTTP calls, Bridge Status, and auto-loop orchestration. Phase 4 delivered Pi-side auth (`X-Bridge-Key`) and stable route contracts. Phase 5 extracts the HTTP client into `lua/bridge_client.lua`, adds structured error results for richer operator UX, gates remote offer on C-7000 session meter, enhances Bridge Status, and adds Lua host tests for parse/error mapping.

**Primary recommendation:** Three-wave execution — (1) module extraction + loader, (2) monolith wiring + MTR-04/06 UX, (3) auto-loop contract verification + Lua tests + validation sign-off. Product commits on `claude/lighttune-main`; GSD docs on planning branch.

## Standard Stack

### Core

| Component | Purpose | Why Standard |
|-----------|---------|--------------|
| `require("socket")` + raw HTTP/1.0 | MA3 → Pi bridge transport | Already validated in v0.5 experimental branch; no HTTPS on console |
| `lua/bridge_client.lua` | Extracted HTTP + parse layer | Matches Phase 2 module pattern (`color_math`, `goals`, `fixture_db`) |
| Regex JSON field extraction | Parse MeasurementRecord without JSON library | MA3 Lua has no guaranteed `json` module; existing pattern in monolith |
| `tests/lib_assert.lua` + `tests/run.lua` | Host test runner | Phase 3 TST-01 infrastructure |

### Supporting

| Component | Purpose | When to Use |
|-----------|---------|-------------|
| `bridge_client.set_transport(fn)` or parse-only tests | Test seam without live TCP | D-99 discretion — prefer **parse helper unit tests** with fixture strings; optional transport stub |
| Phase 3/4 pytest | Pi route contract | Unchanged — no duplicate HTTP stack tests in Lua |

### Alternatives Considered

| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| Regex parse | Embed minimal JSON decoder | Higher risk on MA3; out of Phase 5 scope |
| Inline Section 2c | Keep monolithic | Violates ARCH-04; blocks testability |
| `socket.http` | Raw TCP HTTP/1.0 | Unverified on MA3; current code uses TCP |

## Architecture Patterns

### Module contract (`bridge_client.lua`)

```lua
-- Returns on success:
{ ok = true, data = { ... } }

-- Returns on failure:
{ ok = false, kind = "connection"|"timeout"|"unauthorized"|"http"|"parse"|"validation",
  message = "...", hint = "...", http_status = 401 }
```

**Functions to export:**
- `request(method, host, port, path, opts)` — opts: `timeout_s`, `api_key`
- `fetch_measurement(config)` → `{ok, data={cct,duv,cri,r9,tlci?}}` or error
- `check_status(config)` → `{ok, data={connected, meter, device_configured, protocol_captured, trigger_discovered, auth_required, last_error}}`
- `discover(config)`, `capture(config)`, `learn_trigger(config)` — setup routes
- **Parse helpers (testable):** `parse_measure_body(body)`, `parse_status_body(body)`, `classify_http(status, body)`

### Timeouts (locked D-81)

| Route | Timeout (s) |
|-------|-------------|
| GET /status | 5 |
| GET /discover | 12 |
| POST /capture | 35 |
| POST /measure | 38 |
| POST /learn_trigger | 120 |

### Error mapping (MTR-04 D-83)

| Condition | `kind` | Operator hint |
|-----------|--------|---------------|
| TCP connect fail | `connection` | Check bridge IP / network |
| HTTP 401 | `unauthorized` | Set matching `bridge_api_key` |
| HTTP 503 | `http` | Meter not connected — USB |
| HTTP 409 | `http` | Measurement in progress — wait |
| HTTP 504 | `timeout` | Meter did not respond |
| Missing JSON fields | `parse` | Malformed bridge response |
| CCT/Duv out of range | `validation` | Re-measure or manual entry |

### Remote offer gating (D-91)

Only show Remote/Manual choice when `config.bridge_ip` non-empty **and** `goals.meter == METER_C7000`. C-700/C-800 sessions skip remote dialog.

### Auto-loop (existing — verify, don't redesign)

- `MAX_AUTO_ATTEMPTS = 3`, `user_manual` sticky flag
- Attempt 2+: direct `bridge_client.fetch_measurement` (no Remote/Manual choice)
- Per-cycle Accept / Enter Manually / Cancel preserved (D-88)
- Stuck dialog after 3 cycles unchanged (D-89)

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| HTTPS client | TLS in Lua | HTTP on show VLAN + optional API key | MA3 constraint |
| JSON parser | Full decoder | Regex field extract (existing) | Proven in plugin |
| Retry backoff | Exponential retry in client | Operator Retry button | D-93 — no silent retries |
| Pi-side changes | New bridge routes | Consume Phase 4 routes as-is | Phase boundary |

## Common Pitfalls

### Pitfall 1: Breaking setup wizard regex parsers
**What goes wrong:** Changing JSON key order or response shapes breaks `run_bridge_setup` string matches.  
**How to avoid:** `bridge_client` returns parsed tables; monolith keeps same success/failure checks on `data` fields.  
**Warning signs:** Setup wizard steps fail in mock mode after refactor.

### Pitfall 2: TLCI nil on real C-7000
**What goes wrong:** `goals_met` with TLCI goal when bridge omits `tlci` field.  
**How to avoid:** `fetch_measurement` returns `tlci=nil` when absent; existing goals.lua behavior (`TLCI nil ignored when missing`) — document in validation, no Phase 5 logic change unless test proves bug.

### Pitfall 3: Test runner can't load bridge_client without socket
**What goes wrong:** Host tests fail on CI if `require("socket")` unavailable.  
**How to avoid:** Test **parse helpers** and **classify_http** with fixture strings only; transport tests optional behind stub.

### Pitfall 4: Removing Phase 4 auth header
**What goes wrong:** 401 on setup routes when key configured.  
**How to avoid:** Every `bridge_client.request` must pass `config.bridge_api_key` into `X-Bridge-Key` header when non-empty.

## Codebase Map (Phase 5 touch points)

| File | Change |
|------|--------|
| `lua/bridge_client.lua` | **NEW** — HTTP client module |
| `lua/SekonicCalibrator.lua` | Wire module; error formatter; C7000 gate; status UI |
| `tests/test_bridge_client.lua` | **NEW** — parse/error tests |
| `tests/run.lua` | Register bridge_client tests |
| `tests/fixtures/bridge_measure_ok.json` | Reference for parse fixtures (optional duplicate as Lua string) |

**No changes expected:** `sekonic-bridge/server.py`, pytest files (regression only).

## Validation Architecture

### Test pyramid

| Layer | Tool | Scope |
|-------|------|-------|
| Unit (Lua) | `tests/test_bridge_client.lua` | Parse helpers, HTTP classify, validation bounds |
| Integration (Python) | pytest (existing) | Pi routes unchanged |
| Regression (Lua) | `tests/run.lua` full suite | 139+ prior tests + new bridge tests |
| Manual | Phase 7 UAT | Real MA3 LuaSocket |

### Per-plan verification

| Plan | Primary verify |
|------|----------------|
| 05-01 | `test -f lua/bridge_client.lua`; grep structured `ok`/`kind` |
| 05-02 | grep `bridge_client` in monolith; manual spot-check error strings |
| 05-03 | `lua5.4 tests/run.lua` 154+ PASS; pytest unchanged green |

### CI impact

`.github/workflows/ci.yml` host-lua job automatically picks up new tests via `tests/run.lua` — no workflow change required unless assertion count documented in VALIDATION.md.

## Open Questions (resolved for planning)

| Question | Resolution |
|----------|------------|
| Extract UI or transport only? | Transport + parse in module; UI in monolith (D-79) |
| Auto-accept auto-loop? | No — Phase 6 deferred |
| Mandatory /status pre-flight? | No — D-93 |

## Sources

### Primary (HIGH confidence)
- `lua/SekonicCalibrator.lua` Section 2c and auto-loop ~1544–1700
- `.planning/phases/05-ma3-http-integration/05-CONTEXT.md` D-77–D-101
- `.planning/codebase/INTEGRATIONS.md`, `CONCERNS.md`
- Phase 4 executed bridge (`sekonic-bridge/server.py` auth + routes)

### Secondary (MEDIUM confidence)
- GrandMA3 LuaSocket availability — confirmed by experimental branch; full UAT Phase 7

---

*Phase: 5-MA3 ↔ HTTP Integration*
