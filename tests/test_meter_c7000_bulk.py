"""
Unit tests for sekonic-bridge/meter_c7000_bulk.py against a fake USB device
-- no real Sekonic hardware required.

Covers:
  * the two-read-per-command protocol (ACK, then main response)
  * RT1/RT0 remote-mode session-scoping (once per connect/disconnect, not
    once per measure())
  * the ST poll bit-mask fix (bit 1 = remote-on, NOT busy; bit 0 = busy)
  * covered-sensor / out-of-range sentinel rejection in _parse()
  * connect()/disconnect() error paths
"""

from __future__ import annotations

import struct
import sys
from pathlib import Path

import pytest
import usb.core
import usb.util

REPO_ROOT = Path(__file__).resolve().parent.parent
BRIDGE_DIR = REPO_ROOT / "sekonic-bridge"
sys.path.insert(0, str(BRIDGE_DIR))

import meter_c7000_bulk as m  # noqa: E402


ACK = m.ACK  # bytes([0x06, 0x30])


def make_measure_payload(cct=3200.0, duv=0.0012, cri=92.0, r9=55.0) -> bytes:
    data = bytearray(m.RESPONSE_SIZE)
    struct.pack_into(">f", data, m._OFF_CCT, cct)
    struct.pack_into(">f", data, m._OFF_DUV, duv)
    struct.pack_into(">f", data, m._OFF_CRI, cri)
    struct.pack_into(">f", data, m._OFF_R9, r9)
    return bytes(data)


def make_st_payload(st1: int, st2: int = 0x00, key: int = 0x00) -> bytes:
    return b"ST" + bytes([st1, st2, key])


class FakeUSBDevice:
    """
    Minimal stand-in for a pyusb Device: records every write() and serves
    read() from a pre-loaded queue of response packets, one packet per
    call -- mirroring how the real C-7000 gives a separate bulk IN packet
    for the ACK and for the main response to every command.
    """

    def __init__(self):
        self.writes: list[bytes] = []
        self._queue: list[bytes] = []
        self.stale_queue: list[bytes] = []  # consumed only by _drain()'s short-timeout reads
        self.idVendor = m.VENDOR_ID
        self.idProduct = m.PRODUCT_ID
        # Real pyusb Device objects expose these; connect() calls them.
        self.is_kernel_driver_active = lambda iface: False
        self.set_configuration = lambda: None

    def queue(self, *packets: bytes) -> "FakeUSBDevice":
        self._queue.extend(packets)
        return self

    def queue_command_ok(self, main_response: bytes) -> "FakeUSBDevice":
        """Queue a standard ACK + main-response pair for one command."""
        self._queue.append(ACK)
        self._queue.append(main_response)
        return self

    def write(self, endpoint, data, timeout=None):
        self.writes.append(bytes(data))
        return len(data)

    def read(self, endpoint, size, timeout=None):
        # _drain() always calls read(..., timeout=50); every other protocol
        # read uses a much longer timeout (2000/5000 ms). Routing short-
        # timeout reads to a separate stale_queue keeps drain()'s "mop up
        # leftover bytes" behaviour from silently eating the packets a test
        # queued for the actual command/response sequence that follows.
        if timeout is not None and timeout <= 50:
            if not self.stale_queue:
                raise usb.core.USBTimeoutError("no stale packets", None, None)
            return self.stale_queue.pop(0)
        if not self._queue:
            raise usb.core.USBTimeoutError("no more queued packets", None, None)
        return self._queue.pop(0)


@pytest.fixture
def fake_dev(monkeypatch):
    dev = FakeUSBDevice()
    monkeypatch.setattr(usb.core, "find", lambda **kwargs: dev)
    monkeypatch.setattr(usb.util, "claim_interface", lambda *a, **k: None)
    monkeypatch.setattr(usb.util, "release_interface", lambda *a, **k: None)
    monkeypatch.setattr(usb.util, "dispose_resources", lambda *a, **k: None)
    return dev


def _connected_meter(fake_dev) -> m.C7000Bulk:
    """A C7000Bulk connected against fake_dev, with connect()'s RT1 consumed."""
    fake_dev.queue_command_ok(b"\x00" * 8)  # RT1 main response (contents unused)
    meter = m.C7000Bulk()
    assert meter.connect() is True
    return meter


# ── connect() / RT1 session-scoping ────────────────────────────────────────


def test_connect_enables_remote_mode_once(fake_dev):
    meter = _connected_meter(fake_dev)
    assert meter._remote_enabled is True
    assert fake_dev.writes == [b"RT1"]


def test_connect_returns_false_when_device_not_found(monkeypatch):
    monkeypatch.setattr(usb.core, "find", lambda **kwargs: None)
    meter = m.C7000Bulk()
    assert meter.connect() is False
    assert meter.is_connected() is False


def test_connect_survives_rt1_failure_and_retries_lazily(fake_dev):
    # No packets queued at all -> RT1 write during connect() raises
    # USBTimeoutError on the ACK read; connect() should still succeed
    # (best-effort), leaving _remote_enabled False for measure() to retry.
    meter = m.C7000Bulk()
    assert meter.connect() is True
    assert meter._remote_enabled is False


# ── measure() RT1 laziness ──────────────────────────────────────────────────


