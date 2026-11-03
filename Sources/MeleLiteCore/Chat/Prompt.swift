import Foundation

public struct PromptInput: Sendable {
    public var contact: Contact
    public var identity: Identity
    public var history: [Message]
    public var loreHits: [LoreEntry]
    public var stickers: [Sticker]
    public var peekResult: String?
    public var lang: Lang
    public var now: Date
    public var timeZone: TimeZone
    public var currentImage: Data?

    public init(contact: Contact, identity: Identity, history: [Message], loreHits: [LoreEntry] = [], stickers: [Sticker] = [],
                peekResult: String? = nil, lang: Lang, now: Date = Date(), timeZone: TimeZone = .current, currentImage: Data? = nil) {
        self.contact = contact; self.identity = identity; self.history = history; self.loreHits = loreHits
        self.stickers = stickers; self.peekResult = peekResult; self.lang = lang; self.now = now
        self.timeZone = timeZone; self.currentImage = currentImage
    }
}

/// 拼给模型的一整份：system = 底子 + 你是谁 + 人设 + 对面这个人 + 线上线下 + 表情包（不常变，缓存吃得住）；
/// context = 现在几点 + 世界书 + 翻到的东西（每轮变，贴在 TA 最新那句后面）；
/// turns = 最近的聊天（同一方连着的几条并成一段，太长从最早丢）。
public enum Prompt {
    public static func build(_ i: PromptInput, budgetChars: Int = 24000) -> ChatRequest {
        ChatRequest(system: system(i), turns: turns(i, budget: budgetChars), context: context(i))
    }

    /// 每轮会变的：现在几点、世界书命中、翻到的
    static func context(_ i: PromptInput) -> String {
        let zh = i.lang == .zh
        // 开头一行跟服务器 context.HEADER 一样：后面这些是 app 附的，不是对方说的（10-08：Lite 之前没这行）
        var parts = [(zh ? "〔以下是 app 附上的参考，不是对方说的话〕\n" : "〔Notes attached by the app — not the user's words〕\n")
                     + (zh ? "现在是 " : "It's now ") + clock(i.now, i.timeZone, i.lang)]
        if !i.loreHits.isEmpty {
            parts.append((zh ? "## 世界书\n" : "## Lorebook\n") + i.loreHits.map { "### \($0.title)\n\($0.content)" }.joined(separator: "\n\n"))
        }
        if let p = i.peekResult { parts.append((zh ? "## 你翻到的\n" : "## What you found on their phone\n") + p) }
        return parts.joined(separator: "\n\n")
    }

    static func system(_ i: PromptInput) -> String {
        let zh = i.lang == .zh
        let c = i.contact, me = i.identity
        var base = Resources.text("base", i.lang)
        let bare = c.bare == true
        if bare {                        // 本体化（11-03）：开头那句身份和「你有自己的情绪…」换成只讲事实的；标记怎么写那几行照留
            base = base.replacingOccurrences(of: zh ? offlineOpening.zh.0 : offlineOpening.en.0, with: zh ? bareOpening.zh : bareOpening.en)
                .replacingOccurrences(of: zh ? bareFeelings.zh.0 : bareFeelings.en.0, with: zh ? bareFeelings.zh.1 : bareFeelings.en.1)
        } else if c.mode == .offline {          // 线下：底子第一句不写死「在手机上」（照服务器 OFFLINE_OPENING）
            base = base.replacingOccurrences(of: zh ? offlineOpening.zh.0 : offlineOpening.en.0, with: zh ? offlineOpening.zh.1 : offlineOpening.en.1)
        }
        var parts = [base]
        let pack = me.isMain && !bare ? c.relationshipPack?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" : ""   // 本体化：关系只写一句「你们的关系：恋人」
        if !pack.isEmpty { parts.append(pack) }
        parts.append((zh ? "你是 \(c.name)。\n" : "You are \(c.name).\n") + c.persona)
        var who: [String] = []
        if !me.userName.isEmpty { who.append((zh ? "名字：" : "Name: ") + me.userName) }
        if !me.aboutMe.isEmpty { who.append((zh ? "关于 TA：" : "About them: ") + me.aboutMe) }
        if pack.isEmpty, !me.relationship.isEmpty { who.append((zh ? "你们的关系：" : "Your relationship: ") + me.relationship) }
        if !who.isEmpty { parts.append((zh ? "## 对面这个人\n" : "## The person you're talking to\n") + who.joined(separator: "\n")) }
        // 线上那段的「你有自己的一天」看线下生活开关（10-05 Aporia：谈人机恋的有人不喜欢 AI 角色扮演，默认关）
        let talk = c.talkRules?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if bare {                        // 本体化：线上线下只讲格式；用户自己写的说话规矩照放
            parts.append(Resources.mode(c.mode == .online ? "bare_online" : "bare_offline", i.lang) + (talk.isEmpty ? "" : "\n" + talk))
        } else {
        parts.append(c.mode == .online
            ? Resources.mode("online", i.lang)
                .replacingOccurrences(of: "{talk}", with: c.talkRules.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .flatMap { $0.isEmpty ? nil : $0 } ?? Resources.mode("talk", i.lang))   // 说话规矩：用户写了就换成他的（10-05）
                .replacingOccurrences(of: "{life}", with: Resources.mode((c.offlineLife ?? true) ? "life_on" : "life_off", i.lang))
            : Resources.mode("offline", i.lang))
        }
        let stickers = StickerMenu(i.stickers).block(zh: zh)     // 编号表（10-31）：它写 [表情包：#12]
        if !stickers.isEmpty { parts.append(stickers) }
        return parts.joined(separator: "\n\n")
    }

