# Technology Stack — Lighttune v1

**Project:** Lighttune (SekonicCalibrator)  
**Researched:** 2026-07-01  
**Scope:** v1 replanned architecture — GrandMA3 Lua plugin + Raspberry Pi HTTP bridge + Sekonic C-7000  
**Confidence:** HIGH (brownfield prototypes validated on Sekonic branches; MA3 constraints confirmed in source and MA forum/docs)

---

## Executive Recommendation

Lighttune v1 should adopt the **proven dual-runtime stack** from `origin/claude/sekonic-remote-api-research-HdMTl` / `origin/Lighttune-experimental`, reorganized into clean modules—not a new technology pivot.

| Layer | Standard stack | Rationale |
|-------|----------------|-----------|
| Console plugin | **Lua 5.4** + **GrandMA3 Object-Free/Object API** | Only supported plugin runtime on MA3; v0.4 math and UX already validated |
| Console → bridge | **LuaSocket** `require("socket")` + **raw HTTP/1.0 over TCP** | Only viable HTTP path on MA3 (no HTTPS, no `io.popen`, no shell `curl`) |
| Pi bridge | **Python 3.12** + **FastAPI 0.115** + **uvicorn 0.32** | Async REST, minimal deps, prototype already ships on port 8765 |
| Meter I/O | **pyusb 1.3.1** + **skreader protocol** (reference, not pip dep) | C-7000 USB bulk is documented; no official Sekonic HTTP API for v1 |
| Pi OS | **Raspberry Pi OS Lite 64-bit (Bookworm)** + **systemd** | Matches `setup-pi.sh` / `build-image.sh`; headless stage deployment |
| Dev / CI host | **lua5.4 CLI** + **Python venv** + **meter_mock** | Color math testable without console; bridge testable without hardware |

**Do not adopt for v1:** Flask/Django bridge, `socket.http` or `lua-http` luarocks on console, HTTPS/TLS from plugin, `io.popen`/`os.execute` networking, native Sekonic device HTTP (deferred), Node/Electron sidecars, Docker on Pi (unnecessary complexity for a single-service appliance).

---

## Languages

### Primary — GrandMA3 plugin (Lua 5.4)

| Technology | Version | Purpose | Why this choice |
|------------|---------|---------|-----------------|
| **Lua** | **5.4.x** (MA3 ships 5.4.6 per MA docs) | All FOH application logic | GrandMA3 embeds Lua as the sole plugin language; no alternative SDK in-repo |
| **GrandMA3 API** | GMA3 **v1.6+** (`DataVersion` 1.6.1.3 in `plugin.xml`) | UI, patch introspection, color apply | `MessageBox`, `Cmd`, `SetColor`, `DataPool`, `GetPath`, `HostOS` — console-provided bindings |
| **XML** | GMA3 plugin manifest | `plugin.xml` registers `ComponentLua` | Standard MA3 plugin packaging |
| **JSON (custom)** | N/A | `config.json`, `fixture_log.json` | No JSON library on console; regex encode/decode in Section 2b (proven, keep for v1) |

**v1 module layout (prescriptive):** Split the monolithic `SekonicCalibrator.lua` into multiple Lua files loaded from one entry (`main.lua` or thin `SekonicCalibrator.lua` that `dofile`s modules). MA3 supports multi-file plugins via `plugin.xml` or `dofile` relative to plugin path. Keep **pure** color math and JSON helpers in files that `test_color_math.lua` can `require` or mirror—eliminate the duplicate-and-drift pattern from v0.4.

### Secondary — Pi bridge (Python 3)

| Technology | Version | Purpose | Why this choice |
|------------|---------|---------|-----------------|
| **Python** | **3.12** (Pi Bookworm system Python; venv in `/opt/sekonic-bridge`) | Bridge server, USB driver, mock meter | Prototype complete; pyusb/FastAPI ecosystem mature on ARM64 |
| **Bash** | POSIX | `setup-pi.sh`, `build-image.sh`, `start.sh` | One-line Pi provisioning; no config management framework needed |
| **JSON** | stdlib | `device_config.json`, API responses | Native `json` module; no pydantic required for v1 (keep dependency count at three pip packages) |

