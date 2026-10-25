import Foundation

/// Local display preferences, never a platform blacklist request.
enum BlockRules {
    static let key = "fusion-blocking-v1"
    static let platforms = ["bilibili","huya","douyu","douyin"]
    static func string(_ value: Any?) -> String { (value as? String ?? "").trimmingCharacters(in:.whitespacesAndNewlines) }
    static func identity(_ raw: JSON) -> JSON {
        let platform = platforms.contains(raw.str("platform")) ? raw.str("platform") : "bilibili"
        let candidate = string(raw["uid"])
        let uid = candidate.matches("^[A-Za-z0-9_-]{1,100}$") && !candidate.matches("^0+$") ? candidate : ""
        let name = String(string(raw["name"] ?? raw["user"]).prefix(100))
        return ["platform":platform,"uid":uid,"name":name]
    }
    static func normalize(_ value: JSON) -> JSON {
        var users = [JSON](), words = [String](), seen = Set<String>()
        for raw in (value["users"] as? [JSON] ?? []).prefix(500) {
            let user = identity(raw), uid = user.str("uid"), name = user.str("name")
            let key = user.str("platform") + ":" + (uid.isEmpty ? "name:"+name : "id:"+uid)
            if (!uid.isEmpty || !name.isEmpty) && seen.insert(key).inserted { users.append(user) }
        }
        for raw in (value["keywords"] as? [String] ?? []).prefix(200) {
            let word = String(string(raw).prefix(100))
            if !word.isEmpty && !words.contains(word) { words.append(word) }
        }
        let exact = Array((value["exactTexts"] as? [String] ?? []).prefix(200)).filter { !$0.isEmpty && $0.utf16.count <= 2000 }
        return ["users":users,"keywords":words,"exactTexts":Array(NSOrderedSet(array:exact))]
    }
    static func load() -> JSON { normalize(UserDefaults.standard.dictionary(forKey:key) ?? [:]) }
    @discardableResult static func save(_ value: JSON) -> JSON {
        let rules = normalize(value); UserDefaults.standard.set(rules,forKey:key); return rules
    }
    static func matches(_ rules: JSON, uid: String, name: String, text: String, platform: String = "bilibili") -> Bool {
        let candidate = identity(["platform":platform,"uid":uid,"name":name]), userID = candidate.str("uid")
        for user in rules["users"] as? [JSON] ?? [] where user.str("platform") == candidate.str("platform") {
            if user.str("uid").isEmpty {
                if !candidate.str("name").isEmpty && user.str("name") == candidate.str("name") { return true }
            } else if !userID.isEmpty && user.str("uid") == userID { return true }
        }
        if (rules["exactTexts"] as? [String] ?? []).contains(where:{$0.utf8.elementsEqual(text.utf8)}) { return true }
        let body = text.lowercased()
        return (rules["keywords"] as? [String] ?? []).contains { body.contains($0.lowercased()) }
    }
}
