"""
Sekonic C-7000 Bridge Server
Lighttune – Remote Measurement Bridge

Exposes a simple REST API over the show network so the GrandMA3 Lua plugin
can trigger measurements on the Sekonic C-7000 and read values remotely.

Endpoints:
  GET  /status        — health check, meter connection state
  POST /measure       — trigger a measurement, blocks until complete (up to 35s)
  GET  /discover      — scan USB, find Sekonic meter, save VID/PID to device_config.json
  POST /capture       — listen passively for one HID report (user presses meter button),
                        capture raw bytes, attempt auto-parse, save to device_config.json
  POST /learn_trigger — probe candidate HID trigger commands to discover the remote
                        trigger byte sequence; saves result to device_config.json
  GET  /dashboard     — bridge setup/status web UI
  GET  /fixtures      — fixture measurement log web UI (synced from console)
  GET  /fixture_log   — JSON fixture log
  POST /fixture_log   — replace fixture log from console plugin upload

Usage:
  python3 server.py [--host 0.0.0.0] [--port 8765] [--mock]

  --mock    Use the mock meter (no hardware needed, for testing)
"""

import argparse
import asyncio
import json
import logging
import os
import struct
import sys
import time
from contextlib import asynccontextmanager
from datetime import datetime, timezone
from pathlib import Path

from fastapi import Depends, FastAPI, Header, HTTPException, Request
from fastapi.responses import HTMLResponse, JSONResponse
import uvicorn

# ── logging ──────────────────────────────────────────────────────────────────

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)-7s  %(message)s",
    handlers=[
        logging.StreamHandler(sys.stdout),
        logging.FileHandler("bridge.log", encoding="utf-8"),
    ],
)
log = logging.getLogger("sekonic-bridge")

# ── device config (auto-discovery persistence) ────────────────────────────────

INSTALL_DIR = Path(__file__).parent
DEVICE_CONFIG_PATH = INSTALL_DIR / "device_config.json"
BRIDGE_CONFIG_PATH = INSTALL_DIR / "bridge_config.json"

_bridge_api_key: str | None = None  # cached; None = not yet loaded


def _load_bridge_api_key() -> str:
    """Load optional API key from BRIDGE_API_KEY env or bridge_config.json."""
    env_key = os.environ.get("BRIDGE_API_KEY", "").strip()
    if env_key:
        return env_key
    if BRIDGE_CONFIG_PATH.exists():
        try:
            cfg = json.loads(BRIDGE_CONFIG_PATH.read_text())
            file_key = cfg.get("bridge_api_key", "")
            if isinstance(file_key, str):
                return file_key.strip()
        except Exception:
            pass
    return ""


def _get_bridge_api_key() -> str:
    global _bridge_api_key
    if _bridge_api_key is None:
        _bridge_api_key = _load_bridge_api_key()
    return _bridge_api_key


def _auth_required() -> bool:
    return bool(_get_bridge_api_key())


async def verify_bridge_key(
    x_bridge_key: str | None = Header(None, alias="X-Bridge-Key"),
) -> None:
    """Reject requests when a key is configured but the header is missing or wrong."""
    key = _get_bridge_api_key()
    if not key:
        return
    if x_bridge_key != key:
        raise HTTPException(
            status_code=401,
            detail={"error": "unauthorized", "hint": "Send X-Bridge-Key header"},
        )


def _atomic_write_text(path: Path, content: str) -> None:
    """Write file atomically via temp + replace."""
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(content)
    tmp.replace(path)


def _load_device_config() -> dict:
    """Load device_config.json if it exists, else return empty dict."""
    if DEVICE_CONFIG_PATH.exists():
        try:
            return json.loads(DEVICE_CONFIG_PATH.read_text())
        except Exception:
            pass
    return {}


def _save_device_config(cfg: dict) -> None:
    """Persist device_config.json atomically."""
    _atomic_write_text(DEVICE_CONFIG_PATH, json.dumps(cfg, indent=2))


def _is_device_configured() -> bool:
    cfg = _load_device_config()
    return bool(cfg.get("configured"))


ALLOWED_METER_MODELS = ["C-700", "C-800", "C-7000"]


def _get_meter_model() -> str:
    cfg = _load_device_config()
    model = cfg.get("meter_model")
    return model if model in ALLOWED_METER_MODELS else "C-7000"


def _is_protocol_captured() -> bool:
    cfg = _load_device_config()
    return bool(cfg.get("protocol_captured"))


def _is_trigger_discovered() -> bool:
    cfg = _load_device_config()
    return bool(cfg.get("trigger_discovered"))


# ── fixture log (synced from GrandMA3 plugin) ────────────────────────────────

FIXTURE_LOG_PATH = INSTALL_DIR / "fixture_log.json"
_fixture_log_updated_at: str | None = None


def _load_fixture_log() -> list[dict]:
    if not FIXTURE_LOG_PATH.exists():
        return []
    try:
        data = json.loads(FIXTURE_LOG_PATH.read_text())
    except Exception:
        return []
    if isinstance(data, list):
        return data
    if isinstance(data, dict) and isinstance(data.get("records"), list):
        return data["records"]
    return []


def _save_fixture_log(records: list[dict]) -> None:
    global _fixture_log_updated_at
    _atomic_write_text(FIXTURE_LOG_PATH, json.dumps(records, indent=2))
    _fixture_log_updated_at = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _normalize_fixture_record(raw: object, index: int) -> dict:
    if not isinstance(raw, dict):
        raise HTTPException(
            status_code=422,
            detail={"error": "invalid_record",
                    "hint": f"record {index} must be an object"},
        )
    make = raw.get("make")
    model = raw.get("model")
    kelvin = raw.get("kelvin")
    if not isinstance(make, str) or not make.strip():
        raise HTTPException(
            status_code=422,
            detail={"error": "invalid_record",
                    "hint": f"record {index}: make is required"},
        )
    if not isinstance(model, str) or not model.strip():
        raise HTTPException(
            status_code=422,
            detail={"error": "invalid_record",
                    "hint": f"record {index}: model is required"},
        )
    try:
        kelvin_i = int(kelvin)
    except (TypeError, ValueError):
        raise HTTPException(
            status_code=422,
            detail={"error": "invalid_record",
                    "hint": f"record {index}: kelvin must be an integer"},
        )

    rec: dict = {
        "make": make.strip(),
        "model": model.strip(),
        "kelvin": kelvin_i,
    }
    for key in ("date", "contributor"):
        val = raw.get(key)
        if isinstance(val, str) and val.strip():
            rec[key] = val.strip()
    for key in ("cct", "cri", "r9", "tlci"):
        val = raw.get(key)
        if val is not None:
            try:
                rec[key] = int(val)
            except (TypeError, ValueError):
                pass
    duv = raw.get("duv")
    if duv is not None:
        try:
            rec["duv"] = float(duv)
        except (TypeError, ValueError):
            pass
    for key in ("best_cri", "best_r9", "best_tlci", "best_duv"):
        if raw.get(key) is True:
            rec[key] = True
    return rec


def _fixture_log_payload() -> dict:
    records = _load_fixture_log()
    return {
        "records": records,
        "count": len(records),
        "updated_at": _fixture_log_updated_at,
    }


