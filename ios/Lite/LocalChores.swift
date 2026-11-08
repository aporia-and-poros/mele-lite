#if LITE
import Foundation
import MeleLiteCore

/// 钥匙串分活（10-15）：表存 chores.json {chores: {活儿: 钥匙 id}, draw_model}。
/// 第一次读的时候从旧的 media.json（看图 / 画图）和第一个设了 echo_key_id 的 TA（回声）搬过来。
enum LocalChores {
    static func table(_ host: LocalHost) -> (table: [String: String], drawModel: String) {
        if let f = host.store.read("chores.json") as? [String: Any] {
            return (f["chores"] as? [String: String] ?? [:], f["draw_model"] as? String ?? "")
        }
        let echo = host.store.companions.lazy
            .compactMap { ($0["settings"] as? [String: Any])?["echo_key_id"] as? String }.first { !$0.isEmpty }
        let m = Chores.migrate(media: LocalMedia.settings(host.store), echoKey: echo)
        save(host, table: m.table, drawModel: m.drawModel)
        return m
    }

    static func save(_ host: LocalHost, table: [String: String], drawModel: String) {
        host.store.write("chores.json", ["chores": table, "draw_model": drawModel] as [String: Any])
    }

    /// 钥匙 id → 哪家（ElevenLabs、MiniMax 那把也算）
    static func live(_ host: LocalHost) -> [String: String] {
        var out: [String: String] = [:]
        for k in host.keys { if let id = k["id"] as? String { out[id] = k["provider"] as? String ?? "" } }
        if LocalVoice.key(host) != nil { out[LocalVoice.keyID] = "elevenlabs" }
        if LocalVoice.key(host, provider: "minimax") != nil { out[LocalVoice.mmKeyID] = "minimax" }
        return out
    }

    static func keysOut(_ host: LocalHost) -> [[String: Any]] {
        let (t, dm) = table(host)
        var rows = host.keys
        if let v = LocalVoice.key(host) {
            rows.append(["id": LocalVoice.keyID, "provider": "elevenlabs", "chat_model": "", "last4": String(v.suffix(4)),
                         "base_url": NSNull()])
        }
        if let v = LocalVoice.key(host, provider: "minimax") {
            rows.append(["id": LocalVoice.mmKeyID, "provider": "minimax", "chat_model": "", "last4": String(v.suffix(4)),
                         "base_url": host.vault.get(LocalVoice.mmBaseID) ?? NSNull()])
        }
        return rows.map { k in
            var k = k
            let id = k["id"] as? String ?? "", p = k["provider"] as? String ?? ""
            let mine = LocalVoice.providers.contains(p) ? ["voice"] : Chores.all.filter { t[$0] == id }
            k["chores"] = mine
            k["can"] = Chores.can(p)
            k["draw_model"] = mine.contains("draw") ? dm : ""
            return k
        }
    }

    static func patch(_ host: LocalHost, key id: String, _ b: [String: Any]) -> LocalResponse {
        guard let p = live(host)[id] else { return .error(404, String(localized: "没有这把钥匙")) }
        if let m = b["chat_model"] as? String, !LocalVoice.providers.contains(p) {      // 换聊天模型（10-29 内测：不用再加一把）
            let model = String(m.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
            guard !model.isEmpty else { return .error(400, String(localized: "要填一个聊天用的模型")) }
            host.store.write("keys.json", host.keys.map { k in
                guard (k["id"] as? String) == id else { return k }
                var k = k
                k["chat_model"] = model
                return k
            })
        }
        var (t, dm) = table(host)
        var moved: [[String: String]] = []
        if let list = b["chores"] as? [String], !LocalVoice.providers.contains(p) {
            do { (t, moved) = try Chores.assign(t, key: id, provider: p, chores: list) }
            catch { return .error(400, String(localized: "这家干不了这样活")) }
        }
        if let m = b["draw_model"] as? String { dm = String(m.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100)) }
        save(host, table: t, drawModel: dm)
        guard var out = keysOut(host).first(where: { ($0["id"] as? String) == id }) else { return .empty }
        out["moved"] = moved
        return .json(out)
    }
}

extension LocalHost {
    /// 后台某样活用哪把：钥匙串里勾了的那把（不开思考）；没勾 / 删了 / 那家干不了 → fallback（一般是跟 TA 聊天那把）
    func route(chore: String, else fallback: (ProviderConfig, String)?) -> (ProviderConfig, String)? {
        let (t, _) = LocalChores.table(self)
        guard let id = Chores.pick(t, chore, live: LocalChores.live(self)), var r = route(key: id) else { return fallback }
        r.0.thinking = false
        return r
    }
}
#endif
