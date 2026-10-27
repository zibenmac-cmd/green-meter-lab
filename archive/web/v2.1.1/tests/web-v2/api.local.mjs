// Integration fixtures stay in local Miniflare only. Never run against a deployment.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import {features,FEATURE_VERSION} from '../../lib/learning-v2.mjs';
const base='http://127.0.0.1:8787',env=Object.fromEntries(fs.readFileSync('.dev.vars','utf8').trim().split('\n').map(l=>l.split('='))),id=crypto.randomUUID();let cookie='',key='';
async function call(path,method='GET',body,expected=200,token){const r=await fetch(base+'/api'+path,{method,headers:{Origin:base,...(cookie?{Cookie:cookie}:{}),...(body?{'Content-Type':'application/json'}:{}),...(token?{Authorization:'Bearer '+token}:{})},body:body?JSON.stringify(body):undefined});const text=await r.text();assert.equal(r.status,expected,path+': '+text.slice(0,500));if(path==='/auth/login'&&r.ok)cookie=r.headers.get('set-cookie').split(';')[0];return text.startsWith('{')||text.startsWith('[')?JSON.parse(text):text;}
await call('/config','GET',undefined,401);await call('/auth/login','POST',{key:'wrong'},401);await call('/auth/login','POST',{key:env.ADMIN_KEY});
assert.equal((await call('/auth/status')).authenticated,true);
const cfg=await call('/config');assert.equal((await call('/config','PUT',{...cfg,threshold:1000})).threshold,1000);await call('/config','PUT',{...cfg,threshold:-1},400);
const a=await call('/appliances','POST',{name:'本机集成测试灯 '+id.slice(0,4),rated_power:1000});
const time=Date.parse('2026-03-15T12:00:00+08:00'),rows=Array.from({length:61},(_,j)=>({device_id:'local-'+id,timestamp:time+j*60000,session_id:id,power_w:1000,energy_kwh:10+j/60,quality:'calibrated',appliance_id:a.id,state:'running',state_source:'manual'}));
assert.equal((await call('/import','POST',{readings:rows})).inserted,61);assert.equal((await call('/import','POST',{readings:rows})).duplicates,61);
await call('/import','POST',{readings:[{...rows[0],device_id:'demo-bad'}]},400);
const s=await call('/analytics?from=2026-03-15&to=2026-03-15'),app=s.appliances.find(x=>x.id===a.id);assert.ok(Math.abs(app.kwh-1)<1e-8);assert.equal(app.running_seconds,3600);assert.equal(app.high_seconds,3600);assert.equal(app.peak,1000);
assert.match(await call('/export?from=2026-03-15&to=2026-03-15'),/power_w,estimated_power_w/);await call('/analytics?from=bad&to=bad','GET',undefined,400);
key=(await call('/key','POST')).key;const t=Date.now()-10000,profile='adc-shape-v1|socket128|client|192.168.1.2|'+(10000+Math.floor(Math.random()*50000))+'|6400|128',v=Array.from({length:128},(_,j)=>Math.round(160*Math.sin(2*Math.PI*j/128)+5)),current=amp=>v.map((_,j)=>Math.round(amp*Math.sin(2*Math.PI*j/128)+18)),i=current(30);
const row={device_id:'local-auto-'+id,timestamp:new Date(t).toISOString(),session_id:id,estimated_power_w:500,energy_kwh:null,quality:'reference'},window={time:row.timestamp,values:features(v,i),frames:50,voltagePreviewADC:v,currentPreviewADC:i},payload={device_id:row.device_id,profile,readings:[row],windows:[window]};
await call('/ingest','POST',payload,401,'invalid');assert.equal((await call('/ingest','POST',payload,200,key)).inserted,1);assert.equal((await call('/ingest','POST',payload,200,key)).duplicates,1);
await call('/ingest','POST',{...payload,profile:profile.replace('192.168.1.2','127.0.0.1')},400,key);
const live=await call('/live');assert.equal(live.devices[0].timestamp,t);assert.ok(Date.parse(live.recent[0].timestamp)>0);assert.equal(live.devices[0].signal.values.length,12);
await call('/learning/start','POST',{appliance_id:a.id,state:'running',device_id:'missing'},400);
const samples=['off','off','off','running','running','running'].map((state,j)=>{const start=time+j*30000,ci=current(state==='off'?0:30);return{id:'local-'+id+'-'+j,label:{applianceID:a.id,applianceName:a.name,state},profile,source:'device_user_label',featureVersion:FEATURE_VERSION,startedAt:new Date(start).toISOString(),endedAt:new Date(start+20000).toISOString(),windows:Array.from({length:20},(_,k)=>({time:new Date(start+(k+1)*1000).toISOString(),values:features(v,ci),frames:50,voltagePreviewADC:v,currentPreviewADC:ci}))}});
assert.equal((await call('/learning/import','POST',{captures:samples})).imported,6);const m=await call('/learning/train','POST',{profile});assert.equal(m.validation.passed,true);assert.equal((await call('/learning')).model.validation.passed,true);
await call('/learning/review','POST',{id:samples[0].id,excluded:true});assert.equal((await call('/learning')).model,null);await call('/learning/import','POST',{captures:[{...samples[0],source:'loopback_test_NOT_hardware'}]},400);
await call('/auth/logout','POST');cookie='';await call('/learning','GET',undefined,401);
console.log('PASS: local auth, D1 statistics, duplicate/import/export, ingest, source isolation, live timestamps, learning validation and revocation. Synthetic records remain local only.');
