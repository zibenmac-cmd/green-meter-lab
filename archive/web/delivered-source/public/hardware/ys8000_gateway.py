#!/usr/bin/env python3
"""Configurable YS8000 waveform gateway. Python 3.9+, standard library only.
Only #/$ acquisition commands are sent. Never sends relay commands.
The supplied manual does not specify complete binary markers: configuration is required.
"""
import argparse
import ipaddress
import json
import math
import os
import socket
import sqlite3
import struct
import sys
import threading
import time
import uuid
from datetime import datetime, timezone
from collections import deque
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import urlparse
from urllib.request import Request, urlopen


class FrameParser:
    def __init__(self, points, header, trailer, byte_order='little'):
        if not 8 <= points <= 256 or len(header) != 3 or len(trailer) != 3:
            raise ValueError('Confirm 3-byte header/trailer and 8–256 samples per cycle.')
        if byte_order not in ('little', 'big'):
            raise ValueError('byte_order must be little or big')
        self.points, self.header, self.trailer = points, header, trailer
        self.length = points * 4 + 6
        self.format = ('<' if byte_order == 'little' else '>') + 'h' * points * 2
        self.buffer = bytearray()
        self.rejected = 0

    def feed(self, data):
        self.buffer.extend(data)
        frames = []
        while True:
            pos = self.buffer.find(self.header)
            if pos < 0:
                self.buffer[:] = self.buffer[-2:]
                break
            if pos:
                del self.buffer[:pos]
                self.rejected += 1
            if len(self.buffer) < self.length:
                break
            if self.buffer[self.length - 3:self.length] != self.trailer:
                del self.buffer[0]
                self.rejected += 1
                continue
            values = struct.unpack(self.format, self.buffer[3:self.length - 3])
            frames.append((values[:self.points], values[self.points:]))
            del self.buffer[:self.length]
        return frames


def physical(voltage, current, cfg):
    # Raw ADC zero offsets are removed before conversion to physical units.
    v = [(x - cfg['voltage_offset_adc']) * cfg['voltage_scale'] for x in voltage]
    i = [(x - cfg['current_offset_adc']) * cfg['current_scale'] * cfg['current_sign'] for x in current]
    if any(abs(x) > 2000 for x in v) or any(abs(x) > 500 for x in i):
        raise ValueError('Waveform out of range: verify channels and calibration.')
    return v, i


def validate_config(cfg):
    if cfg.get('calibration_confirmed') is not True:
        raise ValueError('calibration_confirmed must be true after measurement validation.')
    if cfg.get('frame_format_confirmed') is not True:
        raise ValueError('frame_format_confirmed must be true after checking a captured packet.')
    ipaddress.ip_address(cfg['host'])
    for k in ('voltage_scale', 'current_scale'):
        if not isinstance(cfg[k], (int, float)) or not math.isfinite(cfg[k]) or cfg[k] <= 0:
            raise ValueError('Calibration scales must be finite and positive.')
    if cfg.get('current_sign') not in (-1, 1):
        raise ValueError('current_sign must be -1 or 1')
    for k in ('voltage_offset_adc', 'current_offset_adc'):
        if not isinstance(cfg[k], (int, float)) or not math.isfinite(cfg[k]):
            raise ValueError('ADC offsets must be finite')
    if cfg['line_hz'] not in (50, 60) or cfg['sample_rate_hz'] != cfg['points_per_cycle'] * cfg['line_hz']:
        raise ValueError('sample_rate_hz must equal points_per_cycle * line_hz')
    if not 1 <= cfg['port'] <= 65535 or cfg['device_id'] != 'meter-01':
        raise ValueError('Invalid port or device ID')
    return FrameParser(cfg['points_per_cycle'], bytes.fromhex(cfg['header_hex']), bytes.fromhex(cfg['trailer_hex']), cfg['byte_order'])


