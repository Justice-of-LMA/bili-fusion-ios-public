/* App-scoped resolver selection. Only an explicit recovery click refreshes a stream. */
(()=>{'use strict';
window.FusionNetworkCompat={mount({rpc,active,refresh,settings,stage}){
 let mode='system',busy=false,revision=0;
 const section=document.createElement('section');section.id='networkResolutionSettings';
 section.innerHTML='<h3>网络兼容解析</h3><label>解析方式<select data-network-mode><option value="system">系统默认</option><option value="compatible">兼容解析（阿里公共 DNS）</option></select></label><p class="hint">Wi-Fi 起播提示域名解析失败时可尝试。仅影响本 App 的新连接，使用阿里公共 DNS 加密解析；系统加密 DNS / VPN 优先。切换后请手动刷新需要恢复的一路，可随时改回系统默认。</p><p data-network-state class="hint" role="status"></p>';
 settings.append(section);const select=section.querySelector('[data-network-mode]'),status=section.querySelector('[data-network-state]');
 const recovery=document.createElement('section');recovery.id='networkRecovery';recovery.hidden=true;recovery.setAttribute('aria-label','直播网络恢复');stage.append(recovery);
 const style=document.createElement('style');style.textContent='#networkRecovery{position:absolute;z-index:15;left:max(12px,env(safe-area-inset-left));bottom:80px;max-width:min(440px,calc(100% - 24px));max-height:calc(100% - 100px);overflow-y:auto;overscroll-behavior:contain;background:#14253cf5;color:#e9f5ff;border:1px solid #58c9dc;border-radius:12px;padding:12px;box-shadow:0 4px 22px #0007;pointer-events:auto}#networkRecovery[hidden]{display:none!important}#networkRecovery p{margin:0 0 8px;font-size:13px;overflow-wrap:anywhere}#networkRecovery button{font-size:14px;padding:10px 12px}#networkResolutionSettings select{min-width:0;width:100%}';document.head.append(style);
 const failures=new Map();
 function current(source,entry){return failures.get(source)===entry&&active(source)===entry.channel&&entry.channel?.epoch===entry.epoch&&entry.channel?.media?.token===entry.token;}
 async function setMode(value){revision++;const result=await rpc('networkResolutionSet',{mode:value});mode=result?.mode==='compatible'?'compatible':'system';select.value=mode;status.textContent='已保存：'+(mode==='compatible'?'兼容解析（阿里公共 DNS）':'系统默认')+'。已播放的直播不会自动刷新。';render();}
 select.onchange=async()=>{if(busy){select.value=mode;return;}busy=true;select.disabled=true;const previous=mode;try{await setMode(select.value);}catch(e){select.value=previous;status.textContent='设置未保存：'+e.message;}finally{busy=false;select.disabled=false;render();}};
 async function recover(entries){
   if(busy)return;const selected=entries.filter(([source,entry])=>current(source,entry));if(!selected.length)return;
   busy=true;select.disabled=true;render();try{
     if(mode!=='compatible')await setMode('compatible');
     await Promise.all(selected.map(async([source,entry])=>{
       if(!current(source,entry))return;
       await refresh(source,entry.channel);
     }));
   }catch(e){status.textContent='尚未恢复：'+e.message;for(const [source,entry] of selected)if(current(source,entry))failures.set(source,entry);}
   finally{busy=false;select.disabled=false;render();}
 }
 function render(){recovery.replaceChildren();for(const [source,entry] of failures)if(!current(source,entry))failures.delete(source);
 if(failures.size>1){const all=document.createElement('button');all.type='button';all.dataset.networkRecoverAll='';all.disabled=busy;all.textContent=mode==='compatible'?'使用兼容解析刷新失败直播间':'启用兼容解析并刷新失败直播间';all.onclick=()=>void recover([...failures]);recovery.append(all);}
 for(const [source,entry] of failures){
   const row=document.createElement('div'),detail=document.createElement('p'),button=document.createElement('button');detail.textContent=source+' · '+entry.reason;
   button.type='button';button.dataset.networkRecover=source;button.textContent=source==='起播'?(mode==='compatible'?'使用兼容解析重新开始融合':'启用兼容解析并重新开始融合'):(mode==='compatible'?'使用兼容解析刷新 '+source:'启用兼容解析并刷新 '+source);button.disabled=busy;
   button.onclick=()=>void recover([[source,entry]]);
   row.append(detail,button);recovery.append(row);
 }recovery.hidden=!failures.size;}
 const initialRevision=revision;rpc('networkResolutionGet').then(result=>{if(initialRevision!==revision)return;mode=result?.mode==='compatible'?'compatible':'system';select.value=mode;render();}).catch(()=>{status.textContent='未能读取解析设置，请重新打开设置。';});
 return {offer(source,reason,channel){if(!['A','B','C','起播'].includes(source)||!/[（(]-(?:1003|1006)[）)]/.test(String(reason)))return;failures.set(source,{reason:String(reason),channel,epoch:channel?.epoch,token:channel?.media?.token});render();},clear(source){failures.delete(source);render();}};
}};
})();
