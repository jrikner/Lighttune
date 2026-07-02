# External Integrations

**Analysis Date:** 2026-07-01

## Branch Summary

| Integration | `origin/claude/lighttune-main` (v0.4) | Sekonic branches (v0.5) |
|-------------|--------------------------------------|-------------------------|
| Sekonic meter | Manual MessageBox entry | Manual **or** HTTP bridge auto-read |
| USB / HID | None | Pi bridge via pyusb bulk |
| HTTP bridge (8765) | None | FastAPI REST API |
| Lua → bridge client | None | LuaSocket TCP + HTTP/1.0 |
| `config.json` bridge fields | None | `bridge_ip`, `bridge_port` |
| Mock meter dev mode | N/A | `server.py --mock` |

---

## APIs & External Services

### GrandMA3 Console API (all branches)

- **Purpose:** UI dialogs, fixture selection, chromaticity correction, patch/GDTF introspection.
- **Client:** Built-in GrandMA3 Lua bindings (no SDK package in repo).
- **Auth:** Console session / showfile context.
- **Key call sites** in `lua/SekonicCalibrator.lua`:
  - `MessageBox({...})` — all user input and workflow UI.
  - `Cmd('Group "..."')` — select fixture group.
  - `SetColor("xyY", ...)` / `SetColor("HSB", ...)` fallback — apply correction.
  - `DataPool()` → patch chain — fixture make/model, DMX attributes (Tint, CTO, CTB, ColorWheel).
  - `GetPath(Enums.PathType.PluginLibrary)`, `GetPathSeparator()`, `HostOS()` — path resolution.

### Sekonic Bridge HTTP API (Sekonic branches only)

- **Purpose:** Trigger C-7000 measurements remotely; return CCT, Duv, CRI, R9, TLCI as JSON.
- **Server:** `sekonic-bridge/server.py` (FastAPI + uvicorn).
- **Default bind:** `0.0.0.0:8765`.
- **Auth:** None (show-network trust model; no TLS).
- **Concurrency:** `/measure` uses `asyncio.Lock`; concurrent requests return **HTTP 409**.

| Method | Path | Behavior |
|--------|------|----------|
| `GET` | `/status` | Health, meter connection, setup flags, uptime |
| `POST` | `/measure` | Trigger measurement; **blocks up to 35 s**; returns JSON readings |
| `GET` | `/discover` | Scan USB; save VID/PID to `device_config.json` |
| `POST` | `/capture` | Passive listen / test measure; protocol verification |
| `POST` | `/learn_trigger` | Probe HID trigger candidates (fallback for unknown meters) |

**`/status` response fields:** `status`, `meter`, `connected`, `uptime_s`, `last_error`, `version`, `device_configured`, `protocol_captured`, `trigger_discovered`.

**`/measure` response fields:** `cct`, `duv`, `cri`, `r9`, `tlci` (optional), `timestamp`.

**Error codes:** 503 (`meter_not_connected`), 409 (`measurement_in_progress`), 504 (`measurement_timeout`), 500 (`measurement_error`).

### GrandMA3 Lua → Bridge HTTP Client (v0.5)

- **Purpose:** Console at FOH calls Pi bridge without leaving the plugin.
- **Implementation:** `require("socket")` (LuaSocket) — **not** `curl`, **not** `socket.http` module, **not** HTTPS.
- **Protocol:** Raw **HTTP/1.0 over TCP** (`_http_request()` in `lua/SekonicCalibrator.lua`, Section 2c).
- **Constraints documented in source:** `io.popen()` / `os.execute()` unavailable; `lua.ftp` implies TCP socket availability.
- **Call sites:**
  - `bridge_fetch_measurement(config)` — `POST /measure`, 38 s timeout.
  - `bridge_check_status(config)` — `GET /status`, 5 s timeout.
  - Bridge setup wizard — `GET /discover`, `POST /capture`, `POST /learn_trigger`.
- **Response parsing:** Regex extraction from JSON body (no JSON library in Lua).