def _build_trigger_candidates() -> list:
    """
    Return a prioritised list of candidate HID trigger byte sequences.
    Shortest and most common patterns first; the probe loop stops as soon as
    one produces a valid measurement response.
    """
    cands = []
    # 1-byte: report IDs 0x00–0x0F (most HID light meters use a single byte)
    for b in range(0x10):
        cands.append(bytes([b]))
    # 2-byte: leading report ID 0x00 or 0x01 with command byte
    for b in range(0x10):
        cands.append(bytes([0x00, b]))
        cands.append(bytes([0x01, b]))
    # 4-byte patterns common for Sekonic-family HID (command in byte 3)
    for cmd in [0x01, 0x02, 0x03, 0x04]:
        cands.append(bytes([0x00, 0x00, 0x00, cmd]))
    return cands


# ── meter backend ─────────────────────────────────────────────────────────────

_meter = None
_start_time = time.time()
_last_error: str | None = None
_measurement_lock = asyncio.Lock()   # prevent concurrent /measure calls


def _load_meter(use_mock: bool):
    """Instantiate and connect the appropriate meter backend."""
    global _meter, _last_error
    if use_mock:
        from meter_mock import MockMeter, mock_plant
        backend = MockMeter(mock_plant)
        log.info("Using MOCK meter backend (development mode)")
    else:
        from meter_c7000_bulk import C7000Bulk
        backend = C7000Bulk()
        log.info("Using C-7000 USB bulk backend")

    log.info("Connecting to meter…")
    try:
        ok = backend.connect()
        if ok:
            log.info("Meter connected successfully")
        else:
            _last_error = "meter_not_found"
            log.warning("Meter not found – is the C-7000 plugged in?")
    except Exception as exc:
        _last_error = str(exc)
        log.error("Failed to connect: %s", exc)
        ok = False

    _meter = backend
    return ok


# ── FastAPI app ───────────────────────────────────────────────────────────────

_use_mock_global = False  # set by CLI before app start


@asynccontextmanager
async def lifespan(app: FastAPI):
    _load_meter(_use_mock_global)
    yield
    if _meter is not None:
        try:
            _meter.disconnect()
        except Exception:
            pass
    log.info("Bridge server shut down")


app = FastAPI(
    title="Sekonic C-7000 Bridge",
    description="Remote measurement bridge for Lighttune SekonicCalibrator",
    version="0.5.0-replan",
    lifespan=lifespan,
)
# verify_bridge_key is applied per-route (not as an app-wide dependency) so
# that GET /dashboard can be reached by a plain browser navigation (which
# can't attach a custom X-Bridge-Key header) even when an API key is
# configured. The dashboard page itself carries no sensitive data -- it's
# static HTML/JS; the JSON API calls that page makes from JavaScript still
# go through this same dependency and still require the key.
_auth = [Depends(verify_bridge_key)]


@app.get("/status", dependencies=_auth)
async def status():
    """Return bridge health, meter connection state, and configuration status."""
    connected = _meter is not None and _meter.is_connected()
    return {
        "status":             "ok",
        "meter":              _get_meter_model(),
        "connected":          connected,
        "uptime_s":           int(time.time() - _start_time),
        "last_error":         _last_error,
        "version":            "0.5.0-replan",
        "device_configured":  _is_device_configured()  or _use_mock_global,
        "protocol_captured":  _is_protocol_captured()  or _use_mock_global,
        "trigger_discovered": _is_trigger_discovered() or _use_mock_global,
        "auth_required":      _auth_required(),
    }


@app.post("/device_model", dependencies=_auth)
async def set_device_model(request: Request):
    """
    Set which Sekonic meter model the bridge (and the dashboard's status
    display) should report itself as. This is an operator-asserted label
    persisted to device_config.json -- distinct from the auto-detected
    VID/PID from /discover, which identifies the USB device itself.
    Moved here from the GrandMA3 plugin (v2 plan: device model selection
    lives in the bridge dashboard, not in a console dialog).
    """
    try:
        body = await request.json()
    except Exception:
        raise HTTPException(status_code=400, detail={"error": "invalid_json"})

    model = body.get("model") if isinstance(body, dict) else None
    if model not in ALLOWED_METER_MODELS:
        raise HTTPException(
            status_code=422,
            detail={"error": "invalid_model",
                    "hint": f"model must be one of {ALLOWED_METER_MODELS}"},
        )

    cfg = _load_device_config()
    cfg["meter_model"] = model
    _save_device_config(cfg)
    log.info("Meter model set to %s", model)
    return {"ok": True, "meter_model": model}


@app.post("/restart", dependencies=_auth)
async def restart():
    """
    Restart the bridge process itself, relying on the OS-level service
    supervisor to relaunch it -- this is the "restart" button on the
    dashboard, for when the bridge needs a clean reconnect to the meter
    (e.g. after a USB hiccup) without SSHing into the Pi/Mac.

    Exits with status 1 (not 0) deliberately: the macOS launchd unit
    (com.lighttune.sekonic-bridge.plist) uses KeepAlive.SuccessfulExit =
    false, which means launchd relaunches the job only on an UNSUCCESSFUL
    exit -- a clean sys.exit(0) would be treated as "done on purpose" and
    NOT relaunched, leaving the bridge down until someone logs in and
    restarts it by hand. The systemd unit (sekonic-bridge.service) uses
    Restart=always, which relaunches on any exit code, so exit(1) is safe
    there too. The actual process exit is deferred slightly so this
    response can flush to the client first.
    """
    log.warning("Restart requested via /restart -- exiting for supervisor relaunch")

    async def _delayed_exit():
        await asyncio.sleep(0.3)
        if _meter is not None:
            try:
                _meter.disconnect()
            except Exception:
                pass
        os._exit(1)

    asyncio.get_event_loop().create_task(_delayed_exit())
    return {"ok": True, "message": "Restarting -- the service supervisor will relaunch the bridge in a few seconds."}


