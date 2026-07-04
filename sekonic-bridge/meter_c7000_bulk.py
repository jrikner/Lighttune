"""
Sekonic C-7000 USB bulk interface.

Protocol confirmed from https://github.com/kinglevel/skreader (MIT licence),
based on the official Sekonic C# SDK. No Wireshark capture required.

Command sequence:
  b"RT1"  → 2-byte ACK + main response  — enable remote mode (once per
                                           session, in connect() — see below)
  b"RM0"  → 2-byte ACK + main response  — trigger measurement
  b"ST"   → 2-byte ACK + 5-byte status  — poll every 50 ms until idle
  b"NR"   → 2-byte ACK + 2380 B         — retrieve result
  b"RT0"  → 2-byte ACK + main response  — disable remote mode (once per
                                           session, in disconnect())

Every command gets TWO replies from the device, not one: first the 2-byte
ACK, then a second "main response" packet with the command's actual data
(confirmed from skreader's Device.execCommand in device.go — this applies
uniformly to every command, including the ones whose main response isn't
otherwise used, like RT1/RM0/RT0). Reading only the first reply leaves the
second one queued device-side; the next command's ACK-read then picks up
that stale leftover packet instead of its own ACK.

RT1/RT0 are sent once per session (connect()/disconnect()), not once per
measurement: the "remote on" status bit stays set device-side for the
whole session regardless (see _poll_ready's bit-mask comment below), so
toggling it off and back on around every single measure() call only added
two extra command round trips with no protocol benefit. Each measure()
call now issues just RM0 → poll(ST) → NR.

Supported meters: C-700, C-800, C-7000 (VID 0x0A41, all share PID 0x7003
for this generation; verify with GET /discover if yours differs).
"""

import json
import logging
import struct
import time
from pathlib import Path

import usb.core
import usb.util

log = logging.getLogger("sekonic-bridge.c7000")


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
READ_BUF_SIZE   = 512                   # Safe upper bound for a single bulk
                                         # IN packet on this device — big
                                         # enough to avoid LIBUSB_ERROR_OVERFLOW
                                         # on short logical replies (ACK/ST),
                                         # small enough to stay well under
                                         # RESPONSE_SIZE for the real payload.
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


