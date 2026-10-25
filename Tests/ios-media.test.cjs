const {test}=require('node:test'),assert=require('node:assert/strict'),vm=require('node:vm'),fs=require('node:fs'),path=require('node:path');
function setup(handler){
 const calls=[],win={addEventListener(){}},sandbox={window:win,document:{getElementById:()=>({style:{}}),addEventListener(){}},performance:{now:()=>1000},setTimeout,clearTimeout,console};
 vm.runInNewContext(fs.readFileSync(path.join(__dirname,'../Fusion/Web/ios-media.js'),'utf8'),sandbox);
 const media=new win.IOSMedia('A',(op,args)=>{calls.push({op,args});return handler?handler(op,args):Promise.resolve({ok:true});});return {media,calls,win};
}
test('native adapter never seeks when opening at zero delay',async()=>{
 const {media,calls}=setup();await media.open('https://x.bilivideo.com/a.m3u8');await media.play();assert.deepEqual(calls.map(c=>c.op),['mediaOpen','mediaPlay']);
});
test('native adapter ignores stale generation and closes exact player token',async()=>{
 const {media,calls,win}=setup();await media.open('https://x.bilivideo.com/a.m3u8');const old=media.token;
 media.removeAttribute('src');await media.open('https://x.bilivideo.com/b.m3u8');
 win.iosMediaState({A:{token:old,currentTime:999,rate:1,readyState:4,paused:false}});assert.equal(media.currentTime,0);
 assert.equal(calls.find(c=>c.op==='mediaClose').args.token,old);
});
test('native adapter applies volume independently and reports seek',async()=>{
 const {media,calls}=setup();await media.open('https://x.bilivideo.com/a.m3u8');media.volume=.35;
 await new Promise(r=>setTimeout(r,100));assert.equal(calls.at(-1).op,'mediaVolume');assert.equal(calls.at(-1).args.volume,.35);assert.equal(calls.at(-1).args.source,'A');
 media.currentTime=12;assert.equal(calls.at(-1).op,'mediaSeek');assert.equal(calls.at(-1).args.time,12);
});
test('audio-only mode persists through opening without seeking or restarting',async()=>{
 const {media,calls}=setup();media.audioOnly=true;await media.open('https://x.bilivideo.com/a.m3u8');
 assert.equal(calls[0].args.audioOnly,true);media.audioOnly=false;
 assert.equal(calls.at(-1).op,'mediaAudioOnly');assert.equal(calls.at(-1).args.value,false);
 assert.equal(calls.filter(c=>c.op==='mediaOpen').length,1);assert.equal(calls.filter(c=>c.op==='mediaSeek').length,0);
});
test('downloaded ranges and pending seek are independent of a far-ahead seekable window',async()=>{
 let done;const {media,win}=setup(op=>op==='mediaSeek'?new Promise(resolve=>done=resolve):Promise.resolve({ok:true}));
 await media.open('https://x.bilivideo.com/a.m3u8');
 const state={token:media.token,currentTime:10,rate:1,readyState:4,paused:false,seeking:false,ranges:[[0,100]],loaded:[[0,12]]};
 win.iosMediaState({A:state});assert.equal(media.buffered.end(0),12);
 media.currentTime=5;win.iosMediaState({A:{...state,currentTime:10,seeking:false}});
 assert.equal(media.seeking,true);assert.equal(media.currentTime,5);
 done({state:{...state,currentTime:5,seeking:false}});await new Promise(r=>setTimeout(r,0));assert.equal(media.seeking,false);assert.ok(media.currentTime>=5&&media.currentTime<5.1);
});
test('a late seek failure from a replaced player cannot poison its successor',async()=>{
 let fail,errors=0;const {media}=setup(op=>op==='mediaSeek'?new Promise((resolve,reject)=>fail=reject):Promise.resolve({ok:true}));
 await media.open('https://x.bilivideo.com/a.m3u8');media.onseekerror=()=>errors++;media.currentTime=5;
 media.removeAttribute('src');await media.open('https://x.bilivideo.com/b.m3u8');fail(Error('old seek'));await new Promise(r=>setTimeout(r,0));assert.equal(errors,0);assert.equal(media.seeking,false);
});

test('network waiting freezes presentation clock and emits once, then original item resumes without open/seek/play RPC',async()=>{
 const {media,calls,win}=setup();await media.open('https://x.bilivideo.com/a.m3u8');let waiting=0,playing=0;
 media.onwaiting=()=>waiting++;media.onplaying=()=>playing++;
 const token=media.token,base={token,currentTime:15,rate:1,readyState:4,paused:false,seeking:false,loaded:[[10,18]]};
 win.iosMediaState({A:base});assert.equal(playing,1);
 const buffered={...base,rate:0,readyState:2,waiting:true};win.iosMediaState({A:buffered});win.iosMediaState({A:buffered});
 assert.equal(media.currentTime,15);assert.equal(media.waiting,true);assert.equal(waiting,1);
 win.iosMediaState({A:{...base,currentTime:15.1,waiting:false}});assert.equal(playing,2);assert.equal(media.waiting,false);
 assert.equal(media.token,token);assert.deepEqual(calls.map(c=>c.op),['mediaOpen']);
});

test('initial buffer wait is visible but explicit pause and pending seek are never mistaken for starvation',async()=>{
 const {media,win}=setup();await media.open('https://x.bilivideo.com/a.m3u8');let waits=0;media.onwaiting=()=>waits++;
 win.iosMediaState({A:{token:media.token,currentTime:0,rate:0,readyState:2,paused:false,waiting:true}});
 assert.equal(waits,1);assert.equal(media.waiting,true);
 win.iosMediaState({A:{token:media.token,currentTime:0,rate:0,readyState:2,paused:true,waiting:false}});
 assert.equal(media.waiting,false);assert.equal(waits,1);
 win.iosMediaState({A:{token:media.token,currentTime:0,rate:0,readyState:2,paused:false,seeking:true,waiting:true}});
 assert.equal(media.waiting,false);assert.equal(waits,1);
});
