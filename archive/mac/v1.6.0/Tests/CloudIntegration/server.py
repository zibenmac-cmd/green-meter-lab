"""Isolated localhost collector. Never connects to the socket or Cloudflare."""
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path
import json, subprocess, sys
out = Path(sys.argv[1]); out.mkdir(parents=True, exist_ok=True)
mode = 'ok'; seen = set(); captured = []; redirects = 0
class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_GET(self):
        global mode, redirects
        if self.path.startswith('/mode/'):
            mode = self.path.split('/')[-1]
        elif self.path == '/leaked': redirects += 1
        self.send_response(200); self.end_headers(); self.wfile.write(b'{}')
    def do_POST(self):
        global redirects
        if self.path != '/api/ingest': redirects += 1
        value = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        assert self.headers['Authorization'] == 'Bearer gml_'+'a'*64
        assert 0 < len(value['readings']) <= 10
        assert len(value['readings']) == len(value['windows'])
        for row, window in zip(value['readings'], value['windows']):
            assert row['device_id'] == value['device_id']
            assert row['timestamp'] == window['time'] and window['frames'] >= 4
            assert row['energy_kwh'] is None and row['quality'] == 'reference'
            assert len(window['values']) == 12 and len(window['voltagePreviewADC']) == 128
        captured.append({'mode': mode, 'body': value})
        status = int(mode) if mode.isdecimal() else 200
        response = {'inserted': 0, 'duplicates': 0}
        if mode == 'redirect':
            status = 307
        elif mode == 'ok':
            for row in value['readings']:
                key = row['device_id']+'|'+row['timestamp']
                response['duplicates' if key in seen else 'inserted'] += 1
                seen.add(key)
        self.send_response(status)
        if mode == 'redirect': self.send_header('Location','/leaked')
        self.send_header('Content-Type','application/json'); self.end_headers()
        self.wfile.write(json.dumps(response).encode())
server = ThreadingHTTPServer(('127.0.0.1',0),Handler)
import threading
threading.Thread(target=server.serve_forever,daemon=True).start()
run = subprocess.run([sys.argv[2],str(out),f'http://127.0.0.1:{server.server_port}'])
server.shutdown()
assert redirects == 0, 'redirect leaked authorization'
(out/'requests.json').write_text(json.dumps(captured,ensure_ascii=False))
(out/'server-result.json').write_text(json.dumps({'redirects':redirects,'unique_rows':len(seen),'requests':len(captured)}))
sys.exit(run.returncode)
