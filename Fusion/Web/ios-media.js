/* AVPlayer bridge: media stays below a transparent, fully interactive WKWebView. */
(()=>{
'use strict';
const active=new Map();let serial=0;
class IOSMedia{
  constructor(source,rpc){this.source=source;this.rpc=rpc;this.element=document.getElementById('video'+source);this.style=this.element.style;this._volume=1;this.token='';this.seekSerial=0;this.pendingSeek=0;this.state={currentTime:0,rate:0,paused:true,readyState:0,ranges:[]};this.at=performance.now();active.set(source,this);}
  command(op,args={}){if(!this.token)return Promise.resolve();return this.rpc(op,{source:this.source,token:this.token,...args});}
  async open(url,type='hls'){if(type==='flv')return this.openWeb(url);this.webMode=false;this.element.classList?.remove('web-player');this.token='media-'+this.source+'-'+(++serial);this.state={currentTime:0,rate:0,paused:true,readyState:0,ranges:[]};this.at=performance.now();return this.command('mediaOpen',{url,volume:this._volume,audioOnly:!!this._audioOnly});}
  async openWeb(url){if(!window.mpegts?.isSupported())throw Error('当前 iOS 不支持 FLV 播放，请手动选择 HLS 平台或线路');this.webMode=true;this.channels=0;this.onAudioInfo?.(0);this.token='web-'+(++serial);this.element.classList.add('web-player');this.element.setAttribute('disableRemotePlayback','');this.element.disableRemotePlayback=true;const token=this.token,result=await this.rpc('mediaWebURL',{source:this.source,url,token});if(this.token!==token)return;this.engine=mpegts.createPlayer({type:'flv',url:result.url,isLive:true,hasVideo:!this._audioOnly},{enableWorker:false,isLive:true,lazyLoad:false,liveBufferLatencyChasing:false,liveSync:false,autoCleanupSourceBuffer:true,autoCleanupMaxBackwardDuration:35,autoCleanupMinBackwardDuration:25});this.engine.on(mpegts.Events.MEDIA_INFO,info=>{this.channels=Number(info.audioChannelCount)||0;this.onAudioInfo?.(this.channels);});this.engine.on(mpegts.Events.ERROR,()=>this.onerror?.(new Error('FLV 播放中断，请手动重新获取')));this.element.onplaying=()=>this.onplaying?.();this.element.onwaiting=()=>this.onwaiting?.();this.element.volume=this._volume;this.engine.attachMediaElement(this.element);this.engine.load();}
  get audioOnly(){return !!this._audioOnly;}
  set audioOnly(value){this._audioOnly=!!value;if(this.webMode){this.element.style.visibility=value?'hidden':'visible';return;}this.command('mediaAudioOnly',{value:this._audioOnly}).catch(e=>this.onseekerror?.(e));}
  get currentTime(){if(this.webMode)return this.element.currentTime;const s=this.state;return s.currentTime+(!this.pendingSeek&&!s.paused&&!s.seeking&&s.readyState>=3?s.rate*Math.min(.3,(performance.now()-this.at)/1000):0);}
  set currentTime(time){if(this.webMode){this.element.currentTime=time;return;}const rev=++this.seekSerial,token=this.token;this.pendingSeek=rev;this.state.currentTime=time;this.state.seeking=true;this.at=performance.now();this.command('mediaSeek',{time}).then(result=>{if(this.pendingSeek!==rev||this.token!==token)return;this.pendingSeek=0;this.state.seeking=false;if(result?.state)this.update(result.state);}).catch(e=>{if(this.pendingSeek!==rev||this.token!==token)return;this.pendingSeek=0;this.state.seeking=false;this.onseekerror?.(e);});}
  get buffered(){if(this.webMode)return this.element.buffered;const r=this.state.loaded||this.state.ranges||[];return {length:r.length,start:i=>r[i][0],end:i=>r[i][1]};}
  get paused(){return this.webMode?this.element.paused:this.state.paused;}
  get seeking(){return this.webMode?this.element.seeking:!!(this.pendingSeek||this.state.seeking);}
  get waiting(){return this.webMode?!this.element.paused&&this.element.readyState<3:!!this.token&&!this.state.paused&&!this.state.seeking&&(this.state.waiting===true||this.state.readyState<3);}
  get readyState(){return this.webMode?this.element.readyState:this.state.readyState;}
  get videoWidth(){if(this.webMode)return this.element.videoWidth;return this.state.videoWidth||0;}
  get videoHeight(){if(this.webMode)return this.element.videoHeight;return this.state.videoHeight||0;}
  get volume(){return this._volume;}
  set volume(value){this._volume=Math.min(1,Math.max(0,Number(value)||0));if(this.webMode){this.element.volume=this._volume;return;}clearTimeout(this.volumeTimer);this.volumeTimer=setTimeout(()=>{this.command('mediaVolume',{volume:this._volume}).catch(()=>{});},80);}
  play(){if(this.webMode)return this.element.play();this.state.paused=false;return this.command('mediaPlay');}
  pause(){if(this.webMode){this.element.pause();return;}this.state.currentTime=this.currentTime;this.state.paused=true;this.at=performance.now();this.command('mediaPause').catch(()=>{});}
  removeAttribute(name){if(name!=='src')return;this.pendingSeek=0;this.seekSerial++;if(this.webMode){this.engine?.destroy();this.engine=null;this.element.pause();this.element.removeAttribute('src');this.element.load();this.token='';return;}clearTimeout(this.volumeTimer);this.command('mediaClose').catch(()=>{});this.token='';this.state={currentTime:0,rate:0,paused:true,readyState:0,ranges:[]};}
  load(){}
  update(state){
    if(this.webMode||!this.token||state.token!==this.token)return;
    const wasWaiting=this.waiting,before=this.state;if(this.pendingSeek)state={...state,currentTime:before.currentTime,seeking:true};this.state=state;this.at=performance.now();
    if(state.error&&!before.error)this.onerror?.(new Error(state.error));
    else if(state.rate>0&&state.readyState>=3&&(before.rate===0||before.readyState<3))this.onplaying?.();
    else if(this.waiting&&!wasWaiting)this.onwaiting?.();
  }
}
window.IOSMedia=IOSMedia;
window.iosVideoZoom=(source,value)=>{const media=active.get(source);if(media?.token&&!media.webMode)window.Native?.call('0','videoZoom',JSON.stringify({source,token:media.token,...value}));};
window.iosMediaState=states=>{for(const [source,state] of Object.entries(states))active.get(source)?.update(state);};
let queued=false,last='';
window.iosLayout=()=>{
  if(queued)return;queued=true;
  requestAnimationFrame(()=>{
    queued=false;const result={};
    for(const s of ['A','B']){const rect=document.getElementById('view'+s).getBoundingClientRect();result[s]={x:rect.x,y:rect.y,width:rect.width,height:rect.height,visible:!active.get(s)?.webMode&&(s==='A'||document.body.classList.contains('dual'))};}
    const text=JSON.stringify(result);if(text!==last){last=text;window.Native?.call('0','layout',text);}
  });
};
window.addEventListener('scroll',window.iosLayout,{passive:true,capture:true});window.addEventListener('resize',window.iosLayout);
document.addEventListener('DOMContentLoaded',()=>{
  new ResizeObserver(window.iosLayout).observe(document.getElementById('stage'));
  new MutationObserver(window.iosLayout).observe(document.body,{attributes:true,attributeFilter:['class']});
  window.iosLayout();
});
})();
