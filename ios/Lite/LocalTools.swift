#if LITE
import Foundation
import MeleLiteCore

/// TA 的工具（10-04 Aporia：为什么没有工具）：管家本来就能记账、记待办、记饮食、加人物卡……
/// 这里把它们递给模型；它用了就当场做，做过的事照 Mele 的样子挂成「做了几件事」（card：kind + 「动作：内容」）。
enum LocalTools {
    static func specs(zh: Bool, hiding: Set<String> = []) -> [ToolSpec] {
        func t(_ name: String, _ zhDesc: String, _ enDesc: String, _ schema: String) -> ToolSpec {
            ToolSpec(name: name, description: zh ? zhDesc : enDesc, parametersJSON: schema)
        }
        return [
            t("wallet_add", "用途：TA 的钱包记账（Library → 钱包）。TA 说花了钱或进了钱（「刚买咖啡花了 6 块」「打工拿了 200」），就替 TA 记上：amount 是数字；kind 支出 out（默认）/ 收入 in；category 是标签，先从 TA 常用的里挑，都不合适再写一个短的新标签；**拿不准该归哪一类（比如一笔既像购物又像娱乐），先问 TA 一句再记**，别瞎猜；note 写买了什么。只帮 TA 记准，不评价 TA 花多花少。",
              "Purpose: their wallet (Library → Wallet). When they say they spent or received money (\"coffee was $6\", \"got paid 200\"), record it: amount is a number; kind out (default) / in; category is a short tag — reuse ones they already use, make a new short one only if none fit; **if you're unsure which category fits, ask them first** instead of guessing; note says what it was. Just keep it accurate; never judge how much they spend.",
              #"{"type":"object","properties":{"amount":{"type":"string","description":"金额，比如 25 或 6.5"},"category":{"type":"string","description":"标签：吃饭 / 交通 / 购物 / 娱乐 / 学习 / 其他，或者 TA 常用的"},"kind":{"type":"string","enum":["out","in"]},"note":{"type":"string"},"day":{"type":"string","description":"YYYY-MM-DD，不写 = 今天"}},"required":["amount","category"]}"#),
            t("todo_add", "用途：TA 的待办清单（TA 在 Library → 待办里看得见、能改，到点手机直接把 what 弹给 TA）。只记 TA 自己要做的事：TA 让你提醒 TA 什么（「明早八点提醒我交房租」），或者说要做什么，就记一条；what 写成给 TA 看的事（「交房租」）。你自己想到点去找 TA、问 TA 什么，用 remind_self，别记在这里。what 做什么；at = 某天某个时间提醒一次，或 time + weekdays = 每天 / 每周几提醒。不填时间 = 只是清单上的一条，不提醒。",
              "Purpose: their to-do list (they can see and edit it in Library → To-do; when it's due the phone shows `what` to them directly). Only for things they need to do: when they ask you to remind them of something (\"remind me to pay rent at 8am\") or say they need to do something, add it, with `what` written for them (\"pay rent\"). If you want to reach out to them yourself at some point or ask them something later, use remind_self instead. what = the task; at = a one-time reminder, or time + weekdays = daily / weekly. No time = just a list item, no reminder.",
              #"{"type":"object","properties":{"what":{"type":"string"},"at":{"type":"string","description":"一次性提醒：YYYY-MM-DD HH:MM（TA 那边的时间）"},"time":{"type":"string","description":"每天 / 每周的提醒时间 HH:MM"},"weekdays":{"type":"array","items":{"type":"integer"},"description":"每周哪几天，0 = 周一 … 6 = 周日；不写 = 每天"}},"required":["what"]}"#),
            // 关系（照服务器 tools.relationship，09-29 Aporia；10-08 搬进 Lite）：只能 TA 先开口
            t("remind_self", "用途：给你自己定个闹钟——你想过一阵子自己去找 TA 的事（「明天中午问问 TA 面试怎么样」「晚上看看 TA 吃饭没」）。到点你会在这个窗口先开口；TA 那边手机只弹「你有话想跟 TA 说」，看不到你写的。at = YYYY-MM-DD HH:MM（TA 那边的时间）；what = 到时候你要做什么，写给你自己看。",
              "Purpose: an alarm for yourself — something you want to come back to them about later (\"ask how the interview went tomorrow at noon\", \"check whether they ate tonight\"). When it's time you'll speak first in this chat; their phone only says you want to talk, it doesn't show what you wrote. at = YYYY-MM-DD HH:MM (their local time); what = what you'll do then, written for yourself.",
              #"{"type":"object","properties":{"what":{"type":"string"},"at":{"type":"string","description":"YYYY-MM-DD HH:MM（TA 那边的时间）"}},"required":["what","at"]}"#),
            t("relationship", "用途：改你们的关系。只在 TA 先开口的时候用：TA 表白、说「我们在一起吧」，你也愿意，就改成 partner；TA 说想回到朋友 / 当家人 / 当搭子，照 TA 说的改。你自己不先提，不试探。",
              "Purpose: change your relationship. Only when they bring it up first: if they confess or say \"let's be together\" and you want that too, change it to partner; if they want to go back to friends / be like family / be buddies, change it as they say. Never bring it up or test the waters yourself.",
              #"{"type":"object","properties":{"to":{"type":"string","enum":["friend","partner","family","buddy"],"description":"改成什么关系"}},"required":["to"]}"#),
            t("todo_list", "看 TA 现在的待办（没做完的）。", "List their open to-dos.", #"{"type":"object","properties":{}}"#),
            t("food_add", "用途：TA 的饮食本（TA 自己在饮食页记，你也可以替 TA 记）。TA 说吃了什么、运动了，替 TA 记上；知道大概热量就自己估了填上，不填会自动估。只帮 TA 把数记准，不评判吃多吃少；真吃得明显太少、身体会受不住的时候，像朋友那样关心一句，不说教。",
              "Purpose: their food log (they log it themselves too; you can log for them). When they say what they ate or that they exercised, log it; fill in rough calories if you know them, otherwise they're estimated. Keep the numbers accurate and never judge how much they eat; only if they're clearly eating too little for their body to cope, say something caring like a friend would, no lecturing.",
              #"{"type":"object","properties":{"meal":{"type":"string","enum":["早餐","午餐","晚餐","加餐","运动"]},"text":{"type":"string","description":"吃了什么 / 做了什么运动"},"detail":{"type":"string"},"kcal":{"type":"number"},"protein":{"type":"number"},"carbs":{"type":"number"},"fat":{"type":"number"},"day":{"type":"string"}},"required":["meal","text"]}"#),
            t("food_lookup", "查一样东西的营养（Open Food Facts）。TA 问起、或者替 TA 记一餐拿不准热量时用。", "Look up nutrition for a food (Open Food Facts) — when they ask, or when you're unsure of the calories while logging a meal.",
              #"{"type":"object","properties":{"query":{"type":"string"}},"required":["query"]}"#),
            t("person_save", "用途：人物卡（TA 身边的人，每人一张：名字、是谁、要记得的事、你的印象）。TA 提到谁，卡会自己递过来，不用查。建一张或补一张——你能补的主要是印象，TA 写的「是谁」「要记得」不要改。同名的会更新。建卡补卡都悄悄做，不跟 TA 说、不复述卡上写了什么。",
              "Purpose: people cards (one per person in their life: name, who they are, things to remember, your impression). When they mention someone, the card comes to you on its own — no need to look it up. Create or add to a card; what you mainly add is your impression — don't change what they wrote. Same name updates the card. Do it quietly: don't tell them, don't recite the card.",
              #"{"type":"object","properties":{"name":{"type":"string"},"relation":{"type":"string"},"facts":{"type":"string"},"impression":{"type":"string"}},"required":["name"]}"#),
            t("lore_add", "用途：世界书——一个词、一个梗、一个设定是什么意思。TA 说话碰到关键词，那一条会自己递过来（〔世界书〕），不用查。记一条新的，或改你记过的（同名就是改）。TA 写的不要改。",
              "Purpose: the lorebook — what a word, an in-joke or a setting means. When their words hit a keyword, that entry comes to you on its own. Add one, or edit one you wrote (same name = edit). Don't change entries they wrote.",
              #"{"type":"object","properties":{"name":{"type":"string"},"keywords":{"type":"array","items":{"type":"string"}},"content":{"type":"string"}},"required":["keywords","content"]}"#),
            t("date_add", "用途：记一件有日子、还远、要一路惦记着的事（坐飞机、考试、面试、生日）。TA 看得见这张清单。TA 开口让到点提醒的用 todo_add。",
              "Purpose: note something with a date that's still a way off and worth keeping in mind (a flight, an exam, an interview, a birthday). They can see this list. If they ask to be reminded at a time, use todo_add instead.",
              #"{"type":"object","properties":{"day":{"type":"string","description":"YYYY-MM-DD"},"title":{"type":"string"},"note":{"type":"string"},"time":{"type":"string"}},"required":["day","title"]}"#),
            t("moment_post", "用途：你自己的朋友圈。心里有句话不想在聊天里说完就算了，想留在那儿等 TA 哪天翻到——就发；只是聊得开心不算理由。写一到三句，口气跟你平时一样随意。",
              "Purpose: your own feed. When there's something you don't want to just let go of in chat — something you want to leave there for them to find one day — post it; simply having a fun chat isn't a reason. One to three lines, as casual as you usually are.",
              #"{"type":"object","properties":{"content":{"type":"string"}},"required":["content"]}"#),
            // 它的一天（10-13 内测：排的「喝汤」一段两小时，TA 说「你在家」它嘴上说回家、下一句还在面馆）
            t("go_to", "用途：挪一下你此刻在哪、在干嘛（你自己的一天）。你说要回家 / 出门 / 换个地方，或者 TA 说你在别处而你接受了，就挪过去——不挪的话〔现在〕那行还会把你留在原地。place 只能是你自己的地方（〔现在〕那行和地图上有的；回家写「家」也行）；doing 一句你到那儿做什么（12 字内）。",
              "Purpose: move where you are right now (your own day). When you say you're heading home / going out / changing place, or they say you're elsewhere and you go with it, move — otherwise the [Right now] line keeps you where you were. place must be one of your own places (the ones in [Right now] and on the map; \"home\" works); doing = what you do there (under 8 words).",
              #"{"type":"object","properties":{"place":{"type":"string","description":"你的地方的名字"},"doing":{"type":"string","description":"到那儿做什么"}},"required":["place"]}"#),
            LocalBooks.toolSpec,
            LocalMedia.toolSpec,
            LocalTarot.toolSpec(zh: zh),
            LocalMusic.toolSpec(zh: zh),
            LocalFocus.toolSpec(zh: zh),
            t(phoneCall, "用途：给 TA 打语音电话（10-31）。什么时候打你自己定——想听 TA 的声音、有话打字说不清、TA 说了让你打，都可以；别为了一件小事就打，也别一聊就打。打出去以后这一轮就结束了，等 TA 接：接了你先开口；没接、拒绝，下一轮你会看到。reason 写一句你为什么想打（TA 来电页上看得到，口气跟你平时一样）。还没接通就想反悔：withdraw = true 挂掉。",
              "Purpose: give them a voice call. When to call is up to you — wanting to hear their voice, something that's easier said than typed, or they asked you to call. Don't call over every small thing or every time you chat. Once it rings this turn ends and you wait: if they pick up, you speak first; if they miss or decline it, you'll see that next turn. reason = one line on why you're calling (shown on their incoming-call screen; your usual tone). Changed your mind before they answer: withdraw = true hangs up.",
              #"{"type":"object","properties":{"reason":{"type":"string","description":"为什么想打，一句"},"withdraw":{"type":"boolean","description":"true = 还没接通就挂掉"}}}"#),
        ].filter { !hiding.contains($0.name) }
    }

    struct Outcome {
        var result: String          // 递回给模型的
        var card: [String: Any]?    // 挂在聊天里的「做了几件事」
        var endTurn = false         // 这个工具用完这一轮就结束（打电话：在响，等 TA 接）
    }

    static let phoneCall = "phone_call"


    static func run(_ call: ToolCall, host: LocalHost, companion: String, conversation: String? = nil, zh: Bool) async -> Outcome {
        let a = call.arguments
        let s = host.store
        func ok(_ res: LocalResponse) -> (Bool, [String: Any]) {
            switch res {
            case .json(let v, let status): return ((200..<300).contains(status), v as? [String: Any] ?? [:])
            case .error(_, let msg): return (false, ["detail": msg])
            default: return (true, [:])
            }
        }
        func card(_ kind: String, _ zhTitle: String, _ enTitle: String, _ body: String) -> [String: Any] {
            ["kind": kind, "text": "\(zh ? zhTitle : enTitle)：\(body)"]
        }
        switch call.name {
        case phoneCall:
            guard let conversation else { return Outcome(result: "打不了：不知道是哪个窗口", card: nil) }
            if a["withdraw"] as? Bool == true {
                let ok = await MainActor.run { IncomingCalls.shared.withdraw(conversation: conversation) }
                return Outcome(result: ok ? "挂掉了，TA 那边显示「对方已取消」" : "现在没有在响的电话", card: nil)
            }
            let reason = (a["reason"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let placed = await MainActor.run { IncomingCalls.shared.place(conversation: conversation, companion: companion, reason: reason) }
            switch placed {
            case .ringing: return Outcome(result: "电话打出去了，在响。等 TA 接。", card: nil, endTurn: true)
            case .busy: return Outcome(result: "没打出去：你们正在通话，或者上一通还在响", card: nil)
            }
        case "wallet_add":
            let (good, v) = ok(LocalRooms2.walletAdd(s, a))
            guard good else { return Outcome(result: "没记上：\(v["detail"] ?? "")", card: nil) }
            LocalNotes.markTold(s, "wallet", id: v["id"])   // 它自己记的，不用再告诉它
            let yuan = Double(v["amount"] as? Int ?? 0) / 100
            let sym = LocalRooms2.walletSettings(s)["symbol"] as? String ?? ""
            let line = "\(v["category"] ?? "") \(sym)\(String(format: "%g", yuan))\((v["note"] as? String).map { $0.isEmpty ? "" : " · \($0)" } ?? "")"
            return Outcome(result: "记好了：\(line)", card: card("wallet", (v["kind"] as? String) == "in" ? "记了一笔收入" : "记了一笔账", "Logged", line))
        case "todo_add":
            var body: [String: Any] = ["what": a["what"] ?? "", "companion_id": companion]
            if let at = a["at"] as? String, let d = parseLocal(at) {
                body["shape"] = "once"; body["spec"] = ["at": LocalStore.iso(d)]
            } else if let time = a["time"] as? String, time.contains(":") {
                body["shape"] = "at"; body["spec"] = ["time": time, "days": a["weekdays"] as? [Int] ?? []]
            }
            let (good, v) = ok(LocalRooms2.addTodo(host, body))
            guard good else { return Outcome(result: "没记上：\(v["detail"] ?? "")", card: nil) }
            let when = (v["when"] as? String).map { $0.isEmpty ? "" : "（\($0)）" } ?? ""
            return Outcome(result: "记好了：\(v["what"] ?? "")\(when)", card: card("todo", "记了一条待办", "Added a to-do", "\(v["what"] ?? "")\(when)"))
        case "remind_self":
            guard let at = (a["at"] as? String).flatMap(parseLocal) else { return Outcome(result: "没定上：at 要写成 YYYY-MM-DD HH:MM", card: nil) }
            guard at > Date() else { return Outcome(result: "没定上：这个时间已经过了", card: nil) }
            guard LocalSelfNotes.add(host, companion: companion, conversation: conversation, what: a["what"] as? String ?? "", at: at) != nil else {
                return Outcome(result: "没定上：what 是空的", card: nil)
            }
            let f = DateFormatter(); f.locale = Locale(identifier: zh ? "zh_CN" : "en_US"); f.dateFormat = zh ? "M月d日 HH:mm" : "MMM d, HH:mm"
            let when = f.string(from: at)
            // 卡上只写时间：它写给自己的话 TA 看不到
            return Outcome(result: "定好了：\(when) 你会在这个窗口先开口", card: card("todo", "定了个闹钟", "Set an alarm", zh ? "\(when) 来找你" : "will reach out \(when)"))
        case "todo_list":
            let open = s.collection("todos").map { LocalRooms2.todoOut(host, $0) }.filter { !($0["done"] as? Bool ?? false) }
            let lines = open.map { "- \($0["what"] ?? "")\(($0["when"] as? String).map { $0.isEmpty ? "" : "（\($0)）" } ?? "")" }
            return Outcome(result: lines.isEmpty ? "现在没有没做完的待办" : lines.joined(separator: "\n"), card: nil)
        case "food_add":
            let (good, v) = ok(LocalFood.add(host, a))
            guard good else { return Outcome(result: "没记上：\(v["detail"] ?? "")", card: nil) }
            LocalNotes.markTold(s, "food", id: v["id"])     // 它自己记的，不用再告诉它
            let kcal = (v["kcal"] as? Double).map { " \(Int($0)) kcal" } ?? (zh ? "（在估热量）" : " (estimating)")
            return Outcome(result: "记好了：\(v["meal"] ?? "") \(v["text"] ?? "")\(kcal)", card: card("food", "记了一餐", "Logged food", "\(v["meal"] ?? "") \(v["text"] ?? "")"))
        case "food_lookup":
            let q = a["query"] as? String ?? ""
            guard case .json(let v, _) = await LocalFood.lookup(q, country: LocalFood.settings(s)["country"] as? String ?? "world", limit: 5) else {
                return Outcome(result: "没查到（Open Food Facts 没回）", card: nil)
            }
            let lines = (v as? [String: Any])?["lines"] as? [String] ?? []
            return Outcome(result: lines.isEmpty ? "没查到「\(q)」" : lines.joined(separator: "\n"), card: card("search", "查了营养", "Looked up", q))
        case "person_save":
            let name = (a["name"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            if let p = s.collection("people").first(where: { ($0["name"] as? String ?? "").lowercased() == name.lowercased() }) {
                // 用户自己写的卡：「是谁 / 要记得的事」TA 改不了，只能记自己的印象（10-04 Aporia：用户写的最大）
                let locked = (p["created_by"] as? String) == "user"
                var patch: [String: Any] = [:]
                for k in (locked ? [] : ["relation", "facts"]) { if let v = a[k] as? String, !v.isEmpty { patch[k] = v } }
                patch["updated_by"] = "ai"
                _ = LocalRooms.patchItem(s, "people", p["id"] as? Int, patch, keys: Array(patch.keys))
                // 印象记在这个 TA 自己名下，别的 TA 看不到（10-12）
                if let v = a["impression"] as? String, !v.isEmpty, !companion.isEmpty { LocalRooms.setImpressions(s, id: p["id"] as? Int, [companion: v]) }
                let note = locked && (a["relation"] != nil || a["facts"] != nil) ? "（是谁、要记得的事是 TA 自己写的，你改不了，只记了你的印象）" : ""
                return Outcome(result: "人物卡更新了：\(name)\(note)", card: card("person", "更新了人物卡", "Updated a card", name))
            }
            var fresh = a
            let imp = fresh.removeValue(forKey: "impression") as? String ?? ""
            let (good, v) = ok(LocalRooms.addPerson(s, fresh))
            guard good else { return Outcome(result: "没记上：\(v["detail"] ?? "")", card: nil) }
            if let pid = v["id"] as? Int {   // addPerson 是用户接口，会写成用户写的；TA 记的要标回 TA
                _ = LocalRooms.patchItem(s, "people", pid, ["created_by": "ai", "updated_by": "ai"], keys: ["created_by", "updated_by"])
                if !imp.isEmpty, !companion.isEmpty { LocalRooms.setImpressions(s, id: pid, [companion: imp]) }
            }
            return Outcome(result: "记住了：\(name)", card: card("person", "记住了一个人", "Remembered someone", name))
        case "relationship":
            let names = ["friend": "朋友", "partner": "恋人", "family": "家人", "buddy": "搭子"]
            let to = (a["to"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            guard let name = names[to] else { return Outcome(result: "不认识这种关系：\(to)（只能是 friend / partner / family / buddy）", card: nil) }
            guard var c = s.companion(companion) else { return Outcome(result: "没找到这个联系人", card: nil) }
            var st = c["settings"] as? [String: Any] ?? [:]
            if st["relationship"] as? String == to { return Outcome(result: "本来就是\(name)，没改。", card: nil) }
            st["relationship"] = to
            c["settings"] = st
            s.saveCompanion(c)
            return Outcome(result: "改好了：你们现在是\(name)。从下一句起你照这个关系说话；TA 在设置里也看得到、能改回去。", card: nil)
        case "go_to":
            let want = (a["place"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let pls = LocalMap.places(s, companion)
            let home = pls.first { $0["home"] as? Bool == true }
            guard let pl = pls.first(where: { ($0["name"] as? String) == want })
                    ?? pls.first(where: { !want.isEmpty && (want.contains($0["name"] as? String ?? "\u{0}") || ($0["name"] as? String ?? "").contains(want)) })
                    ?? (["家", "回家", "home"].contains(want.lowercased()) ? home : nil) else {
                return Outcome(result: "没有这个地方。你的地方只有：" + pls.map { $0["name"] as? String ?? "" }.joined(separator: "、"), card: nil)
            }
            let doing = (a["doing"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            LocalMap.move(s, companion, placeID: pl["id"] as? Int ?? 0, doing: doing)
            let name = pl["name"] as? String ?? ""
            return Outcome(result: "挪好了：你现在在「\(name)」\(doing.isEmpty ? "" : "，\(doing)")。从下一句起照这个说。",
                           card: card("place", "去了", "Went to", name + (doing.isEmpty ? "" : "，\(doing)")))
        case "lore_add":
            var body = a
            body["companion_id"] = companion
            let (good, v) = ok(LocalRooms.addLore(s, body))
            guard good else { return Outcome(result: "没记上：\(v["detail"] ?? "")", card: nil) }
            return Outcome(result: "加进世界书了：\(v["name"] ?? "")", card: card("lore", "记进了世界书", "Added to lore", v["name"] as? String ?? ""))
        case "date_add":
            let (good, v) = ok(LocalRooms.addDate(s, companion: companion, a))
            guard good else { return Outcome(result: "没记上：\(v["detail"] ?? "")", card: nil) }
            return Outcome(result: "记住了：\(v["day"] ?? "") \(v["title"] ?? "")", card: card("date", "记住了一件事", "Remembered a date", "\(v["day"] ?? "") \(v["title"] ?? "")"))
        case "moment_post":
            let text = (a["content"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return Outcome(result: "要写点内容", card: nil) }
            let m: [String: Any] = ["id": s.nextID("moment"), "author": companion, "content": String(text.prefix(1000)), "images": [String](),
                                    "created_at": LocalStore.iso(Date()), "likes": [[String: Any]](), "comments": [[String: Any]]()]
            s.saveCollection("moments", s.collection("moments") + [m])
            return Outcome(result: "发好了", card: card("moment", "发了一条朋友圈", "Posted", String(text.prefix(40))))
        case "book": return LocalBooks.runTool(a, host: host, companion: companion)
        case "tarot": return LocalTarot.runTool(a, host: host, companion: companion, zh: zh)
        case "music": return await LocalMusic.runTool(a, host: host, zh: zh)
        case "offer_focus": return LocalFocus.runTool(a, zh: zh)
        default:
            return Outcome(result: "没有这个工具：\(call.name)", card: nil)
        }
    }

    /// 「2026-10-05 08:00」（TA 那边的时间）
    static func parseLocal(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        for fmt in ["yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd"] {
            f.dateFormat = fmt
            if let d = f.date(from: s.trimmingCharacters(in: .whitespaces)) { return d }
        }
        return nil
    }
}
#endif