_DASHBOARD_HTML = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>SEKONIC BRIDGE // LIGHTTUNE</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Archivo:wght@800;900&family=JetBrains+Mono:wght@400;500;700&display=swap" rel="stylesheet">
<style>
  :root {
    --bg:#0d0d0d; --panel:#121212; --line:#2b2b2b; --line-2:#1e1e1e;
    --fg:#eaeaea; --dim:#8a8a8a; --faint:#565656;
    --red:#e61919; --green:#4af626;
    --mono:"JetBrains Mono",ui-monospace,"SF Mono",Menlo,monospace;
    --head:"Archivo","Helvetica Neue",Arial,sans-serif;
  }
  * { box-sizing:border-box; border-radius:0 !important; }
  html,body { margin:0; }
  body {
    background:var(--bg); color:var(--fg);
    font:13px/1.5 var(--mono); letter-spacing:0.02em;
    -webkit-font-smoothing:antialiased; padding:0; position:relative;
  }
  /* grain */
  body::before {
    content:""; position:fixed; inset:0; z-index:2; pointer-events:none; opacity:0.05;
    background-image:url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='120' height='120'%3E%3Cfilter id='n'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='0.9' numOctaves='2' stitchTiles='stitch'/%3E%3C/filter%3E%3Crect width='100%25' height='100%25' filter='url(%23n)'/%3E%3C/svg%3E");
  }
  /* scanlines */
  body::after {
    content:""; position:fixed; inset:0; z-index:3; pointer-events:none;
    background:repeating-linear-gradient(0deg, rgba(0,0,0,0) 0, rgba(0,0,0,0) 2px, rgba(0,0,0,0.22) 3px, rgba(0,0,0,0) 4px);
  }
  .wrap { max-width:760px; margin:0 auto; padding:26px 22px 40px; position:relative; z-index:1; }

  .uppercase { text-transform:uppercase; }
  .frame { border:1px solid var(--line); position:relative; }

  .topbar { display:flex; align-items:center; justify-content:space-between;
    padding:12px 16px; border:1px solid var(--line); border-bottom:2px solid var(--red);
    text-transform:uppercase; letter-spacing:0.12em; }
  .topbar .id { color:var(--fg); font-weight:700; }
  .topbar .id b { color:var(--red); }
  .topbar .rev { color:var(--dim); font-size:11px; }

  .keyrow { display:none; gap:0; margin-top:16px; border:1px solid var(--line); }
  .keyrow.show { display:flex; }
  .keyrow input { flex:1; min-width:160px; }

  /* macro status */
  .macro { border:1px solid var(--line); border-top:none; padding:30px 20px 26px; position:relative; }
  .macro .meta-top { display:flex; justify-content:space-between; align-items:center;
    color:var(--dim); font-size:11px; text-transform:uppercase; letter-spacing:0.14em; margin-bottom:18px; }
  .macro .live { display:inline-flex; align-items:center; gap:8px; }
  .macro .beacon { width:9px; height:9px; background:var(--faint); display:inline-block; }
  .macro .beacon.on { background:var(--green); animation:blink 1.15s steps(1) infinite; }
  .macro .beacon.off { background:var(--red); }
  @keyframes blink { 50% { opacity:0.25; } }
  .macro h1 { font-family:var(--head); font-weight:900; text-transform:uppercase;
    font-size:clamp(3.2rem,13vw,8.5rem); line-height:0.84; letter-spacing:-0.045em; margin:0; }
  .macro .state { margin-top:14px; font-size:clamp(0.95rem,2.6vw,1.35rem);
    text-transform:uppercase; letter-spacing:0.18em; color:var(--dim); }
  .macro .state b { font-weight:700; }
  .macro .state .on { color:var(--green); } .macro .state .off { color:var(--red); }
  .macro .sub { margin-top:12px; max-width:56ch; color:var(--dim); font-size:12px;
    text-transform:uppercase; letter-spacing:0.05em; line-height:1.6; }
  .cross { position:absolute; color:var(--faint); font-size:14px; line-height:1; }
  .cross.tr { top:-7px; right:-7px; } .cross.bl { bottom:-7px; left:-7px; }

  /* telemetry grid */
  .telemetry { display:grid; grid-template-columns:repeat(4,1fr); gap:1px;
    background:var(--line); border:1px solid var(--line); border-top:none; }
  .cell { background:var(--bg); padding:13px 15px; }
  .cell .l { color:var(--faint); font-size:10px; text-transform:uppercase; letter-spacing:0.12em; }
  .cell .v { margin-top:7px; font-size:14px; font-weight:500; text-transform:uppercase; letter-spacing:0.06em; }
  .cell .v.on { color:var(--green); } .cell .v.off { color:var(--red); }
  @media (max-width:560px) { .telemetry { grid-template-columns:repeat(2,1fr); } }

  .err-line { display:none; margin-top:16px; border:1px solid var(--red); padding:11px 14px;
    color:var(--red); font-size:12px; text-transform:uppercase; letter-spacing:0.06em; }
  .err-line.show { display:block; }
  .err-line b { color:var(--red); }

  .sec { margin-top:26px; }
  .sec-h { color:var(--dim); font-size:11px; text-transform:uppercase; letter-spacing:0.16em;
    padding-bottom:10px; border-bottom:1px solid var(--line); margin-bottom:2px; }
  .sec-h b { color:var(--red); font-weight:400; }

  .row { display:flex; align-items:center; gap:16px; padding:15px 2px; border-bottom:1px solid var(--line-2); }
  .row .k { text-transform:uppercase; letter-spacing:0.05em; color:var(--fg); font-size:12px; }
  .row .d { color:var(--faint); font-size:11px; text-transform:uppercase; letter-spacing:0.04em; margin-top:4px; }
  .row .tag { margin-left:auto; flex:none; }

  .tag { display:inline-block; font-size:11px; text-transform:uppercase; letter-spacing:0.08em;
    padding:4px 9px; border:1px solid currentColor; color:var(--dim); }
  .tag.ok { color:var(--fg); } .tag.warn { color:var(--red); } .tag.info { color:var(--dim); }

  .controls { display:flex; align-items:stretch; gap:0; margin-top:16px; flex-wrap:wrap; }
  input, select, .btn {
    font:12px/1 var(--mono); text-transform:uppercase; letter-spacing:0.08em;
    background:var(--bg); color:var(--fg); border:1px solid var(--line); padding:12px 14px;
  }
  input::placeholder { color:var(--faint); }
  input:focus, select:focus { outline:none; border-color:var(--fg); }
  .btn { cursor:pointer; background:transparent; color:var(--fg); border-color:var(--fg);
    transition:background .08s steps(1), color .08s steps(1); }
  .btn:hover { background:var(--fg); color:var(--bg); }
  .btn:active { transform:translate(1px,1px); }
  .btn.danger { color:var(--red); border-color:var(--red); }
  .btn.danger:hover { background:var(--red); color:var(--bg); }
  .btn + .btn { margin-left:-1px; }
  .btn-grid { display:flex; flex-wrap:wrap; margin-top:16px; }

  .msg { font-size:11px; margin-top:14px; min-height:15px; color:var(--dim);
    text-transform:uppercase; letter-spacing:0.05em; white-space:pre-wrap; word-break:break-word; }
  .msg.ok { color:var(--green); } .msg.err { color:var(--red); }
  .msg.inline { margin:0 0 0 14px; align-self:center; }

  .foot { margin-top:34px; padding-top:14px; border-top:2px solid var(--red);
    color:var(--faint); font-size:10px; text-transform:uppercase; letter-spacing:0.18em;
    display:flex; justify-content:space-between; }
  .foot a.nav { color:var(--fg); text-decoration:none; }
  .foot a.nav:hover { text-decoration:underline; }

  .reveal { opacity:0; transform:translateY(8px);
    transition:opacity .3s steps(5), transform .3s ease-out; transition-delay:calc(var(--i,0) * 55ms); }
  .reveal.in { opacity:1; transform:none; }
  @media (prefers-reduced-motion: reduce) { .reveal { opacity:1; transform:none; transition:none; } }
