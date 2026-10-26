const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict'),path=require('node:path');
const html=fs.readFileSync(path.join(__dirname,'../../Source/index.html'),'utf8');
const script=html.match(/<script>([\s\S]*?)<\/script>/)[1];new vm.Script(script);
const nodes=new Map(),sent=[],actions=[],messages=[];
let focused='';
class Element{
 constructor(id=''){this.id=id;this.options=[];this._value='';this.disabled=false;this.hidden=false;this.textContent='';}
 get value(){return this._value}set value(x){this._value=x}
 add(o){this.options.push(o);if(this.options.length===1)this.value=o.value}
 replaceChildren(){this.options=[];this.value=''}
 append(){}focus(){focused=this.id}scrollIntoView(){actions.push('show-controls')}
}
function $(id){if(!nodes.has(id))nodes.set(id,new Element(id));return nodes.get(id)}
const context=vm.createContext({$,current:{},document:{createElement:()=>new Element()},Option:function(t,v){this.text=t;this.value=v},window:{webkit:{messageHandlers:{meter:{postMessage:p=>sent.push(p)}}}},toast:m=>messages.push(m),act:a=>actions.push(a),setTimeout:fn=>fn(),Date,JSON,Number});
vm.runInContext(script.slice(script.indexOf("let learningCatalog='';"),script.indexOf('window.receive=receive;')),context);
$('host').value='192.168.1.2';$('port').value='8266';$('learningActualState').value='running';
const appliance={id:'human-labelled-dryer',name:'吹风机'};
function show(p,state={}){context.current={learning:p,...state};context.learningState(p)}
const offline={appliances:[appliance],readinessCode:'disconnected',readinessMessage:'尚未连接插座；请先连接 Wi-Fi。',canCapture:false};
show(offline);
assert.equal($('learningAppliance').value,appliance.id);
assert.equal($('learningStart').disabled,false,'offline capture must respond with an explanation');
context.startLearning();assert.equal(sent.length,0);assert.equal(focused,'learningConnectionReason');assert.match(messages.at(-1),/尚未连接/);
assert.equal($('learningConnect').hidden,false);context.connectForLearning();assert.deepEqual(actions,['start']);assert.equal(sent.length,0,'connect must not send device commands');
show({...offline,readinessCode:'connecting',readinessMessage:'正在连接；上次连接超时。'},{connecting:true});
assert.equal($('learningStart').disabled,false);assert.equal($('learningConnect').hidden,true);context.connectForLearning();assert.equal(actions.length,1);
show({...offline,readinessCode:'waiting',readinessMessage:'TCP 已连接，等待有效波形。'},{connected:true});context.startLearning();assert.equal(sent.length,0);assert.equal($('learningShowControls').hidden,false);
show({...offline,readinessCode:'ready',readinessMessage:'可采集',canCapture:true},{connected:true});context.startLearning();assert.equal(sent.length,1);assert.equal(sent[0].action,'learningStart');assert.equal(sent[0].applianceID,appliance.id);assert.equal(sent[0].state,'running');
show({...offline,capturing:true,elapsed:3,windows:3},{connected:true});assert.equal($('learningStart').disabled,true);context.startLearning();assert.equal(sent.length,1);assert.equal($('learningShowControls').hidden,true);
show({...offline,readinessCode:'stale',readinessMessage:'实时波形已中断。'},{connected:true});context.startLearning();assert.equal(sent.length,1);assert.match(messages.at(-1),/已中断/);
show({...offline,appliances:[]});context.startLearning();assert.equal(focused,'learningName');assert.equal($('learningStart').disabled,false);assert.equal(sent.length,1);
console.log('PASS: capture responds offline, explains connection/wait/stale states, preserves appliance, starts only with live readiness, locks during capture; connect sends no supply commands.');
