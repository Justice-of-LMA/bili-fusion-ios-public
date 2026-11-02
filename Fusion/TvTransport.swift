import Foundation
import Network

/// A user-paired LAN control channel. TV plays independently; no account is transferred.
enum TvTransport {
 static func address(_ raw:String)throws->(String,UInt16){
  var s=raw.trimmingCharacters(in:.whitespacesAndNewlines);if s.hasPrefix("http://"){s=String(s.dropFirst(7))};if s.hasSuffix("/"){s=String(s.dropLast())}
  let parts=s.split(separator:":",omittingEmptySubsequences:false);guard parts.count==1||parts.count==2 else{throw FusionError("请输入电视显示的局域网 IPv4 地址")}
  let ip=parts[0].split(separator:".",omittingEmptySubsequences:false);guard ip.count==4 else{throw FusionError("请输入电视显示的局域网 IPv4 地址")}
  var octets=[Int]();for p in ip{guard let n=Int(p),(0...255).contains(n),String(n)==p else{throw FusionError("电视地址无效")};octets.append(n)}
  guard octets[0]==10||octets[0]==192&&octets[1]==168||octets[0]==172&&(16...31).contains(octets[1]) else{throw FusionError("只允许连接同一局域网内的电视")}
  let port=parts.count==2 ? UInt16(parts[1]):18762;guard let port,port>=1024 else{throw FusionError("电视端口无效")};return(String(parts[0]),port)
 }
 static func request(_ a:JSON) async throws->JSON {
  let (host,port)=try address(a.str("endpoint")),action=a.str("action"),token=a.str("token")
  guard ["pair","state","config","control","settings","login","disconnect"].contains(action),token.isEmpty||token.range(of:"^[A-Za-z0-9_-]{32,80}$",options:.regularExpression) != nil else{throw FusionError("电视操作或配对状态无效")}
  let data=try JSONSerialization.data(withJSONObject:a.obj("data"));guard data.count<=32768 else{throw FusionError("电视配置过大")}
  let header="POST /v1/\(action) HTTP/1.1\r\nHost: \(host):\(port)\r\nContent-Type: application/json\r\nAuthorization: Bearer \(token)\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n"
  var request=Data(header.utf8);request.append(data)
  return try await withCheckedThrowingContinuation{waiter in TvExchange(host:host,port:port,request:request,waiter:waiter,timeout:action == "login" ? 32:8).start()}
 }
}
private final class TvExchange {
 private let connection:NWConnection,queue=DispatchQueue(label:"fusion.tv-control"),request:Data
 private let timeout:Double;private var waiter:CheckedContinuation<JSON,Error>?,timer:DispatchSourceTimer?,buffer=Data()
 init(host:String,port:UInt16,request:Data,waiter:CheckedContinuation<JSON,Error>,timeout:Double){self.timeout=timeout;connection=NWConnection(host:NWEndpoint.Host(host),port:NWEndpoint.Port(rawValue:port)!,using:.tcp);self.request=request;self.waiter=waiter}
 func start(){let timer=DispatchSource.makeTimerSource(queue:queue);self.timer=timer;timer.schedule(deadline:.now()+timeout);timer.setEventHandler{self.finish(.failure(FusionError("电视连接超时，请确认同一 Wi-Fi，并允许本 App 访问本地网络")))};timer.resume();connection.stateUpdateHandler={state in switch state{case .ready:self.connection.send(content:self.request,completion:.contentProcessed{error in if let error{self.finish(.failure(error))}else{self.receive()}});case .failed(let error):self.finish(.failure(error));default:break}};connection.start(queue:queue)}
 private func receive(){connection.receive(minimumIncompleteLength:1,maximumLength:8192){data,_,complete,error in
  if let data{self.buffer.append(data)};if self.buffer.count>73728{self.finish(.failure(FusionError("电视响应过大")));return}
  if let end=self.buffer.range(of:Data("\r\n\r\n".utf8)){
   guard end.lowerBound<8192,let header=String(data:self.buffer[..<end.lowerBound],encoding:.ascii) else{self.finish(.failure(FusionError("电视响应头无效")));return}
   let lines=header.components(separatedBy:"\r\n");var values=[String:String]();for row in lines.dropFirst(){let parts=row.split(separator:":",maxSplits:1);guard parts.count==2,values[String(parts[0]).lowercased()]==nil else{self.finish(.failure(FusionError("电视响应头无效")));return};values[String(parts[0]).lowercased()]=parts[1].trimmingCharacters(in:.whitespaces)}
   guard values["transfer-encoding"]==nil,let raw=values["content-length"],let size=Int(raw),(0...65536).contains(size) else{self.finish(.failure(FusionError("电视协议不匹配")));return}
   if self.buffer.count-end.upperBound>=size{do{guard let result=try JSONSerialization.jsonObject(with:self.buffer.subdata(in:end.upperBound..<(end.upperBound+size))) as? JSON else{throw FusionError("电视返回格式无效")};guard lines.first?.hasPrefix("HTTP/1.1 200 ")==true,result["ok"] as? Bool==true else{throw FusionError(result.str("error").isEmpty ? "电视操作未成功":result.str("error"))};self.finish(.success(result))}catch{self.finish(.failure(error))};return}
  }else if self.buffer.count>8192{self.finish(.failure(FusionError("电视响应头过长")));return}
  if let error{self.finish(.failure(error))}else if complete{self.finish(.failure(FusionError("电视连接提前结束")))}else{self.receive()}
 }}
 private func finish(_ result:Result<JSON,Error>){guard let waiter else{return};self.waiter=nil;timer?.cancel();timer=nil;connection.stateUpdateHandler=nil;connection.cancel();waiter.resume(with:result)}
}