</style>
</head>
<body>
  <div class="wrap">
    <div class="topbar reveal">
      <span class="id">SEKONIC BRIDGE <b>///</b></span>
      <span class="rev"><span id="version">VERSION —</span></span>
    </div>

    <div id="keyRow" class="keyrow reveal">
      <input id="apiKey" type="password" placeholder="BRIDGE KEY">
      <button class="btn" onclick="saveKey()">UNLOCK</button>
      <span class="msg err inline" id="keyMsg"></span>
    </div>

    <div class="macro reveal" style="--i:1">
      <span class="cross tr">+</span><span class="cross bl">+</span>
      <div class="meta-top">
        <span class="live"><span class="beacon" id="beacon"></span><span id="connBadge">CHECKING</span></span>
        <span id="connMeta"></span>
      </div>
      <h1 id="connModel">C-7000</h1>
      <div class="state" id="connState"><b>CHECKING…</b></div>
      <p class="sub" id="connSub">Reading bridge status over the show network.</p>
    </div>

    <div class="telemetry reveal" style="--i:2">
      <div class="cell"><div class="l">METER</div><div class="v" id="tLink">--</div></div>
      <div class="cell"><div class="l">UPTIME</div><div class="v" id="tUptime">--</div></div>
      <div class="cell"><div class="l">VERSION</div><div class="v" id="tVersion">--</div></div>
      <div class="cell"><div class="l">KEY</div><div class="v" id="tAuth">--</div></div>
    </div>

    <div class="err-line reveal" id="errorLine" style="--i:2"><b>ERROR:</b> <span id="errorText"></span></div>

    <div class="sec reveal" style="--i:2">
      <div class="sec-h"><b>[</b> 01 · SETUP STATUS <b>]</b></div>
      <div class="row">
        <div><div class="k">Device discovered</div><div class="d">USB meter found and identified</div></div>
        <span class="tag" id="bDevice">--</span>
      </div>
      <div class="row">
        <div><div class="k">Protocol captured</div><div class="d">Measurement format is known</div></div>
        <span class="tag" id="bProto">--</span>
      </div>
      <div class="row">
        <div><div class="k">Remote trigger</div><div class="d">Hands-free vs. physical button</div></div>
        <span class="tag" id="bTrig">--</span>
      </div>
    </div>

    <div class="sec reveal" style="--i:3">
      <div class="sec-h"><b>[</b> 02 · METER MODEL <b>]</b></div>
      <div class="controls">
        <select id="meterModel">
          <option value="C-700">C-700</option>
          <option value="C-800">C-800</option>
          <option value="C-7000">C-7000</option>
        </select>
        <button class="btn" onclick="setModel()">SAVE</button>
        <span class="msg inline" id="modelMsg"></span>
      </div>
    </div>

    <div class="sec reveal" style="--i:4">
      <div class="sec-h"><b>[</b> 03 · ACTIONS <b>]</b></div>
      <div class="btn-grid">
        <button class="btn" onclick="doAction('/discover','GET','SCANNING FOR THE METER…')">SCAN FOR METER</button>
        <button class="btn" onclick="doAction('/capture','POST','TAKING A TEST MEASUREMENT…')">TEST MEASUREMENT</button>
        <button class="btn" onclick="doAction('/learn_trigger','POST','SEARCHING FOR THE REMOTE TRIGGER (UP TO 2 MIN)…')">FIND TRIGGER</button>
        <button class="btn danger" onclick="restart()">RESTART</button>
      </div>
      <div class="msg" id="actionMsg"></div>
    </div>

    <div class="foot"><span><a class="nav" href="/fixtures">FIXTURE LOG</a> · LIVE · UPDATES EVERY 3S</span><span>LIGHTTUNE ©</span></div>
  </div>

<script>
let apiKey = new URLSearchParams(location.search).get('key') || '';
const $ = (id) => document.getElementById(id);

function headers() {
  const h = {'Content-Type': 'application/json'};
  if (apiKey) h['X-Bridge-Key'] = apiKey;
  return h;
}

function setBeacon(state) { $('beacon').className = 'beacon' + (state ? ' ' + state : ''); }
function setTag(el, state, text) { el.className = 'tag' + (state ? ' ' + state : ''); el.textContent = text; }

function saveKey() {
  apiKey = $('apiKey').value;
  $('keyMsg').textContent = '';
  refresh();
}

async function refresh() {
  try {
    const res = await fetch('/status', {headers: headers()});
    if (res.status === 401) {
      $('keyRow').classList.add('show');
      $('keyMsg').textContent = 'KEY REQUIRED';
      setBeacon('off');
      $('connBadge').textContent = 'LOCKED';
      $('connState').innerHTML = '<b class="off">LOCKED</b>';
      $('connSub').textContent = 'This bridge needs a key. Unlock it to see the status.';
      $('connMeta').textContent = '';
      $('tLink').textContent = 'LOCKED'; $('tLink').className = 'v off';
      return;
    }
    $('keyRow').classList.remove('show');
    const d = await res.json();

    setBeacon(d.connected ? 'on' : 'off');
    $('connBadge').textContent = d.connected ? 'CONNECTED' : 'NOT CONNECTED';
    $('connModel').textContent = d.meter;
    $('connState').innerHTML = d.connected
      ? '<b class="on">CONNECTED</b> — READY TO MEASURE'
      : '<b class="off">NOT CONNECTED</b> — NO METER FOUND';
    $('connSub').textContent = d.connected
      ? 'The meter is connected. You can take measurements from the console.'
      : 'The meter is not responding on USB. Reconnect it, then press SCAN FOR METER.';
    const mins = Math.floor(d.uptime_s / 60), secs = d.uptime_s % 60;
    $('connMeta').textContent = 'RUNNING ' + mins + 'M ' + (secs < 10 ? '0' : '') + secs + 'S';

    $('tLink').textContent = d.connected ? 'CONNECTED' : 'OFFLINE';
    $('tLink').className = 'v ' + (d.connected ? 'on' : 'off');
    $('tUptime').textContent = mins + 'M ' + (secs < 10 ? '0' : '') + secs + 'S';
    $('tVersion').textContent = d.version;
    $('version').textContent = 'VERSION ' + d.version;
    $('tAuth').textContent = d.auth_required ? 'REQUIRED' : 'NOT SET';

    setTag($('bDevice'), d.device_configured ? 'ok' : 'warn', d.device_configured ? 'READY' : 'NOT READY');
    setTag($('bProto'), d.protocol_captured ? 'ok' : 'warn', d.protocol_captured ? 'READY' : 'NOT READY');
    setTag($('bTrig'), d.trigger_discovered ? 'ok' : 'info', d.trigger_discovered ? 'HANDS-FREE' : 'BUTTON PRESS');

    const errLine = $('errorLine');
    if (d.last_error) { $('errorText').textContent = String(d.last_error).toUpperCase(); errLine.classList.add('show'); }
    else { errLine.classList.remove('show'); }

    const sel = $('meterModel');
    if (document.activeElement !== sel) sel.value = d.meter;
  } catch (e) {
    setBeacon('off');
    $('connBadge').textContent = 'NOT CONNECTED';
    $('connState').innerHTML = '<b class="off">CANNOT REACH BRIDGE</b>';
    $('connSub').textContent = 'No response from the bridge service. Check that it is running.';
    $('connMeta').textContent = '';
    $('tLink').textContent = 'OFFLINE'; $('tLink').className = 'v off';
  }
}

