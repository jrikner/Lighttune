"""
Sekonic C-7000 USB HID interface using pyusb.

This module communicates with the C-7000 directly over USB without
requiring the official Windows-only SDK. It uses the raw USB HID protocol
which works on Raspberry Pi (Linux), macOS, and Windows.

IMPORTANT — USB PROTOCOL CAPTURE REQUIRED:
The C-7000's USB HID command protocol is not publicly documented.
Before this module can work you must capture the USB traffic once:

  1. On a Windows PC, install Wireshark + USBPcap (https://desowin.org/usbpcap/)
  2. Connect your C-7000 via USB and run the Sekonic C-700/7000 Utility Software
  3. In Wireshark, start a capture on the USBPcap interface that shows the C-7000
  4. In the Utility Software, press "Measure" and watch the packets in Wireshark
  5. Filter: usb.transfer_type == 0x03 (interrupt transfers = HID data)
  6. Identify the OUT packet sent to trigger a measurement
  7. Identify the IN packets returned with measurement data
  8. Fill in the constants below

Alternatively on macOS:
  brew install wireshark
  sudo tcpdump -i usbmon0 -w capture.pcap   (or use the system Bluetooth/USB logger)

Once you have the protocol, set:
  TRIGGER_CMD     — bytes sent to trigger a measurement
  RESPONSE_LENGTH — expected response packet length
  And update _parse() to extract the values from the response bytes.
"""

import usb.core
import usb.util
import struct
import time


# ── TODO: fill in after USB protocol capture ─────────────────────────────────

# USB vendor/product IDs for the Sekonic C-7000.
# Find these with: lsusb (Linux) or Device Manager (Windows) after connecting meter.
VENDOR_ID  = 0x0000   # TODO: replace with actual vendor ID
PRODUCT_ID = 0x0000   # TODO: replace with actual product ID

# HID interface number (usually 0)
INTERFACE = 0

# HID endpoint addresses (find via: usb.core.find(...).configurations()[0])
# Typical: 0x01 = OUT (host→device), 0x81 = IN (device→host)
ENDPOINT_OUT = 0x01   # TODO: verify
ENDPOINT_IN  = 0x81   # TODO: verify

# Command bytes that trigger a single measurement (replace with captured bytes)
TRIGGER_CMD = bytes([0x00])   # TODO: replace with actual trigger command

# Expected length of the response packet from the meter
RESPONSE_LENGTH = 64           # TODO: adjust to actual packet size

# Timeout waiting for measurement response (milliseconds)
MEASUREMENT_TIMEOUT_MS = 30_000

# ─────────────────────────────────────────────────────────────────────────────


class C7000HID:
    """USB HID driver for the Sekonic C-7000 Spectromaster."""

    def __init__(self):
        self._dev = None

    def connect(self) -> bool:
        """Find and open the C-7000 USB device. Returns True on success."""
        if VENDOR_ID == 0 or PRODUCT_ID == 0:
            raise RuntimeError(
                "VENDOR_ID and PRODUCT_ID not set in meter_c7000_hid.py. "
                "See the USB protocol capture instructions at the top of the file."
            )
        dev = usb.core.find(idVendor=VENDOR_ID, idProduct=PRODUCT_ID)
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

        # Send trigger command
        self._dev.write(ENDPOINT_OUT, TRIGGER_CMD)

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
        # TODO: replace struct format and offsets with real values from capture
        if len(data) < 7:
            raise ValueError(f"Response packet too short: {len(data)} bytes")

        cct_raw, duv_raw, cri, r9, tlci = struct.unpack_from("<HhBBB", data, offset=0)

        cct = int(cct_raw)
        duv = round(duv_raw / 10000.0, 4)

        return {
            "cct":  cct,
            "duv":  duv,
            "cri":  int(cri),
            "r9":   int(r9),
            "tlci": int(tlci),
        }
