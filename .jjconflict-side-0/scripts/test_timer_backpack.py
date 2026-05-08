"""
Send OSD test message via Timer Backpack (ELRS Backpack FW).
Timer Backpack listens on Serial 460800 baud for MSPv2 packets.
"""
import serial
import hashlib
import time
import sys

# --- MSPv2 helpers ---

def crc8_dvb_s2(crc, byte):
    crc ^= byte
    for _ in range(8):
        crc = ((crc << 1) ^ 0xD5) if (crc & 0x80) else (crc << 1)
        crc &= 0xFF
    return crc

def msp_build(function, payload=b""):
    buf = bytearray()
    buf.append(0x24)  # $
    buf.append(0x58)  # X
    buf.append(0x3C)  # <
    buf.append(0x00)  # flags
    buf.append(function & 0xFF)
    buf.append((function >> 8) & 0xFF)
    buf.append(len(payload) & 0xFF)
    buf.append((len(payload) >> 8) & 0xFF)
    buf.extend(payload)
    crc = 0
    for b in buf[3:]:
        crc = crc8_dvb_s2(crc, b)
    buf.append(crc)
    return bytes(buf)

# --- UID from bind phrase ---

def uid_from_phrase(phrase):
    full = f'-DMY_BINDING_PHRASE="{phrase}"'
    h = hashlib.md5(full.encode()).digest()[:6]
    uid = bytearray(h)
    uid[0] &= ~0x01
    return bytes(uid)

# --- MSP commands ---

MSP_ELRS_SET_SEND_UID = 0x00B5
MSP_ELRS_SET_OSD = 0x00B6

def set_send_uid(ser, uid):
    payload = bytearray([0x01]) + bytearray(uid)
    ser.write(msp_build(MSP_ELRS_SET_SEND_UID, payload))

def reset_send_uid(ser):
    ser.write(msp_build(MSP_ELRS_SET_SEND_UID, b"\x00"))

def osd_clear(ser):
    ser.write(msp_build(MSP_ELRS_SET_OSD, b"\x02"))

def osd_write(ser, row, col, text):
    text = text.upper()  # BF OSD font: no lowercase
    payload = bytearray([0x03, row, col, 0x00]) + text.encode("ascii")
    ser.write(msp_build(MSP_ELRS_SET_OSD, payload))

def osd_draw(ser):
    ser.write(msp_build(MSP_ELRS_SET_OSD, b"\x04"))

# --- Main ---

BIND_PHRASE = "saqhdz"
PORT = "/dev/cu.usbserial-110"
BAUD = 460800

uid = uid_from_phrase(BIND_PHRASE)
print(f"Bind phrase: {BIND_PHRASE}")
print(f"UID: {':'.join(f'{b:02X}' for b in uid)}")

ser = serial.Serial(PORT, BAUD, timeout=1)
time.sleep(1)

print("Sending OSD via Timer Backpack...")

set_send_uid(ser, uid)
osd_clear(ser)
osd_write(ser, 4, 10, "TIMER BACKPACK")
osd_write(ser, 6, 10, "OSD TEST OK!")
osd_write(ser, 8, 10, "VIA SERIAL MSP")
osd_draw(ser)
reset_send_uid(ser)

print("Done!")
ser.close()
