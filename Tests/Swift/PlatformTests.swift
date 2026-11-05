import XCTest
import Network
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
 func testDouyuAliasMustMatchVIPAndIsNeverEvaluated()throws{
  let data="0:[\"$\",\"room\",{\"roomInfo\":{\"room\":{\"room_id\":6979222,\"vipId\":6657}}}]"
  let frame=try JSONSerialization.data(withJSONObject:[1,data]),html="<script>self.__next_f.push("+String(data:frame,encoding:.utf8)!+")</script>"
  XCTAssertEqual(PlatformRoom.douyuRoomAlias(html,"6657"),"6979222");XCTAssertNil(PlatformRoom.douyuRoomAlias(html,"12306"))
  XCTAssertNil(PlatformRoom.douyuRoomAlias("<script>alert(1)</script>","6657"))
 }
 func testDouyuMediaRedirectKeepsMediaHeadersAndDropsCredentials(){
  var request=URLRequest(url:URL(string:"https://a.douyucdn.cn/live/a.flv")!);request.httpMethod="GET"
  request.setValue("bytes=0-",forHTTPHeaderField:"Range");request.setValue("fixture",forHTTPHeaderField:"Cookie");request.setValue("Bearer fixture",forHTTPHeaderField:"Authorization")
  let next=PlatformRoom.douyuRedirect(request,to:URL(string:"https://b.douyucdn2.cn/live/a.flv"),count:0)
  XCTAssertNotNil(next);XCTAssertEqual(next?.value(forHTTPHeaderField:"Range"),"bytes=0-");XCTAssertNil(next?.value(forHTTPHeaderField:"Cookie"));XCTAssertNil(next?.value(forHTTPHeaderField:"Authorization"))
  for target in ["http://b.douyucdn.cn/a.flv","https://douyucdn.cn.evil.test/a.flv","https://127.0.0.1/a.flv"]{XCTAssertNil(PlatformRoom.douyuRedirect(request,to:URL(string:target),count:0))}
  XCTAssertNil(PlatformRoom.douyuRedirect(request,to:URL(string:"https://b.douyucdn.cn/a.flv"),count:3))
 }
 func testDouyuFLVBytePipeFollowsObserved2561707CDNRedirect(){
  let initial=URL(string:"https://huos3a.douyucdn2.cn/live/fixture.flv?sign=fixture")!
  let target=URL(string:"https://2409_8c44_2_ff03_8000_0_b00_179.bytefcdnrd.com/live/fixture.flv?sign=fixture")!
  var request=URLRequest(url:initial);request.httpMethod="GET"
  request.setValue("https://www.douyu.com/",forHTTPHeaderField:"Referer")
  request.setValue("bytes=0-",forHTTPHeaderField:"Range")
  request.setValue("private",forHTTPHeaderField:"Cookie")
  request.setValue("Bearer private",forHTTPHeaderField:"Authorization")
  let pipe=MediaBytePipe(connection:NWConnection(host:"127.0.0.1",port:9,using:.tcp),request:request)
  let session=URLSession(configuration:.ephemeral),task=session.dataTask(with:request)
  defer{session.invalidateAndCancel()}
  let response=HTTPURLResponse(url:initial,statusCode:302,httpVersion:nil,headerFields:["Location":target.absoluteString])!
  var next:URLRequest?
  pipe.urlSession(session,task:task,willPerformHTTPRedirection:response,newRequest:URLRequest(url:target)){next=$0}
  XCTAssertEqual(next?.url,target,"A real Douyu CDN redirect must not become an HTTP 302 playback failure")
  XCTAssertEqual(next?.value(forHTTPHeaderField:"Referer"),"https://www.douyu.com/")
  XCTAssertEqual(next?.value(forHTTPHeaderField:"Range"),"bytes=0-")
  XCTAssertNil(next?.value(forHTTPHeaderField:"Cookie"));XCTAssertNil(next?.value(forHTTPHeaderField:"Authorization"))
  for denied in ["http://cdn.bytefcdnrd.com/a.flv","https://bytefcdnrd.com.evil.test/a.flv","https://127.0.0.1/a.flv","https://user@cdn.bytefcdnrd.com/a.flv","https://cdn.bytefcdnrd.com:444/a.flv"]{
   XCTAssertNil(PlatformRoom.douyuRedirect(request,to:URL(string:denied),count:0))
  }
  XCTAssertNil(PlatformRoom.douyuRedirect(request,to:target,count:3))
  var unrelated=request;unrelated.url=URL(string:"https://cdn.bilivideo.com/a.flv")!
  XCTAssertNil(PlatformRoom.douyuRedirect(unrelated,to:target,count:0),"This change must stay scoped to a Douyu source")
 }
 @MainActor func testDouyuPlaylistRedirectUsesFinalCDNWithoutRetry()async throws{
  let initial=URL(string:"https://huos3a.douyucdn2.cn/live/fixture.m3u8")!
  let target=URL(string:"https://cdn.bytefcdnrd.com/live/fixture.m3u8")!
  var requests=[URLRequest]()
  let proxy=MediaProxy{request,_ in
   requests.append(request)
   if request.url==initial{return(Data(),HTTPURLResponse(url:initial,statusCode:302,httpVersion:nil,headerFields:["Location":target.absoluteString])!)}
   return(Data("#EXTM3U\n#EXT-X-VERSION:3\n".utf8),HTTPURLResponse(url:target,statusCode:200,httpVersion:nil,headerFields:nil)!)
  }
  var request=URLRequest(url:initial);request.httpMethod="GET";request.setValue("https://www.douyu.com/",forHTTPHeaderField:"Referer")
  let result=try await proxy.fetchMedia(request,limit:8192)
  XCTAssertEqual(requests.map{$0.url!},[initial,target]);XCTAssertEqual(result.1.url,target)
  XCTAssertTrue(String(data:result.0,encoding:.utf8)!.hasPrefix("#EXTM3U"))
  XCTAssertTrue(requests.allSatisfy{$0.value(forHTTPHeaderField:"Cookie")==nil})
 }

 @MainActor func testHuyaHLSAndHEADFollowSharedCDNAndRetainSegmentOrigin()async throws{
  let initial=URL(string:"https://tx.hls.huya.com/live/fixture.m3u8")!
  let final=URL(string:"https://2409_8c20_a17_119__85.bytefcdnrd.com/live/fixture.m3u8")!
  let segment=final.deletingLastPathComponent().appendingPathComponent("segment.ts")
  var requests=[URLRequest]()
  let proxy=MediaProxy{request,_ in
   requests.append(request);let url=request.url!
   if url==initial{return(Data(),HTTPURLResponse(url:initial,statusCode:302,httpVersion:nil,headerFields:["Location":final.absoluteString])!)}
   if url==final{return(Data("#EXTM3U\n#EXTINF:1,\nsegment.ts\n".utf8),HTTPURLResponse(url:final,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"application/vnd.apple.mpegurl"])!)}
   XCTAssertEqual(url,segment)
   return(Data([1,2,3]),HTTPURLResponse(url:url,statusCode:200,httpVersion:nil,headerFields:nil)!)
  }
  try await proxy.start();defer{proxy.stop()}
  let local=try proxy.register(initial,owner:proxy.begin("B",token:"huya-fixture"))
  var head=URLRequest(url:local);head.httpMethod="HEAD"
  let (_,headResponse)=try await URLSession.shared.data(for:head)
  XCTAssertEqual((headResponse as? HTTPURLResponse)?.statusCode,200)
  XCTAssertTrue(requests.prefix(2).allSatisfy{$0.httpMethod=="HEAD"},"HEAD must not turn into an unbounded FLV GET")
  let (playlist,response)=try await URLSession.shared.data(from:local)
  XCTAssertEqual((response as? HTTPURLResponse)?.statusCode,200)
  let part=String(decoding:playlist,as:UTF8.self).split(separator:"\n").last!
  let (data,_)=try await URLSession.shared.data(from:URL(string:String(part))!)
  XCTAssertEqual(data,Data([1,2,3]))
  XCTAssertEqual(requests.count,5,"Only the requested redirect chains and segment may be fetched")
  XCTAssertTrue(requests.allSatisfy{$0.value(forHTTPHeaderField:"Referer")=="https://www.huya.com/"})
  XCTAssertTrue(requests.allSatisfy{$0.value(forHTTPHeaderField:"User-Agent")?.hasPrefix("HYSDK")==true})
 }
 @MainActor func testSharedCDNSegmentDoesNotMixDouyuAndBiliHeaders()async throws{
  let shared=URL(string:"https://cdn.bytefcdnrd.com/live/shared.ts")!
  var referers=[String]()
  let proxy=MediaProxy{request,_ in
   referers.append(request.value(forHTTPHeaderField:"Referer") ?? "")
   return(Data([1,2,3]),HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!)
  }
  try await proxy.start();defer{proxy.stop()}
  let a=try proxy.register(shared,owner:"same-fixture",platform:"bilibili")
  let b=try proxy.register(shared,owner:"same-fixture",platform:"douyu")
  XCTAssertNotEqual(a,b,"A shared CDN URL must not merge platform-specific request contexts")
  _ = try await URLSession.shared.data(from:a);_ = try await URLSession.shared.data(from:b)
  XCTAssertEqual(referers,["https://live.bilibili.com/","https://www.douyu.com/"])
 }

}

