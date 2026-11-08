import Foundation

/// 钥匙串分活（10-15 Aporia）：钥匙串里点一把钥匙勾它干哪些活。一样活同一时间只归一把；没人勾 = 跟 TA 聊天那把。
/// 跟 Host 的 server/brain/chores.py 同一份规矩，改一边改另一边。
public enum Chores {
    public static let all = ["vision", "draw", "ledger", "dedupe", "food", "caption", "import", "music", "translate",
                             "diary", "day", "moments", "tarot", "focus", "voice"]
    /// TA 亲笔：勾整个「后台杂活」不带它们
    public static let own: Set<String> = ["diary", "day", "moments", "tarot", "focus"]
    public static let odd: Set<String> = ["dedupe", "food", "caption", "import", "music", "translate"]
    static let sees: Set<String> = ["vision", "caption"]

    public struct Cannot: Error { public let chores: [String] }

    public static func can(_ provider: String) -> [String] {
        let no: Set<String>
        switch provider {
        case "elevenlabs", "minimax": no = Set(all).subtracting(["voice"])
        case "deepseek": no = sees.union(["draw", "voice"])
        case "anthropic": no = ["draw", "voice"]
        default: no = ["voice"]
        }
        return all.filter { !no.contains($0) }
    }

    /// 旧的 media.json {vision_key, image_key, image_model} + 某个 TA 的 echo_key_id → 分活表
    public static func migrate(media: [String: Any], echoKey: String?) -> (table: [String: String], drawModel: String) {
        var t: [String: String] = [:]
        if let v = media["vision_key"] as? String, !v.isEmpty { t["vision"] = v }
        if let v = media["image_key"] as? String, !v.isEmpty { t["draw"] = v }
        if let e = echoKey, !e.isEmpty { t["ledger"] = e }
        return (t, media["image_model"] as? String ?? "")
    }

    public static func assign(_ table: [String: String], key: String, provider: String, chores: [String]) throws
        -> (table: [String: String], moved: [[String: String]]) {
        let allowed = Set(can(provider))
        let bad = chores.filter { !allowed.contains($0) }
        if !bad.isEmpty { throw Cannot(chores: bad) }
        var out = table.filter { $0.value != key }
        var moved: [[String: String]] = []
        for c in all where chores.contains(c) {
            if let from = out[c] { moved.append(["chore": c, "from_key": from]) }
            out[c] = key
        }
        return (out, moved)
    }

    /// 画图模型（不能拿来聊天）。10-16 内测：钥匙上填了 gpt-image-1 当聊天模型 →「not supported on the Chat Completions endpoint」
    public static func isImageModel(_ model: String) -> Bool {
        let m = model.lowercased()
        return m.hasPrefix("gpt-image") || m.hasPrefix("dall-e") || m.hasPrefix("imagen") || m.contains("-image")
    }

    /// 聊天接口说「这个模型不在这儿」：画图模型、只走 Responses 的（o1-pro / codex）
    public static func notChatModelError(_ text: String) -> Bool {
        let l = text.lowercased()
        return l.contains("not supported on the chat completions") || l.contains("only supported in v1/responses")
            || l.contains("not a chat model") || l.contains("not supported in the v1/chat/completions")
    }

    /// 用户是不是在叫 TA 画图（10-16：没挑画图钥匙时在聊天里提醒一句去哪挑）。跟 chores.wants_drawing 同一个
    static let drawAsk = try! NSRegularExpression(
        pattern: #"(画|生成)(一|几|两|三)?(张|幅|个)|生图|出图|(生成|画).{0,10}(图|照片|自拍|头像|壁纸|插画)|\b(draw|paint|generate|make)\b.{0,20}\b(image|picture|photo|selfie|drawing|portrait)s?\b|\bdraw me\b"#,
        options: [.caseInsensitive])
    public static func wantsDrawing(_ text: String) -> Bool {
        drawAsk.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }

    public static func pick(_ table: [String: String], _ chore: String, live: [String: String]) -> String? {
        guard let k = table[chore], let p = live[k], can(p).contains(chore) else { return nil }
        return k
    }
}