**User-facing flow (v0.5):**
1. Operator sets `bridge_ip` / `bridge_port` in `config.json`.
2. Main menu adds **Bridge Status** (connectivity + setup wizard).
3. During calibration, if `bridge_ip` set: **Remote Measurement** vs **Enter Manually**.
4. **Auto-loop mode:** After first remote measure, subsequent attempts auto-trigger bridge until `goals_met()` or 3 cycles (`MAX_AUTO_ATTEMPTS = 3`).

### Sekonic C-7000 USB / HID (Sekonic branches — Pi side)

- **Purpose:** Programmatic measurement trigger and result read on stage.
- **Driver:** `sekonic-bridge/meter_c7000_hid.py` (`C7000HID` class).
- **Library:** pyusb (USB **bulk**, not HID report API despite filename).
- **Protocol source:** [kinglevel/skreader](https://github.com/kinglevel/skreader) (MIT) — derived from official Sekonic C# SDK.

| Constant | Value |
|----------|-------|
| Vendor ID | `0x0A41` |
| Product ID | `0x7003` |
| OUT endpoint | `0x02` (bulk) |
| IN endpoint | `0x81` (bulk) |
| Response size | 2380 bytes |
| ACK pattern | `0x06 0x30` |

**Command sequence:**
```
RT1 → ACK           — enable remote mode
RM0 → ACK           — trigger measurement
ST  → 5-byte status — poll every 50 ms until idle
NR  → ACK + 2380 B  — retrieve result
RT0 → ACK           — disable remote mode
```

**Response byte offsets (big-endian float32 + range flag):**

| Field | Offset |
|-------|--------|
| CCT (K) | 50 |
| Duv | 55 |
| CRI Ra | 348 |
| R9 | 393 |
| TLCI | Not in standard NR response (FW > 25 extended mode) |

**Discovery CLI:** `sekonic-bridge/discover_device.py` — standalone USB scan; writes `device_config.json`.

**Pi USB permissions:** udev rule `/etc/udev/rules.d/99-sekonic-c7000.rules` (broad fallback in `setup-pi.sh`; tighten to VID/PID after `lsusb`).

### Sekonic spectrometers — manual path (all branches)

- **Models:** C-700, C-800 (no TLCI), C-7000 (full incl. TLCI).
- **Integration:** Operator reads meter display; enters values via `MessageBox` prompts.
- **v0.4 (main):** Only manual path.
- **v0.5:** Manual remains available as fallback when bridge fails or operator chooses **Enter Manually**.

### Mock meter (development — Sekonic branches)

- **Purpose:** Test full Lua ↔ bridge integration without Pi or C-7000.
- **Implementation:** `sekonic-bridge/meter_mock.py` (`MockMeter` class).
- **Activation:** `python3 server.py --mock` or `./start.sh --mock`.
- **Behavior:** Simulates converging calibration progression (~4100K/CRI72 → ~5605K/CRI94) across successive `/measure` calls; small random jitter per call. Counter resets on server restart.
- **Status flags:** Mock mode reports all setup flags (`device_configured`, `protocol_captured`, `trigger_discovered`) as true.
- **Dev workflow:** Set `bridge_ip` in `config.json` to dev machine IP; run mock server on port 8765. Documented in `AGENTS.md` (`origin/cursor/setup-dev-environment-4246`).

### GitHub / Lighttune community (all branches — manual only)

- **Purpose:** Share fixture measurement records (project: https://github.com/jrikner/Lighttune-0.1).
- **Integration:** **Manual export** of `data/fixture_log.json` — no authenticated API.
- **Automatic upload:** Not implemented (HTTPS unavailable in console Lua).
- **`github_username` in `config.json`:** Used as `contributor` field in local JSON records only.

---

## Data Storage

**Databases:** None (no SQL/NoSQL).

**Local JSON — Lua plugin:**
- `data/fixture_log.json` — append-only measurement database; custom regex JSON encode/decode in Section 2b.
- Schema: `make`, `model`, `kelvin`, `date`, `contributor`, `cct`, `duv`, `cri`, `r9`, `tlci`, best-value flags.

**Local JSON — sekonic-bridge (Sekonic branches):**
- `sekonic-bridge/device_config.json` — USB discovery persistence (`vendor_id`, `product_id`, `configured`, `protocol_captured`, `trigger_discovered`, optional `trigger_cmd_hex` for Wireshark fallback).
- `sekonic-bridge/bridge.log` — measurement and error log (file handler in `server.py`).

**Config file — Lua plugin:**
- `config.json` at plugin root (optional, gitignored).
- **main:** `github_username` only (`data/config.json.example`).
- **Sekonic branches:** adds `bridge_ip`, `bridge_port` (example: `"192.168.1.50"`, `8765`).

**Caching:** In-memory `fixture_records` table per session (Lua); bridge holds singleton `_meter` instance (Python).

---

## Authentication & Identity

- **Bridge API:** No auth — intended for isolated show VLAN.
- **Console plugin:** No login; optional `github_username` for local record attribution.
- **Pi SSH:** Enabled by `setup-pi.sh` for remote administration (out-of-band from bridge API).

---

## Monitoring & Observability

**Bridge (Sekonic branches):**
- `bridge.log` in install directory.
- systemd journal: `journalctl -u sekonic-bridge -f`.
- `/status` endpoint for programmatic health checks.

**Lua plugin:**
- No structured logging; errors via `MessageBox` in `pcall`-wrapped `main()`.
- v0.5 **Bridge Status** menu for operator-visible connectivity diagnostics.

---

## CI/CD & Deployment

**Lua plugin hosting:** GrandMA3 on-premise plugin library — manual folder copy + import.

**Bridge hosting:** Raspberry Pi on stage (recommended Pi Zero 2W) or dev machine in mock mode.

**Deployment paths:**
- **Pi Option 1:** Flash `sekonic-bridge-pi.img.gz` from `build-image.sh`.
- **Pi Option 2:** `curl .../setup-pi.sh | sudo bash` on existing Pi OS Lite.
- **Dev:** `cd sekonic-bridge && ./venv/bin/python server.py --mock --port 8765`.

**CI pipeline:** None in repository.

---

## Environment Configuration

**Required for remote measurement (v0.5):**
- `config.json` at plugin root with `bridge_ip` (Pi or dev machine on show network).
- Optional `bridge_port` (defaults to **8765** in `load_config()`).

**Example (`data/config.json.example` on Sekonic branches):**
```json
{
  "github_username":   "your_github_username",
  "bridge_ip":         "192.168.1.50",
  "bridge_port":       8765
}
```

**Pi-side:** No env vars; USB permissions via udev; service user `sekonic`.

**Secrets:** `config.json` gitignored; no tokens required for bridge. GitHub token fields removed from v0.5 example (community upload disabled).

---

## Network Topology

```
[Sekonic C-7000] ──USB──► [Raspberry Pi :8765 FastAPI]
                              │
                         WiFi / Ethernet (show network)
                              │
                              ▼
                    [GrandMA3 Console @ FOH]
                    lua/SekonicCalibrator.lua
                    LuaSocket TCP → POST /measure
                              │
                              ▼
                    [iPhone Safari WebRemote]  (optional operator UI)
```

**Latency:** `/measure` blocks 2–5 s typical (mock ~1.5 s); up to 35 s timeout for real hardware.

**iPhone note:** iOS cannot USB-connect to C-7000; operator uses GrandMA3 WebRemote while bridge handles meter I/O on Pi.

---

## Webhooks & Callbacks

**Incoming:** Bridge REST endpoints on port 8765 (console-initiated only).

**Outgoing:** None from plugin or bridge (no push notifications, no cloud webhooks).

---

## Integration Gaps (main vs Sekonic)

| Capability | `lighttune-main` | Sekonic branches |
|------------|------------------|------------------|
| Remote C-7000 trigger | ❌ | ✅ via bridge |
| Auto-loop until goals met | ❌ | ✅ (bridge mode) |
| Bridge setup wizard in plugin | ❌ | ✅ |
| TLCI from bridge | ❌ | ✅ (when meter/FW supports) |
| HTTPS / GitHub auto-upload | ❌ | ❌ (unchanged) |

---

*Integration audit: 2026-07-01 — multi-branch (main baseline + sekonic-remote-api-research-HdMTl + Lighttune-experimental + setup-dev-environment-4246)*
