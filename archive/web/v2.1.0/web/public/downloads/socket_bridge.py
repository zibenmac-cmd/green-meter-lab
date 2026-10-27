#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""socket128 -> local raw/SQLite queue -> private Cloudflare ingest. No relay commands."""
import argparse,datetime,getpass,json,math,os,signal,socket,sqlite3,struct,sys,threading,time,urllib.request,urllib.error,uuid
from pathlib import Path
VERSION='adc-shape-v1'

def features(v,i):
    if len(v)!=128 or len(i)!=128 or any(not math.isfinite(x) or abs(x)>=32760 for x in v+i):raise ValueError('invalid/clipped ADC')
    n=128;vm=sum(v)/n;im=sum(i)/n;a=[x-vm for x in v];b=[x-im for x in i]
    vr=math.sqrt(sum(x*x for x in a)/n);ir=math.sqrt(sum(x*x for x in b)/n);full=math.sqrt(sum(x*x for x in i)/n)
    if vr<=5:raise ValueError('voltage signal too small')
    corr=sum(x*y for x,y in zip(a,b))/n/vr/ir if ir>1e-6 else 0
    crest=max(map(abs,b))/ir if ir>1e-6 else 0;dc=im/full if full>1e-6 else 0
    rough=sum((b[j]-b[j-1])**2 for j in range(1,n))/(n-1)/ir**2 if ir>1e-6 else 0
    bands=[]
    for k in [1,2,3,4,8]:
        re=sum(b[j]*math.cos(2*math.pi*k*j/n) for j in range(n));im2=sum(b[j]*math.sin(2*math.pi*k*j/n) for j in range(n))
        bands.append(min(1,2*(re*re+im2*im2)/(n*n*ir*ir)) if ir>1e-6 else 0)
    return [math.log1p(ir),math.log1p(full),dc,crest,max(-1,min(1,corr)),rough]+bands+[math.log1p(vr)]

class Decoder:
    def __init__(self):self.buffer=bytearray();self.good=0;self.bad=0;self.discarded=0
    def feed(self,data):
        self.buffer.extend(data);frames=[]
        while len(self.buffer)>=3:
            if self.buffer[:3]!=b'\x68\x00\x02':del self.buffer[0];self.discarded+=1;continue
            if len(self.buffer)<518:break
            packet=self.buffer[:518];words=struct.unpack('<256h',packet[3:515]);expected=(512+sum(x&65535 for x in words))&65535
            if packet[-1]!=17 or struct.unpack('<H',packet[515:517])[0]!=expected:self.bad+=1;del self.buffer[0];self.discarded+=1;continue
            del self.buffer[:518];self.good+=1;frames.append((list(words[:128]),list(words[128:])))
        return frames

def iso(t):return datetime.datetime.fromtimestamp(t,datetime.timezone.utc).isoformat(timespec='milliseconds').replace('+00:00','Z')

