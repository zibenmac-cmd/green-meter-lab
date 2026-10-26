import { env } from 'cloudflare:workers';
import { defaults,validateReadings } from './meter.mjs';
export function db(){if(!env.DB)throw new Error('数据库尚未配置');return env.DB;}
export function json(data:unknown,status=200){return Response.json(data,{status,headers:{'Cache-Control':'no-store'}});}
export function authorized(req:Request){return !!req.headers.get('oai-authenticated-user-id');}
export function sameOrigin(req:Request){const origin=req.headers.get('origin');return !origin||origin===new URL(req.url).origin;}
export async function config(){const row=await db().prepare('SELECT value FROM settings WHERE id=?').bind('config').first<{value:string}>();return row?JSON.parse(row.value):defaults;}
export async function readJSON(req:Request){const text=await req.text();if(text.length>4_000_000)throw new Error('提交过大，最多 4 MB');return JSON.parse(text);}
export async function hash(value:string){const bytes=await crypto.subtle.digest('SHA-256',new TextEncoder().encode(value));return [...new Uint8Array(bytes)].map(x=>x.toString(16).padStart(2,'0')).join('');}
export async function insert(input:unknown,source:string){const cfg=await config();const rows=validateReadings(input,cfg.deviceId);const unique=new Map<string,typeof rows[number]>();for(const r of rows){const previous=unique.get(r.timestamp);if(previous&&(previous.power_w!==r.power_w||previous.energy_kwh!==r.energy_kwh))throw new Error('同一时间包含冲突记录');unique.set(r.timestamp,r);}
 let inserted=0;const values=[...unique.values()];
 for(let i=0;i<values.length;i+=100){const result=await db().batch(values.slice(i,i+100).map(r=>db().prepare('INSERT INTO readings (device_id,timestamp,power_w,energy_kwh,source,received_at) VALUES (?,?,?,?,?,?) ON CONFLICT(device_id,timestamp) DO NOTHING').bind(r.device_id,r.timestamp,r.power_w,r.energy_kwh,source,new Date().toISOString())));inserted+=result.reduce((s,r)=>s+(r.meta.changes||0),0);}
 return {inserted,duplicates:rows.length-inserted};
}
