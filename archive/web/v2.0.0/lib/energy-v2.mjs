export const CONFIG={name:'绿电实验室',tariff:0.6,carbon:0.785,threshold:1000,goal:10};
export const DAY=86400000,ZONE=28800000;
export const dayKey=t=>new Date(Number(t)+ZONE).toISOString().slice(0,10);
export function dateRange(from,to){if(!/^\d{4}-\d{2}-\d{2}$/.test(from)||!/^\d{4}-\d{2}-\d{2}$/.test(to))throw Error('请选择有效日期');const start=Date.parse(from+'T00:00:00+08:00'),end=Date.parse(to+'T00:00:00+08:00')+DAY;if(!Number.isFinite(start)||!Number.isFinite(end)||start>=end||end-start>31*DAY||dayKey(start)!==from||dayKey(end-DAY)!==to)throw Error('日期范围应为 1–31 天');return{start,end};}
export function validateConfig(c){for(const [k,max]of[['tariff',100],['carbon',10],['threshold',100000],['goal',90]])if(!Number.isFinite(c[k])||c[k]<0||c[k]>max)throw Error('电价、系数、阈值或目标超出范围');return{...CONFIG,tariff:c.tariff,carbon:c.carbon,threshold:c.threshold,goal:c.goal};}
export function validateRows(input,now=Date.now()){
 if(!Array.isArray(input)||!input.length||input.length>10000)throw Error('每次可提交 1–10000 条记录');
 const keys=new Set();return input.map((r,index)=>{
 const timestamp=typeof r.timestamp==='number'?r.timestamp:Date.parse(r.timestamp);
 if(!r.device_id||!/^[\w.-]{1,64}$/.test(r.device_id)||!Number.isFinite(timestamp)||timestamp<1577808000000||timestamp>now+60000)throw Error(`第 ${index+1} 条设备或时间无效`);
 if(typeof r.timestamp==='string'&&!/(Z|[+-]\d{2}:\d{2})$/.test(r.timestamp))throw Error('时间须包含时区');
 if(r.source==='demo'||r.device_id.startsWith('demo-')||r.source==='loopback_test_NOT_hardware')throw Error('演示或回环记录不能导入真实数据空间');
 const quality=['calibrated','reference'].includes(r.quality)?r.quality:(Number.isFinite(r.estimated_power_w)?'reference':'calibrated');
 const power=r.power??(quality==='reference'?r.estimated_power_w:r.power_w);
 if(!Number.isFinite(power)||power<0||power>1e6)throw Error(`第 ${index+1} 条功率无效；负功率须先检查通道与极性`);
 const energy=r.energy??r.energy_kwh??null;if(energy!==null&&(!Number.isFinite(energy)||energy<0||energy>1e12))throw Error('累计电量无效');
 if(quality==='reference'&&energy!==null)throw Error('未标定参考功率不能冒充累计电表读数');
 const session=String(r.session_id||'meter-counter').slice(0,100),state=['running','off','standby'].includes(r.state)?r.state:'unknown';
 const key=r.device_id+'|'+timestamp;if(keys.has(key))throw Error('本次提交存在重复时间记录');keys.add(key);
 return{device_id:r.device_id,timestamp,session_id:session,power,energy,quality,appliance_id:typeof r.appliance_id==='string'?r.appliance_id.slice(0,64):null,state,state_source:['manual','learned'].includes(r.state_source)?r.state_source:'unknown'};
 });
}
// The same bounded intervals power the charts, totals and duration denominators.
export function analyseRows(rows,appliances,from,to,cfg=CONFIG){
 const{start,end}=dateRange(from,to),daily=[],byId=new Map(appliances.map(a=>[a.id,{...a,kwh:0,running_seconds:0,high_seconds:0,covered_seconds:0,unknown_seconds:0,standby_kwh:0,peak:0,reference_seconds:0}]));
 for(let t=start;t<end;t+=DAY)daily.push({date:dayKey(t),kwh:0,seconds:0,reference_kwh:0});
 const days=new Map(daily.map(d=>[d.date,d])),groups=new Map();let resets=0,gaps=0;
 for(const r of [...rows].sort((a,b)=>a.timestamp-b.timestamp)){
 const prev=groups.get(r.device_id);groups.set(r.device_id,r);if(r.timestamp<start||prev?.timestamp>=end)continue;
 if(!prev)continue;const dt=r.timestamp-prev.timestamp;if(dt<=0)continue;if(dt>60000){gaps++;continue;}if(r.session_id!==prev.session_id||r.quality!==prev.quality){gaps++;continue;}
 const meter=prev.energy!=null&&r.energy!=null;if(meter&&r.energy<prev.energy){resets++;continue;}
 const sameLabel=r.appliance_id===prev.appliance_id&&r.state===prev.state;const delta=meter?r.energy-prev.energy:(sameLabel?(prev.power+r.power)*.5:prev.power)*dt/3600000000;
 if(!Number.isFinite(delta)||delta<0)continue;
 const a=byId.get(prev.appliance_id)||byId.get('unknown');const left=Math.max(start,prev.timestamp),right=Math.min(end,r.timestamp),seconds=(right-left)/1000;if(seconds<=0)continue;
 if(a){a.kwh+=delta*seconds/(dt/1000);a.covered_seconds+=seconds;a.running_seconds+=prev.state==='running'?seconds:0;a.high_seconds+=prev.power>=cfg.threshold?seconds:0;a.unknown_seconds+=prev.state==='unknown'?seconds:0;a.standby_kwh+=['standby','off'].includes(prev.state)?delta*seconds/(dt/1000):0;a.reference_seconds+=prev.quality==='reference'?seconds:0;a.peak=Math.max(a.peak,prev.power);}
 for(let t=left;t<right;){const key=dayKey(t),next=Math.min(right,Date.parse(key+'T00:00:00+08:00')+DAY),d=days.get(key);if(d){d.kwh+=delta*(next-t)/dt;d.seconds+=(next-t)/1000;d.reference_kwh+=prev.quality==='reference'?delta*(next-t)/dt:0;}t=next;}
 }
 const list=[...byId.values()].filter(a=>a.covered_seconds>0),total=daily.reduce((s,d)=>s+d.kwh,0),coverage=daily.reduce((s,d)=>s+d.seconds,0);
 return{daily,appliances:list,kwh:total,covered_seconds:coverage,reference_kwh:daily.reduce((s,d)=>s+d.reference_kwh,0),peak:Math.max(0,...list.map(a=>a.peak)),resets,gaps,records:rows.filter(r=>r.timestamp>=start&&r.timestamp<end).length};
}
export function recommendations(summary,cfg=CONFIG){
 const a=[...(summary.appliances||[])].sort((a,b)=>b.kwh-a.kwh),total=summary.kwh||0;
 if(!summary.covered_seconds)return[{type:'setup',title:'先建立你的用电基线',detail:'连接本机采集程序，或导入带时间与功率的真实记录。至少覆盖一天后再比较日常用电。',metric:'等待真实记录',appliance:null}];
 const result=[],top=a[0];if(top&&total>0)result.push({type:'focus',title:`优先关注${top.name}`,detail:`占已记录电量的 ${(top.kwh/total*100).toFixed(0)}%。先检查它的运行设置与空转时段，再记录调整前后的差异。`,metric:`${top.kwh.toFixed(2)} kWh`,appliance:top.id});
 const high=a.filter(x=>Math.max(x.rated_power||0,x.peak)>=cfg.threshold&&x.covered_seconds>0).sort((x,y)=>y.high_seconds-x.high_seconds)[0];
 if(high)result.push({type:'high',title:`缩短${high.name}的高功率时段`,detail:`在全部有效观测时间中，超过 ${cfg.threshold} W 的比例为 ${(100*high.high_seconds/summary.covered_seconds).toFixed(1)}%。优先查看无人使用的运行时段；错峰能降低同时使用的峰值，未必减少总电量。`,metric:`高功率 ${(high.high_seconds/3600).toFixed(1)} 小时`,appliance:high.id});
 const standby=a.reduce((s,x)=>s+x.standby_kwh,0);if(standby>0.01)result.push({type:'standby',title:'检查长时间待机耗电',detail:'以下电量来自标注为关闭或待机的有效记录。先确认设备是否需要常开，再考虑通过设备自身设置减少闲置耗电。',metric:`待机 ${standby.toFixed(2)} kWh`,appliance:null});
 result.push({type:'goal',title:`设置 ${cfg.goal}% 的用电改善目标`,detail:`按同样观测时长测算，减少 ${(total*cfg.goal/100).toFixed(2)} kWh 可少支出约 ¥${(total*cfg.goal/100*cfg.tariff).toFixed(2)}。这是目标情景估算，后续需要前后对照验证。`,metric:`情景目标 · 非承诺`,appliance:null});
 const unknown=a.reduce((s,x)=>s+x.unknown_seconds,0);if(unknown>summary.covered_seconds*.2)result.push({type:'quality',title:'补齐电器与状态标签',detail:`${(100*unknown/summary.covered_seconds).toFixed(0)}% 的有效观测时间尚未确定使用状态。补充人工标签或通过学习验证后，使用率分析会更完整。`,metric:'改善记录质量',appliance:null});return result;
}
export function demoData(now=Date.now(),days=7){
 const appliances=[{id:'ac',name:'空调',rated_power:1450,color:'#2b7557'},{id:'heater',name:'电热水壶',rated_power:1800,color:'#a6bc84'},{id:'washer',name:'洗衣机',rated_power:650,color:'#dba264'},{id:'dryer',name:'吹风机',rated_power:1600,color:'#6d9e91'},{id:'computer',name:'笔记本电脑',rated_power:90,color:'#b7c4b4'},{id:'unknown',name:'未标记电器',rated_power:0,color:'#c4ccc2'}];
 const end=Math.floor(now/60000)*60000,start=Date.parse(dayKey(end)+'T00:00:00+08:00')-(days-1)*DAY,rows=[];
 for(let t=start;t<=end;t+=60000){const h=new Date(t+ZONE).getUTCHours(),minute=new Date(t+ZONE).getUTCMinutes(),day=Math.floor((t-start)/DAY);for(let j=0;j<5;j++){const a=appliances[j];const on=j===0?(h>=13&&h<17||h>=20&&h<24):j===1?([7,12,20].includes(h)&&minute<6):j===2?(h===18&&day%2===0):j===3?(h===22&&minute<12):(h>=9&&h<19);if(on){const priority=j===1?0:j===2?1:j===3?2:j===0?3:4;const power=a.rated_power*(j===0?.78+.09*Math.sin(t/3e6):j===2?.32+.2*Math.sin(t/2e5):.9);const record={device_id:'demo-meter',timestamp:t,session_id:'demo',power,energy:null,quality:'reference',appliance_id:a.id,state:'running',state_source:'manual',priority};if(rows.at(-1)?.timestamp===t){if(priority<rows.at(-1).priority)rows[rows.length-1]=record;}else rows.push(record);}}if(rows.at(-1)?.timestamp!==t)rows.push({device_id:'demo-meter',timestamp:t,session_id:'demo',power:3.8,energy:null,quality:'reference',appliance_id:'unknown',state:'standby',state_source:'manual'});}
 return{appliances,rows};
}
export function csvRows(text){const lines=[],s=text.replace(/^\uFEFF/,'');let row=[],cell='',quoted=false;for(let i=0;i<s.length;i++){const c=s[i];if(c==='"'){if(quoted&&s[i+1]==='"'){cell+='"';i++;}else quoted=!quoted;}else if(c===','&&!quoted){row.push(cell);cell='';}else if((c==='\n'||c==='\r')&&!quoted){if(c==='\r'&&s[i+1]==='\n')i++;row.push(cell);if(row.some(v=>v.trim()))lines.push(row);row=[];cell='';}else cell+=c;}if(quoted)throw Error('CSV 引号没有闭合');row.push(cell);if(row.some(v=>v.trim()))lines.push(row);const head=lines.shift()?.map(x=>x.trim());if(!head||!['device_id','timestamp'].every(k=>head.includes(k))||!['power_w','estimated_power_w'].some(k=>head.includes(k))||new Set(head).size!==head.length)throw Error('请使用页面提供的 CSV 模板');const records=lines.map((r,i)=>{if(r.length!==head.length)throw Error(`CSV 第 ${i+2} 行列数不符`);const o=Object.fromEntries(head.map((k,j)=>[k,r[j].trim()]));for(const k of['power_w','estimated_power_w','energy_kwh'])if(k in o)o[k]=o[k]===''?null:Number(o[k]);return o;});return validateRows(records);}
export function toCSV(rows){const cols=['device_id','timestamp','session_id','power_w','estimated_power_w','energy_kwh','quality','appliance_id','state','state_source'];const escape=x=>'"'+String(x??'').replaceAll('"','""')+'"';return '\uFEFF'+cols.join(',')+'\r\n'+rows.map(r=>cols.map(k=>escape(k==='timestamp'?new Date(r.timestamp).toISOString():k==='power_w'?r.quality==='calibrated'?r.power:null:k==='estimated_power_w'?r.quality==='reference'?r.power:null:k==='energy_kwh'?r.energy:r[k])).join(',')).join('\r\n');}