def open_store(path):
    con = sqlite3.connect(path, timeout=20)
    con.execute('PRAGMA journal_mode=WAL')
    con.execute('CREATE TABLE IF NOT EXISTS state (id INTEGER PRIMARY KEY, energy REAL, session TEXT, fingerprint TEXT)')
    con.execute('CREATE TABLE IF NOT EXISTS outbox (id INTEGER PRIMARY KEY, body TEXT NOT NULL)')
    return con


def upload_loop(path, stop, site, key, access):
    con = open_store(path)
    headers = {'Content-Type': 'application/json', 'Authorization': 'Bearer ' + key}
    if access:
        headers['OAI-Sites-Authorization'] = 'Bearer ' + access
    while not stop.is_set():
        row = con.execute('SELECT id,body FROM outbox ORDER BY id LIMIT 1').fetchone()
        if not row:
            stop.wait(.2)
            continue
        try:
            with urlopen(Request(site + '/api/ys8000', data=row[1].encode(), headers=headers, method='POST'), timeout=15) as r:
                if r.headers.get('Content-Type', '').split(';')[0] != 'application/json':
                    print('Upload paused: returned a sign-in page; verify Site credentials.', file=sys.stderr)
                    stop.set()
                    break
                body = json.load(r)
                if 'inserted' not in body or 'duplicates' not in body:
                    raise ValueError('Unexpected response')
            with con:
                con.execute('DELETE FROM outbox WHERE id=?', (row[0],))
        except HTTPError as e:
            print('Upload HTTP %d. Pending readings remain in the local outbox.' % e.code, file=sys.stderr)
            if e.code < 500:
                stop.set()
                break
            stop.wait(5)
        except (URLError, OSError, TimeoutError, ValueError):
            print('Upload unavailable; preserving readings locally.', file=sys.stderr)
            stop.wait(5)
    con.close()


