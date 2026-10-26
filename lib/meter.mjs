export const ZONE = 8 * 3600_000;
export const defaults = { deviceId:'meter-01', name:'实验电器 · 智能电表', appliance:'待配置电器', threshold:1800, tariff:0.6, carbon:0.785 };
export function validDate(s){try{return typeof s==='string'&&/^\d{4}-\d{2}-\d{2}$/.test(s)&&new Date(s+'T00:00:00Z').toISOString().slice(0,10)===s;}catch{return false;}}
export function dayKey(time) { return new Date(new Date(time).getTime()+ZONE).toISOString().slice(0,10); }
export function validateReadings(input, deviceId='meter-01', now=Date.now()) {
  if (!Array.isArray(input) || !input.length || input.length>20000) throw new Error('每次提交 1–20,000 条记录');
  return input.map((r,i)=>{
    if (!r || r.device_id!==deviceId) throw new Error(`第 ${i+1} 行设备编号应为 ${deviceId}`);
    if (typeof r.timestamp!=='string' || !validDate(r.timestamp.slice(0,10)) || !/^\d{4}-\d{2}-\d{2}T.+(?:Z|[+-]\d{2}:\d{2})$/.test(r.timestamp) || !Number.isFinite(Date.parse(r.timestamp))) throw new Error(`第 ${i+1} 行时间必须包含时区，例如 2026-10-05T12:00:00+08:00`);
    if (Date.parse(r.timestamp)>now+60_000) throw new Error(`第 ${i+1} 行时间在未来`);
    for (const field of ['power_w','energy_kwh']) if(typeof r[field]!=='number'||!Number.isFinite(r[field])||r[field]<0) throw new Error(`第 ${i+1} 行 ${field} 必须是非负数字`);
    if(r.power_w>1000000 || r.energy_kwh>1e12) throw new Error(`第 ${i+1} 行数值超出计量范围`);
    return {device_id:deviceId,timestamp:new Date(r.timestamp).toISOString(),power_w:r.power_w,energy_kwh:r.energy_kwh};
  });
}
export function validateConfig(c) {
  if(typeof c.name!=='string'||!c.name.trim()||c.name.length>80||typeof c.appliance!=='string'||c.appliance.length>80) throw new Error('设备名称不能为空，名称最多 80 字');
  for(const [k,max] of [['threshold',1000000],['tariff',100],['carbon',10]]) if(typeof c[k]!=='number'||!Number.isFinite(c[k])||c[k]<0||c[k]>max) throw new Error('阈值、电价或碳排系数不在有效范围');
  return {...defaults,name:c.name.trim(),appliance:c.appliance.trim(),threshold:c.threshold,tariff:c.tariff,carbon:c.carbon};
}
export function connection(rows,now=Date.now()) {
 const automatic=rows.filter(r=>r.source==='auto');
 if(!automatic.length)return {state:'未连接',latest:null};
 const latest=automatic.reduce((a,b)=>Date.parse(a.timestamp)>Date.parse(b.timestamp)?a:b);
 return {state:now-Date.parse(latest.timestamp)>60000?'数据中断':'在线',latest};
}
export function summarize(rows,from,to,threshold=1800) {
 const sorted=[...rows].sort((a,b)=>Date.parse(a.timestamp)-Date.parse(b.timestamp));
 const days=new Map(); const alerts=[];
 const day=(key)=>{if(!days.has(key))days.set(key,{date:key,kwh:0,powers:[],coverage:0,intervals:0,resets:0});return days.get(key)};
 for(const r of sorted){const k=dayKey(r.timestamp);if(k>=from&&k<=to){day(k).powers.push(r.power_w);if(r.power_w>threshold)alerts.push({type:'power',timestamp:r.timestamp,message:`功率 ${r.power_w.toFixed(0)} W 超过阈值 ${threshold} W`});}}
 for(let i=1;i<sorted.length;i++){
  const a=sorted[i-1],b=sorted[i],start=Date.parse(a.timestamp),end=Date.parse(b.timestamp),seconds=(end-start)/1000,delta=b.energy_kwh-a.energy_kwh;
  if(seconds<=0)continue;
  const key=dayKey(b.timestamp);
  if(delta<0){if(key>=from&&key<=to){day(key).resets++;alerts.push({type:'reset',timestamp:b.timestamp,message:'累计电量降低，可能发生电表重置；该段不计入耗电或节电'});}continue;}
  if(seconds>60&&key>=from&&key<=to)alerts.push({type:'gap',timestamp:b.timestamp,message:`采样间隔 ${(seconds/60).toFixed(1)} 分钟；功率曲线中断，电量差仍保留`});
  let cursor=start;
  while(cursor<end){const k=dayKey(cursor);const boundary=Date.parse(k+'T00:00:00+08:00')+86400000;const next=Math.min(end,boundary);
   if(k>=from&&k<=to){const d=day(k);d.kwh+=delta*(next-cursor)/(end-start);d.intervals++;if(seconds<=60)d.coverage+=(next-cursor)/1000;}
   cursor=next;
  }
 }
 const daily=[...days.values()].sort((a,b)=>a.date.localeCompare(b.date)).map(d=>({...d,average:d.powers.length?d.powers.reduce((a,b)=>a+b,0)/d.powers.length:null,peak:d.powers.length?d.powers.reduce((m,p)=>Math.max(m,p),0):null,complete:d.coverage>=20*3600&&d.resets===0&&d.date<dayKey(Date.now()), samples:d.powers.length}));
 const filtered=sorted.filter(r=>{const k=dayKey(r.timestamp);return k>=from&&k<=to;});
 return {daily,alerts,rows:filtered,kwh:daily.reduce((s,d)=>s+d.kwh,0),peak:filtered.length?filtered.reduce((m,r)=>Math.max(m,r.power_w),0):null,average:filtered.length?filtered.reduce((s,r)=>s+r.power_w,0)/filtered.length:null};
}
export function compare(daily,beforeFrom,beforeTo,afterFrom,afterTo) {
 if(beforeFrom>beforeTo||afterFrom>afterTo||!(beforeTo<afterFrom||afterTo<beforeFrom))return {error:'请选择有效且不重叠的前后时段'};
 const b=daily.filter(d=>d.date>=beforeFrom&&d.date<=beforeTo),a=daily.filter(d=>d.date>=afterFrom&&d.date<=afterTo);
 const bc=b.filter(d=>d.complete),ac=a.filter(d=>d.complete);
 if(!bc.length||!ac.length)return {error:'数据不足：前后时段各需至少 1 个有效日（覆盖 ≥20 小时且无重置）',beforeDays:b.length,afterDays:a.length};
 const before=bc.reduce((s,d)=>s+d.kwh,0)/bc.length,after=ac.reduce((s,d)=>s+d.kwh,0)/ac.length;
 return {before,after,beforeDays:b.length,afterDays:a.length,beforeValid:bc.length,afterValid:ac.length,saved:before-after,percent:before>0?(before-after)/before*100:null};
}
export function parseCSV(text,deviceId) {
 const lines=[];const s=text.replace(/^\uFEFF/,'');let row=[],cell='',quoted=false;
 for(let i=0;i<s.length;i++){const c=s[i];if(c==='"'){if(quoted&&s[i+1]==='"'){cell+='"';i++;}else quoted=!quoted;}else if(c===','&&!quoted){row.push(cell);cell='';}else if((c==='\n'||c==='\r')&&!quoted){if(c==='\r'&&s[i+1]==='\n')i++;row.push(cell);if(row.some(v=>v.trim()))lines.push(row);row=[];cell='';}else cell+=c;}
 if(quoted)throw new Error('CSV 引号未闭合');row.push(cell);if(row.some(v=>v.trim()))lines.push(row);
 const header=lines.shift()?.map(s=>s.trim()); const required=['device_id','timestamp','power_w','energy_kwh'];
 if(!header||required.some(k=>!header.includes(k))||new Set(header).size!==header.length)throw new Error('CSV 表头需包含 device_id,timestamp,power_w,energy_kwh，且不可重复');
 const records=lines.map((r,i)=>{if(r.length!==header.length)throw new Error(`第 ${i+2} 行列数错误`);const o=Object.fromEntries(header.map((k,j)=>[k,r[j].trim()]));if(o.power_w===''||o.energy_kwh==='')throw new Error(`第 ${i+2} 行数值为空`);return {...o,power_w:Number(o.power_w),energy_kwh:Number(o.energy_kwh)};});
 return validateReadings(records,deviceId);
}
export function toCSV(rows){const columns=['device_id','timestamp','power_w','energy_kwh','source'];const escape=v=>'"'+String(v??'').replaceAll('"','""')+'"';return '\uFEFF'+columns.join(',')+'\r\n'+rows.map(r=>columns.map(c=>escape(r[c])).join(',')).join('\r\n');}
export function demoReadings(now=Date.now()) {
 const end=Math.floor(now/60000)*60000,start=Date.parse(dayKey(end)+'T00:00:00+08:00')-13*86400000;
 let energy=100;const rows=[];
 for(let t=start,i=0;t<=end;t+=60000,i++){const h=new Date(t+ZONE).getUTCHours();const saving=t>=start+7*86400000;const wave=Math.sin(i*0.023)*70+Math.cos(i*.041)*35;let p=(h>=8&&h<22?760:95)+wave;if(saving)p*=.76;if(i%3700<10)p=1980; p=Math.max(25,p);if(i)energy+=p/60/1000;rows.push({device_id:'meter-01',timestamp:new Date(t).toISOString(),power_w:Math.round(p),energy_kwh:+energy.toFixed(6),source:'demo'});}
 return rows;
}
