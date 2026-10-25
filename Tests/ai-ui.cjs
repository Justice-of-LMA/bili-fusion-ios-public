// Local Windows/Chrome integration check; excluded from portable *.test.cjs CI.
const {test}=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
test('AI edition UI is explicit, local-only and never applies the old web filter silently',async()=>{
 const {chromium}=require('playwright'),browser=await chromium.launch({headless:true,executablePath:'C:/Program Files/Google/Chrome/Application/chrome.exe'});
 try{
  const page=await browser.newPage({viewport:{width:1024,height:768}}),root=path.resolve(__dirname,'../Fusion/Web'),errors=[];page.on('pageerror',e=>errors.push(e.message));
  await page.route('**/*',route=>{const u=new URL(route.request().url()),f=path.join(root,u.pathname);if(u.hostname==='fusion.test'&&f.startsWith(root)&&fs.existsSync(f)&&fs.statSync(f).isFile())return route.fulfill({status:200,contentType:f.endsWith('.html')?'text/html':f.endsWith('.js')?'application/javascript':f.endsWith('.css')?'text/css':'application/octet-stream',body:fs.readFileSync(f)});return route.abort();});
  await page.addInitScript(()=>{window.calls=[];window.Native={call(id,op,payload){const args=JSON.parse(payload);calls.push({op,args});const result=op==='voiceMode'?{ai:true}:op==='status'?{loggedIn:false}:{};setTimeout(()=>window.receiveNative?.(id,result,null),0);}};});
  await page.goto('https://fusion.test/index.html');
  await page.waitForFunction(()=>document.getElementById('voiceModeLabel').textContent.includes('本机 AI'));
  assert.match(await page.locator('#voiceModeHint').textContent(),/仅处理 A 的 HLS\/TS\/AAC，B 不变/);
  assert.equal(await page.locator('#voiceA').isChecked(),false,'AI must remain opt-in');
  await page.locator('#voiceA').evaluate(el=>{el.checked=true;el.dispatchEvent(new Event('input',{bubbles:true}));});
  await page.waitForFunction(()=>calls.some(c=>c.op==='mediaVoice'&&c.args.strength>0));
  await page.evaluate(()=>window.__fusionVoiceStatus('GTCRN local CPU · 120 frames · RTF 0.20'));
  assert.match(await page.locator('#voiceStatus').textContent(),/GTCRN local CPU/);
  assert.equal(await page.evaluate(()=>calls.some(c=>/reconnect|refresh|send/.test(c.op))),false);
  assert.deepEqual(errors,[]);
 }finally{await browser.close();}
});
