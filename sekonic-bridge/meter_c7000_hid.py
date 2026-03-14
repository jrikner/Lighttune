"""
Sekonic C-7000 USB HID interface using pyusb.

This module communicates with the C-7000 directly over USB without
requiring the official Windows-only SDK. It uses the raw USB HID protocol
which works on Raspberry Pi (Linux), macOS, and Windows.

SETUP — use the built-in wizard (no Wireshark required):
  1. GET  /discover       – finds VID/PID automatically, saves device_config.json
  2. POST /capture        – user presses MEASURE once; bridge captures the response format
  3. POST /learn_trigger  – bridge probes candidate HID commands to find the remote trigger

After step 3 succeeds, POST /measure triggers measurements with no physical button press.
All discovered values are persisted in device_config.json; restarting the server reloads them.

FALLBACK (advanced) — if /learn_trigger fails:
  Use Wireshark + USBPcap on Windows to capture the trigger command manually:
  1. Install Wireshark + USBPcap (https://desowin.org/usbpcap/)
  2. Connect C-7000, run the Sekonic Utility Software, capture the USBPcap interface
  3. Filter: usb.transfer_type == 0x03 (interrupt transfers = HID data)
  4. Identify the OUT packet that triggers a measurement; copy the bytes
  5. Set TRIGGER_CMD below to those bytes and restart the server
"""

import json
import struct
import time
from pathlib import Path

import usb.core
import usb.util


# ── Device configuration (overridden by device_config.json if present) ────────
#
# device_config.json is written by GET /discover and POST /capture on the server.
# If it exists, its values take priority over the TODO constants below.

_DEVICE_CONFIG_PATH = Path(__file__).parent / "device_config.json"


def _load_cfg() -> dict:
    if _DEVICE_CONFIG_PATH.exists():
        try:
            return json.loads(_DEVICE_CONFIG_PATH.read_text())
        except Exception:
            pass
    return {}


_cfg = _load_cfg()

VENDOR_ID  = _cfg.get("vendor_id",  0x0000)   # TODO: set after running /discover
PRODUCT_ID = _cfg.get("product_id", 0x0000)   # TODO: set after running /discover

INTERFACE    = 0
ENDPOINT_OUT = 0x01   # TODO: verify from Wireshark capture
ENDPOINT_IN  = 0x81   # TODO: verify from Wireshark capture

# Trigger command — loaded from device_config.json if POST /learn_trigger succeeded,
# otherwise defaults to the single-byte placeholder (physical button press required).
_trigger_hex = _cfg.get("trigger_cmd_hex", "")
TRIGGER_CMD     = bytes.fromhex(_trigger_hex) if _trigger_hex else bytes([0x00])
RESPONSE_LENGTH = _cfg.get("response_length", 64)

MEASUREMENT_TIMEOUT_MS = 30_000

# Parse parameters discovered during POST /capture (empty = use _parse() defaults)
_PARSE_FMT    = _cfg.get("parse_fmt",    "<HhBBB")
_PARSE_OFFSET = _cfg.get("parse_offset", 0)

# ─────────────────────────────────────────────────────────────────────────────


