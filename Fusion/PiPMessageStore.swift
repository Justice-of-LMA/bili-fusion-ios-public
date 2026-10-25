import Foundation

/// B-room messages on B's media clock, independent of a suspended WKWebView.
struct PiPFragment: Equatable {
    var text: String
    var image: URL? = nil
    var ratio: Double = 1
}
struct PiPMessage: Equatable {
    let id: String, user: String, text: String
    var uid: String = ""
    var mergeCount=1
    let price: Int?
    let parts: [PiPFragment]
    var at: Double?
    let duration: Double
}
struct PiPMessageStore {
    private(set) var items = [PiPMessage]()
    private var deleted = Set<String>()
    private var book = [String: PiPFragment]()
    private var serial = 0
    private var blocking: JSON = [:]
    var platform="bilibili",mergeSame=false
    mutating func setBlocking(_ rules: JSON) {
        blocking = BlockRules.normalize(rules)
        let current = blocking,p=platform
        items.removeAll { BlockRules.matches(current,uid:$0.uid,name:$0.user,text:$0.text,platform:p) }
    }
    static func imageURL(_ value: String) -> URL? {
        var s = value
        if s.hasPrefix("//") { s = "https:" + s }
        if s.hasPrefix("http://") { s = "https://" + s.dropFirst(7) }
        guard s.count < 2048, let u = URL(string: s), u.scheme == "https", let host = u.host,
              u.user == nil, u.password == nil, u.port == nil || u.port == 443,
              ["hdslb.com", "biliimg.com", "bilibili.com", "bilivideo.com"].contains(where: { Safety.inDomain(host, $0) }) else { return nil }
        return u
    }
    private func object(_ value: Any?) -> JSON {
        if let d = value as? JSON { return d }
        if let s = value as? String, s.utf8.count < 100000, let bytes = s.data(using: .utf8) {
            return (try? JSONSerialization.jsonObject(with: bytes)) as? JSON ?? [:]
        }
        return [:]
    }
    private mutating func add(_ label: String, _ d: JSON) {
        let name = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let paired = (name.hasPrefix("[") && name.hasSuffix("]")) || (name.hasPrefix("【") && name.hasSuffix("】"))
        let inner = paired ? String(name.dropFirst().dropLast()) : name
        guard !inner.isEmpty, inner.count <= 98, name != "表情",
              !inner.contains(where: { "[]【】\r\n".contains($0) }),
              let url = Self.imageURL(d.str("url").isEmpty ? d.str("emoticon_url") : d.str("url")) else { return }
        let key = "[" + inner + "]"
        let ratio = max(0.5, min(3, Double(max(1,d.int("width"))) / Double(max(1,d.int("height")))))
        if book.count >= 2000 { book.removeValue(forKey: book.keys.sorted().first!) }
        book[key] = PiPFragment(text: key, image: url, ratio: ratio)
        book["【" + key.dropFirst().dropLast() + "】"] = book[key]
    }
    mutating func learn(_ value: Any) {
        var remaining = 8000
        learn(value, depth: 0, remaining: &remaining)
    }
    private mutating func learn(_ value: Any, depth: Int, remaining: inout Int) {
        remaining -= 1; guard depth <= 8, remaining > 0 else { return }
        if let array = value as? [Any] { for child in array.prefix(1000) { learn(child, depth: depth+1, remaining: &remaining) }; return }
        guard let d = value as? JSON else { return }
        for key in ["emoji","emoticon_unique","alt","text"] { add(d.str(key), d) }
        for label in (d["aliases"] as? [String] ?? []).prefix(30) { add(label, d) }
        for (key, child) in d.prefix(300) {
            if let info = child as? JSON { add(key, info) }
            learn(child, depth: depth+1, remaining: &remaining)
        }
    }
    private mutating func segments(_ text: String, direct: JSON = [:], inline: JSON = [:]) -> [PiPFragment] {
        for (key, d) in inline.prefix(100) { add(key, object(d)) }
        if let url = Self.imageURL(direct.str("url")) {
            let ratio = max(0.5, min(3, Double(max(1,direct.int("width"))) / Double(max(1,direct.int("height")))))
            return [PiPFragment(text: text.isEmpty ? "[表情]" : text, image: url, ratio: ratio)]
        }
        let keys = book.keys.filter { text.contains($0) }.sorted { $0.count > $1.count }
        guard !keys.isEmpty else { return [PiPFragment(text: text)] }
        var rest = text[...], run = "", result = [PiPFragment](), images = 0
        while !rest.isEmpty {
            if images < 24, let key = keys.first(where: { rest.hasPrefix($0) }), let part = book[key] {
                if !run.isEmpty { result.append(PiPFragment(text: run)); run = "" }
                result.append(part); rest = rest.dropFirst(key.count); images += 1
            } else { run.append(rest.removeFirst()) }
        }
        if !run.isEmpty { result.append(PiPFragment(text: run)) }; return result
    }
    mutating func receive(_ packet: JSON, edge: Double?, now: Double = Date().timeIntervalSince1970) {
        let cmd = packet.str("cmd").split(separator: ":").first.map(String.init) ?? "", d = packet.obj("data")
        if cmd == "SUPER_CHAT_MESSAGE_DELETE" {
            for id in (d["ids"] as? [Any] ?? []).prefix(1000) { deleted.insert(String(describing: id)) }
            items.removeAll { deleted.contains($0.id) }
            if deleted.count > 2000 { deleted = Set(deleted.sorted().suffix(2000)) }; return
        }
        var user = "", uid = "", text = "", price: Int?, duration = 90.0, parts = [PiPFragment](), id = ""
        if cmd == "DANMU_MSG" {
            guard let info = packet["info"] as? [Any], info.count >= 3 else { return }
            let meta = info[0] as? [Any] ?? [], sender = info[2] as? [Any] ?? []
            text = String((info[1] as? String ?? "").prefix(2000))
            user = sender.count > 1 ? String((sender[1] as? String ?? "").prefix(60)) : ""
            uid = sender.isEmpty ? "" : String(describing:sender[0])
            let extra = object(meta.count > 15 ? meta[15] : nil)
            parts = segments(text, direct: object(meta.count > 13 ? meta[13] : nil), inline: object(extra["extra"]).obj("emots"))
            serial += 1; id = "chat:\(serial)"
        } else if ["SUPER_CHAT_MESSAGE", "SUPER_CHAT_MESSAGE_JPN"].contains(cmd) {
            id = String(describing: d["id"] ?? ""); guard !id.isEmpty, !deleted.contains(id), !items.contains(where: { $0.id == id }) else { return }
            user = String((d.obj("user_info").str("uname").isEmpty ? d.str("uname") : d.obj("user_info").str("uname")).prefix(60))
            text = String(d.str("message").prefix(2000)); price = max(0,min(10000000,d.int("price")))
            uid = String(describing:d["uid"] ?? d.obj("user_info")["uid"] ?? "")
            let total = max(1,min(7200,Double(d.int("time") > 0 ? d.int("time") : 60)))
            duration = d.int64("end_time") > 0 ? min(total,Double(d.int64("end_time"))-now) : total
            guard duration > 0 else { return }; parts = segments(text)
        } else { return }
        guard !text.isEmpty || parts.contains(where: { $0.image != nil }) else { return }
        guard !BlockRules.matches(blocking,uid:uid,name:user,text:text,platform:platform) else { return }
        items.append(PiPMessage(id: id, user: user, text: text, uid: uid, price: price, parts: parts, at: edge?.isFinite == true ? edge : nil, duration: duration))
        if items.count > 180 { items.removeFirst(items.count-180) }
    }
    mutating func visible(time: Double, edge: Double?, rows: Int, chat: Bool, sc: Bool) -> [PiPMessage] {
        guard time.isFinite else { return [] }
        if let edge, edge.isFinite { for i in items.indices where items[i].at == nil { items[i].at = edge } }
        items.removeAll { if let at = $0.at { return time-at > $0.duration+30 }; return false }
        let due = items.filter { m in
            guard let at = m.at, time >= at, time-at < m.duration else { return false }
            return m.price == nil ? chat : sc
        }
        // Reserve up to two positions for live SC, then show the latest chat in order.
        let count = max(2,min(8,rows)), cards = Array(due.filter { $0.price != nil }.suffix(2))
        var chats=[PiPMessage]()
        for m in due where m.price==nil {if mergeSame,let i=chats.firstIndex(where:{$0.text.utf8.elementsEqual(m.text.utf8)}){chats[i].mergeCount+=1}else{chats.append(m)}}
        let chatItems = Array(chats.suffix(max(0,count-cards.count)))
        return cards + chatItems
    }
    mutating func clearMessages() { items.removeAll(); deleted.removeAll() }
}
