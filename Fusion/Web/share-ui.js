/* Explicit local configuration import/export and user-triggered, paced sharing. */
(()=>{'use strict';
window.FusionShareUI={mount(h){
 const d=document,dialog=d.createElement('dialog');dialog.id='shareDialog';dialog.className='fusion-share-dialog';
 dialog.innerHTML='<div class="share-title"><strong>延迟分享</strong><button type="button" data-action="close" aria-label="关闭分享">×</button></div><p class="hint">包含 A/B/C 平台、房间和相对偏移；账号不进入分享码。</p><div class="share-tabs"><button type="button" data-tab="export">分享当前配置</button><button type="button" data-tab="import">粘贴配置</button></div><div data-panel="export"><div class="share-summary"></div><textarea id="shareExportCode" readonly aria-label="当前延迟分享码"></textarea><div class="share-actions"><button type="button" data-action="copy">复制完整码</button></div><p class="hint">一键分享到弹幕（可选多路，长码自动分段）</p><div class="share-targets"></div><div class="share-actions"><button type="button" data-action="send" class="primary">一键分享到所选直播间</button><button type="button" data-action="cancel" hidden>停止后续发送</button></div><p class="hint">按实际文字长度分段，表情标签也计入；每条至少间隔5秒。提交失败或结果未知会停止。</p></div><div data-panel="import" hidden><textarea id="shareImportCode" placeholder="粘贴完整码、仅码体，或全部分段" aria-label="粘贴延迟分享码"></textarea><div class="share-actions"><button type="button" data-action="paste">从剪贴板粘贴</button><button type="button" data-action="preview">预览配置</button></div><div class="share-import-summary"></div><button type="button" data-action="apply" class="primary" disabled>应用并开始融合</button></div><p class="share-status" role="status"></p>';
 d.body.append(dialog);const $=s=>dialog.querySelector(s),status=$('.share-status'),collector=h.collector;let current='',imported=null,ticket=0,running=false,toastTimer;const toast=d.createElement('div');toast.className='share-progress-toast';toast.hidden=true;const toastText=d.createElement('span'),toastStop=d.createElement('button');toastStop.textContent='停止';toastStop.onclick=()=>{ticket++;message('已停止后续发送；正在提交的一条仍需等待平台结果。');};toast.append(toastText,toastStop);d.body.append(toast);
 const names={bilibili:'B站',huya:'虎牙',douyu:'斗鱼',douyin:'抖音'};
 function message(s,error=false){status.textContent=s;status.classList.toggle('error',error);toastText.textContent=s;if(running)toast.hidden=false;}
 function summary(el,rooms){el.replaceChildren();const actual=FusionShare.actuals(rooms);rooms.forEach((r,i)=>{const p=d.createElement('div');p.className='share-room';const tag=d.createElement('b');tag.textContent='ABC'[i];const text=d.createElement('span');text.textContent=(r.enabled?names[r.platform]+' '+r.room:'未启用'+(r.room?' · '+r.room:''))+' · 偏移 '+(r.offset>0?'+':'')+r.offset.toFixed(1)+'s'+(r.enabled?' · 实际延迟 '+actual[i].toFixed(1)+'s':'');p.append(tag,text);el.append(p);});}
 function tab(name){dialog.querySelectorAll('[data-panel]').forEach(e=>e.hidden=e.dataset.panel!==name);dialog.querySelectorAll('[data-tab]').forEach(e=>e.classList.toggle('selected',e.dataset.tab===name));message('');}
 function close(){dialog.close();}
 function preview(){imported=null;$('[data-action=apply]').disabled=true;try{imported=FusionShare.decode($('#shareImportCode').value);summary($('.share-import-summary'),imported);$('[data-action=apply]').disabled=false;message('请核对房间与延迟后应用。');}catch(e){$('.share-import-summary').replaceChildren();message(e.message,true);}}
 function open(initial=''){if(running){if(!dialog.open)dialog.showModal();return;}ticket++;imported=null;tab(initial?'import':'export');$('[data-action=apply]').disabled=true;$('#shareImportCode').value=initial;$('.share-import-summary').replaceChildren();try{const rooms=h.read();current=FusionShare.encode(rooms);$('#shareExportCode').value=current;summary($('.share-summary'),rooms);}catch(e){current='';$('#shareExportCode').value='';$('.share-summary').replaceChildren();message(e.message,true);}
  const targets=$('.share-targets');targets.replaceChildren();for(const source of ['A','B','C']){const context=h.context(source),label=d.createElement('label'),input=d.createElement('input');input.type='checkbox';input.value=source;input.disabled=!context;input.checked=source==='B'&&!!context;const text=d.createElement('span');text.textContent=source+' · '+(context?names[context.platform]+' '+context.room:'尚未连接');label.append(input,text);targets.append(label);}if(!targets.querySelector('input:checked')){const first=targets.querySelector('input:not(:disabled)');if(first)first.checked=true;}
  if(!dialog.open)dialog.showModal();if(initial)preview();
 }
 $('[data-action=close]').onclick=close;dialog.addEventListener('cancel',e=>{e.preventDefault();close();});
 dialog.querySelectorAll('[data-tab]').forEach(e=>e.onclick=()=>tab(e.dataset.tab));
 $('[data-action=copy]').onclick=async()=>{try{if(!current)throw Error('请先填写有效房间');await h.rpc('clipboardWrite',{text:current});message('已复制完整分享码。');}catch(e){message(e.message,true);}};
 $('[data-action=paste]').onclick=async()=>{try{const r=await h.rpc('clipboardRead');$('#shareImportCode').value=typeof r==='string'?r:r.text||'';preview();}catch(e){message(e.message,true);}};
 $('[data-action=preview]').onclick=preview;$('#shareImportCode').oninput=()=>{imported=null;$('[data-action=apply]').disabled=true;};
 $('[data-action=apply]').onclick=async()=>{try{if(!imported)throw Error('请先预览配置');await h.apply(imported,true);close();}catch(e){message(e.message,true);}};
 $('[data-action=cancel]').onclick=()=>{ticket++;message('已停止后续发送；正在提交的一条仍需等待平台结果。');};
 $('[data-action=send]').onclick=async()=>{
  if(h.busy()){message('已有弹幕正在提交，请稍候',true);return;}
  const targets=[...dialog.querySelectorAll('.share-targets input:checked')].map(e=>h.context(e.value));
  if(!targets.length||targets.some(c=>!c)){message('请先选择已连接的直播间',true);return;}
  if(targets.some(c=>!h.canSend(c))){message('请先登录对应平台，并保持当前直播间',true);return;}
  const serial=++ticket,uid=h.uid(),visibility=h.visibility?.();running=true;clearTimeout(toastTimer);toastStop.hidden=false;h.setBusy(true);$('[data-action=send]').disabled=true;$('[data-action=cancel]').hidden=false;
  try{const code=current,active=()=>ticket===serial&&h.foreground()&&h.uid()===uid&&h.visibility?.()===visibility&&targets.every(c=>h.canSend(c));const result=await FusionShare.deliver(code,targets,{
    active,limit:async c=>c.platform==='bilibili'?(await h.rpc('messageLimit',{room:c.room,platform:c.platform})).length:40,
    send:(c,text)=>h.rpc('send',{room:c.room,platform:c.platform,text,uid}),progress:p=>message('已确认 '+p.submitted+'/'+p.total+' 条 · '+p.item.target.source+' 第'+p.item.index+'/'+p.item.total+'段'+(p.submitted<p.total?'，请稍候':''))
   });message('已确认提交 '+result.submitted+'/'+result.total+' 条。实际广播以直播间为准。');
  }catch(e){message(e.message+'；后续已停止，没有自动重发。',true);}
  finally{running=false;h.setBusy(false);toastStop.hidden=true;toastTimer=setTimeout(()=>toast.hidden=true,8000);$('[data-action=send]').disabled=false;$('[data-action=cancel]').hidden=true;}
 };
 $('textarea').spellcheck=false;d.getElementById('shareConfig').onclick=()=>open();d.getElementById('shareFromPlayer').onclick=()=>open();
 return {open,isRunning:()=>running,close:()=>dialog.open?(close(),true):false,collector};
}};
})();

