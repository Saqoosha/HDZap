#!/usr/bin/env python3
"""Read the SPIFFS partition from flash (m5stick-s3 + min_spiffs.csv on device may differ).
   Finds the `spiffs` entry in the partition table at 0x8000, then read_flash to a file.

   Usage:
     python3 scripts/dump_analysis_spiffs.py [--port /dev/cu.usbmodem1101] [--out firmware/out/spiffs.bin]

   Requires: PlatformIO Core (same Python that ships `pio`), and esptool under ~/.platformio/packages/tool-esptoolpy/
"""
from __future__ import annotations

import argparse
import os
import struct
import subprocess
import sys


def pio_python() -> str:
    try:
        out = subprocess.check_output(["pio", "system", "info"], text=True)
        for line in out.splitlines():
            if line.strip().startswith("Python Executable"):
                return line.split("Python Executable", 1)[1].strip().lstrip("-").strip()
    except (subprocess.CalledProcessError, FileNotFoundError):
        pass
    return sys.executable


def esptool_path() -> str:
    home = os.path.expanduser("~/.platformio/packages/tool-esptoolpy/esptool.py")
    if os.path.isfile(home):
        return home
    raise SystemExit("esptool.py not found at ~/.platformio/packages/tool-esptoolpy/")


def read_partition_table(py: str, port: str) -> bytes:
    tmp = "/tmp/esp_pt_dump.bin"
    subprocess.run(
        [py, esptool_path(), "--chip", "esp32s3", "-p", port, "read_flash", "0x8000", "0x1000", tmp],
        check=True,
    )
    with open(tmp, "rb") as f:
        return f.read()


def find_spiffs_off_size(pt: bytes) -> tuple[int, int]:
    """ESP-IDF partition table: 32-byte entries, magic 0x50AA."""
    for i in range(0, len(pt) - 32, 32):
        magic, ty, st = struct.unpack_from("<HBB", pt, i)
        if magic != 0x50AA:
            continue
        offset, size = struct.unpack_from("<II", pt, i + 4)
        label = pt[i + 12 : i + 28].split(b"\0", 1)[0].decode("ascii", errors="replace")
        if label == "spiffs":
            return offset, size
    raise SystemExit("spiffs partition not found in table (dump 0x8000)")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", default=os.environ.get("ESPPORT", "/dev/cu.usbmodem1101"))
    ap.add_argument("--out", default="firmware/out/espnow_spiffs_raw.bin")
    args = ap.parse_args()

    os.makedirs(os.path.dirname(args.out) or ".", exist_ok=True)
    py = pio_python()
    pt = read_partition_table(py, args.port)
    off, sz = find_spiffs_off_size(pt)
    print(f"SPIFFS partition: offset=0x{off:x} size=0x{sz:x}", file=sys.stderr)
    subprocess.run(
        [
            py,
            esptool_path(),
            "--chip",
            "esp32s3",
            "-p",
            args.port,
            "read_flash",
            f"0x{off:x}",
            f"0x{sz:x}",
            args.out,
        ],
        check=True,
    )
    print(args.out)


if __name__ == "__main__":
    main()
