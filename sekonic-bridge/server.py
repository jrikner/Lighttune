"""
Sekonic C-7000 Bridge Server
Lighttune – Remote Measurement Bridge

Exposes a simple REST API over the show network so the GrandMA3 Lua plugin
can trigger measurements on the Sekonic C-7000 and read values remotely.

Endpoints:
  GET  /status   — health check, meter connection state
  POST /measure  — trigger a measurement, blocks until complete (up to 30s)

Usage:
  python3 server.py [--host 0.0.0.0] [--port 8765] [--mock]

  --mock    Use the mock meter (no hardware needed, for testing)
"""

import argparse
import asyncio
import logging
import sys
import time
from contextlib import asynccontextmanager
from datetime import datetime, timezone

from fastapi import FastAPI, HTTPException
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
        from meter_c7000_hid import C7000HID
        backend = C7000HID()
        log.info("Using C-7000 USB HID backend")

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
    version="1.0.0",
    lifespan=lifespan,
)


@app.get("/status")
async def status():
    """Return bridge health and meter connection state."""
    connected = _meter is not None and _meter.is_connected()
    return {
        "status":     "ok",
        "meter":      "C-7000",
        "connected":  connected,
        "uptime_s":   int(time.time() - _start_time),
        "last_error": _last_error,
        "version":    "1.0.0",
    }


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
