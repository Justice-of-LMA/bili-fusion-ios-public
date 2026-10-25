const assert=require('node:assert/strict');
module.exports=async function(page){
 if(await page.evaluate(()=>document.body.classList.contains('full')))await page.evaluate(()=>document.getElementById('full').click());
 await page.evaluate(()=>{
  for(const key of ['chatA','chatB','scA','scB'])document.getElementById(key).checked=true;
  for(const key of ['delayA','delayB']){const el=document.getElementById(key);el.value='0';el.dispatchEvent(new Event('change'));}
  const packet={cmd:'DANMU_MSG',info:[[],'屏蔽合成聊天',[445,'屏蔽目标']]};
  window.__emitBlockingTest('B',packet);
  window.__emitBlockingTest('B',{cmd:'SUPER_CHAT_MESSAGE',data:{id:'blocking-sc',uid:445,price:30,time:120,message:'屏蔽合成SC',user_info:{uname:'屏蔽目标'}}});
 });
 await page.waitForFunction(()=>[...document.querySelectorAll('.history-user')].some(n=>n.textContent==='屏蔽目标'));
 await page.locator('.history-user').filter({hasText:'屏蔽目标'}).first().click();
 const dialog=page.locator('.fusion-blocking');
 assert.equal(await dialog.isVisible(),true);
 await dialog.locator('[data-block]').click();
 await page.waitForFunction(()=>window.__blockedRules?.users?.some(u=>u.uid==='445'));
 await page.waitForFunction(()=>![...document.querySelectorAll('.history-row,.bullet,.sc')].some(n=>n.textContent.includes('屏蔽合成')));
 await dialog.locator('[data-keyword]').fill('TEST-广告');
 await dialog.locator('[data-add-word]').click();
 await page.waitForFunction(()=>window.__blockedRules?.keywords?.includes('TEST-广告'));
 await page.evaluate(()=>{
  __emitBlockingTest('B',{cmd:'DANMU_MSG',info:[[],'改名后不该显示',[445,'改名用户']]});
  __emitBlockingTest('A',{cmd:'SUPER_CHAT_MESSAGE',data:{id:'keyword-sc',uid:778,price:30,time:60,message:'test-广告内容',user_info:{uname:'未屏蔽用户'}}});
  __emitBlockingTest('B',{cmd:'DANMU_MSG',info:[[],'允许同名不同ID显示',[446,'屏蔽目标']]});
 });
 await page.waitForFunction(()=>[...document.querySelectorAll('.history-row')].some(n=>n.textContent.includes('允许同名不同ID')));
 assert.equal(await page.locator('.history-row,.bullet,.sc').filter({hasText:'改名后不该显示'}).count(),0);
 assert.equal(await page.locator('.history-row,.bullet,.sc').filter({hasText:'test-广告内容'}).count(),0);
 await dialog.screenshot({path:require('node:path').resolve(__dirname,'../qa/blocking-settings.png')});
 assert.equal(await page.evaluate(()=>handleBack()),true);assert.equal(await dialog.isVisible(),false);
 await page.evaluate(()=>openBlocking());await dialog.locator('[data-users] button').click();
 await page.waitForFunction(()=>window.__blockedRules?.users?.length===0);
 // Mock storage changes before its asynchronous reply. Wait for the real UI commit
 // (render + changed callback), not just the native-side mock variable.
 await page.waitForFunction(()=>document.querySelector('.fusion-blocking [data-users]').textContent==='暂无');
 await page.evaluate(()=>__emitBlockingTest('B',{cmd:'DANMU_MSG',info:[[],'解除后新消息显示',[445,'改名用户']]}));
 await page.waitForFunction(()=>[...document.querySelectorAll('.history-row')].some(n=>n.textContent.includes('解除后新消息')));
 await dialog.locator('[data-words] button').click();
 await page.waitForFunction(()=>window.__blockedRules?.keywords?.length===0);
 await dialog.locator('[data-close]').click();
 console.log('PASS blocking actual app UI: username selection, immediate chat/SC removal, cross-ID safety, literal keyword, unblock and back dismissal');
};

