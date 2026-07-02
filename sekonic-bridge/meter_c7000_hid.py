"""
Sekonic C-7000 USB bulk interface.

Protocol confirmed from https://github.com/kinglevel/skreader (MIT licence),
based on the official Sekonic C# SDK. No Wireshark capture required.

Command sequence for a remote measurement:
  b"RT1"  → 2-byte ACK           — enable remote mode
  b"RM0"  → 2-byte ACK           — trigger measurement
  b"ST"   → 5-byte status reply  — poll every 50 ms until idle
  b"NR"   → 2-byte ACK + 2380 B  — retrieve result
  b"RT0"  → 2-byte ACK           — disable remote mode

Supported meters: C-700, C-800, C-7000 (VID 0x0A41, all share PID 0x7003
for this generation; verify with GET /discover if yours differs).
"""

import json
import struct
import time
from pathlib import Path

import usb.core
import usb.util


# ── Device configuration ──────────────────────────────────────────────────────

_DEVICE_CONFIG_PATH = Path(__file__).parent / "device_config.json"


def _load_cfg() -> dict:
    if _DEVICE_CONFIG_PATH.exists():
        try:
            return json.loads(_DEVICE_CONFIG_PATH.read_text())
        except Exception:
            pass
    return {}


_cfg = _load_cfg()

# VID/PID confirmed from skreader; override via device_config.json if needed.
VENDOR_ID   = _cfg.get("vendor_id",  0x0A41)
PRODUCT_ID  = _cfg.get("product_id", 0x7003)

INTERFACE    = 0
ENDPOINT_OUT = 0x02   # bulk OUT — confirmed from skreader
ENDPOINT_IN  = 0x81   # bulk IN  — confirmed from skreader

# Protocol constants confirmed from skreader const.go / device.go
RESPONSE_SIZE   = 2380                  # MeasurementDataValidSize
ACK             = bytes([0x06, 0x30])   # SkResponseOK
POLL_INTERVAL_S = 0.05                  # WaitPollFreqDefault (50 ms)
MEASURE_TIMEOUT = 20.0                  # WaitMeasTimeoutDefault (20 s)

# ── Response byte offsets (confirmed from skreader measurement.go) ─────────────
# All values are big-endian float32.
# Each field entry is 5 bytes: 4-byte float32 + 1-byte range indicator (Ok/Under/Over).
_OFF_CCT = 50    # Correlated Colour Temperature (K)
_OFF_DUV = 55    # Delta uv
_OFF_CRI = 348   # CRI Ra
_OFF_R9  = 393   # R9 = R1-array[8], offset = 353 + 8 × 5
# TLCI is not present in the standard NR response; requires FW>25 extended mode.

# ─────────────────────────────────────────────────────────────────────────────