class C7000HID:
    """USB HID driver for the Sekonic C-7000 Spectromaster."""

    def __init__(self):
        self._dev = None
        self._trigger_cmd = TRIGGER_CMD

    def connect(self) -> bool:
        """Find and open the C-7000 USB device. Returns True on success."""
        # Reload config on each connect attempt so changes written by /discover,
        # /capture, or /learn_trigger take effect without restarting the server.
        cfg = _load_cfg()
        vid = cfg.get("vendor_id", VENDOR_ID)
        pid = cfg.get("product_id", PRODUCT_ID)
        # Update the effective trigger command from config if available
        trigger_hex = cfg.get("trigger_cmd_hex", "")
        self._trigger_cmd = bytes.fromhex(trigger_hex) if trigger_hex else TRIGGER_CMD
        if vid == 0 or pid == 0:
            raise RuntimeError(
                "VID/PID not configured. Run GET /discover to auto-detect, "
                "or set VENDOR_ID/PRODUCT_ID in meter_c7000_hid.py."
            )
        dev = usb.core.find(idVendor=vid, idProduct=pid)
        if dev is None:
            return False
        # Detach kernel HID driver on Linux so we can claim the interface
        if dev.is_kernel_driver_active(INTERFACE):
            dev.detach_kernel_driver(INTERFACE)
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

    def measure(self) -> dict:
        """
        Trigger a measurement and return parsed values.
        Blocks until the meter responds or timeout elapses.
        """
        if self._dev is None:
            raise RuntimeError("meter_not_connected")

        # Send trigger command (loaded from device_config.json if /learn_trigger succeeded)
        self._dev.write(ENDPOINT_OUT, self._trigger_cmd)

        # Wait for response
        start = time.time()
        while True:
            try:
                data = self._dev.read(ENDPOINT_IN, RESPONSE_LENGTH,
                                      timeout=MEASUREMENT_TIMEOUT_MS)
                return self._parse(bytes(data))
            except usb.core.USBTimeoutError:
                if time.time() - start > MEASUREMENT_TIMEOUT_MS / 1000:
                    raise TimeoutError("No response from C-7000 within timeout")
                continue

    def _parse(self, data: bytes) -> dict:
        """
        Parse the raw HID response packet into measurement values.

        TODO: Update this method once you have captured real packets.
        The offsets and formats below are placeholders — replace them
        with the actual byte positions from your Wireshark capture.

        Typical C-7000 data layout (hypothetical example):
          bytes 0-1:  CCT in Kelvin (uint16, little-endian)
          bytes 2-3:  Duv × 10000 as signed int16 (e.g. 28 = 0.0028)
          bytes 4:    CRI Ra (uint8)
          bytes 5:    R9 (uint8)
          bytes 6:    TLCI (uint8)
        """
        # Use format/offset from device_config.json if protocol was captured.
        # Falls back to the placeholder layout when no capture data is available.
        cfg = _load_cfg()
        fmt    = cfg.get("parse_fmt",    _PARSE_FMT)
        offset = cfg.get("parse_offset", _PARSE_OFFSET)

        size = struct.calcsize(fmt)
        if len(data) < offset + size:
            raise ValueError(
                f"Response packet too short: {len(data)} bytes "
                f"(need {offset + size} for fmt={fmt!r} at offset={offset})"
            )

        values = struct.unpack_from(fmt, data, offset=offset)
        # Expected field order: cct, duv_raw, cri, r9[, tlci]
        if len(values) < 4:
            raise ValueError(f"Unexpected struct field count: {len(values)}")
        cct_raw, duv_raw, cri, r9 = values[:4]
        tlci = values[4] if len(values) > 4 else None

        cct = int(cct_raw)
        duv = round(duv_raw / 10000.0, 4)

        result = {
            "cct":  cct,
            "duv":  duv,
            "cri":  int(cri),
            "r9":   int(r9),
        }
        if tlci is not None:
            result["tlci"] = int(tlci)
        return result

    def probe_trigger(self, cmd: bytes, timeout_ms: int = 4000) -> dict | None:
        """
        Send `cmd` to the OUT endpoint and listen for a measurement response.

        Used by POST /learn_trigger to auto-discover the remote trigger command.
        Returns a parsed measurement dict if the response looks valid, else None.
        Never raises — all exceptions are swallowed so the caller can iterate.
        """
        if self._dev is None:
            return None
        try:
            self._dev.write(ENDPOINT_OUT, cmd, timeout=2000)
            raw = bytes(self._dev.read(ENDPOINT_IN, RESPONSE_LENGTH,
                                       timeout=timeout_ms))
            parsed = self._parse(raw)
            # Sanity-check: must be a plausible light-meter measurement
            if 1667 <= parsed["cct"] <= 25000 and -0.05 <= parsed["duv"] <= 0.05:
                return parsed
        except Exception:
            pass
        return None
