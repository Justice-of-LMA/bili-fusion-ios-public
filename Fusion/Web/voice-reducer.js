(function(root){'use strict';
class VoiceReducer{
 constructor(media){this.media=media;this.context=null;this.ready=null;this.channels=0;this.enabled=false;this.strength=.8;}
 setChannels(n){this.channels=Number(n)||0;if(this.remove&&this.context){const now=this.context.currentTime;this.remove.gain.setTargetAtTime(this.enabled&&this.channels===2?-this.strength:0,now,.02);}}
 detail(){return !this.enabled?'已关闭，保留 A 原声音':this.node?'本机立体声人声减弱中':this.channels===2?'本机立体声人声减弱中':this.channels===1?'当前为单声道，保留原声音':'等待音频声道信息，暂保留原声音';}
 async set(enabled,strength=.8){
  this.enabled=enabled;this.strength=Math.max(0,Math.min(1,strength));
  if(!this.ready){if(!enabled)return;this.ready=(async()=>{
   const Audio=root.AudioContext||root.webkitAudioContext;if(!Audio)throw Error('此系统没有可用的本机音频处理');const c=this.context=new Audio();
   if(root.isSecureContext&&c.audioWorklet){await c.audioWorklet.addModule('voice-worklet.js');const source=c.createMediaElementSource(this.media);this.node=new AudioWorkletNode(c,'fusion-voice',{outputChannelCount:[2]});source.connect(this.node);this.node.connect(c.destination);}
   else {const source=c.createMediaElementSource(this.media),split=c.createChannelSplitter(2),mid=c.createGain(),high=c.createBiquadFilter(),low=c.createBiquadFilter(),remove=this.remove=c.createGain();source.connect(c.destination);source.connect(split);mid.gain.value=.5;split.connect(mid,0);split.connect(mid,1);high.type='highpass';high.frequency.value=180;high.Q.value=.5;low.type='lowpass';low.frequency.value=5500;low.Q.value=.5;remove.gain.value=0;mid.connect(high);high.connect(low);low.connect(remove);remove.connect(c.destination);}
  })();}
  await this.ready;await this.context.resume();if(this.node)this.node.parameters.get('strength').setTargetAtTime(enabled?this.strength:0,this.context.currentTime,.02);else this.setChannels(this.channels);
 }
}
root.FusionVoiceReducer=VoiceReducer;
})(globalThis);