### Host-only — development and tests

| Technology | Purpose | Why |
|------------|---------|-----|
| **Lua 5.4 CLI** | `lua5.4 test_color_math.lua` | Runs outside MA3; 126 assertions on color math + DB helpers |
| **curl / jq** | Manual bridge smoke tests | Dev machine only—not available on console |

---

## Runtime

### GrandMA3 console (production)

| Aspect | Standard | Notes |
|--------|----------|-------|
| Host | GrandMA3 onPC or hardware console | Target GMA3 **1.6+** |
| Lua VM | Embedded 5.4 with stdlib (`math`, `string`, `table`, `io.open`, `os.date`) | `io.popen` and `os.execute` **unavailable or unsafe** — do not depend on them |
| Networking | **LuaSocket** via `require("socket")` | Inferred available because MA documents `lua.ftp` (LuaSocket); validated in v0.5 `_http_request` |
| Plugin lifecycle | Lua **coroutine** per plugin invocation | Long `/measure` calls (up to 38 s client timeout) **block the plugin coroutine**; acceptable during calibration wizard, not during live busking—document operator expectation |
| Deployment | Folder copy to MA3 plugin library | No build step, no luarocks, no npm |

**MA3 hard constraints (non-negotiable for v1):**

1. **No HTTPS/TLS** from plugin — use plain HTTP on isolated show VLAN only.
2. **No `io.popen` / `os.execute`** — cannot shell out to `curl`, `ping`, or OpenSSL.
3. **No `socket.http` luarocks** — assume only base `socket` TCP; implement HTTP/1.0 manually (proven pattern).
4. **No external JSON library** — regex parse bridge JSON responses in Lua (or extract pure parse helpers testable on host).
5. **Blocking TCP reads** — `tcp:receive` blocks until timeout; set explicit `tcp:settimeout` per call (5 s status, 38 s measure, 120 s learn_trigger).

### Raspberry Pi bridge (production)

| Aspect | Standard | Notes |
|--------|----------|-------|
| Hardware | **Raspberry Pi Zero 2 W** (recommended) or Pi 4 | Stage-adjacent; USB to C-7000, WiFi/Ethernet to show net |
| OS | **Raspberry Pi OS Lite 64-bit Bookworm** | Pinned in `build-image.sh` |
| Process manager | **systemd** (`sekonic-bridge.service`) | Unprivileged `sekonic` user; auto-restart |
| HTTP server | **uvicorn** ASGI on `0.0.0.0:8765` | Single worker sufficient; `/measure` serialized with `asyncio.Lock` |
| USB access | **pyusb** + **libusb-1.0** + udev rule | `99-sekonic-c7000.rules`; VID `0x0A41`, PID `0x7003` |
| Mock mode | `python3 server.py --mock` | `MockMeter` replaces `C7000HID` — same REST surface |

### Development host

| Component | Command | Purpose |
|-----------|---------|---------|
| Color math | `lua5.4 test_color_math.lua` | Pre-commit gate; target 126+ passing |
| Mock bridge | `cd sekonic-bridge && python3 server.py --mock --port 8765` | Lua plugin integration without Pi/C-7000 |
| Plugin → bridge | Set `bridge_ip` in `config.json` to dev machine LAN IP | E2E against mock progression |

---

## Frameworks

### GrandMA3 Plugin API (core framework)

Entry contract: `return main` (or `return function(display) ... end`) at plugin load.

**Prescriptive API usage by concern:**

| Concern | MA3 APIs | Module boundary (v1) |
|---------|----------|----------------------|
| Operator UI | `MessageBox({...})` | `ui/` or `ui.lua` |
| Fixture selection | `Cmd('Group "..."')` | `calibration/` orchestration |
| Color application | `SetColor("xyY", ...)`, HSB fallback | `calibration/apply.lua` |
| Patch / GDTF hints | `DataPool()` → Groups → FixtureType → DMXModes | `patch.lua` |
| Paths | `GetPath`, `GetPathSeparator`, `HostOS` | `paths.lua` |
| Bridge HTTP | `_http_request`, `bridge_fetch_measurement`, `bridge_check_status` | `bridge_client.lua` (Section 2c extracted) |

