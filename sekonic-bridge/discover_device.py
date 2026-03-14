"""
Sekonic C-7000 USB Device Discovery
Lighttune – Sekonic Bridge

Run this on the Raspberry Pi with the C-7000 connected via USB:
    python3 discover_device.py

Scans all USB devices and prints VID/PID for each. Highlights any Sekonic
device found and shows the exact values to copy into meter_c7000_hid.py.

If the VID/PID are found, this script also writes device_config.json so
the bridge server self-configures without manual file editing.

Requirements: pyusb  (pip install pyusb)
"""

import json
import sys
from pathlib import Path

try:
    import usb.core
    import usb.util
except ImportError:
    print("Error: pyusb is not installed. Run: pip install pyusb")
    sys.exit(1)


def main() -> None:
    print("Scanning USB devices...\n")
    print(f"  {'VID':8}  {'PID':8}  {'Manufacturer':20}  Product")
    print("  " + "-" * 70)

    found_sekonic = []

    for dev in usb.core.find(find_all=True):
        try:
            mfr  = usb.util.get_string(dev, dev.iManufacturer) if dev.iManufacturer else ""
            prod = usb.util.get_string(dev, dev.iProduct)      if dev.iProduct      else ""
        except Exception:
            mfr, prod = "", ""

        vid = f"0x{dev.idVendor:04x}"
        pid = f"0x{dev.idProduct:04x}"
        is_sekonic = "sekonic" in (mfr + prod).lower()

        line = f"  {vid:8}  {pid:8}  {mfr:20}  {prod}"
        if is_sekonic:
            print(f"*** {line}  ← SEKONIC")
            found_sekonic.append({
                "vendor_id":    dev.idVendor,
                "product_id":   dev.idProduct,
                "manufacturer": mfr,
                "product":      prod,
            })
        else:
            print(line)

    print()

    if not found_sekonic:
        print("No Sekonic device found.\n")
        print("Check:")
        print("  • C-7000 is connected to this machine via USB")
        print("  • USB cable is working (try a different cable or port)")
        print("  • Meter is powered on")
        sys.exit(1)

    for dev_info in found_sekonic:
        vid = dev_info["vendor_id"]
        pid = dev_info["product_id"]
        print(f"Sekonic found: {dev_info['manufacturer']} {dev_info['product']}")
        print(f"  VID = 0x{vid:04x}  ({vid})")
        print(f"  PID = 0x{pid:04x}  ({pid})")
        print()
        print("Update meter_c7000_hid.py:")
        print(f"  VENDOR_ID  = 0x{vid:04x}")
        print(f"  PRODUCT_ID = 0x{pid:04x}")
        print()

    # Write device_config.json so the bridge server self-configures
    config_path = Path(__file__).parent / "device_config.json"
    existing: dict = {}
    if config_path.exists():
        try:
            existing = json.loads(config_path.read_text())
        except Exception:
            pass

    # Use the first Sekonic found (there should only ever be one)
    device = found_sekonic[0]
    existing.update({
        "vendor_id":    device["vendor_id"],
        "product_id":   device["product_id"],
        "manufacturer": device["manufacturer"],
        "product":      device["product"],
        "configured":   True,
    })
    config_path.write_text(json.dumps(existing, indent=2))
    print(f"Saved to {config_path}")
    print("Bridge server will use these values on next startup.")
    print()
    print("Next step: run POST /capture (via bridge wizard or curl) to capture")
    print("the measurement protocol, or capture manually with Wireshark + USBPcap.")


if __name__ == "__main__":
    main()
