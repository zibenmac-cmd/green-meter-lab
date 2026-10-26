// Waveform values are already calibrated physical units: V and A.
export function analyzeWaveform(voltage, current, sampleRate=1600, lineHz=50) {
 if(!Array.isArray(voltage)||!Array.isArray(current)||voltage.length!==current.length||voltage.length<16||voltage.length>32000)throw new Error('需要 16–32,000 对等长电压和电流采样');
 if(!Number.isFinite(sampleRate)||sampleRate<400||sampleRate>20000||![50,60].includes(lineHz))throw new Error('采样率或电网频率无效');
 const cycle=sampleRate/lineHz,n=voltage.length;
 if(!Number.isInteger(cycle)||n%cycle!==0)throw new Error('请导入完整周波：采样数须为每周波采样点数的整数倍');
 for(let j=0;j<n;j++)if(!Number.isFinite(voltage[j])||!Number.isFinite(current[j])||Math.abs(voltage[j])>2000||Math.abs(current[j])>500)throw new Error('波形含空值、非数字或超范围值（±2000 V / ±500 A）');
 const mean=a=>a.reduce((s,v)=>s+v,0)/n,rms=a=>Math.sqrt(mean(a.map(v=>v*v)));
 const vrms=rms(voltage),irms=rms(current),p=mean(voltage.map((v,j)=>v*current[j])),s=vrms*irms;
 const harmonics=[];const maxH=Math.min(15,Math.ceil(sampleRate/(2*lineHz))-1);
 for(let h=1;h<=maxH;h++){
  let re=0,im=0;for(let j=0;j<n;j++){const angle=2*Math.PI*h*lineHz*j/sampleRate;re+=current[j]*Math.cos(angle);im-=current[j]*Math.sin(angle);}
  harmonics.push({order:h,rms:Math.sqrt(2)*Math.hypot(re,im)/n});
 }
 const fundamental=harmonics[0]?.rms??0;
 const thd=fundamental>Math.max(1e-6,irms*.01)?Math.sqrt(harmonics.slice(1).reduce((sum,h)=>sum+h.rms*h.rms,0))/fundamental*100:null;
 const warnings=[];
 if(p<0)warnings.push('有功功率为负，请核对电流方向、通道顺序和标定。不会取绝对值或写入耗电统计。');
 if(irms>0&&Math.abs(mean(current))>irms*.2)warnings.push('电流直流偏置较大，请核对采集零点与标定系数。');
 if(thd==null)warnings.push('电流基波过小，无法可靠计算谐波畸变。');
 return {voltage_rms:vrms,current_rms:irms,power_w:p,apparent_va:s,power_factor:s>1e-9?Math.max(-1,Math.min(1,p/s)):null,current_thd_percent:thd,harmonics,sample_rate_hz:sampleRate,line_hz:lineHz,sample_count:n,duration_s:n/sampleRate,segment_energy_kwh:p*n/sampleRate/3600000,voltage_dc:mean(voltage),current_dc:mean(current),warnings};
}
export function parseWaveCSV(text) {
 const rows=text.replace(/^\uFEFF/,'').trim().split(/\r?\n/).filter(x=>x.trim());
 const headers=rows.shift()?.split(',').map(x=>x.trim().replace(/^"|"$/g,''));
 if(!headers||new Set(headers).size!==headers.length||!headers.includes('I')||!headers.includes('V'))throw new Error('波形 CSV 需要 I,V 列，label 列可选；数值单位为 A 和 V');
 if(rows.length>32000)throw new Error('波形最多 32,000 行');
 const voltage=[],current=[];
 rows.forEach((row,j)=>{const values=row.split(',').map(x=>x.trim().replace(/^"|"$/g,''));if(values.length!==headers.length)throw new Error(`第 ${j+2} 行列数不符`);const v=values[headers.indexOf('V')],i=values[headers.indexOf('I')];if(v===''||i==='')throw new Error(`第 ${j+2} 行有空值`);voltage.push(Number(v));current.push(Number(i));});
 return {voltage,current};
}
export function validateTelemetry(input,deviceId='meter-01',now=Date.now()) {
 if(!input||input.device_id!==deviceId||input.energy_basis!=='waveform_integral')throw new Error('YS8000 设备编号或电量来源无效');
 if(typeof input.session_id!=='string'||!/^ys-[a-f0-9-]{8,64}$/.test(input.session_id))throw new Error('需要有效的采集会话编号');
 if(typeof input.timestamp!=='string'||!/(Z|[+-]\d{2}:\d{2})$/.test(input.timestamp)||!Number.isFinite(Date.parse(input.timestamp))||Date.parse(input.timestamp)>now+60000)throw new Error('采集时间无效');
 if(!Array.isArray(input.voltage)||input.voltage.length>512)throw new Error('实时波形最多保存 512 对采样');
 if(input.calibration_confirmed!==true)throw new Error('必须确认标定后才能上传真实波形');
 if(!Number.isFinite(input.acquisition_duration_s)||input.acquisition_duration_s<=0||input.acquisition_duration_s>60)throw new Error('采集窗口须为 0–60 秒');
 const recent=input.recent_power??[];
 if(!Array.isArray(recent)||recent.length>180)throw new Error('每秒功率摘要最多 180 条');
 let previous=-Infinity;for(const row of recent){const t=Date.parse(row.timestamp);if(!Number.isFinite(t)||t<=previous||t>Date.parse(input.timestamp)||t<Date.parse(input.timestamp)-240000||typeof row.power_w!=='number'||!Number.isFinite(row.power_w)||row.power_w<0||row.power_w>1000000)throw new Error('每秒功率摘要无效');previous=t;}
 const metrics=analyzeWaveform(input.voltage,input.current,input.sample_rate_hz,input.line_hz);
 if(metrics.power_w<0)throw new Error('实时波形功率为负，请先核对接线和标定');
 for(const k of ['power_w','energy_kwh'])if(typeof input[k]!=='number'||!Number.isFinite(input[k])||input[k]<0)throw new Error('功率与软件积分电量须为非负数');
 return {...metrics,recent_power:recent.map(r=>({timestamp:new Date(r.timestamp).toISOString(),power_w:r.power_w})),voltage:input.voltage,current:input.current,device_id:deviceId,timestamp:new Date(input.timestamp).toISOString(),session_id:input.session_id,energy_basis:'waveform_integral',energy_kwh:input.energy_kwh,window_power_w:input.power_w,acquisition_duration_s:input.acquisition_duration_s,calibration_confirmed:true};
}
