# -*- coding: utf-8 -*-
"""127.0.0.1 synthetic socket128 source. Never opens a physical-device address."""
import json
import math
from pathlib import Path
import select
import socket
import struct
import sys
import time

root = Path(sys.argv[1])
root.mkdir(parents=True, exist_ok=True)
server = socket.socket()
server.bind(('127.0.0.1', 0))
server.listen(1)
(root / 'ready.json').write_text(json.dumps({'port': server.getsockname()[1]}))
client, _ = server.accept()
commands = bytearray()
frames = 0
try:
    while True:
        control = json.loads((root / 'control.json').read_text()) if (root / 'control.json').exists() else {'amplitude': 30}
        if control.get('shutdown'):
            break
        amp, third, phase = control.get('amplitude', 30), control.get('third', 0), control.get('phase', 0)
        voltage = [round(160 * math.sin(2 * math.pi * j / 128) + 5) for j in range(128)]
        current = [round(amp * (math.sin(2 * math.pi * j / 128 - phase) + third * math.sin(6 * math.pi * j / 128)) + 18) for j in range(128)]
        words = voltage + current
        checksum = (512 + sum(x & 65535 for x in words)) & 65535
        packet = b'\x68\x00\x02' + struct.pack('<256h', *words) + struct.pack('<H', checksum) + b'\x11'
        client.sendall(packet)
        frames += 1
        if select.select([client], [], [], 0)[0]:
            incoming = client.recv(1024)
            if not incoming:
                break
            commands.extend(incoming)
        time.sleep(0.02)
except (BrokenPipeError, ConnectionResetError):
    pass
finally:
    (root / 'server-result.json').write_text(json.dumps({'source': 'loopback_synthetic_NOT_hardware', 'frames': frames, 'commands_hex': commands.hex()}))
    client.close()
    server.close()
