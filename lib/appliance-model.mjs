import {analyzeWaveform} from './waveform.mjs';
export const FEATURE_NAMES=['Vrms','Irms','P','PF','I_DC_ratio','I_skew','I_kurtosis','H2','H3','H5','H7','H9','H11'];
export function waveformFeatures(wave,rate=6400,lineHz=50){
 const size=rate/lineHz*3;
 if(!Number.isInteger(size)||wave.voltage.length<size)throw new Error('识别需要至少 3 个完整周波');
 // Use the same three-cycle window for training and online inference.
 const v=wave.voltage.slice(-size),i=wave.current.slice(-size),m=analyzeWaveform(v,i,rate,lineHz);
 const mean=i.reduce((s,x)=>s+x,0)/i.length,variance=i.reduce((s,x)=>s+(x-mean)**2,0)/i.length;
 const skew=variance>1e-12?i.reduce((s,x)=>s+(x-mean)**3,0)/i.length/variance**1.5:0;
 const kurt=variance>1e-12?i.reduce((s,x)=>s+(x-mean)**4,0)/i.length/variance**2:0;
 return [m.voltage_rms,m.current_rms,m.power_w,m.power_factor??0,m.current_rms>1e-9?m.current_dc/m.current_rms:0,skew,kurt,...[2,3,5,7,9,11].map(h=>(m.harmonics.find(x=>x.order===h)?.rms??0)/Math.max(m.current_rms,1e-9))];
}
const distance=(a,b)=>Math.sqrt(a.reduce((s,x,j)=>s+(x-b[j])**2,0)/a.length);
export function trainKNN(examples,rate=6400,lineHz=50){
 if(!Array.isArray(examples)||examples.length<4||examples.length>200)throw new Error('至少导入 4 个标注片段，最多 200 个');
 const classes=[...new Set(examples.map(e=>e.label))];
 if(classes.length<2||classes.some(c=>typeof c!=='string'||!c.trim()||c.length>60))throw new Error('至少需要两类有名称的电器');
 if(classes.some(c=>examples.filter(e=>e.label===c).length<2))throw new Error('每类至少需要 2 次独立采集片段');
 if(examples.some(e=>!Array.isArray(e.features)||e.features.length!==FEATURE_NAMES.length||e.features.some(v=>!Number.isFinite(v))))throw new Error('特征格式无效');
 const means=FEATURE_NAMES.map((_,j)=>examples.reduce((s,e)=>s+e.features[j],0)/examples.length);
 const scales=means.map((mean,j)=>Math.max(Math.sqrt(examples.reduce((s,e)=>s+(e.features[j]-mean)**2,0)/examples.length),Math.abs(mean)*.01,1e-6));
 const normalized=examples.map(e=>({label:e.label,features:e.features.map((v,j)=>(v-means[j])/scales[j])}));
 const within=normalized.map((e,j)=>Math.min(...normalized.filter((x,k)=>k!==j&&x.label===e.label).map(x=>distance(e.features,x.features)))).sort((a,b)=>a-b);
 const cutoff=Math.max(.5,within[Math.floor(within.length*.9)]*2);
 return {version:1,type:'green-meter-knn',sample_rate_hz:rate,line_hz:lineHz,feature_names:FEATURE_NAMES,means,scales,examples:normalized,cutoff,k:Math.min(3,Math.max(1,examples.length-1)),classes};
}
export function validateModel(m){
 if(!m||m.type!=='green-meter-knn'||m.version!==1||JSON.stringify(m.feature_names)!==JSON.stringify(FEATURE_NAMES))throw new Error('模型须为绿电实验室 KNN JSON 格式');
 if(!Number.isInteger(m.sample_rate_hz/ m.line_hz)||m.sample_rate_hz<400||m.sample_rate_hz>20000||![50,60].includes(m.line_hz))throw new Error('模型采样配置无效');
 for(const a of [m.means,m.scales])if(!Array.isArray(a)||a.length!==FEATURE_NAMES.length||a.some(v=>typeof v!=='number'||!Number.isFinite(v)))throw new Error('模型标准化参数无效');
 if(m.scales.some(v=>v<=0)||!Number.isFinite(m.cutoff)||m.cutoff<=0||!Number.isInteger(m.k)||m.k<1||m.k>9)throw new Error('模型距离或邻居参数无效');
 if(!Array.isArray(m.examples)||m.examples.length<4||m.examples.length>200)throw new Error('模型样本数无效');
 for(const e of m.examples)if(typeof e.label!=='string'||!e.label.trim()||e.label.length>60||!Array.isArray(e.features)||e.features.length!==FEATURE_NAMES.length||e.features.some(v=>typeof v!=='number'||!Number.isFinite(v)||Math.abs(v)>1e9))throw new Error('模型样本无效');
 const labels=[...new Set(m.examples.map(e=>e.label))];if(labels.length<2||labels.some(l=>m.examples.filter(e=>e.label===l).length<2))throw new Error('模型至少需要两类，每类两个片段');
 return {...m,classes:labels};
}
export function classifyKNN(model,features,rate,lineHz=50){
 const m=validateModel(model);if(rate!==m.sample_rate_hz||lineHz!==m.line_hz)throw new Error('当前波形的采样率/电网频率与训练模型不一致');
 if(features.length!==FEATURE_NAMES.length||features.some(x=>!Number.isFinite(x)))throw new Error('识别特征无效');
 const x=features.map((v,j)=>(v-m.means[j])/m.scales[j]);
 const nearest=m.examples.map(e=>({label:e.label,distance:distance(x,e.features)})).sort((a,b)=>a.distance-b.distance);
 const neighbors=nearest.slice(0,m.k),counts=new Map();for(const e of neighbors)counts.set(e.label,(counts.get(e.label)||0)+1);
 const candidates=[...counts].map(([label,votes])=>({label,vote_share:votes/neighbors.length})).sort((a,b)=>b.vote_share-a.vote_share);
 return {unknown:nearest[0].distance>m.cutoff||candidates.length>1&&candidates[0].vote_share===candidates[1].vote_share,candidates,distance:nearest[0].distance,cutoff:m.cutoff};
}
