const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict'),path=require('node:path');
const html=fs.readFileSync(path.join(__dirname,'../../Source/index.html'),'utf8');
const script=html.match(/<script>([\s\S]*?)<\/script>/)[1];new vm.Script(script);
const ids=[...html.matchAll(/\bid="([^"]+)"/g)].map(m=>m[1]);assert.equal(ids.length,new Set(ids).size,'duplicate UI ids');
const elements=new Map(),sent=[];
function $(id){assert(ids.includes(id),'missing element '+id);if(!elements.has(id))elements.set(id,{value:'',checked:false,disabled:false,textContent:'',hidden:false});return elements.get(id)}
const context=vm.createContext({$,window:{webkit:{messageHandlers:{meter:{postMessage:p=>sent.push(p)}}}},toast:()=>{},Date});
vm.runInContext(script.slice(script.indexOf('let cloudFormInitialized='),script.indexOf('window.receive=receive;')),context);
context.cloudState({ready:true,enabled:false,deviceID:'meter-01',keyConfigured:false});
assert.equal($('cloudDevice').value,'meter-01');assert.equal($('cloudSave').disabled,false);
$('cloudDevice').value='meter-02';$('cloudKey').value='gml_'+'b'.repeat(64);$('cloudEnabled').checked=true;
context.cloudState({ready:true,enabled:true,deviceID:'meter-01',keyConfigured:true,pending:12,pendingBytes:8000,message:'断网补传',otherDevicePending:3});
assert.equal($('cloudDevice').value,'meter-02','refresh must not overwrite editing');
assert.equal($('cloudKey').value,'gml_'+'b'.repeat(64),'state never overwrites secret input');
assert.match($('cloudOther').textContent,/3 条属于其他设备/);assert.equal($('cloudOther').hidden,false);
context.saveCloud();assert.equal(sent.length,1);assert.equal(sent[0].action,'cloudSave');assert.equal(sent[0].enabled,true);assert.equal(sent[0].device,'meter-02');
assert(!JSON.stringify(sent).includes('deviceCommand'),'sync cannot send relay commands');
assert.match(script,/p.event==='cloudSaved'\)\{\$\('cloudKey'\).value=''/,'successful save clears password');
console.log('PASS: cloud UI syntax, unique ids, settings editing, status and native sync action. No supply commands.');
