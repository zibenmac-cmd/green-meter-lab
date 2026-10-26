import {authorized,sameOrigin,json,config,db,readJSON} from '../../../lib/server';
import {validateConfig} from '../../../lib/meter.mjs';
export async function GET(req:Request){if(!authorized(req))return json({error:'请登录后访问'},401);try{return json(await config());}catch{return json({error:'数据库不可用'},503);}}
export async function PUT(req:Request){if(!authorized(req)||!sameOrigin(req))return json({error:'未授权'},401);try{const c=validateConfig(await readJSON(req));await db().prepare('INSERT INTO settings (id,value) VALUES (?,?) ON CONFLICT(id) DO UPDATE SET value=excluded.value').bind('config',JSON.stringify(c)).run();return json(c);}catch(e){return json({error:e instanceof Error?e.message:'保存失败'},400);}}
