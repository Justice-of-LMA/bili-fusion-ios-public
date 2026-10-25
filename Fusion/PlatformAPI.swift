import Foundation
import WebKit
import CryptoKit

enum PlatformRoom {
    static let desktopUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Version/18.0 Safari/605.1.15"
    static func id(_ platform: String, _ input: String) throws -> String {
        if platform == "bilibili" { return String(try Safety.room(input)) }
        guard ["huya","douyu"].contains(platform) else { throw FusionError("不支持的平台") }
        var value=input.trimmingCharacters(in:.whitespacesAndNewlines)
        if value.contains("://") {
            guard let u=URL(string:value),u.scheme=="https",u.user==nil,u.password==nil,u.port==nil||u.port==443,
                  ["www."+platform+".com","m."+platform+".com",platform+".com"].contains(u.host ?? "") else { throw FusionError("请使用所选平台的官方 HTTPS 房间链接") }
            value=u.path.trimmingCharacters(in:CharacterSet(charactersIn:"/"))
        }
        guard value.matches(platform=="huya" ? "^[A-Za-z0-9_-]{1,32}$" : "^[1-9][0-9]{0,15}$") else { throw FusionError("房间号无效") }
        return value
    }
    static func page(_ platform: String, _ id: String) -> URL { URL(string:"https://www."+platform+".com/"+id)! }
    static func huyaShare(_ input:String)throws->URL? {
        let value=input.trimmingCharacters(in:.whitespacesAndNewlines)
        guard value.hasPrefix("https://hy.fan/") else{return nil}
        guard let u=URL(string:value),u.scheme=="https",u.host=="hy.fan",u.user==nil,u.password==nil,u.port==nil||u.port==443,u.query==nil,u.fragment==nil,u.path.matches("^/[A-Za-z0-9]{1,40}$") else{throw FusionError("虎牙分享链接无效，请使用官方 https://hy.fan/ 短链接")};return u
    }
    static func huyaWebStream(_ html:String)throws->JSON {
        guard let config=html.range(of:"hyPlayerConfig"),let marker=html[config.lowerBound...].range(of:"(?:[\"']stream[\"']|\\bstream)\\s*:\\s*\\{",options:.regularExpression) else{throw FusionError("虎牙网页播放信息缺失，请在官方房间核实开播或验证状态")}
        return try object(String(html[marker.lowerBound...]),after:":")
    }
    static func huyaLines(_ web:JSON)->[JSON] {
        var result=[JSON](),seen=Set<String>()
        for group in web.arr("data").prefix(16) {for line in group.arr("gameStreamInfoList").prefix(32) {
            let name=line.str("sStreamName"),base=https(line.str("sFlvUrl"))
            guard name.matches("^[A-Za-z0-9_-]{1,300}$"),let url=URL(string:base+"/"+name+".flv"),Safety.media(url),let host=url.host,["huya.com","msstatic.com","mobgslb.tbcache.com"].contains(where:{Safety.inDomain(host,$0)}),seen.insert(url.absoluteString).inserted else{continue}
            result.append(line);if result.count>=16{return result}
        }};return result
    }
    static func huyaRedirect(_ original:URLRequest,to target:URL?,count:Int)->URLRequest? {
        guard count<3,let initial=original.url?.host,["huya.com","msstatic.com","mobgslb.tbcache.com"].contains(where:{Safety.inDomain(initial,$0)}),original.url?.path.lowercased().contains(".flv")==true,
              let target,Safety.media(target),let host=target.host,["huya.com","msstatic.com","mobgslb.tbcache.com","bytefcdnrd.com"].contains(where:{Safety.inDomain(host,$0)}) else{return nil}
        var redirected=URLRequest(url:target);redirected.httpMethod="GET"
        for header in ["User-Agent","Referer","Origin","Range","Accept-Encoding"]{if let value=original.value(forHTTPHeaderField:header){redirected.setValue(value,forHTTPHeaderField:header)}}
        return redirected
    }
    static func object(_ text: String, after marker: String) throws -> JSON {
        guard let mark=text.range(of:marker),let start=text[mark.upperBound...].firstIndex(of:"{") else { throw FusionError("官方房间数据暂不可用") }
        var depth=0,quoted=false,escape=false
        for i in text[start...].indices { let c=text[i]
            if quoted { if escape { escape=false } else if c=="\\" { escape=true } else if c=="\"" { quoted=false } }
            else if c=="\"" { quoted=true } else if c=="{" { depth+=1 } else if c=="}" { depth-=1;if depth==0 { guard let d=String(text[start...i]).data(using:.utf8),let json=try JSONSerialization.jsonObject(with:d) as? JSON else { break };return json } }
        };throw FusionError("官方房间数据不完整")
    }
    static func https(_ s: String) -> String { s.hasPrefix("//") ? "https:"+s : s.replacingOccurrences(of:"^http://",with:"https://",options:.regularExpression) }
    static func md5(_ s: String) -> String { Insecure.MD5.hash(data:Data(s.utf8)).map { String(format:"%02x",$0) }.joined() }
    static func anti(_ stream: String, uid: UInt64, raw: String, now: UInt64 = UInt64(Date().timeIntervalSince1970*1000)) throws -> String {
        var c=URLComponents();c.percentEncodedQuery=raw
        let q=Dictionary((c.queryItems ?? []).map { ($0.name,$0.value ?? "") },uniquingKeysWith: {a,_ in a})
        guard let fm=q["fm"] else { return raw }
        guard let data=Data(base64Encoded:fm),let decoded=String(data:data,encoding:.utf8),let prefix=decoded.split(separator:"_").first,let time=q["wsTime"] else { throw FusionError("虎牙播放校验不完整") }
        let t=q["t"] ?? "0",type=q["ctype"] ?? "huya_pc_exe",seq=uid+now
        let rotated=(uid & ~UInt64(0xffffffff)) | (((uid<<8)|(uid>>24)) & 0xffffffff),use=t=="103" ? uid : rotated
        let secret=md5("\(prefix)_\(use)_\(stream)_\(md5("\(seq)|\(type)|\(t)"))_\(time)")
        return "wsSecret=\(secret)&wsTime=\(time)&seqid=\(seq)&ctype=\(Safety.encoded(type))&ver=1&fs=\(q["fs"] ?? "")&t=\(t)&\(t=="103" ? "uid":"u")=\(use)"
    }
}
@MainActor final class PlatformAPI {
    private let signer = PlaybackSigner()
    func request(_ url: URL, body: String? = nil, rawBody:Data?=nil, ua: String = PlatformRoom.desktopUA) async throws -> Data {
        guard url.scheme=="https",let host=url.host,url.user==nil,url.password==nil,url.port==nil||url.port==443,["huya.com","douyu.com"].contains(where:{Safety.inDomain(host,$0)}) else { throw FusionError("平台接口来源无效") }
        var r=URLRequest(url:url);r.setValue(ua,forHTTPHeaderField:"User-Agent");r.setValue("https://www.\(Safety.inDomain(host,"huya.com") ? "huya":"douyu").com/",forHTTPHeaderField:"Referer")
        let all=await withCheckedContinuation { c in WKWebsiteDataStore.default().httpCookieStore.getAllCookies { c.resume(returning:$0) } }
        let valid=all.filter { cookie in let d=cookie.domain.trimmingCharacters(in:CharacterSet(charactersIn:".")),root=Safety.inDomain(host,"huya.com") ? "huya.com":"douyu.com";return Safety.inDomain(d,root) && (cookie.domain.hasPrefix(".") ? Safety.inDomain(host,d) : host==d) && url.path.hasPrefix(cookie.path) && (cookie.expiresDate==nil||cookie.expiresDate!>Date()) }
        if !valid.isEmpty { r.setValue(HTTPCookie.requestHeaderFields(with:valid)["Cookie"],forHTTPHeaderField:"Cookie") }
        if let body { r.httpMethod="POST";r.setValue("application/x-www-form-urlencoded",forHTTPHeaderField:"Content-Type");r.httpBody=Data(body.utf8) }
        if let rawBody{r.httpMethod="POST";r.httpBody=rawBody;r.setValue("application/x-wup",forHTTPHeaderField:"Content-Type")}
        let (data,response)=try await HTTP.shared.fetch(r,limit:4*1024*1024)
        guard response.statusCode==200 else { throw FusionError("平台 HTTP \(response.statusCode)，请在账号页面验证后手动重试") }
        for cookie in HTTPCookie.cookies(withResponseHeaderFields:response.allHeaderFields.reduce(into:[String:String]()){if let k=$1.key as? String,let v=$1.value as? String{$0[k]=v}},for:url) {
            let d=cookie.domain.trimmingCharacters(in:CharacterSet(charactersIn:"."));if Safety.inDomain(d,Safety.inDomain(host,"huya.com") ? "huya.com":"douyu.com") && (host==d||Safety.inDomain(host,d)) { await withCheckedContinuation { (c:CheckedContinuation<Void,Never>) in WKWebsiteDataStore.default().httpCookieStore.setCookie(cookie){c.resume()} } }
        }
        return data
    }
    func json(_ url: String, body: String? = nil) async throws -> JSON { guard let result=try JSONSerialization.jsonObject(with:await request(URL(string:url)!,body:body)) as? JSON else { throw FusionError("平台返回格式无效") };return result }
    func html(_ url: String, mobile: Bool = false) async throws -> String { guard let s=String(data:try await request(URL(string:url)!,ua:mobile ? Safety.ua : PlatformRoom.desktopUA),encoding:.utf8) else { throw FusionError("平台页面编码无效") };return s }
    private func huyaRoom(_ input:String)async throws->String {
        guard let url=try PlatformRoom.huyaShare(input) else{return try PlatformRoom.id("huya",input)}
        // A single explicitly requested share lookup, with no login state or automatic redirect following.
        var r=URLRequest(url:url);r.httpMethod="HEAD";r.setValue(PlatformRoom.desktopUA,forHTTPHeaderField:"User-Agent")
        let (_,response)=try await HTTP.shared.fetch(r,limit:8192)
        guard [301,302,303,307,308].contains(response.statusCode),let target=response.value(forHTTPHeaderField:"Location"),target.hasPrefix("https://") else{throw FusionError("虎牙分享链接暂未提供官方 HTTPS 房间跳转，请直接输入房间号")}
        do{return try PlatformRoom.id("huya",target)}catch{throw FusionError("虎牙分享未跳转到受信任的官方直播间，请直接输入房间号")}
    }
    func preview(_ platform: String, _ input: String) async throws -> JSON {
        let id:String
        if platform=="huya"{id=try await huyaRoom(input)}else{id=try PlatformRoom.id(platform,input)}
        if platform=="douyu" { let r=try await json("https://www.douyu.com/betard/"+id).obj("room");guard r.int64("room_id")>0 else { throw FusionError("未找到斗鱼房间") };return ["platform":platform,"room":String(r.int64("room_id")),"name":r.str("owner_name"),"title":r.str("room_name"),"cover":PlatformRoom.https(r.str("room_pic")),"live":r.int("show_status")==1] }
        let root=try PlatformRoom.object(await html("https://m.huya.com/"+id,mobile:true),after:"HNF_GLOBAL_INIT"),info=root.obj("roomInfo"),r=info.obj("tLiveInfo")
        guard r.int64("lProfileRoom")>0 else { throw FusionError("未找到虎牙房间") }
        return ["platform":platform,"room":String(r.int64("lProfileRoom")),"name":info.obj("tProfileInfo").str("sNick"),"title":r.str("sIntroduction").isEmpty ? r.str("sRoomName"):r.str("sIntroduction"),"cover":PlatformRoom.https(r.str("sScreenshot")),"live":info.int("eLiveStatus")==2,"_huya":root]
    }
    private func huyaToken(_ stream:String)async throws->String{
        let all=await withCheckedContinuation{c in WKWebsiteDataStore.default().httpCookieStore.getAllCookies{c.resume(returning:$0)}}
        let selected=all.filter{cookie in let d=cookie.domain.trimmingCharacters(in:CharacterSet(charactersIn:"."));return Safety.inDomain(d,"huya.com") && (cookie.domain.hasPrefix(".") ? Safety.inDomain("www.huya.com",d):d=="www.huya.com") && (cookie.expiresDate==nil||cookie.expiresDate!>Date())}
        let cookies=HTTPCookie.requestHeaderFields(with:selected)["Cookie"] ?? "",uid=selected.first{$0.name=="udb_uid"}?.value ?? "",guid=selected.first{$0.name=="guid"}?.value ?? ""
        let user=Tars.Writer().number(0,Int64(uid) ?? 0).string(1,guid).string(2,"").string(3,"webh5&1.0.0&web").string(4,cookies).number(5,0).string(6,"").string(7,"")
        let payload=Tars.Writer().string(0,"").string(1,stream).number(2,0).structure(3,user).number(4,66)
        let data=try await request(URL(string:"https://wup.huya.com")!,rawBody:Tars.request("getCdnTokenInfoEx",payload))
        guard let token=try Tars.response(data)[0] as? String,!token.isEmpty,token.count<=8000 else{throw FusionError("虎牙未返回播放校验")};return token
    }
    func resolve(_ platform: String, _ input: String, quality: Int) async throws -> JSON {
        guard (0...100000).contains(quality) else { throw FusionError("画质参数无效") }
        var room=try await preview(platform,input);guard room["live"] as? Bool==true else { throw FusionError("该房间当前未开播") }
        let id=room.str("room");var sources=[JSON](),qualities=[JSON]()
        if platform=="huya" {
            let html=try await self.html("https://www.huya.com/"+id)
            let web=try PlatformRoom.huyaWebStream(html)
            qualities=web.arr("vMultiStreamInfo").compactMap { q in let rate=q.int("iBitRate"),label=q.str("sDisplayName");return rate>=0&&rate<100000 && !label.contains("HDR") ? ["qn":rate==0 ? 100000:rate,"label":label] : nil }
            guard !qualities.isEmpty else{throw FusionError("虎牙未提供画质列表，请在官方房间完成验证后手动重试")}
            let recommended=web.int("iWebDefaultBitRate")
            let selected=qualities.contains(where:{$0.int("qn")==quality}) && quality>0 ? quality : qualities.contains(where:{$0.int("qn")==recommended}) && recommended>0 ? recommended : qualities.filter{$0.int("qn")<100000}.map{$0.int("qn")}.max() ?? 100000
            let label=qualities.first{$0.int("qn")==selected}?.str("label") ?? "平台当前档位",rate=selected==100000 ? 0:selected
            let live=room.obj("_huya").obj("roomInfo").obj("tLiveInfo")
            let lines=PlatformRoom.huyaLines(web)
            guard let first=lines.first else{throw FusionError("虎牙未提供可用的 HTTPS FLV 线路，请在官方房间核实权限后手动重试")}
            let name=first.str("sStreamName"),raw=try await huyaToken(name)
            for line in lines where line.str("sStreamName")==name {
                let uid=line.int64("lChannelId")>0 ? line.int64("lChannelId"):live.int64("lYyid")
                guard uid>0 else{throw FusionError("虎牙播放签名缺少频道信息，请反馈房间号")}
                let anti=try PlatformRoom.anti(name,uid:UInt64(uid),raw:raw)
                let rawURL=PlatformRoom.https(line.str("sFlvUrl"))+"/"+name+".flv?"+anti+"&codec=264"+(rate>0 ? "&ratio=\(rate)":"")
                if let url=URL(string:rawURL),Safety.media(url) { sources.append(["url":url.absoluteString,"type":"flv","quality":selected,"qualityLabel":label]) }
            }
        } else {
            let script=try await json("https://www.douyu.com/swf_api/homeH5Enc?rids="+id).obj("data").str("room"+id)
            let signed=try await signer.sign(script,room:id)
            let result=try await json("https://www.douyu.com/lapi/live/getH5Play/"+id,body:signed+"&cdn=&rate=\(quality)&ver=Douyu_223061205&iar=1&ive=1&hevc=0&fa=0")
            guard result.int("error")==0 else { throw FusionError("斗鱼取流失败："+result.str("msg")) }
            let d=result.obj("data"),rate=d.int("rate")
            qualities=d.arr("multirates").map{["qn":$0.int("rate"),"label":$0.str("name")] as JSON}
            let address=PlatformRoom.https(d.str("rtmp_url")+"/"+d.str("rtmp_live")).replacingOccurrences(of:"&amp;",with:"&")
            if let u=URL(string:address),Safety.media(u) { sources.append(["url":u.absoluteString,"type":u.path.contains(".m3u8") ? "hls":"flv","quality":rate,"qualityLabel":qualities.first{$0.int("qn")==rate}?.str("label") ?? "平台当前档位"]) }
        }
        room.removeValue(forKey:"_huya");guard !sources.isEmpty else { throw FusionError("平台没有提供可用的播放源") }
        room["sources"]=sources;room["qualities"]=qualities;room["requestedQuality"]=quality;room["currentQuality"]=sources[0].int("quality")
        return room
    }
}

