from pathlib import Path
import json,socketserver,threading,time
base=Path(__file__).resolve().parent
state={'source':'loopback_command_test_NOT_hardware','connections':0,'received':[]}
lock=threading.Lock()
class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address=True;daemon_threads=True
class Handler(socketserver.BaseRequestHandler):
    def handle(self):
        with lock:
            state['connections']+=1;number=state['connections']
            (base/'observed.json').write_text(json.dumps(state))
        count=0
        self.request.settimeout(30)
        while True:
            try:data=self.request.recv(65536)
            except OSError:return
            if not data:return
            with lock:
                state['received'].append({'connection':number,'hex':data.hex()})
                (base/'observed.json').write_text(json.dumps(state))
            count+=1
            if number==1 and count==8:return
server=Server(('127.0.0.1',0),Handler)
(base/'ready.json').write_text(json.dumps({'port':server.server_address[1]}))
print('Loopback command test server ready; no hardware connection.',flush=True)
server.serve_forever()
