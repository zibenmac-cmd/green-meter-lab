#!/usr/bin/env python3
"""Loopback-only mock sockets for developer tests. NEVER contacts a physical device."""
import argparse
import json
from pathlib import Path
import socket
import threading
import time

PUSH = bytes.fromhex('00 ff 01 02 14 07 11 55 aa 00 01 02 03')
QUERY = b'{"device":"SIMULATED-TEST-ONLY","password":"demo-only-secret","voltage":230.0}\n'
CAPTURE = bytes.fromhex('00 ff 23 24 10 00 80 7f') * 4


def handle(conn, kind, folder):
    try:
        conn.settimeout(8)
        if kind == 'passive':
            conn.sendall(PUSH[:3]); time.sleep(.04); conn.sendall(PUSH[3:])
            while conn.recv(1024):
                pass
        elif kind == 'silent':
            while conn.recv(1024):
                pass
        elif kind == 'query':
            received = b''
            while len(received) < 8:
                received += conn.recv(8-len(received))
            if received != b'ifconfig':
                raise RuntimeError('unexpected query bytes')
            (folder/'query-command.txt').write_text(received.decode())
            conn.sendall(QUERY)
            while conn.recv(1024):
                pass
        elif kind == 'capture':
            if conn.recv(1) != b'#':
                raise RuntimeError('missing # command')
            conn.settimeout(.02)
            end = time.monotonic()+8
            while time.monotonic() < end:
                conn.sendall(CAPTURE)
                try:
                    chunk = conn.recv(1024)
                    if b'$' in chunk:
                        (folder/'capture-stop.txt').write_text('received $')
                        break
                    if not chunk:
                        break
                except socket.timeout:
                    continue
    except (OSError, RuntimeError) as exc:
        if not isinstance(exc, (BrokenPipeError, ConnectionResetError)):
            print(kind+': '+str(exc), flush=True)
    finally:
        conn.close()


def serve(server, kind, folder):
    while True:
        try:
            conn, _ = server.accept()
        except OSError:
            return
        threading.Thread(target=handle,args=(conn,kind,folder),daemon=True).start()


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--folder',required=True)
    args = parser.parse_args()
    folder = Path(args.folder).resolve(); folder.mkdir(parents=True,exist_ok=True)
    ports, servers = {}, []
    for kind in ['passive','silent','query','capture']:
        server = socket.socket(); server.bind(('127.0.0.1',0)); server.listen(4)
        servers.append(server); ports[kind] = server.getsockname()[1]
        threading.Thread(target=serve,args=(server,kind,folder),daemon=True).start()
    reserved = socket.socket(); reserved.bind(('127.0.0.1',0))
    ports['refused'] = reserved.getsockname()[1]
    reserved.close()
    timeout_socket = socket.socket(); timeout_socket.bind(('127.0.0.1',0))
    ports['timeout'] = timeout_socket.getsockname()[1]
    # On macOS a bound, non-listening TCP endpoint can silently drop SYNs.
    (folder/'ports.json').write_text(json.dumps(ports))
    print('Loopback mock ready: '+json.dumps(ports),flush=True)
    try:
        while True: time.sleep(1)
    except KeyboardInterrupt:
        pass