async function setModel() {
  const model = $('meterModel').value;
  const msg = $('modelMsg');
  msg.textContent = 'SAVING…'; msg.className = 'msg inline';
  try {
    const res = await fetch('/device_model', {method: 'POST', headers: headers(), body: JSON.stringify({model})});
    const d = await res.json();
    if (res.ok) { msg.textContent = 'SAVED'; msg.className = 'msg inline ok'; refresh(); }
    else { msg.textContent = ((d.detail && d.detail.error) || 'FAILED').toUpperCase(); msg.className = 'msg inline err'; }
  } catch (e) { msg.textContent = 'REQUEST FAILED'; msg.className = 'msg inline err'; }
}

async function doAction(path, method, pendingText) {
  const msg = $('actionMsg');
  msg.textContent = pendingText; msg.className = 'msg';
  try {
    const res = await fetch(path, {method, headers: headers()});
    const d = await res.json();
    msg.textContent = (res.ok ? 'DONE: ' : 'ERROR: ') + JSON.stringify(d);
    msg.className = 'msg ' + (res.ok ? 'ok' : 'err');
    refresh();
  } catch (e) { msg.textContent = 'REQUEST FAILED: ' + e; msg.className = 'msg err'; }
}

async function restart() {
  if (!confirm('Restart the bridge now? Any measurement in progress will be interrupted.')) return;
  const msg = $('actionMsg');
  try {
    const res = await fetch('/restart', {method: 'POST', headers: headers()});
    const d = await res.json();
    msg.textContent = (d.message || 'RESTARTING…').toUpperCase();
    msg.className = 'msg ok';
  } catch (e) { msg.textContent = 'RESTART SENT — CONNECTION DROPPED, AS EXPECTED'; msg.className = 'msg ok'; }
}

if ('IntersectionObserver' in window) {
  const io = new IntersectionObserver((entries) => {
    entries.forEach((e) => { if (e.isIntersecting) { e.target.classList.add('in'); io.unobserve(e.target); } });
  }, {threshold: 0.1});
  document.querySelectorAll('.reveal').forEach((el) => io.observe(el));
} else {
  document.querySelectorAll('.reveal').forEach((el) => el.classList.add('in'));
}

refresh();
setInterval(refresh, 3000);
</script>
</body>
</html>
"""


@app.get("/dashboard", response_class=HTMLResponse)
async def dashboard():
    """
    Web dashboard: live bridge/meter status, meter-model selection (moved
    here from the GrandMA3 plugin per the v2 plan), and the setup/
    troubleshooting actions (scan/capture/discover-trigger/restart).

    Deliberately NOT behind the `_auth` per-route dependency used by the
    JSON API routes: a plain browser navigation to this URL can't attach a
    custom X-Bridge-Key header, and this route serves only static HTML/JS
    with no sensitive data. The page's own fetch() calls to the JSON
    routes below still carry the key (typed into the page, or passed as
    ?key=... in the dashboard URL) and are still fully protected.
    """
    return _DASHBOARD_HTML


_FIXTURES_HTML = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>FIXTURE LOG // LIGHTTUNE</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Archivo:wght@800;900&family=JetBrains+Mono:wght@400;500;700&display=swap" rel="stylesheet">
<style>
  :root {
    --bg:#0d0d0d; --line:#2b2b2b; --fg:#eaeaea; --dim:#8a8a8a; --faint:#565656;
    --red:#e61919; --green:#4af626;
    --mono:"JetBrains Mono",ui-monospace,"SF Mono",Menlo,monospace;
    --head:"Archivo","Helvetica Neue",Arial,sans-serif;
  }
  * { box-sizing:border-box; border-radius:0 !important; }
  html,body { margin:0; }
  body { background:var(--bg); color:var(--fg); font:13px/1.5 var(--mono); padding:0; }
  .wrap { max-width:1100px; margin:0 auto; padding:26px 22px 40px; }
  .topbar { display:flex; align-items:center; justify-content:space-between; margin-bottom:22px; }
  .topbar a { color:var(--dim); text-decoration:none; font-size:11px; letter-spacing:0.12em; text-transform:uppercase; }
  .topbar a:hover { color:var(--fg); }
  h1 { font:900 34px/1 var(--head); margin:0 0 8px; text-transform:uppercase; }
  .meta { color:var(--dim); font-size:11px; text-transform:uppercase; letter-spacing:0.08em; margin-bottom:18px; }
  .keyrow { display:none; gap:0; margin-bottom:16px; }
  .keyrow.show { display:flex; }
  input, .btn {
    font:12px/1 var(--mono); text-transform:uppercase; letter-spacing:0.08em;
    background:var(--bg); color:var(--fg); border:1px solid var(--line); padding:12px 14px;
  }
  .btn { cursor:pointer; }
  .btn:hover { background:var(--fg); color:var(--bg); }
  .table-wrap { overflow-x:auto; border:1px solid var(--line); }
  table { width:100%; border-collapse:collapse; font-size:12px; }
  th, td { padding:10px 12px; border-bottom:1px solid var(--line); text-align:left; white-space:nowrap; }
  th { color:var(--dim); font-size:10px; letter-spacing:0.1em; text-transform:uppercase; background:#111; position:sticky; top:0; }
  tr:last-child td { border-bottom:none; }
  tr:hover td { background:#151515; }
  .star { color:var(--green); }
  .empty { padding:40px 0; color:var(--dim); text-transform:uppercase; letter-spacing:0.08em; text-align:center; }
  .msg { font-size:11px; margin-top:10px; color:var(--dim); text-transform:uppercase; }
  .msg.err { color:var(--red); }
  .foot { margin-top:28px; padding-top:14px; border-top:2px solid var(--red);
    color:var(--faint); font-size:10px; text-transform:uppercase; letter-spacing:0.18em;
    display:flex; justify-content:space-between; }
</style>
</head>
<body>
  <div class="wrap">
    <div class="topbar">
      <a href="/dashboard">← SEKONIC BRIDGE</a>
      <span id="updated">—</span>
    </div>
    <h1>Fixture Log</h1>
    <div class="meta" id="summary">Loading logged fixtures…</div>

    <div id="keyRow" class="keyrow">
      <input id="apiKey" type="password" placeholder="BRIDGE KEY" style="flex:1">
      <button class="btn" onclick="saveKey()">UNLOCK</button>
    </div>

    <div class="table-wrap" id="tableWrap">
      <table id="logTable">
        <thead>
          <tr>
            <th>Make</th><th>Model</th><th>K</th><th>Date</th><th>By</th>
            <th>CCT</th><th>Duv</th><th>CRI</th><th>R9</th><th>TLCI</th><th>Best</th>
          </tr>
        </thead>
        <tbody id="logBody"></tbody>
      </table>
      <div class="empty" id="emptyState" style="display:none">No fixtures logged yet — run a calibration on the console.</div>
    </div>
    <div class="msg" id="statusMsg"></div>
    <div class="foot"><span id="countFoot">—</span><span>LIGHTTUNE ©</span></div>
  </div>
<script>
let apiKey = new URLSearchParams(location.search).get('key') || '';
const $ = (id) => document.getElementById(id);

function headers() {
  const h = {};
  if (apiKey) h['X-Bridge-Key'] = apiKey;
  return h;
}

function saveKey() {
  apiKey = $('apiKey').value;
  refresh();
}

function fmtNum(v, digits) {
  if (v === null || v === undefined || v === '') return '—';
  if (typeof v === 'number' && digits !== undefined) return v.toFixed(digits);
  return String(v);
}

function bestTags(rec) {
  const tags = [];
  if (rec.best_cri) tags.push('CRI★');
  if (rec.best_r9) tags.push('R9★');
  if (rec.best_tlci) tags.push('TLCI★');
  if (rec.best_duv) tags.push('DUV★');
  return tags.length ? tags.join(' ') : '—';
}

function renderRows(records) {
  const body = $('logBody');
  body.innerHTML = '';
  if (!records.length) {
    $('emptyState').style.display = 'block';
    $('logTable').style.display = 'none';
    return;
  }
  $('emptyState').style.display = 'none';
  $('logTable').style.display = 'table';
  for (const rec of records) {
    const tr = document.createElement('tr');
    tr.innerHTML = `
      <td>${rec.make || '—'}</td>
      <td>${rec.model || '—'}</td>
      <td>${rec.kelvin || '—'}K</td>
      <td>${rec.date || '—'}</td>
      <td>${rec.contributor || '—'}</td>
      <td>${rec.cct != null ? rec.cct + 'K' : '—'}</td>
      <td>${rec.duv != null ? (rec.duv >= 0 ? '+' : '') + fmtNum(rec.duv, 4) : '—'}</td>
      <td>${rec.cri != null ? rec.cri : '—'}</td>
      <td>${rec.r9 != null ? rec.r9 : '—'}</td>
      <td>${rec.tlci != null ? rec.tlci : '—'}</td>
      <td class="star">${bestTags(rec)}</td>`;
    body.appendChild(tr);
  }
}

async function refresh() {
  const msg = $('statusMsg');
  msg.textContent = '';
  try {
    const res = await fetch('/fixture_log', {headers: headers()});
    if (res.status === 401) {
      $('keyRow').classList.add('show');
      msg.textContent = 'KEY REQUIRED';
      msg.className = 'msg err';
      $('summary').textContent = 'Unlock with your bridge key to view the fixture log.';
      renderRows([]);
      return;
    }
    $('keyRow').classList.remove('show');
    const d = await res.json();
    const records = d.records || [];
    renderRows(records);
    $('summary').textContent = records.length
      ? records.length + ' measurement' + (records.length === 1 ? '' : 's') + ' from the console'
      : 'Waiting for the first calibration upload from the console';
    $('updated').textContent = d.updated_at ? 'UPDATED ' + d.updated_at.replace('T', ' ').replace('Z', ' UTC') : 'NOT YET SYNCED';
    $('countFoot').textContent = records.length + ' ENTRIES';
  } catch (e) {
    msg.textContent = 'CANNOT REACH BRIDGE';
    msg.className = 'msg err';
    renderRows([]);
  }
}

refresh();
setInterval(refresh, 5000);
</script>
</body>
</html>
"""


