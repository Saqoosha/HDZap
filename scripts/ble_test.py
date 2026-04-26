#!/usr/bin/env python3
"""HDZero Lap Timer BLE control CLI for macOS.

Acts as a stand-in for the iOS app so we can drive the M5Stick from
the command line during debugging — no tapping required.

Usage (run via the prepared venv at /tmp/ble-env):
    /tmp/ble-env/bin/python ble_test.py status
    /tmp/ble-env/bin/python ble_test.py test
    /tmp/ble-env/bin/python ble_test.py bind saqhdz
    /tmp/ble-env/bin/python ble_test.py uid 60:D2:53:8A:B2:9E
    /tmp/ble-env/bin/python ble_test.py uid 96 210 83 138 178 158
    /tmp/ble-env/bin/python ble_test.py clear
    /tmp/ble-env/bin/python ble_test.py resetlaps
    /tmp/ble-env/bin/python ble_test.py lap 1 12345         # send fake lap
"""

import asyncio
import sys
import hashlib

from bleak import BleakClient, BleakScanner

DEVICE_NAME = "HDZeroOSD"

SERVICE_UUID    = "f47ac10b-58cc-4372-a567-0e02b2c3d479"
UID_CONFIG_UUID = "f47ac10b-58cc-4372-a567-0e02b2c3d481"
BIND_CMD_UUID   = "f47ac10b-58cc-4372-a567-0e02b2c3d482"
LAP_TIME_UUID   = "f47ac10b-58cc-4372-a567-0e02b2c3d483"
OSD_CTRL_UUID   = "f47ac10b-58cc-4372-a567-0e02b2c3d484"
STATUS_UUID     = "f47ac10b-58cc-4372-a567-0e02b2c3d485"

OSD_CMD_CLEAR = 0x01
OSD_CMD_RESET = 0x02
OSD_CMD_TEST  = 0x03


def parse_uid(arg_tokens):
    """Same dual-format parser the iOS app uses (hex vs decimal)."""
    raw = " ".join(arg_tokens).replace(":", " ").replace(",", " ")
    parts = raw.split()
    if len(parts) != 6:
        raise ValueError(f"UID must be 6 bytes, got {len(parts)} parts")
    use_hex = ":" in " ".join(arg_tokens) or any(
        any(c.isalpha() for c in p) for p in parts
    )
    base = 16 if use_hex else 10
    out = bytes(int(p, base) for p in parts)
    if any(b > 0xFF for b in out):
        raise ValueError("byte out of range 0-255")
    return out


def uid_from_phrase(phrase):
    full = f'-DMY_BINDING_PHRASE="{phrase}"'
    h = hashlib.md5(full.encode()).digest()[:6]
    return bytes([h[0] & 0xFE]) + h[1:]


async def find_device():
    print(f"Scanning for '{DEVICE_NAME}'...")
    dev = await BleakScanner.find_device_by_name(DEVICE_NAME, timeout=10.0)
    if dev is None:
        raise RuntimeError(f"Could not find '{DEVICE_NAME}' — is the M5Stick powered on?")
    print(f"Found {dev.name} @ {dev.address}")
    return dev


def fmt_uid(b):
    return ":".join(f"{x:02X}" for x in b)


async def cmd_status(client):
    payload = await client.read_gatt_char(STATUS_UUID)
    if len(payload) < 8:
        print(f"Short status payload: {payload.hex()}")
        return
    connected = bool(payload[0])
    uid = payload[1:7]
    laps = payload[7]
    print(f"Connected: {connected}")
    print(f"UID:       {fmt_uid(uid)}")
    print(f"Laps:      {laps}")


async def cmd_test(client):
    print("Sending OSD test (osdControl <- 0x03)...")
    await client.write_gatt_char(OSD_CTRL_UUID, bytes([OSD_CMD_TEST]), response=True)
    print("Sent. Watch the goggle for 'HDZERO TEST' and the M5Stick LCD strip for TEST OK / TEST LOST.")


async def cmd_clear(client):
    print("Sending OSD clear (osdControl <- 0x01)...")
    await client.write_gatt_char(OSD_CTRL_UUID, bytes([OSD_CMD_CLEAR]), response=True)


async def cmd_resetlaps(client):
    print("Sending laps reset (osdControl <- 0x02)...")
    await client.write_gatt_char(OSD_CTRL_UUID, bytes([OSD_CMD_RESET]), response=True)


async def cmd_bind(client, phrase):
    uid = uid_from_phrase(phrase)
    print(f"Bind phrase '{phrase}' -> UID {fmt_uid(uid)}")
    payload = bytes([0x01]) + phrase.encode("utf-8")
    await client.write_gatt_char(UID_CONFIG_UUID, payload, response=True)
    print("Wrote uidConfig (mode 0x01). M5Stick should re-init ESP-NOW shortly.")


async def cmd_uid(client, raw_tokens):
    uid = parse_uid(raw_tokens)
    uid = bytes([uid[0] & 0xFE]) + uid[1:]   # match firmware bit0 clear
    print(f"Manual UID -> {fmt_uid(uid)}")
    payload = bytes([0x02]) + uid
    await client.write_gatt_char(UID_CONFIG_UUID, payload, response=True)
    print("Wrote uidConfig (mode 0x02). M5Stick should re-init ESP-NOW shortly.")


async def cmd_lap(client, lap_num, time_ms):
    payload = bytes([lap_num]) + int(time_ms).to_bytes(4, "little")
    print(f"Sending lap {lap_num} @ {time_ms}ms ({payload.hex()})")
    await client.write_gatt_char(LAP_TIME_UUID, payload, response=True)


async def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    cmd = sys.argv[1]
    args = sys.argv[2:]

    dev = await find_device()
    async with BleakClient(dev) as client:
        # Quick service sanity print
        services = client.services
        if not services.get_service(SERVICE_UUID):
            print(f"WARNING: service {SERVICE_UUID} not found")

        if cmd == "status":
            await cmd_status(client)
        elif cmd == "test":
            await cmd_test(client)
        elif cmd == "clear":
            await cmd_clear(client)
        elif cmd in ("reset", "resetlaps"):
            await cmd_resetlaps(client)
        elif cmd == "bind":
            if not args:
                raise SystemExit("bind requires a phrase")
            await cmd_bind(client, args[0])
        elif cmd == "uid":
            if not args:
                raise SystemExit("uid requires 6 bytes (hex or decimal)")
            await cmd_uid(client, args)
        elif cmd == "lap":
            if len(args) != 2:
                raise SystemExit("lap requires <lap_num> <time_ms>")
            await cmd_lap(client, int(args[0]), int(args[1]))
        else:
            raise SystemExit(f"unknown command: {cmd}")

        # Give the M5Stick a moment to react before we tear down BLE.
        await asyncio.sleep(0.5)


if __name__ == "__main__":
    asyncio.run(main())
