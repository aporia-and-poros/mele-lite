#if LITE
import Foundation
import UIKit
import MeleLiteCore

/// 第三批：相册、朋友圈（照 routes_album / routes_moments）。它「看照片」「来评论」都用你自己的 key，App 开着时做。
enum LocalRooms3 {
    static func handle(_ r: LocalRequest, host: LocalHost) -> LocalResponse? {
        let p = r.parts
        let s = host.store
        switch (r.method, p.first ?? "", p.count) {
        // 相册
        case ("GET", "album", 1): return .json(albumList(s, book: r.query["book"] ?? "all", companion: r.query["companion_id"]))
        case ("GET", "album", 3) where p[2] == "image":
            guard let ph = s.collection("album").first(where: { ($0["id"] as? Int) == Int(p[1]) }),
                  let d = try? Data(contentsOf: s.fileURL(ph["file"] as? String ?? "")) else { return .error(404, String(localized: "没有这张")) }
            return .data(d, mime: "image/jpeg")
        case ("POST", "album", 1): return albumAdd(host, r)
        case ("PATCH", "album", 2):
            var all = s.collection("album")
            guard let i = all.firstIndex(where: { ($0["id"] as? Int) == Int(p[1]) }) else { return .error(404, String(localized: "没有这张")) }
            for k in ["starred", "secret"] where r.json.keys.contains(k) { all[i][k] = r.json[k] as? Bool ?? false }
            s.saveCollection("album", all)
            return .json(albumOut(all[i]))
        case ("DELETE", "album", 2): return LocalRooms.removeWhere(s, "album", 404, String(localized: "没有这张")) { ($0["id"] as? Int) == Int(p[1]) }
        // 朋友圈
        case ("GET", "moments", 1): return .json(feed(host, who: r.query["who"], before: r.query["before"].flatMap(Int.init), limit: Int(r.query["limit"] ?? "20") ?? 20))
        case ("GET", "moments", 2) where p[1] == "activity": return .json(activity(host, since: r.query["since"]))
        case ("POST", "moments", 1): return post(host, r)
        case ("DELETE", "moments", 2):
            return LocalRooms.removeWhere(s, "moments", 404, String(localized: "没有这条（只能删自己发的）")) { ($0["id"] as? Int) == Int(p[1]) && ($0["author"] as? String) == "user" }
        case ("POST", "moments", 3) where p[2] == "like": return like(host, Int(p[1]), r.json["liked"] as? Bool ?? true)
        case ("POST", "moments", 3) where p[2] == "comments": return comment(host, Int(p[1]), r.json)
        case ("DELETE", "moments", 3) where p[1] == "comments": return deleteComment(host, Int(p[2]))
        case ("GET", "moments", 4) where p[2] == "images":
            guard let m = s.collection("moments").first(where: { ($0["id"] as? Int) == Int(p[1]) }),
                  let files = m["images"] as? [String], let n = Int(p[3]), files.indices.contains(n),
                  let d = try? Data(contentsOf: s.fileURL(files[n])) else { return .error(404, String(localized: "没有这张")) }
            return .data(d, mime: "image/jpeg")
        case ("GET", "moments", 3) where p[1] == "profile":
            let prof = (s.read("moments-profiles.json") as? [String: [String: Any]])?[p[2]] ?? [:]
            return .json(["who": p[2], "name": names(host)[p[2]] ?? "", "signature": prof["signature"] ?? "",
                          "has_cover": FileManager.default.fileExists(atPath: s.fileURL("cover-\(p[2])").path)])
        case ("PUT", "moments", 4) where p[1] == "profile" && p[3] == "signature":
            var all = s.read("moments-profiles.json") as? [String: [String: Any]] ?? [:]
            let sig = String((r.json["signature"] as? String ?? "").prefix(60))
            all[p[2], default: [:]]["signature"] = sig
            s.write("moments-profiles.json", all)
            return .json(["signature": sig])
        case ("PUT", "moments", 4) where p[1] == "profile" && p[3] == "cover":
            guard let f = r.form.files["file"]?.first, let img = UIImage(data: f.data),
                  let jpg = LocalBrain.jpeg(img, maxSide: 2000) else { return .error(400, String(localized: "图读不了")) }
            s.saveFile(jpg, name: "cover-\(p[2])")
            return .empty
        case ("GET", "moments", 4) where p[1] == "profile" && p[3] == "cover":
            guard let d = try? Data(contentsOf: s.fileURL("cover-\(p[2])")) else { return .error(404, String(localized: "还没有封面")) }
            return .data(d, mime: "image/jpeg")
        default: return nil
        }
    }

