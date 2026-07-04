"""
Mock Sekonic C-7000 meter for development and testing.

Two modes:
  1. Fixed progression (legacy) — when no plant correction commands received.
  2. Reactive plant model — when POST /plant_correction updates commanded xy;
     each measurement moves the simulated fixture output by `gain` toward the
     commanded point (same model as tests/gen_mock_sequences.lua).
"""

from __future__ import annotations

import random
import time
from typing import Optional


# ── Fixed progression (fallback when plant is inactive) ─────────────────────

_CCT_STEPS = [4100, 4920, 5480, 5590, 5605]
_DUV_STEPS = [0.0085, 0.0042, 0.0015, 0.0003, 0.0001]
_CRI_STEPS = [72, 81, 88, 92, 94]
_R9_STEPS = [42, 58, 72, 83, 85]
_TLCI_STEPS = [68, 77, 86, 90, 92]


def _xy_to_uv(x: float, y: float) -> tuple[float, float]:
    denom = -2 * x + 12 * y + 3
    if denom == 0:
        return 0.0, 0.0
    return 4 * x / denom, 9 * y / denom


def _uv_to_xy(up: float, vp: float) -> tuple[float, float]:
    denom = 6 * up - 16 * vp + 12
    if denom == 0:
        return 0.0, 0.0
    return 9 * up / denom, 4 * vp / denom


def _xy_to_cct_duv(x: float, y: float) -> tuple[int, float]:
    """McCamy + simplified Duv (host-test model, matches gen_mock_sequences.lua)."""
    n = (x - 0.3320) / (0.1858 - y)
    cct = 437 * n ** 3 + 3601 * n ** 2 + 6861 * n + 5517
    up, vp = _xy_to_uv(x, y)
    lx = (-3.0258469e9 / 5600 ** 3) + (2.1070379e6 / 5600 ** 2) + (0.2226347e3 / 5600) + 0.240390
    ly = (3.0817580 * lx ** 3) + (-5.87338670 * lx ** 2) + (3.75112997 * lx) + (-0.37001483)
    lup, lvp = _xy_to_uv(lx, ly)
    duv = (vp - lvp) / 1.5
    return int(round(max(1667, min(25000, cct)))), round(max(-0.05, min(0.05, duv)), 4)


class MockPlant:
    """Reactive fixture plant for closed-loop mock E2E testing."""

    DEFAULT_GAIN = 0.35

    def __init__(self) -> None:
        self.reset()

    def reset(self) -> None:
        self.measured_x, self.measured_y = 0.3930, 0.3800
        self.commanded_x: Optional[float] = None
        self.commanded_y: Optional[float] = None
        self.prev_commanded_x: Optional[float] = None
        self.prev_commanded_y: Optional[float] = None
        self.gain = self.DEFAULT_GAIN
        self.active = False
        self._quality_step = 0

    def apply_command(
        self,
        target_x: float,
        target_y: float,
        gain: Optional[float] = None,
    ) -> None:
        if gain is not None:
            self.gain = float(gain)
        self.prev_commanded_x = self.commanded_x if self.commanded_x is not None else self.measured_x
        self.prev_commanded_y = self.commanded_y if self.commanded_y is not None else self.measured_y
        self.commanded_x = float(target_x)
        self.commanded_y = float(target_y)
        self.active = True

    def _advance_plant(self) -> None:
        assert self.commanded_x is not None and self.commanded_y is not None
        req_up, req_vp = _xy_to_uv(self.commanded_x, self.commanded_y)
        prev_x = self.prev_commanded_x if self.prev_commanded_x is not None else self.measured_x
        prev_y = self.prev_commanded_y if self.prev_commanded_y is not None else self.measured_y
        prev_up, prev_vp = _xy_to_uv(prev_x, prev_y)
        delta_up = req_up - prev_up
        delta_vp = req_vp - prev_vp
        meas_up, meas_vp = _xy_to_uv(self.measured_x, self.measured_y)
        meas_up += self.gain * delta_up
        meas_vp += self.gain * delta_vp
        self.measured_x, self.measured_y = _uv_to_xy(meas_up, meas_vp)
        self._quality_step = min(self._quality_step + 1, len(_CCT_STEPS) - 1)

    def read(self) -> dict:
        if self.commanded_x is not None:
            self._advance_plant()
        cct, duv = _xy_to_cct_duv(self.measured_x, self.measured_y)
        idx = min(self._quality_step, len(_CRI_STEPS) - 1)
        cri = _CRI_STEPS[idx] + random.randint(-2, 2)
        r9 = _R9_STEPS[idx] + random.randint(-4, 4)
        tlci = _TLCI_STEPS[idx] + random.randint(-3, 3)
        return {
            "cct": max(1667, min(25000, cct)),
            "duv": round(max(-0.05, min(0.05, duv)), 4),
            "cri": max(0, min(100, cri)),
            "r9": max(0, min(100, r9)),
            "tlci": max(0, min(100, tlci)),
        }


# Shared plant state for mock server mode (updated via POST /plant_correction).
mock_plant = MockPlant()


class MockMeter:
    """Simulates a connected C-7000 (fixed progression or reactive plant)."""

    def __init__(self, plant: Optional[MockPlant] = None):
        self._connected = False
        self._call_count = 0
        self._plant = plant

    def connect(self) -> bool:
        time.sleep(0.1)
        self._connected = True
        return True

    def is_connected(self) -> bool:
        return self._connected

    def disconnect(self):
        self._connected = False

    def measure(self) -> dict:
        if not self._connected:
            raise RuntimeError("meter_not_connected")

        time.sleep(1.5)
        self._call_count += 1

        if self._plant and self._plant.active:
            return self._plant.read()

        idx = min(self._call_count - 1, len(_CCT_STEPS) - 1)
        cct = _CCT_STEPS[idx] + random.randint(-25, 25)
        duv = round(_DUV_STEPS[idx] + random.uniform(-0.0006, 0.0006), 4)
        cri = _CRI_STEPS[idx] + random.randint(-2, 2)
        r9 = _R9_STEPS[idx] + random.randint(-4, 4)
        tlci = _TLCI_STEPS[idx] + random.randint(-3, 3)

        return {
            "cct": max(1667, min(25000, cct)),
            "duv": round(max(-0.05, min(0.05, duv)), 4),
            "cri": max(0, min(100, cri)),
            "r9": max(0, min(100, r9)),
            "tlci": max(0, min(100, tlci)),
        }