def open_queue(path):
    db=sqlite3.connect(str(path),timeout=30);db.execute('PRAGMA journal_mode=WAL');db.execute('CREATE TABLE IF NOT EXISTS queue(id INTEGER PRIMARY KEY AUTOINCREMENT,payload TEXT NOT NULL)');db.commit();return db

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--host',default='192.168.1.2');p.add_argument('--port',type=int,default=8266);p.add_argument('--url',default='');p.add_argument('--device',default='meter-01');p.add_argument('--sample-rate',type=int,default=6400);p.add_argument('--directory',type=Path,default=Path.home()/'Documents/绿电实验室Web采集');p.add_argument('--appliance-id',default='');p.add_argument('--state',choices=['unknown','running','off','standby'],default='unknown');p.add_argument('--voltage-scale',type=float,default=1.935205);p.add_argument('--current-scale',type=float,default=.011848);p.add_argument('--voltage-offset',type=float,default=0);p.add_argument('--current-offset',type=float,default=0);p.add_argument('--current-sign',type=int,choices=[-1,1],default=1);p.add_argument('--sync-only',action='store_true');p.add_argument('--seconds',type=int,default=0);p.add_argument('--self-test',type=Path);args=p.parse_args()
    if args.self_test:
        d=Decoder();data=args.self_test.read_bytes();frames=[]
        for j in range(0,len(data),733):frames.extend(d.feed(data[j:j+733]))
        print(json.dumps({'valid_frames':d.good,'bad_frames':d.bad,'discarded_bytes':d.discarded,'feature_dimensions':len(features(*frames[0])) if frames else 0,'note':'protocol test only, not calibrated measurement'}));return
    if not(0<args.port<65536 and 400<=args.sample_rate<=20000):p.error('invalid port / configured sample rate')
    if args.url and not args.url.startswith('https://') and not args.url.startswith(('http://127.0.0.1:','http://localhost:')):p.error('website URL must use HTTPS')
    if args.state!='unknown' and not args.appliance_id:p.error('manual state requires --appliance-id from the website')
    key=os.environ.get('GML_INGEST_KEY','')
    if args.url and not key:key=getpass.getpass('Website ingest key (hidden): ')
    args.directory.mkdir(parents=True,exist_ok=True);queue_path=args.directory/'upload-queue.sqlite';queue=open_queue(queue_path);os.chmod(queue_path,0o600)
    stop=threading.Event();profile=f'{VERSION}|socket128|client|{args.host}|{args.port}|{args.sample_rate}|128'
    def shutdown(*_):stop.set()
    signal.signal(signal.SIGINT,shutdown);signal.signal(signal.SIGTERM,shutdown)
    def upload():
        db=open_queue(queue_path)
        while not stop.is_set():
            pending=db.execute('SELECT id,payload FROM queue ORDER BY id LIMIT 10').fetchall()
            if pending and args.url:
                first=json.loads(pending[0][1]);batch=[];ids=[]
                for row_id,payload in pending:
                    item=json.loads(payload)
                    if item['profile']!=first['profile'] or item['row']['session_id']!=first['row']['session_id'] or item['row']['device_id']!=first['row']['device_id']:break
                    ids.append(row_id);batch.append(item)
                content={'device_id':first['row']['device_id'],'profile':first['profile'],'sample_rate_configured':int(first['profile'].split('|')[-2]),'readings':[r['row'] for r in batch],'windows':[r['window'] for r in batch if r.get('window')]}
                try:
                    request=urllib.request.Request(args.url.rstrip('/')+'/api/ingest',data=json.dumps(content,separators=(',',':')).encode(),headers={'Content-Type':'application/json','Authorization':'Bearer '+key},method='POST')
                    with urllib.request.urlopen(request,timeout=15) as response:result=json.load(response)
                    db.executemany('DELETE FROM queue WHERE id=?',[(i,)for i in ids]);db.commit();print(f"Synced {len(ids)} seconds; new={result.get('inserted',0)} duplicate={result.get('duplicates',0)}",flush=True)
                    if len(pending)==10:continue
                except urllib.error.HTTPError as e:print(f'Upload HTTP {e.code}; local queue retained. Check website key, device and appliance IDs.',flush=True)
                except Exception:print('Internet unavailable / upload not completed; local queue retained.',flush=True)
            if args.sync_only and not db.execute('SELECT 1 FROM queue LIMIT 1').fetchone():stop.set();break
            stop.wait(10)
        db.close()
    threading.Thread(target=upload,daemon=True).start()
    if args.sync_only:
        while not stop.wait(.5):pass
        queue.close();return
    began=time.monotonic();retry=1
    print('Passive socket128 capture. No query, start/stop or power command is sent. W is a reference estimate; configured sample rate is unverified.',flush=True)
    while not stop.is_set() and (not args.seconds or time.monotonic()-began<args.seconds):
        try:
            with socket.create_connection((args.host,args.port),timeout=5) as client:
                session=str(uuid.uuid4());client.settimeout(1);decoder=Decoder();cut=time.monotonic()+1;last_receive=time.monotonic();vectors=[];powers=[];preview=None;retry=1
                raw_path=args.directory/(datetime.datetime.now().strftime('%Y%m%d-%H%M%S')+'-'+session[:8]+'.bin');raw=raw_path.open('ab');os.chmod(raw_path,0o600)
                try:
                    while not stop.is_set() and (not args.seconds or time.monotonic()-began<args.seconds):
                        try:
                            data=client.recv(65536)
                            if not data:raise ConnectionError('socket closed')
                            raw.write(data);last_receive=time.monotonic()
                            for v,i in decoder.feed(data):
                                try:f=features(v,i)
                                except ValueError:continue
                                vectors.append(f);preview=(v,i);powers.append(sum((a-args.voltage_offset)*args.voltage_scale*(b-args.current_offset)*args.current_scale*args.current_sign for a,b in zip(v,i))/128)
                        except socket.timeout:pass
                        if time.monotonic()>=cut:
                            cut=time.monotonic()+1;timestamp=time.time();raw.flush()
                            if len(vectors)>=4 and preview:
                                power=sum(powers)/len(powers)
                                if math.isfinite(power) and power>=0:
                                    row={'device_id':args.device,'timestamp':iso(timestamp),'session_id':session,'estimated_power_w':power,'energy_kwh':None,'quality':'reference','appliance_id':args.appliance_id or None,'state':args.state,'state_source':'manual' if args.state!='unknown' else 'unknown'}
                                    window={'time':row['timestamp'],'values':[sum(x[j] for x in vectors)/len(vectors) for j in range(12)],'frames':len(vectors),'voltagePreviewADC':preview[0],'currentPreviewADC':preview[1]}
                                    queue.execute('INSERT INTO queue(payload)VALUES(?)',(json.dumps({'profile':profile,'row':row,'window':window},separators=(',',':')),));queue.commit();print(f'{row["timestamp"]} reference {power:.2f} W; {len(vectors)} frames; saved locally',flush=True)
                                else:print('Negative / invalid reference power. Raw ADC retained; check gain, zero and polarity. Not uploaded as consumption.',flush=True)
                            vectors=[];powers=[];preview=None
                        if time.monotonic()-last_receive>15:raise ConnectionError('15 seconds without socket bytes')
                finally:raw.close()
        except (OSError,ConnectionError) as e:
            print(f'Socket unavailable ({type(e).__name__}); reconnect in {retry}s. No relay action.',flush=True);stop.wait(retry);retry=min(30,retry*2)
    stop.set();queue.close();print('Capture stopped. Pending uploads remain in the local queue. Device power state unchanged.',flush=True)
if __name__=='__main__':main()
