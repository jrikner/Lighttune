"""
Mock Sekonic C-7000 meter for development and testing.
Returns realistic but hardcoded measurement values so the bridge
can be fully tested without physical hardware.
"""

import time
import random


class MockMeter:
    """Simulates a connected C-7000 returning plausible values."""

    def __init__(self):
        self._connected = False

    def connect(self) -> bool:
        time.sleep(0.1)  # simulate USB enumeration
        self._connected = True
        return True

    def is_connected(self) -> bool:
        return self._connected

    def disconnect(self):
        self._connected = False

    def measure(self) -> dict:
        """Simulate a 1-second measurement cycle with slight random variation."""
        if not self._connected:
            raise RuntimeError("meter_not_connected")
        time.sleep(1.0)  # simulate measurement time
        # Realistic values for a 5600K daylight source with slight green push
        cct  = 5580 + random.randint(-40, 40)
        duv  = round(0.0018 + random.uniform(-0.0010, 0.0010), 4)
        cri  = 94  + random.randint(-2, 2)
        r9   = 85  + random.randint(-5, 5)
        tlci = 91  + random.randint(-3, 3)
        # Clamp to valid ranges
        cct  = max(1667, min(25000, cct))
        duv  = round(max(-0.02, min(0.02, duv)), 4)
        cri  = max(0,   min(100, cri))
        r9   = max(0,   min(100, r9))
        tlci = max(0,   min(100, tlci))
        return {"cct": cct, "duv": duv, "cri": cri, "r9": r9, "tlci": tlci}
