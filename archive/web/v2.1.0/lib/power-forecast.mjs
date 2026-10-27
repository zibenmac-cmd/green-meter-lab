// Small ridge autoregression fitted only to preceding observations.
export function parsePowerCSV(text){
 const lines=text.replace(/^\uFEFF/,'').trim().split(/\r?\n/).filter(s=>s.trim()),headers=lines.shift()?.split(',').map(s=>s.trim().replace(/^"|"$/g,''));
 if(!headers||!headers.includes('timestamp')||!headers.includes('power_w')||new Set(headers).size!==headers.length)throw new Error('功率 CSV 需要 timestamp,power_w 表头');
 if(lines.length>20000)throw new Error('功率序列最多 20,000 行');
 const records=lines.map((line,j)=>{const cells=line.split(',').map(s=>s.trim().replace(/^"|"$/g,''));const timestamp=cells[headers.indexOf('timestamp')],power=cells[headers.indexOf('power_w')];if(cells.length!==headers.length||!/(Z|[+-]\d{2}:\d{2})$/.test(timestamp)||!Number.isFinite(Date.parse(timestamp))||power===''||!Number.isFinite(Number(power))||Number(power)<0||Number(power)>1e6)throw new Error(`第 ${j+2} 行时间或功率无效`);return{timestamp:new Date(timestamp).toISOString(),power_w:Number(power)};});
 return records;
}
function fit(series,lag=6){
 const mean=series.reduce((s,x)=>s+x,0)/series.length,scale=Math.max(1,Math.sqrt(series.reduce((s,x)=>s+(x-mean)**2,0)/series.length));
 const z=series.map(x=>(x-mean)/scale),n=lag+1,a=Array.from({length:n},()=>Array(n).fill(0)),b=Array(n).fill(0);
 for(let t=lag;t<z.length;t++){const x=[1,...z.slice(t-lag,t).reverse()];for(let j=0;j<n;j++){b[j]+=x[j]*z[t];for(let k=0;k<n;k++)a[j][k]+=x[j]*x[k];}}
 for(let j=1;j<n;j++)a[j][j]+=.5;a[0][0]+=.0001;
 for(let j=0;j<n;j++){let p=j;for(let k=j+1;k<n;k++)if(Math.abs(a[k][j])>Math.abs(a[p][j]))p=k;[a[j],a[p]]=[a[p],a[j]];[b[j],b[p]]=[b[p],b[j]];const pivot=a[j][j];if(Math.abs(pivot)<1e-10)throw new Error('功率序列无法拟合');for(let k=j;k<n;k++)a[j][k]/=pivot;b[j]/=pivot;for(let r=0;r<n;r++)if(r!==j){const f=a[r][j];for(let k=j;k<n;k++)a[r][k]-=f*a[j][k];b[r]-=f*b[j];}}
 return history=>{const x=[1,...history.slice(-lag).reverse().map(v=>(v-mean)/scale)];return mean+scale*b.reduce((s,c,j)=>s+c*x[j],0)};
}
export function forecastPower(records,horizon=30){
 if(!Array.isArray(records)||records.length<90)return {error:'至少需要连续 90 秒的每秒功率摘要'};
 const rows=records.slice(-180),values=rows.map(r=>r.power_w);
 if(values.some(v=>!Number.isFinite(v)||v<0))return{error:'功率序列无效'};
 for(let j=1;j<rows.length;j++){const dt=Date.parse(rows[j].timestamp)-Date.parse(rows[j-1].timestamp);if(!Number.isFinite(dt)||dt<500||dt>1800)return{error:'功率摘要不连续，恢复连续采集后再预测'};}
 const trainEnd=values.length-20,predict=fit(values.slice(0,trainEnd)),errors=[];
 for(let t=trainEnd;t<values.length;t++)errors.push(predict(values.slice(0,t))-values[t]);
 const mae=errors.reduce((s,e)=>s+Math.abs(e),0)/errors.length,rmse=Math.sqrt(errors.reduce((s,e)=>s+e*e,0)/errors.length);
 const fitted=fit(values),history=[...values],future=[],max=Math.max(100,...values)*2;
 for(let j=1;j<=horizon;j++){const raw=fitted(history);if(!Number.isFinite(raw)||raw>max||raw< -Math.max(100,...values))return{error:'外推不稳定，暂不输出预测'};const p=Math.max(0,raw);history.push(p);future.push({seconds:j,power_w:p,spread:Math.max(rmse,1)*Math.sqrt(j)});}
 const peak=future.reduce((a,b)=>a.power_w>b.power_w?a:b),valley=future.reduce((a,b)=>a.power_w<b.power_w?a:b);
 return {future,peak,valley,mae,rmse,historySeconds:values.length,testSeconds:20,model:'岭回归自回归 AR(6)',flat:peak.power_w-valley.power_w<Math.max(5,mae)};
}