class C7000HID:
    """USB bulk driver for the Sekonic C-7000 (and compatible C-700/C-800)."""

    def __init__(self):
        self._dev = None

    def connect(self) -> bool:
        """Find and open the C-7000 USB device. Returns True on success."""
        cfg = _load_cfg()
        vid = cfg.get("vendor_id", VENDOR_ID)
        pid = cfg.get("product_id", PRODUCT_ID)

        dev = usb.core.find(idVendor=vid, idProduct=pid)
        if dev is None:
            return False

        # Detach kernel driver on Linux so we can claim the interface.
        try:
            if dev.is_kernel_driver_active(INTERFACE):
                dev.detach_kernel_driver(INTERFACE)
        except Exception:
            pass  # not applicable on Windows/macOS

        dev.set_configuration()
        usb.util.claim_interface(dev, INTERFACE)
        self._dev = dev
        return True

    def is_connected(self) -> bool:
        return self._dev is not None

    def disconnect(self):
        if self._dev is not None:
            try:
                usb.util.release_interface(self._dev, INTERFACE)
                usb.util.dispose_resources(self._dev)
            except Exception:
                pass
            self._dev = None

    # ── Protocol helpers ──────────────────────────────────────────────────────

    def _send_cmd(self, cmd: bytes) -> None:
        """Write cmd and verify the 2-byte ACK response."""
        self._dev.write(ENDPOINT_OUT, cmd, timeout=2000)
        ack = bytes(self._dev.read(ENDPOINT_IN, 2, timeout=2000))
        if ack != ACK:
            raise RuntimeError(f"Expected ACK {ACK.hex()}, got {ack.hex()!r}")

    def _poll_ready(self) -> None:
        """
        Poll ST every 50 ms until the device reports idle.

        ST response format (5 bytes total):
          b"ST" prefix (2 bytes) + st1 + st2 + key
        The device is busy while st2 & 0x0F (measuring / init / dark-cal /
        flash-standby bits) or st1 & 0x0E (additional busy flags) are set.
        Bit masks verified from skreader device.go.
        """
        deadline = time.time() + MEASURE_TIMEOUT
        while time.time() < deadline:
            try:
                self._dev.write(ENDPOINT_OUT, b"ST", timeout=2000)
                resp = bytes(self._dev.read(ENDPOINT_IN, 5, timeout=2000))
                if len(resp) >= 5 and resp[:2] == b"ST":
                    st1, st2 = resp[2], resp[3]
                    if not (st2 & 0x0F) and not (st1 & 0x0E):
                        return  # idle
            except usb.core.USBTimeoutError:
                pass
            time.sleep(POLL_INTERVAL_S)
        raise TimeoutError("Meter did not complete measurement within timeout")

    def _get_result(self) -> bytes:
        """Send NR, read the ACK, then read the 2380-byte measurement payload."""
        self._dev.write(ENDPOINT_OUT, b"NR", timeout=2000)
        ack = bytes(self._dev.read(ENDPOINT_IN, 2, timeout=2000))
        if ack != ACK:
            raise RuntimeError(f"NR: expected ACK {ACK.hex()}, got {ack.hex()!r}")
        return bytes(self._dev.read(ENDPOINT_IN, RESPONSE_SIZE, timeout=5000))

    # ── Public API ────────────────────────────────────────────────────────────

    def measure(self) -> dict:
        """Trigger a remote measurement and return parsed values."""
        if self._dev is None:
            raise RuntimeError("meter_not_connected")
        self._send_cmd(b"RT1")      # enable remote mode
        self._send_cmd(b"RM0")      # trigger measurement
        self._poll_ready()           # wait for completion
        data = self._get_result()    # retrieve 2380-byte result
        try:
            self._send_cmd(b"RT0")  # disable remote mode (best-effort)
        except Exception:
            pass
        return self._parse(data)

    def _parse(self, data: bytes) -> dict:
        """
        Parse the 2380-byte NR response.

        All field offsets and byte order confirmed from skreader measurement.go.
        CCT range: 1563–100000 K; Duv range: −0.1 to +0.1.
        """
        if len(data) < RESPONSE_SIZE:
            raise ValueError(
                f"Response too short: {len(data)} bytes (expected {RESPONSE_SIZE})"
            )
        cct = round(struct.unpack_from(">f", data, _OFF_CCT)[0])
        duv = round(struct.unpack_from(">f", data, _OFF_DUV)[0], 4)
        cri = round(struct.unpack_from(">f", data, _OFF_CRI)[0])
        r9  = round(struct.unpack_from(">f", data, _OFF_R9)[0])
        return {"cct": cct, "duv": duv, "cri": cri, "r9": r9}
        # TLCI is not in the standard NR response (requires FW>25 extended mode).

    def probe_trigger(self, cmd: bytes, timeout_ms: int = 4000) -> dict | None:
        """
        Legacy probe for unknown meters: send cmd and check for a valid response.
        Not used for the C-7000 (protocol is fully known); kept for future meters.
        """
        if self._dev is None:
            return None
        try:
            self._dev.write(ENDPOINT_OUT, cmd, timeout=2000)
            raw = bytes(self._dev.read(ENDPOINT_IN, RESPONSE_SIZE, timeout=timeout_ms))
            if len(raw) < RESPONSE_SIZE:
                return None
            parsed = self._parse(raw)
            if 1667 <= parsed["cct"] <= 25000 and -0.05 <= parsed["duv"] <= 0.05:
                return parsed
        except Exception:
            pass
        return None
