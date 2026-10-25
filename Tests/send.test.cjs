const {test}=require('node:test'),assert=require('node:assert/strict'),{sendBatch}=require('../Fusion/Web/core.js');
const targets=[{source:'A',room:'6'},{source:'B',room:'7777'}];
test('dual-send keeps a five-second gap and distinct per-room receipts',async()=>{
 const calls=[],r=await sendBatch(targets,async room=>{calls.push(room);return {submitted:true};},{wait:async ms=>calls.push(ms)});
 assert.deepEqual(calls,['6',5100,'7777']);assert.deepEqual(r.map(x=>x.submitted),[true,true]);
});
test('partial failure and unknown reply do not retry',async()=>{
 const calls=[],r=await sendBatch(targets,async room=>{calls.push(room);if(room==='7777')throw Error('平台拒绝');return {submitted:true};},{wait:async()=>{}});
 assert.deepEqual(calls,['6','7777']);assert.equal(r[0].submitted,true);assert.equal(r[1].error,'平台拒绝');
 assert.equal((await sendBatch([targets[0]],async()=>({ok:true})))[0].submitted,false);
});
test('same canonical room is submitted only once',async()=>{
 let count=0;const r=await sendBatch([{source:'A',room:'6'},{source:'B',room:6}],async()=>{count++;return {submitted:true};});
 assert.equal(count,1);assert.deepEqual(r[0].sources,['A','B']);
});
test('stop or change room during the interval cancels the remaining target',async()=>{
 let active=true,count=0;const r=await sendBatch(targets,async()=>{count++;return {submitted:true};},{active:()=>active,wait:async()=>{active=false;}});
 assert.equal(count,1);assert.equal(r[1].submitted,false);assert.match(r[1].error,/已取消/);
});
test('empty/oversized/invalid targets never reach the send callback',async()=>{
 for(const x of [[],[...targets,targets[0]],[{source:'C',room:'6'}],[{source:'A',room:'0'}],[{source:'A',room:'9007199254740992'}]]){
  await assert.rejects(sendBatch(x,async()=>{throw Error('must not run');}),/目标|两个/);
 }
});
