const {test}=require('node:test');const assert=require('node:assert/strict');
const C=require('../Fusion/Web/core.js');
test('area and maximum rows jointly constrain A viewport, including small screens',()=>{
  assert.equal(C.laneCount(400,20,50,4),4);
  assert.equal(C.laneCount(400,20,25,20),2);
  assert.equal(C.laneCount(400,20,100,20),11);
  assert.equal(C.laneCount(400,20,100,1),1);
  assert.equal(C.laneCount(205,22,25,8),1);
  assert.equal(C.laneCount(80,32,25,20),0);
});
test('selected area stays exact and capped rows spread across its full height',()=>{
  for(const height of [80,205,390,600,768,1024])for(const size of [14,20,22,32])for(const area of [25,50,75,100])for(const limit of [1,4,8,11,20]){
    const p=C.laneLayout(height,size,area,limit);
    assert.equal(p.height,height*area/100);assert.ok(p.count<=limit);
    assert.equal(p.tops.length,p.count);
    for(let i=0;i<p.count;i++){assert.ok(p.tops[i]>=8);assert.ok(p.tops[i]+p.rowHeight<=p.height-3+1e-8);if(i)assert.ok(p.tops[i]-p.tops[i-1]>=size*1.7-1e-8);}
    if(p.count>1)assert.ok(Math.abs(p.tops.at(-1)+p.rowHeight+3-p.height)<1e-8);
  }
  const p=C.laneLayout(600,20,75,8);
  assert.equal(p.height,450);assert.equal(p.count,8);assert.equal(p.tops.at(-1)+p.rowHeight,447);
});
test('sparse single-source messages rotate over all rows without changing the region',()=>{
  const lanes=new C.Lanes(4,100);
  assert.deepEqual([0,20,40,60,80].map(t=>lanes.enter(40,600,t).lane),[0,1,2,3,0]);
  lanes.reset(2);assert.equal(lanes.enter(40,600,0).lane,0);assert.equal(lanes.enter(40,600,0).lane,1);assert.equal(lanes.enter(40,600,0),null);
  lanes.reset(0);assert.equal(lanes.enter(40,600,100),null);
});
test('emoji URL allowlist and protocol normalization',()=>{
  assert.equal(C.imageUrl('http://i0.hdslb.com/a.png'),'https://i0.hdslb.com/a.png');
  for(const u of ['https://hdslb.com.evil.test/a','javascript:alert(1)','https://u:p@i0.hdslb.com/a','http://127.0.0.1/a','https://i0.hdslb.com:8443/a'])assert.equal(C.imageUrl(u),'');
});
test('UP-specific emoji and text/image mixture stay structured',()=>{
  const b=new C.EmojiBook();b.learn({packages:[{emoticons:[{emoji:'[UP_生气]',url:'https://i0.hdslb.com/a.png',width:100,height:100}]}]});
  const parts=b.segments('前文[UP_生气]后文[未知表情]');
  assert.deepEqual(parts.map(s=>s.type),['text','emoji','text']);assert.equal(parts[2].value,'后文[未知表情]');
  assert.equal(b.segments('【UP_生气】')[0].type,'emoji');
});
test('single-image metadata is not printed again as text',()=>{
  const info=[[],'[UP专属_笑]',['1','测试用户']];info[0][13]={url:'https://i0.hdslb.com/up.png'};
  const m=C.normalize({cmd:'DANMU_MSG',info});assert.equal(m.segments.length,1);assert.equal(m.segments[0].type,'emoji');
});
test('inline extra mapping and repeated images',()=>{
  const info=[[],'[脸]很棒[脸]',['1','观众']];info[0][15]={extra:JSON.stringify({emots:{'[脸]':{url:'https://i0.hdslb.com/x.png'}}})};
  const m=C.normalize({cmd:'DANMU_MSG:4:0',info});assert.equal(m.segments.filter(s=>s.type==='emoji').length,2);
});
test('crawler removes only matching adjacent fallback, preserves unknown tokens',()=>{
  const parts=C.cleanSegments([{type:'emoji',url:'https://i0.hdslb.com/a',alt:'[UP表情_笑]'}, {type:'text',value:'[UP表情_笑]正文[其他表情]'}]);
  assert.equal(parts[1].value,'正文[其他表情]');
});
test('room emoji books are isolated',()=>{
  const a=new C.EmojiBook(),b=new C.EmojiBook();a.add('[脸]',{url:'https://i0.hdslb.com/a'});
  assert.equal(a.segments('[脸]')[0].type,'emoji');assert.equal(b.segments('[脸]')[0].type,'text');
});
test('SC expired snapshots do not restart, remaining life retained',()=>{
  const now=200000;
  assert.equal(C.normalize({cmd:'SUPER_CHAT_MESSAGE',data:{id:1,time:60,end_time:190}},new C.EmojiBook(),now),null);
  assert.equal(C.normalize({cmd:'SUPER_CHAT_MESSAGE',data:{id:1,time:60,end_time:220}},new C.EmojiBook(),now).duration,20);
});
test('SC follows media clock, source IDs isolated, deletes immediate',()=>{
  const a=new C.Timeline(),b=new C.Timeline(),m={type:'sc',id:'same',duration:30,totalDuration:30};
  a.add(m,10);b.add(m,20);
  assert.equal(a.cards(9).length,0);assert.equal(a.cards(10)[0].left,30);assert.equal(a.cards(15)[0].left,25);assert.equal(a.cards(15)[0].left,25);
  assert.equal(b.cards(15).length,0);a.add({type:'delete',ids:['same']},0);a.add(m,10);assert.equal(a.cards(20).length,0);assert.equal(b.cards(20).length,1);
});
test('SC local dismiss survives seeks and duplicate arrival',()=>{
  const q=new C.Timeline();q.add({type:'sc',id:'x',duration:30,totalDuration:30},1);q.dismiss('x');q.seek(0);
  assert.equal(q.cards(5).length,0);q.add({type:'sc',id:'x',duration:100,totalDuration:100},2);assert.equal(q.sc.size,1);
});
test('chat bounded, late backlog skipped, seek selects relevant events',()=>{
  const q=new C.Timeline();for(let i=0;i<1500;i++)q.add({type:'chat',text:String(i)},i);
  assert.equal(q.items.length,1200);const ready=q.drain(1499);assert.deepEqual(ready.map(m=>m.text),['1497','1498','1499']);assert.equal(q.drain(1499).length,0);
  q.seek(1498);assert.deepEqual(q.drain(1498).map(m=>m.text),['1498']);
});
test('zero delay does not seek or pause; increased delay uses real buffer',()=>{
  assert.deepEqual(C.delayAction(20,0,0,[[10,25]]),{seek:null,hold:0});
  assert.deepEqual(C.delayAction(20,0,3,[[10,25]]),{seek:17,hold:0});
  const x=C.delayAction(20,0,10,[[18,25]]);assert.ok(Math.abs(x.hold-8.1)<.001);assert.ok(Math.abs(x.seek-18.1)<.001);
  assert.ok(C.delayAction(20,0,100,[[18,25]]).hold<=20);
});
test('shared lanes reject a second room until tail clearance',()=>{
  const l=new C.Lanes(1,100);assert.equal(l.enter(100,600,0).lane,0);assert.equal(l.enter(50,600,.5),null);assert.equal(l.enter(50,600,1.4).lane,0);
});

