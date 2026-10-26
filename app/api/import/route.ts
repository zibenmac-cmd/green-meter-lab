import {authorized,sameOrigin,json,readJSON,insert} from '../../../lib/server';
export async function POST(req:Request){if(!authorized(req)||!sameOrigin(req))return json({error:'未授权'},401);try{const input=await readJSON(req);return json(await insert(input.readings,'import'));}catch(e){return json({error:e instanceof Error?e.message:'导入失败'},400);}}