    // MARK: - 相册

    static func albumOut(_ a: [String: Any]) -> [String: Any] {
        let id = a["id"] as? Int ?? 0
        return ["id": id, "companion_id": a["companion_id"] ?? "", "source": a["source"] ?? "user", "taken_at": a["taken_at"] ?? "",
                "caption": a["caption"] ?? "", "felt": a["felt"] ?? "", "why": a["why"] ?? "", "thoughts": a["thoughts"] ?? "",
                "note": a["note"] ?? "", "batch": a["batch"] as? String ?? "",   // 单张存的 batch 是空：给空串，App 那边是 String（10-31 内测：null 让整本相册解不出来） "starred": a["starred"] ?? false, "secret": a["secret"] ?? false,
                "looking": a["looking"] ?? false, "url": "album/\(id)/image", "thumb": "album/\(id)/image?thumb=1"]
    }

    static func albumList(_ s: LocalStore, book: String, companion: String?) -> [[String: Any]] {
        s.collection("album").filter { a in
            if let companion, !companion.isEmpty, (a["companion_id"] as? String) != companion { return false }
            switch book {
            case "starred": return a["starred"] as? Bool ?? false
            case "secret": return a["secret"] as? Bool ?? false
            default: return !(a["secret"] as? Bool ?? false)
            }
        }.sorted { LocalStore.date($0["taken_at"]) > LocalStore.date($1["taken_at"]) }.map(albumOut)
    }

    /// 存一张进相册（你在相册里加的，或者你在聊天里发的）
    @discardableResult
    static func addPhoto(_ host: LocalHost, _ data: Data, companion: String, source: String, note: String = "", batch: String? = nil) -> [String: Any]? {
        guard let img = UIImage(data: data), let jpg = LocalBrain.jpeg(img, maxSide: 2400) else { return nil }
        let s = host.store
        let id = s.nextID("album")
        s.saveFile(jpg, name: "album-\(id)")
        let a: [String: Any] = ["id": id, "companion_id": companion, "file": "album-\(id)", "source": source,
                                "taken_at": LocalStore.iso(Date()), "note": note, "batch": batch ?? NSNull(),
                                "starred": false, "secret": false, "looking": source == "user"]
        s.saveCollection("album", s.collection("album") + [a])
        return a
    }

    static func albumAdd(_ host: LocalHost, _ r: LocalRequest) -> LocalResponse {
        let form = r.form
        let comp = (form.fields["companion_id"]).flatMap { $0.isEmpty ? nil : $0 } ?? (host.store.companions.first?["id"] as? String ?? "")
        let note = String((form.fields["note"] ?? "").prefix(500))
        let batch = UUID().uuidString.lowercased()
        let files = (form.files["files"] ?? []).prefix(9)
        guard !files.isEmpty else { return .error(400, String(localized: "选几张照片吧")) }
        let added = files.compactMap { addPhoto(host, $0.data, companion: comp, source: "user", note: note, batch: files.count > 1 ? batch : nil) }
        look(host, ids: added.compactMap { $0["id"] as? Int }, companion: comp, note: note)
        return .json(added.map(albumOut), status: 201)
    }

