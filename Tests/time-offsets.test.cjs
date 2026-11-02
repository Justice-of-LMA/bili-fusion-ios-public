const {test}=require('node:test'),assert=require('node:assert/strict');
const F=require('../Fusion/Web/time-offsets.js');
test('signed basis excludes disabled C and rejects an impossible sixty-second span',()=>{
 assert.deepEqual(F.normalize({A:-3.2,B:-1.2,C:0},{A:true,B:true,C:true}),{A:0,B:2,C:3.2});
 assert.deepEqual(F.normalize({A:0,B:2,C:-60},{A:true,B:true,C:false}),{A:0,B:2,C:0});
 assert.throws(()=>F.normalize({A:-60,B:1,C:0},{A:true,B:true,C:false}));
});
const media=end=>({currentTime:40,buffered:{length:1,start:()=>30,end:()=>end}});
test('adjusting an existing delay hold never invents a second pause or seeks through missing buffer',()=>{
 assert.deepEqual(F.transition(media(60),5,1,4),{seek:null,hold:0});
 assert.deepEqual(F.transition(media(60),5,0,3),{seek:42,hold:0});
 assert.throws(()=>F.transition(media(41),5,0,3));
 assert.deepEqual(F.transition(media(60),0,20),{seek:30.1,hold:10.1});
});