@app.get("/fixtures", response_class=HTMLResponse)
async def fixtures_page():
    """Browser page listing all fixture measurements synced from the console."""
    return _FIXTURES_HTML


@app.get("/fixture_log", dependencies=_auth)
async def get_fixture_log():
    """Return the fixture measurement log synced from the GrandMA3 plugin."""
    return _fixture_log_payload()


@app.post("/fixture_log", dependencies=_auth)
async def post_fixture_log(request: Request):
    """
    Replace the bridge's fixture log with the console's fixture_log.json.
    Called automatically by the SekonicCalibrator plugin after each save.
    """
    try:
        body = await request.json()
    except Exception:
        raise HTTPException(status_code=400, detail={"error": "invalid_json"})

    raw_records = body
    if isinstance(body, dict):
        raw_records = body.get("records", [])

    if not isinstance(raw_records, list):
        raise HTTPException(
            status_code=422,
            detail={"error": "invalid_payload",
                    "hint": "body must be a JSON array or {\"records\": [...]}"},
        )

    records = [_normalize_fixture_record(item, i) for i, item in enumerate(raw_records)]
    _save_fixture_log(records)
    log.info("Fixture log synced: %d record(s)", len(records))
    payload = _fixture_log_payload()
    payload["ok"] = True
    return payload



@app.get("/discover", dependencies=_auth)
async def discover():
    """
    Scan USB bus for a Sekonic meter.
    Saves VID/PID to device_config.json and returns found device info.
    """
    if _use_mock_global:
        return {
            "configured":   True,
            "manufacturer": "Sekonic",
            "product":      "C-7000 (mock)",
            "vendor_id":    "0x0000",
            "product_id":   "0x0000",
            "devices":      [],
        }

    try:
        import usb.core
        import usb.util
    except ImportError:
        raise HTTPException(
            status_code=500,
            detail={"error": "pyusb_not_installed",
                    "hint": "Run: pip install pyusb"}
        )

    loop = asyncio.get_event_loop()

    def _scan():
        found = []
        sekonic_device = None
        for dev in usb.core.find(find_all=True):
            try:
                mfr  = usb.util.get_string(dev, dev.iManufacturer) if dev.iManufacturer else ""
                prod = usb.util.get_string(dev, dev.iProduct)      if dev.iProduct      else ""
            except Exception:
                mfr, prod = "", ""
            entry = {
                "vendor_id":    f"0x{dev.idVendor:04x}",
                "product_id":   f"0x{dev.idProduct:04x}",
                "manufacturer": mfr,
                "product":      prod,
            }
            found.append(entry)
            if "sekonic" in (mfr + prod).lower():
                sekonic_device = entry
        return found, sekonic_device

    devices, sekonic = await loop.run_in_executor(None, _scan)

    if not sekonic:
        return JSONResponse(
            status_code=404,
            content={"configured": False, "devices": devices,
                     "error": "no_sekonic_found"}
        )

    # Persist discovered VID/PID
    cfg = _load_device_config()
    cfg.update({
        "vendor_id":    int(sekonic["vendor_id"], 16),
        "product_id":   int(sekonic["product_id"], 16),
        "manufacturer": sekonic["manufacturer"],
        "product":      sekonic["product"],
        "configured":   True,
    })
    # C-7000 (VID 0x0A41): full protocol is confirmed from skreader; no manual
    # capture or trigger-discovery steps needed.
    if int(sekonic["vendor_id"], 16) == 0x0A41:
        cfg["protocol_captured"]  = True
        cfg["trigger_discovered"] = True
    _save_device_config(cfg)
    log.info("Discovered Sekonic: %s %s VID=%s PID=%s",
             sekonic["manufacturer"], sekonic["product"],
             sekonic["vendor_id"], sekonic["product_id"])

    return {
        "configured":   True,
        "manufacturer": sekonic["manufacturer"],
        "product":      sekonic["product"],
        "vendor_id":    sekonic["vendor_id"],
        "product_id":   sekonic["product_id"],
        "devices":      devices,
    }


# Candidate struct formats to try when auto-parsing a captured HID report.
# Each is (format_string, field_order) where field_order maps struct fields
# to measurement names. We try each in order and accept the first that
# produces plausible Sekonic values.
_PARSE_CANDIDATES = [
    # Format: CCT uint16 LE, Duv×10000 int16 LE, CRI uint8, R9 uint8, TLCI uint8
    ("<HhBBB", ["cct", "duv_raw", "cri", "r9", "tlci"]),
    # Format: CCT uint16 BE, Duv×10000 int16 BE, CRI uint8, R9 uint8, TLCI uint8
    (">HhBBB", ["cct", "duv_raw", "cri", "r9", "tlci"]),
    # Format: CCT uint16 LE, Duv×10000 int16 LE, CRI uint8, R9 uint8 (no TLCI)
    ("<HhBB",  ["cct", "duv_raw", "cri", "r9"]),
]


