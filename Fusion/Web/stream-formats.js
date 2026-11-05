/* Explicit per-lane stream format selection. Never retries or resolves a new URL. */
(()=>{'use strict';
function candidates(room){const seen=new Set();return [...(room?.sources||[]),...(room?.formatSources||[])].filter(s=>['flv','hls'].includes(s.type)&&s.url&&!seen.has(s.url)&&seen.add(s.url));}
function pick(room,preferred,flvDefault=false){const all=candidates(room);return all.find(s=>s.type===preferred)||(flvDefault?(room?.sources||[]).find(s=>s.type==='flv'):null)||room?.sources?.[0]||null;}
function mount({get,change,notice,apple=false}){
 let saved={};try{saved=JSON.parse(localStorage.getItem('fusion-stream-formats-v1')||'{}')||{};}catch{}
 const controls={},actions=document.createElement('div');actions.className='format-recovery';actions.hidden=true;document.getElementById('stage').append(actions);
 for(const source of ['A','B','C']){
  const label=document.createElement('label'),select=document.createElement('select');select.id='streamFormat'+source;select.setAttribute('aria-label',source+' 直播格式');label.append(source+' 直播格式',select);
  document.getElementById('quality'+source+'State').after(label);controls[source]=select;
  select.onchange=()=>set(source,select.value);
 }
 function supported(type){return type!=='flv'||!apple||!!window.mpegts?.isSupported();}
 function selected(source,room,flvDefault){return pick(room,saved[source],flvDefault);}
 function set(source,type){
  const c=get(source);if(c?.closed||c?.qualityBusy)return;
  if(c&&type&&!candidates(c.room).some(s=>s.type===type)){notice(source+' 路平台未提供 '+type.toUpperCase()+' 线路。',true);render();return;}
  if(!supported(type)){notice('当前系统不支持 FLV，请使用 HLS。',true);render();return;}
  saved[source]=type;try{localStorage.setItem('fusion-stream-formats-v1',JSON.stringify(saved));}catch{}
  if(c){change(c);notice(source+' 路正在切换为 '+(type?type.toUpperCase():'默认格式')+'，已保留音量、画质选择、延迟和弹幕连接。');}
  render();
 }
 function render(){
  actions.replaceChildren();
  for(const source of ['A','B','C']){
   const c=get(source),select=controls[source],rows=candidates(c?.room),current=c?.currentSource||selected(source,c?.room,false),preferred=['flv','hls'].includes(saved[source])?saved[source]:'';
   select.replaceChildren(new Option('默认（保持原设置）',''));
   for(const type of ['flv','hls']){const available=!c||rows.some(s=>s.type===type),ok=supported(type);const option=new Option(type.toUpperCase()+(ok?(available?'':'（平台未提供）'):'（此系统不支持）'),type);option.disabled=!available||!ok;select.add(option);}
   select.value=preferred;select.disabled=!!c?.qualityBusy;
   if(c&&(c.mediaFailed||c.lastMediaFailure)&&!c.closed&&!c.qualityBusy&&current){
    const other=current.type==='flv'?'hls':'flv';if(rows.some(s=>s.type===other)&&supported(other)){
     const button=document.createElement('button');button.type='button';button.textContent=source+' 路改用 '+other.toUpperCase();button.onclick=()=>{if(get(source)===c&&(c.mediaFailed||c.lastMediaFailure))set(source,other);};actions.append(button);
    }
   }
  }
  actions.hidden=!actions.childElementCount;
 }
 render();return {selected,render};
}
const api={candidates,pick,mount};if(typeof module==='object')module.exports=api;else window.FusionStreamFormats=api;
})();
