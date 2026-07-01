# Technology Stack

**Analysis Date:** 2026-07-01

## Languages

**Primary:**
- Lua 5.4 — All application logic in `lua/SekonicCalibrator.lua` (~1,431 lines); unit tests in `test_color_math.lua` (~575 lines). README specifies `lua5.4 test_color_math.lua` for local test runs. GrandMA3 hosts an embedded Lua runtime for plugin execution.

**Secondary:**
- XML — Plugin manifest in `plugin.xml` (GMA3 `DataVersion="1.6.1.3"`, declares `ComponentLua` entry point).
- JSON — Local configuration and fixture database; parsed/encoded with custom regex helpers in `lua/SekonicCalibrator.lua` (Section 2b), not via an external JSON library.

## Runtime

**Environment:**
- **Production:** GrandMA3 console embedded Lua (MA Lighting plugin sandbox). Documented constraints: no `io.popen()`, no `os.execute()`; limited network (`lua.ftp` only — plain FTP documented, HTTPS unavailable).
- **Development/testing:** Standalone Lua 5.4 interpreter on a host machine to run `test_color_math.lua` outside the console.

**Package Manager:**
- None — No `package.json`, `requirements.txt`, `Cargo.toml`, luarocks manifest, or other dependency lockfile in the project root.
- Lockfile: Not applicable (zero declared third-party packages).

## Frameworks

**Core:**
- GrandMA3 Plugin API — Host framework for UI, show control, patch introspection, and color application. Entry point: `return main` at end of `lua/SekonicCalibrator.lua`; loaded via `plugin.xml` → `<ComponentLua FileName="lua/SekonicCalibrator.lua" />`.

**Testing:**
- Custom inline test harness in `test_color_math.lua` — `assert_near`, `assert_equal`, `assert_true`, `assert_false`, section-based output; mirrors pure color-math and DB helper logic from the main plugin without MA3 API calls. README documents 126 passing tests.

**Build/Dev:**
- No build toolchain — Deployment is a folder copy into the MA3 plugin library (`SekonicCalibrator/` with `plugin.xml`, `lua/`, `data/`).
- GSD Core (`.cursor/`) — Project-planning tooling installed locally; not part of the SekonicCalibrator runtime.

## Key Dependencies

**Critical:**
- GrandMA3 standard library (console-provided) — `MessageBox`, `Cmd`, `SetColor`, `DataPool`, `GetPath`, `GetPathSeparator`, `HostOS`, `Enums.PathType.PluginLibrary`. All invoked via `pcall` wrappers in `lua/SekonicCalibrator.lua`.
- Lua standard library — `math`, `string`, `table`, `tonumber`, `tostring`, `io.open` (read/write local files), `os.date`, `os.getenv` (fallback path resolution only).

**Infrastructure:**
- None — No cloud SDKs, ORMs, HTTP clients, or luarocks modules in source.

**External hardware (operator-driven, not programmatic):**
- Sekonic C-700, C-800, or C-7000 spectromaster — Readings entered manually through `MessageBox` prompts; no Sekonic SDK or serial/USB integration.

## Configuration

**Environment:**
- Optional `config.json` at plugin root (sibling of `data/`, not inside it). Example template: `data/config.json.example` with `github_username` field. Real `config.json` is gitignored (`.gitignore` line 5).
- No `.env` files or environment-variable-based feature flags in plugin code.

**Key configs required:**
- None mandatory — Plugin runs without `config.json`; contributor defaults to `"local"` when `github_username` is absent (`load_config()` in `lua/SekonicCalibrator.lua`).

**Data files (runtime, local filesystem):**
- `data/fixture_log.json` — Append-only fixture measurement database (gitignored).
- `data/measurements/*.json` — Reserved for local measurement logs (gitignored; directory exists with `.gitkeep` only).

**Build:**
- `plugin.xml` — Sole build/deploy manifest; pins plugin name `SekonicCalibrator`, author `Lighttune`, version `0.1.0` (source comments reference v0.4 feature set).

## Platform Requirements

**Development:**
- Lua 5.4 CLI for running `test_color_math.lua` (README: `lua5.4 test_color_math.lua`).
- Git for version control.

**Production:**
- GrandMA3 console software v1.6 or later (recommended per `README.md`).
- Fixture groups configured in the showfile; GDTF/patch data available through MA3 `DataPool`.
- Plugin installed under MA3 plugin library:
  - Windows: `C:\ProgramData\MALightingTechnology\gma3_library\datapools\plugins\SekonicCalibrator\`
  - macOS/Linux: `~/MALightingTechnology/gma3_library/datapools/plugins/SekonicCalibrator/`
- `data/` directory must ship with the plugin package (no runtime directory creation).

**README vs. code note:** README still mentions `curl` (community upload) and `unzip` (GDTF extraction). Current source uses MA3 Patch API for GDTF capabilities and saves fixture data locally only; automatic GitHub upload is explicitly disabled in `lua/SekonicCalibrator.lua` (Section 5 comments).

## Source Layout (tech-relevant)

| Path | Role |
|------|------|
| `plugin.xml` | GMA3 plugin manifest |
| `lua/SekonicCalibrator.lua` | Monolithic plugin: color math, JSON DB, UI, MA3 integration |
| `test_color_math.lua` | Standalone unit tests (pure functions + DB helpers) |
| `data/config.json.example` | Config template |
| `data/fixture_log.json` | Runtime DB (created on first save; gitignored) |
| `README.md` | Installation, meter workflow, schema documentation |

---

*Stack analysis: 2026-07-01*
