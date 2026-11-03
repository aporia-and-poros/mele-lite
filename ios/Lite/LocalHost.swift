#if LITE
import Foundation
import UIKit
import MeleLiteCore

/// 手机里的小管家：照 Mele 服务器（server/api/）的接口回话，界面一行不用改。
/// 回答不了的（要一直醒着的服务器才能做的）回 503 needs_host，界面那边灰掉。
final class LocalHost: @unchecked Sendable {
    static let shared = LocalHost()

    let store = LocalStore.shared
    let vault = KeychainVault(service: "chat.mele.lite.keys")
    lazy var brain = LocalBrain(host: self)
    let mcp = LocalMCP()

    func handle(_ r: LocalRequest) async -> LocalResponse {
        LocalUsage.install(self)                     // 用量记账（只接一次）
        let p = r.parts
        let m = r.method
        switch (m, p.count) {
        // ── 账号 ──
        case ("GET", 1) where p[0] == "me": return .json(me)
        case ("GET", 2) where p == ["me", "profile"]: return .json(profile)
        case ("PUT", 2) where p == ["me", "profile"]: return putProfile(r.json)
        case (_, _) where p.first == "auth": return .json(["token": "local", "account": me])
        case ("POST", 2) where p == ["me", "devices"], ("POST", 2) where p == ["me", "active"]: return .empty
        case ("PUT", 3) where p[0] == "me" && p[1] == "context": return LocalContext.save(store, kind: p[2], body: r.json)   // 天气 / 在哪 / 日程 / 步数：存本机，聊天时拼〔TA 那边〕
        // ── 钥匙 ──
        case ("GET", 1) where p[0] == "keys": return .json(LocalChores.keysOut(self))
        case ("POST", 1) where p[0] == "keys": return addKey(r.json)
        case ("PATCH", 2) where p[0] == "keys": return LocalChores.patch(self, key: p[1], r.json)
        case ("DELETE", 2) where p[0] == "keys": return deleteKey(p[1])
        case ("GET", 1) where p[0] == "models": return .json(Self.catalog.filter { r.query["provider"] == nil || ($0["provider"] as? String) == r.query["provider"] })
        case ("GET", 1) where p[0] == "traits": return .json([String]())
        // ── 联系人 ──
        case ("GET", 1) where p[0] == "companions":
            if store.companions.isEmpty { _ = createCompanion(name: "Lumi") }      // 跟 Mele 一样：第一次打开就有一个 Lumi
            brain.maybeWriteLetters()                                               // App 一打开会拉联系人：顺手看看要不要留信
            LocalDiary.maybeWrite(self)                                             // 昨天聊过、还没写昨天的：补写日记（10-05）
            LocalFriends.tick(self)                                                 // 到点的好友申请顺手通过
            LocalSelfNotes.tick(self); LocalSelfNotes.rearm(self)                   // 它给自己定的闹钟：到点了就先开口（10-11）
            LocalMusic.maybePick(self)                                              // 过了推歌时间、今天还没推：推今天的私选
            return .json(store.companions.map { companionOut($0) })
        case ("POST", 1) where p[0] == "companions": return .json(createCompanion(name: r.json["name"] as? String), status: 201)
        case ("POST", 3) where p[0] == "companions" && p[1] == "import" && p[2] == "preview": return importCard(r, preview: true)
        case ("POST", 2) where p[0] == "companions" && p[1] == "import": return importCard(r, preview: false)
        case ("GET", 2) where p[0] == "companions": return companionFull(p[1])
        case ("PATCH", 2) where p[0] == "companions": return patchCompanion(p[1], r.json)
        case ("DELETE", 2) where p[0] == "companions": return deleteCompanion(p[1])
        case ("GET", 3) where p[0] == "companions" && p[2] == "avatar": return avatar(p[1])
        case ("PUT", 3) where p[0] == "companions" && p[2] == "avatar": return putAvatar(p[1], r)
        case ("GET", 3) where p[0] == "companions" && p[2] == "conversations": return .json(conversationsOf(p[1]))
        case ("POST", 3) where p[0] == "companions" && p[2] == "conversations":
            return .json(conversationOut(newConversation(p[1], incognito: r.json["incognito"] as? Bool ?? false,
                                                         alt: r.json["alt"] as? [String: Any])), status: 201)
        case ("POST", 3) where p[0] == "companions" && p[2] == "greet": return .json(["ok": false])
        case ("POST", 3) where p[0] == "companions" && p[2] == "sync-advanced": return syncAdvanced(p[1])
        // ── 窗口 ──
        case ("PATCH", 2) where p[0] == "conversations": return patchConversation(p[1], r.json)
        case ("DELETE", 2) where p[0] == "conversations": return deleteConversation(p[1])
        case ("GET", 3) where p[0] == "conversations" && p[2] == "messages": return messages(p[1], r.query)
        case ("POST", 3) where p[0] == "conversations" && p[2] == "messages": return brain.submit(p[1], r.json)
        case ("GET", 3) where p[0] == "conversations" && p[2] == "events": return .stream(brain.listen(p[1]))
        case ("POST", 3) where p[0] == "conversations" && p[2] == "attachments": return upload(p[1], r)
        case ("GET", 3) where p[0] == "conversations" && p[2] == "search": return search(p[1], r.query["q"] ?? "")
        case ("GET", 3) where p[0] == "conversations" && p[2] == "calendar": return calendar(p[1])
        case ("POST", 3) where p[0] == "conversations" && p[2] == "rewind": return brain.rewind(p[1], r.json)
        case ("POST", 3) where p[0] == "conversations" && p[2] == "recall": return brain.recall(p[1], r.json)
        case ("GET", 2) where p[0] == "attachments": return attachment(p[1])
        // ── 消息上的小动作 ──
        case ("PUT", 3) where p[0] == "messages" && p[2] == "reaction": return react(Int(p[1]), r.json["emoji"] as? String, bubble: r.json["bubble"] as? Int)
        case ("DELETE", 3) where p[0] == "messages" && p[2] == "reaction": return react(Int(p[1]), nil, bubble: r.query["bubble"].flatMap(Int.init))
        default:
            if let res = await LocalGroups.handle(r, host: self) { return res }     // 群聊（10-11）
            if let res = await LocalVoice.handle(r, host: self) { return res }
            if let res = await LocalMCP.handle(r, host: self) { return res }
            if let res = await LocalImport.handle(r, host: self) { return res }
            if let res = await LocalMemoryRooms.handle(r, host: self) { return res }
            if let res = await LocalFood.handle(r, host: self) { return res }
            if let res = LocalBooks.handle(r, host: self) { return res }
            if let res = await LocalMedia.handle(r, host: self) { return res }
            if let res = LocalPeek.handle(r, host: self) { return res }
            if let res = LocalFriends.handle(r, host: self) { return res }
            if let res = LocalMap.handle(r, host: self) { return res }
            if let res = LocalUsage.handle(r, host: self) { return res }
            if let res = LocalEcho.handle(r, host: self) { return res }
            if let res = LocalMusic.handle(r, host: self) { return res }
            if let res = await LocalTarot.handle(r, host: self) { return res }
            if let res = await LocalFocus.handle(r, host: self) { return res }
            if let res = await LocalRooms3.translate(r, host: self) { return res }
            return LocalRooms.handle(r, host: self) ?? .needsHost
        }
    }