def test_measure_skips_rt1_when_remote_already_enabled(fake_dev):
    meter = _connected_meter(fake_dev)
    fake_dev.writes.clear()

    fake_dev.queue_command_ok(make_st_payload(st1=0x00))          # ST: idle
    fake_dev.queue_command_ok(make_measure_payload())             # NR
    # RM0's own ACK+response:
    fake_dev.queue_command_ok(b"\x00" * 4)
    # Re-order queue: RM0 must be sent (and consumed) before ST poll.
    fake_dev._queue = []
    fake_dev.queue_command_ok(b"\x00" * 4)                        # RM0
    fake_dev.queue_command_ok(make_st_payload(st1=0x00))          # ST idle
    fake_dev.queue_command_ok(make_measure_payload(cct=3210))     # NR

    result = meter.measure()
    assert result["cct"] == 3210
    assert fake_dev.writes == [b"RM0", b"ST", b"NR"]  # no RT1 -- already enabled


def test_measure_lazily_enables_remote_mode_when_not_yet_enabled(fake_dev):
    meter = m.C7000Bulk()
    # connect() with no queued packets -> RT1 fails silently, not enabled.
    assert meter.connect() is True
    assert meter._remote_enabled is False
    fake_dev.writes.clear()

    fake_dev.queue_command_ok(b"\x00" * 4)                    # RT1 (lazy, in measure())
    fake_dev.queue_command_ok(b"\x00" * 4)                    # RM0
    fake_dev.queue_command_ok(make_st_payload(st1=0x00))      # ST idle
    fake_dev.queue_command_ok(make_measure_payload(cct=3300))  # NR

    result = meter.measure()
    assert result["cct"] == 3300
    assert meter._remote_enabled is True
    assert fake_dev.writes == [b"RT1", b"RM0", b"ST", b"NR"]


# ── disconnect() RT0 session-scoping ────────────────────────────────────────


def test_disconnect_sends_rt0_only_if_remote_was_enabled(fake_dev):
    meter = _connected_meter(fake_dev)
    assert meter._remote_enabled is True
    fake_dev.writes.clear()

    fake_dev.queue_command_ok(b"\x00" * 4)  # RT0 main response
    meter.disconnect()
    assert fake_dev.writes == [b"RT0"]
    assert meter.is_connected() is False


def test_disconnect_skips_rt0_if_remote_was_never_enabled(fake_dev):
    meter = m.C7000Bulk()
    assert meter.connect() is True   # no packets queued -> RT1 fails, not enabled
    assert meter._remote_enabled is False
    fake_dev.writes.clear()

    meter.disconnect()
    assert fake_dev.writes == []   # no RT0 sent -- remote was never on
    assert meter.is_connected() is False


def test_disconnect_is_a_noop_when_never_connected():
    meter = m.C7000Bulk()
    meter.disconnect()  # must not raise
    assert meter.is_connected() is False


# ── two-read protocol (ACK, then main response) ─────────────────────────────


def test_exec_reads_ack_then_main_response(fake_dev):
    meter = _connected_meter(fake_dev)
    fake_dev.queue_command_ok(b"hello-main-response")
    result = meter._exec(b"XX", resp_size=len(b"hello-main-response"))
    assert result == b"hello-main-response"


def test_exec_raises_on_bad_ack(fake_dev):
    meter = _connected_meter(fake_dev)
    fake_dev.queue(b"\xff\xff")  # not a valid ACK
    with pytest.raises(RuntimeError, match="expected ACK"):
        meter._exec(b"XX")


def test_drain_discards_stale_packets(fake_dev):
    meter = _connected_meter(fake_dev)
    fake_dev.stale_queue.extend([b"stale-1", b"stale-2", b"stale-3"])
    meter._drain()  # must not raise
    assert fake_dev.stale_queue == []


# ── _poll_ready bit-mask (regression test for the st1=0x42 bug) ────────────


def test_poll_ready_remote_on_bit_is_not_busy(fake_dev):
    """
    Regression test: st1=0x42 means bit1 (remote-on) set, bit0 (busy) clear
    -- device is idle. The original (wrong) mask treated bits 1-3 as busy,
    which made every poll look busy forever once remote mode was enabled.
    """
    meter = _connected_meter(fake_dev)
    fake_dev.queue_command_ok(make_st_payload(st1=0x42))
    meter._poll_ready()  # must return immediately, not time out


def test_poll_ready_busy_then_idle(fake_dev):
    meter = _connected_meter(fake_dev)
    fake_dev.queue_command_ok(make_st_payload(st1=0x01))  # busy
    fake_dev.queue_command_ok(make_st_payload(st1=0x00))  # idle
    meter._poll_ready()  # must return after the second poll


def test_poll_ready_hardware_error_raises(fake_dev):
    meter = _connected_meter(fake_dev)
    fake_dev.queue_command_ok(make_st_payload(st1=0x10))  # hardware error bit
    with pytest.raises(RuntimeError, match="hardware error"):
        meter._poll_ready()


# ── _parse() bounds checking (covered-sensor sentinel rejection) ───────────


def test_parse_valid_measurement(fake_dev):
    meter = _connected_meter(fake_dev)
    result = meter._parse(make_measure_payload(cct=5600, duv=-0.0021, cri=95, r9=80))
    assert result == {"cct": 5600, "duv": -0.0021, "cri": 95, "r9": 80}


def test_parse_covered_sensor_sentinel_raises_value_error(fake_dev):
    meter = _connected_meter(fake_dev)
    # Live-observed sentinel values when the sensor is covered/aimed away.
    payload = make_measure_payload(cct=0, duv=-2.0, cri=-200, r9=-200)
    with pytest.raises(ValueError, match="invalid_measurement"):
        meter._parse(payload)


def test_parse_short_response_raises_value_error(fake_dev):
    meter = _connected_meter(fake_dev)
    with pytest.raises(ValueError, match="too short"):
        meter._parse(b"\x00" * 10)


def test_measure_raises_when_not_connected():
    meter = m.C7000Bulk()
    with pytest.raises(RuntimeError, match="meter_not_connected"):
        meter.measure()