test('bare emoji aliases never replace ordinary words across learned/inline maps',()=>{
  const b=new C.EmojiBook(),url='https://i0.hdslb.com/2233.png';
  for(const word of ['第一','生气','喜欢','加油','笑'])b.learn({emoji:'[2233娘_'+word+']',alt:word,text:word,aliases:[word],url});
  const text='第一名生气了，也喜欢加油和笑';
  assert.deepEqual(b.segments(text),[{type:'text',value:text}]);
  assert.equal(b.segments('第一[2233娘_第一]第一名')[1].type,'emoji');
  assert.deepEqual(b.segments('第一',null,{'第一':{url}}),[{type:'text',value:'第一'}]);
  assert.equal(b.segments('第一',{url})[0].type,'emoji');
  const parts=C.cleanSegments([{type:'emoji',url,alt:'第一'},{type:'text',value:'第一名是我[未知表情]'}]);
  assert.equal(parts[1].value,'第一名是我[未知表情]');
});
test('twenty seconds keeps audio/video/chat/SC on the same user-selected clock',()=>{
  assert.deepEqual(C.delayAction(50,0,20,[[0,60]]),{seek:30,hold:0});
  assert.deepEqual(C.delayAction(30,20,5,[[0,60]]),{seek:45,hold:0});
  const short=C.delayAction(5,0,20,[[0,5]]);
  assert.ok(short.hold>15&&short.hold<16);
  assert.deepEqual(C.delayAction(50,0,999,[[0,60]]),{seek:30,hold:0});
});

test('unbracketed platform metadata maps complete tags but never bare chat words',()=>{
 const book=new C.EmojiBook(),url='https://i0.hdslb.com/bfs/emote/test.png';
 for(const word of ['阴险','惊讶','花','妙','微笑','欢喜','第一'])book.learn({emoji:word,url});
 book.learn({'加油':{url}});
 const text='童站表情来咯[阴险][惊讶][花][妙][微笑][欢喜]';
 const parts=book.segments(text);
 assert.equal(parts.filter(p=>p.type==='emoji').length,6);
 assert.equal(parts[0].value,'童站表情来咯');
 assert.deepEqual(book.segments('第一名微笑着给他加油'),[{type:'text',value:'第一名微笑着给他加油'}]);
 assert.equal(book.segments('【微笑】')[0].type,'emoji');
 assert.equal(book.segments('[加油]')[0].type,'emoji');
 assert.deepEqual(book.segments('[未收录][微笑]后文').map(p=>p.type),['text','emoji','text']);
 assert.deepEqual(book.segments('[阴险[微笑]]').map(p=>p.type),['text','emoji','text']);
});