No third-party Lua frameworks (no Penlight, no dkjson on console).

### LuaSocket HTTP client pattern (prescriptive)

**Use:** Raw HTTP/1.0 over `socket.tcp()` — **not** `socket.http`, **not** MA2-era `gma.http` patterns.

**Canonical request shape (from validated v0.5):**

```lua
local ok, socket = pcall(require, "socket")
local tcp = socket.tcp()
tcp:settimeout(timeout_s)
tcp:connect(host, port)
local req = string.format(
    "%s %s HTTP/1.0\r\nHost: %s\r\nContent-Length: 0\r\n\r\n",
    method, path, host)
tcp:send(req)
-- receive until EOF; parse status line + body after \r\n\r\n
```

**Timeouts (keep):**

| Call | Timeout | Endpoint |
|------|---------|----------|
| Status check | 5 s | `GET /status` |
| Measurement | 38 s | `POST /measure` (bridge blocks up to 35 s) |
| Discover | 12 s | `GET /discover` |
| Capture | 35 s | `POST /capture` |
| Learn trigger | 120 s | `POST /learn_trigger` |

**Response handling:** Regex extraction of JSON fields (`"cct"`, `"duv"`, `"cri"`, `"r9"`, `"tlci"`, `"connected"`). Return structured `{ok, err}` tables to UI layer for operator-facing MessageBox messages.

**Optional v1 improvement:** Insert `coroutine.yield(0.1)` between receive chunks only if UI freeze is observed on hardware consoles; not required for calibration wizard flow where blocking is expected.

### sekonic-bridge (FastAPI + uvicorn)

**Use FastAPI** — not Flask, not aiohttp bare, not Node.

| Endpoint | Method | Behavior |
|----------|--------|----------|
| `/status` | GET | Health, meter state, setup flags |
| `/measure` | POST | Trigger measure; blocks 2–35 s; 409 if concurrent |
| `/discover` | GET | USB scan → `device_config.json` |
| `/capture` | POST | Passive capture / protocol verify |
| `/learn_trigger` | POST | HID trigger probe fallback |

**Concurrency model:** `asyncio.Lock` on `/measure`; executor for blocking `meter.measure()` USB I/O. Errors: 503 (not connected), 409 (in progress), 504 (timeout), 500 (driver error).

### USB meter driver (pyusb + skreader)