def _try_parse(data: bytes) -> dict | None:
    """Attempt to parse raw HID data using candidate struct layouts."""
    for offset in range(min(4, len(data))):
        for fmt, fields in _PARSE_CANDIDATES:
            size = struct.calcsize(fmt)
            if offset + size > len(data):
                continue
            try:
                values = struct.unpack_from(fmt, data, offset)
                result = dict(zip(fields, values))
                cct = result.get("cct", 0)
                duv = result.get("duv_raw", 0) / 10000.0
                cri = result.get("cri", 0)
                r9  = result.get("r9",  0)
                # Sanity check: plausible Sekonic values
                if not (1667 <= cct <= 25000):
                    continue
                if not (-0.05 <= duv <= 0.05):
                    continue
                if not (0 <= cri <= 100 and 0 <= r9 <= 100):
                    continue
                parsed = {"cct": int(cct), "duv": round(duv, 4),
                          "cri": int(cri), "r9": int(r9)}
                if "tlci" in result:
                    tlci = result["tlci"]
                    if 0 <= tlci <= 100:
                        parsed["tlci"] = int(tlci)
                parsed["_offset"] = offset
                parsed["_fmt"]    = fmt
                return parsed
            except Exception:
                continue
    return None


@app.post("/capture", dependencies=_auth)
async def capture():
    """
    Verify the meter connection by taking a test measurement.

    For the Sekonic C-7000 (VID 0x0A41): uses the fully-documented protocol
    (RT1 → RM0 → ST poll → NR) — no button press required.

    For other/unknown meters: falls back to passively listening for one bulk
    IN packet, triggered by the user pressing the physical MEASURE button.
    Times out after 30 seconds.

    Saves protocol_captured=true to device_config.json on success.
    """
    if _use_mock_global:
        from meter_mock import MockMeter
        mock = MockMeter()
        mock.connect()
        data = mock.measure()
        mock.disconnect()
        cfg = _load_device_config()
        cfg.update({"protocol_captured": True, "trigger_discovered": True})
        _save_device_config(cfg)
        return {
            "success":           True,
            "protocol_captured": True,
            "cct":  data["cct"],
            "duv":  data["duv"],
            "cri":  data["cri"],
            "r9":   data["r9"],
            "tlci": data.get("tlci"),
        }

    cfg = _load_device_config()
    vendor_id  = cfg.get("vendor_id")
    product_id = cfg.get("product_id")

    if not vendor_id or not product_id:
        raise HTTPException(
            status_code=409,
            detail={"error": "device_not_discovered",
                    "hint": "Call GET /discover first to find the VID/PID"}
        )

    loop = asyncio.get_event_loop()

    # ── C-7000 fast path: protocol fully known, trigger directly ──────────────
    if vendor_id == 0x0A41:
        # Reuse the already-connected global `_meter` instead of constructing a
        # second C7000Bulk() and calling connect() on it: libusb only allows
        # one claim on INTERFACE at a time, so a second connect() while the
        # startup connection is still holding it fails with a misleading
        # "USBError: [Errno 13] Access denied (insufficient permissions)" —
        # not an actual OS permissions problem. Mirrors how /measure does it.
        if _meter is None or not _meter.is_connected():
            raise HTTPException(
                status_code=503,
                detail={"error": "device_not_found",
                        "hint": "Check that the C-7000 is plugged into the Pi"}
            )

        async with _measurement_lock:
            try:
                data = await loop.run_in_executor(None, _meter.measure)
            except Exception as exc:
                log.error("Capture (C-7000 fast path) failed: %s", exc)
                data = None

        if data is None:
            raise HTTPException(
                status_code=503,
                detail={"error": "device_not_found",
                        "hint": "Check that the C-7000 is plugged into the Pi"}
            )
        cfg.update({"protocol_captured": True})
        _save_device_config(cfg)
        log.info("Capture (C-7000 fast path): CCT=%dK CRI=%d R9=%d",
                 data["cct"], data["cri"], data["r9"])
        return JSONResponse(content={"success": True, "protocol_captured": True, **data})

    # ── Fallback: passive bulk listen for unknown meters ─────────────────────
    try:
        import usb.core
        import usb.util
    except ImportError:
        raise HTTPException(
            status_code=500,
            detail={"error": "pyusb_not_installed", "hint": "pip install pyusb"}
        )

    def _listen():
        dev = usb.core.find(idVendor=vendor_id, idProduct=product_id)
        if dev is None:
            return None, "device_not_found"
        try:
            if dev.is_kernel_driver_active(0):
                dev.detach_kernel_driver(0)
            dev.set_configuration()
        except Exception as exc:
            return None, str(exc)

        # Find the first bulk or interrupt IN endpoint
        cfg_obj = dev.get_active_configuration()
        ep_in = None
        for intf in cfg_obj:
            for ep in intf:
                import usb.util as _u
                if _u.endpoint_direction(ep.bEndpointAddress) == _u.ENDPOINT_IN:
                    ep_in = ep
                    break
            if ep_in:
                break

        if ep_in is None:
            return None, "no_in_endpoint"

        log.info("Capture (fallback): listening on %s for up to 30 s…", ep_in)
        deadline = time.time() + 30
        while time.time() < deadline:
            try:
                data = dev.read(ep_in.bEndpointAddress, ep_in.wMaxPacketSize,
                                timeout=1000)
                return bytes(data), None
            except usb.core.USBTimeoutError:
                continue
            except Exception as exc:
                return None, str(exc)
        return None, "capture_timeout"

    raw, err = await loop.run_in_executor(None, _listen)
    if raw is None:
        raise HTTPException(
            status_code=504 if err == "capture_timeout" else 500,
            detail={"success": False, "error": err}
        )

    raw_hex = raw.hex()
    parsed  = _try_parse(raw)
    cfg.update({
        "response_sample_hex": raw_hex,
        "response_length":     len(raw),
        "protocol_captured":   parsed is not None,
    })
    if parsed:
        cfg["parse_fmt"]    = parsed.get("_fmt", "")
        cfg["parse_offset"] = parsed.get("_offset", 0)
    _save_device_config(cfg)

    result = {"success": True, "raw_hex": raw_hex,
               "protocol_captured": parsed is not None}
    if parsed:
        result.update({k: v for k, v in parsed.items() if not k.startswith("_")})
    log.info("Capture (fallback): %d bytes, parsed=%s", len(raw), parsed is not None)
    return JSONResponse(content=result)


