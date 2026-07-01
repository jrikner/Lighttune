# Cherry-Pick Manifest — Phase 1 Canonical Merge & Baseline

**Merge target:** `claude/lighttune-main` (direct push per D-14)  
**Source branch:** `origin/claude/sekonic-remote-api-research-HdMTl` (tip `5cc8bf8`)  
**Rejected source:** `origin/Lighttune-experimental` — lacks skreader commit `5cc8bf8`; five-file drift in driver/mock/server/Lua/README (D-02)  
**Strategy:** Six ordered cherry-picks, not wholesale branch merge (BASE-01, D-04)  
**Audit substitute:** No PR gate required (D-16); this manifest is the audit trail  
**Planning artifacts:** Remain on `cursor/install-gsd-core-342d` (D-15)

## Commits applied (oldest → newest)

| # | Source hash | Source subject | New main SHA | Notes |
|---|-------------|----------------|--------------|-------|
| 1 | `55aedbb` | v0.5: Add Sekonic bridge for remote measurement over network | `dff15fc` | **Conflict** on `lua/SekonicCalibrator.lua`, `data/config.json.example` — resolved `-X theirs` (research wins, D-03) |
| 2 | `2180070` | v0.5: GrandMA3-compliant bridge with LuaSocket TCP, auto-loop, USB discovery | `79aef76` | Adds `discover_device.py`, Section 2c HTTP client |
| 3 | `96ce166` | docs: clarify curl commands run on Pi terminal, not GrandMA3 console | `2d198eb` | Doc-only |
| 4 | `5091f62` | feat: add remote trigger auto-discovery (no Wireshark required) | `da24676` | Trigger discovery wizard |
| 5 | `5fb8e28` | fix: forward-declare _run_trigger_discovery; clean up stale v0.4 docs | `92c0c2f` | Lua forward decl fix |
| 6 | `5cc8bf8` | feat: integrate skreader SDK — confirmed USB protocol, mock convergence | `98f3ccd` | **skreader bulk protocol** — reason research branch chosen over experimental |

## Post-cherry-pick alignment (Wave 2)

| Main SHA | Subject |
|----------|---------|
| `91b322c` | docs: align v0.5.0-replan version, README truth, and config path (Phase 1 Wave 2) |

## Tree parity (after cherry-picks, before Wave 2)

Verified zero diff vs research tip for:
- `lua/SekonicCalibrator.lua`
- `sekonic-bridge/`
- `data/config.json.example`
- `plugin.xml`

`README.md` intentionally differs from research tip (main retains Patch API section; research had on-disk GDTF regression).

## Wave 2 intentional deltas from research tip

- Lua header → `v0.5.0-replan`
- `plugin.xml` Version → `0.5.0`
- `sekonic-bridge/server.py` `/status` version → `0.5.0-replan`
- README full honesty pass (BASE-02)
- `config.json` plugin-root path docs + `.gitignore` (BASE-03)

## Verification (Wave 3)

- `lua5.4 test_color_math.lua` → **126 passed, 0 failed**
- README grep: no `community_upload`, no `gma3_library/gdtf`
- `config.json` at plugin root documented and gitignored

*Manifest written: 2026-07-01 — Phase 1 execution*
