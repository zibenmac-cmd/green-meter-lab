import {authorized,json,readJSON,hash,db,config} from '../../../lib/server';
import {validateReadings} from '../../../lib/meter.mjs';
import {validateTelemetry} from '../../../lib/waveform.mjs';
export async function GET(req:Request){
 if(!authorized(req))return json({error:'请登录后访问'},401);
 try{const r=await db().prepare('SELECT value FROM settings WHERE id=?').bind('ys8000:latest').first<{value:string}>();return json({snapshot:r?JSON.parse(r.value):null});}catch{return json({error:'波形读取失败'},503);}
}
export async function POST(req:Request){try{
 const bearer=req.headers.get('authorization'),key=await db().prepare('SELECT value FROM settings WHERE id=?').bind('ingest_key_hash').first<{value:string}>();
 if(!key||!bearer?.startsWith('Bearer ')||await hash(bearer.slice(7))!==key.value)return json({error:'采集密钥无效'},401);
 const input=await readJSON(req),cfg=await config(),snapshot=validateTelemetry(input,cfg.deviceId),r=validateReadings([input],cfg.deviceId)[0],source='ys8000:'+snapshot.session_id;
 const old=await db().prepare('SELECT power_w,energy_kwh,source FROM readings WHERE device_id=? AND timestamp=?').bind(r.device_id,r.timestamp).first<{power_w:number;energy_kwh:number;source:string}>();
 if(old){if(old.source!==source||old.power_w!==r.power_w||old.energy_kwh!==r.energy_kwh)return json({error:'同一时间已有不同记录'},409);return json({inserted:0,duplicates:1});}
 const result=await db().batch([
  db().prepare('INSERT INTO readings (device_id,timestamp,power_w,energy_kwh,source,received_at) VALUES (?,?,?,?,?,?) ON CONFLICT(device_id,timestamp) DO NOTHING').bind(r.device_id,r.timestamp,r.power_w,r.energy_kwh,source,new Date().toISOString()),
  db().prepare("INSERT INTO settings (id,value) SELECT ?,? WHERE EXISTS (SELECT 1 FROM readings WHERE device_id=? AND timestamp=? AND source=? AND power_w=? AND energy_kwh=?) ON CONFLICT(id) DO UPDATE SET value=excluded.value WHERE json_extract(excluded.value,'$.timestamp')>json_extract(settings.value,'$.timestamp')").bind('ys8000:latest',JSON.stringify(snapshot),r.device_id,r.timestamp,source,r.power_w,r.energy_kwh)
 ]);
 return json({inserted:result[0].meta.changes,duplicates:result[0].meta.changes?0:1,energy_basis:'waveform_integral'});
 }catch(e){return json({error:e instanceof Error?e.message:'采集失败'},400);}
}
