// Real bundled page and bridge state transitions; no public streams or chat submission.
const {test}=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
test('iOS original-stream buffer wait resumes without resetting eight-second delay or reopening either room',async()=>{
 const {chromium}=require('playwright'),browser=await chromium.launch({headless:true,executablePath:'C:/Program Files/Google/Chrome/Application/chrome.exe'});
 try{
  const page=await browser.newPage({viewport:{width:1024,height:768}}),root=path.resolve(__dirname,'../Fusion/Web'),errors=[];
  page.on('pageerror',e=>errors.push(e.message));
  await page.route('**/*',r=>{const u=new URL(r.request().url()),f=path.join(root,u.pathname);if(u.hostname==='fusion.test'&&f.startsWith(root)&&fs.existsSync(f)&&fs.statSync(f).isFile())return r.fulfill({body:fs.readFileSync(f),contentType:f.endsWith('.js')?'application/javascript':f.endsWith('.html')?'text/html':f.endsWith('.css')?'text/css':'application/octet-stream'});return r.abort();});
  await page.addInitScript(()=>{
   window.calls=[];window.ps={};window.epochs={};window.__medias={};let implementation;
   Object.defineProperty(window,'IOSMedia',{configurable:true,get:()=>implementation,set:Type=>{implementation=class extends Type{constructor(...args){super(...args);__medias[this.source]=this;}};}});window.Native={call(id,op,payload){
    const a=JSON.parse(payload);calls.push({op,a});let result={ok:true};
    if(op==='layout'||op==='videoZoom')return;
    if(op==='status')result={loggedIn:false};
    if(op==='voiceMode')result={ai:false};
    if(op==='resolve')result={room:Number(a.room),platform:'bilibili',title:'本地缓冲状态测试',requestedQuality:0,qualities:[],sources:[{url:'https://x.bilivideo.com/test.m3u8',type:'hls',quality:80}]};
    if(op==='mediaOpen')ps[a.source]={token:a.token,currentTime:20,rate:0,paused:true,readyState:4,loaded:[[0,30]],videoWidth:1280,videoHeight:720};
    if(op==='mediaPlay'&&ps[a.source])Object.assign(ps[a.source],{paused:false,rate:1,waiting:false,readyState:4});
    if(op==='mediaPause'&&ps[a.source])Object.assign(ps[a.source],{paused:true,rate:0,waiting:false});
    if(op==='mediaSeek'&&ps[a.source]){ps[a.source].currentTime=a.time;result.state=structuredClone(ps[a.source]);}
    if(op==='mediaClose')delete ps[a.source];
    if(op==='startChat')epochs[a.source]=a.epoch;
    setTimeout(()=>receiveNative(id,result,null),0);
   }};
   window.snapshot=()=>window.iosMediaState?.(structuredClone(ps));
   setInterval(()=>{for(const p of Object.values(ps))if(!p.paused&&!p.waiting)p.currentTime+=.05;snapshot();},50);
  });
  await page.goto('https://fusion.test/index.html');
  await page.evaluate(()=>{document.getElementById('roomA').value='7777';document.getElementById('roomB').value='84074';document.getElementById('connect').click();});
  await page.waitForFunction(()=>__medias.A?.readyState>=3&&__medias.B?.readyState>=3&&!__medias.A.paused&&!__medias.B.paused);
  await page.locator('#delayA').evaluate(e=>{e.value='8';e.dispatchEvent(new Event('change'));});
  await page.waitForFunction(()=>calls.filter(c=>c.op==='mediaSeek').length===1&&!__medias.A.seeking);
  const identity=await page.evaluate(()=>{window.__firstA=__medias.A;window.__firstB=__medias.B;return calls.filter(c=>['resolve','mediaOpen','startChat','mediaSeek','mediaPlay'].includes(c.op)).map(c=>c.op+':'+(c.a.source||c.a.room));});
  const stalled=await page.evaluate(()=>{Object.assign(ps.A,{rate:0,waiting:true,readyState:2});snapshot();return ps.A.currentTime;});
  await page.waitForFunction(()=>document.getElementById('statusA').textContent.includes('缓冲'));
  await page.evaluate(()=>liveEvent('A',epochs.A,{status:'弹幕 / SC 已连接'}));
  assert.match(await page.locator('#statusA').textContent(),/缓冲/,'message connection status cannot falsely claim media is playing');
  await page.waitForTimeout(450);
  assert.equal(await page.evaluate(()=>__medias.A.currentTime),stalled);
  assert.ok(await page.evaluate(()=>ps.B.currentTime)>20.3,'B keeps playing while A waits');
  await page.evaluate(()=>{Object.assign(ps.A,{rate:1,waiting:false,readyState:4});snapshot();});
  await page.waitForFunction(()=>document.getElementById('statusA').textContent.startsWith('播放中'));
  assert.equal(await page.locator('#delayA').inputValue(),'8');
  assert.equal(await page.evaluate(()=>JSON.parse(localStorage.getItem('fusion-mobile-v1')).delayA),8);
  assert.equal(await page.evaluate(()=>__medias.A===__firstA&&__medias.B===__firstB),true);
  assert.deepEqual(await page.evaluate(()=>calls.filter(c=>['resolve','mediaOpen','startChat','mediaSeek','mediaPlay'].includes(c.op)).map(c=>c.op+':'+(c.a.source||c.a.room))),identity,'buffer recovery must not re-open, seek, reconnect, or issue repeated play commands');
  assert.deepEqual(errors,[]);
 }finally{await browser.close();}
});