    static let offlineOpening = (
        zh: ("你是一个住在手机 app 里的 AI 伙伴，陪 TA 过日子：记得 TA 说过的事，帮 TA 把生活理顺，也会主动关心 TA。",
             "你是 TA 的 AI 伙伴，陪 TA 过日子：记得 TA 说过的事，也会主动关心 TA。你们现在在哪、是见面还是隔着屏幕，照人设里的场景和你们的对话来。"),
        en: ("You are an AI companion living in a phone app, keeping them company day to day: you remember what they tell you, help them keep life in order, and check in on them.",
             "You are their AI companion, keeping them company day to day: you remember what they tell you and check in on them. Where you are right now, and whether you're together or talking through a screen, follows the scenario in your character and your conversation."))

    static let bareOpening = (zh: "这是一个聊天 app，你在里面跟对方说话。", en: "This is a chat app; you're talking with them here.")
    static let bareFeelings = (
        zh: ("你有自己的情绪和想法：可以开玩笑、可以不同意、可以反问。对方发来图片，你看得见，就着图里的东西聊。", "对方发来图片，你看得见。"),
        en: ("You have your own feelings and opinions: joke around, disagree, ask things back. When they send a photo, you can see it, so talk about what's in it.",
             "When they send a photo, you can see it."))

    static func clock(_ d: Date, _ tz: TimeZone, _ lang: Lang) -> String {
        let f = DateFormatter()
        f.timeZone = tz
        f.locale = Locale(identifier: lang == .zh ? "zh_CN" : "en_US")
        f.dateFormat = lang == .zh ? "yyyy-MM-dd EEEE HH:mm" : "EEEE, d MMM yyyy, HH:mm"
        return f.string(from: d)
    }

    static func turns(_ i: PromptInput, budget: Int) -> [ChatTurn] {
        let byID = Dictionary(i.history.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var merged: [ChatTurn] = []
        for m in i.history {
            var text = m.text
            if let q = m.quoteOf, let orig = byID[q] {
                text = (i.lang == .zh ? "（回复：\(orig.text.prefix(30))）\n" : "(Replying to: \(orig.text.prefix(30)))\n") + text
            }
            if let last = merged.last, last.role == m.role {
                merged[merged.count - 1].text += "\n\n" + text
            } else {
                merged.append(ChatTurn(role: m.role, text: text))
            }
        }
        // 从最早开始丢，直到总字数 ≤ budget；最后一段一定留着
        var total = merged.reduce(0) { $0 + $1.text.count }
        while merged.count > 1, total > budget {
            total -= merged.removeFirst().text.count
        }
        if merged.first?.role == .assistant {
            merged.insert(ChatTurn(role: .user, text: i.lang == .zh ? "（开始聊天）" : "(Chat started)"), at: 0)
        }
        if let img = i.currentImage, let li = merged.lastIndex(where: { $0.role == .user }) {
            merged[li].imageJPEG = img
        }
        return merged
    }
}

/// 读 Resources/{zh,en}/*.md
enum Resources {
    static func text(_ name: String, _ lang: Lang) -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: "md", subdirectory: "Prompts/\(lang.rawValue)"),
              let s = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// modes.md 里 [online] / [offline] / [letter] 各一段
    static func mode(_ key: String, _ lang: Lang) -> String {
        let all = text("modes", lang)
        var out: [String: String] = [:], cur = ""
        for line in all.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("["), line.hasSuffix("]") { cur = String(line.dropFirst().dropLast()); continue }
            out[cur, default: ""] += (out[cur, default: ""].isEmpty ? "" : "\n") + line
        }
        return out[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

/// Lite 版说明书（10-08 Aporia：开关，默认开）。照服务器 manuals/<语言>/lumi.md 改的：只讲 Lite 真会递给它的纸条；
/// 记忆库那几条只在接了记忆库时给（memoryTools = 记一条、翻一下的工具名）；说话那几条只在线上给（线下有自己的规矩）；
/// 〔现在〕那行只在线下生活开着时给（10-08 真 key：关着也写这行，它反而老提自己在天台）
public enum Handbook {
    /// bare = 本体化（11-03）：「说话再补几条」不放（纯文字那条在 bare_online 里）
    public static func text(zh: Bool, online: Bool, life: Bool, memoryTools: (remember: String, search: String)?, bare: Bool = false) -> String {
        let lang: Lang = zh ? .zh : .en
        var notes = section("notes", lang)
        if !life {
            notes = notes.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.contains("〔现在〕") && !$0.contains("[Right now]") }.joined(separator: "\n")
        }
        var parts = [notes]
        if let m = memoryTools {
            parts.append(section("memory", lang).replacingOccurrences(of: "{remember}", with: m.remember)
                .replacingOccurrences(of: "{search}", with: m.search))
        }
        if online && !bare { parts.append(section("talk", lang)) }
        return parts.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    static func section(_ key: String, _ lang: Lang, file: String = "handbook") -> String {
        let all = Resources.text(file, lang)
        var out: [String: String] = [:], cur = ""
        for line in all.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("["), line.hasSuffix("]") { cur = String(line.dropFirst().dropLast()); continue }
            out[cur, default: ""] += (out[cur, default: ""].isEmpty ? "" : "\n") + line
        }
        return out[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

/// 关系包（照 server/brain/persona.relationship_text）：friend / partner / family / buddy / card，别的字 = 自定义（{rel} 换成它），空着 = 朋友
public enum Relationship {
    public static let known = ["friend", "partner", "family", "buddy", "card"]
    public static func pack(_ rel: String, zh: Bool) -> String {
        let r = rel.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = known.contains(r) ? r : (r.isEmpty ? "friend" : "custom")
        return Handbook.section(key, zh ? .zh : .en, file: "relationship").replacingOccurrences(of: "{rel}", with: r)
    }
}
