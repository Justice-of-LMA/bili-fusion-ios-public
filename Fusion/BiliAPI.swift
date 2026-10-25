import Foundation
import WebKit

@MainActor final class BiliAPI {
    private var sending = false
    private var sentAt = Date.distantPast
    private let cookieStore = WKWebsiteDataStore.default().httpCookieStore
    private func cookies() async -> [HTTPCookie] {
        await withCheckedContinuation { c in cookieStore.getAllCookies { c.resume(returning: $0) } }
    }
    private func value(_ key: String) async -> String {
        await cookies().first { $0.name == key && Safety.inDomain($0.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")), "bilibili.com") }?.value ?? ""
    }
    func request(_ url: URL, body: [String: String]? = nil) async throws -> JSON {
        guard url.scheme == "https", ["api.live.bilibili.com", "api.bilibili.com"].contains(url.host ?? ""), url.user == nil, url.port == nil || url.port == 443 else { throw FusionError("不允许的接口") }
        var req = URLRequest(url: url); req.setValue(Safety.ua, forHTTPHeaderField: "User-Agent")
        req.setValue("https://live.bilibili.com/", forHTTPHeaderField: "Referer"); req.setValue("https://live.bilibili.com", forHTTPHeaderField: "Origin")
        let valid = await cookies().filter { c in
            let domain = c.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return Safety.inDomain(domain, "bilibili.com") && ((c.domain.hasPrefix(".") && Safety.inDomain(url.host!, domain)) || domain == url.host!) && url.path.hasPrefix(c.path) && (c.expiresDate == nil || c.expiresDate! > Date())
        }
        if !valid.isEmpty { req.setValue(HTTPCookie.requestHeaderFields(with: valid)["Cookie"], forHTTPHeaderField: "Cookie") }
        if let body {
            req.httpMethod = "POST"; req.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
            req.httpBody = Data(body.keys.sorted().map { Safety.encoded($0) + "=" + Safety.encoded(body[$0]!) }.joined(separator: "&").utf8)
        }
        let (bytes, response) = try await HTTP.shared.fetch(req)
        guard response.statusCode == 200 else { throw FusionError("B站接口 HTTP \(response.statusCode)") }
        guard let result = try JSONSerialization.jsonObject(with: bytes) as? JSON else { throw FusionError("B站响应格式发生变化") }
        return result
    }
    func data(_ path: String) async throws -> JSON { try Self.require(await request(URL(string: "https://api.live.bilibili.com" + path)!)) }
    static func require(_ json: JSON) throws -> JSON {
        guard json["code"] != nil, json.int("code") == 0 else { throw FusionError("B站 \(json.int("code"))：\(json.str("message").isEmpty ? json.str("msg") : json.str("message"))") }
        return json.obj("data")
    }
    func status() async throws -> JSON {
        let d = try await request(URL(string: "https://api.bilibili.com/x/web-interface/nav")!).obj("data")
        return ["loggedIn": d["isLogin"] as? Bool ?? false, "name": d.str("uname"), "uid": d.int64("mid")]
    }
    static func previewRow(_ info: JSON) -> JSON {
        let cover = ["user_cover","cover_from_user","cover","keyframe"].map { info.str($0) }.first { !$0.isEmpty } ?? ""
        return ["room": max(info.int64("room_id"), info.int64("roomid")), "title": info.str("title"), "cover": cover, "face": info.str("face"), "name": info.str("uname"), "live": info.int("live_status") == 1]
    }
    func preview(_ input: String) async throws -> JSON {
        let id = try Safety.room(input), info = try await data("/room/v1/Room/get_info?room_id=\(id)")
        guard info.int64("room_id") > 0 else { throw FusionError("直播间未找到") }
        var result = Self.previewRow(info)
        if let anchor = try? await data("/live_user/v1/UserInfo/get_anchor_in_room?roomid=\(info.int64("room_id"))").obj("info") {
            result["name"] = anchor.str("uname"); result["face"] = anchor.str("face")
        }
        return result
    }
    func following(_ page: Int) async throws -> JSON {
        guard (1...50).contains(page) else { throw FusionError("列表页码无效") }
        guard try await status()["loggedIn"] as? Bool == true else { throw FusionError("请先在内置浏览器登录 B站") }
        let d = try await data("/xlive/web-ucenter/v1/xfetter/GetWebList?page=\(page)&page_size=20&hit_ab=true")
        guard let rows = d["list"] as? [JSON] else { throw FusionError("关注列表格式发生变化，请手动输入") }
        var seen = Set<Int64>()
        let items = rows.prefix(100).map(Self.previewRow).filter { $0.int64("room") > 0 && $0["live"] as? Bool == true && seen.insert($0.int64("room")).inserted }
        return ["items": items, "page": page, "hasMore": page < 50 && (d.int("total_page") > 0 ? page < d.int("total_page") : rows.count >= 20)]
    }
    func resolve(_ input: String, quality: Int, preferTS:Bool=false) async throws -> JSON {
        guard (0...100000).contains(quality) else { throw FusionError("清晰度参数无效") }
        let id = try Safety.room(input), info = try await data("/room/v1/Room/get_info?room_id=\(id)")
        let room = info.int64("room_id")
        guard room > 0, info.int("live_status") == 1 else { throw FusionError("直播间不存在或当前未开播") }
        let play = try await data("/xlive/web-room/v2/index/getRoomPlayInfo?room_id=\(room)&protocol=0,1&format=\(preferTS ? "1":"0,1,2")&codec=0&qn=\(quality == 0 ? 80 : quality)&platform=web&ptype=8")
        var result = try Self.playback(play, requested: quality); result["room"] = room; result["title"] = info.str("title"); return result
    }
    static func playback(_ play: JSON, requested: Int) throws -> JSON {
        let pu = play.obj("playurl_info").obj("playurl")
        var names = [Int: String](), sources = [JSON](), available = Set<Int>()
        for d in pu.arr("g_qn_desc").prefix(256) {
            let label = d.obj("media_base_desc").obj("detail_desc").str("desc")
            names[d.int("qn")] = String((label.isEmpty ? d.str("desc") : label).prefix(60))
        }
        for stream in pu.arr("stream") { for format in stream.arr("format") where ["ts", "fmp4"].contains(format.str("format_name")) {
            for codec in format.arr("codec") where codec.str("codec_name") == "avc" {
                let actual = codec.int("current_qn"); var usable = false
                for u in codec.arr("url_info").prefix(2) {
                    guard let url = URL(string: u.str("host") + codec.str("base_url") + u.str("extra")), Safety.media(url) else { continue }
                    usable = true
                    sources.append(["type": "hls", "url": url.absoluteString, "quality": actual, "qualityLabel": names[actual] ?? "档位 \(actual)"])
                }
                if usable {
                    if actual > 0 && actual <= 100000 { available.insert(actual) }
                    for q in (codec["accept_qn"] as? [Int] ?? []).prefix(256) where q > 0 && q <= 100000 { available.insert(q) }
                }
            }
        }}
        if requested > 0 && sources.contains(where: { $0.int("quality") == requested }) { sources = sources.filter { $0.int("quality") == requested } }
        guard !sources.isEmpty else { throw FusionError("该房间暂未提供 iOS 可用的 HTTPS H.264 / HLS 线路") }
        let qualities = available.sorted(by: >).map { ["qn": $0, "label": names[$0] ?? "档位 \($0)"] as JSON }
        return ["sources": sources, "qualities": qualities, "requestedQuality": requested, "currentQuality": sources[0].int("quality")]
    }
    func config(_ room: Int64) async throws -> JSON {
        if await value("buvid3").isEmpty {
            if let response = try? await request(URL(string: "https://api.bilibili.com/x/frontend/finger/spi")!), let spi = try? Self.require(response) {
                let buvid = spi.str("b_3")
                if buvid.matches("^[A-Za-z0-9_-]{10,100}$"), let cookie = HTTPCookie(properties: [.name: "buvid3", .value: buvid, .domain: ".bilibili.com", .path: "/", .secure: "TRUE"]) {
                    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in cookieStore.setCookie(cookie) { c.resume() } }
                }
            }
        }
        let nav = try await request(URL(string: "https://api.bilibili.com/x/web-interface/nav")!).obj("data"), keys = nav.obj("wbi_img")
        let query = try Safety.wbi(room: room, image: keys.str("img_url"), sub: keys.str("sub_url"), seconds: Int(Date().timeIntervalSince1970))
        var conf = try await data("/xlive/web-room/v1/index/getDanmuInfo?" + query)
        conf["uid"] = nav.int64("mid"); conf["buvid"] = await value("buvid3"); return conf
    }
    func send(room: Int64, text: String, uid: Int64) async throws -> JSON {
        let text = try Safety.message(text)
        guard !sending, Date().timeIntervalSince(sentAt) >= 5 else { throw FusionError("上一条仍在发送，或发送间隔不足 5 秒") }
        sending = true; defer { sending = false }
        let account = try await status()
        guard account["loggedIn"] as? Bool == true, uid > 0, account.int64("uid") == uid else { throw FusionError("请登录或刷新切换后的账号") }
        let csrf = await value("bili_jct"); guard !csrf.isEmpty else { throw FusionError("登录校验已失效，请重新登录") }
        let body = ["roomid": String(room), "msg": text, "bubble": "0", "color": "16777215", "mode": "1", "fontsize": "25", "rnd": String(Int(Date().timeIntervalSince1970)), "csrf": csrf, "csrf_token": csrf]
        sentAt = Date(); let response: JSON
        do { response = try await request(URL(string: "https://api.live.bilibili.com/msg/send")!, body: body) }
        catch { throw FusionError("发送结果未知，请到房间确认；没有自动重发") }
        _ = try Self.require(response)
        let hint = response.str("message").isEmpty ? response.str("msg") : response.str("message")
        guard hint.isEmpty else { throw FusionError("平台提示：" + hint) }
        return ["submitted": true, "room": room]
    }
}