    // MARK: - 账号

    var me: [String: Any] {
        if store.read("account.json") == nil { store.write("account.json", ["id": UUID().uuidString.lowercased()]) }
        let id = (store.read("account.json") as? [String: Any])?["id"] as? String ?? UUID().uuidString.lowercased()
        return ["id": id, "email": NSNull(), "plan": "lite"]
    }

    var profile: [String: Any] {
        store.read("profile.json") as? [String: Any] ?? ["name": "", "pronoun": "she", "looks": ""]
    }

    private func putProfile(_ body: [String: Any]) -> LocalResponse {
        var p = profile
        for k in ["name", "pronoun", "looks"] { if let v = body[k] as? String { p[k] = v } }
        store.write("profile.json", p)
        for var c in store.companions {          // 名字跟着进每个联系人的设置（服务器也这么做）
            var s = c["settings"] as? [String: Any] ?? [:]
            s["user_name"] = p["name"]; s["user_pronoun"] = p["pronoun"]
            c["settings"] = s
            store.saveCompanion(c)
        }
        return .json(p)
    }

    // MARK: - 钥匙（key 本身在钥匙串，这里只存是哪家、哪个模型、后四位）

    var keys: [[String: Any]] { store.read("keys.json") as? [[String: Any]] ?? [] }

    #if DEBUG
    /// 自测（10-05）：模拟器启动时用环境变量 SIMCTL_CHILD_LITE_TEST_DEEPSEEK 塞一把 DeepSeek 钥匙（不在屏幕上敲 key）；已经有 deepseek 的不重复加
    func debugSeedKey() {
        guard let key = ProcessInfo.processInfo.environment["LITE_TEST_DEEPSEEK"], !key.isEmpty,
              !keys.contains(where: { ($0["provider"] as? String) == "deepseek" }) else { return }
        _ = addKey(["provider": "deepseek", "api_key": key, "chat_model": "deepseek-flash"])
    }

    /// 同上，Gemini（10-10：内测前用Aporia的免费 key 走一遍）
    func debugSeedGemini() {
        guard let key = ProcessInfo.processInfo.environment["LITE_TEST_GEMINI"], !key.isEmpty,
              !keys.contains(where: { ($0["provider"] as? String) == "gemini" }) else { return }
        _ = addKey(["provider": "gemini", "api_key": key, "chat_model": ProcessInfo.processInfo.environment["LITE_TEST_GEMINI_MODEL"] ?? "gemini-3.5-flash-lite"])
    }
    #endif

