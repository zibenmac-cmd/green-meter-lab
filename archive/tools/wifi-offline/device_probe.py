#!/usr/bin/env python3
"""Offline TCP probe. No network settings or relay commands are changed.
Default: connect only. YS8000 commands require explicit --ys8000 confirmation.
"""
import argparse
import ipaddress
import json
import socket
import time
from datetime import datetime
from pathlib import Path


def probe(host, port, mode='connect', seconds=3):
    ip = ipaddress.ip_address(host)
    if not ip.is_private or ip.is_unspecified or ip.is_multicast:
        raise ValueError('请填写设备的局域网 IP，不支持公网或广播/多播地址。')
    if not 1 <= port <= 65535 or mode not in ('connect', 'config', 'capture'):
        raise ValueError('端口或操作模式无效。')
    result = {'host': host, 'port': port, 'mode': mode, 'connected': False,
              'created_at': datetime.now().astimezone().isoformat(), 'bytes_received': 0}
    data = bytearray()
    with socket.create_connection((host, port), timeout=3) as sock:
        result['connected'] = True
        if mode == 'connect':
            return result, bytes(data)
        command = b'ifconfig' if mode == 'config' else b'#'
        limit = 16384 if mode == 'config' else 262144
        sock.settimeout(.5)
        started = time.monotonic()
        try:
            sock.sendall(command)
            while time.monotonic() - started < seconds and len(data) < limit:
                try:
                    chunk = sock.recv(min(8192, limit-len(data)))
                except socket.timeout:
                    continue
                if not chunk:
                    break
                data.extend(chunk)
        finally:
            if mode == 'capture':
                try:
                    sock.sendall(b'$')
                    result['stop_command_sent'] = True
                except OSError:
                    result['stop_command_sent'] = False
        result.update(bytes_received=len(data), byte_limit_reached=len(data) >= limit,
                      first_32_bytes_hex=bytes(data[:32]).hex(' '))
        # Configuration replies can include private network settings: keep them in local files.
        return result, bytes(data)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--host', required=True, help='实际设备 IP；YS8000 手册默认值为 192.168.1.2')
    ap.add_argument('--port', type=int, default=8266)
    ap.add_argument('--ys8000', action='store_true', help='仅在提供方确认此设备使用 YS8000 协议后使用')
    actions = ap.add_mutually_exclusive_group()
    actions.add_argument('--config', action='store_true', help='发送一次 ifconfig 查询，不修改配置')
    actions.add_argument('--capture', action='store_true', help='发送 #，采集约 3 秒原始字节，然后发送 $')
    ap.add_argument('--output', default='读取结果', help='输出到本机文件夹，不上传任何数据')
    args = ap.parse_args()
    if (args.config or args.capture) and not args.ys8000:
        ap.error('发送查询/采集命令前，须确认设备协议并加上 --ys8000。默认操作仅测试 TCP 连接。')
    mode = 'config' if args.config else 'capture' if args.capture else 'connect'
    folder = Path(args.output)
    folder.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now().strftime('%Y%m%d-%H%M%S-%f')
    try:
        result, data = probe(args.host, args.port, mode)
    except (OSError, ValueError) as e:
        result, data = {'host': args.host, 'port': args.port, 'mode': mode,
                        'connected': False, 'error': str(e)}, b''
    name = folder / ('probe-' + stamp)
    if data:
        raw = name.with_suffix('.bin')
        raw.write_bytes(data)
        result['raw_file'] = raw.name
        if mode == 'config':
            name.with_suffix('.txt').write_text(data.decode('utf-8', errors='replace'), encoding='utf-8')
    name.with_suffix('.json').write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding='utf-8')
    print('TCP 连接成功。' if result.get('connected') else 'TCP 连接未成功。')
    if mode != 'connect' and result.get('connected'):
        print('本次收到 %d 字节；收到字节不代表波形格式或标定已经验证。' % result['bytes_received'])
    print('结果已保存在：' + str(folder.resolve()))
    if result.get('error'):
        print('原因：' + result['error'])
    return 0 if result.get('connected') else 1


if __name__ == '__main__':
    raise SystemExit(main())
