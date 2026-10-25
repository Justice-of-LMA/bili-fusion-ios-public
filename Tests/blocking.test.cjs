const {test}=require('node:test'),assert=require('node:assert/strict'),F=require("../Fusion/Web/blocking.js");
test('user ID matching is scoped to platform and survives nickname changes',()=>{
 const r=F.addUser(F.normalize(),{uid:'123',user:'原昵称'},'bilibili');
 assert.ok(F.matches(r,{uid:'123',user:'新昵称'},'bilibili'));
 assert.equal(F.matches(r,{uid:'124',user:'原昵称'},'bilibili'),false);
 assert.equal(F.matches(r,{uid:'123',user:'原昵称'},'huya'),false);
});
test('missing or zero ID never blocks every anonymous message; nickname fallback is exact',()=>{
 const r=F.addUser(F.normalize(),{uid:0,user:'小明'},'douyu');
 assert.equal(r.users[0].uid,'');
 assert.ok(F.matches(r,{uid:0,user:'小明'},'douyu'));
 assert.equal(F.matches(r,{uid:0,user:'小红'},'douyu'),false);
 assert.equal(F.matches(r,{user:'小明2'},'douyu'),false);
 assert.equal(F.matches(r,{user:'小明'},'bilibili'),false);
});
test('literal substring keywords cover chat and SC, not deletion events',()=>{
 const r=F.normalize({keywords:['广告','a.B','[链接]']});
 assert.ok(F.matches(r,{type:'chat',text:'这里有广告'}));
 assert.ok(F.matches(r,{type:'sc',text:'AA.BC'}));
 assert.equal(F.matches(r,{text:'axB'}),false);
 assert.equal(F.matches(r,{type:'delete',text:'广告'}),false);
 assert.equal(F.matches(r,null),false);
});
test('malformed and huge rules are safely bounded and deduplicated',()=>{
 assert.deepEqual(F.normalize(null),{users:[],keywords:[],exactTexts:[]});
 assert.deepEqual(F.normalize({users:[null,4,false,{}, {uid:'0'}, {uid:'<bad>',name:'正常'}],keywords:[null,{},4,' ', 'a','a']}),{users:[{platform:'bilibili',uid:'',name:'正常'}],keywords:['a'],exactTexts:[]});
 assert.equal(F.normalize({users:Array.from({length:550},(_,i)=>({uid:String(i+1)})),keywords:Array.from({length:230},(_,i)=>'词'+i)}).users.length,500);
 assert.equal(F.normalize({keywords:Array.from({length:230},(_,i)=>'词'+i)}).keywords.length,200);
 const max=F.normalize({users:Array.from({length:500},(_,i)=>({uid:String(i+1),name:'💛'.repeat(100)})),keywords:Array.from({length:200},(_,i)=>i+'💛'.repeat(100))});
 assert.ok(Buffer.byteLength(JSON.stringify({rules:max}))<524288);
});
test('complete text blocking preserves all characters',()=>{const r=F.normalize({exactTexts:['第一',' a ','第一']});assert.ok(F.matches(r,{text:'第一'}));for(const text of ['第一名',' 第一','第一!','a',' A '])assert.equal(F.matches(r,{text}),false);assert.ok(F.matches(r,{text:' a '}));assert.equal(r.exactTexts.length,2);});

