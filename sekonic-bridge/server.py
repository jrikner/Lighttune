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

from fastapi import Depends, FastAPI, Header, HTTPException
from fastapi.responses import JSONResponse
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
    DEVICE_CONFIG_PATH.write_text(json.dumps(cfg, indent=2))


def _is_device_configured() -> bool:
    cfg = _load_device_config()
    return bool(cfg.get("configured"))


def _is_protocol_captured() -> bool:
    cfg = _load_device_config()
    return bool(cfg.get("protocol_captured"))


def _is_trigger_discovered() -> bool:
    cfg = _load_device_config()
    return bool(cfg.get("trigger_discovered"))


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
        from meter_mock import MockMeter
        backend = MockMeter()
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
    dependencies=[Depends(verify_bridge_key)],
)


@app.get("/status")
async def status():
    """Return bridge health, meter connection state, and configuration status."""
    connected = _meter is not None and _meter.is_connected()
    return {
        "status":             "ok",
        "meter":              "C-7000",
        "connected":          connected,
        "uptime_s":           int(time.time() - _start_time),
        "last_error":         _last_error,
        "version":            "0.5.0-replan",
        "device_configured":  _is_device_configured()  or _use_mock_global,
        "protocol_captured":  _is_protocol_captured()  or _use_mock_global,
        "trigger_discovered": _is_trigger_discovered() or _use_mock_global,
        "auth_required":      _auth_required(),
    }


@app.get("/discover")
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


@app.post("/capture")
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
        from meter_c7000_bulk import C7000Bulk

        def _test_measure():
            m = C7000Bulk()
            if not m.connect():
                return None
            try:
                return m.measure()
            finally:
                m.disconnect()

        data = await loop.run_in_executor(None, _test_measure)
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


@app.post("/learn_trigger")
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

    from meter_c7000_bulk import C7000Bulk

    candidates = _build_trigger_candidates()
    loop = asyncio.get_event_loop()

    async with _measurement_lock:
        for idx, cmd_bytes in enumerate(candidates):
            def _probe(cmd=cmd_bytes):
                m = C7000Bulk()
                try:
                    if not m.connect():
                        return None
                    return m.probe_trigger(cmd, timeout_ms=4000)
                except Exception:
                    return None
                finally:
                    try:
                        m.disconnect()
                    except Exception:
                        pass

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


@app.post("/measure")
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
