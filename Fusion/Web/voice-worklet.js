class FusionVoiceWorklet extends AudioWorkletProcessor{
 static get parameterDescriptors(){return [{name:'strength',defaultValue:0,minValue:0,maxValue:1,automationRate:'a-rate'}];}
 constructor(){super();this.a=Math.exp(-2*Math.PI*180/sampleRate);this.b=Math.exp(-2*Math.PI*5500/sampleRate);this.prev=this.high=this.low=0;}
 process(inputs,outputs,params){const input=inputs[0],out=outputs[0];if(!input?.length)return true;const l=input[0],r=input[1];for(let i=0;i<out[0].length;i++){const left=l[i]||0,right=r?r[i]||0:left;if(!r){out[0][i]=out[1][i]=left;continue;}const mid=(left+right)/2;this.high=this.a*(this.high+mid-this.prev);this.prev=mid;this.low=this.b*this.low+(1-this.b)*this.high;const amount=params.strength.length===1?params.strength[0]:params.strength[i],remove=amount*this.low;out[0][i]=Math.max(-1,Math.min(1,left-remove));out[1][i]=Math.max(-1,Math.min(1,right-remove));}return true;}
}
registerProcessor('fusion-voice',FusionVoiceWorklet);