    private func addKey(_ b: [String: Any]) -> LocalResponse {
        let provider = b["provider"] as? String ?? ""
        let key = (b["api_key"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let model = (b["chat_model"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        guard ["anthropic", "deepseek", "openai", "openai-compatible", "gemini"].contains(provider) else {
            return .error(400, String(localized: "不认识这家：\(provider)"))
        }
        guard key.count >= 8 else { return .error(400, String(localized: "这个 key 太短了，是不是没贴全")) }
        guard !model.isEmpty else { return .error(400, String(localized: "要选一个聊天用的模型")) }
        let id = UUID().uuidString.lowercased()
        vault.set(key, for: id)
        var k: [String: Any] = ["id": id, "provider": provider, "chat_model": model, "last4": String(key.suffix(4))]
        let base = (b["base_url"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        k["base_url"] = base.isEmpty ? NSNull() : base
        store.write("keys.json", keys + [k])
        // 第一把钥匙：还没挑钥匙的联系人都用上它
        for var c in store.companions where c["key_id"] == nil || c["key_id"] is NSNull {
            c["key_id"] = id
            store.saveCompanion(c)
        }
        return .json(k, status: 201)
    }

    private func deleteKey(_ id: String) -> LocalResponse {
        if id == LocalVoice.keyID, LocalVoice.key(self) != nil {
            vault.set(nil, for: id)
            return .empty
        }
        guard keys.contains(where: { ($0["id"] as? String) == id }) else { return .error(404, String(localized: "没有这把钥匙")) }
        store.write("keys.json", keys.filter { ($0["id"] as? String) != id })
        vault.set(nil, for: id)
        for var c in store.companions where (c["key_id"] as? String) == id {
            c["key_id"] = NSNull()
            store.saveCompanion(c)
        }
        return .empty
    }

    /// 这个联系人用哪家、哪把 key（零件包的 ProviderConfig）
    func route(for companion: [String: Any]) -> (ProviderConfig, String)? {
        guard let kid = companion["key_id"] as? String else { return nil }
        return route(key: kid, thinking: (companion["settings"] as? [String: Any])?["thinking"] as? Bool ?? true)
    }

    /// 某一把钥匙（看图 / 画图那张卡挑的，10-15）
    func route(key kid: String, thinking: Bool = false) -> (ProviderConfig, String)? {
        guard let k = keys.first(where: { ($0["id"] as? String) == kid }),
              let secret = vault.get(kid) else { return nil }
        let model = k["chat_model"] as? String ?? ""
        let base = k["base_url"] as? String
        switch k["provider"] as? String {
        case "anthropic": return (ProviderConfig(kind: .anthropic, model: model, thinking: thinking), secret)
        case "gemini": return (ProviderConfig(kind: .gemini, model: model, thinking: thinking), secret)
        case "deepseek": return (ProviderConfig(kind: .openai, baseURL: base ?? "https://api.deepseek.com", model: model, thinking: thinking), secret)
        case "openai": return (ProviderConfig(kind: .openai, baseURL: base, model: model, thinking: thinking), secret)
        default: return (ProviderConfig(kind: .openai, baseURL: base, model: model, thinking: thinking), secret)
        }
    }

    /// 后台小活（估热量、看表情包、排行程、看相册……）：只要一小段 JSON / 一句话，不让模型先想。
    /// 想的那段会吃掉不大的 max_tokens，正文空了就静悄悄失败（10-08：饮食一直不估热量）
    func quietRoute(for companion: [String: Any]) -> (ProviderConfig, String)? {
        guard var r = route(for: companion) else { return nil }
        r.0.thinking = false
        return r
    }

    /// 加钥匙时选模型（照服务器 llm/catalog.py，外加 OpenAI / Gemini 几个常用的）
    static let catalog: [[String: Any]] = [
        ["id": "deepseek-flash", "provider": "deepseek", "label": "DeepSeek-V4.1-Flash", "price_in": 0.3, "price_cache_read": 0.006, "price_out": 1.2, "thinking": true],
        ["id": "deepseek-v4-pro", "provider": "deepseek", "label": "DeepSeek-V4-Pro", "price_in": 1.32, "price_cache_read": 0.044, "price_out": 3.96, "thinking": true],
        ["id": "claude-sonnet-5", "provider": "anthropic", "label": "claude-sonnet-5", "price_in": 2.0, "price_cache_read": 0.2, "price_out": 10.0, "thinking": true],
        ["id": "claude-opus-5", "provider": "anthropic", "label": "claude-opus-5", "price_in": 5.0, "price_cache_read": 0.5, "price_out": 25.0, "thinking": true],
        ["id": "claude-haiku-4-5", "provider": "anthropic", "label": "claude-haiku-4-5", "price_in": 1.0, "price_cache_read": 0.1, "price_out": 5.0, "thinking": false],
        ["id": "gemini-3.5-flash-lite", "provider": "gemini", "label": "gemini-3.5-flash-lite", "price_in": 0.1, "price_cache_read": 0.025, "price_out": 0.4, "thinking": true],
    ]

    // MARK: - 联系人

    /// 服务器 Settings() 的出厂值（从 server/brain/settings.py 直接导出来的，10-04）
    static let defaultSettings: [String: Any] = [
        "lang": "zh", "tz": TimeZone.current.identifier, "user_name": "", "user_pronoun": "she", "warmth": "mid", "initiative": "mid",
        "humor": "mid", "recall_level": "medium", "careful_read": true, "recall_probe": true, "memory_length": NSNull(),
        "reply_wait": 10, "max_bubbles": 6, "long_mode": false, "thinking": true, "thinking_mode": NSNull(),
        "ledger_same_as_chat": false, "sentinels": ["thinking_style": true, "tool_reminder": true, "remembered": true],
        "tool_reminder_every": 5, "thinking_style_text": "", "monologue_examples": "", "bare_mode": false, "thinking_style_every": 3, "inner_voice": false, "inner_voice_style": "", "monologue_retry": false, "bilingual": false, "bilingual_lang": "English", "bilingual_to": "", "bilingual_by": "key", "injections": [Any](), "patrol_level": "mid",
        "heartbeat_on": true, "morning_on": true, "sleep_from": "00:00", "sleep_to": "08:00", "patrol_overrides": [String: Any](),
        "relationship": "", "cache_keepalive": false, "diary_on": true, "offline_life": false, "talk_rules": "", "diary_chars": 600, "voice_mode": "sometimes",
        "full_handbook": true,      // Lite 说明书开关（10-08 Aporia：默认开）
        "voice_id": "", "voice_name": "",
        "memory_server": LocalMemory.serverID,   // 新联系人默认接本地记忆库（10-11 第 20 版）
    ]

    static func defaultPersona(name: String) -> [String: Any] {
        ["name": name, "personality": "", "style": "", "call_user": "", "imported": "", "gender": "", "traits": [String](),
         "factory": [String]()]
    }

    func createCompanion(name: String?, persona: [String: Any]? = nil, settings extra: [String: Any] = [:]) -> [String: Any] {
        let id = UUID().uuidString.lowercased()
        let first = store.companions.first
        var s = Self.defaultSettings
        if let fs = first?["settings"] as? [String: Any] { s["tz"] = fs["tz"]; s["lang"] = fs["lang"] }
        s["lang"] = (Bundle.main.preferredLocalizations.first ?? "zh").hasPrefix("en") ? "en" : "zh"   // 跟 App 界面的语言走
        s["user_name"] = profile["name"]; s["user_pronoun"] = profile["pronoun"]
        for (k, v) in extra { s[k] = v }
        let n = (name ?? "").trimmingCharacters(in: .whitespaces)
        var c: [String: Any] = ["id": id, "persona": persona ?? Self.defaultPersona(name: n.isEmpty ? "TA" : String(n.prefix(20))),
                                "settings": s, "avatar_ver": 0, "created_at": LocalStore.iso(Date())]
        c["key_id"] = keys.first?["id"] ?? NSNull()
        store.saveCompanion(c)
        let conv = newConversation(id, incognito: false)
        return companionOut(c, full: true).merging(["conversation": conv["id"] ?? ""]) { a, _ in a }
    }

    func companionOut(_ c: [String: Any], full: Bool = false) -> [String: Any] {
        let id = c["id"] as? String ?? ""
        let persona = c["persona"] as? [String: Any] ?? [:]
        let settings = c["settings"] as? [String: Any] ?? [:]
        let convs = store.conversations.filter { ($0["companion_id"] as? String) == id && ($0["incognito"] as? Bool) != true }
        let weekAgo = Date().addingTimeInterval(-7 * 86400)
        var week = 0, total = 0
        for cv in convs {
            let msgs = store.messages(cv["id"] as? String ?? "")
            total += msgs.count
            week += msgs.filter { LocalStore.date($0["at"]) >= weekAgo }.count
        }
        var out: [String: Any] = ["id": id, "name": persona["name"] as? String ?? "TA", "key_id": c["key_id"] ?? NSNull(),
                                  "avatar_ver": c["avatar_ver"] ?? 0, "created_at": c["created_at"] ?? LocalStore.iso(Date()),
                                  "week_messages": week, "total_messages": total,
                                  "relationship": settings["relationship"] ?? ""]
        if full { out["persona"] = persona; out["settings"] = settings }
        return out
    }

    private func companionFull(_ id: String) -> LocalResponse {
        guard let c = store.companion(id) else { return .error(404, String(localized: "没有这个联系人")) }
        _ = LocalFriends.wechatID(store, c)            // 没有微信号就先起一个
        return .json(companionOut(store.companion(id) ?? c, full: true))
    }

    private func patchCompanion(_ id: String, _ body: [String: Any]) -> LocalResponse {
        guard var c = store.companion(id) else { return .error(404, String(localized: "没有这个联系人")) }
        if let s = body["settings"] as? [String: Any] {
            var merged = (c["settings"] as? [String: Any] ?? [:]).merging(s) { _, new in new }
            if (s["long_mode"] as? Bool) == false { merged["scene_place"] = nil }   // 回线上：地图上那场线下结束了
            c["settings"] = merged
        }
        if var p = body["persona"] as? [String: Any] {
            if let w = p["wechat_id"] as? String {
                let (ok, why) = LocalFriends.validate(store, companion: id, w)
                guard let ok else { return .error(400, why) }
                p["wechat_id"] = ok
            }
            var cur = c["persona"] as? [String: Any] ?? [:]
            for (k, v) in p { cur[k] = v }
            c["persona"] = cur
        }
        if body.keys.contains("key_id") { c["key_id"] = body["key_id"] ?? NSNull() }
        store.saveCompanion(c)
        return .json(companionOut(c, full: true))
    }

    private func deleteCompanion(_ id: String) -> LocalResponse {
        guard store.companions.count > 1 else { return .error(400, String(localized: "至少留一个联系人")) }
        for cv in store.conversations where (cv["companion_id"] as? String) == id {
            _ = deleteConversation(cv["id"] as? String ?? "")
        }
        LocalGroups.companionRemoved(self, id)          // 自动退群，说过的话留着
        store.companions = store.companions.filter { ($0["id"] as? String) != id }
        store.removeFile("avatar-\(id).jpg")
        LocalMemory.dropVault(store, companion: id)     // TA 单独那本记忆一起删（共用的不动）
        return .empty
    }

    private func syncAdvanced(_ id: String) -> LocalResponse {
        guard let src = store.companion(id)?["settings"] as? [String: Any] else { return .error(404, "") }
        let adv = ["careful_read", "heartbeat_on", "injections", "ledger_same_as_chat", "max_bubbles", "patrol_overrides",
                   "recall_probe", "reply_wait", "sentinels", "thinking", "thinking_mode", "thinking_style_text", "monologue_examples", "tool_reminder_every", "full_handbook", "thinking_style_every", "inner_voice", "inner_voice_style", "monologue_retry"]
        var n = 0
        for var c in store.companions where (c["id"] as? String) != id {
            var s = c["settings"] as? [String: Any] ?? [:]
            for k in adv { s[k] = src[k] }
            c["settings"] = s
            store.saveCompanion(c)
            n += 1
        }
        return .json(["copied": n])
    }

    private func avatar(_ id: String) -> LocalResponse {
        guard let d = try? Data(contentsOf: store.fileURL("avatar-\(id).jpg")) else { return .error(404, String(localized: "还没有头像")) }
        return .data(d, mime: "image/jpeg")
    }

    private func putAvatar(_ id: String, _ r: LocalRequest) -> LocalResponse {
        guard var c = store.companion(id), let file = r.form.files["file"]?.first else { return .error(400, String(localized: "图读不了")) }
        store.saveFile(Self.squareJPEG(file.data) ?? file.data, name: "avatar-\(id).jpg")
        let ver = (c["avatar_ver"] as? Int ?? 0) + 1
        c["avatar_ver"] = ver
        store.saveCompanion(c)
        return .json(["avatar_ver": ver])
    }

    static func squareJPEG(_ data: Data) -> Data? {
        guard let img = UIImage(data: data) else { return nil }
        let side = min(img.size.width, img.size.height)
        let k = 512 / side
        let r = UIGraphicsImageRenderer(size: CGSize(width: 512, height: 512))
        return r.image { _ in
            img.draw(in: CGRect(x: -(img.size.width - side) / 2 * k, y: -(img.size.height - side) / 2 * k,
                                width: img.size.width * k, height: img.size.height * k))
        }.jpegData(compressionQuality: 0.88)
    }

    // MARK: - 导入角色卡（照服务器 /companions/import：卡的名字、人设、头像、世界书只给它、开场白当第一句）

    private func importCard(_ r: LocalRequest, preview: Bool) -> LocalResponse {
        let form = r.form
        guard let file = form.files["file"]?.first else { return .error(400, String(localized: "要带一张卡")) }
        let lang: Lang = (Bundle.main.preferredLocalizations.first ?? "zh").hasPrefix("en") ? .en : .zh
        let user = profile["name"] as? String ?? ""
        let card: ParsedCard
        do { card = try CardParser.parse(file.data, userName: user, lang: lang, fileName: file.name) }
        catch let e as CardError { return .error(400, e.message) }
        catch { return .error(400, String(localized: "这张卡读不出来")) }
        if preview {
            return .json(["name": card.name, "greetings": card.greetings, "persona": card.persona,
                          "lore": card.lore.count, "lore_skipped": card.skippedLore, "creator_notes": card.creatorNotes,
                          "persona_cost": NSNull(), "has_image": card.avatarPNG != nil])
        }
        let style = form.fields["style"] ?? "chat"
        let greeting = Int(form.fields["greeting"] ?? "0") ?? 0
        var persona = Self.defaultPersona(name: card.name)
        persona["imported"] = card.persona
        var made = createCompanion(name: card.name, persona: persona,
                                   settings: ["relationship": "card", "patrol_level": "low", "long_mode": style == "long"])
        let cid = made["id"] as? String ?? ""
        if let png = card.avatarPNG, var c = store.companion(cid) {
            store.saveFile(Self.squareJPEG(png) ?? png, name: "avatar-\(cid).jpg")
            c["avatar_ver"] = 1
            store.saveCompanion(c)
            made["avatar_ver"] = 1
        }
        var lore = store.collection("lore")
        for e in card.lore {
            lore.append(LocalRooms.loreOut(e, companion: cid, id: store.nextID("lore")))
        }
        store.saveCollection("lore", lore)
        if let conv = made["conversation"] as? String, !card.greetings.isEmpty {
            store.addMessage(conv, role: "assistant", text: card.greetings[max(0, min(greeting, card.greetings.count - 1))])
        }
        made["lore"] = card.lore.count
        made["lore_skipped"] = card.skippedLore
        return .json(made, status: 201)
    }

    // MARK: - 窗口

    @discardableResult
    /// alt = 小号（user_name / about_me / relationship）：这个窗口里它把你当成另一个人
    func newConversation(_ companion: String, incognito: Bool, alt: [String: Any]? = nil) -> [String: Any] {
        let now = LocalStore.iso(Date())
        var c: [String: Any] = ["id": UUID().uuidString.lowercased(), "companion_id": companion, "incognito": incognito,
                                "created_at": now, "last_at": now, "title": ""]
        if let alt, let n = alt["user_name"] as? String, !n.trimmingCharacters(in: .whitespaces).isEmpty {
            c["alt"] = ["id": (alt["id"] as? String) ?? UUID().uuidString.lowercased(), "user_name": n,
                        "about_me": alt["about_me"] as? String ?? "", "relationship": alt["relationship"] as? String ?? ""]
        }
        store.saveConversation(c)
        return c
    }

    /// 平常的你说话的窗口（不是无痕、不是小号）：信、私选、塔罗回看、记忆库都只认这些
    static func isMainWindow(_ c: [String: Any]) -> Bool { (c["incognito"] as? Bool) != true && c["alt"] == nil }

    func conversationOut(_ c: [String: Any]) -> [String: Any] {
        let msgs = store.messages(c["id"] as? String ?? "")
        var out = c
        out["preview"] = msgs.last?["call_end"] as? Bool == true || msgs.last?["ring"] != nil ? (msgs.last?["divider"] as? String ?? "")      // 列表里写「📞 通话时长」，不写纸条
            : String((msgs.last?["text"] as? String ?? "").prefix(40))
        out["first"] = String((msgs.first?["text"] as? String ?? "").prefix(20))
        out["title"] = c["title"] ?? ""
        return out
    }

    private func conversationsOf(_ companion: String) -> [[String: Any]] {
        store.conversations.filter { ($0["companion_id"] as? String) == companion }
            .sorted { LocalStore.date($0["last_at"]) > LocalStore.date($1["last_at"]) }
            .map(conversationOut)
    }

    private func patchConversation(_ id: String, _ body: [String: Any]) -> LocalResponse {
        guard var c = store.conversation(id) else { return .error(404, String(localized: "没有这个窗口")) }
        if let t = body["title"] as? String { c["title"] = String(t.prefix(30)) }
        store.saveConversation(c)
        return .json(conversationOut(c))
    }

    func deleteConversation(_ id: String) -> LocalResponse {
        brain.drop(id)
        // 小号的对话删了 = 好友也删了（以后能再加）
        store.saveCollection("friend_requests", store.collection("friend_requests").filter { ($0["conversation"] as? String) != id })
        store.conversations = store.conversations.filter { ($0["id"] as? String) != id }
        try? FileManager.default.removeItem(at: store.root.appendingPathComponent("conversations/\(id).json"))
        return .empty
    }

    // MARK: - 消息

    func companion(ofConversation conv: String) -> [String: Any]? {
        guard let cid = store.conversation(conv)?["companion_id"] as? String else { return nil }
        return store.companion(cid)
    }

    /// 一条消息按谁的设定拆气泡：群里看说话的那个 TA
    func settings(forMessage m: [String: Any], in conv: String) -> [String: Any] {
        let comp = (m["speaker"] as? String).flatMap { store.companion($0) } ?? companion(ofConversation: conv)
        return comp?["settings"] as? [String: Any] ?? [:]
    }

    func messageOut(_ m: [String: Any], settings: [String: Any]) -> [String: Any] {
        let role = m["role"] as? String ?? "user"
        let text = m["text"] as? String ?? ""
        // 电话挂了那一条（10-31）：正文是递给 TA 的纸条，屏幕上只画 divider 那行「📞 通话时长」
        // 电话里说的（10-31 Aporia：照微信，聊天里只留一行「📞 通话时长」，点开再看全文）：也不出气泡
        let inCall = m["call_end"] as? Bool == true || m["call"] as? Bool == true || m["ring"] != nil     // 未接 / 拒绝那行也只画灰字（10-31）
        let bubbles: [String] = inCall ? [] : role == "assistant"
            ? Bubbles.split(text, cap: settings["max_bubbles"] as? Int ?? 6, offline: settings["long_mode"] as? Bool ?? false)
            : (m["parts"] as? [String] ?? [text])
        let atts = (m["attachments"] as? [String] ?? []).compactMap { attachmentPublic($0) }
        // 语音条（10-04）：气泡里给逐字稿，并排一列 voices（null = 文字）；按文字指纹找，换了嗓子老的还在
        let clips = m["voice_clips"] as? [String: Any] ?? [:]
        let voices: [Any] = bubbles.map { b in
            LocalVoice.isVoice(b) ? (clips[LocalVoice.sha(LocalVoice.body(b))] ?? NSNull()) : NSNull()
        }
        // 还没念的（10-31 按需念）：并排一列 lazy_voices，App 画成语音条、点了才念；没 key 了就还是文字
        let canSpeak = role == "assistant" && LocalVoice.key(self) != nil
        let lazy: [Any] = bubbles.map { b in
            canSpeak && LocalVoice.isVoice(b) && clips[LocalVoice.sha(LocalVoice.body(b))] == nil ? LocalVoice.lazyRef(b) as Any : NSNull()
        }
        let shown = bubbles.map { LocalVoice.isVoice($0) ? LocalVoice.asText($0) : $0 }
        return ["id": m["id"] ?? 0, "role": role, "text": text, "thinking": m["thinking"] ?? "",
                "thinking_ms": m["thinking_ms"] ?? NSNull(), "inner_voice": m["inner_voice"] ?? "", "at": m["at"] ?? "", "bubbles": shown, "voices": voices, "lazy_voices": lazy, "cards": inCall ? [Any]() : m["cards"] ?? [Any](),
                "reaction": m["reaction"] ?? NSNull(), "reactions": Self.perBubble(m, count: shown.count),
                "attachments": atts, "divider": m["divider"] ?? NSNull(),
                "translations": (m["translations"] as? [Any]).flatMap { $0.count == shown.count ? $0 : nil } ?? NSNull(),
                "speaker": m["speaker"] ?? NSNull(), "speaker_name": m["speaker_name"] ?? NSNull(),
                "call": m["call"] as? Bool ?? false, "call_end": m["call_end"] as? Bool ?? false, "call_id": m["call_id"] ?? NSNull(), "ring": m["ring"] ?? NSNull()]
    }

    private func messages(_ conv: String, _ q: [String: String]) -> LocalResponse {
        let comp = companion(ofConversation: conv)
        guard comp != nil || LocalGroups.group(store, conv) != nil else { return .error(404, String(localized: "没有这个窗口")) }
        // 它的一天：今天第一次进这个人的聊天，后台排今天的行程（没世界先起世界）
        if let cid = comp?["id"] as? String, LocalMap.lifeOn(store, cid), LocalMap.today(store, cid).isEmpty {
            Task { await LocalMap.ensureDay(self, cid) }
        }
        let all = store.messages(conv)
        let limit = max(1, min(Int(q["limit"] ?? "200") ?? 200, 500))
        var picked: [[String: Any]]
        var hasMore: Bool?
        if let b = q["before"].flatMap(Int.init) {
            let older = all.filter { ($0["id"] as? Int ?? 0) < b }
            picked = Array(older.suffix(limit))
            hasMore = older.count > limit
        } else if let day = q["day"] {
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = .current
            picked = Array(all.filter { f.string(from: LocalStore.date($0["at"])) == day }.prefix(limit))
        } else {
            let after = Int(q["after"] ?? "0") ?? 0
            picked = Array(all.filter { ($0["id"] as? Int ?? 0) > after }.suffix(limit))
        }
        var out: [String: Any] = ["messages": picked.map { messageOut($0, settings: settings(forMessage: $0, in: conv)) }, "busy": brain.busy(conv)]
        if let hasMore { out["has_more"] = hasMore }
        return .json(out)
    }

    private func search(_ conv: String, _ q: String) -> LocalResponse {
        let needle = q.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return .error(400, String(localized: "要搜什么？")) }
        let all = store.messages(conv)
        func brief(_ m: [String: Any]) -> [String: Any] {
            ["id": m["id"] ?? 0, "role": m["role"] ?? "", "text": m["text"] ?? "", "thinking": m["thinking"] ?? "", "at": m["at"] ?? ""]
        }
        var hits: [[String: Any]] = []
        for (i, m) in all.enumerated().reversed() where (m["text"] as? String ?? "").localizedCaseInsensitiveContains(needle) {
            hits.append(["message": brief(m), "before": i > 0 ? brief(all[i - 1]) : NSNull(),
                         "after": i + 1 < all.count ? brief(all[i + 1]) : NSNull()])
            if hits.count >= 50 { break }
        }
        return .json(["hits": hits])
    }

    private func calendar(_ conv: String) -> LocalResponse {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = .current
        var days: [String: (Int, Int)] = [:]
        for m in store.messages(conv) {
            let d = f.string(from: LocalStore.date(m["at"]))
            let id = m["id"] as? Int ?? 0
            let cur = days[d] ?? (0, id)
            days[d] = (cur.0 + 1, min(cur.1, id))
        }
        return .json(["days": days.keys.sorted().map { ["day": $0, "count": days[$0]!.0, "first_id": days[$0]!.1] }])
    }

    /// 表情按气泡记（10-11）：reactions = {"第几泡": 表情}；老的整条记在 reaction 上，画在最后一泡（那泡自己有就让它）
    static func perBubble(_ m: [String: Any], count: Int) -> [Any] {
        let rs = m["reactions"] as? [String: String] ?? [:]
        var out: [Any] = (0..<count).map { rs[String($0)] ?? NSNull() }
        if count > 0, out[count - 1] is NSNull, let old = m["reaction"] as? String, !old.isEmpty { out[count - 1] = old }
        return out
    }

    private func react(_ mid: Int?, _ emoji: String?, bubble: Int?) -> LocalResponse {
        guard let mid, let (conv, i) = store.locate(message: mid) else { return .error(404, String(localized: "没有这条消息")) }
        var list = store.messages(conv)
        guard let b = bubble, b >= 0 else {                         // 老的整条记法（不带第几泡）
            list[i]["reaction"] = emoji ?? NSNull()
            list[i]["reaction_told"] = emoji == nil ? nil : false   // 下一轮告诉它一次（LocalNotes）
            store.saveMessages(conv, list)
            return .empty
        }
        let settings = settings(forMessage: list[i], in: conv)
        let parts = Bubbles.split(list[i]["text"] as? String ?? "", cap: settings["max_bubbles"] as? Int ?? 6,
                                  offline: settings["long_mode"] as? Bool ?? false)
        let quote = parts.indices.contains(b) ? (LocalVoice.isVoice(parts[b]) ? LocalVoice.asText(parts[b]) : parts[b]) : ""
        if b == parts.count - 1 {                                   // 最后一泡上画着老的那个：换 / 取消都把它清掉
            list[i]["reaction"] = nil
            list[i]["reaction_told"] = nil
        }
        var rs = list[i]["reactions"] as? [String: String] ?? [:]
        rs[String(b)] = emoji
        list[i]["reactions"] = rs.isEmpty ? nil : rs
        // 没告诉它的：同一泡只留最新的；取消了就不说
        var news = (list[i]["reaction_news"] as? [[String: Any]] ?? []).filter { $0["b"] as? Int != b }
        if let emoji { news.append(["b": b, "e": emoji, "q": quote]) }
        list[i]["reaction_news"] = news.isEmpty ? nil : news
        store.saveMessages(conv, list)
        return .empty
    }

    // MARK: - 附件（你发的照片、文件）

    private func upload(_ conv: String, _ r: LocalRequest) -> LocalResponse {
        guard let file = r.form.files["file"]?.first else { return .error(400, String(localized: "没收到文件")) }
        let id = UUID().uuidString.lowercased()
        let mime = file.name.lowercased().hasSuffix(".pdf") ? "application/pdf"
            : (UIImage(data: file.data) != nil ? "image/jpeg" : "text/plain")
        let kind = mime.hasPrefix("image/") ? "image" : "file"
        store.saveFile(file.data, name: "att-\(id)")
        var all = store.collection("attachments")
        all.append(["id": id, "conversation": conv, "kind": kind, "name": file.name, "mime": mime, "size": file.data.count])
        store.saveCollection("attachments", all)
        return .json(attachmentPublic(id) ?? [:], status: 201)
    }

    func attachmentPublic(_ id: String) -> [String: Any]? {
        guard let a = store.collection("attachments").first(where: { ($0["id"] as? String) == id }) else { return nil }
        var out: [String: Any] = ["id": id, "kind": a["kind"] ?? "file", "name": a["name"] ?? "", "mime": a["mime"] ?? "", "size": a["size"] ?? 0]
        if let secs = a["seconds"] { out["seconds"] = secs }                    // TA 的语音：几秒
        return out
    }

    private func attachment(_ id: String) -> LocalResponse {
        guard let a = store.collection("attachments").first(where: { ($0["id"] as? String) == id }),
              let d = try? Data(contentsOf: store.fileURL("att-\(id)")) else { return .error(404, String(localized: "没有这个附件")) }
        return .data(d, mime: a["mime"] as? String ?? "application/octet-stream")
    }
}
#endif