**Reference implementation:** [kinglevel/skreader](https://github.com/kinglevel/skreader) (MIT) — C# SDK reverse-engineered; **not** a pip dependency.

**Protocol (C-7000 bulk):**

```
RT1 → ACK → RM0 → ACK → ST (poll 50 ms) → NR (2380 B) → RT0 → ACK
```

**Parse offsets:** CCT @50, Duv @55, CRI @348, R9 @393; TLCI when FW supports extended NR.

**Filename note:** `meter_c7000_hid.py` uses **USB bulk**, not HID report API—keep name for brownfield compatibility or rename to `meter_c7000_usb.py` in v1 refactor (behavior unchanged).

### Test tooling frameworks

| Tool | Role | v1 standard |
|------|------|-------------|
| **lua5.4 host tests** | Unit tests for color math, JSON DB, base64, `goals_met` pure logic | **Required** — extend `test_color_math.lua` or split `tests/test_*.lua` with shared `require` of pure modules |
| **meter_mock.py** | Drop-in `C7000HID` replacement; converging CCT/CRI progression | **Required** for dev and manual QA |
| **pytest + httpx TestClient** | Bridge route tests, mock progression assertions, golden NR binary | **Recommended** v1 addition (not in prototype; see `.planning/codebase/TESTING.md`) |
| **Busted / LuaUnit** | Lua test runners on console | **Do not adopt** — MA3 cannot run them; host-only custom harness is the pattern |

**meter_mock contract (must preserve):**

```python
class MockMeter:
    def connect(self) -> bool: ...
    def is_connected(self) -> bool: ...
    def disconnect(self): ...
    def measure(self) -> dict:  # keys: cct, duv, cri, r9, tlci
```

Progression table (calls 1→5+ improving toward ~5605 K / CRI 94) enables auto-loop validation without hardware.

---

## Key Dependencies

### GrandMA3 Lua plugin

| Dependency | Source | Version | Purpose |
|------------|--------|---------|---------|
| GrandMA3 API | Console | GMA3 1.6+ | UI, patch, color |
| Lua stdlib | Console | 5.4 | Core language |
| LuaSocket (`socket`) | Console | Bundled with MA3 | TCP HTTP client |
| Sekonic meter (manual) | Operator | C-700 / C-800 / C-7000 | Fallback MessageBox entry |

**Zero repo dependencies** for plugin — no luarocks, no vendored DLLs.

### sekonic-bridge Python (pin exactly)

| Package | Version | Purpose |
|---------|---------|---------|
| `fastapi` | **0.115.0** | REST API |
| `uvicorn[standard]` | **0.32.0** | ASGI server |
| `pyusb` | **1.3.1** | USB bulk I/O |

**System packages (Pi via `setup-pi.sh`):**

`python3`, `python3-pip`, `python3-venv`, `python3-usb`, `libusb-1.0-0`, `git`, `curl`

**v1 optional dev-only (not runtime):**

`pytest`, `httpx` — for `sekonic-bridge/tests/`; do not install on production Pi image unless running CI there.

### Hardware

| Device | Role |
|--------|------|
| Sekonic **C-7000** | Primary remote meter (USB to Pi) |
| Sekonic C-700 / C-800 | Manual-only path (no TLCI on C-700/C-800) |
| Raspberry Pi Zero 2 W | Bridge host on stage |
| USB OTG + Mini-B cable | C-7000 connection |

---

## Configuration

### Lua plugin

| File | Location | Fields (v1) |
|------|----------|-------------|
| `config.json` | Plugin root (gitignored) | `github_username`, **`bridge_ip`**, **`bridge_port`** (default 8765) |
| `data/config.json.example` | Repo template | Same fields with placeholders |
| `data/fixture_log.json` | Runtime append-only DB | make, model, kelvin, metrics, best_* flags |
| `plugin.xml` | Repo | `DataVersion`, `Version` — align with implementation in v1 |

**Loading:** `load_config()` regex parser — add host tests for `bridge_ip` / `bridge_port` parsing in v1.

### sekonic-bridge

| File / mechanism | Purpose |
|------------------|---------|
| `device_config.json` | VID/PID, `configured`, `protocol_captured`, `trigger_discovered`, optional `trigger_cmd_hex` |
| CLI `--host`, `--port`, `--mock` | Dev override |
| systemd unit | `WorkingDirectory=/opt/sekonic-bridge`, `ExecStart=.../venv/bin/python3 server.py` |
| `bridge.log` | File + stdout logging |

**No environment variables required** for v1 — keep operator setup minimal.

### Network / security

- Bridge binds **`0.0.0.0:8765`** on show LAN.
- **No auth, no TLS** — acceptable only on isolated VLAN; document in README.
- Console `config.json` is local-only; never commit.

---

## Alternatives Considered

| Category | Recommended | Alternative | Why not for v1 |
|----------|-------------|-------------|----------------|
| Bridge framework | FastAPI + uvicorn | Flask + gunicorn | Prototype already FastAPI; async lock + lifespan fit measure blocking |
| Bridge framework | FastAPI | Node.js / Go binary | Python stack matches skreader port; team brownfield knowledge |
| Console HTTP | LuaSocket raw HTTP/1.0 | `socket.http` module | Not guaranteed on MA3; raw TCP proven |
| Console HTTP | HTTP on LAN | HTTPS to bridge | MA3 cannot do TLS from plugin |
| Console HTTP | Lua plugin | `io.popen("curl ...")` | `io.popen` unavailable on console OS |
| Meter API | Pi USB bridge | Native Sekonic HTTP | Not confirmed for C-7000; research deferred |
| Meter driver | pyusb bulk (skreader) | Official Sekonic SDK | No public Python SDK; skreader is community-validated |
| Lua tests | Host `lua5.4` + require pure modules | In-console tests | No test runner on MA3 |
| Bridge tests | pytest + mock | Hardware-only QA | Too slow for regression; meter_mock exists |
| Pi deploy | systemd + setup-pi.sh | Docker container | Overkill for single Python service on constrained Pi |
| JSON on console | Regex encode/decode | Embed dkjson | Extra binary dep; regex works for small schemas |

---

## Installation (v1 standard)

### GrandMA3 plugin

```bash
# No build — copy folder to MA3 plugin library
# Windows: C:\ProgramData\MALightingTechnology\gma3_library\datapools\plugins\SekonicCalibrator\
# macOS/Linux: ~/MALightingTechnology/gma3_library/datapools/plugins/SekonicCalibrator/
cp data/config.json.example config.json
# Edit bridge_ip to Pi address on show network
```

### Pi bridge

```bash
# Option A: flash sekonic-bridge-pi.img.gz (build-image.sh output)
# Option B: on existing Pi OS Lite:
curl -fsSL https://raw.githubusercontent.com/.../setup-pi.sh | sudo bash

# Dev mock (any Linux/macOS):
cd sekonic-bridge
python3 -m venv venv && ./venv/bin/pip install -r requirements.txt
./venv/bin/python server.py --mock --host 0.0.0.0 --port 8765
```

### Host tests

```bash
lua5.4 test_color_math.lua          # expect: 126 passed, 0 failed (grow as modules split)
curl -s http://localhost:8765/status
curl -s -X POST http://localhost:8765/measure
```

---

## v1 Stack Evolution (from brownfield)

| Area | Keep from prototype | Change in v1 replan |
|------|---------------------|---------------------|
| Languages | Lua 5.4 + Python 3.12 | Modular Lua files; shared `require` for testable pure logic |
| HTTP client | LuaSocket HTTP/1.0 | Extract `bridge_client.lua`; add host tests for regex parsers |
| Bridge | FastAPI/uvicorn/pyusb pins | Add pytest suite; optional rename `meter_c7000_hid.py` |
| Testing | `test_color_math.lua`, `meter_mock` | Eliminate Section 2/2b duplication; test `goals_met` on host |
| Versions | Align `plugin.xml`, Lua header, bridge `/status` version | Single semver story in v1 release |
| CI | None today | Add GitHub workflow: `lua5.4 test_color_math.lua` + `pytest sekonic-bridge/tests` |

---

## Sources

| Source | Confidence | Used for |
|--------|------------|----------|
| `.planning/PROJECT.md` | HIGH | v1 scope, constraints, topology |
| `.planning/codebase/STACK.md` | HIGH | Branch matrix, pinned versions, deployment |
| `.planning/codebase/INTEGRATIONS.md` | HIGH | API contracts, USB protocol, mock workflow |
| `.planning/codebase/TESTING.md` | HIGH | lua5.4 harness, meter_mock, gaps |
| `origin/claude/sekonic-remote-api-research-HdMTl` — `_http_request`, `server.py`, `requirements.txt` | HIGH | Validated implementation patterns |
| [MA Lighting — What is Lua (GMA3)](https://help.malighting.com/grandMA3/2.2/HTML/lua.html) | HIGH | Lua 5.4.6 on MA3 |
| [MA Lighting Forum — LuaSocket / blocking plugins](https://forum.malighting.com/forum/thread/7973-non-blocking-plugins/) | MEDIUM | Coroutine + TCP timeout behavior |
| [kinglevel/skreader](https://github.com/kinglevel/skreader) | HIGH | C-7000 USB command sequence |

---

*Stack research for Lighttune v1 replan — prescriptive recommendation: retain proven LuaSocket + FastAPI/pyusb stack, modularize Lua, add pytest around existing meter_mock.*