@app.post("/learn_trigger", dependencies=_auth)
async def learn_trigger():
    """
    Discover the USB HID trigger command for the C-7000 without Wireshark.

    Iterates through candidate byte sequences, sends each to the meter's OUT
    endpoint, and checks whether the meter responds with valid measurement data.
    The first candidate that elicits a plausible response is saved to
    device_config.json as trigger_cmd_hex and trigger_discovered=true.

    Returns immediately if the trigger is already known.
    Times out after ~2 minutes (covers all candidates with 4-second probes).
    """
    if _use_mock_global:
        cfg = _load_device_config()
        cfg.update({"trigger_cmd_hex": "01", "trigger_discovered": True})
        _save_device_config(cfg)
        return {"success": True, "already_known": False,
                "trigger_cmd_hex": "01", "attempts": 1}

    cfg = _load_device_config()
    if cfg.get("trigger_discovered"):
        return {"success": True, "already_known": True,
                "trigger_cmd_hex": cfg.get("trigger_cmd_hex", "bulk")}

    # C-7000 bulk fast-path: skreader protocol needs no HID trigger probe grid.
    if cfg.get("vendor_id") == 0x0A41 and cfg.get("protocol_captured"):
        cfg.update({"trigger_cmd_hex": "bulk", "trigger_discovered": True})
        _save_device_config(cfg)
        log.info("learn_trigger (C-7000 bulk fast-path): trigger_discovered=true")
        return {
            "success": True,
            "already_known": False,
            "trigger_cmd_hex": "bulk",
            "attempts": 0,
        }

    if not cfg.get("vendor_id") or not cfg.get("product_id"):
        raise HTTPException(
            status_code=409,
            detail={"error": "device_not_discovered",
                    "hint": "Call GET /discover first to find the VID/PID"}
        )
    if not cfg.get("protocol_captured"):
        raise HTTPException(
            status_code=409,
            detail={"error": "protocol_not_captured",
                    "hint": "Call POST /capture first to capture the response format"}
        )

    candidates = _build_trigger_candidates()
    loop = asyncio.get_event_loop()

    async with _measurement_lock:
        for idx, cmd_bytes in enumerate(candidates):
            # Reuse the already-connected global `_meter` — see /capture above
            # for why constructing a second C7000Bulk() and connect()-ing it
            # fails with a misleading libusb "Access denied" error.
            def _probe(cmd=cmd_bytes):
                if _meter is None or not _meter.is_connected():
                    return None
                try:
                    return _meter.probe_trigger(cmd, timeout_ms=4000)
                except Exception:
                    return None

            result = await loop.run_in_executor(None, _probe)
            if result is not None:
                hex_str = cmd_bytes.hex()
                cfg.update({"trigger_cmd_hex": hex_str, "trigger_discovered": True})
                _save_device_config(cfg)
                log.info("Remote trigger discovered: 0x%s (attempt %d)", hex_str, idx + 1)
                return {"success": True, "trigger_cmd_hex": hex_str,
                        "attempts": idx + 1}

    log.warning("learn_trigger: no candidate succeeded after %d attempts", len(candidates))
    return JSONResponse(
        status_code=404,
        content={
            "success": False,
            "error":   "trigger_not_found",
            "message": "No candidate triggered a valid measurement. "
                       "Physical button press is still required. "
                       "See README for Wireshark capture fallback.",
        }
    )


@app.post("/plant_correction", dependencies=_auth)
async def plant_correction(request: Request):
    """
    Mock-mode only: tell the reactive plant model what xy the console applied.
    Ignored when not running with --mock (returns ok/ignored).
    """
    if not _use_mock_global:
        return {"ok": True, "ignored": True, "reason": "not_mock_mode"}

    try:
        body = await request.json()
    except Exception:
        raise HTTPException(
            status_code=422,
            detail={"error": "invalid_json", "hint": "Send JSON with target_x and target_y"},
        )

    target_x = body.get("target_x")
    target_y = body.get("target_y")
    if target_x is None or target_y is None:
        raise HTTPException(
            status_code=422,
            detail={"error": "missing_fields",
                    "hint": "target_x and target_y are required"},
        )

    from meter_mock import mock_plant

    gain = body.get("gain")
    mock_plant.apply_command(float(target_x), float(target_y),
                             float(gain) if gain is not None else None)
    return {"ok": True, "active": True, "gain": mock_plant.gain}


@app.post("/measure", dependencies=_auth)
async def measure():
    """
    Trigger a measurement on the connected C-7000.
    Blocks until the meter responds (up to 30 seconds).
    Returns CCT, Duv, CRI, R9, and TLCI as JSON.
    """
    global _last_error

    if _meter is None or not _meter.is_connected():
        raise HTTPException(
            status_code=503,
            detail={"error": "meter_not_connected",
                    "hint": "Check that the C-7000 is plugged in and the bridge restarted"}
        )

    # Prevent two simultaneous measurements (e.g. operator double-clicks)
    if _measurement_lock.locked():
        raise HTTPException(
            status_code=409,
            detail={"error": "measurement_in_progress",
                    "hint": "A measurement is already running – please wait"}
        )

    async with _measurement_lock:
        log.info("Triggering measurement…")
        try:
            loop = asyncio.get_event_loop()
            data = await asyncio.wait_for(
                loop.run_in_executor(None, _meter.measure),
                timeout=35.0,
            )
            _last_error = None
            log.info(
                "Measurement: CCT=%dK  Duv=%+.4f  CRI=%d  R9=%d  TLCI=%s",
                data["cct"], data["duv"], data["cri"], data["r9"],
                data.get("tlci", "n/a"),
            )
            data["timestamp"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
            return JSONResponse(content=data)

        except TimeoutError:
            _last_error = "measurement_timeout"
            log.error("Measurement timed out after 35 s")
            raise HTTPException(
                status_code=504,
                detail={"error": "measurement_timeout",
                        "hint": "The meter did not respond – check USB connection"}
            )
        except ValueError as exc:
            # Raised by C7000Bulk._parse() when the response contains
            # out-of-range sentinel values -- almost always means the
            # sensor was covered or aimed away from any light source.
            _last_error = str(exc)
            log.error("Invalid measurement: %s", exc)
            raise HTTPException(
                status_code=422,
                detail={"error": "invalid_measurement",
                        "hint": "Check that the meter's sensor is uncovered "
                                "and pointed at the fixture, then try again."}
            )
        except Exception as exc:
            _last_error = str(exc)
            log.error("Measurement error: %s", exc)
            raise HTTPException(
                status_code=500,
                detail={"error": "measurement_error", "detail": str(exc)}
            )


# ── entry point ───────────────────────────────────────────────────────────────

def main():
    global _use_mock_global

    parser = argparse.ArgumentParser(description="Sekonic C-7000 Bridge Server")
    parser.add_argument("--host",  default="0.0.0.0",  help="Bind host (default: 0.0.0.0)")
    parser.add_argument("--port",  default=8765, type=int, help="Port (default: 8765)")
    parser.add_argument("--mock",  action="store_true",   help="Use mock meter (no hardware)")
    args = parser.parse_args()

    _use_mock_global = args.mock

    log.info("=" * 60)
    log.info("Sekonic C-7000 Bridge Server v1.0.0")
    log.info("Binding on %s:%d", args.host, args.port)
    log.info("Mode: %s", "MOCK" if args.mock else "REAL HARDWARE")
    log.info("=" * 60)

    uvicorn.run(
        app,
        host=args.host,
        port=args.port,
        log_level="warning",  # uvicorn access log is noisy; use our own logger
    )


if __name__ == "__main__":
    main()