    /// 它看照片：写一句图注、当时的感觉、想说的话（用你的 key；配不上 key 就不看）
    static func look(_ host: LocalHost, ids: [Int], companion: String, note: String) {
        Task.detached {
            let s = host.store
            defer {
                var all = s.collection("album")
                for i in all.indices where ids.contains(all[i]["id"] as? Int ?? -1) { all[i]["looking"] = false }
                s.saveCollection("album", all)
            }
            guard let comp = s.companion(companion), let (provider, key) = host.route(chore: "moments", else: host.quietRoute(for: comp)),
                  !LiteConsent.book.needsAsk(provider) else { return }
            try? await Task.sleep(for: .seconds(20))
            let zh = ((comp["settings"] as? [String: Any])?["lang"] as? String ?? "zh") == "zh"
            let contact = LocalBrain.contact(comp, provider: provider)
            for id in ids {
                guard let ph = s.collection("album").first(where: { ($0["id"] as? Int) == id }),
                      let d = try? Data(contentsOf: s.fileURL(ph["file"] as? String ?? "")), let img = UIImage(data: d),
                      let jpeg = LocalBrain.jpeg(img, maxSide: 1024) else { continue }
                let ask = zh
                    ? "TA 把这张照片放进了你们的相册\(note.isEmpty ? "" : "，还写了一句：「\(note)」")。用你自己的口吻写三行，每行一个，不要别的：\n图注：（10 字以内）\n感觉：（一个词）\n想说：（一两句，对 TA 说）"
                    : "They added this photo to your shared album\(note.isEmpty ? "" : " with the note: \"\(note)\""). In your own voice, write exactly three lines:\nCaption: (under 8 words)\nFeeling: (one word)\nSay: (one or two sentences to them)"
                var req = Prompt.build(PromptInput(contact: contact, identity: contact.mainIdentity, history: [], lang: zh ? .zh : .en))
                req.turns = [ChatTurn(role: .user, text: ask, imageJPEG: jpeg)]
                req.maxTokens = 600
                var text = ""
                do { for try await e in makeClient(provider, key: key).stream(req) { if case .text(let t) = e { text += t } } } catch { return }
                func line(_ keys: [String]) -> String {
                    for l in text.split(separator: "\n") {
                        let t = l.trimmingCharacters(in: .whitespaces)
                        for k in keys where t.hasPrefix(k) {
                            return t.dropFirst(k.count).trimmingCharacters(in: CharacterSet(charactersIn: "：: "))
                        }
                    }
                    return ""
                }
                var all = s.collection("album")
                if let i = all.firstIndex(where: { ($0["id"] as? Int) == id }) {
                    all[i]["caption"] = line(["图注", "Caption"])
                    all[i]["felt"] = line(["感觉", "Feeling"])
                    all[i]["thoughts"] = line(["想说", "Say"])
                    all[i]["looking"] = false
                    s.saveCollection("album", all)
                }
            }
        }
    }

    // MARK: - 朋友圈

    static func names(_ host: LocalHost) -> [String: String] {
        var out: [String: String] = ["user": host.profile["name"] as? String ?? ""]
        for c in host.store.companions { out[c["id"] as? String ?? ""] = (c["persona"] as? [String: Any])?["name"] as? String ?? "" }
        return out
    }

    static func momentOut(_ m: [String: Any], _ nm: [String: String]) -> [String: Any] {
        let comments = m["comments"] as? [[String: Any]] ?? []
        let byID = Dictionary(comments.map { ($0["id"] as? Int ?? 0, $0) }, uniquingKeysWith: { a, _ in a })
        return ["id": m["id"] ?? 0, "author": m["author"] ?? "user", "name": nm[m["author"] as? String ?? ""] ?? "",
                "content": m["content"] ?? "", "images": (m["images"] as? [String] ?? []).count, "created_at": m["created_at"] ?? "",
                "likes": (m["likes"] as? [[String: Any]] ?? []).map { ["who": $0["who"] ?? "", "name": nm[$0["who"] as? String ?? ""] ?? ""] },
                "comments": comments.map { c in
                    ["id": c["id"] ?? 0, "author": c["author"] ?? "", "name": nm[c["author"] as? String ?? ""] ?? "",
                     "content": c["content"] ?? "", "reply_to": c["reply_to"] ?? NSNull(),
                     "reply_to_name": (c["reply_to"] as? Int).flatMap { byID[$0] }.flatMap { nm[$0["author"] as? String ?? ""] } ?? NSNull(),
                     "created_at": c["created_at"] ?? ""] as [String: Any]
                }]
    }

    static func feed(_ host: LocalHost, who: String?, before: Int?, limit: Int) -> [[String: Any]] {
        let nm = names(host)
        return host.store.collection("moments")
            .filter { (who == nil || ($0["author"] as? String) == who) && (before == nil || ($0["id"] as? Int ?? 0) < before!) }
            .sorted { ($0["id"] as? Int ?? 0) > ($1["id"] as? Int ?? 0) }
            .prefix(max(1, min(limit, 50))).map { momentOut($0, nm) }
    }

    static func activity(_ host: LocalHost, since: String?) -> [String: Any] {
        let at = since.map { LocalStore.date($0) } ?? .distantPast
        let nm = names(host)
        var items: [[String: Any]] = []
        var newPosts = 0
        for m in host.store.collection("moments") {
            let mine = (m["author"] as? String) == "user"
            if !mine, LocalStore.date(m["created_at"]) > at { newPosts += 1 }
            if mine {
                for l in m["likes"] as? [[String: Any]] ?? [] where (l["who"] as? String) != "user" && LocalStore.date(l["at"]) > at {
                    items.append(["kind": "like", "who": l["who"] ?? "", "name": nm[l["who"] as? String ?? ""] ?? "", "at": l["at"] ?? "",
                                  "moment_id": m["id"] ?? 0, "post": m["content"] ?? "", "content": NSNull()])
                }
            }
            let comments = m["comments"] as? [[String: Any]] ?? []
            for c in comments where (c["author"] as? String) != "user" && LocalStore.date(c["created_at"]) > at {
                let toMe = (c["reply_to"] as? Int).flatMap { r in comments.first { ($0["id"] as? Int) == r } }.map { ($0["author"] as? String) == "user" }
                    ?? mine
                guard toMe else { continue }
                items.append(["kind": "comment", "who": c["author"] ?? "", "name": nm[c["author"] as? String ?? ""] ?? "",
                              "at": c["created_at"] ?? "", "moment_id": m["id"] ?? 0, "post": m["content"] ?? "", "content": c["content"] ?? ""])
            }
        }
        items.sort { ($0["at"] as? String ?? "") > ($1["at"] as? String ?? "") }
        return ["count": items.count, "new_posts": newPosts, "items": Array(items.prefix(50))]
    }

    static func post(_ host: LocalHost, _ r: LocalRequest) -> LocalResponse {
        let form = r.form
        let content = (form.fields["content"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let s = host.store
        var files: [String] = []
        for f in (form.files["files"] ?? []).prefix(9) {
            guard let img = UIImage(data: f.data), let jpg = LocalBrain.jpeg(img, maxSide: 2000) else { continue }
            let name = "moment-\(UUID().uuidString.lowercased())"
            s.saveFile(jpg, name: name)
            files.append(name)
        }
        guard !content.isEmpty || !files.isEmpty else { return .error(400, String(localized: "说点什么，或者放张图")) }
        let m: [String: Any] = ["id": s.nextID("moment"), "author": "user", "content": String(content.prefix(1000)), "images": files,
                                "created_at": LocalStore.iso(Date()), "likes": [[String: Any]](), "comments": [[String: Any]]()]
        s.saveCollection("moments", s.collection("moments") + [m])
        drop(host, moment: m["id"] as? Int ?? 0, replyTo: nil)
        return .json(momentOut(m, names(host)), status: 201)
    }

    static func update(_ s: LocalStore, _ id: Int?, _ change: (inout [String: Any]) -> Void) -> [String: Any]? {
        var all = s.collection("moments")
        guard let id, let i = all.firstIndex(where: { ($0["id"] as? Int) == id }) else { return nil }
        change(&all[i])
        s.saveCollection("moments", all)
        return all[i]
    }

    static func like(_ host: LocalHost, _ id: Int?, _ liked: Bool) -> LocalResponse {
        guard let m = update(host.store, id, { m in
            var likes = (m["likes"] as? [[String: Any]] ?? []).filter { ($0["who"] as? String) != "user" }
            if liked { likes.append(["who": "user", "at": LocalStore.iso(Date())]) }
            m["likes"] = likes
        }) else { return .error(404, String(localized: "没有这条")) }
        return .json(momentOut(m, names(host)))
    }

    static func comment(_ host: LocalHost, _ id: Int?, _ b: [String: Any]) -> LocalResponse {
        let text = (b["content"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .error(400, String(localized: "写点什么吧")) }
        let cid = host.store.nextID("moment-comment")
        guard let m = update(host.store, id, { m in
            var cs = m["comments"] as? [[String: Any]] ?? []
            cs.append(["id": cid, "author": "user", "content": String(text.prefix(500)), "reply_to": b["reply_to"] ?? NSNull(),
                       "created_at": LocalStore.iso(Date())])
            m["comments"] = cs
        }) else { return .error(404, String(localized: "没有这条")) }
        drop(host, moment: id ?? 0, replyTo: cid)
        return .json(momentOut(m, names(host)), status: 201)
    }

    /// 长按「翻译」（10-23 内测，像微信；照 Host moments.translate）：{comment_id?, to?} → {text}，翻一次存一份。
    /// 钥匙用写这句的那个联系人的（钥匙串「翻译」那把优先）；你自己写的用第一个联系人的
    static func translate(_ r: LocalRequest, host: LocalHost) async -> LocalResponse? {
        let p = r.parts
        guard r.method == "POST", p.count == 3, p[0] == "moments", p[2] == "translate" else { return nil }
        let s = host.store
        guard let mid = Int(p[1]), let m = s.collection("moments").first(where: { ($0["id"] as? Int) == mid }) else {
            return .error(404, String(localized: "没有这条"))
        }
        let cid = r.json["comment_id"] as? Int
        let to = String((r.json["to"] as? String ?? "").trimmingCharacters(in: .whitespaces).prefix(20))
        let dst = to.isEmpty ? "中文" : to
        let row: [String: Any]
        if let cid {
            guard let c = (m["comments"] as? [[String: Any]] ?? []).first(where: { ($0["id"] as? Int) == cid }) else {
                return .error(404, String(localized: "没有这条"))
            }
            row = c
        } else { row = m }
        let text = row["content"] as? String ?? ""
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .error(400, String(localized: "没有字可以翻")) }
        if let got = (row["translations"] as? [String: String])?[dst], !got.isEmpty { return .json(["text": got]) }
        let author = row["author"] as? String ?? ""
        guard let comp = s.companion(author) ?? s.companions.first else { return .error(502, String(localized: "翻译没成功，等一下再试")) }
        let zh = dst.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
        guard let out = await LocalBilingual.translate(host, comp: comp, [text], from: zh ? "原文的语言" : "the original language",
                                                       to: dst, zh: zh).first ?? nil else {
            return .error(502, String(localized: "翻译没成功，等一下再试"))
        }
        _ = update(s, mid) { m in
            if let cid {
                var cs = m["comments"] as? [[String: Any]] ?? []
                if let i = cs.firstIndex(where: { ($0["id"] as? Int) == cid }) {
                    var tr = cs[i]["translations"] as? [String: String] ?? [:]
                    tr[dst] = out
                    cs[i]["translations"] = tr
                }
                m["comments"] = cs
            } else {
                var tr = m["translations"] as? [String: String] ?? [:]
                tr[dst] = out
                m["translations"] = tr
            }
        }
        return .json(["text": out])
    }

    static func deleteComment(_ host: LocalHost, _ cid: Int?) -> LocalResponse {
        var all = host.store.collection("moments")
        for i in all.indices {
            let cs = all[i]["comments"] as? [[String: Any]] ?? []
            if cs.contains(where: { ($0["id"] as? Int) == cid && ($0["author"] as? String) == "user" }) {
                all[i]["comments"] = cs.filter { ($0["id"] as? Int) != cid }
                host.store.saveCollection("moments", all)
                return .empty
            }
        }
        return .error(404, String(localized: "没有这条评论（只能删自己的）"))
    }

    /// 一条评论是说给谁的：回某条评论 = 那条的作者，直接评论 = 发动态的人
    static func addressee(parent: [String: Any]?, post: [String: Any]) -> String? {
        (parent ?? post)["author"] as? String
    }

    /// TA 过一会儿来：你发了动态 → 每个联系人过一阵来赞一下、留一句；你评论了它的动态 / 回了它的评论 → 它接一句。
    /// 先记进 rooms/moment-visits.json 再等（10-18 内测：以前只在内存里等，评论完把 App 关掉，它就再也不来了）：
    /// App 开着到点就来；关掉了，下次打开 / 回到前台补上。太久的（3 天）就算了。
    static func drop(_ host: LocalHost, moment id: Int, replyTo: Int?) {
        let s = host.store
        guard let m = s.collection("moments").first(where: { ($0["id"] as? Int) == id }) else { return }
        var who: [String] = []
        if let replyTo {
            let comments = m["comments"] as? [[String: Any]] ?? []
            guard let mine = comments.first(where: { ($0["id"] as? Int) == replyTo }) else { return }
            let parent = (mine["reply_to"] as? Int).flatMap { r in comments.first { ($0["id"] as? Int) == r } }
            // 10-18 内测：以前只认「回它的评论」，直接评论在它动态下的被当成不是说给它的，它从来不来
            if let to = addressee(parent: parent, post: m), to != "user" { who = [to] }
        } else {
            who = s.companions.compactMap { $0["id"] as? String }
        }
        guard !who.isEmpty else { return }
        visitLock.lock()
        var jobs = s.collection("moment-visits")
        for cid in who {   // 不秒回（10-18 Aporia：跟之前自用的 App一样）：你发的 15～180 分钟、多数 45；评论 5～60、多数 15
            let wait = replyTo == nil ? triangular(15, 45, 180) : triangular(5, 15, 60)
            jobs.append(["companion": cid, "moment": id, "reply_to": replyTo ?? NSNull(),
                         "due": LocalStore.iso(Date().addingTimeInterval(wait * 60))])
        }
        s.saveCollection("moment-visits", jobs)
        visitLock.unlock()
        scheduleVisits(host)
    }

    /// 聊天里知道朋友圈（10-18，跟 Host moments.recap 一样）：这个窗口上次聊完以后跟它有关的新动静，递一次——
    /// TA 发的、TA 赞它的、TA 说给它的评论、它自己留的。最多往回 48 小时、8 条。
    static func recapNote(_ s: LocalStore, companion cid: String, conversation conv: String, zh: Bool) -> String {
        let now = Date()
        var seen = s.read("moments-seen.json") as? [String: String] ?? [:]
        let floor = now.addingTimeInterval(-48 * 3600)
        let since = seen[conv].map { max(LocalStore.date($0), floor) } ?? floor
        seen[conv] = LocalStore.iso(now)
        s.write("moments-seen.json", seen)
        func cut(_ v: Any?, _ n: Int) -> String {
            let t = (v as? String ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return t.count <= n ? t : String(t.prefix(n)) + "…"
        }
        var ev: [(Date, String)] = []
        for m in s.collection("moments") {
            let author = m["author"] as? String ?? ""
            let post = cut(m["content"], 40)
            let whose = author == cid ? (zh ? "你那条" : "your post") : author == "user" ? (zh ? "TA 那条" : "their post") : (zh ? "那条" : "the post")
            if author == "user", LocalStore.date(m["created_at"]) > since {
                ev.append((LocalStore.date(m["created_at"]), zh ? "TA 发了一条：「\(cut(m["content"], 120))」" : "they posted: \"\(cut(m["content"], 120))\""))
            }
            if author == cid {
                for l in m["likes"] as? [[String: Any]] ?? [] where (l["who"] as? String) == "user" && LocalStore.date(l["at"]) > since {
                    ev.append((LocalStore.date(l["at"]), zh ? "TA 赞了你那条「\(post)」" : "they liked your post \"\(post)\""))
                }
            }
            let comments = m["comments"] as? [[String: Any]] ?? []
            for c in comments where LocalStore.date(c["created_at"]) > since {
                let at = LocalStore.date(c["created_at"]), text = cut(c["content"], 120)
                let a = c["author"] as? String ?? ""
                if a == cid {
                    let mineWhose = author == cid ? (zh ? "自己那条" : "your post") : author == "user" ? (zh ? " TA 那条" : "their post") : (zh ? "那条" : "the post")
                    ev.append((at, zh ? "你在\(mineWhose)「\(post)」下留了：「\(text)」" : "you left under \(mineWhose) \"\(post)\": \"\(text)\""))
                } else if a == "user" {
                    let parent = (c["reply_to"] as? Int).flatMap { r in comments.first { ($0["id"] as? Int) == r } }
                    guard addressee(parent: parent, post: m) == cid else { continue }
                    ev.append((at, zh ? "TA 在\(whose)「\(post)」下\(parent != nil ? "回你" : "评论")：「\(text)」"
                                      : "they \(parent != nil ? "replied to you" : "commented") under \(whose) \"\(post)\": \"\(text)\""))
                }
            }
        }
        guard !ev.isEmpty else { return "" }
        func ago(_ d: Date) -> String {
            let m = max(0, Int(now.timeIntervalSince(d) / 60))
            return zh ? (m < 2 ? "刚刚" : m < 60 ? "\(m) 分钟前" : "\(m / 60) 小时前") : (m < 2 ? "just now" : m < 60 ? "\(m) min ago" : "\(m / 60) h ago")
        }
        let rows = ev.sorted { $0.0 < $1.0 }.suffix(8).map { zh ? "- \($0.1)（\(ago($0.0))）" : "- \($0.1) (\(ago($0.0)))" }
        return (zh ? "〔朋友圈〕上次聊完以后，朋友圈里跟你有关的事（你都看见了，想提就提）："
                   : "〔Moments〕Since you last talked, on Moments (you've seen all of this; bring it up if you like):")
            + "\n" + rows.joined(separator: "\n")
    }

    /// 三角分布（分钟）：大多落在 mode 附近，偶尔很快或很晚——跟 Host / 之前自用的 App同一套
    static func triangular(_ lo: Double, _ mode: Double, _ hi: Double) -> Double {
        let u = Double.random(in: 0..<1), c = (mode - lo) / (hi - lo)
        return u < c ? lo + ((hi - lo) * (mode - lo) * u).squareRoot() : hi - ((hi - lo) * (hi - mode) * (1 - u)).squareRoot()
    }

    #if DEBUG
    /// -momentsSelfTest（10-18）：不叫模型，只看排队和〔朋友圈〕；跑完把朋友圈和队列换回原样
    static func selfTest(_ host: LocalHost) {
        let s = host.store
        let keep = (s.collection("moments"), s.collection("moment-visits"), s.read("moments-seen.json"))
        defer {
            s.saveCollection("moments", keep.0); s.saveCollection("moment-visits", keep.1)
            if let v = keep.2 { s.write("moments-seen.json", v) } else { s.write("moments-seen.json", [String: String]()) }
        }
        guard let cid = s.companions.first?["id"] as? String else { print("momentsSelfTest FAILED: 没有联系人"); return }
        let now = LocalStore.iso(Date())
        s.saveCollection("moments", [["id": 9001, "author": cid, "content": "她今天又熬夜", "created_at": now,
                                      "likes": [["who": "user", "at": now]], "comments": [[String: Any]]()]])
        s.saveCollection("moment-visits", [])
        s.write("moments-seen.json", [String: String]())
        _ = comment(host, 9001, ["content": "早点睡你也是"])
        let jobs = s.collection("moment-visits")
        let mins = jobs.map { LocalStore.date($0["due"]).timeIntervalSinceNow / 60 }
        let queued = jobs.count == 1 && (jobs[0]["companion"] as? String) == cid && mins.allSatisfy { $0 >= 4.9 && $0 <= 60.1 }
        let first = recapNote(s, companion: cid, conversation: "selftest", zh: true)
        let second = recapNote(s, companion: cid, conversation: "selftest", zh: true)
        let told = first.contains("TA 在你那条「她今天又熬夜」下评论：「早点睡你也是」") && first.contains("TA 赞了你那条") && second.isEmpty
        let tri = (0..<2000).map { _ in triangular(15, 45, 180) }
        let triOK = tri.min()! >= 15 && tri.max()! <= 180 && abs(tri.reduce(0, +) / 2000 - 80) < 6   // 均值 (15+45+180)/3 = 80
        print("momentsSelfTest", queued && told && triOK ? "ok" : "FAILED", "queued=\(queued) mins=\(mins) told=\(told) tri=\(triOK)")
        print(first)
    }
    #endif

    private static let visitLock = NSLock()
    private static let visitMaxAge: TimeInterval = 3 * 86400

    /// 等到最早那一笔到点再跑（App 被挂起 / 关掉就等下次 runDueVisits）
    static func scheduleVisits(_ host: LocalHost) {
        let next = host.store.collection("moment-visits").map { LocalStore.date($0["due"]) }.min()
        guard let next else { return }
        Task.detached {
            let wait = next.timeIntervalSinceNow
            if wait > 0 { try? await Task.sleep(for: .seconds(wait + 1)) }
            await runDueVisits(host)
        }
    }

    /// 到点的都来一遍：先从文件里摘下来（两处同时跑也不会回两次），再一个个问模型
    static func runDueVisits(_ host: LocalHost) async {
        let s = host.store
        visitLock.lock()
        let all = s.collection("moment-visits")
        let now = Date()
        let due = all.filter { LocalStore.date($0["due"]) <= now }
        s.saveCollection("moment-visits", all.filter { LocalStore.date($0["due"]) > now })
        visitLock.unlock()
        // 11-03 一测「来访一点动静都没有」：以前摘下来就问模型，失败了（网断、App 刚好被切走挂起、钥匙报错）这一笔就没了，连赞都没有。
        // 现在没写成的放回去，过 10 分钟再来，最多 3 次
        var retry: [[String: Any]] = []
        for job in due where now.timeIntervalSince(LocalStore.date(job["due"])) < visitMaxAge {
            guard let cid = job["companion"] as? String, let id = job["moment"] as? Int else { continue }
            if await visit(host, companion: cid, moment: id, replyTo: job["reply_to"] as? Int) { continue }
            let tries = (job["tries"] as? Int ?? 0) + 1
            guard tries < 3 else { NSLog("[moments] \(cid) 来 #\(id) 失败 3 次，算了"); continue }
            var again = job
            again["tries"] = tries
            again["due"] = LocalStore.iso(Date().addingTimeInterval(10 * 60))
            retry.append(again)
        }
        if !retry.isEmpty {
            visitLock.lock()
            s.saveCollection("moment-visits", s.collection("moment-visits") + retry)
            visitLock.unlock()
        }
        if !s.collection("moment-visits").isEmpty { scheduleVisits(host) }
    }

    /// 来一趟：你发的动态先赞上（不用问模型），再问模型写一句评论。false = 评论没写成、该再来一次
    private static func visit(_ host: LocalHost, companion cid: String, moment id: Int, replyTo: Int?) async -> Bool {
        let s = host.store
        guard let comp = s.companions.first(where: { ($0["id"] as? String) == cid }),
              let m = s.collection("moments").first(where: { ($0["id"] as? Int) == id }) else { return true }   // 人 / 动态删了：不用再来
        if replyTo == nil {
            _ = update(s, id) { m in
                var likes = m["likes"] as? [[String: Any]] ?? []
                if !likes.contains(where: { ($0["who"] as? String) == cid }) { likes.append(["who": cid, "at": LocalStore.iso(Date())]) }
                m["likes"] = likes
            }
        }
        guard let (provider, key) = host.route(chore: "moments", else: host.quietRoute(for: comp)) else {
            NSLog("[moments] \(cid) 没有能用的钥匙，只赞不评"); return true
        }
        guard !LiteConsent.book.needsAsk(provider) else { NSLog("[moments] \(cid) 这把钥匙还没同意发数据，只赞不评"); return true }
        let comments = m["comments"] as? [[String: Any]] ?? []
        var onMyPost = false
        if let replyTo {
            guard let mine = comments.first(where: { ($0["id"] as? Int) == replyTo }) else { return true }   // 那句被删了
            onMyPost = mine["reply_to"] is NSNull || mine["reply_to"] == nil
        }
        let zh = ((comp["settings"] as? [String: Any])?["lang"] as? String ?? "zh") == "zh"
        let contact = LocalBrain.contact(comp, provider: provider)
        let thread = comments.map { "\(names(host)[$0["author"] as? String ?? ""] ?? "")：\($0["content"] as? String ?? "")" }.joined(separator: "\n")
        let ask = zh
            ? "TA 在朋友圈\(replyTo == nil ? "发了一条" : onMyPost ? "评论了你的动态" : "回了你的评论")。\n动态：\(m["content"] as? String ?? "")\(thread.isEmpty ? "" : "\n评论区：\n\(thread)")\n\n用你的口吻写一句评论（朋友圈那种短短一句），只写这一句。"
            : "They \(replyTo == nil ? "posted on their feed" : onMyPost ? "commented on your post" : "replied to your comment").\nPost: \(m["content"] as? String ?? "")\(thread.isEmpty ? "" : "\nComments:\n\(thread)")\n\nWrite one short comment in your own voice. Only the comment."
        var req = Prompt.build(PromptInput(contact: contact, identity: contact.mainIdentity, history: [], lang: zh ? .zh : .en))
        req.turns = [ChatTurn(role: .user, text: ask)]
        req.maxTokens = 400
        var text = ""
        do { for try await e in makeClient(provider, key: key).stream(req) { if case .text(let t) = e { text += t } } } catch {
            NSLog("[moments] \(cid) 来 #\(id) 问模型失败：\(error)"); return false
        }
        let said = Monologue.split(ModelNoise.strip(text)).body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !said.isEmpty else { NSLog("[moments] \(cid) 来 #\(id) 模型什么都没写"); return false }
        _ = update(s, id) { m in
            var cs = m["comments"] as? [[String: Any]] ?? []
            cs.append(["id": s.nextID("moment-comment"), "author": cid, "content": String(said.prefix(300)),
                       "reply_to": replyTo ?? NSNull(), "created_at": LocalStore.iso(Date())])
            m["comments"] = cs
        }
        return true
    }
}
#endif
