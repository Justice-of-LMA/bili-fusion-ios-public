import Foundation
import Network
/// Bounded, cancellable FLV byte pipe. Cookies are never sent to media CDNs.
final class MediaBytePipe: NSObject, URLSessionDataDelegate {
    private let connection:NWConnection,request:URLRequest
    private var session:URLSession?,task:URLSessionDataTask?
    private var queue=[Data](),bytes=0,sending=false,started=false,finished=false,closed=false
    private var redirects=0
    var onClose:(()->Void)?
    init(connection:NWConnection,request:URLRequest){self.connection=connection;self.request=request}
    func start(){let c=URLSessionConfiguration.ephemeral;c.httpCookieStorage=nil;c.httpShouldSetCookies=false;c.urlCache=nil;c.timeoutIntervalForRequest=20;c.timeoutIntervalForResource=24*3600;session=URLSession(configuration:c,delegate:self,delegateQueue:nil);task=session!.dataTask(with:request);task!.resume()}
    func cancel(){DispatchQueue.main.async{self.stop()}}
    private func stop(){guard !closed else{return};closed=true;task?.cancel();session?.invalidateAndCancel();connection.cancel();queue.removeAll();bytes=0;onClose?();onClose=nil}
    func urlSession(_ session:URLSession,task:URLSessionTask,willPerformHTTPRedirection response:HTTPURLResponse,newRequest request:URLRequest,completionHandler:@escaping(URLRequest?)->Void){
        // This only follows the same Huya HTTP request's bounded CDN redirect;
        // it never rebuilds a stream, retries a failure or selects another line.
        guard let next=PlatformRoom.huyaRedirect(self.request,to:request.url,count:redirects) else{completionHandler(nil);return}
        redirects+=1;completionHandler(next)
    }
    func urlSession(_ session:URLSession,dataTask:URLSessionDataTask,didReceive response:URLResponse,completionHandler:@escaping(URLSession.ResponseDisposition)->Void){
        guard let r=response as? HTTPURLResponse,let header=Self.responseHeader(r) else{completionHandler(.cancel);return}
        DispatchQueue.main.async{guard !self.closed else{return};self.started=true;self.enqueue(header)}
        completionHandler(.allow)
    }
    static func responseHeader(_ response:HTTPURLResponse)->Data?{
        guard [200,206].contains(response.statusCode) else{return nil}
        var header="HTTP/1.1 \(response.statusCode) \(response.statusCode==206 ? "Partial Content":"OK")\r\nContent-Type: video/x-flv\r\nTransfer-Encoding: chunked\r\nAccess-Control-Allow-Origin: *\r\nCache-Control: no-store\r\nConnection: close\r\n"
        if response.statusCode==206{
            guard let range=response.value(forHTTPHeaderField:"Content-Range"),!range.contains("\r"),!range.contains("\n"),range.range(of:"^bytes [0-9]+-[0-9]+/(?:[0-9]+|\\*)$",options:.regularExpression) != nil else{return nil}
            header += "Content-Range: "+range+"\r\n"
        }
        if let ranges=response.value(forHTTPHeaderField:"Accept-Ranges"),!ranges.contains("\r"),!ranges.contains("\n"){header += "Accept-Ranges: "+ranges+"\r\n"}
        return Data((header+"\r\n").utf8)
    }
    func urlSession(_ session:URLSession,dataTask:URLSessionDataTask,didReceive data:Data){DispatchQueue.main.async{
        guard !self.closed else{return};var packet=Data((String(data.count,radix:16)+"\r\n").utf8);packet.append(data);packet.append(Data("\r\n".utf8));self.enqueue(packet)
    }}
    private func enqueue(_ data:Data){guard !closed else{return};if bytes+data.count>8*1024*1024{stop();return};queue.append(data);bytes+=data.count;pump()}
    private func pump(){guard !closed,!sending else{return};guard !queue.isEmpty else{if finished{stop()};return};sending=true;let data=queue.removeFirst()
        connection.send(content:data,completion:.contentProcessed{ error in DispatchQueue.main.async{self.sending=false;self.bytes-=data.count;if error != nil{self.stop()}else{self.pump()}}})
    }
    func urlSession(_ session:URLSession,task:URLSessionTask,didCompleteWithError error:Error?){DispatchQueue.main.async{guard !self.closed else{return};if !self.started{self.enqueue(Data("HTTP/1.1 502 Error\r\nContent-Length: 0\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n".utf8))}else if error==nil{self.enqueue(Data("0\r\n\r\n".utf8))};self.finished=true;self.pump()}}
}

