import Foundation

@MainActor final class LiveSocket {
    private let api: BiliAPI
    private let room: Int64
    private let sink: (JSON) -> Void
    private var socket: URLSessionWebSocketTask?
    private var session: URLSession?
    private var runner: Task<Void, Never>?, heartbeat: Task<Void, Never>?, timeout: Task<Void, Never>?
    private var closed = false, authed = false
    private var revision = 0
    private var lastReply = Date()
    init(api: BiliAPI, room: Int64, sink: @escaping (JSON) -> Void) { self.api = api; self.room = room; self.sink = sink }
    func start() {
        guard !closed else { return }; revision += 1; let rev = revision
        runner?.cancel(); heartbeat?.cancel(); timeout?.cancel(); socket?.cancel(with: .goingAway, reason: nil); session?.invalidateAndCancel()
        sink(["status": "正在连接弹幕 / SC"])
        runner = Task { [weak self] in await self?.run(rev) }
    }
    private func current(_ rev: Int) -> Bool { !closed && revision == rev && !Task.isCancelled }
    private func run(_ rev: Int) async {
        let config: JSON
        do { config = try await api.config(room) }
        catch { if current(rev) { sink(["status": error.localizedDescription + "；请在官方页验证后点重连"]) }; return }
        guard current(rev) else { return }
        guard let host = config.arr("host_list").first(where: { $0.str("host").matches("^[A-Za-z0-9.-]+\\.chat\\.bilibili\\.com$") }), !config.str("token").isEmpty else { sink(["status": "弹幕线路不可用"]); return }
        let port = host.int("wss_port") == 0 ? 443 : host.int("wss_port")
        guard (1...65535).contains(port), let url = URL(string: "wss://\(host.str("host")):\(port)/sub") else { return }
        var request = URLRequest(url: url); request.setValue("https://live.bilibili.com", forHTTPHeaderField: "Origin"); request.setValue(Safety.ua, forHTTPHeaderField: "User-Agent")
        let options = URLSessionConfiguration.ephemeral; options.httpCookieStorage = nil; options.urlCache = nil
        let session = URLSession(configuration: options); self.session = session
        let socket = session.webSocketTask(with: request); socket.maximumMessageSize = LiveProtocol.limit; self.socket = socket
        authed = false; lastReply = Date(); socket.resume()
        timeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 18_000_000_000)
            guard let self, self.current(rev), !self.authed else { return }
            socket.cancel(with: .goingAway, reason: nil)
        }
        do {
            let body: JSON = ["roomid": room, "uid": config.int64("uid"), "buvid": config.str("buvid"), "protover": 2, "platform": "web", "type": 2, "key": config.str("token")]
            let text = String(data: try JSONSerialization.data(withJSONObject: body), encoding: .utf8)!
            try await socket.send(.data(LiveProtocol.packet(7, text)))
            heartbeat = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 25_000_000_000)
                    guard let self, self.current(rev) else { return }
                    if Date().timeIntervalSince(self.lastReply) > 65 { socket.cancel(with: .goingAway, reason: nil); return }
                    if self.authed { try? await socket.send(.data(LiveProtocol.packet(2, "[object Object]"))) }
                }
            }
            while current(rev) {
                let message = try await socket.receive(); guard current(rev) else { return }
                let bytes: Data
                switch message { case .data(let d): bytes = d; case .string(let s): bytes = Data(s.utf8); @unknown default: continue }
                for event in try LiveProtocol.decode(bytes) {
                    if event.operation == 8 {
                        guard event.data["code"] != nil, event.data.int("code") == 0 else { sink(["status": "弹幕鉴权被拒绝，请登录验证后重连"]); cancelTransport(); return }
                        authed = true; lastReply = Date(); timeout?.cancel(); sink(["status": "弹幕 / SC 已连接"])
                    } else if event.operation == 3 { lastReply = Date() }
                    else if event.operation == 5 && authed { lastReply = Date(); sink(["packet": event.data]) }
                }
            }
        } catch {
            guard current(rev) else { return }; cancelTransport()
            sink(["status": "连接中断，未自动重连，请手动刷新", "needsRefresh":true])
        }
    }
    private func cancelTransport() { heartbeat?.cancel(); timeout?.cancel(); socket?.cancel(with: .goingAway, reason: nil); session?.invalidateAndCancel() }
    func close() { closed = true; revision += 1; runner?.cancel(); cancelTransport() }
}
