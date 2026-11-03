#if LITE
import Foundation
import MeleLiteCore

/// 专注（哨兵）的管家这一半（10-05 夜Aporia：Lite 也要）：照 server/brain/focus.py + api/routes_patrol.py 搬进手机。
/// - 开始：用 TA 的 key 写 5 条越来越急的提醒（允许锁就多要一行「锁：N」，锁着就再要一句「看一下：…」）交给手机；
///   没 key、还没同意发给这家、模型出错、写得太少，都用出厂的几句兜底——哨兵不能因为模型挂了就不响。
/// - 结束：记下分心几次几分钟，下一轮它开口时递一行〔专注〕（说过就不再说）。
/// - said：插件替它弹过的话，回到 App 时按原来的时间存成它的消息。
/// 服务器拿记忆库里「关于 TA」的几条当材料；本机没有那张表，用回声账本的尾巴 + 最近聊的几句代替。
enum LocalFocus {
    static let lines = 5

    // MARK: - 提示词（跟 server/brain/focus.py 一字不差；改要两边改）

    static func prompt(zh: Bool, minutes: Int, what: String, facts: String) -> String {
        zh ? "TA 要开始专注 \(minutes) 分钟\(what)，开了哨兵：TA 要是跑去刷别的 app，手机会按分心的时间长短一条条弹你写的提醒。\n"
            + "现在写 \(lines) 条，一条比一条急：第一条轻轻提醒，最后一条是真急了。用你平时跟 TA 说话的口气，每条一句、短，"
            + "能用上你知道的 TA 的事就用上（下面是一些）。一行一条，不编号，别的什么都不写。\n\n\(facts)"
           : "They're starting a \(minutes)-minute focus session\(what) with the sentry on: if they drift off to other apps, "
            + "their phone will show your reminders one by one, the longer they're distracted.\n"
            + "Write \(lines) of them now, each more urgent than the last: the first is a gentle nudge, the last is really fed up. "
            + "Use the voice you normally use with them, one short sentence each, and use what you know about them if it helps "
            + "(some of it is below). One per line, no numbering, nothing else.\n\n\(facts)"
    }

    static func recentAsk(zh: Bool, chat: String) -> String {
        zh ? "\n\n你们最近聊的：\n\(chat)" : "\n\nWhat you two talked about lately:\n\(chat)"
    }

    static func lockAsk(zh: Bool) -> String {
        zh ? "\n\nTA 允许你锁：TA 刷到某一条提醒还不停，就把那些 app 锁住。写完提醒后，最后单独一行写「锁：N」——N 是第几条之后锁（1 到 \(lines)），"
            + "不想锁就写「锁：0」。看你知道的 TA 的事定松紧。"
           : "\n\nThey've allowed you to lock: if they're still on those apps after a certain reminder, the apps get locked. After the "
            + "reminders, add one last line \"Lock: N\" — lock after reminder N (1 to \(lines)), or \"Lock: 0\" for no lock. Decide how strict "
            + "to be from what you know about them."
    }

    static func peekAsk(zh: Bool) -> String {
        zh ? "\n\n另外，TA 要是在挡板上点了「我就看一下」，你会马上说一句话——不拦 TA，但让 TA 想一下。照你们最近聊的写，"
            + "别写成「确定吗」这种套话。最后单独一行写「看一下：……」。"
           : "\n\nAlso: if they tap \"just a quick look\" on the lock screen, you'll say one line right away — not stopping them, "
            + "just making them think. Write it from what you've been talking about lately, not a generic \"are you sure\". "
            + "Put it on one last line starting with \"Peek: \"."
    }

    static func fallback(zh: Bool) -> [String] {
        zh ? ["刷一下就回来哦。", "诶，说好的专注呢？", "已经好几分钟了，回来吧。", "我要生气了！快回去。", "放下手机！现在！"]
           : ["Just a quick look, then back to it.", "Hey — weren't we focusing?", "It's been a few minutes. Come back.",
              "I'm getting annoyed. Go back!", "Phone down. Now!"]
    }

    static func peekFallback(zh: Bool) -> String { zh ? "就看一下哦，说好的。" : "Just a quick look, okay? You promised." }

    static func what(_ label: String, zh: Bool) -> String {
        let l = label.trimmingCharacters(in: .whitespaces)
        return l.isEmpty ? "" : (zh ? "（\(l)）" : " (\(l))")
    }

