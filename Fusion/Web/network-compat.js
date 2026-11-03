/* App-scoped resolver selection. Only an explicit recovery click refreshes a stream. */
(()=>{'use strict';
window.FusionNetworkCompat={mount({rpc,active,refresh,settings,stage}){
 let mode='system',busy=false,revision=0;
 const modes={system:'系统默认',compatible:'阿里 DNS',tencent:'腾讯 DNS',google:'Google DNS'},readMode=value=>Object.hasOwn(modes,value)?value:'system';
 const section=document.createElement('section');section.id='networkResolutionSettings';
 section.innerHTML='<h3>网络兼容解析</h3><label>解析方式<select data-network-mode><option value="system">系统默认</option><option value="compatible">阿里 DNS（推荐）</option><option value="tencent">腾讯 DNS</option><option value="google">Google DNS</option></select></label><p class="hint">不用填写地址，选择后会记住。解析服务仅影响本 App 的新连接；系统加密 DNS / VPN 优先。切换后点击“一键修复网络”恢复失败直播间，可随时改回系统默认。Google 在部分网络可能不可达。</p><p data-network-state class="hint" role="status"></p>';
 settings.append(section);const select=section.querySelector('[data-network-mode]'),status=section.querySelector('[data-network-state]');
 const recovery=document.createElement('section');recovery.id='networkRecovery';recovery.hidden=true;recovery.setAttribute('aria-label','直播网络恢复');stage.append(recovery);
 const style=document.createElement('style');style.textContent='#networkRecovery{position:absolute;z-index:15;left:max(12px,env(safe-area-inset-left));bottom:80px;max-width:min(440px,calc(100% - 24px));max-height:calc(100% - 100px);overflow-y:auto;overscroll-behavior:contain;background:#14253cf5;color:#e9f5ff;border:1px solid #58c9dc;border-radius:12px;padding:12px;box-shadow:0 4px 22px #0007;pointer-events:auto}#networkRecovery[hidden]{display:none!important}#networkRecovery p{margin:0 0 8px;font-size:13px;overflow-wrap:anywhere}#networkRecovery button{font-size:14px;padding:10px 12px}#networkResolutionSettings select{min-width:0;width:100%}';document.head.append(style);
 const failures=new Map();
 function current(source,entry){return failures.get(source)===entry&&active(source)===entry.channel&&entry.channel?.epoch===entry.epoch&&entry.channel?.media?.token===entry.token;}
 async function setMode(value){revision++;const result=await rpc('networkResolutionSet',{mode:value});mode=readMode(result?.mode);select.value=mode;status.textContent='已保存：'+modes[mode]+'。已播放的直播不会自动刷新。';render();}
 select.onchange=async()=>{if(busy){select.value=mode;return;}busy=true;select.disabled=true;const previous=mode;try{await setMode(select.value);}catch(e){select.value=previous;status.textContent='设置未保存：'+e.message;}finally{busy=false;select.disabled=false;render();}};
 async function recover(entries){
   if(busy)return;const selected=entries.filter(([source,entry])=>current(source,entry));if(!selected.length)return;
   busy=true;select.disabled=true;render();try{
     if(mode==='system')await setMode('compatible');
     await Promise.all(selected.map(async([source,entry])=>{
       if(!current(source,entry))return;
       await refresh(source,entry.channel);
     }));
   }catch(e){status.textContent='尚未恢复：'+e.message;for(const [source,entry] of selected)if(current(source,entry))failures.set(source,entry);}
   finally{busy=false;select.disabled=false;render();}
 }
 function render(){recovery.replaceChildren();for(const [source,entry] of failures)if(!current(source,entry))failures.delete(source);
 if(failures.size>1){const all=document.createElement('button');all.type='button';all.dataset.networkRecoverAll='';all.disabled=busy;all.textContent='一键修复网络';all.onclick=()=>void recover([...failures]);recovery.append(all);}
 for(const [source,entry] of failures){
   const row=document.createElement('div'),detail=document.createElement('p'),button=document.createElement('button');detail.textContent=source+' · '+entry.reason+' · '+(mode==='system'?'一键修复将使用阿里 DNS':modes[mode]);
   button.type='button';button.dataset.networkRecover=source;button.textContent=source==='起播'?'一键修复网络并开始融合':(failures.size===1?'一键修复网络':'仅修复 '+source);button.disabled=busy;
   button.onclick=()=>void recover([[source,entry]]);
   row.append(detail,button);recovery.append(row);
 }recovery.hidden=!failures.size;}
 const initialRevision=revision;rpc('networkResolutionGet').then(result=>{if(initialRevision!==revision)return;mode=readMode(result?.mode);select.value=mode;render();}).catch(()=>{status.textContent='未能读取解析设置，请重新打开设置。';});
 return {offer(source,reason,channel){if(!['A','B','C','起播'].includes(source)||!/[（(]-(?:1003|1006)[）)]/.test(String(reason)))return;failures.set(source,{reason:String(reason),channel,epoch:channel?.epoch,token:channel?.media?.token});render();},clear(source){failures.delete(source);render();}};
}};
})();