class C7000Bulk:
    """USB bulk driver for the Sekonic C-7000 (and compatible C-700/C-800)."""

    def __init__(self):
        self._dev = None
        self._remote_enabled = False

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
        self._remote_enabled = False

        # Enable remote mode once per session instead of once per
        # measurement. RT1's "remote on" flag stays set device-side for the
        # whole session (this is exactly what _poll_ready's bit-mask fix
        # above had to account for), so there is no protocol reason to
        # toggle it off (RT0) and back on (RT1) around every single
        # measurement -- doing so just pays a write+ACK+response round trip
        # twice per measurement for no effect. Best-effort here: if it
        # fails (e.g. device still settling right after being claimed),
        # measure() retries it lazily before the first trigger.
        try:
            self._send_cmd(b"RT1")
            self._remote_enabled = True
        except Exception:
            log.warning("connect: RT1 (enable remote mode) failed; will retry on first measure()")
        return True

    def is_connected(self) -> bool:
        return self._dev is not None

    def disconnect(self):
        if self._dev is not None:
            if self._remote_enabled:
                try:
                    self._send_cmd(b"RT0")  # disable remote mode (best-effort)
                except Exception:
                    pass
            try:
                usb.util.release_interface(self._dev, INTERFACE)
                usb.util.dispose_resources(self._dev)
            except Exception:
                pass
            self._dev = None
            self._remote_enabled = False

    # ── Protocol helpers ──────────────────────────────────────────────────────

    def _exec(self, cmd: bytes, resp_size: int = READ_BUF_SIZE) -> bytes:
        """
        Send cmd and read its TWO replies: a 2-byte ACK, then a second
        "main response" packet holding the command's actual data, and
        return that second packet.

        This mirrors skreader's Device.execCommand (device.go), which
        performs this same two-read sequence for every command — not just
        NR. The original port of this driver only read once per command
        (treating that single read as the ACK), which left each command's
        main-response packet sitting unread in the endpoint; the next
        command's ACK-read would then consume that leftover packet instead
        of its own ACK. That surfaced as "Expected ACK 0x0630, got ..."
        with data that looked like a mangled echo of the previous command —
        because it was: the previous command's own unread main response.

        Bulk endpoints deliver whole packets, so both reads use a buffer
        sized to the caller's expectation (resp_size) rather than the exact
        logical size — requesting fewer bytes than the device's packet
        raises LIBUSB_ERROR_OVERFLOW ("[Errno 84] Overflow") instead of
        truncating.
        """
        self._dev.write(ENDPOINT_OUT, cmd, timeout=2000)
        ack = bytes(self._dev.read(ENDPOINT_IN, READ_BUF_SIZE, timeout=2000))
        if ack[:len(ACK)] != ACK:
            raise RuntimeError(f"{cmd!r}: expected ACK {ACK.hex()}, got {ack.hex()!r}")
        return bytes(self._dev.read(ENDPOINT_IN, resp_size, timeout=5000))

    def _send_cmd(self, cmd: bytes) -> None:
        """Write cmd, verify the ACK, and discard its main response."""
        self._exec(cmd)

    def _poll_ready(self) -> None:
        """
        Poll ST every 50 ms until the device reports idle.

        ST main-response format (5 bytes total):
          b"ST" prefix (2 bytes) + st1 + st2 + key

        Bit layout confirmed from skreader's Device.State() (device.go) —
        NOT the mask this method originally used (st2 & 0x0F / st1 & 0x0E),
        which was an unverified guess and turned out to be wrong in a way
        that only shows up against real hardware:

          st1 & 0x10 (bit 4)  hardware error
          st1 & 0x01 (bit 0)  busy (st2's low nibble then says which kind:
                              initializing / dark-cal / flash-standby / measuring)
          st1 & 0x08 (bit 3)  idle, but "out of measurement range" (still
                              counts as ready — skreader's WaitReady accepts
                              both SkDeviceStatusIdle and SkDeviceStatusIdleOutMeas)
          st1 & 0x02 (bit 1)  remote mode is ON — NOT a busy flag

        Real hardware trace that exposed the bug: after RT1 (enable remote
        mode), every single ST poll returned st1=0x42 forever, and the
        meter never appeared to finish "measuring". 0x42 = 0b0100_0010:
        bit 1 (remote-on) is set, bit 0 (busy) is NOT. The device was idle
        and ready from the very first poll — but the old mask treated bits
        1-3 as "busy", so the permanently-set remote-on bit made every poll
        look busy forever, regardless of the actual measurement state.
        """
        deadline = time.time() + MEASURE_TIMEOUT
        while time.time() < deadline:
            try:
                resp = self._exec(b"ST")
                if len(resp) >= 5 and resp[:2] == b"ST":
                    st1 = resp[2]
                    if st1 & 0x10:
                        raise RuntimeError(f"C-7000 reports a hardware error (st1=0x{st1:02x})")
                    if not (st1 & 0x01):
                        return  # idle, or idle-out-of-measurement-range
            except usb.core.USBTimeoutError:
                pass
            time.sleep(POLL_INTERVAL_S)
        raise TimeoutError("Meter did not complete measurement within timeout")

    def _get_result(self) -> bytes:
        """Send NR and return its 2380-byte main-response payload."""
        return self._exec(b"NR", resp_size=RESPONSE_SIZE)

    # ── Public API ────────────────────────────────────────────────────────────

    def _drain(self) -> None:
        """
        Discard any stale bytes left in the IN endpoint from a prior
        transaction that sent a command but never read its reply (e.g. a
        request that raised before reaching the read, or a previous crashed
        process) — the C-7000 queues replies device-side, so they are still
        sitting there waiting to be read on the next connection. Reading
        them here (instead of failing on this or the next _send_cmd) keeps
        the command sequence self-healing without requiring a physical
        unplug/replug every time something goes wrong mid-sequence.
        """
        drained = 0
        try:
            while True:
                leftover = self._dev.read(ENDPOINT_IN, READ_BUF_SIZE, timeout=50)
                drained += 1
                log.debug("drain: discarded %d stale bytes: %s",
                          len(leftover), bytes(leftover).hex())
        except usb.core.USBTimeoutError:
            pass
        except Exception as exc:
            log.debug("drain: stopped early: %s", exc)
        if drained:
            log.info("drain: discarded %d stale packet(s) before starting command sequence", drained)

    def measure(self) -> dict:
        """
        Trigger a remote measurement and return parsed values.

        Remote mode (RT1) is enabled once per session by connect(), not on
        every call here -- see the comment in connect(). This lazily
        retries RT1 only if it never successfully landed (e.g. connect()'s
        best-effort attempt failed), so a single flaky enable doesn't
        permanently block measurements.
        """
        if self._dev is None:
            raise RuntimeError("meter_not_connected")
        self._drain()
        if not self._remote_enabled:
            self._send_cmd(b"RT1")      # enable remote mode (lazy fallback)
            self._remote_enabled = True
        self._send_cmd(b"RM0")      # trigger measurement
        self._poll_ready()           # wait for completion
        data = self._get_result()    # retrieve 2380-byte result
        return self._parse(data)

    def _parse(self, data: bytes) -> dict:
        """
        Parse the 2380-byte NR response.

        All field offsets and byte order confirmed from skreader measurement.go.
        CCT range: 1563–100000 K; Duv range: −0.1 to +0.1.

        When the sensor is covered or aimed away from any light source, the
        C-7000 fills this response with out-of-range sentinel values (seen
        live: cct=0, duv=-2.0000, cri=-200, r9=-200) instead of raising a
        device-side error -- so an all-sentinel payload parses "successfully"
        into physically meaningless numbers unless we bounds-check it here.
        """
        if len(data) < RESPONSE_SIZE:
            raise ValueError(
                f"Response too short: {len(data)} bytes (expected {RESPONSE_SIZE})"
            )
        cct = round(struct.unpack_from(">f", data, _OFF_CCT)[0])
        duv = round(struct.unpack_from(">f", data, _OFF_DUV)[0], 4)
        cri = round(struct.unpack_from(">f", data, _OFF_CRI)[0])
        r9  = round(struct.unpack_from(">f", data, _OFF_R9)[0])

        if not (1000 <= cct <= 100000) or not (-0.5 <= duv <= 0.5) \
           or not (0 <= cri <= 100) or not (-100 <= r9 <= 100):
            raise ValueError(
                "invalid_measurement: sensor may be covered or aimed away "
                f"from a light source (got cct={cct} duv={duv} cri={cri} r9={r9})"
            )
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
