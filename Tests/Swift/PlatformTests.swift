import XCTest
@testable import Fusion
final class PlatformTests:XCTestCase {
 func testRoomAndOfficialHostValidation()throws {
  XCTAssertEqual(try PlatformRoom.id("huya","https://www.huya.com/102411"),"102411")
  XCTAssertEqual(try PlatformRoom.id("douyu","https://www.douyu.com/93589?x=1"),"93589")
  for url in ["https://www.huya.com.evil.test/6","http://www.huya.com/6","https://user@www.huya.com/6","https://www.huya.com:444/6"]{XCTAssertThrowsError(try PlatformRoom.id("huya",url))}
  for host in ["x.huya.com","x.msstatic.com","x.douyucdn.cn"]{XCTAssertTrue(Safety.media(URL(string:"https://"+host+"/a")!))}
  for host in ["huya.com.evil.test","evil.test","127.0.0.1"]{XCTAssertFalse(Safety.media(URL(string:"https://"+host+"/a")!))}
 }
 func testBalancedJSONAndDouyuFrames()throws {
  let result=try PlatformRoom.object("HNF_GLOBAL_INIT = {\"a\":\"brace } inside\",\"room\":{\"id\":6}};junk",after:"HNF_GLOBAL_INIT")
  XCTAssertEqual(result.obj("room").int("id"),6)
  var pending=Data(),bytes=DouyuWire.encode("type@=chatmsg/txt@=a@Sb@Ac/nn@=名字/uid@=2/")
  let first=try DouyuWire.decode(&pending,bytes.prefix(6));XCTAssertTrue(first.isEmpty)
  bytes.removeFirst(6);let messages=try DouyuWire.decode(&pending,bytes)
  XCTAssertEqual(messages[0]["txt"],"a/b@c");XCTAssertEqual(messages[0]["nn"],"名字");XCTAssertTrue(pending.isEmpty)
  XCTAssertThrowsError(try DouyuWire.decode(&pending,Data(repeating:0,count:16)))
 }
 func testHuyaShareAndSparsePlaybackMetadata()throws {
  XCTAssertEqual(try PlatformRoom.huyaShare(" https://hy.fan/BbuMBsd ")?.absoluteString,"https://hy.fan/BbuMBsd")
  XCTAssertNil(try PlatformRoom.huyaShare("660000"))
  for bad in ["https://hy.fan/a?target=https://evil.test","https://hy.fan/a#x","https://hy.fan/u/extra","https://hy.fan/a%2fb"]{XCTAssertThrowsError(try PlatformRoom.huyaShare(bad))}
  for marker in ["stream:","stream : ","\"stream\" : ","'stream':"]{XCTAssertEqual(try PlatformRoom.huyaWebStream("var hyPlayerConfig={"+marker+"{\"test\":2}};").int("test"),2)}
  let good:JSON=["sStreamName":"stream_A-1","sFlvUrl":"http://tx.flv.huya.com/src","lChannelId":42]
  let bad:JSON=["sStreamName":"bad","sFlvUrl":"https://huya.com.evil.test/src"]
  let tail:[JSON]=[bad,good,good,["sStreamName":"other","sFlvUrl":"https://al-game.flv.huya.com/src"]]
  let lines=PlatformRoom.huyaLines(["data":[["missing":true],["gameStreamInfoList":tail]] as [JSON]])
  XCTAssertEqual(lines.count,2);XCTAssertEqual(lines[0].str("sStreamName"),"stream_A-1")
  XCTAssertTrue(PlatformRoom.huyaLines([:]).isEmpty)
 }
 func testHuyaCDNRedirectIsBoundedAndDoesNotExportLoginHeaders(){
  var original=URLRequest(url:URL(string:"https://al.flv.huya.com/src/a.flv?fixture=1")!)
  original.setValue("fixture-HYSDK",forHTTPHeaderField:"User-Agent");original.setValue("https://www.huya.com/",forHTTPHeaderField:"Referer");original.setValue("https://www.huya.com",forHTTPHeaderField:"Origin")
  original.setValue("never-forward",forHTTPHeaderField:"Cookie");original.setValue("never-forward",forHTTPHeaderField:"Authorization")
  let target=URL(string:"https://2409_8c28_90a0_208__55.bytefcdnrd.com/src/a.flv")!
  let next=PlatformRoom.huyaRedirect(original,to:target,count:0)
  XCTAssertEqual(next?.url,target);XCTAssertEqual(next?.value(forHTTPHeaderField:"User-Agent"),"fixture-HYSDK")
  XCTAssertNil(next?.value(forHTTPHeaderField:"Cookie"));XCTAssertNil(next?.value(forHTTPHeaderField:"Authorization"))
  XCTAssertNil(PlatformRoom.huyaRedirect(original,to:target,count:3))
  for bad in ["http://x.huya.com/a.flv","https://huya.com.evil.test/a.flv","https://unrelated.tbcache.com/a.flv","https://user@x.huya.com/a.flv","https://x.huya.com:444/a.flv"]{XCTAssertNil(PlatformRoom.huyaRedirect(original,to:URL(string:bad),count:0))}
  original.url=URL(string:"https://x.douyucdn.cn/a.flv")!;XCTAssertNil(PlatformRoom.huyaRedirect(original,to:target,count:0))
 }
 @MainActor func testOfficialSigningRunsLocallyWithoutAppBridge()async throws {
  let signer=PlaybackSigner()
  let result=try await signer.sign("function ub98484234(room,did,time){return room+'|'+(typeof window)+'|'+(typeof document)+'|'+(typeof Native)+'|'+CryptoJS.MD5('fixture').toString();}",room:"6")
  XCTAssertEqual(result,"6|undefined|undefined|undefined|"+PlatformRoom.md5("fixture"))
 }

 func testHuyaTarsBoundsAndRoundtrip()throws {
  let data=Tars.Writer().number(0,-129).number(1,9_876_543_210).string(2,"名字").bytes(3,Data([1,2,3])).structure(4,Tars.Writer().number(0,0)).map(5,["tRsp":Data([4,5])]).data
  let fields=try Tars.read(data);XCTAssertEqual(fields[0] as? Int64,-129);XCTAssertEqual(fields[1] as? Int64,9_876_543_210);XCTAssertEqual(fields[2] as? String,"名字");XCTAssertEqual(fields[3] as? Data,Data([1,2,3]));XCTAssertEqual((fields[4] as? [Int:Any])?[0] as? Int64,0)
  XCTAssertThrowsError(try Tars.read(Data([0x37,0xff,0xff,0xff,0xff])))
  XCTAssertThrowsError(try Tars.read(Data(repeating:0,count:2*1024*1024+1)))
 }

 func testPiPMergingAndPlatformScopedBlocking(){
  var s=PiPMessageStore();s.platform="douyu";s.mergeSame=true
  for id in ["1","2"] {s.receive(["cmd":"DANMU_MSG","info":[[],"同句",[id,"观众"]]],edge:10)}
  s.receive(["cmd":"DANMU_MSG","info":[[],"同句！",["3","观众"]]],edge:10)
  var visible=s.visible(time:11,edge:11,rows:5,chat:true,sc:false);XCTAssertEqual(visible.count,2);XCTAssertEqual(visible[0].mergeCount,2)
  s.setBlocking(["users":[["platform":"bilibili","uid":"1"]]]);XCTAssertEqual(s.items.count,3)
  s.setBlocking(["users":[["platform":"douyu","uid":"1"]]]);visible=s.visible(time:11,edge:11,rows:5,chat:true,sc:false);XCTAssertEqual(visible[0].mergeCount,1)
 }
}

