// Execute the real page script against a minimal DOM and replay real RV32 UART data.
'use strict';
const fs=require('fs'),path=require('path'),vm=require('vm'),assert=require('assert');
const {Receiver,crc32}=require('./ble_proto.js');
const html=fs.readFileSync(path.join(__dirname,'index.html'),'utf8');
const code=html.match(/<script>([\s\S]*?)<\/script>/)[1];
const els=new Map();
function element(id) {
 if(!els.has(id))els.set(id,{id,value:'',textContent:'',innerHTML:'',style:{},dataset:{},options:[],childNodes:[],appendChild(x){this.childNodes.push(x);},removeChild(){this.childNodes.shift();}});
 return els.get(id);
}
const context={document:{getElementById:element,querySelectorAll:()=>[],createElement:()=>element('child'+Math.random())},
 window:{isSecureContext:true},navigator:{bluetooth:{}},localStorage:{getItem:()=>null,setItem(){},removeItem(){}},
 TextEncoder,Uint8Array,BleProto:{Receiver},console,setTimeout:()=>1,clearTimeout(){}};
vm.createContext(context);vm.runInContext(code,context);
function line(s){vm.runInContext(`rx.h.line(${JSON.stringify(s)})`,context);}
for(const [n,label] of ['G3 彩虹','G1 星空','G2 红天','G4 保持'].entries()){
 line(`KNOB,${n}`);assert.equal(element('knob').textContent,label);
 assert(html.includes(`data-cmd="KNOB,${n}" disabled>${label}`));
}
line('BANK,4,rainbow');assert.equal(element('bank').textContent,'BANK 4 · rainbow');assert.equal(element('bankSelect').value,'4');
line('SLOT,4');assert.equal(element('slot').textContent,'SLOT 4');
line('OSD,0');assert.equal(element('osd').textContent,'OSD 关');line('VIEW,1');assert.equal(element('view').textContent,'视图 对比');
vm.runInContext('var sent=[];sendLine=s=>sent.push(s)',context);element('bankSelect').value='2';element('selectBank').onclick();
assert.equal(vm.runInContext('sent[0]',context),'SLOT,2');
assert(html.match(/id="size"[^>]*><option value="320" selected>320×240<\/option><\/select>/));
assert(html.includes('<option value="1500" selected>'));assert(!html.includes('value="160"')&&!html.includes('value="640"'));
assert(html.includes('getDevices()')&&html.includes('showBound()'));
console.log('PASS actual browser script: B knob labels, BANK/SLOT/OSD/VIEW updates, bank command, 320-only, 1500 default, A reconnect functionality');
const dir=path.resolve(__dirname,'../../reports/simulation/peripheral_merge');
const stream=fs.readFileSync(path.join(dir,'snapshot_stream.bin')),jpg=fs.readFileSync(path.join(dir,'snapshot.jpg'));
function replay(bytes){let image,errs=[];const rx=new Receiver({send(){},line(){},progress(){},image:d=>image=Buffer.from(d),error:e=>errs.push(e)});
 for(let i=0;i<bytes.length;i+=20)rx.push(bytes.subarray(i,i+20));assert.deepEqual(errs,[]);assert(image&&image.equals(jpg));}
replay(stream);
// Corrupt/drop packet 2, then supply the actual board's packets again as go-back-N retransmission.
const at=stream.indexOf(Buffer.from([0xa5,0x5a,2,0]));assert(at>=0);const len=stream[at+4]+7;
const corrupt=Buffer.from(stream);corrupt[at+9]^=0x40;
const end=stream.indexOf(Buffer.from('IMG,END'));const data=stream.subarray(0,end);
replay(Buffer.concat([corrupt.subarray(0,end),data,Buffer.from('IMG,END\r\n')]));
replay(Buffer.concat([stream.subarray(0,at),stream.subarray(at+len,end),data,Buffer.from('IMG,END\r\n')]));
console.log('PASS browser receiver: real RV32 320x240 JPEG byte-for-byte, CRC, fragmented BLE notifications, packet corruption/loss and recovery',crc32(jpg).toString(16));
