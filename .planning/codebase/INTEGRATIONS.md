# External Integrations

**Analysis Date:** 2026-07-01

## APIs & External Services

**GrandMA3 Console API (primary host integration):**
- Purpose: UI dialogs, fixture selection, color application, patch/GDTF capability introspection.
- Client: Built-in GrandMA3 Lua bindings (no separate SDK package in repo).
- Auth: Console session / showfile context (no API keys or OAuth).
- Key call sites in `lua/SekonicCalibrator.lua`:
  - `MessageBox({...})` — All user input and assessment UI (Sections 3, 6).
  - `Cmd('Group "..."')` / `Cmd("Group N")` — Select fixture group (`select_group`, ~line 1154).
  - `SetColor("xyY", ...)` with `SetColor("HSB", ...)` fallback — Apply chromaticity correction (`apply_color_xyY`, `apply_color_hsb`, ~lines 1163–1174).
  - `DataPool()` → `Groups` → `Members` → `FixtureType` → `DMXModes` → `DMXChannels` → `LogicalChannels` — Fixture make/model and DMX attribute detection (`get_fixture_from_patch`, `read_capabilities_from_patch`, ~lines 590–1148).
  - `GetPath(Enums.PathType.PluginLibrary)`, `GetPathSeparator()`, `HostOS()` — Resolve plugin and data paths (~lines 1201–1233).

**Sekonic spectrometers (C-700, C-800, C-7000):**
- Purpose: Source of CCT, Duv, CRI, R9, and (C-7000 only) TLCI measurements for calibration workflow.
- Integration type: **Manual operator entry** via `MessageBox` numeric prompts — no Sekonic SDK, USB, Bluetooth, or file import from meter.
- Auth: Not applicable.

**GitHub / Lighttune community database:**
- Purpose: Share fixture measurement records across users (documented in `README.md`; project home: https://github.com/jrikner/Lighttune-0.1).
- Integration type: **Manual only** — export `data/fixture_log.json` and submit via GitHub PR/issue.
- Automatic upload: **Not implemented.** Source comments (~lines 1192–1195, 1273–1275) state GrandMA3 Lua lacks HTTPS; only `lua.ftp` (plain FTP) is documented. No `curl`, GitHub REST, or FTP calls exist in code.
- `github_username` in optional root `config.json` is used only as the `contributor` field in local JSON records, not for authenticated API access.

**GDTF (General Device Type Format):**
- Purpose: Fixture DMX attributes (Tint, CTO, CTB, ColorWheel, RGB), nominal CCT/CRI.
- Integration type: **Indirect** — Data already parsed by GrandMA3; queried through Patch API objects. GDTF XML files are **not** read from disk (`io.popen` / `unzip` unavailable in console Lua).

## Data Storage

**Databases:**
- None (no SQL/NoSQL server).

**Local JSON files (filesystem via `io.open`):**
- `data/fixture_log.json` — Append-only array of measurement records with optional `best_cri`, `best_r9`, `best_tlci`, `best_duv` flags. Read/write in `save_fixture_log_local`, `show_fixture_history`, session pre-fill (~lines 955–967, 1255–1268, 1316–1321).
- Schema fields: `make`, `model`, `kelvin`, `date`, `contributor`, `cct`, `duv`, `cri`, `r9`, `tlci`, plus best-value booleans.
- Custom JSON encode/deparse in Section 2b (`json_encode_db_record`, `json_parse_db_array`) — no external JSON library.

**Config file:**
- `config.json` (plugin root, optional) — Currently supports `github_username` only (`load_config`, ~lines 1243–1252). Template: `data/config.json.example`.

**File Storage:**
- Local filesystem on console or show computer under the MA3 plugin library path. No cloud blob storage, S3, or CDN integration in code.

**Caching:**
- In-memory `fixture_records` table loaded at session start and updated after each group save (~lines 1316–1405). No Redis or external cache.

## Authentication & Identity

**Auth Provider:**
- Custom / none — No login, tokens, or OAuth in the plugin.
- Contributor identity: Optional `github_username` string from local `config.json`; defaults to `"local"` when missing.

## Monitoring & Observability

**Error Tracking:**
- None — Errors surfaced via `MessageBox` “Unexpected Error” dialog wrapping `main()` in `pcall` (~lines 1286, 1423–1428).

**Logs:**
- No structured logging framework. Session summary displayed in-console via `show_session_summary`. Fixture history browsable through plugin UI (`show_fixture_history`).

## CI/CD & Deployment

**Hosting:**
- GrandMA3 console plugin library (on-premise lighting console / show computer). Not a web-hosted service.

**CI Pipeline:**
- None detected in repository (no `.github/workflows`, Makefile, or test runner config at project root).

**Deployment:**
- Manual copy of `SekonicCalibrator/` folder → MA3 `datapools/plugins/` → import via `Menu → Plugin Pool → Import` (`README.md`).

## Environment Configuration

**Required env vars:**
- None for plugin operation.

**Optional env vars (fallback path resolution only):**
- `APPDATA` — Windows fallback when `GetPath` unavailable (`get_plugin_dir`, ~line 1223).
- `HOME` — macOS/Linux fallback (~line 1229).

**Secrets location:**
- No secrets in repo. `data/config.json` gitignored. No API tokens or upload credentials in source.

## Webhooks & Callbacks

**Incoming:**
- None.

**Outgoing:**
- None — No HTTP callbacks, webhooks, or network requests in `lua/SekonicCalibrator.lua`.

## Network & Protocol Summary

| Capability | Available in GMA3 Lua (per source) | Used in SekonicCalibrator |
|------------|-----------------------------------|---------------------------|
| HTTPS / HTTP | No | No |
| `lua.ftp` (plain FTP) | Documented | No |
| `io.popen` / shell | No | No |
| Local `io.open` | Yes | Yes (`config.json`, `fixture_log.json`) |

## Integration Diagram

```text
Operator + Sekonic meter (manual readings)
        │
        ▼
┌───────────────────────────────────────┐
│  SekonicCalibrator.lua (GrandMA3 Lua) │
│  MessageBox UI │ Color math │ JSON DB │
└───────┬───────────────┬───────────────┘
        │               │
        ▼               ▼
  MA3 API             Local filesystem
  (Cmd, SetColor,     (config.json,
   DataPool/Patch)    fixture_log.json)
        │
        ▼
  Fixture groups / GDTF-via-patch
  on GrandMA3 console

Manual export ──► GitHub (PR/issue) — not automated
```

---

*Integration audit: 2026-07-01*
