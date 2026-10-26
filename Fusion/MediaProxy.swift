import Foundation
import Network

/// Loopback only. Opaque, per-launch capability URLs; upstreams are HTTPS Bili CDNs.
/// No browser/login Cookie is ever forwarded to media hosts.
@MainActor final class MediaProxy {
    typealias Fetch = @MainActor (URLRequest, Int) async throws -> (Data, HTTPURLResponse)
    private let fetch: Fetch
    init(fetch: @escaping Fetch = { request, limit in try await HTTP.shared.fetch(request, limit: limit) }) { self.fetch = fetch }
    private let secret = UUID().uuidString
    private var listener: NWListener?
    private var port: UInt16 = 0
    private var urls = [String: (URL, Date, String)]()
    private var voice = [String: Float](), voiceStatus = [String: String](), fragmented = Set<String>(), owners=[String:String]()
    func begin(_ source:String,token:String)->String{let owner=source+":"+token;if let old=owners[source]{voice.removeValue(forKey:old);voiceStatus.removeValue(forKey:old);fragmented.remove(old);traces.removeValue(forKey:old)};owners[source]=owner;voice[owner]=voice[source] ?? 0;return owner}
    func setVoice(_ owner: String, strength: Float) { voice[owner] = max(0,min(1,strength)); let key=owners[owner] ?? owner;voice[key]=voice[owner];voiceStatus[key] = strength > 0 ? "等待后续片段处理（已缓存声音暂不改变）" : "已关闭" }
    func voiceDetail(_ owner: String) -> String { voiceStatus[owners[owner] ?? owner] ?? "已关闭" }
    private var traces=[String:MediaFetchTrace]()
    func diagnostics()->JSON{let now=ProcessInfo.processInfo.systemUptime;return owners.mapValues{traces[$0]?.snapshot(now:now) ?? [:]}}
    private var reverse = [String: String]()
    private var connections = [UUID: NWConnection]()
    private var pipes=[ObjectIdentifier:MediaBytePipe]()
    private var activeRequests=Set<ObjectIdentifier>()
    var headerTimeout: TimeInterval = 35
    private var startup = [CheckedContinuation<Void, Error>]()
    private var startupTimeout: Task<Void, Never>?
    private var startGeneration = 0
    var isRunning: Bool { port > 0 }
    func start() async throws {
        if isRunning { return }
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            startup.append(continuation)
            // A and B share one bounded startup rather than overwriting each other's continuation.
            guard self.listener == nil else { return }
            let listener: NWListener
            do {
                let params = NWParameters.tcp
                params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
                listener = try NWListener(using: params)
            } catch { finishStart(.failure(error)); return }
            self.listener = listener
            startGeneration += 1; let generation = startGeneration
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                Task { @MainActor in
                    guard let self, self.startGeneration == generation else { return }
                    switch state {
                    case .ready:
                        self.port = listener?.port?.rawValue ?? 0
                        self.finishStart(self.port > 0 ? .success(()) : .failure(FusionError("本地媒体端口不可用（MEDIA-PORT）")))
                    case .waiting: self.finishStart(.failure(FusionError("本地媒体服务暂不可用（MEDIA-WAIT），请稍后重试")))
                    case .failed(let error): self.finishStart(.failure(error))
                    case .cancelled: self.finishStart(.failure(FusionError("本地播放器连接被取消")))
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in if let self { self.accept(connection) } else { connection.cancel() } }
            }
            startupTimeout = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 6_000_000_000) } catch { return }
                guard let self, self.startGeneration == generation, !self.startup.isEmpty else { return }
                self.finishStart(.failure(FusionError("本地媒体服务启动超时（MEDIA-TIMEOUT），请重试")))
            }
            listener.start(queue: .main)
        }
    }
    private func finishStart(_ result: Result<Void, Error>) {
        startupTimeout?.cancel(); startupTimeout = nil
        let waiters = startup; startup.removeAll()
        if case .failure = result {
            startGeneration += 1; listener?.stateUpdateHandler = nil
            listener?.cancel(); listener = nil; port = 0
        }
        for waiter in waiters { waiter.resume(with: result) }
    }
    func register(_ url: URL, owner: String = "") throws -> URL {
        guard Safety.media(url), port > 0 else { throw FusionError("不允许的直播线路") }
        if let id = reverse[owner+"|"+url.absoluteString] { urls[id] = (url, Date(), owner); return local(id) }
        if urls.count >= 4096 {
            for (id, entry) in urls.sorted(by: { $0.value.1 < $1.value.1 }).prefix(512) { urls.removeValue(forKey: id); reverse.removeValue(forKey: entry.2+"|"+entry.0.absoluteString) }
        }
        let id = UUID().uuidString; urls[id] = (url, Date(), owner); reverse[owner+"|"+url.absoluteString] = id
        return local(id)
    }
    private func local(_ id: String) -> URL { URL(string: "http://127.0.0.1:\(port)/\(secret)/\(id)")! }
    private func accept(_ connection: NWConnection) {
        guard connections.count < 24 else { connection.cancel(); return }
        let id = UUID(); connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                if case .cancelled = state { connection.stateUpdateHandler = nil; self?.connections.removeValue(forKey: id);self?.activeRequests.remove(ObjectIdentifier(connection));self?.pipes.removeValue(forKey:ObjectIdentifier(connection))?.cancel() }
                if case .failed = state { connection.stateUpdateHandler = nil; connection.cancel(); self?.connections.removeValue(forKey: id);self?.activeRequests.remove(ObjectIdentifier(connection));self?.pipes.removeValue(forKey:ObjectIdentifier(connection))?.cancel() }
            }
        }
        connection.start(queue: .main)
        // This is a request-header deadline, not a lifetime limit on an active HLS fetch/send.
        DispatchQueue.main.asyncAfter(deadline: .now() + headerTimeout) { [weak self] in
            guard let self else { return }
            if self.pipes[ObjectIdentifier(connection)] == nil && !self.activeRequests.contains(ObjectIdentifier(connection)) { self.connections[id]?.cancel() }
        }
        read(connection, Data())
    }
    private func read(_ connection: NWConnection, _ soFar: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, done, error in
            Task { @MainActor in
                guard let self else { connection.cancel(); return }
                var bytes = soFar; if let data { bytes.append(data) }
                guard bytes.count <= 16384 else { self.respond(connection, code: 400, body: Data()); return }
                if bytes.range(of: Data("\r\n\r\n".utf8)) != nil { self.activeRequests.insert(ObjectIdentifier(connection)); await self.serve(connection, bytes) }
                else if done || error != nil { connection.cancel() }
                else { self.read(connection, bytes) }
            }
        }
    }
    private func serve(_ connection: NWConnection, _ bytes: Data) async {
        guard let header = String(data: bytes, encoding: .utf8) else { respond(connection, code: 400, body: Data()); return }
        let lines = header.components(separatedBy: "\r\n"), first = lines[0].split(separator: " ")
        guard first.count == 3, first[0] == "GET" || first[0] == "HEAD" else { respond(connection, code: 405, body: Data()); return }
        let parts = first[1].split(separator: "/")
        guard parts.count == 2, parts[0] == secret, let entry = urls[String(parts[1])] else { respond(connection, code: 404, body: Data()); return }
        urls[String(parts[1])] = (entry.0, Date(), entry.2) // Active manifest capabilities must not become the oldest unused entries.
        let isHead = first[0] == "HEAD", knownManifest = entry.0.path.lowercased().hasSuffix(".m3u8")
        var req = URLRequest(url: entry.0, cachePolicy: .reloadIgnoringLocalCacheData)
        req.httpMethod = isHead ? "HEAD" : "GET"
        req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        req.setValue(Safety.ua, forHTTPHeaderField: "User-Agent")
        let h=entry.0.host ?? "", platform=["huya.com","msstatic.com","tbcache.com"].contains(where:{Safety.inDomain(h,$0)}) ? "huya": ["douyucdn.cn","douyucdn2.cn","douyuscdn.com","douyuscdn.cn","douyucdn.com","edgesrv.com"].contains(where:{Safety.inDomain(h,$0)}) ? "douyu":"bilibili"
        if platform=="huya"{req.setValue("HYSDK(Windows, 30000002)_APP(pc_exe&7060000&official)_SDK(trans&2.32.3.5646)",forHTTPHeaderField:"User-Agent")}
        let referer=platform=="bilibili" ? "https://live.bilibili.com":"https://www."+platform+".com"
        req.setValue(referer+"/", forHTTPHeaderField: "Referer")
        req.setValue(referer, forHTTPHeaderField: "Origin")
        req.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        for line in lines.dropFirst() where line.lowercased().hasPrefix("range:") {
            let range = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
            guard Self.validRange(range) else { respond(connection, code: 400, body: Data()); return }
            // Rewriting changes byte offsets/length. A playlist must be fetched whole, never rewrite a two-byte sniff response.
            if !knownManifest { req.setValue(range, forHTTPHeaderField: "Range") }
        }
        if entry.0.path.lowercased().contains(".flv"),first[0]=="GET" {
            if VoiceSegment.aiEnabled, (voice[entry.2] ?? 0) > 0 { voiceStatus[entry.2]="当前 FLV 为透传，没有 AI 处理；请手动选择可用的 HLS/TS 线路" }
            let key=ObjectIdentifier(connection),pipe=MediaBytePipe(connection:connection,request:req);pipes[key]=pipe
            pipe.onClose={ [weak self] in Task{@MainActor in self?.pipes.removeValue(forKey:key)} };pipe.start();return
        }
        let traceID=traces[entry.2,default:MediaFetchTrace()].begin(now:ProcessInfo.processInfo.systemUptime)
        do {
            var (data, response) = try await fetch(req, isHead ? Int.max : 24 * 1024 * 1024)
            if ![200,206].contains(response.statusCode){traces[entry.2]?.finish(traceID,now:ProcessInfo.processInfo.systemUptime,status:response.statusCode,isManifest:knownManifest,body:Data());respond(connection,code:502,body:Data());return}
            var type = response.mimeType ?? "application/octet-stream"
            let isManifest = knownManifest || type.lowercased().contains("mpegurl") || data.prefix(7) == Data("#EXTM3U".utf8)
            traces[entry.2]?.finish(traceID,now:ProcessInfo.processInfo.systemUptime,status:response.statusCode,isManifest:isManifest && !isHead,body:data,age:Double(response.value(forHTTPHeaderField:"Age") ?? "") ?? 0)
            guard !isManifest || response.statusCode == 200 else { respond(connection, code: 502, body: Data()); return }
            if isHead {
                var extras=[String:String]()
                if !isManifest { for name in ["Content-Range","Accept-Ranges"] { if let value=response.value(forHTTPHeaderField:name), !value.contains("\r"), !value.contains("\n") { extras[name]=value } } }
                if isManifest { type="application/vnd.apple.mpegurl" }
                // The rewritten playlist has a different length; don't advertise the upstream byte count or a false zero.
                respond(connection,code:response.statusCode,body:Data(),type:type,headers:extras,head:true,contentLength:response.expectedContentLength >= 0 ? response.expectedContentLength:nil,omitLength:isManifest || response.expectedContentLength < 0)
                return
            }
            if isManifest {
                guard response.statusCode == 200, data.count < 1024 * 1024, let text = String(data: data, encoding: .utf8), text.hasPrefix("#EXTM3U") else { throw FusionError("播放列表无效") }
                if text.contains("#EXT-X-MAP") { fragmented.insert(entry.2); if (voice[entry.2] ?? 0) > 0 { voiceStatus[entry.2] = "当前为分片 MP4，保持原声音；请点“应用人声设置并手动重新获取 A”改取 TS" } }
                data = Data(try rewrite(text, base: entry.0, owner: entry.2).utf8); type = "application/vnd.apple.mpegurl"
            }
            var transformed=false
            if !isManifest, (voice[entry.2] ?? 0) > 0, !fragmented.contains(entry.2), data.first == 0x47, (req.value(forHTTPHeaderField:"Range")==nil || req.value(forHTTPHeaderField:"Range")=="bytes=0-") {
                let amount=voice[entry.2] ?? 0, input=data
                let processed=await Task.detached(priority:.userInitiated) { VoiceSegment.process(input,strength:amount) }.value
                data=processed.0; if processed.1 == 1 { transformed=true;type="video/mp2t"; voiceStatus[entry.2]=VoiceSegment.aiEnabled ? VoiceSegment.aiDetail+" · 本机模型去人声；画面不重编码" : "本机减弱处理中 · 立体声 AAC；画面不重编码" } else { voiceStatus[entry.2]=VoiceSegment.aiEnabled ? "AI 未处理（格式/片段不支持或模型失败），保留原声音："+VoiceSegment.aiDetail : "当前音频格式无法处理，保留原声音（非立体声 AAC 或片段不完整）" }
            }
            var extras = [String: String]()
            if !isManifest && !transformed {
                for name in ["Content-Range", "Accept-Ranges"] { if let value = response.value(forHTTPHeaderField: name), !value.contains("\r"), !value.contains("\n") { extras[name] = value } }
            }
            respond(connection, code: transformed ? 200:response.statusCode, body: data, type: type, headers: extras, head: first[0] == "HEAD")
        } catch { traces[entry.2]?.finish(traceID,now:ProcessInfo.processInfo.systemUptime,status:0,isManifest:knownManifest,body:Data());respond(connection,code:502,body:Data()) }
    }
    func rewrite(_ manifest: String, base: URL, owner: String = "") throws -> String {
        let regex = try NSRegularExpression(pattern: "URI=\"([^\"]+)\"")
        func replacement(_ raw: String) throws -> String {
            guard let resolved = URL(string: raw, relativeTo: base)?.absoluteURL,
                  var components = URLComponents(url: resolved, resolvingAgainstBaseURL: true) else { throw FusionError("无效媒体地址") }
            if components.scheme == "http" { components.scheme = "https" }
            guard let target = components.url, Safety.media(target) else { throw FusionError("播放列表包含不允许的地址") }
            return try register(target, owner:owner).absoluteString
        }
        return try manifest.components(separatedBy: .newlines).map { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return line }
            if !trimmed.hasPrefix("#") { return try replacement(trimmed) }
            var result = line
            for match in regex.matches(in: line, range: NSRange(line.startIndex..., in: line)).reversed() {
                guard let range = Range(match.range(at: 1), in: result) else { continue }
                let value = String(result[range]); result.replaceSubrange(range, with: try replacement(value))
            }
            return result
        }.joined(separator: "\n")
    }
    static func validRange(_ value:String)->Bool {
        guard value.matches("^bytes=(?:[0-9]+-[0-9]*|-[0-9]+)$") else { return false }
        let parts=value.dropFirst(6).split(separator:"-",omittingEmptySubsequences:false)
        guard parts.count==2 else { return false }
        if parts[0].isEmpty { return (Int64(parts[1]) ?? 0)>0 }
        guard let start=Int64(parts[0]),start>=0 else { return false }
        return parts[1].isEmpty || (Int64(parts[1]).map{$0>=start} ?? false)
    }
    private func respond(_ connection: NWConnection, code: Int, body: Data, type: String = "application/octet-stream", headers: [String: String] = [:], head: Bool = false, contentLength: Int64? = nil, omitLength: Bool = false) {
        let reason = code == 200 ? "OK" : code == 206 ? "Partial Content" : "Error"
        var h = "HTTP/1.1 \(code) \(reason)\r\nContent-Type: \(type)\r\n"
        if !omitLength { h += "Content-Length: \(contentLength ?? Int64(body.count))\r\n" }
        h += "Access-Control-Allow-Origin: *\r\nCache-Control: no-store\r\nConnection: close\r\n"
        for (key, value) in headers { h += key + ": " + value + "\r\n" }
        var output = Data((h + "\r\n").utf8); if !head { output.append(body) }
        connection.send(content: output, completion: .contentProcessed { _ in connection.cancel() })
    }
    func stop() { finishStart(.failure(FusionError("播放器已关闭"))); listener?.cancel(); listener = nil; for pipe in pipes.values {pipe.cancel()};pipes.removeAll(); for c in connections.values { c.cancel() }; connections.removeAll();activeRequests.removeAll(); urls.removeAll(); reverse.removeAll(); voice.removeAll(); voiceStatus.removeAll(); fragmented.removeAll();owners.removeAll();traces.removeAll(); port = 0 }
}
