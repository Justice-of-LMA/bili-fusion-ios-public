(()=>{
'use strict';
const $=id=>document.getElementById(id),C=FusionCore,waiters=new Map();let sequence=0,generation=0,channels={},manualPaused=false,foreground=true,account={loggedIn:false},full=false;
const qualityChoices={A:0,B:0},preferredDelays={A:0,B:0};let preferredDual=false,inVideoPiP=false;
let pipEnabled=false,pipBusy=false,aiVoiceMode=false,voiceFailure="";
let hideTimer,frame=0,lastPump=0,historyCount=0,lastChatStats=0;
const stage=$('stage'),bulletLayer=$('bullets'),cardLayer=$('cards'),lanes=new C.Lanes();
let flying=[],bulletLayout={tops:[]};const scNodes=new Map();
function notice(message,error=false){$('notice').textContent=message;$('notice').classList.toggle('error',error);}
function rpc(op,args={}){
  return new Promise((resolve,reject)=>{
    const id=String(++sequence),timer=setTimeout(()=>{waiters.delete(id);reject(Error(op==='send'?'发送结果未知，没有自动重发':'请求超时，请稍后重试'));},35000);
    waiters.set(id,{resolve,reject,timer});
    if(!window.Native){clearTimeout(timer);waiters.delete(id);reject(Error('当前为网页预览；请在二路随行 iOS App 中使用直播功能'));return;}
    Native.call(id,op,JSON.stringify(args));
  });
}
window.receiveNative=(id,result,error)=>{const item=waiters.get(id);if(!item)return;waiters.delete(id);clearTimeout(item.timer);error?item.reject(Error(error)):item.resolve(result);};
let blockedRules=FusionBlocking.normalize();
function blocked(event,source){return FusionBlocking.matches(blockedRules,event,channels[source]?.room?.platform||'bilibili');}
function applyBlocked(value){
 blockedRules=FusionBlocking.normalize(value);
 for(const [source,c] of Object.entries(channels)){
  c.pending=c.pending.filter(m=>!blocked(m,source));c.timeline.items=c.timeline.items.filter(m=>!blocked(m,source));
  for(const [id,m]of c.timeline.sc)if(blocked(m,source))c.timeline.sc.delete(id);
 }
 for(const row of $('history').querySelectorAll('.history-row'))if(row.__message&&blocked(row.__message,row.dataset.source))row.remove();
 historyCount=$('history').querySelectorAll('.history-row').length;
 for(const b of flying)if(!refreshBulletGroup(b))b.el.remove();
 flying=flying.filter(b=>b.el.isConnected);renderCards();
}
const blockPanel=FusionBlockingUI.mount({read:()=>rpc('blockingGet'),write:rules=>rpc('blockingSet',{rules}),changed:applyBlocked});
const messageMenu=FusionDanmaku.menu({blockUser:(m,p)=>blockPanel.blockUser(m,p),blockText:text=>blockPanel.blockText(text),
 active:c=>foreground&&c.generation===generation&&channels[c.source]?.epoch===c.epoch&&String(channels[c.source]?.room?.room)===c.room&&(channels[c.source]?.room?.platform||'bilibili')===c.platform,
 send:async(text,c)=>{if(c.platform==='bilibili'&&!account.loggedIn)throw Error('请先登录 B站');const reply=await rpc('send',{room:c.room,platform:c.platform,text,uid:account.uid});if(reply?.submitted!==true)throw Error('未收到明确提交确认，没有重发');return '已提交到 '+c.source+'；平台确认不保证所有观众可见。';}});
function messageContext(source){const c=channels[source];return {source,platform:c?.room?.platform||'bilibili',room:String(c?.room?.room||''),epoch:c?.epoch,generation};}
function refreshBulletGroup(b){const old=b.group.members[0]?.key;if(!b.group.filter((m,c)=>!blocked(m,c.source)))return false;if(old!==b.group.members[0]?.key)b.el.querySelector(".username")?.remove();b.source=b.group.members[0].context.source;if(b.badge)FusionDanmaku.badge(b.badge,b.group);return true;}
async function setupVoiceMode(){try{const mode=await rpc('voiceMode');aiVoiceMode=mode?.ai===true;if(!aiVoiceMode)return;document.querySelector('h1 small').textContent='AI 去人声 0.3.2';$('voiceModeLabel').textContent='A 模型去人声（本机 AI）';$('voiceModeHint').textContent='GTCRN 轻量语音模型：从原声中减去模型估计的人声。仅处理 A 的 HLS/TS/AAC，B 不变；FLV / 分片 MP4 不处理，需要手动选可用的 TS 线路。会损伤部分游戏声音；处理后续片段，不上传音频、不自动刷新。';$('voiceStatus').textContent='AI 默认关闭。开启后加载本地模型；可先用 100% 强度试听，真机耗电和效果因设备、音源而异。';}catch{/* Ordinary/mock/native older versions retain the existing filter UI. */}}
async function applyVoice(){voiceFailure='';const strength=$('voiceA').checked?Number($('voiceStrength').value)/100:0;$('voiceStrengthValue').textContent=$('voiceStrength').value+'%';try{const c=channels.A;if(c?.media.webMode){if(aiVoiceMode){c.voice?.close?.();$('voiceStatus').textContent='此 FLV 线路未经过 AI 模型，保留原声音；请手动选择 HLS/TS，不会自动换线。';return;}c.voice||=new FusionVoiceReducer(c.media.element);c.voice.setChannels(c.media.channels);await c.voice.set($('voiceA').checked,strength);$('voiceStatus').textContent=c.voice.detail()+'；不是 AI 分离，居中游戏音效也可能减弱。';}else await rpc('mediaVoice',{strength});}catch(e){voiceFailure='当前未处理，保持原声音：'+e.message;$('voiceStatus').textContent=voiceFailure;notice(e.message,true);}}
window.__fusionVoiceStatus=value=>{if(voiceFailure){$('voiceStatus').textContent=voiceFailure;return;}if(channels.A?.media.webMode)return;if(!$('voiceA').checked){$('voiceStatus').textContent='已关闭，保留 A 原声音';return;}if($('voiceA').checked)$('voiceStatus').textContent=value+(aiVoiceMode?'。仅本机处理 A 的后续 TS/AAC 片段（单声道/立体声），不改 B；未支持格式保留原声。':'。只处理后续未缓存的 TS/AAC 片段，单声道和不支持的格式保留原声音。');};
const blockButton=document.createElement('button');blockButton.id='blockingSettings';blockButton.textContent='用户 / 关键词屏蔽';blockButton.onclick=()=>blockPanel.open();
$('settings').append(blockButton);
window.openBlocking=()=>blockPanel.open();
const ids=['backgroundMode','screenOrientation','voiceA','voiceStrength','volumeA','volumeB','size','chatSpeed','opacity','font','color','marker','chatA','chatB','scA','scB','user','original','chatArea','maxRows','audioOnlyB','nonOverlap','mergeSame','scDraggable','pipRows','pipSize','pipUser','platformA','platformB'];
function save(){
  const config={roomA:$('roomA').value,roomB:$('roomB').value};
  for(const id of ids)config[id]=$(id).type==='checkbox'?$(id).checked:$(id).value;
  config.qualityA=qualityChoices.A;config.qualityB=qualityChoices.B;config.delayA=preferredDelays.A;config.delayB=preferredDelays.B;config.dual=document.body.classList.contains('dual');
  try{localStorage.setItem('fusion-mobile-v1',JSON.stringify(config));}catch{}
}
try{
  const conf=JSON.parse(localStorage.getItem('fusion-mobile-v1')||'{}');
  preferredDual=conf.dual===true;
  for(const source of ['A','B']){preferredDelays[source]=C.clamp(Number(conf['delay'+source])||0,0,20);$('delay'+source).value=preferredDelays[source];$('delay'+source+'Value').textContent=preferredDelays[source].toFixed(1)+'s';}
  for(const s of ['A','B'])qualityChoices[s]=Number.isInteger(conf['quality'+s])&&conf['quality'+s]>=0&&conf['quality'+s]<=100000?conf['quality'+s]:0;
  for(const id of [...ids,'roomA','roomB'])if(Object.hasOwn(conf,id)){
    const e=$(id);if(e.type==='checkbox')e.checked=!!conf[id];else e.value=conf[id];
  }
}catch{}
if(!['audio','pause'].includes($('backgroundMode').value))$('backgroundMode').value='audio';
if(!['auto','portrait','landscape'].includes($('screenOrientation').value))$('screenOrientation').value='auto';
const scLayout=SCLayout.mount(cardLayer,$('viewA'),{load:()=>JSON.parse(localStorage.getItem('fusion-ios-sc-position')||'null'),save:p=>localStorage.setItem('fusion-ios-sc-position',JSON.stringify(p)),bottom:()=>Math.min(64,$('viewA').clientHeight*.13)});
scLayout.setDraggable($('scDraggable').checked);
$('scCorner').onchange=()=>scLayout.corner($('scCorner').value);
function updateLabels(){
  for(const s of ['A','B'])$('volume'+s+'Value').textContent=$('volume'+s).value+'%';
  $('chatSpeedValue').textContent=Number($('chatSpeed').value).toFixed(1)+' 倍';lanes.setSpeed($('chatSpeed').value,flying,bulletLayer.clientWidth);
  $('sizeValue').textContent=$('size').value+'px';$('opacityValue').textContent=$('opacity').value+'%';
  $('maxRowsValue').textContent=$('maxRows').value+' 行';
}
async function status(){
  try{account=await rpc('status');$('login').textContent='账号 / 登录';}
  catch{account={loggedIn:false};$('login').textContent='账号 / 登录';}
}
const previews={A:{},B:{}},following={source:'A',page:0,revision:0,busy:false,seen:new Set()};
function roomCard(source,data){
  const el=$('preview'+source);el.replaceChildren();
  const url=C.roomImageUrl(data.cover||data.face);
  if(url){const img=document.createElement('img');img.src=url;img.alt='房间封面';img.referrerPolicy='no-referrer';img.onerror=()=>img.remove();el.append(img);}
  const title=document.createElement('strong');title.textContent=data.title||'未设置直播标题';
  const name=document.createElement('span');name.textContent=data.name||('房间 '+data.room);
  const state=document.createElement('span');state.className=data.live?'is-live':'';state.textContent=(data.live?'正在直播':'未开播 / 轮播')+' · '+data.room;
  el.append(title,name,state);
}
async function preview(source){
  const state=previews[source],input=$('room'+source).value.trim(),el=$('preview'+source);
  if(state.busy)return;
  if(!input){el.textContent='输入后显示房间信息';state.last='';return;}
  if(state.last===input&&state.data){roomCard(source,state.data);return;}
  state.busy=true;el.textContent='正在读取房间信息…';
  try{
    const data=await rpc('preview',{room:input,platform:$('platform'+source).value});
    if($('room'+source).value.trim()===input){state.data=data;state.last=input;roomCard(source,data);}
  }catch(e){if($('room'+source).value.trim()===input){el.textContent='预览失败：'+e.message;state.data=null;}}
  finally{state.busy=false;if($('room'+source).value.trim()!==input)void preview(source);}
}
async function loadFollowing(reset=false){
  if(following.busy&&!reset)return;
  if(reset){following.revision++;following.page=0;following.seen.clear();$('followingList').replaceChildren();}
  const revision=following.revision,page=following.page+1;
  following.busy=true;$('followingMore').hidden=true;$('followingState').textContent='正在读取关注列表…';
  try{
    const data=await rpc('following',{page});
    if(revision!==following.revision||!$('following').open)return;
    for(const item of data.items||[]){
      if(!item.live||!Number.isSafeInteger(item.room)||item.room<=0||following.seen.has(item.room))continue;
      following.seen.add(item.room);
      const button=document.createElement('button'),text=document.createElement('span'),name=document.createElement('strong'),title=document.createElement('small');
      text.className='follow-text';name.textContent=item.name||('房间 '+item.room);title.textContent=(item.title||'未设置标题')+' · '+item.room;
      const url=C.imageUrl(item.cover||item.face);if(url){const img=document.createElement('img');img.src=url;img.alt='';img.referrerPolicy='no-referrer';img.onerror=()=>img.remove();button.append(img);}
      text.append(name,title);button.append(text);button.onclick=()=>{
        const source=following.source;$('room'+source).value=String(item.room);roomCard(source,item);save();closeFollowing();void preview(source);
      };$('followingList').append(button);
    }
    following.page=page;$('followingMore').hidden=!data.hasMore;
    $('followingState').textContent=following.seen.size?'已显示 '+following.seen.size+' 位正在直播的关注主播，点选填入 '+following.source+'。':data.hasMore?'本页没有正在直播的关注，可继续加载下一页。':'当前列表中没有正在直播的关注主播；仍可手动输入房间号。';
  }catch(e){if(revision===following.revision&&$('following').open){$('followingState').textContent=e.message+'。可登录后刷新，或关闭后手动输入。';$('followingMore').hidden=page===1;}}
  finally{if(revision===following.revision)following.busy=false;}
}
function closeFollowing(){following.revision++;following.busy=false;following.seen.clear();$('followingList').replaceChildren();$('following').close();}
for(const source of ['A','B']){
  $('room'+source).addEventListener('input',()=>{save();clearTimeout(previews[source].timer);previews[source].timer=setTimeout(()=>preview(source),800);});
  $('room'+source).addEventListener('blur',()=>{clearTimeout(previews[source].timer);void preview(source);});
  $('follow'+source).onclick=()=>{const platform=$('platform'+source).value;if(platform!=='bilibili'){void rpc('platformFollowing',{platform,source}).catch(e=>notice(e.message,true));return;}following.source=source;$('followingTitle').textContent='选择 '+source+' · 正在直播的关注';$('following').showModal();void loadFollowing(true);};
}
$('followingClose').onclick=closeFollowing;
$('following').addEventListener('cancel',e=>{e.preventDefault();closeFollowing();});
$('followingRefresh').onclick=()=>{if(!following.busy)void loadFollowing(true);};
$('followingMore').onclick=()=>void loadFollowing();
$('followingLogin').onclick=()=>rpc('login').catch(e=>{$('followingState').textContent=e.message;});
function donationMethods(){
  $('donationTitle').textContent='制作不易TvT，是否打赏作者？';$('donationMethods').hidden=false;
  $('donationWechatPanel').hidden=true;$('donationBack').hidden=true;$('donationClose').textContent='暂不';
  $('donationState').hidden=true;$('donationQr').hidden=true;$('donationQr').open=false;
}
$('donate').onclick=()=>{donationMethods();$('donation').showModal();};
$('donationBack').onclick=donationMethods;
$('donationWechat').onclick=()=>{
  $('donationMethods').hidden=true;$('donationTitle').textContent='微信打赏';
  $('donationWechatPanel').hidden=false;$('donationBack').hidden=false;$('donationClose').textContent='关闭';
  $('donationQr').hidden=true;$('donationState').hidden=true;
};
$('donationClose').onclick=()=>{$('donation').close();};
$('donationOpen').onclick=async()=>{
  $('donationOpen').disabled=true;
  try{await rpc('donate');$('donation').close();}
  catch(e){$('donationState').hidden=false;$('donationState').textContent=e.message;$('donationQr').hidden=false;}
  finally{$('donationOpen').disabled=false;}
};
window.handleBack=()=>{
  if(messageMenu.close())return true;
  if(blockPanel.close())return true;
  if($('donation').open){if(!$('donationWechatPanel').hidden)donationMethods();else $('donation').close();return true;}
  if($('following').open){closeFollowing();return true;}
  if(!$('legal').hidden){$('legal').hidden=true;return true;}
  if(!$('settings').hidden){$('settings').hidden=true;wake();return true;}
  return false;
};
function clearBullets(){
  messageMenu.close();for(const b of flying)b.el.remove();flying=[];
  const area=C.clamp($('chatArea').value,25,100);
  // Always derive the percentage from A's full viewport, never the already-clipped layer.
  bulletLayout=C.laneLayout($('viewA').getBoundingClientRect().height,Number($('size').value),area,Number($('maxRows').value));
  bulletLayer.style.height=area+'%';lanes.reset(bulletLayout.count);
}
function clearSourceBullets(source){for(const b of flying){b.group.filter((m,c)=>c.source!==source);if(!b.group.members.length)b.el.remove();else refreshBulletGroup(b);}flying=flying.filter(b=>b.el.isConnected);messageMenu.close();}
function appendContent(parent,event){
  const parts=C.cleanSegments(event.segments?.length?event.segments:[{type:'text',value:event.text}]);
  for(const item of parts){
    if(item.type==='text'){parent.append(document.createTextNode(item.value));continue;}
    const image=document.createElement('img');image.className='emote';image.src=item.url;image.alt=item.alt;image.referrerPolicy='no-referrer';image.decoding='async';image.draggable=false;
    image.style.width=(1.55*item.ratio)+'em';
    image.onerror=()=>{const fallback=document.createElement('span');fallback.className='fallback';fallback.textContent=item.alt;fallback.style.width=(1.55*item.ratio)+'em';image.replaceWith(fallback);};
    parent.append(image);
  }
}
function addHistory(event,source){
  if(blocked(event,source))return;
  if(historyCount===0)$('history').replaceChildren();
  const row=document.createElement('div');row.className='history-row';row.dataset.source=source;
  const tag=document.createElement('span');tag.className='source';tag.textContent=source+(event.type==='sc'?' · ¥'+event.price:'');
  row.__message=event;const name=document.createElement('button');name.className='history-user';name.textContent=event.user||'用户';name.onclick=()=>blockPanel.open(event,channels[source]?.room?.platform||'bilibili');
  const historyGroup=new FusionDanmaku.Group(event,messageContext(source));row.onclick=e=>{if(!e.target.closest('button'))messageMenu.open(historyGroup,e);};
  row.append(tag,name);appendContent(row,event);$('history').append(row);historyCount++;
  while(historyCount>160){$('history').firstChild.remove();historyCount--;}
  $('history').scrollTop=$('history').scrollHeight;
}
function addBullet(event,source,now){
  if(blocked(event,source))return;
  if(!$('chat'+source).checked)return;
  const context=messageContext(source);
  if($('mergeSame').checked){const existing=flying.find(b=>b.group.text===String(event.text)&&b.el.isConnected&&b.age<b.duration);
    if(existing&&existing.group.add(event,context)){FusionDanmaku.badge(existing.badge,existing.group);const c=channels[source];if(c&&event.type==='chat'&&!c.countedMessages.has(event)){c.countedMessages.add(event);c.displayedChats++;}return;}}
  const group=new FusionDanmaku.Group(event,context),el=document.createElement('div');el.className='bullet';el.dataset.source=source;el.__message=event;
  el.style.pointerEvents='auto';el.style.cursor='pointer';el.tabIndex=0;el.setAttribute('role','button');el.setAttribute('aria-label','弹幕：'+String(event.text)+'，打开操作');
  el.onclick=e=>{e.stopPropagation();messageMenu.open(group,e);};el.onkeydown=e=>{if(e.key==='Enter'||e.key===' '){e.preventDefault();messageMenu.open(group,e);}};
  el.style.fontSize=$('size').value+'px';el.style.fontFamily=$('font').value;el.style.opacity=Number($('opacity').value)/100;
  if($('marker').value!=='none'){
    const tag=document.createElement('span');tag.className=($('marker').value==='pill'?'source-pill':'source-dot')+' '+source;
    if($('marker').value==='pill')tag.textContent=source;el.append(tag);
  }
  if($('user').checked&&event.user){const n=document.createElement('span');n.className='username';n.textContent=event.user+'：';el.append(n);}
  const body=document.createElement('span');body.className='body';body.style.color=$('original').checked?'#'+(event.color||16777215).toString(16).padStart(6,'0'):$('color').value;
  appendContent(body,event);el.append(body);let badge=null;if($('mergeSame').checked){badge=document.createElement('span');badge.className='fusion-merge-count';FusionDanmaku.badge(badge,group);el.append(badge);}bulletLayer.append(el);
  const width=el.getBoundingClientRect().width;
  lanes.tail=lanes.tail.map((_,lane)=>flying.some(b=>b.lane===lane&&bulletLayer.clientWidth-lanes.speed*b.age+b.width+32>bulletLayer.clientWidth)?Infinity:-Infinity);
  const track=lanes.enter(width,bulletLayer.clientWidth,now/1000,$('nonOverlap').checked);
  if(!track){el.remove();return;}
  el.style.top=bulletLayout.tops[track.lane]+'px';
  flying.push({el,group,badge,width,source,lane:track.lane,duration:track.duration,age:0,last:now,countChat:event.type==='chat',counted:false});
}
function ranges(media){const out=[];for(let i=0;i<media.buffered.length;i++)out.push([media.buffered.start(i),media.buffered.end(i)]);return out;}
function renderQuality(c){
  const s=c.source,select=$('quality'+s),wanted=Number(c.room.requestedQuality||0),source=c.room.sources[c.index];
  select.replaceChildren(new Option('自动（默认档位）','0'));
  for(const q of c.room.qualities||[])select.add(new Option(q.label,String(q.qn)));
  if(wanted&&!Array.from(select.options).some(o=>o.value===String(wanted))){const o=new Option('所选档位暂不可用',String(wanted));o.disabled=true;select.add(o);}
  select.value=String(wanted);select.disabled=!!c.qualityBusy;
  const actual=source?.quality,label=source?.qualityLabel||('档位 '+actual);
  $('quality'+s+'State').textContent=c.qualityBusy?'正在获取新清晰度，原直播继续播放…':!source?'线路不可用，请重连':
    '当前：'+label+(c.started&&c.media.videoWidth?' · '+c.media.videoWidth+'×'+c.media.videoHeight:'')+
    (wanted&&actual!==wanted?'（平台未提供所选档位，可能需要登录或该房间暂不支持）':'');
}
async function changeQuality(source,force=false){
  const c=channels[source],select=$('quality'+source);if(!c)return;
  const wanted=Number(select.value);if(!force&&wanted===Number(c.room.requestedQuality||0))return;
  const revision=(c.qualityRevision||0)+1;c.qualityRevision=revision;c.qualityBusy=true;select.disabled=true;
  $('quality'+source+'State').textContent='正在获取新清晰度，原直播继续播放…';
  const active=()=>channels[source]===c&&!c.closed&&c.qualityRevision===revision;
  try{
    const room=await rpc('resolve',{room:String(c.room.room),platform:c.room.platform||'bilibili',quality:wanted,voice:source==='A'&&$('voiceA').checked});
    if(!active())return;
    if(room.room!==c.room.room)throw Error('直播间发生变化，请重新连接');
    c.qualityBusy=false;c.room=room;c.index=0;c.epoch=generation+'-'+source+'-'+Date.now();c.suspended=!foreground;
    qualityChoices[source]=wanted;save();clearSourceBullets(source);c.open();void messages(c);
    notice(source+' 清晰度正在切换，保留该路设置的额外延迟；另一路继续播放，请重新核对同步。');
  }catch(e){if(active()){c.qualityBusy=false;renderQuality(c);$('quality'+source+'State').textContent='切换失败：'+e.message+'；原直播未停止';}}
}
class Channel{
  constructor(source,room,epoch){
    this.source=source;this.room=room;this.epoch=epoch;this.media=new IOSMedia(source,rpc);this.timeline=new C.Timeline();this.book=new C.EmojiBook();
    this.receivedChats=0;this.displayedChats=0;this.countedMessages=new WeakSet();this.index=0;this.closed=false;this.delay=0;this.holdUntil=0;this.started=false;this.pending=[];this.lastEnd=0;this.endAt=performance.now();this.lastMediaTime=0;this.chatState='消息准备中';
    this.media.onwaiting=()=>this.renderStatus('正在缓冲');
    this.media.onplaying=()=>this.playing();
    this.media.onerror=()=>this.fallback();
    this.media.onAudioInfo=()=>{if(this.source==='A')void applyVoice();};
    this.media.onseekerror=e=>{this.holdUntil=0;this.renderStatus('跳转未完成，请点继续或重新调整');notice(this.source+' 延迟调整失败：'+e.message,true);};
  }
  playing(){
    this.started=true;this.media.style.visibility='visible';
    const target=this.restoreDelayPending;this.restoreDelayPending=null;
    if(target>0)this.applyDelay(target);
    this.renderStatus();renderQuality(this);
  }
  renderStatus(playing=''){
    if(this.closed)return;
    if(!playing)playing=this.holdUntil>performance.now()?'正在积累 '+this.delay.toFixed(1)+'s 延迟':this.media.paused?'已暂停':this.media.waiting?'正在缓冲，等待原线路数据':'播放中';
    $('status'+this.source).textContent=playing+' · '+this.chatState;
  }
  open(){
    window.FusionVideoZoom?.reset(this.source);
    if(this.closed)return;
    this.switching=true;this.destroyEngine();this.switching=false;this.started=false;this.lastEnd=0;this.pending=[];this.timeline=new C.Timeline();this.holdUntil=0;this.delay=0;this.restoreDelayPending=preferredDelays[this.source];
    $('delay'+this.source).value=String(preferredDelays[this.source]);$('delay'+this.source+'Value').textContent=preferredDelays[this.source].toFixed(1)+'s';
    const source=this.room.sources[this.index];
    renderQuality(this);
    if(!source){this.renderStatus('直播线路失败，请重新连接');return;}
    if(!foreground){this.suspended=true;this.renderStatus('已暂停连接，点击继续恢复');return;}
    this.media.volume=Number($('volume'+this.source).value)/100;
    this.media.audioOnly=this.source==='B'&&$('audioOnlyB').checked;
    try{
      const revision=(this.mediaRevision||0)+1;this.mediaRevision=revision;
      this.media.open(source.url,source.type).then(()=>{if(!this.closed&&this.mediaRevision===revision){this.play();if(this.source==='A')void applyVoice();window.iosLayout();}}).catch(e=>{if(!this.closed&&this.mediaRevision===revision)this.fallback(e.message);});
    }catch(e){this.fallback(e.message);}
    this.media.volume=Number($('volume'+this.source).value)/100;
  }
  play(){
    if(this.closed||manualPaused||(!foreground&&!inVideoPiP&&$('backgroundMode').value==='pause')||performance.now()<this.holdUntil)return;
    if(this.suspended){this.suspended=false;this.epoch=generation+'-'+this.source+'-'+Date.now();this.open();void messages(this);notice(this.source+' 已恢复连接，保留设置的额外延迟，请核对同步。');return;}
    this.media.play().catch(()=>this.renderStatus('点击继续播放'));
  }
  suspend(){
    if(this.closed||this.suspended)return;
    this.suspended=true;this.switching=true;this.destroyEngine();this.switching=false;
    this.holdUntil=0;this.renderStatus('已暂停连接，点击继续恢复');
  }
  destroyEngine(){
    this.mediaRevision=(this.mediaRevision||0)+1;
    clearTimeout(this.retry);this.retry=null;
    if(this.engine){this.engine.destroy();this.engine=null;}
    this.media.pause();this.media.removeAttribute('src');this.media.load();
    this.media.style.visibility='hidden';
  }
  fallback(reason){
    if(this.closed||this.retry||this.switching)return;
    this.media.pause();this.renderStatus(reason||'播放中断，请手动重新获取画质');notice(this.source+' 播放停止，未自动重连或切换线路。',true);
  }
  edge(now){
    const r=ranges(this.media);if(!r.length)return null;
    const end=r[r.length-1][1];if(end>this.lastEnd+.001){this.lastEnd=end;this.endAt=now;}
    return this.lastEnd+Math.min(2,(now-this.endAt)/1000);
  }
  messageAt(now){return this.started&&this.media.readyState>=2?C.messageTime(this.media.currentTime,this.delay,Math.max(0,(this.holdUntil-now)/1000)):null;}
  accept(packet){
    const m=C.normalize(packet,this.book);if(!m)return;if(m.type==='chat')this.receivedChats++;
    m.platform=this.room.platform||'bilibili';
    if(blocked(m,this.source))return;
    if(m.type==='delete'){this.timeline.add(m,0);return;}
    const at=this.messageAt(performance.now());
    if(at===null){this.pending.push(m);if(this.pending.length>100)this.pending.shift();}
    else this.timeline.add(m,at);
  }
  applyDelay(value){
    if(!this.started){preferredDelays[this.source]=C.clamp(value,0,20);this.restoreDelayPending=preferredDelays[this.source];save();return;}
    if(this.holdUntil>performance.now()){notice('正在积累缓冲，请完成后再调节',true);$('delay'+this.source).value=this.delay;$('delay'+this.source+'Value').textContent=this.delay.toFixed(1)+'s';return;}
    const action=C.delayAction(this.media.currentTime,this.delay,value,ranges(this.media));this.delay=C.clamp(value,0,20);preferredDelays[this.source]=this.delay;save();
    $('delay'+this.source).value=String(this.delay);$('delay'+this.source+'Value').textContent=this.delay.toFixed(1)+'s';
    clearBullets();if(action.seek!==null){this.media.currentTime=Math.max(0,action.seek);this.timeline.seek(this.media.currentTime);}
    if(action.hold>.02){this.holdUntil=performance.now()+action.hold*1000;this.media.pause();}
    this.renderStatus();notice(this.source+' 额外延迟设为 '+this.delay.toFixed(1)+' 秒，消息与 SC 跟随该路播放进度。');
  }
  tick(now){
    if(this.suspended)return;
    const edge=this.edge(now);
    if(foreground&&this.media.paused&&edge!==null&&edge-this.media.currentTime>30&&this.room.sources[this.index]?.type==='flv'){
      this.suspend();notice(this.source+' 暂停后的缓冲已达上限，已停止下载；点击继续可重新连接。');return;
    }
    const at=this.messageAt(now);if(at!==null&&this.pending.length){for(const m of this.pending)this.timeline.add(m,at);this.pending=[];}
    if(this.holdUntil&&now>=this.holdUntil){this.holdUntil=0;this.play();}
    if(manualPaused||!foreground||this.media.paused||this.media.seeking||this.media.readyState<3)return;
    this.lastMediaTime=this.media.currentTime;
    for(const m of this.timeline.drain(this.media.currentTime)){addHistory(m,this.source);addBullet(m,this.source,now);}
  }
  close(){this.closed=true;this.media.onwaiting=this.media.onplaying=this.media.onerror=null;this.destroyEngine();}
}
window.liveEvent=(source,epoch,event)=>{
  const c=channels[source];if(!c||c.epoch!==epoch||c.closed)return;
  if(event.status){c.chatState=event.status;c.renderStatus();}if(event.packet)c.accept(event.packet);
};
async function messages(c){
  const epoch=c.epoch,active=()=>channels[c.source]===c&&!c.closed&&c.epoch===epoch;
  if((c.room.platform||'bilibili')==='bilibili'){
  rpc('emojis',{room:String(c.room.room)}).then(data=>{if(active())c.book.learn(data);}).catch(()=>{});
  rpc('learned',{room:String(c.room.room)}).then(data=>{if(active())c.book.learn(data);}).catch(()=>{});
  rpc('snapshot',{room:String(c.room.room)}).then(data=>{
    if(active())for(const m of (data.super_chat_info?.message_list||[]))c.accept({cmd:'SUPER_CHAT_MESSAGE',data:m});
  }).catch(e=>{if(active())notice(c.source+' 房间历史 SC 暂不可用（'+e.message+'）。实时弹幕 / SC 请看连接状态；可在官方页面登录验证后重连。');});
  }
  try{await rpc('startChat',{source:c.source,epoch:c.epoch,room:String(c.room.room),title:c.room.title,platform:c.room.platform||'bilibili'});}catch(e){if(active()){c.chatState=e.message;c.renderStatus();}}
}
function stop(){
  void rpc('pipStop').catch(()=>{});pipEnabled=false;
  generation++;
  for(const c of Object.values(channels))c.close();channels={};
  rpc('stopChat').catch(()=>{});manualPaused=false;updatePlaybackService();clearBullets();cardLayer.replaceChildren();scNodes.clear();
  $('placeholder').hidden=false;$('pause').disabled=$('live').disabled=$('stop').disabled=true;$('pause').textContent='暂停';
  for(const s of ['A','B']){
    $('video'+s).style.visibility='hidden';$('status'+s).textContent='尚未连接';$('delay'+s).value=String(preferredDelays[s]);$('delay'+s+'Value').textContent=preferredDelays[s].toFixed(1)+'s';
    $('quality'+s).replaceChildren(new Option('自动（默认档位）','0'));$('quality'+s).disabled=true;$('quality'+s+'State').textContent='开始融合后读取可选清晰度';
  }
}
async function connect(){
  stop();const gen=generation;$('connect').disabled=true;save();notice('正在读取两路直播…');
  try{
    const rooms=await Promise.all(['A','B'].map(s=>rpc('resolve',{room:$('room'+s).value.trim(),platform:$('platform'+s).value,quality:qualityChoices[s],voice:s==='A'&&$('voiceA').checked}).catch(e=>{throw Error(s+' 房间：'+e.message);})));
    if(gen!==generation)return;
    if((rooms[0].platform||'bilibili')===(rooms[1].platform||'bilibili')&&String(rooms[0].room)===String(rooms[1].room))throw Error('A 和 B 指向同一个房间，请选择不同的两路直播间');
    for(let i=0;i<2;i++){const s=['A','B'][i],epoch=gen+'-'+s+'-'+Date.now(),c=new Channel(s,rooms[i],epoch);channels[s]=c;$('title'+s).textContent=rooms[i].title;c.open();}
    $('placeholder').hidden=true;$('pause').disabled=$('live').disabled=$('stop').disabled=false;
    for(const c of Object.values(channels))void messages(c);updatePlaybackService();
    notice('直播流已获取。消息连接状态见下方；必要时先在官方页面完成登录验证。');
  }catch(e){if(gen===generation){stop();notice(e.message,true);}}
  finally{$('connect').disabled=false;}
}
function createCard(m){
  const el=document.createElement('article');el.className='sc';el.dataset.source=m.source;
  const head=document.createElement('div');head.className='sc-head';
  if(m.avatar){const img=document.createElement('img');img.src=m.avatar;img.alt='';img.referrerPolicy='no-referrer';img.onerror=()=>img.remove();head.append(img);}
  if($('marker').value!=='none'){const tag=document.createElement('span');tag.className='source-dot '+m.source;head.append(tag);}
  const name=document.createElement('strong');name.textContent=m.user;const price=document.createElement('small');price.textContent='¥ '+m.price;
  const close=document.createElement('button');close.type='button';close.textContent='×';close.setAttribute('aria-label','关闭醒目留言');close.onclick=e=>{e.stopPropagation();channels[m.source]?.timeline.dismiss(m.id);renderCards();};
  head.append(name,price,close);const body=document.createElement('div');body.className='sc-body';appendContent(body,m);
  const time=document.createElement('div');time.className='sc-time';const progress=document.createElement('div');progress.className='sc-progress';
  el.append(head,body,time,progress);return {el,time,progress};
}
function renderCards(){
  if(manualPaused){cardLayer.replaceChildren();scNodes.clear();return;}
  cardLayer.hidden=manualPaused;
  const by={A:[],B:[]};
  for(const s of ['A','B']){
    const c=channels[s];if(!c)continue;
    const time=c.media.currentTime;
    for(const m of c.timeline.cards(time)){
      if(blocked(m,s))continue;
      if(!m.logged){const original=c.timeline.sc.get(m.id);if(original&&!original.logged){original.logged=true;addHistory(m,s);}}
      if($('sc'+s).checked)by[s].push({...m,source:s,key:c.epoch+':'+m.id});
    }
  }
  // Keep at least the newest card from either active room before filling remaining space.
  const selected=[by.A.at(-1),by.B.at(-1)].filter(Boolean),rest=[...by.A.slice(0,-1),...by.B.slice(0,-1)].sort((a,b)=>b.received-a.received);
  selected.push(...rest.slice(0,Math.max(0,3-selected.length)));selected.sort((a,b)=>b.received-a.received);
  const wanted=new Set(selected.map(m=>m.key));
  for(const [key,n] of scNodes)if(!wanted.has(key)){n.el.remove();scNodes.delete(key);}
  let cardIndex=0;
  for(const m of selected){
    let node=scNodes.get(m.key);if(!node){node=createCard(m);scNodes.set(m.key,node);}
    const left=Math.max(0,Math.ceil(m.left));node.time.textContent=Math.floor(left/60)+':'+String(left%60).padStart(2,'0');
    node.progress.style.transform='scaleX('+m.fraction+')';
    if(cardLayer.children[cardIndex]!==node.el)cardLayer.insertBefore(node.el,cardLayer.children[cardIndex]||null);
    cardIndex++;
  }
}
function running(c){return !manualPaused&&foreground&&!c.media.paused&&!c.media.seeking&&c.media.readyState>=3;}
function animate(now){
  if(now-lastPump>80){for(const c of Object.values(channels))c.tick(now);lastPump=now;}
  const laneFront=new Map();
  for(const item of [...flying].sort((a,b)=>b.age-a.age)){
    const c=item.group.members.map(m=>channels[m.context.source]).find(c=>c&&running(c))||channels[item.source];if(!c){item.el.remove();flying.splice(flying.indexOf(item),1);continue;}
    let proposed=item.age+(running(c)?Math.min(.1,(now-item.last)/1000):0);
    const front=laneFront.get(item.lane);
    if(front&&$('nonOverlap').checked)proposed=Math.min(proposed,front.age-(front.width+32)/lanes.speed);
    item.age=Math.max(item.age,proposed);item.last=now;laneFront.set(item.lane,item);
    if(item.countChat&&!item.counted&&running(c)&&item.age>0&&bulletLayer.clientWidth>0&&bulletLayer.clientHeight>0){item.counted=true;if(!c.countedMessages.has(item.el.__message)){c.countedMessages.add(item.el.__message);c.displayedChats++;}}
    if(item.age>=item.duration){item.el.remove();flying.splice(flying.indexOf(item),1);}
    else item.el.style.transform='translateX('+(-lanes.speed*item.age)+'px)';
  }
  renderCards();if(now-lastChatStats>=500){lastChatStats=now;for(const s of ['A','B']){$('chatStats'+s).textContent=s+' · 已接收 '+(channels[s]?.receivedChats||0)+' 条 · 已显示 '+(channels[s]?.displayedChats||0)+' 条';}}
  if(foreground&&Object.keys(channels).length)frame=requestAnimationFrame(animate);else setTimeout(()=>{frame=requestAnimationFrame(animate);},250);
}
function wake(){
  stage.classList.remove('quiet');clearTimeout(hideTimer);
  if(full)hideTimer=setTimeout(()=>{if($('settings').hidden&&!stage.querySelector('input:focus,select:focus'))stage.classList.add('quiet');},3500);
}
async function setFull(value){
  full=value;document.body.classList.toggle('full',value);$('full').textContent=value?'退出全屏':'全屏';
  if(window.Native)try{await rpc('fullscreen',{value});}catch(e){notice(e.message,true);}
  wake();clearBullets();
}
window.exitFull=()=>{full=false;document.body.classList.remove('full');$('full').textContent='全屏';wake();clearBullets();};
window.playbackLifecycle=state=>{
  const visible=!!state.foreground;if(!visible)sendVisibilityEpoch++;
  foreground=visible;
  if(typeof state.videoPiP==='boolean'){inVideoPiP=state.videoPiP;document.body.classList.toggle('video-pip',inVideoPiP);}
  if(!visible){
    if(!inVideoPiP&&$('backgroundMode').value==='pause')for(const c of Object.values(channels))if(!window.IOSMedia||c.media.webMode)c.media.pause();
    if(inVideoPiP&&!manualPaused)for(const c of Object.values(channels))if(!window.IOSMedia||c.media.webMode)c.play();
    clearBullets();
  }else{
    void status();for(const c of Object.values(channels)){if(c.started)c.media.style.visibility='visible';if(!manualPaused&&!c.suspended&&!c.mediaFailed&&(!window.IOSMedia||c.media.webMode))c.play();}
    window.iosLayout?.();wake();
  }
};
window.orientationState=state=>{
  if(state.error){notice('系统未允许切换方向：'+state.error+'。可退出系统分屏后再试。',true);return;}
  if(state.detail)notice(state.detail);
  if(state.actual)$('rotateScreen').textContent=state.actual==='landscape'?'切竖屏':'切横屏';
};
window.videoPiPState=(state,detail)=>{if(detail)notice(detail,state==='error');if(state==='stopped'||state==='error'){inVideoPiP=false;document.body.classList.remove('video-pip');}};
window.appVisibility=visible=>window.playbackLifecycle({foreground:visible});
function updatePlaybackService(){if(!window.IOSMedia)void rpc('playbackActivity',{active:Object.keys(channels).length>0,paused:manualPaused}).catch(e=>notice('后台播放提示：'+e.message,true));}
async function syncPlaybackPreferences(){
  await rpc('backgroundMode',{value:$('backgroundMode').value}).catch(e=>notice(e.message,true));if($('screenOrientation').value!=='auto')await rpc('orientation',{value:$('screenOrientation').value}).catch(e=>notice(e.message,true));updatePlaybackService();
}
async function rotateScreen(){
  const value=window.innerWidth>window.innerHeight?'portrait':'landscape';
  if(!full)await setFull(true);$('screenOrientation').value=value;save();
  await rpc('orientation',{value}).catch(e=>notice('方向切换失败：'+e.message,true));
}
$('rotateScreen').onclick=()=>void rotateScreen();
$('videoPiP').onclick=async()=>{try{if(!Object.keys(channels).length)throw Error('请先开始播放');if(!window.IOSMedia){document.body.classList.add('video-pip');await new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)));}await rpc('videoPiPStart',{source:'A'});}catch(e){document.body.classList.remove('video-pip');notice(e.message,true);}};
$('refreshStreams').onclick=async()=>{
  if($('refreshStreams').disabled)return;
  const sources=Object.keys(channels);if(!sources.length){notice('请先开始融合');return;}
  $('refreshStreams').disabled=true;
  try{await Promise.all(sources.map(source=>changeQuality(source,true)));notice('已手动刷新两路直播流；延迟、音量和弹幕设置保留。失败的一路保持原状态，请看其画质提示。');}
  finally{$('refreshStreams').disabled=false;}
};
for(const id of ids)$(id).addEventListener('input',()=>{
  updateLabels();save();
  if(id==='backgroundMode'){void syncPlaybackPreferences();}
  else if(id==='screenOrientation'){void rpc('orientation',{value:$(id).value}).catch(e=>notice(e.message,true));}
  else if(id==='scDraggable'){scLayout.setDraggable($(id).checked);}
  else if(id.startsWith('pip')){if(pipEnabled)void rpc('pipSettings',pipSettings()).catch(e=>notice(e.message,true));}
  else if(id==='voiceA'||id==='voiceStrength'){void applyVoice();}
  else if(id==='audioOnlyB'){if(pipEnabled)$('audioOnlyB').checked=true;applyAudioMode();}
  else if(id.startsWith('volume')){const s=id.slice(-1);if(channels[s])channels[s].media.volume=Number($(id).value)/100;}
  else if(id==='chatSpeed'){/* Scroll only: preserve position, media clocks and SC lifetime. */}
  else if(id==='chatA'||id==='chatB'){if(!$(id).checked)clearSourceBullets(id.slice(-1));}
  else if(id!=='scA'&&id!=='scB'){clearBullets();if(id==='marker'){cardLayer.replaceChildren();scNodes.clear();}}
  if(pipEnabled&&(id==='chatB'||id==='scB'||id==='mergeSame'))void rpc('pipSettings',pipSettings()).catch(()=>{});
});
for(const s of ['A','B']){
  $('quality'+s).onchange=()=>void changeQuality(s);
  $('delay'+s).oninput=()=>{$('delay'+s+'Value').textContent=Number($('delay'+s).value).toFixed(1)+'s';};
  $('delay'+s).onchange=()=>{const value=C.clamp(Number($('delay'+s).value),0,20),c=channels[s];if(c)c.applyDelay(value);else{preferredDelays[s]=value;save();notice('已记住 '+s+' 延迟，开始播放后自动积累缓冲应用。');}};
}
$('connect').onclick=connect;$('stop').onclick=()=>{stop();notice('已停止播放与消息连接');};
$('voiceApply').onclick=()=>void changeQuality('A',true);
$('login').onclick=()=>{const menu=document.createElement('dialog');menu.innerHTML='<p>账号 / 登录</p>';for(const [platform,name] of [['bilibili','B站'],['huya','虎牙'],['douyu','斗鱼']]){const button=document.createElement('button');button.textContent=name;button.onclick=()=>{menu.close();menu.remove();void rpc('login',{platform}).catch(e=>notice(e.message,true));};menu.append(button);}const close=document.createElement('button');close.textContent='关闭';close.onclick=()=>{menu.close();menu.remove();};menu.append(close);document.body.append(menu);menu.showModal();};
$('pause').onclick=()=>{manualPaused=!manualPaused;if(manualPaused)clearBullets();if(pipEnabled)void rpc('pipPause',{value:manualPaused}).catch(()=>{});for(const c of Object.values(channels)){if(pipEnabled&&c.source==='A')continue;manualPaused?c.media.pause():c.play();}if(manualPaused)clearBullets();$('pause').textContent=manualPaused?'继续':'暂停';updatePlaybackService();wake();};
$('live').onclick=()=>{
  clearBullets();manualPaused=false;$('pause').textContent='暂停';
  for(const c of Object.values(channels)){const r=ranges(c.media);if(r.length){c.media.currentTime=Math.max(r.at(-1)[0],r.at(-1)[1]-.7);c.timeline.seek(c.media.currentTime);}c.delay=0;preferredDelays[c.source]=0;save();c.holdUntil=0;$('delay'+c.source).value='0';$('delay'+c.source+'Value').textContent='0.0s';c.play();}
  notice('回到当前可播放位置，额外延迟归零；两路仍可能有不同的原始直播延迟。');
};
$('settingsToggle').onclick=()=>{$('settings').hidden=!$('settings').hidden;wake();};
$('settingsClose').onclick=()=>{$('settings').hidden=true;wake();};
$('full').onclick=()=>setFull(!full);$('wake').onclick=wake;
function applyAudioMode(){const on=$('audioOnlyB').checked;if(on)setDual(false);const c=channels.B;if(c?.media.webMode&&c.media.audioOnly!==on){c.media._audioOnly=on;clearSourceBullets('B');c.open();void messages(c);notice('B 声音模式已手动切换，保留该路设置的额外延迟，请核对同步。');}else if(c)c.media.audioOnly=on;}
function setDual(on){window.FusionVideoZoom?.resetAll();document.body.classList.toggle('dual',on);preferredDual=on;save();$('dual').textContent=on?'单画面':'双画面';$('dual').setAttribute('aria-pressed',String(on));$('viewB').setAttribute('aria-hidden',String(!on));clearBullets();wake();}
$('dual').onclick=()=>{if(pipEnabled){notice('请先关闭消息画中画，再恢复双路画面');return;}const on=!document.body.classList.contains('dual');if(on&&$('audioOnlyB').checked){$('audioOnlyB').checked=false;applyAudioMode();save();}setDual(on);};
function hideChrome(){clearTimeout(hideTimer);$('settings').hidden=true;stage.querySelector('input:focus,select:focus')?.blur();stage.classList.add('quiet');}
stage.addEventListener('click',e=>{
  if(e.target.closest('button,input,select,textarea,a,#settings,.sc,.bullet,[role="dialog"]'))return;
  if(stage.classList.contains('quiet'))wake();else hideChrome();
});
$('historyClear').onclick=()=>{$('history').replaceChildren();historyCount=0;};
$('reconnect').onclick=()=>{for(const c of Object.values(channels))void messages(c);};
$('verify').onclick=()=>{const c=channels[$('target').value];if(!c){notice('请先连接直播间',true);return;}rpc('verify',{room:String(c.room.room),platform:c.room.platform||'bilibili',source:c.source}).catch(e=>notice(e.message,true));};
function pipSettings(){return {mergeSame:$('mergeSame').checked,rows:Number($('pipRows').value),size:Number($('pipSize').value),user:$('pipUser').checked,chat:$('chatB').checked,sc:$('scB').checked};}
window.pipState=(state,detail)=>{
  pipEnabled=state==='starting'||state==='active';pipBusy=state==='starting';
  $('pip').disabled=$('pipSettingsToggle').disabled=pipBusy;
  $('pip').textContent=$('pipSettingsToggle').textContent=pipEnabled?'关闭消息画中画':'二路消息画中画';
  $('pipStatus').textContent=detail;notice(detail,state==='error');
  if(state==='active'){
    channels.A?.suspend();manualPaused=false;$('pause').textContent='暂停';clearBullets();
    $('audioOnlyB').checked=true;applyAudioMode();$('settings').hidden=true;
  }
};
window.pipPlayback=playing=>{manualPaused=!playing;$('pause').textContent=playing?'暂停':'继续';if(!playing)clearBullets();};
window.pipRestored=()=>{$('settings').hidden=false;wake();};
async function togglePiP(){
  if(pipBusy)return;
  if(pipEnabled){await rpc('pipStop').catch(e=>notice(e.message,true));return;}
  pipBusy=true;$('pip').disabled=$('pipSettingsToggle').disabled=true;
  try{
    const input=$('roomB').value.trim();if(!input)throw Error('请先填入二路房间 B');
    // Resolve the entered B explicitly. Editing the input must not keep the old room in PiP.
    notice('正在连接二路并准备消息画中画…');
    const gen=generation,room=await rpc('resolve',{room:input,platform:$('platformB').value,quality:qualityChoices.B});
    if(gen!==generation)throw Error('连接已改变，请重试');
    if(!channels.B||String(channels.B.room.room)!==String(room.room)||channels.B.suspended){
      stop();const c=new Channel('B',room,generation+'-B-'+Date.now());channels.B=c;
      $('audioOnlyB').checked=true;setDual(false);$('titleB').textContent=room.title;c.open();void messages(c);
      $('pause').disabled=$('live').disabled=$('stop').disabled=false;
    }
    const c=channels.B,epoch=c.epoch;manualPaused=false;c.play();
    for(let n=0;n<60&&!c.started;n++)await new Promise(r=>setTimeout(r,200));
    if(channels.B!==c||c.closed||c.epoch!==epoch)throw Error('二路已切换，请重新开启画中画');
    if(!c.started)throw Error('二路声音尚未就绪，请等开始播放后再试');
    $('audioOnlyB').checked=true;applyAudioMode();
    await rpc('pipStart',pipSettings());
  }catch(e){notice(e.message,true);$('pipStatus').textContent=e.message;}
  finally{if(!pipEnabled){pipBusy=false;$('pip').disabled=$('pipSettingsToggle').disabled=false;}}
}
$('pip').onclick=$('pipSettingsToggle').onclick=()=>void togglePiP();
let sendingMessage=false,sendResultTimer,sendVisibilityEpoch=0;
async function sendMessage(both){
  if(sendingMessage)return;
  const sources=both?['A','B']:[$('target').value],text=$('message').value.trim();
  if(sources.some(s=>!channels[s])){notice('请先连接直播间',true);return;}
  if(sources.some(s=>(channels[s].room.platform||'bilibili')==='bilibili')&&!account.loggedIn){notice('请先登录 B站',true);return;}
  if(!text||[...text].length>40){notice('请输入 1–40 字的弹幕',true);return;}
  const gen=generation,uid=account.uid,visibility=sendVisibilityEpoch,refs=sources.map(s=>channels[s]),epochs=refs.map(c=>c.epoch);
  const active=()=>gen===generation&&foreground&&visibility===sendVisibilityEpoch&&uid===account.uid&&sources.every((s,i)=>channels[s]===refs[i]&&channels[s].epoch===epochs[i]);
  const show=message=>{clearTimeout(sendResultTimer);$('sendResult').hidden=false;$('sendResult').textContent=message;notice(message);wake();};
  const summarize=results=>results.map(r=>r.sources.join('/')+'：'+(r.submitted?'已提交':r.error)).join('；');
  sendingMessage=true;$('send').disabled=$('sendBoth').disabled=true;
  try{
    const results=await C.sendBatch(sources.map(s=>({source:s,room:String(channels[s].room.room),platform:channels[s].room.platform||'bilibili'})),
      (room,platform)=>rpc('send',{room,platform,text,uid}),{active,progress:(state,results,item)=>show(
        state==='wait'?summarize(results)+'；间隔 5 秒后提交另一房间':
        state==='sending'?(results.length?summarize(results)+'；':'')+'正在提交 '+item.sources.join('/')+'…':summarize(results))});
    const all=results.every(r=>r.submitted);
    if(all&&$('message').value.trim()===text)$('message').value='';
    show(summarize(results)+(all?'。提交不保证所有观众可见。':'。草稿已保留；请确认结果，仅重发未成功的房间。'));
  }catch(error){show(error.message);}
  finally{sendingMessage=false;$('send').disabled=$('sendBoth').disabled=false;sendResultTimer=setTimeout(()=>{$('sendResult').hidden=true;},10000);wake();}
}
$('composer').onsubmit=e=>{e.preventDefault();void sendMessage(false);};
$('sendBoth').onclick=()=>void sendMessage(true);
new ResizeObserver(clearBullets).observe($('viewA'));updateLabels();setDual(preferredDual&&!$('audioOnlyB').checked);void syncPlaybackPreferences();clearBullets();requestAnimationFrame(animate);void status();void setupVoiceMode();
window.platformRoomSelected=(source,platform,room)=>{if(!['A','B'].includes(source)||!['bilibili','huya','douyu'].includes(platform))return;$('platform'+source).value=platform;$('room'+source).value=String(room);save();void preview(source);};
for(const source of ['A','B'])$('platform'+source).addEventListener('change',()=>{qualityChoices[source]=0;previews[source].revision++;save();void preview(source);});
void preview('A');void preview('B');
document.querySelector('a[href="licenses.html"]').onclick=async e=>{
  e.preventDefault();$('legal').hidden=false;$('legalText').textContent='正在读取本地许可…';
  const files=['NOTICES.txt','vendor/desktop-MIT-notice.txt'];
  const texts=await Promise.all(files.map(async f=>{try{const r=await fetch(f);return r.ok?f+'\n\n'+await r.text():f+'：请参阅随包许可文件';}catch{return f;}}));
  $('legalText').textContent=texts.join('\n\n────────────────\n\n');
};
$('legalClose').onclick=()=>{$('legal').hidden=true;};
window.__fusionUIReady=true;
})();
