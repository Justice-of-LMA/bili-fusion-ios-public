/* Shared mobile SC settings. Apply is explicit; active messages keep their timer. */
(()=>{'use strict';
const tiers=[['30','¥30–49'],['50','¥50–99'],['100','¥100–499'],['500','¥500–999'],['1000','¥1000–1999'],['2000','¥2000 及以上']];
function mount(root,initial,changed){
 let current=FusionCore.scLifetime(initial);
 root.classList.add('sc-lifetime-editor');root.innerHTML='<h3>SC 停留时长</h3><label>计时方式<select data-sc-mode aria-label="SC 计时方式"><option value="official">官方时长（默认）</option><option value="tiers">按金额分别设置</option><option value="uniform">所有 SC 统一时长</option></select></label><p class="hint" data-sc-official>跟随平台消息提供的时长，不改变官方倒计时。</p><div data-sc-tiers hidden></div><div data-sc-uniform hidden><label>统一秒数<input type="number" min="1" max="7200" step="1" inputmode="numeric" data-sc-seconds aria-label="SC 统一秒数"></label></div><div class="actions"><button type="button" data-sc-apply>应用 SC 时长</button></div><p class="hint" data-sc-result role="status"></p><p class="hint">1–7200 整秒。按金额设置时，留空及 ¥30 以下跟随官方。对新收到的 SC 生效，已收到或显示的 SC 保持当前倒计时。</p>';
 const $=s=>root.querySelector('[data-sc-'+s+']');
 for(const [key,label] of tiers){const row=document.createElement('label');row.textContent=label+'（秒）';const input=document.createElement('input');input.type='number';input.min='1';input.max='7200';input.step='1';input.inputMode='numeric';input.placeholder='官方';input.dataset.scTier=key;input.setAttribute('aria-label',label+' SC 秒数');row.append(input);$('tiers').append(row);}
 function paint(){const mode=$('mode').value;$('tiers').hidden=mode!=='tiers';$('uniform').hidden=mode!=='uniform';$('official').hidden=mode!=='official';$('apply').textContent=mode==='uniform'?'一键应用到所有 SC':'应用 SC 时长';}
 function set(value){current=FusionCore.scLifetime(value);$('mode').value=current.mode;$('seconds').value=current.uniformSeconds;for(const [key] of tiers)root.querySelector('[data-sc-tier="'+key+'"]').value=current.tiers[key]??'';paint();}
 function seconds(input,empty){const raw=input.value.trim();if(empty&&!raw)return null;const value=Number(raw);if(!raw||!Number.isInteger(value)||value<1||value>7200){input.focus();throw Error('请输入 1–7200 的整数秒数');}return value;}
 $('mode').onchange=paint;
 $('apply').onclick=async()=>{try{const next=FusionCore.scLifetime(current);next.mode=$('mode').value;
   if(next.mode==='uniform')next.uniformSeconds=seconds($('seconds'),false);
   if(next.mode==='tiers')for(const [key] of tiers)next.tiers[key]=seconds(root.querySelector('[data-sc-tier="'+key+'"]'),true);
   $('apply').disabled=true;await changed(next);current=next;$('result').textContent='已保存，对新收到的 SC 生效。';
  }catch(e){$('result').textContent=e.message||'设置失败，请重试';}finally{$('apply').disabled=false;}};
 set(current);return {set,get:()=>FusionCore.scLifetime(current)};
}
window.FusionSCLifetimeUI={mount};
})();
