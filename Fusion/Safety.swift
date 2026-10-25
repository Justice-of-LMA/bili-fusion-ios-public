import Foundation
import CryptoKit

typealias JSON = [String: Any]
struct FusionError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
enum Safety {
    static let ua = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
    static func inDomain(_ host: String, _ domain: String) -> Bool { host == domain || host.hasSuffix("." + domain) }
    static func room(_ input: String) throws -> Int64 {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.matches("^[0-9]{1,16}$") {
            guard let url = URL(string: value), url.scheme == "https", url.host == "live.bilibili.com", url.user == nil, url.password == nil, url.port == nil || url.port == 443 else { throw FusionError("请输入 B站房间号或官方 HTTPS 直播链接") }
            value = url.path.replacingOccurrences(of: "^/(?:blanc/)?", with: "", options: .regularExpression).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        guard value.matches("^[0-9]{1,16}$"), let id = Int64(value), id > 0, id <= 9_007_199_254_740_991 else { throw FusionError("直播间号无效") }
        return id
    }
    static func media(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased(), url.user == nil, url.password == nil, url.port == nil || url.port == 443 else { return false }
        return ["bilivideo.com", "bilivideo.cn", "biliapi.net", "hdslb.com", "biliimg.com", "bytefcdnrd.com", "smtcdns.net", "huya.com", "msstatic.com", "mobgslb.tbcache.com", "douyucdn.cn", "douyucdn2.cn", "douyuscdn.com", "douyuscdn.cn", "douyucdn.com", "edgesrv.com"].contains { inDomain(host, $0) }
    }
    static func message(_ value: String) throws -> String {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.unicodeScalars.count <= 40, !text.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw FusionError("弹幕请使用 1–40 字的单行文字") }
        return text
    }
    static func encoded(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) ?? "" }
    static func wbi(room: Int64, image: String, sub: String, seconds: Int) throws -> String {
        func key(_ s: String) -> String { URL(string: s)?.deletingPathExtension().lastPathComponent ?? "" }
        let keys = Array(key(image) + key(sub))
        guard keys.count >= 64 else { throw FusionError("未取得完整的连接签名，请在官方页面登录验证") }
        let mix = [46,47,18,2,53,8,23,32,15,50,10,31,58,3,45,35,27,43,5,49,33,9,42,19,29,28,14,39,12,38,41,13]
        let query = "id=\(room)&wts=\(seconds)"
        let salt = String(mix.map { keys[$0] })
        let digest = Insecure.MD5.hash(data: Data((query + salt).utf8)).map { String(format: "%02x", $0) }.joined()
        return query + "&w_rid=" + digest
    }
}
extension String { func matches(_ pattern: String) -> Bool { range(of: pattern, options: .regularExpression) != nil } }
extension Dictionary where Key == String, Value == Any {
    func obj(_ key: String) -> JSON { self[key] as? JSON ?? [:] }
    func arr(_ key: String) -> [JSON] { self[key] as? [JSON] ?? [] }
    func str(_ key: String) -> String { self[key] as? String ?? "" }
    func int(_ key: String) -> Int { (self[key] as? NSNumber)?.intValue ?? Int(str(key)) ?? 0 }
    func int64(_ key: String) -> Int64 { (self[key] as? NSNumber)?.int64Value ?? Int64(str(key)) ?? 0 }
}

