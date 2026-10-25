import Foundation
@MainActor protocol ChatConnection: AnyObject { func start();func close() }
extension LiveSocket: ChatConnection {}
enum DouyuWire {
    static func encode(_ text: String) -> Data {
        let payload=Data(text.utf8);var out=Data()
        for value in [UInt32(payload.count+9),UInt32(payload.count+9)] { var v=value.littleEndian;withUnsafeBytes(of:&v){out.append(contentsOf:$0)} }
        out.append(contentsOf:[0xb1,2,0,0]);out.append(payload);out.append(0);return out
    }
    static func parse(_ text: String) -> [String:String] {
        var result=[String:String]()
        func unescape(_ s:String)->String{s.replacingOccurrences(of:"@S",with:"/").replacingOccurrences(of:"@A",with:"@")}
        for field in text.split(separator:"/") { if let r=field.range(of:"@=") { result[unescape(String(field[..<r.lowerBound]))]=unescape(String(field[r.upperBound...])) } };return result
    }
    static func decode(_ pending: inout Data, _ bytes: Data) throws -> [[String:String]] {
        guard pending.count+bytes.count<=2*1024*1024 else { throw FusionError("斗鱼消息过大") };pending.append(bytes);var out=[[String:String]]()
        while pending.count>=12 {
            let b=[UInt8](pending.prefix(12));func u32(_ i:Int)->Int{Int(b[i])|Int(b[i+1])<<8|Int(b[i+2])<<16|Int(b[i+3])<<24}
            let length=u32(0);guard length>=9,length<=1024*1024,length==u32(4),(b[8]==0xb1||b[8]==0xb2),b[9]==2,b[10]==0,b[11]==0 else { throw FusionError("斗鱼消息格式异常") }
            if pending.count<length+4 { break };let packet=[UInt8](pending.prefix(length+4));guard packet.last==0 else { throw FusionError("斗鱼消息不完整") }
            if let text=String(bytes:packet[12..<(length+3)],encoding:.utf8){out.append(parse(text))};pending.removeFirst(length+4)
        };return out
    }
}
@MainActor final class DouyuChat: ChatConnection {
    private let room: String,sink:(JSON)->Void
    private var session: URLSession?,socket:URLSessionWebSocketTask?,runner:Task<Void,Never>?,heartbeat:Task<Void,Never>?
    private var closed=false,pending=Data(),received=Date()
    init(room:String,sink:@escaping(JSON)->Void){self.room=room;self.sink=sink}
    func start(){
        guard !closed else { return };sink(["status":"正在连接斗鱼弹幕"])
        let config=URLSessionConfiguration.ephemeral;config.httpCookieStorage=nil;config.httpShouldSetCookies=false
        let session=URLSession(configuration:config);self.session=session
        var request=URLRequest(url:URL(string:"wss://danmuproxy.douyu.com:8506")!);request.setValue("https://www.douyu.com",forHTTPHeaderField:"Origin")
        let socket=session.webSocketTask(with:request);socket.maximumMessageSize=2*1024*1024;self.socket=socket;socket.resume()
        runner=Task { [weak self] in guard let self else { return };do {
            try await socket.send(.data(DouyuWire.encode("type@=loginreq/roomid@=\(self.room)/")))
            self.heartbeat=Task { [weak self] in while !Task.isCancelled { try? await Task.sleep(nanoseconds:30_000_000_000);guard let self,!self.closed,!Task.isCancelled else{return};if Date().timeIntervalSince(self.received)>95{self.failure();return};try? await socket.send(.data(DouyuWire.encode("type@=mrkl/"))) } }
            while !self.closed && !Task.isCancelled { let message=try await socket.receive();let bytes:Data;switch message{case .data(let d):bytes=d;case .string(let s):bytes=Data(s.utf8);@unknown default:continue};self.received=Date()
                for m in try DouyuWire.decode(&self.pending,bytes) {
                    if m["type"]=="loginres" { try await socket.send(.data(DouyuWire.encode("type@=joingroup/rid@=\(self.room)/gid@=-9999/")));self.sink(["status":"斗鱼已订阅，等待消息"]) }
                    else if m["type"]=="chatmsg",let text=m["txt"],!text.isEmpty,text.count<=2000 {
                        let colors=[0xffffff,0xff0000,0x1e87f0,0x7ac84b,0xff7f00,0x9b39f4,0xff69b4],index=Int(m["col"] ?? "") ?? 0
                        self.sink(["packet":["cmd":"DANMU_MSG","info":[[0,1,25,colors.indices.contains(index) ? colors[index]:0xffffff],text,[m["uid"] ?? "",m["nn"] ?? ""]]]])
                    }else if ["error","logout"].contains(m["type"] ?? ""){self.failure();return}
                }
            }
        }catch { if !self.closed { self.failure() } } }
    }
    private func failure(){sink(["status":"斗鱼连接断开，未自动重连，请手动刷新","needsRefresh":true]);close()}
    func close(){closed=true;runner?.cancel();heartbeat?.cancel();socket?.cancel(with:.goingAway,reason:nil);session?.invalidateAndCancel()}
}

