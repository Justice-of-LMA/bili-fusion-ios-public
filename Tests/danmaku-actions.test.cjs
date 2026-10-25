const {test}=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const root=path.resolve(__dirname,'../Fusion/Web');
global.FusionBlocking=require(path.join(root,'blocking.js'));
const {Group}=require(path.join(root,'danmaku-common.js')),C=require(path.join(root,'core.js'));
test('exact groups preserve platform, sender and old room-session identity',()=>{
 const a={source:'A',platform:'bilibili',room:'6',epoch:'one'},b={source:'B',platform:'huya',room:'6',epoch:'two'};
 const group=new Group({text:'完全相同',uid:'1',user:'甲'},a);
 assert.equal(group.add({text:'完全相同',uid:'2',user:'乙'},b),true);group.add({text:'完全相同',uid:'1',user:'甲'},a);
 assert.equal(group.count,3);assert.equal(group.members.length,2);assert.equal(group.members[1].context.platform,'huya');
 assert.equal(group.add({text:'完全相同 ',uid:'1'},a),false);assert.equal(group.add({text:'完全相同!',uid:'1'},a),false);
 group.filter((m,c)=>c.platform!=='bilibili');assert.equal(group.count,1);assert.equal(group.members[0].message.user,'乙');assert.equal(a.epoch,'one');
});
test('group bounds never grow through many unique senders',()=>{const g=new Group({text:'a',uid:'1'});for(let i=2;i<1000;i++)g.add({text:'a',uid:String(i)});assert.equal(g.members.length,60);});
test('non-overlap mode rejects occupied rows; permissive mode is explicitly opt-in',()=>{const l=new C.Lanes();l.reset(1);assert.ok(l.enter(300,1000,0,true));assert.equal(l.enter(100,1000,.01,true),null);assert.ok(l.enter(100,1000,.01,false));});
test('voice worklet actually reduces stereo centre, bypasses off and preserves mono',()=>{
 const file=path.join(root,'voice-worklet.js');if(!fs.existsSync(file))return;
 let Processor;const ctx={sampleRate:48000,AudioWorkletProcessor:class{},registerProcessor:(n,p)=>{Processor=p;},Math};vm.runInNewContext(fs.readFileSync(file,'utf8'),ctx);
 const process=(strength,mono=false,side=false)=>{const p=new Processor();let input=0,output=0;for(let block=0;block<300;block++){const l=new Float32Array(128),r=new Float32Array(128);for(let i=0;i<128;i++){l[i]=.2*Math.sin(2*Math.PI*1000*(block*128+i)/48000);r[i]=side?-l[i]:l[i];}const out=[new Float32Array(128),new Float32Array(128)];p.process([mono?[l]:[l,r]],[out],{strength:new Float32Array([strength])});for(let i=0;i<128;i++){if(block>30){input+=l[i]*l[i];output+=out[0][i]*out[0][i];}if(strength===0||mono||side)assert.equal(out[0][i],l[i]);}}return output/input;};
 assert.ok(process(1)<.05);process(0);process(1,true);process(1,false,true);
});
test('scroll speed defaults to 1x, clamps safely and preserves already visible positions',()=>{
 const l=new C.Lanes(),b={age:2,width:200,duration:15};assert.equal(l.speed,95);
 for(const multiplier of [.5,2,1]){const x=l.speed*b.age;l.setSpeed(multiplier,[b],1000);assert.ok(Math.abs(l.speed*b.age-x)<1e-9);assert.equal(l.speed,95*multiplier);assert.equal(b.duration,1204/l.speed);}
 l.setSpeed(NaN);assert.equal(l.speed,95);l.setSpeed(99);assert.equal(l.speed,190);l.setSpeed(-4);assert.equal(l.speed,47.5);
});
test('non-overlap launch gaps scale with scrolling speed',()=>{
 for(const multiplier of [.5,1,2]){const l=new C.Lanes(1);l.setSpeed(multiplier);assert.ok(l.enter(200,1000,0));const gap=232/(95*multiplier);assert.equal(l.enter(200,1000,gap-.001),null);assert.ok(l.enter(200,1000,gap+.001));}
});

