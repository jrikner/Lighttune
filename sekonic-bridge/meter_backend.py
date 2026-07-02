"""
Meter backend protocol for the Sekonic bridge.

Defines the contract that hardware drivers (C7000Bulk) and MockMeter must satisfy.
"""

from typing import Protocol, runtime_checkable


@runtime_checkable
class MeterBackend(Protocol):
    """USB or mock meter driver used by server.py for /measure and setup routes."""

    def connect(self) -> bool:
        """Open the device connection. Returns True on success."""
        ...

    def is_connected(self) -> bool:
        """Return whether the meter is currently connected."""
        ...

    def disconnect(self) -> None:
        """Release the device connection."""
        ...

    def measure(self) -> dict:
        """
        Trigger a measurement and return parsed values.

        Expected keys: cct (int), duv (float), cri (int), r9 (int).
        Optional: tlci (int) when the meter supports it.
        """
        ...