def run(cfg, state_path):
    validate_config(cfg)
    site = os.environ.get('METER_SITE_URL', '').rstrip('/')
    key, access = os.environ.get('METER_INGEST_KEY', ''), os.environ.get('METER_SITE_ACCESS_TOKEN', '')
    u = urlparse(site)
    local = u.hostname in ('localhost', '127.0.0.1')
    if u.path or u.query or u.fragment or u.username or u.password or not (u.scheme == 'https' or local and u.scheme == 'http'):
        raise ValueError('METER_SITE_URL must be an HTTPS origin (localhost allowed for development).')
    if not key or not local and not access:
        raise ValueError('Set METER_INGEST_KEY and private METER_SITE_ACCESS_TOKEN in the environment.')
    con = open_store(state_path)
    fingerprint = json.dumps({k: cfg[k] for k in sorted(cfg) if k not in ('host', 'port')}, sort_keys=True)
    saved = con.execute('SELECT energy,session,fingerprint FROM state WHERE id=1').fetchone()
    if saved and saved[2] != fingerprint:
        raise ValueError('Calibration/configuration changed. Use a new --state file to start a distinct session.')
    energy, session = (saved[0], saved[1]) if saved else (0., 'ys-' + str(uuid.uuid4()))
    stop = threading.Event()
    uploader = threading.Thread(target=upload_loop, args=(state_path, stop, site, key, access), daemon=True)
    uploader.start()
    sock = None
    try:
        while not stop.is_set():
            parser = validate_config(cfg)
            samples_v, samples_i = [], []
            recent = deque(maxlen=180)
            window_powers = []
            try:
                sock = socket.create_connection((cfg['host'], cfg['port']), timeout=5)
                sock.settimeout(3)
                sock.sendall(b'$')
                time.sleep(.1)
                sock.sendall(b'#')
                print('Collecting %d paired points/s. Session %s' % (cfg['sample_rate_hz'], session), flush=True)
                while not stop.is_set():
                    packet = sock.recv(16384)
                    if not packet:
                        raise ConnectionError('Device disconnected')
                    rejected = parser.rejected
                    frames = parser.feed(packet)
                    if parser.rejected != rejected:
                        samples_v, samples_i = [], []
                        recent.clear()
                        window_powers.clear()
                        print('Frame alignment lost: partial window discarded. Verify framing.', file=sys.stderr)
                        # Do not integrate windows that straddle invalid frames.
                        continue
                    for raw_v, raw_i in frames:
                        v, i = physical(raw_v, raw_i, cfg)
                        samples_v.extend(v)
                        samples_i.extend(i)
                        if len(samples_v) < cfg['sample_rate_hz']:
                            continue
                        n = len(samples_v)
                        power = sum(a*b for a, b in zip(samples_v, samples_i)) / n
                        if power < 0:
                            raise ValueError('Negative active power. Verify calibration/current direction; no absolute value is applied.')
                        duration = n / cfg['sample_rate_hz']
                        energy += power * duration / 3600000
                        timestamp = datetime.now(timezone.utc).isoformat(timespec='milliseconds')
                        recent.append({'timestamp': timestamp, 'power_w': power})
                        window_powers.append(power)
                        with con:
                            con.execute('INSERT INTO state VALUES (1,?,?,?) ON CONFLICT(id) DO UPDATE SET energy=excluded.energy,session=excluded.session,fingerprint=excluded.fingerprint', (energy, session, fingerprint))
                        if len(window_powers) < 10:
                            samples_v, samples_i = [], []
                            continue
                        # Keep 3 full cycles for the latest waveform; full-rate acquisition is used for power/energy.
                        keep = min(cfg['points_per_cycle']*3, 512 // cfg['points_per_cycle']*cfg['points_per_cycle'])
                        body = {'device_id': cfg['device_id'], 'timestamp': timestamp, 'power_w': sum(window_powers) / len(window_powers), 'energy_kwh': energy, 'energy_basis': 'waveform_integral', 'session_id': session, 'calibration_confirmed': True, 'sample_rate_hz': cfg['sample_rate_hz'], 'line_hz': cfg['line_hz'], 'voltage': samples_v[-keep:], 'current': samples_i[-keep:], 'acquisition_duration_s': duration * len(window_powers), 'recent_power': list(recent)}
                        with con:
                            con.execute('INSERT INTO state VALUES (1,?,?,?) ON CONFLICT(id) DO UPDATE SET energy=excluded.energy,session=excluded.session,fingerprint=excluded.fingerprint', (energy, session, fingerprint))
                            con.execute('INSERT INTO outbox(body) VALUES (?)', (json.dumps(body, allow_nan=False),))
                        window_powers.clear()
                        print('P=%.2f W; E=%.8f kWh (software estimate)' % (power, energy), flush=True)
                        samples_v, samples_i = [], []
            except (socket.timeout, ConnectionError, OSError) as e:
                print('Device stream interrupted. Partial window discarded; gaps are not integrated.', file=sys.stderr)
                stop.wait(3)
            finally:
                if sock:
                    try:
                        sock.sendall(b'$')
                    except OSError:
                        pass
                    sock.close()
                    sock = None
    finally:
        stop.set()
        uploader.join(timeout=16)
        con.close()


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--config', required=True)
    ap.add_argument('--state', default='ys8000-state.sqlite', help='Persistent local energy counter and upload outbox; no credentials stored.')
    ap.add_argument('--check-config', action='store_true', help='Validate configuration only; never connects to device or Site.')
    args = ap.parse_args()
    cfg = json.loads(Path(args.config).read_text(encoding='utf-8'))
    validate_config(cfg)
    if args.check_config:
        print('Configuration valid. Hardware protocol and calibration still require physical verification.')
        return
    run(cfg, args.state)


if __name__ == '__main__':
    try:
        main()
    except KeyboardInterrupt:
        print('Stopped. Pending readings are preserved in the local outbox.')
    except (ValueError, KeyError, TypeError) as e:
        sys.exit(str(e))
