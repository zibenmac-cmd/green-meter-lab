#!/usr/bin/env python3
"""Local simulated iSocket device. No hardware, Wi-Fi or external services used."""
import argparse
import csv
import json
import math
from pathlib import Path
import select
import socket
import struct
import time

ROOT = Path(__file__).resolve().parent / 'Fixtures'
ROOT.mkdir(exist_ok=True)
V_SCALE = 0.02452 / 1.41421
I_SCALE = 0.00257 * 128 / 1.41421
MAC = bytes.fromhex('02 00 00 00 00 01')


def crc16(data):
    crc = 0xffff
    for b in data:
        crc ^= b
        for _ in range(8):
            crc = (crc >> 1) ^ 0xa001 if crc & 1 else crc >> 1
    return crc


def frame(payload, function=0x14, fixed=False):
    body = bytes([1, function]) + struct.pack('>H', len(payload)) + payload
    return body + (b'\x55\xaa' if fixed else struct.pack('<H', crc16(body)))


vraw = [round(230 * math.sqrt(2) * math.sin(2 * math.pi * 50 * j / 6400) / V_SCALE) for j in range(640)]
iraw = [round(2 * math.sqrt(2) * math.sin(2 * math.pi * 50 * j / 6400) / I_SCALE) for j in range(640)]
voltage = [x * V_SCALE for x in vraw]
current = [x * I_SCALE for x in iraw]
wave = frame(struct.pack('>640h', *vraw) + struct.pack('640b', *iraw))
regs = [0] * 80
regs[0] = round(230 / .02452)
regs[1] = round(2 / .00257)
regs[2] = round(460 / (.02452 * .00257 * 4096))
regs[4], regs[9] = 100, 5000
parameter = frame(struct.pack('>80h', *regs), function=4, fixed=True)
bad = bytearray(wave)
bad[10] ^= 0x20
(ROOT / '模拟原机报文.bin').write_bytes(MAC + bytes(bad) + wave + parameter + wave)
with (ROOT / '模拟电表波形.csv').open('w', newline='') as f:
    writer = csv.writer(f)
    writer.writerow(['I', 'V', 'label'])
    writer.writerows((i, v, 'simulation') for v, i in zip(voltage, current))
expected = {'simulation': True, 'sample_rate_configured': 6400, 'sample_count': 640,
            'voltage_rms': math.sqrt(sum(x*x for x in voltage)/640),
            'current_rms': math.sqrt(sum(x*x for x in current)/640),
            'power_w': sum(v*i for v, i in zip(voltage, current))/640}
(ROOT / 'expected.json').write_text(json.dumps(expected, indent=2))
print(json.dumps(expected), flush=True)

parser = argparse.ArgumentParser()
parser.add_argument('--fixtures-only', action='store_true')
parser.add_argument('--seconds', type=float, default=180)
parser.add_argument('--port', type=int, default=9876)
parser.add_argument('--pause-after', type=float, default=-1)
parser.add_argument('--pause-seconds', type=float, default=0)
args = parser.parse_args()
if not args.fixtures_only:
    with socket.create_connection(('127.0.0.1', args.port), timeout=5) as conn:
        conn.sendall(MAC[:2])
        time.sleep(.03)
        conn.sendall(MAC[2:] + wave[:51])
        time.sleep(.03)
        conn.sendall(wave[51:] + wave + bytes(bad))
        conn.setblocking(False)
        end = time.monotonic() + args.seconds
        started = time.monotonic()
        received = b''
        while time.monotonic() < end:
            readable, _, _ = select.select([conn], [], [], .1)
            if readable:
                packet = conn.recv(4096)
                if not packet:
                    break
                received += packet
                request = bytes.fromhex('01 04 00 00 00 50 55 AA')
                if request in received:
                    conn.sendall(parameter)
                    print('PASS: native parameter read request verified; 80-register reply sent.', flush=True)
                    received = b''
            elapsed = time.monotonic() - started
            if not (args.pause_after <= elapsed < args.pause_after + args.pause_seconds):
                conn.sendall(wave)
        print('Local simulated device finished. No physical socket was contacted.', flush=True)
