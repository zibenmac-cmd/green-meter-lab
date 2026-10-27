// Local Miniflare only. No production mutation or hardware connection.
import fs from'node:fs';import assert from'node:assert/strict';
const base='http://127.0.0.1:8787',env=Object.fromEntries(fs.readFileSync('.dev.vars','utf8').trim().split('\n').map(l=>l.split('='))),uid=crypto.randomUUID();let cookie='';
async function call(p,m='GET',b,status=200){const r=await fetch(base+'/api'+p,{method:m,headers:{Origin:base,Cookie:cookie,'Content-Type':'application/json'},body:b?JSON.stringify(b):undefined});const t=await r.text();assert.equal(r.status,status,p+': '+t.slice(0,500));if(p==='/auth/login')cookie=r.headers.get('set-cookie').split(';')[0];return JSON.parse(t)}
await call('/campus','GET',null,401);await call('/auth/login','POST',{key:env.ADMIN_KEY});
await call('/campus/floors','POST',{count:2});await call('/campus/floors','POST',{count:2});const floors=(await call('/campus')).floors;assert.equal(floors.length,2);const floor=floors[0].id,other=floors[1].id;await call('/campus/floors','POST',{count:0},400);
const device='local-room-'+uid,plug='local-plug-'+uid,initial={device_id:device,name:'总表测试',kind:'floor',floor_id:floor,valid_from:'2026-03-14T00:00:00+08:00'};
await call('/campus/devices','POST',initial);await call('/campus/devices','POST',{...initial,device_id:'another-'+uid},400);await call('/campus/devices','POST',{...initial,device_id:plug,name:'分表测试',kind:'appliance'});
const t=Date.parse('2026-03-15T12:00:00+08:00'),rows=Array.from({length:61},(_,j)=>({device_id:device,timestamp:t+j*60000,session_id:uid,power_w:1000,energy_kwh:10+j/60,quality:'calibrated'}));
await call('/import','POST',{readings:rows});await call('/import','POST',{readings:rows.map(x=>({...x,device_id:plug}))});
let s=await call('/analytics?from=2026-03-15&to=2026-03-15&level=floor&floor='+floor);assert.ok(Math.abs(s.kwh-1)<1e-8);assert.equal(s.locations.length,1);assert.equal(s.locations[0].id,floor);
s=await call('/analytics?from=2026-03-15&to=2026-03-15&level=appliance&floor='+floor);assert.ok(Math.abs(s.kwh-1)<1e-8); // Submeter is not added to the room total.
await call('/campus/devices','POST',{...initial,floor_id:other,valid_from:'2026-03-16T00:00:00+08:00'});
s=await call('/analytics?from=2026-03-15&to=2026-03-15&level=floor&floor='+floor);assert.ok(Math.abs(s.kwh-1)<1e-8);s=await call('/analytics?from=2026-03-15&to=2026-03-15&level=floor&floor='+other);assert.equal(s.kwh,0);
const cfg={beforeFrom:'2026-03-14',beforeTo:'2026-03-16',afterFrom:'2026-03-17',afterTo:'2026-03-19',minCoverage:.95,minDays:3,pointsFactor:5,occupancyConfirmed:true,equipmentConfirmed:true,contextNote:'local synthetic fixture only'};
await call('/campus/comparison','PUT',cfg);const e=await call('/campus/effects?floor='+floor);assert.equal(e.floors.length,1);assert.ok(e.floors.every(r=>!r.qualified&&!r.canCompare));assert.equal(e.beforeDaily.length,1);assert.ok(Math.abs(e.beforeDaily[0].kwh-1)<1e-8);
await call('/campus/comparison','PUT',{...cfg,afterFrom:cfg.beforeTo},400);
const a=(await call('/campus/activities','POST',{title:'本机活动 '+uid.slice(0,4),kind:'workshop',status:'planned',scheduled_at:null,description:'non-production fixture'})).id;
for(let j=0;j<2;j++)await call('/campus/participation','PUT',{activity_id:a,floor_id:floor,status:'registered'});
let roster=await call('/campus');assert.equal(roster.participation.filter(x=>x.activity_id===a).length,1);await call('/campus/participation','PUT',{activity_id:a,floor_id:floor,status:'completed'});await call('/campus/activities/status','PUT',{id:a,status:'cancelled'});await call('/campus/participation','PUT',{activity_id:a,floor_id:other,status:'registered'},400);
await call('/analytics?from=2026-03-15&to=2026-03-15&level=invalid','GET',null,400);
console.log('PASS local campus: private API, entity persistence, floor/submeter isolation, overlap rejection, historical reassignment, effect coverage gate, comparison validation, participation deduplication and cancellation.');
