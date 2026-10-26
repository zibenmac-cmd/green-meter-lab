from pathlib import Path
import json,math,socketserver,struct,time
base=Path(__file__).resolve().parent
v=[round(160*math.sin(2*math.pi*j/128)+5) for j in range(128)]
i=[round(180*math.sin(2*math.pi*j/128)+18) for j in range(128)]
words=v+i
checksum=(512+sum(x&65535 for x in words))&65535
frame=bytes([0x68,0,2])+struct.pack('<256h',*words)+struct.pack('<H',checksum)+bytes([0x11])
class Server(socketserver.ThreadingTCPServer):allow_reuse_address=True;daemon_threads=True
class Handler(socketserver.BaseRequestHandler):
    def handle(self):
        for _ in range(450):
            try:self.request.sendall(frame)
            except OSError:return
            time.sleep(.02)
server=Server(('127.0.0.1',0),Handler)
(base/'ready.json').write_text(json.dumps({'port':server.server_address[1]}))
print('Loopback synthetic calibrated-amplitude waveform server ready; not hardware.',flush=True)
server.serve_forever()
