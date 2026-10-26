import {validDate} from '../../../lib/meter.mjs';
import {authorized,json,db} from '../../../lib/server';
export async function GET(req:Request){if(!authorized(req))return json({error:'请登录后访问'},401);try{const p=new URL(req.url).searchParams;const from=p.get('from')||new Date(Date.now()-14*86400000).toISOString().slice(0,10);const to=p.get('to')||new Date(Date.now()+86400000).toISOString().slice(0,10);if(!validDate(from)||!validDate(to)||from>to||Date.parse(to)-Date.parse(from)>31*86400000)return json({error:'请选择不超过 31 天的有效日期范围'},400);
const start=new Date(from+'T00:00:00+08:00').toISOString(),end=new Date(to+'T23:59:59.999+08:00').toISOString();
const query='SELECT device_id,timestamp,power_w,energy_kwh,source FROM readings WHERE device_id=?';
const data=await db().prepare(query+' AND timestamp>=? AND timestamp<=? ORDER BY timestamp LIMIT 300001').bind('meter-01',start,end).all();
if(data.results.length>300000)return json({error:'记录过多，请缩小日期范围'},400);
const previous=await db().prepare(query+' AND timestamp<? ORDER BY timestamp DESC LIMIT 1').bind('meter-01',start).first();
const latest=await db().prepare(query+' ORDER BY timestamp DESC LIMIT 1').bind('meter-01').first();
const automatic=await db().prepare(query+" AND source='auto' ORDER BY timestamp DESC LIMIT 1").bind('meter-01').first();
return json({rows:previous?[previous,...data.results]:data.results,latest,automatic});}catch{return json({error:'读取失败，请检查数据库连接'},503);}}