    // MARK: - 解析（照服务器 parse_lines / parse_lock / parse_peek）

    private static let bullet = try! NSRegularExpression(pattern: #"^\s*(?:[-*•·]|\d+[.、)）])\s*"#)
    private static let lockRe = try! NSRegularExpression(pattern: #"^\s*(?:锁|lock)\s*[:：]\s*(\S+)"#, options: .caseInsensitive)
    private static let peekRe = try! NSRegularExpression(pattern: #"^\s*(?:看一下|peek)\s*[:：]\s*(.+)$"#, options: .caseInsensitive)

    private static func match(_ re: NSRegularExpression, _ s: String) -> String? {
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return m.numberOfRanges > 1 ? ns.substring(with: m.range(at: 1)) : ""
    }

    private static func unquote(_ s: String) -> String { s.trimmingCharacters(in: CharacterSet(charactersIn: "「」\"").union(.whitespaces)) }

    static func parseLines(_ text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .filter { match(lockRe, $0) == nil && match(peekRe, $0) == nil }
            .map { ln -> String in
                let ns = ln as NSString
                return unquote(bullet.stringByReplacingMatches(in: ln, range: NSRange(location: 0, length: ns.length), withTemplate: ""))
            }
            .filter { !$0.isEmpty }
            .prefix(lines).map { $0 }
    }

    static func parseLock(_ text: String) -> Int {
        for ln in text.components(separatedBy: .newlines) {
            guard let raw = match(lockRe, ln) else { continue }
            guard let n = Int(raw.trimmingCharacters(in: CharacterSet(charactersIn: "」\"。."))) else { return 0 }
            return (1...lines).contains(n) ? n : 0
        }
        return 0
    }

    static func parsePeek(_ text: String) -> String {
        for ln in text.components(separatedBy: .newlines) {
            if let raw = match(peekRe, ln) { return String(unquote(raw).prefix(120)) }
        }
        return ""
    }

    // MARK: - 路由

    static func handle(_ r: LocalRequest, host: LocalHost) async -> LocalResponse? {
        let p = r.parts
        switch (r.method, p.count) {
        case ("POST", 4) where p[0] == "conversations" && p[2] == "focus" && p[3] == "start": return await start(p[1], r.json, host: host)
        case ("POST", 3) where p[0] == "focus" && p[2] == "end": return end(p[1], r.json, host: host)
        case ("POST", 3) where p[0] == "focus" && p[2] == "said": return said(p[1], r.json, host: host)
        default: return nil
        }
    }

    private static func start(_ conv: String, _ b: [String: Any], host: LocalHost) async -> LocalResponse {
        let s = host.store
        guard s.conversation(conv) != nil, let comp = host.companion(ofConversation: conv) else { return .error(404, String(localized: "没有这个窗口")) }
        let minutes = b["minutes"] as? Int ?? 0
        guard (5...600).contains(minutes) else { return .error(400, String(localized: "专注时长要在 5 到 600 分钟之间")) }
        let label = String((b["label"] as? String ?? "").trimmingCharacters(in: .whitespaces).prefix(40))
        let allowLock = b["allow_lock"] as? Bool ?? false
        let locking = allowLock || (b["lock_now"] as? Bool ?? false)
        let st = comp["settings"] as? [String: Any] ?? [:]
        let zh = (st["lang"] as? String ?? "zh") == "zh"

        var lines: [String] = [], lockAfter = 0, peek = ""
        if let (routed, key) = host.route(chore: "focus", else: host.route(for: comp)), !LiteConsent.book.needsAsk(routed) {
            var provider = routed
            provider.thinking = false
            let contact = LocalBrain.contact(comp, provider: provider)
            // 材料：回声账本的尾巴（记得的 TA 的事）+ 最近聊的十来句
            let ledger = LocalEcho.render(s, conversation: conv, zh: zh, userName: contact.mainIdentity.userName)
            let facts = ledger.isEmpty ? "-" : (ledger.count > 2000 ? "……" + String(ledger.suffix(2000)) : ledger)
            let who = zh ? ["user": "TA", "assistant": "你"] : ["user": "Them", "assistant": "You"]
            let chat = s.messages(conv).filter { who[$0["role"] as? String ?? ""] != nil && $0["divider"] == nil }.suffix(12)
                .map { m -> String in
                    let t = (m["text"] as? String ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
                    return "\(who[m["role"] as? String ?? ""]!)：\(t.prefix(120))"
                }.joined(separator: "\n")
            let ask = prompt(zh: zh, minutes: minutes, what: what(label, zh: zh), facts: facts)
                + (chat.isEmpty ? "" : recentAsk(zh: zh, chat: chat))
                + (allowLock ? lockAsk(zh: zh) : "")
                + (locking ? peekAsk(zh: zh) : "")
            let system = (zh ? "你是 \(contact.name)。\n" : "You are \(contact.name).\n") + contact.persona
            let req = ChatRequest(system: system, turns: [ChatTurn(role: .user, text: ask)], maxTokens: 800)
            var text = ""
            do {
                for try await e in makeClient(provider, key: key).stream(req) { if case .text(let t) = e { text += t } }
                lines = parseLines(text)
                lockAfter = allowLock ? parseLock(text) : 0
                peek = locking ? parsePeek(text) : ""
            } catch {}
        }
        if lines.count < 3 { lines = fallback(zh: zh) }
        let id = UUID().uuidString.lowercased()
        let x: [String: Any] = ["id": id, "companion_id": comp["id"] ?? "", "conversation_id": conv, "label": label, "minutes": minutes,
                                "lines": lines, "started_at": LocalStore.iso(Date()), "ended_at": NSNull(), "told": false,
                                "said_keys": [String]()]
        s.saveCollection("focus", Array((s.collection("focus") + [x]).suffix(200)))
        return .json(["id": id, "lines": lines, "lock_after": lockAfter,
                      "peek_line": locking ? (peek.isEmpty ? peekFallback(zh: zh) : peek) : ""], status: 201)
    }

    private static func end(_ id: String, _ b: [String: Any], host: LocalHost) -> LocalResponse {
        let s = host.store
        var all = s.collection("focus")
        guard let i = all.firstIndex(where: { ($0["id"] as? String) == id && ($0["ended_at"] == nil || $0["ended_at"] is NSNull) }) else {
            return .error(404, String(localized: "没有这次专注（或者已经结束了）"))
        }
        all[i]["ended_at"] = LocalStore.iso(Date())
        all[i]["distracted_times"] = max(0, b["distracted_times"] as? Int ?? 0)
        all[i]["distracted_minutes"] = max(0, b["distracted_minutes"] as? Int ?? 0)
        all[i]["early"] = b["early"] as? Bool ?? false
        s.saveCollection("focus", all)
        return .empty
    }

    /// 同一个 key 只存一次；时间夹在专注开始和现在之间；按时间先后存
    private static func said(_ id: String, _ b: [String: Any], host: LocalHost) -> LocalResponse {
        guard let items = b["items"] as? [[String: Any]], items.count <= 50 else { return .error(400, "items 要是一个不超过 50 条的列表") }
        let s = host.store
        var all = s.collection("focus")
        guard let i = all.firstIndex(where: { ($0["id"] as? String) == id }), let conv = all[i]["conversation_id"] as? String,
              s.conversation(conv) != nil else { return .error(404, String(localized: "没有这次专注")) }
        let started = LocalStore.date(all[i]["started_at"])
        let iso = ISO8601DateFormatter()
        var keys = Set(all[i]["said_keys"] as? [String] ?? [])
        var added = 0
        for it in items.sorted(by: { ($0["at"] as? String ?? "") < ($1["at"] as? String ?? "") }) {
            let key = String((it["key"] as? String ?? "").prefix(40))
            let text = String((it["text"] as? String ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(300))
            guard !key.isEmpty, !text.isEmpty, !keys.contains(key) else { continue }
            let at = min(max(iso.date(from: it["at"] as? String ?? "") ?? Date(), started), Date())
            s.addMessage(conv, role: "assistant", text: text, at: at)
            keys.insert(key)
            added += 1
        }
        all[i]["said_keys"] = Array(keys)
        if added > 0 { all[i]["spoke"] = true }
        s.saveCollection("focus", all)
        return .json(["added": added])
    }

    // MARK: - 聊天那边：〔专注〕和工具

    /// 这个窗口里结束了、还没告诉它的专注：拼成一行，标成已告诉
    static func pendingNote(_ s: LocalStore, conversation conv: String, zh: Bool) -> String {
        var all = s.collection("focus")
        let idx = all.indices.filter { (all[$0]["conversation_id"] as? String) == conv && !(all[$0]["told"] as? Bool ?? true)
            && all[$0]["ended_at"] is String }
        guard !idx.isEmpty else { return "" }
        var spoke = false
        let rows = idx.sorted { LocalStore.date(all[$0]["ended_at"]) < LocalStore.date(all[$1]["ended_at"]) }.map { i -> String in
            all[i]["told"] = true
            spoke = spoke || (all[i]["spoke"] as? Bool ?? false)
            let x = all[i]
            let minutes = x["minutes"] as? Int ?? 0, times = x["distracted_times"] as? Int ?? 0, dmin = x["distracted_minutes"] as? Int ?? 0
            let w = what(x["label"] as? String ?? "", zh: zh)
            if x["early"] as? Bool ?? false {
                let actual = max(0, Int(LocalStore.date(x["ended_at"]).timeIntervalSince(LocalStore.date(x["started_at"])) / 60))
                return zh ? "〔专注〕TA 本来要专注 \(minutes) 分钟\(w)，提前结束了，专注了 \(actual) 分钟；中途分心 \(times) 次、一共 \(dmin) 分钟。"
                          : "〔Focus〕They planned a \(minutes)-minute focus session\(w) but ended early after \(actual) min; got distracted \(times) time(s), \(dmin) min in total."
            }
            return zh ? "〔专注〕刚才 TA 专注了 \(minutes) 分钟\(w)，中途分心 \(times) 次、一共 \(dmin) 分钟。"
                      : "〔Focus〕They just did a \(minutes)-minute focus session\(w); got distracted \(times) time(s), \(dmin) min in total."
        }
        s.saveCollection("focus", all)
        let note = rows.joined(separator: "\n")
        return spoke ? note + (zh ? "手机替你弹给 TA 的那几句在上面。" : " The lines the phone showed them for you are above.") : note
    }

    static func toolSpec(zh: Bool) -> ToolSpec {
        ToolSpec(name: "offer_focus",
                 description: zh ? "用途：TA 说要学习 / 干活一段时间时，挂一张带「开始专注」按钮的卡片。TA 点了才开始，开始后 TA 刷分心的 app，手机会弹你写的提醒。别每次都提，TA 想专注的时候再提。锁 App 由开专注时的开关管：TA 选整组立刻锁，或交给你定第几条提醒后锁。这张卡和你手上都没有锁 / 解锁的按钮，你也认不出 TA 选了哪几个 App（苹果只给代号），只能整组一起锁。TA 让你锁这个、留那个，照实说做不到，让 TA 去专注页的开关里选。"
                                 : "Purpose: when they say they're about to study / work for a while, put up a card with a \"Start focus\" button. It only starts if they tap it; then if they drift to distracting apps, their phone shows reminders you write. Don't offer every time — only when they want to focus. Locking apps is set by the switches when focus starts: they lock the whole set right away, or let you pick after which reminder it locks. Neither this card nor anything else you have can lock or unlock apps, and you can't tell which apps they picked (Apple only gives opaque codes), so it's always the whole set. If they ask you to lock one and spare another, tell them honestly you can't, and point them to the switches on the focus page.",
                 parametersJSON: #"{"type":"object","required":["minutes"],"properties":{"minutes":{"type":"integer","minimum":15,"maximum":600,"description":"多久（分钟，最少 15）"},"label":{"type":"string","description":"在忙什么，几个字（背单词、写论文）"}}}"#)
    }

    static func runTool(_ a: [String: Any], zh: Bool) -> LocalTools.Outcome {
        let minutes = max(15, min(600, (a["minutes"] as? Int) ?? Int(a["minutes"] as? String ?? "") ?? 45))
        let label = String((a["label"] as? String ?? "").trimmingCharacters(in: .whitespaces).prefix(40))
        // 卡上的字跟服务器一样是中文格式（App 的 FocusPrefill.parse 按「 · 」和数字拆）
        let text = label.isEmpty ? "专注 \(minutes) 分钟" : "\(label) · \(minutes) 分钟"
        return .init(result: zh ? "卡片挂好了：TA 点「开始专注」才会开始（\(minutes) 分钟）。你写的提醒会在那时候要。"
                                : "Card's up: it only starts when they tap \"Start focus\" (\(minutes) min). Your reminders will be asked for then.",
                     card: ["kind": "focus", "text": text, "data": ["minutes": minutes, "label": label]])
    }
}
#endif
