const {chromium}=require('playwright'),fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const root=path.resolve(__dirname,'../Fusion/Web');
(async()=>{
 const browser=await chromium.launch({headless:true,executablePath:'C:/Program Files/Google/Chrome/Application/chrome.exe'});
 try{
  const context=await browser.newContext({viewport:{width:1024,height:768},hasTouch:true,isMobile:true,deviceScaleFactor:1});
  const page=await context.newPage(),errors=[];page.on('pageerror',e=>errors.push(e.message));
  await page.route('**/*',route=>{
   const url=new URL(route.request().url()),file=path.join(root,url.pathname);
   if(url.hostname==='fusion.test'&&file.startsWith(root)&&fs.existsSync(file))return route.fulfill({status:200,contentType:file.endsWith('.html')?'text/html':file.endsWith('.css')?'text/css':file.endsWith('.js')?'application/javascript':file.endsWith('.jpg')?'image/jpeg':'text/plain',body:fs.readFileSync(file)});
   return route.abort();
  });
  await page.addInitScript(()=>{
   const players={},epochs={};window.calls=[];
   window.Native={call(id,op,payload){const a=JSON.parse(payload);window.calls.push({op,a});let result={ok:true};
    if(op==='layout')return;
    if(op==='blockingGet')result=window.__blockedRules||{};
    if(op==='blockingSet')result=window.__blockedRules=a.rules;
    if(op==='status')result={loggedIn:true,name:'测试账号',uid:1};
    if(op==='send')result={submitted:true,room:Number(a.room)};
    if(op==='pipStart')setTimeout(()=>window.pipState('active','合成桥接测试：画中画已启动'),10);
    if(op==='pipStop')setTimeout(()=>window.pipState('stopped','已关闭消息画中画'),10);
    if(op==='preview')result={room:Number(a.room),title:'测试直播间 '+a.room,name:'测试主播',live:true};
    if(op==='resolve')result={room:Number(a.room),title:'测试 '+a.room,sources:[{url:'https://x.bilivideo.com/test.m3u8',type:'hls',quality:a.quality||80,qualityLabel:'720P'}],qualities:[{qn:80,label:'720P'},{qn:150,label:'1080P'}],requestedQuality:a.quality};
    if(op==='mediaOpen')players[a.source]={token:a.token,currentTime:20,rate:0,paused:true,readyState:4,ranges:[[0,120]],loaded:[[0,20.3]],videoWidth:1920,videoHeight:1080};
    if(op==='mediaClose')delete players[a.source];
    if(op==='mediaPlay'&&players[a.source])Object.assign(players[a.source],{rate:1,paused:false});
    if(op==='mediaPause'&&players[a.source])Object.assign(players[a.source],{rate:0,paused:true});
    if(op==='mediaSeek'&&players[a.source]){players[a.source].currentTime=a.time;result.state=JSON.parse(JSON.stringify(players[a.source]));}
    if(op==='startChat'){
     epochs[a.source]=a.epoch;
     setTimeout(()=>window.liveEvent(a.source,a.epoch,{status:'弹幕 / SC 已连接',packet:{cmd:'SUPER_CHAT_MESSAGE',data:{id:a.source,uid:123,price:30,time:60,message:'合成 SC，不是真实付费留言',user_info:{uname:'测试观众 '+a.source}}}}),150);
    }
    setTimeout(()=>window.receiveNative(id,JSON.parse(JSON.stringify(result)),null),0);
   }};
   // The real bridge serializes fresh snapshots; sharing mutable objects masks onplaying transitions.
   setInterval(()=>{for(const p of Object.values(players)){if(!p.paused)p.currentTime+=.1;p.loaded=[[0,p.currentTime+.3]];p.ranges=[[0,p.currentTime+90]];}window.iosMediaState?.(structuredClone(players));},100);
   window.emitChat=(source='both',count=1)=>{for(const s of source==='both'?['A','B']:[source])if(epochs[s])for(let i=0;i<count;i++)window.liveEvent(s,epochs[s],{packet:{cmd:'DANMU_MSG',info:[[0,0,0,16777215],'测试弹幕',[123,'测试观众']]}});};
   window.__emitAreaTest=window.emitChat;
   window.__emitBlockingTest=(source,packet)=>{if(epochs[source])window.liveEvent(source,epochs[source],{packet});};
  });
  await page.goto('https://fusion.test/index.html');await page.locator('#connect').click();await page.waitForSelector('.sc');
  assert.equal(await page.locator('.sc').count(),2);await require('./speed-ui-checks.cjs')(page);await page.waitForFunction(()=>/已显示 [1-9]/.test(document.getElementById('chatStatsB').textContent));assert.equal(await page.evaluate(()=>calls.filter(c=>c.op==='mediaSeek').length),0);
  await page.locator('#settingsToggle').click();
  await page.locator('#chatArea').selectOption('50');
  await page.locator('#settingsClose').click();
  // Whole-card drag, excluding the close button; locking preserves close.
  await page.locator('#full').click();
  for(const selector of ['.sc-body','.sc-head strong']){
   const before=await page.locator('#cards').boundingBox(),r=await page.locator(selector).first().boundingBox();
   await page.mouse.move(r.x+20,r.y+8);await page.mouse.down();await page.mouse.move(r.x+80,r.y-22,{steps:8});await page.mouse.up();
   const after=await page.locator('#cards').boundingBox();assert(Math.abs(after.x-before.x-60)<2&&Math.abs(after.y-before.y+30)<2);
  }
  await page.locator('#settingsToggle').click();await page.locator('#scDraggable').uncheck();
  const locked=await page.locator('.sc-body').first().boundingBox();
  assert.equal(await page.evaluate(r=>!!document.elementFromPoint(r.x+10,r.y+10).closest('.sc'),locked),false);
  await page.locator('.sc-head button').first().click();await page.waitForFunction(()=>document.querySelectorAll('.sc').length===1);
  await page.locator('#scDraggable').check();await page.locator('#settingsClose').click();await page.locator('#full').click();
  await page.locator('#dual').click();await page.locator('#full').click();
  await page.locator('#settingsToggle').click();assert.equal(await page.locator('#settings').isVisible(),true);
  await page.locator('#volumeA').fill('35');await page.locator('#volumeA').dispatchEvent('input');await page.waitForTimeout(150);
  assert.equal(await page.evaluate(()=>calls.filter(c=>c.op==='mediaVolume'&&c.a.source==='A').at(-1).a.volume),.35);
  await page.locator('#delayA').fill('3');await page.locator('#delayA').dispatchEvent('change');
  assert.equal(await page.evaluate(()=>calls.filter(c=>c.op==='mediaSeek'&&c.a.source==='A').length),1);
  await page.locator('#settingsClose').click();await page.locator('#target').selectOption('B');await page.locator('#message').fill('合成发送测试');await page.locator('#send').click();
  assert.equal(await page.evaluate(()=>calls.filter(c=>c.op==='send').at(-1).a.room),'7777');
  await page.waitForFunction(()=>!document.getElementById('send').disabled);
  await page.locator('#message').fill('合成双发测试');await page.locator('#sendBoth').click();
  await page.waitForFunction(()=>!document.getElementById('sendBoth').disabled);
  assert.deepEqual(await page.evaluate(()=>calls.filter(c=>c.op==='send').slice(-2).map(c=>c.a.room)),['6','7777']);
  assert.equal(await page.locator('#message').inputValue(),'');
  await page.evaluate(()=>window.emitChat());await page.waitForTimeout(500);
  const boxes=await page.evaluate(()=>{const rect=id=>{const r=document.getElementById(id).getBoundingClientRect();return {x:r.x,y:r.y,w:r.width,h:r.height,r:r.right,b:r.bottom};};return {a:rect('viewA'),b:rect('viewB'),bullets:rect('bullets'),layout:calls.filter(c=>c.op==='layout').at(-1).a};});
  assert.equal(boxes.bullets.x,boxes.a.x);assert.equal(boxes.bullets.y,boxes.a.y);assert.equal(boxes.bullets.w,boxes.a.w);assert.ok(Math.abs(boxes.bullets.h-boxes.a.h*.5)<.06);assert.ok(boxes.b.x>=boxes.a.r);assert.equal(boxes.layout.B.visible,true);
  fs.mkdirSync(path.resolve(__dirname,'../qa'),{recursive:true});await page.screenshot({path:path.resolve(__dirname,'../qa/ipad-web-fullscreen.png')});
  await page.locator('#full').click();await page.locator('#donate').click();assert.equal(await page.locator('#donation').isVisible(),true);await page.locator('#donationClose').click();
  assert.equal(await page.evaluate(()=>calls.filter(c=>c.op==='donate').length),0);
  await page.locator('#donate').click();assert.equal(await page.locator('#donation img:visible').count(),0);
  await page.locator('#donationWechat').click();assert.equal(await page.locator('#donationWechatPanel').isVisible(),true);
  assert.ok(await page.locator('#donationWechatPanel img').evaluate(e=>e.complete&&e.naturalWidth>0));
  const qr=await page.locator('.wechat-qr').evaluate(e=>{
   const r=e.getBoundingClientRect(),img=e.querySelector('img'),s=img.getBoundingClientRect(),scale=img.naturalWidth/s.width;
   return {width:r.width,height:r.height,overflow:getComputedStyle(e).overflow,x:(r.x-s.x)*scale,y:(r.y-s.y)*scale,bottom:(r.bottom-s.y)*scale};
  });
  assert.ok(Math.abs(qr.width-qr.height)<1);assert.equal(qr.overflow,'hidden');
  assert.ok(Math.abs(qr.x-312)<1&&Math.abs(qr.y-396)<1&&Math.abs(qr.bottom-1050)<1,'QR viewport excludes the name below y=1057');
  fs.mkdirSync(path.resolve(__dirname,'../qa'),{recursive:true});
  await page.locator('#donation').screenshot({path:path.resolve(__dirname,'../qa/wechat-qr-only.png')});
  assert.equal(await page.evaluate(()=>calls.filter(c=>c.op==='donate').length),0);
  await page.screenshot({path:path.resolve(__dirname,'../qa/wechat-receipt.png')});
  await page.locator('#donationBack').click();assert.equal(await page.locator('#donation img:visible').count(),0);
  await page.locator('#donationOpen').click();assert.equal(await page.evaluate(()=>calls.filter(c=>c.op==='donate').length),1);
  await page.locator('#settingsToggle').click();await page.locator('#audioOnlyB').check();
  assert.equal(await page.locator('body').evaluate(e=>e.classList.contains('dual')),false);
  assert.equal(await page.evaluate(()=>calls.filter(c=>c.op==='mediaAudioOnly'&&c.a.source==='B').at(-1).a.value),true);
  await page.locator('#settingsClose').click();await page.locator('#dual').click();
  assert.equal(await page.locator('#audioOnlyB').isChecked(),false);
  assert.equal(await page.evaluate(()=>calls.filter(c=>c.op==='mediaOpen').length),2);assert.deepEqual(errors,[]);
  await require('./chat-area-checks.cjs')(page);
  await require('./blocking-ui-checks.cjs')(page);
  // A is not required; opening PiP must resolve the newly entered B and remain opt-in.
  if(await page.evaluate(()=>document.body.classList.contains('full')))await page.evaluate(()=>document.getElementById('full').click());
  await page.locator('#stop').click();
  await page.locator('#roomA').fill(''); await page.locator('#roomB').fill('84074');
  const opensBefore=await page.evaluate(()=>calls.filter(c=>c.op==='mediaOpen').length);
  assert.equal(await page.evaluate(()=>calls.filter(c=>c.op==='pipStart').length),0);
  await page.locator('#pip').click();
  await page.waitForFunction(()=>document.getElementById('pip').textContent==='关闭消息画中画');
  assert.deepEqual(await page.evaluate(n=>calls.filter(c=>c.op==='mediaOpen').slice(n).map(c=>c.a.source),opensBefore),['B']);
  assert.equal(await page.evaluate(()=>calls.filter(c=>c.op==='resolve').at(-1).a.room),'84074');
  assert.equal(await page.locator('#audioOnlyB').isChecked(),true);
  await page.locator('#pip').click(); await page.waitForFunction(()=>document.getElementById('pip').textContent==='二路消息画中画');
  assert.deepEqual(errors,[]);
  console.log('PASS iPad-sized web UI: dual layout, fullscreen controls, B composer, SC layout, independent volume, one-shot delay, donation confirmation. Native AVPlayer not tested here.');
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
