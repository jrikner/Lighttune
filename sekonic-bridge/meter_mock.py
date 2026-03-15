"""
Mock Sekonic C-7000 meter for development and testing.

Simulates a fixture that starts with poor colour quality — as typical for an
uncalibrated LED PAR with a skewed spectrum — and improves toward target values
across successive measurements, demonstrating the plugin's correction loop.

Measurement progression (simulates ~4 calibration attempts to reach goals):

  Attempt 1 (start): 4100 K / +0.0085 Duv / CRI 72 / R9 42 / TLCI 68
    → Badly off: too warm, greenish push, poor colour rendering
  Attempt 2:         4920 K / +0.0042 Duv / CRI 81 / R9 58 / TLCI 77
    → Improving after first correction
  Attempt 3:         5480 K / +0.0015 Duv / CRI 88 / R9 72 / TLCI 86
    → Close, second correction applied
  Attempt 4:         5590 K / +0.0003 Duv / CRI 92 / R9 83 / TLCI 90
    → Near goal
  Attempt 5+:        5605 K / +0.0001 Duv / CRI 94 / R9 85 / TLCI 92
    → At goal

Values are physically correlated: CCT, Duv, CRI, R9, and TLCI all move
together as a real fixture would respond to colour-matrix corrections.
A warm fixture being pushed toward daylight gains both CCT and CRI
simultaneously; Duv pulls back toward the Planckian locus as the spectrum
balances out.

Each call adds small random jitter so readings feel like a real instrument
rather than a lookup table. _call_count resets when a new MockMeter() is
instantiated (which is how --mock mode works in server.py).
"""

import random
import time

# ── Progression tables ────────────────────────────────────────────────────────
# Index 0 = first measurement (worst), index 4 = at goal (capped there).
# All values are target centres; jitter is added per call.

_CCT_STEPS  = [4100, 4920, 5480, 5590, 5605]           # Kelvin
_DUV_STEPS  = [0.0085, 0.0042, 0.0015, 0.0003, 0.0001] # delta-uv
_CRI_STEPS  = [72,   81,   88,   92,   94]              # CRI Ra
_R9_STEPS   = [42,   58,   72,   83,   85]              # R9
_TLCI_STEPS = [68,   77,   86,   90,   92]              # TLCI


class MockMeter:
    """Simulates a connected C-7000 with a degraded-to-converging response."""

    def __init__(self):
        self._connected  = False
        self._call_count = 0

    def connect(self) -> bool:
        time.sleep(0.1)   # simulate USB enumeration delay
        self._connected = True
        return True

    def is_connected(self) -> bool:
        return self._connected

    def disconnect(self):
        self._connected = False

    def measure(self) -> dict:
        """
        Return one measurement reading, advancing through the progression table.

        Jitter per call:
          CCT  ± 25 K      — instrument repeatability
          Duv  ± 0.0006    — sub-0.001 repeatability
          CRI  ± 2         — ±2 Ra typical for spectroradiometers
          R9   ± 4         — R9 is noisier than Ra
          TLCI ± 3
        """
        if not self._connected:
            raise RuntimeError("meter_not_connected")

        time.sleep(1.5)   # simulate ~1.5 s ambient measurement cycle

        self._call_count += 1
        idx = min(self._call_count - 1, len(_CCT_STEPS) - 1)

        cct  = _CCT_STEPS[idx]  + random.randint(-25, 25)
        duv  = round(_DUV_STEPS[idx]  + random.uniform(-0.0006, 0.0006), 4)
        cri  = _CRI_STEPS[idx]  + random.randint(-2,   2)
        r9   = _R9_STEPS[idx]   + random.randint(-4,   4)
        tlci = _TLCI_STEPS[idx] + random.randint(-3,   3)

        # Clamp to instrument valid ranges
        cct  = max(1667,  min(25000, cct))
        duv  = round(max(-0.05, min(0.05, duv)), 4)
        cri  = max(0,     min(100, cri))
        r9   = max(0,     min(100, r9))
        tlci = max(0,     min(100, tlci))

        return {"cct": cct, "duv": duv, "cri": cri, "r9": r9, "tlci": tlci}
