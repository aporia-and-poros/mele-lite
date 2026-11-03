#if LITE
import Foundation
import NaturalLanguage
import MeleLiteCore

/// 本地记忆库（2026-10-11，第 20 版）：没有服务器的人也有记忆库。
/// 对 Lite 来说它就是一个 MCP 记忆库服务——工具名、参数、返回格式跟 mele-memory 一样，
/// 只是不连网、直接在进程里回话，所以 wake / recall / remember / 导入挑记忆这些链路一行不用改。
/// 想起用「关键词为主、苹果自带向量为辅」（tools/memory_eval/hybrid_eval.swift 量过：16 句命中 12，闲聊不乱浮）。
/// 存在 lite-host/memory/ 里 → 备份到文件自动带上（LocalBackup 打包整个 Documents）。
/// 不做 person_upsert / people / date_* / letter_*：人物卡、远事、信 Lite 有自己的房间。
final class LocalMemory: @unchecked Sendable {
    static let serverID = "local-memory"
    static let serverURL = "local://memory"

    // MARK: - 分仓（10-11 Aporia）：默认大家共用一本；TA 设定里开了「单独记一本」的，用自己那本
    // 共用 = lite-host/memory/（第 20 版的老位置，数据不用搬）；单独的 = lite-host/memory-<联系人 id>/

    static let sharedScope = "shared"
    private static let vaultLock = NSLock()
    nonisolated(unsafe) private static var vaults: [String: LocalMemory] = [:]

    /// 共用那本
    static var shared: LocalMemory { vault(sharedScope) }

    /// 按仓拿（同一个仓永远是同一个实例，锁和缓存跟着它）
    static func vault(_ scope: String) -> LocalMemory {
        vaultLock.withLock {
            if let v = vaults[scope] { return v }
            let v = LocalMemory(store: .shared, folder: scope == sharedScope ? "memory" : "memory-\(scope)")
            vaults[scope] = v
            return v
        }
    }

    /// 这个 TA 用哪本：设定 memory_scope = "own" 是自己那本（仓 id = 联系人 id），其余都是共用
    static func scope(of companion: [String: Any]) -> String {
        let st = companion["settings"] as? [String: Any] ?? [:]
        guard st["memory_scope"] as? String == "own", let cid = companion["id"] as? String, !cid.isEmpty else { return sharedScope }
        return cid
    }

    /// 记忆库页的仓选择：共用 + 开了单独一本的各 TA（接的是本地记忆库的才算）
    static func scopes(_ store: LocalStore) -> [(id: String, name: String)] {
        var out: [(String, String)] = [(sharedScope, String(localized: "共用"))]
        for c in store.companions {
            let st = c["settings"] as? [String: Any] ?? [:]
            guard st["memory_server"] as? String == serverID, scope(of: c) != sharedScope, let cid = c["id"] as? String else { continue }
            out.append((cid, (c["persona"] as? [String: Any])?["name"] as? String ?? "TA"))
        }
        return out
    }

    /// 删联系人时把 TA 那本一起删（共用的不动）
    static func dropVault(_ store: LocalStore, companion cid: String) {
        vaultLock.withLock { vaults[cid] = nil }
        try? FileManager.default.removeItem(at: store.root.appendingPathComponent("memory-\(cid)"))
    }

    let store: LocalStore
    /// 这本存在 lite-host 下的哪个文件夹
    let folder: String
    private let lock = NSRecursiveLock()
    private var items: [Item]
    private var vectors: [Int: Vector]          // id → 向量（跟着 vectors.json）
    private var recentShown: [Int: Date] = [:]  // 6 小时内递过的不再递（只在内存里，重开 App 就忘）
    private var termCache: [Int: Set<String>] = [:]
    private let embedder = Embedder()

    init(store: LocalStore, folder: String = "memory") {
        self.store = store
        self.folder = folder
        items = (store.read("\(folder)/memories.json") as? [[String: Any]] ?? []).compactMap(Item.init)
        var vs: [Int: Vector] = [:]
        for (k, v) in store.read("\(folder)/vectors.json") as? [String: Any] ?? [:] {
            guard let id = Int(k), let d = v as? [String: Any], let b64 = d["v"] as? String,
                  let data = Data(base64Encoded: b64) else { continue }
            let floats = data.withUnsafeBytes { Array($0.bindMemory(to: Float32.self)) }
            vs[id] = Vector(lang: d["lang"] as? String ?? "zh", v: floats.map(Double.init))
        }
        vectors = vs
    }

    // MARK: - 一条记忆

    struct Item {
        var id: Int
        var kind: String          // memory / core（钉住的）
        var title: String
        var content: String
        var tags: [String]
        var importance: Int       // 1-10
        var valence: Double       // -1..1
        var arousal: Double       // 0..1
        var resolved: Bool
        var createdAt: Date
        var rewrittenAt: Date?
        /// 哪些 TA 记得这件事（10-11 群聊：共用一本时，同一件事并成一条，标「阿橘和小满都记得」）
        var by: [String] = []

        init?(_ d: [String: Any]) {
            guard let id = d["id"] as? Int, let content = d["content"] as? String else { return nil }
            self.id = id
            kind = d["kind"] as? String ?? "memory"
            title = d["title"] as? String ?? ""
            self.content = content
            tags = d["tags"] as? [String] ?? []
            importance = d["importance"] as? Int ?? 5
            valence = (d["valence"] as? NSNumber)?.doubleValue ?? 0
            arousal = (d["arousal"] as? NSNumber)?.doubleValue ?? 0
            resolved = d["resolved"] as? Bool ?? false
            createdAt = LocalStore.date(d["created_at"])
            rewrittenAt = (d["rewritten_at"] as? String).map { _ in LocalStore.date(d["rewritten_at"]) }
            by = d["by"] as? [String] ?? []
        }

        init(id: Int, kind: String = "memory", title: String = "", content: String, tags: [String] = [],
             importance: Int = 5, valence: Double = 0, arousal: Double = 0, resolved: Bool = false,
             createdAt: Date = Date(), rewrittenAt: Date? = nil) {
            self.id = id; self.kind = kind; self.title = title; self.content = content; self.tags = tags
            self.importance = importance; self.valence = valence; self.arousal = arousal
            self.resolved = resolved; self.createdAt = createdAt; self.rewrittenAt = rewrittenAt
        }

        var dict: [String: Any] {
            var d: [String: Any] = ["id": id, "kind": kind, "title": title, "content": content, "tags": tags,
                                    "importance": importance, "valence": valence, "arousal": arousal,
                                    "resolved": resolved, "created_at": LocalStore.iso(createdAt)]
            if let r = rewrittenAt { d["rewritten_at"] = LocalStore.iso(r) }
            if !by.isEmpty { d["by"] = by }
            return d
        }

        /// 分量：跟 mele-memory 的 decay.py 一个公式。钉住的不淡；越要紧淡得越慢；没了结的再慢一倍。
        func weight(_ now: Date = Date()) -> Double {
            let base = Double(importance) / 10.0
            let emotion = 1.0 + 0.5 * arousal
            if kind == "core" { return base * emotion }
            let mult: Double = [10: 16.0, 9: 10.0, 8: 6.0, 7: 4.0, 6: 2.5, 5: 1.6][importance] ?? 1.0
            let half = 30.0 * mult * (resolved ? 1.0 : 2.0)
            let anchor = max(createdAt, rewrittenAt ?? .distantPast)
            let days = max(0, now.timeIntervalSince(anchor) / 86400)
            return base * pow(0.5, days / half) * emotion
        }
    }

    struct Vector { var lang: String; var v: [Double] }

    private func save() {
        store.write("\(folder)/memories.json", items.map(\.dict))
    }

    private func saveVectors() {
        var out: [String: Any] = [:]
        for (id, vec) in vectors {
            let floats = vec.v.map(Float32.init)
            let data = floats.withUnsafeBufferPointer { Data(buffer: $0) }
            out["\(id)"] = ["lang": vec.lang, "v": data.base64EncodedString()]
        }
        store.write("\(folder)/vectors.json", out)
    }

    // MARK: - 分词（照 hybrid_eval.swift 量过的那套：汉字切相邻两字，英文数字 ≥3 字符）

    static func terms(_ s: String) -> [String] {
        var out: [String] = [], run: [Character] = [], word = ""
        func flushRun() {
            if run.count >= 2 { for i in 0..<run.count - 1 { out.append(String(run[i...i + 1])) } }
            run = []
        }
        func flushWord() { if word.count >= 3 { out.append(word) }; word = "" }
        for ch in s.lowercased() {
            if ("\u{4e00}"..."\u{9fff}").contains(ch) { flushWord(); run.append(ch) }
            else if ch.isLetter || ch.isNumber { flushRun(); word.append(ch) }
            else { flushRun(); flushWord() }
        }
        flushRun(); flushWord()
        return out
    }

    /// 虚词：两字的中文口头词 + 英文功能词（≥3 字符的那些）。称呼和「这个库里太常见的词」在 stopwords() 里另算。
    static let baseStop: Set<String> = [
        "今天", "明天", "昨天", "什么", "怎么", "一个", "这个", "那个", "可以", "我们", "你们", "他们", "她们",
        "没有", "不是", "就是", "还是", "但是", "因为", "所以", "如果", "时候", "现在", "一下", "一起", "有点",
        "the", "and", "you", "are", "for", "was", "were", "this", "that", "with", "have", "has", "had",
        "not", "but", "can", "could", "will", "would", "just", "what", "when", "your",
    ]

    /// 称呼（TA 的名字、叫用户什么、用户的名字）：几乎每条记忆里都有，进了关键词榜会喊坏整张榜
    private func names() -> Set<String> {
        var raw: [String] = [(store.read("profile.json") as? [String: Any])?["name"] as? String ?? ""]
        for c in store.companions {
            let p = c["persona"] as? [String: Any] ?? [:]
            let st = c["settings"] as? [String: Any] ?? [:]
            raw += [p["name"] as? String ?? "", p["call_user"] as? String ?? "", st["user_name"] as? String ?? ""]
        }
        var out: Set<String> = []
        for n in raw {
            let t = n.trimmingCharacters(in: .whitespaces).lowercased()
            guard !t.isEmpty else { continue }
            out.insert(t)
            out.formUnion(Self.terms(t))
        }
        return out
    }

    /// 这次检索的停用词：虚词 + 称呼 + 这个库里太常见的词（出现在 max(5, clamp(20/N, 2%, 20%)×N) 条以上）
    private func stopwords(df: [String: Int], total: Int) -> Set<String> {
        var stop = Self.baseStop.union(names())
        if total >= 5 {
            let ratio = min(0.20, max(0.02, 20.0 / Double(total)))
            let need = max(5, Int((ratio * Double(total)).rounded(.up)))
            for (w, n) in df where n >= need { stop.insert(w) }
        }
        return stop
    }

    private func docTerms(_ m: Item) -> Set<String> {
        if let hit = termCache[m.id] { return hit }
        let t = Set(Self.terms(m.title.isEmpty ? m.content : m.title + " " + m.content))
        termCache[m.id] = t
        return t
    }

    // MARK: - 打分（关键词 idf 为主、向量 z 分为辅；分 = Σidf + 0.5 × max(0, z)）

    struct Scored { var item: Item; var score: Double; var keyword: Bool }

    private func rank(_ query: String) -> [Scored] {
        let kept = items
        guard !kept.isEmpty else { return [] }
        var df: [String: Int] = [:]
        let docs = kept.map(docTerms)
        for t in docs { for w in t { df[w, default: 0] += 1 } }
        let stop = stopwords(df: df, total: kept.count)
        let qt = Set(Self.terms(query)).subtracting(stop)
        let N = Double(kept.count)
        func idf(_ w: String) -> Double { log((N + 1) / (Double(df[w] ?? 0) + 0.5)) }

        // 向量那一路：记忆少于 20 条时 z 不稳，只用关键词；查询和记忆的向量要同一种语言的模型才可比
        var zs: [Int: Double] = [:]
        if kept.count >= 20 {
            let qlang = embedder.lang(of: query)
            if let qv = embedder.vector(query, lang: qlang) {
                let same = kept.compactMap { m -> (Int, Double)? in
                    guard let v = vectors[m.id], v.lang == qlang else { return nil }
                    return (m.id, zip(qv, v.v).map(*).reduce(0, +))
                }
                if same.count >= 20 {
                    let sims = same.map(\.1)
                    let mean = sims.reduce(0, +) / Double(sims.count)
                    let sd = max(1e-6, sqrt(sims.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(sims.count)))
                    for (id, s) in same { zs[id] = (s - mean) / sd }
                }
            }
        }
        return kept.enumerated().map { i, m in
            let hitTerms = qt.intersection(docs[i].subtracting(stop))
            let kw = hitTerms.map(idf).reduce(0, +)
            return Scored(item: m, score: kw + 0.5 * max(0, zs[m.id] ?? 0), keyword: !hitTerms.isEmpty)
        }
    }

    /// 没向量的旧记忆：recall 时每次顺手补 20 条（模型资产刚下好时慢慢追上）
    private func backfillVectors() {
        var done = 0
        for m in items where vectors[m.id] == nil && done < 20 {
            let lang = embedder.lang(of: m.content)
            guard let v = embedder.vector(m.content, lang: lang) else { return }   // 模型还没好：下次再补
            vectors[m.id] = Vector(lang: lang, v: v)
            done += 1
        }
        if done > 0 { saveVectors() }
    }

    private func embed(_ m: Item) {
        let lang = embedder.lang(of: m.content)
        if let v = embedder.vector(m.content, lang: lang) { vectors[m.id] = Vector(lang: lang, v: v); saveVectors() }
        else { vectors[m.id] = nil }
    }

    // MARK: - 想不想得起（照 mele-memory recall.py 的 worth_recalling）

    private static let smallTalk = try! NSRegularExpression(
        pattern: "^(好的?|嗯+|哦+|噢|哈+|嘿+|嘻+|呜+|啊+|行|对|是|好呀|好哦|收到|晚安|早安|么么|亲亲|抱抱|"
            + "ok(ay)?|thanks?|thank you|ok thanks|lol|haha+|yes|no|sure|night|morning)$",
        options: [.caseInsensitive])

    static func worthRecalling(_ text: String) -> Bool {
        var body = ""
        for s in text.unicodeScalars where !(0x1F000...0x1FAFF).contains(s.value) && !(0x2600...0x27BF).contains(s.value) && s.value != 0xFE0F {
            body.unicodeScalars.append(s)
        }
        let bare = body.components(separatedBy: CharacterSet(charactersIn: " \n\t?？!！~～。.…,，"))
            .filter { !$0.isEmpty }.joined(separator: " ")
        if bare.replacingOccurrences(of: " ", with: "").count < 5 { return false }
        let r = NSRange(bare.startIndex..., in: bare)
        return smallTalk.firstMatch(in: bare, range: r) == nil
    }

    // MARK: - 给模型看的文字（照 mcp_server/server.py 的 memory_line / memory_data）

    static func line(_ m: Item, now: Date = Date()) -> String {
        var flags = [m.kind]
        if m.resolved { flags.append("resolved") }
        let day = ISO8601DateFormatter.string(from: m.createdAt, timeZone: TimeZone(identifier: "UTC")!, formatOptions: [.withFullDate])
        var head = "#\(m.id) [\(flags.joined(separator: ", "))] importance \(m.importance), weight \(String(format: "%.2f", m.weight(now))), \(day)"
        if !m.tags.isEmpty { head += " #" + m.tags.joined(separator: " #") }
        return head + "\n" + (m.title.isEmpty ? m.content : "\(m.title)｜\(m.content)")
    }

    static func data(_ m: Item, now: Date = Date()) -> [String: Any] {
        var d = m.dict
        d["weight"] = (m.weight(now) * 10000).rounded() / 10000
        return d
    }

    private func ok(_ text: String, _ data: [String: Any]) -> MCPCallResult {
        let json = (try? JSONSerialization.data(withJSONObject: data)).flatMap { String(data: $0, encoding: .utf8) }
        return MCPCallResult(text: text, structuredJSON: json, isError: false)
    }

    private func err(_ text: String) -> MCPCallResult { MCPCallResult(text: text, structuredJSON: nil, isError: true) }

    private func snippet(_ text: String, _ n: Int = 80) -> String {
        let t = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return t.count <= n ? t : String(t.prefix(n)) + "…"
    }

    // MARK: - 工具本体

    func find(_ id: Int) -> Item? { lock.withLock { items.first { $0.id == id } } }
    var all: [Item] { lock.withLock { items } }

    /// 记之前粗筛「可能重了」的几条，交给模型判断是不是同一件事（10-12：字面和向量都分不清换了说法的同一件事
    /// 跟「下周三考数学 / 考英语」这种不同的事，只能问模型）。字面重合 ≥0.15 的前 3 条 + 向量最近的前 2 条
    func dedupeCandidates(for content: String) -> [MemoryDedupe.Candidate] {
        let body = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return [] }
        let lang = embedder.lang(of: body)
        let qv = embedder.vector(body, lang: lang)
        return lock.withLock {
            let new = Set(Self.terms(body))
            let pool = items.filter { $0.kind != "core" }
            let byTerms = pool.map { m -> (Item, Double) in
                let old = docTerms(m)
                let u = Double(new.union(old).count)
                return (m, u > 0 ? Double(new.intersection(old).count) / u : 0)
            }.filter { $0.1 >= 0.15 }.sorted { $0.1 > $1.1 }.prefix(3).map(\.0)
            var byVector: [Item] = []
            if let qv {
                byVector = pool.compactMap { m -> (Item, Double)? in
                    guard let v = vectors[m.id], v.lang == lang else { return nil }
                    return (m, zip(qv, v.v).map(*).reduce(0, +))
                }.sorted { $0.1 > $1.1 }.prefix(2).map(\.0)
            }
            var seen = Set<Int>(), out: [MemoryDedupe.Candidate] = []
            for m in byTerms + byVector where seen.insert(m.id).inserted {
                out.append(.init(id: m.id, content: m.content))
            }
            return out
        }
    }

    /// 跟已有记忆比词集 Jaccard：≥0.75 合并，0.45~0.75 照存但提醒模型可能重了。
    /// mergeInto = 模型判断过是同一件事的那条（10-12）：直接并进去
    /// by = 哪个 TA 在记（10-11）：并进别的 TA 记过的那条时不改人家的说法，只把自己添进「也记得」
    func remember(content: String, title: String = "", tags: [String] = [], importance: Int = 5,
                  valence: Double = 0, arousal: Double = 0, by: String = "", mergeInto: Int? = nil) -> MCPCallResult {
        let body = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return err("content is empty") }
        return lock.withLock {
            let new = Set(Self.terms(body))
            var best: (item: Item, j: Double)?
            for m in items where m.kind != "core" {
                let old = docTerms(m)
                let inter = Double(new.intersection(old).count)
                let union = Double(new.union(old).count)
                let j = union > 0 ? inter / union : 0
                if j > (best?.j ?? 0) { best = (m, j) }
            }
            let imp = max(1, min(10, importance))
            if let id = mergeInto, let m = items.first(where: { $0.id == id && $0.kind != "core" }) { best = (m, 1) }
            if let b = best, b.j >= 0.75 {        // 同一件事：换上新的说法（别的 TA 记的就不改说法，只添上自己）
                var m = b.item
                let someoneElse = !by.isEmpty && !m.by.isEmpty && !m.by.contains(by)
                if !by.isEmpty && !m.by.contains(by) { m.by.append(by) }
                if someoneElse {
                    m.tags = Array(Set(m.tags + tags.map { String($0.prefix(20)) }).prefix(8)).sorted()
                    m.importance = max(m.importance, imp)
                    replace(m)
                    return ok("Merged into #\(m.id) (already remembered).\n\(Self.line(m))", ["merged": true, "memory": Self.data(m)])
                }
                m.content = body
                if !title.isEmpty { m.title = String(title.prefix(60)) }
                m.tags = Array(Set(m.tags + tags.map { String($0.prefix(20)) }).prefix(8)).sorted()
                m.importance = max(m.importance, imp)
                m.valence = valence; m.arousal = arousal
                m.rewrittenAt = Date()
                replace(m)
                return ok("Merged into #\(m.id).\n\(Self.line(m))", ["merged": true, "memory": Self.data(m)])
            }
            let m = Item(id: store.nextID("memory_item"), title: String(title.prefix(60)), content: body,
                         tags: Array(tags.map { String($0.prefix(20)) }.prefix(8)), importance: imp,
                         valence: max(-1, min(1, valence)), arousal: max(0, min(1, arousal)))
            var made = m
            if !by.isEmpty { made.by = [by] }
            items.append(made)
            termCache[m.id] = nil
            save()
            embed(m)
            var text = "Saved as #\(m.id).\n\(Self.line(m))"
            if let b = best, b.j >= 0.45 {
                text += "\n跟 #\(b.item.id) 很像：\(snippet(b.item.content, 60))。如果是同一件事，update #\(b.item.id) 再 forget 这条。"
            }
            return ok(text, ["merged": false, "memory": Self.data(made)])
        }
    }

    /// 从别的记忆库搬进来的（保留原来的日子）；跟 remember 一样会合并重复的。返回存成的 id，重复合并也算搬到。
    @discardableResult
    func importItem(_ d: [String: Any]) -> Int? {
        guard let content = d["content"] as? String, !content.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return lock.withLock {
            let new = Set(Self.terms(content))
            for m in items {
                let old = docTerms(m)
                let union = Double(new.union(old).count)
                if union > 0, Double(new.intersection(old).count) / union >= 0.75 { return m.id }
            }
            let kind = (d["kind"] as? String) == "core" ? "core" : "memory"
            let m = Item(id: store.nextID("memory_item"), kind: kind,
                         title: String((d["title"] as? String ?? "").prefix(60)), content: content,
                         tags: Array((d["tags"] as? [String] ?? []).map { String($0.prefix(20)) }.prefix(8)),
                         importance: max(1, min(10, d["importance"] as? Int ?? 5)),
                         valence: (d["valence"] as? NSNumber)?.doubleValue ?? 0,
                         arousal: (d["arousal"] as? NSNumber)?.doubleValue ?? 0,
                         resolved: d["resolved"] as? Bool ?? false,
                         createdAt: d["created_at"] != nil ? LocalStore.date(d["created_at"]) : Date(),
                         rewrittenAt: (d["rewritten_at"] as? String).map { _ in LocalStore.date(d["rewritten_at"]) })
            items.append(m)
            termCache[m.id] = nil
            save()
            embed(m)
            return m.id
        }
    }

    /// 从另一本拷过来（分仓切换时问的「拷一份」）：走 importItem，原日期留着、重的自动合并；原来那本不动。返回新添了几条
    func copy(from other: LocalMemory) -> Int {
        guard other !== self else { return 0 }
        let before = all.count
        for m in other.all { _ = importItem(m.dict) }
        return all.count - before
    }

    /// 门槛按 hybrid_eval 量出来的分数定：medium 整条 ≥5、摘要 ≥3；light 6/4；rich 4/2.2
    private static let tiers: [String: (full: Double, line: Double)] = [
        "light": (6.0, 4.0), "medium": (5.0, 3.0), "rich": (4.0, 2.2),
    ]

    func recall(text: String, level: String = "medium") -> MCPCallResult {
        guard level != "off" else { return ok("Nothing surfaced.", ["full": [], "lines": []]) }
        guard let tier = Self.tiers[level] else { return err("level must be light, medium or rich") }
        return lock.withLock {
            backfillVectors()
            let now = Date()
            recentShown = recentShown.filter { now.timeIntervalSince($0.value) < 6 * 3600 }
            guard Self.worthRecalling(text) else { return ok("Nothing surfaced.", ["full": [], "lines": []]) }
            let ranked = rank(text)
                .filter { $0.score >= tier.line && recentShown[$0.item.id] == nil }
                .sorted { $0.score * (0.5 + $0.item.weight(now)) > $1.score * (0.5 + $1.item.weight(now)) }
            var full: [Item] = [], lines: [Item] = []
            for s in ranked {
                if s.score >= tier.full && full.count < 2 { full.append(s.item) }
                else if lines.count < 3 { lines.append(s.item) }
            }
            for m in full + lines { recentShown[m.id] = now }
            var parts: [String] = []
            if !full.isEmpty { parts.append("Memories:\n" + full.map { Self.line($0, now: now) }.joined(separator: "\n\n")) }
            if !lines.isEmpty { parts.append("Might be related:\n" + lines.map { "#\($0.id) \(snippet($0.content))" }.joined(separator: "\n")) }
            return ok(parts.isEmpty ? "Nothing surfaced." : parts.joined(separator: "\n\n"), [
                "full": full.map { Self.data($0, now: now) },
                "lines": lines.map { ["id": $0.id, "snippet": snippet($0.content), "kind": $0.kind] },
            ])
        }
    }

    func search(query: String, limit: Int = 10) -> MCPCallResult {
        lock.withLock {
            backfillVectors()
            let now = Date()
            let hits = rank(query)
                .filter { $0.score > 0.5 }
                .sorted { $0.score * (0.5 + $0.item.weight(now)) > $1.score * (0.5 + $1.item.weight(now)) }
                .prefix(max(1, min(limit, 50)))
            let text = hits.map { Self.line($0.item, now: now) }.joined(separator: "\n\n")
            return ok(text.isEmpty ? "No matches." : text, ["hits": hits.map {
                ["memory": Self.data($0.item, now: now), "score": ($0.score * 1e6).rounded() / 1e6, "keyword": $0.keyword]
            }])
        }
    }

    func listMemories(kind: String? = nil, order: String = "new", resolved: Bool? = nil,
                      limit: Int = 50, offset: Int = 0) -> MCPCallResult {
        lock.withLock {
            var out = items
            if let kind, !kind.isEmpty {
                guard ["memory", "core"].contains(kind) else { return err("kind must be memory or core") }
                out = out.filter { $0.kind == kind }
            }
            if let resolved { out = out.filter { $0.resolved == resolved } }
            switch order {
            case "new": out.sort { $0.createdAt > $1.createdAt }
            case "old": out.sort { $0.createdAt < $1.createdAt }
            case "important": out.sort { ($0.importance, $0.createdAt.timeIntervalSince1970) > ($1.importance, $1.createdAt.timeIntervalSince1970) }
            case "unimportant": out.sort { $0.importance < $1.importance }
            default: return err("order must be new, old, important or unimportant")
            }
            let page = Array(out.dropFirst(max(0, offset)).prefix(max(1, min(limit, 200))))
            let now = Date()
            let text = page.map { Self.line($0, now: now) }.joined(separator: "\n\n")
            return ok(text.isEmpty ? "No memories." : text, ["memories": page.map { Self.data($0, now: now) }])
        }
    }

    private func replace(_ m: Item) {
        if let i = items.firstIndex(where: { $0.id == m.id }) { items[i] = m }
        termCache[m.id] = nil
        save()
        embed(m)
    }

    func update(id: Int, content: String? = nil, title: String? = nil, tags: [String]? = nil,
                importance: Int? = nil, valence: Double? = nil, arousal: Double? = nil) -> MCPCallResult {
        lock.withLock {
            guard var m = items.first(where: { $0.id == id }) else { return err("no memory #\(id)") }
            if let content, !content.trimmingCharacters(in: .whitespaces).isEmpty {
                m.content = content.trimmingCharacters(in: .whitespacesAndNewlines)
                m.rewrittenAt = Date()
            }
            if let title { m.title = String(title.prefix(60)) }
            if let tags { m.tags = Array(tags.map { String($0.prefix(20)) }.prefix(8)) }
            if let importance { m.importance = max(1, min(10, importance)) }
            if let valence { m.valence = max(-1, min(1, valence)) }
            if let arousal { m.arousal = max(0, min(1, arousal)) }
            replace(m)
            return ok("Updated.\n\(Self.line(m))", ["memory": Self.data(m)])
        }
    }

    func pin(id: Int, pinned: Bool = true) -> MCPCallResult {
        lock.withLock {
            guard var m = items.first(where: { $0.id == id }) else { return err("no memory #\(id)") }
            m.kind = pinned ? "core" : "memory"
            replace(m)
            return ok("\(pinned ? "Pinned" : "Unpinned").\n\(Self.line(m))", ["memory": Self.data(m)])
        }
    }

    func resolve(id: Int, resolved: Bool = true) -> MCPCallResult {
        lock.withLock {
            guard var m = items.first(where: { $0.id == id }) else { return err("no memory #\(id)") }
            m.resolved = resolved
            replace(m)
            return ok("\(resolved ? "Resolved" : "Reopened").\n\(Self.line(m))", ["memory": Self.data(m)])
        }
    }

    func forget(id: Int) -> MCPCallResult {
        lock.withLock {
            guard items.contains(where: { $0.id == id }) else { return err("no memory #\(id)") }
            items.removeAll { $0.id == id }
            vectors[id] = nil
            termCache[id] = nil
            save(); saveVectors()
            return ok("Forgot #\(id).", ["deleted": id])
        }
    }

    var sticky: String {
        get { store.read("\(folder)/sticky.json") as? String ?? "" }
        set { store.write("\(folder)/sticky.json", String(newValue.prefix(300))) }
    }

    /// 钉住的记忆，每轮放进 system 最前面那层（10-11 Aporia：照 Host 的壹层「一直记着的」）。
    /// 按钉的先后排（旧的在前），新钉一条只动尾巴，缓存接得上；最多 30 条。
    func pinnedLines(limit: Int = 30) -> [String] {
        lock.withLock {
            items.filter { $0.kind == "core" }.sorted { $0.id < $1.id }.prefix(limit)
                .map { $0.title.isEmpty ? $0.content : "\($0.title)：\($0.content)" }
        }
    }

    func wake() -> MCPCallResult {
        lock.withLock {
            let now = Date()
            let core = items.filter { $0.kind == "core" }
                .sorted { ($0.importance, $0.createdAt.timeIntervalSince1970) > ($1.importance, $1.createdAt.timeIntervalSince1970) }
                .prefix(40)
            let open = items.filter { $0.kind != "core" && !$0.resolved }
                .sorted { $0.weight(now) > $1.weight(now) }.prefix(5)
            var parts: [String] = []
            if !core.isEmpty {
                parts.append("Core (pinned):\n" + core.map { "#\($0.id) " + ($0.title.isEmpty ? $0.content : "\($0.title)｜\($0.content)") }.joined(separator: "\n"))
            }
            if !open.isEmpty { parts.append("Still open, weighing most:\n" + open.map { Self.line($0, now: now) }.joined(separator: "\n")) }
            let note = sticky
            if !note.isEmpty { parts.append("Your sticky note:\n" + note) }
            return ok(parts.isEmpty ? "Nothing yet. This is the beginning." : parts.joined(separator: "\n\n"), [
                "core": core.map { Self.data($0, now: now) }, "open": open.map { Self.data($0, now: now) }, "sticky": note,
            ])
        }
    }

    // MARK: - MCP 的壳（名字、描述、参数照 mele-memory/mcp_server/server.py，去掉这里没有的 date/person/letter）

    private static func spec(_ props: [String: Any], required: [String] = []) -> String {
        var s: [String: Any] = ["type": "object", "properties": props]
        if !required.isEmpty { s["required"] = required }
        return (try? JSONSerialization.data(withJSONObject: s, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    func tools() -> [MCPTool] {
        [
            MCPTool(name: "wake",
                    description: "Call once at the start of every conversation, before anything else. Brings back your pinned "
                        + "core memories, the open matters that weigh most, and your sticky note.",
                    inputSchemaJSON: Self.spec([:])),
            MCPTool(name: "recall",
                    description: "Let memories related to what the user just said surface. Pass their message as `text`. "
                        + "Returns very related memories in full and loosely related ones as one-line snippets. "
                        + "level: light (fewer) / medium / rich (more).",
                    inputSchemaJSON: Self.spec(["text": ["type": "string"], "level": ["type": "string"]], required: ["text"])),
            MCPTool(name: "remember",
                    description: "Store a memory. Use for things worth keeping: facts about the user, promises, how they felt. "
                        + "title: your own short headline, 2-6 words, written fresh (don't copy or cut the first sentence), e.g. "
                        + "\"Mango allergy\". tags: 1-4 short topic tags, e.g. [\"health\", \"family\"]. "
                        + "importance 1-10 (10 = never let this fade). valence -1..1 (sad..happy), arousal 0..1 "
                        + "(calm..intense). If a nearly identical memory exists it is merged, not duplicated. "
                        + "Write content in your own first person: you are \"I\", the user is their name (or \"they\"), never \"you\" — "
                        + "otherwise it's unclear later who did what.",
                    inputSchemaJSON: Self.spec([
                        "content": ["type": "string"], "title": ["type": "string"],
                        "tags": ["type": "array", "items": ["type": "string"]],
                        "importance": ["type": "integer"], "valence": ["type": "number"], "arousal": ["type": "number"],
                    ], required: ["content"])),
            MCPTool(name: "search",
                    description: "Search memories by words or meaning (keyword + vector hybrid, ranked by how much each "
                        + "memory still weighs). Use when looking for something specific.",
                    inputSchemaJSON: Self.spec(["query": ["type": "string"], "limit": ["type": "integer"]], required: ["query"])),
            MCPTool(name: "list_memories",
                    description: "List memories. kind: memory / core (pinned); leave empty for everything. "
                        + "order: new (default) / old / important / unimportant. "
                        + "resolved: true = only settled ones, false = only open ones.",
                    inputSchemaJSON: Self.spec([
                        "kind": ["type": "string"], "order": ["type": "string"], "resolved": ["type": "boolean"],
                        "limit": ["type": "integer"], "offset": ["type": "integer"],
                    ])),
            MCPTool(name: "update",
                    description: "Change a memory: content, title, tags (replaces the list) and/or importance (1-10). "
                        + "Leave a field out to keep it.",
                    inputSchemaJSON: Self.spec([
                        "id": ["type": "integer"], "content": ["type": "string"], "title": ["type": "string"],
                        "tags": ["type": "array", "items": ["type": "string"]], "importance": ["type": "integer"],
                    ], required: ["id"])),
            MCPTool(name: "pin",
                    description: "Pin a memory as core (it never fades) or unpin it.",
                    inputSchemaJSON: Self.spec(["id": ["type": "integer"], "pinned": ["type": "boolean"]], required: ["id"])),
            MCPTool(name: "resolve",
                    description: "Mark a memory resolved (the matter is settled, so it fades at the normal pace) "
                        + "or reopen it with resolved=false.",
                    inputSchemaJSON: Self.spec(["id": ["type": "integer"], "resolved": ["type": "boolean"]], required: ["id"])),
            MCPTool(name: "forget",
                    description: "Delete a memory for good. Only when the user asks to forget it or it is plainly wrong.",
                    inputSchemaJSON: Self.spec(["id": ["type": "integer"]], required: ["id"])),
            MCPTool(name: "sticky_get",
                    description: "Read the sticky note you left for yourself.",
                    inputSchemaJSON: Self.spec([:])),
            MCPTool(name: "sticky_set",
                    description: "Overwrite the sticky note: a few lines for your next turn (what you're in the middle of, "
                        + "what to bring up). Max 300 characters; empty text clears it.",
                    inputSchemaJSON: Self.spec(["text": ["type": "string"]], required: ["text"])),
        ]
    }

    func call(_ name: String, argumentsJSON: String, by: String = "") -> MCPCallResult {
        let a = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8)) as? [String: Any]) ?? [:]
        switch name {
        case "wake": return wake()
        case "recall": return recall(text: a["text"] as? String ?? "", level: a["level"] as? String ?? "medium")
        case "remember":
            return remember(content: a["content"] as? String ?? "", title: a["title"] as? String ?? "",
                            tags: a["tags"] as? [String] ?? [], importance: a["importance"] as? Int ?? 5,
                            valence: (a["valence"] as? NSNumber)?.doubleValue ?? 0,
                            arousal: (a["arousal"] as? NSNumber)?.doubleValue ?? 0, by: by,
                            mergeInto: a["_merge_into"] as? Int)
        case "search": return search(query: a["query"] as? String ?? "", limit: a["limit"] as? Int ?? 10)
        case "list_memories":
            return listMemories(kind: a["kind"] as? String, order: a["order"] as? String ?? "new",
                                resolved: a["resolved"] as? Bool, limit: a["limit"] as? Int ?? 50,
                                offset: a["offset"] as? Int ?? 0)
        case "update":
            guard let id = a["id"] as? Int else { return err("id is required") }
            return update(id: id, content: a["content"] as? String, title: a["title"] as? String,
                          tags: a["tags"] as? [String], importance: a["importance"] as? Int)
        case "pin":
            guard let id = a["id"] as? Int else { return err("id is required") }
            return pin(id: id, pinned: a["pinned"] as? Bool ?? true)
        case "resolve":
            guard let id = a["id"] as? Int else { return err("id is required") }
            return resolve(id: id, resolved: a["resolved"] as? Bool ?? true)
        case "forget":
            guard let id = a["id"] as? Int else { return err("id is required") }
            return forget(id: id)
        case "sticky_get":
            let t = sticky
            return ok(t.isEmpty ? "(empty)" : t, ["text": t])
        case "sticky_set":
            sticky = a["text"] as? String ?? ""
            let t = sticky
            return ok(t.isEmpty ? "Cleared." : "Saved: \(t)", ["text": t])
        default:
            return err("no tool \(name)")
        }
    }

    // MARK: - 星图要的数据（照 mele-memory/memory/graph.py：相近的连线、挂得多的标签成行星、提到你的挂到爱心上）

    struct Star { var id: Int; var label: String; var title: String; var tags: [String]; var weight: Double; var content: String }
    struct StarEdge { var a: Int; var b: Int; var strength: Double }
    struct StarHub { var label: String; var members: Set<Int> }
    struct StarGraph { var stars: [Star]; var edges: [StarEdge]; var hubs: [StarHub]; var mine: Set<Int>; var userLabel: String }

    func graph() -> StarGraph {
        lock.withLock {
            let now = Date()
            let stars = items.map {
                Star(id: $0.id, label: String(($0.title.isEmpty ? $0.content : $0.title).prefix(24)),
                     title: $0.title, tags: $0.tags, weight: $0.weight(now), content: $0.content)
            }
            // 连线：每条记忆连最像的 3 条（向量在就用向量，不在用词集 Jaccard），够像才连
            var edges: [StarEdge] = []
            var seen: Set<String> = []
            let ids = items.map(\.id)
            var sims: [[Double]] = []
            let vecs = items.map { vectors[$0.id] }
            let docs = items.map(docTerms)
            for i in items.indices {
                var row = [Double](repeating: -1, count: items.count)
                for j in items.indices where j != i {
                    if let a = vecs[i], let b = vecs[j], a.lang == b.lang {
                        row[j] = zip(a.v, b.v).map(*).reduce(0, +)
                    } else {
                        let u = Double(docs[i].union(docs[j]).count)
                        row[j] = u > 0 ? Double(docs[i].intersection(docs[j]).count) / u : 0
                    }
                }
                sims.append(row)
            }
            // 门槛自适应：苹果向量的底子偏高，取全部相似度的 均值 + 1 个标准差
            let flat = sims.flatMap { $0 }.filter { $0 > -1 }
            let mean = flat.isEmpty ? 0 : flat.reduce(0, +) / Double(flat.count)
            let sd = flat.isEmpty ? 0 : sqrt(flat.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(flat.count))
            let minSim = mean + sd
            for i in items.indices {
                for j in sims[i].enumerated().sorted(by: { $0.element > $1.element }).prefix(3) where j.element >= minSim {
                    let key = "\(min(ids[i], ids[j.offset]))-\(max(ids[i], ids[j.offset]))"
                    if seen.insert(key).inserted { edges.append(StarEdge(a: ids[i], b: ids[j.offset], strength: j.element)) }
                }
            }
            // 行星：一个标签挂的记忆 ≥ max(4, 总数 × 5%) 就单独成一颗星
            var byTag: [String: Set<Int>] = [:]
            for m in items { for t in m.tags { byTag[t, default: []].insert(m.id) } }
            let need = max(4, Int((Double(items.count) * 0.05).rounded(.up)))
            let hubs = byTag.filter { $0.value.count >= need }
                .map { StarHub(label: $0.key, members: $0.value) }
                .sorted { $0.members.count > $1.members.count }
            // 正中间的「你」：正文里提到用户名字的记忆
            let me = ((store.read("profile.json") as? [String: Any])?["name"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            var mine: Set<Int> = []
            if !me.isEmpty {
                for m in items where m.content.localizedCaseInsensitiveContains(me) { mine.insert(m.id) }
            }
            return StarGraph(stars: stars, edges: edges, hubs: hubs, mine: mine, userLabel: me.isEmpty ? String(localized: "你") : me)
        }
    }

    // MARK: - 默认接上（第 20 版升级）：设置里没碰过记忆库的老联系人，设成本地；显式选过「不接」（NSNull）的不动

    static func adoptDefaults(_ store: LocalStore) {
        for var c in store.companions {
            var st = c["settings"] as? [String: Any] ?? [:]
            guard st.index(forKey: "memory_server") == nil else { continue }
            st["memory_server"] = serverID
            c["settings"] = st
            store.saveCompanion(c)
        }
    }

    #if DEBUG
    func debugRank(_ query: String) -> [(id: Int, score: Double)] {
        lock.withLock { rank(query).sorted { $0.score > $1.score }.map { ($0.item.id, $0.score) } }
    }

    var debugVectorCount: Int { lock.withLock { vectors.count } }
    #endif
}

#if DEBUG
/// 自测（模拟器 -memorySelfTest，照 LocalBackup.selfTest 的样子）：灌 mele-memory 的评测集那 43 条、
/// 跑 16+6 句，打印第一名命中数（拿 Mac 上量过的 ≥12/16 对一下），闲聊不该浮。
/// 评测集先拷进 Documents：simctl get_app_container … data，把 eval/dataset.json 放成 Documents/memory-eval.json
enum LocalMemorySelfTest {
    static func run() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        guard let data = try? Data(contentsOf: docs.appendingPathComponent("memory-eval.json")),
              let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let mems = d["memories"] as? [[String: Any]] else {
            NSLog("[memory-selftest] FAILED: Documents/memory-eval.json 不在（simctl 拷一份 mele-memory/eval/dataset.json）")
            return
        }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("memtest-\(Int(Date().timeIntervalSince1970))")
        let store = LocalStore(root: tmp)
        // 称呼跟评测一样进停用词：小满（用户）、Lumi / 露露（TA）
        let names = d["names"] as? [String: Any] ?? [:]
        store.write("profile.json", ["name": names["user"] as? String ?? "小满"])
        store.write("companions.json", [[
            "id": "t", "persona": ["name": names["ai"] as? String ?? "Lumi",
                                   "call_user": (names["nicknames"] as? [String])?.first ?? "露露"],
            "settings": [String: Any](),
        ]])
        let lib = LocalMemory(store: store)
        var ids: [String: Int] = [:]
        for m in mems {
            guard let key = m["id"] as? String, let content = m["content"] as? String,
                  let mid = lib.importItem(["content": content, "importance": m["importance"] as? Int ?? 5]) else { continue }
            ids[key] = mid
        }
        let byID = Dictionary(uniqueKeysWithValues: ids.map { ($0.value, $0.key) })
        var hit = 0, rel = 0
        let qs = (d["queries"] as? [[String: Any]] ?? []) + (d["name_queries"] as? [[String: Any]] ?? [])
        for q in qs {
            guard let text = q["q"] as? String else { continue }
            let expect = Set(q["expect"] as? [String] ?? [])
            let top = lib.debugRank(text).first
            let topKey = top.flatMap { byID[$0.id] } ?? "-"
            if !expect.isEmpty {
                rel += 1
                if expect.contains(topKey) { hit += 1 }
            }
            NSLog("[memory-selftest] %@ → %@ %.2f %@", String(text.prefix(16)), topKey, top?.score ?? 0,
                  expect.isEmpty ? "-" : (expect.contains(topKey) ? "✓" : "✗ 想要 \(expect.sorted())"))
        }
        // 闲聊不该浮
        var quiet = true
        for s in ["哈哈哈好的", "嗯嗯", "ok thanks"] {
            let r = lib.recall(text: s)
            if r.text != "Nothing surfaced." { quiet = false; NSLog("[memory-selftest] 闲聊浮了: %@ → %@", s, r.text) }
        }
        NSLog("[memory-selftest] top1 hit %d/%d（Mac 上量的是 12/16）, 进库 %d 条（带向量 %d）, 闲聊安静=%@",
              hit, rel, ids.count, lib.debugVectorCount, quiet ? "✓" : "✗")
        try? FileManager.default.removeItem(at: tmp)
    }
}
#endif

// MARK: - 向量（苹果自带的 NLContextualEmbedding：按语言选模型，token 向量求平均再归一化）

private final class Embedder: @unchecked Sendable {
    private var models: [String: NLContextualEmbedding] = [:]
    private var requested: Set<String> = []
    private let lock = NSLock()

    func lang(of text: String) -> String {
        if text.unicodeScalars.contains(where: { (0x4E00...0x9FFF).contains($0.value) }) { return "zh" }
        let r = NLLanguageRecognizer()
        r.processString(String(text.prefix(200)))
        return r.dominantLanguage == .simplifiedChinese || r.dominantLanguage == .traditionalChinese ? "zh" : "en"
    }

    /// 模型资产还没下好：回 nil（这次先只用关键词），顺手请求下载，下次就有了
    func vector(_ text: String, lang: String) -> [Double]? {
        lock.withLock {
            let nl: NLLanguage = lang == "zh" ? .simplifiedChinese : .english
            let model: NLContextualEmbedding
            if let m = models[lang] { model = m } else {
                guard let m = NLContextualEmbedding(language: nl) else { return nil }
                models[lang] = m
                model = m
            }
            // 资产没下好、或下好了还没编译（Code 7 requires compilation）都走这条：请求一次，这回先只用关键词，
            // 编译好之后 recall 的补向量（backfillVectors）会慢慢追上
            guard model.hasAvailableAssets, (try? model.load()) != nil else {
                if requested.insert(lang).inserted {
                    NSLog("[local-memory] \(lang) 向量模型还没就绪，先只用关键词，顺手请求准备")
                    model.requestAssets { result, _ in NSLog("[local-memory] \(lang) 资产请求结果: \(result.rawValue)") }
                }
                return nil
            }
            let body = String(text.prefix(400))
            guard let r = try? model.embeddingResult(for: body, language: nl) else { return nil }
            var sum = [Double](repeating: 0, count: model.dimension)
            var n = 0.0
            r.enumerateTokenVectors(in: body.startIndex..<body.endIndex) { v, _ in
                for i in 0..<min(v.count, sum.count) { sum[i] += v[i] }
                n += 1
                return true
            }
            guard n > 0 else { return nil }
            let m = sum.map { $0 / n }
            let norm = sqrt(m.map { $0 * $0 }.reduce(0, +))
            guard norm > 0 else { return nil }
            return m.map { $0 / norm }
        }
    }
}
#endif

#if LITE
/// 合并自测（10-12，-dedupeSelfTest）：粗筛能不能把换了说法的旧记忆捞进候选、mergeInto 能不能并进去
enum LocalDedupeSelfTest {
    static func run() {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("dedupe-\(Int(Date().timeIntervalSince1970))")
        let store = LocalStore(root: tmp)
        store.write("profile.json", ["name": "小满"])
        store.write("companions.json", [["id": "t", "persona": ["name": "Lumi"], "settings": [String: Any]()]])
        let lib = LocalMemory(store: store)
        var fails: [String] = []
        let seed = ["小满下周三有数学考试，她有点紧张", "小满喜欢喝冰美式，不加糖", "小满的猫叫豆豆，是一只橘猫", "小满今天和妈妈吵架了，心情很差"]
        var ids: [Int] = []
        for s in seed {
            let r = lib.remember(content: s)
            if let m = r.structured?["memory"] as? [String: Any], let id = m["id"] as? Int { ids.append(id) }
        }
        let same = ["小满有点紧张，因为下周三要考数学", "小满爱喝不加糖的冰美式", "豆豆是小满养的橘猫", "小满跟妈妈吵了一架，今天心情不好"]
        for (i, s) in same.enumerated() {
            let c = lib.dedupeCandidates(for: s).map(\.id)
            if !c.contains(ids[i]) { fails.append("候选里没捞到 #\(ids[i])：\(s) → \(c)") }
        }
        let before = lib.all.count
        let r = lib.remember(content: same[0], mergeInto: ids[0])
        if (r.structured?["merged"] as? Bool) != true || lib.all.count != before { fails.append("mergeInto 没并进去") }
        if lib.find(ids[0])?.content != same[0] { fails.append("并进去以后说法没换成新的") }
        let r2 = lib.remember(content: "小满下周三有英语考试")
        if (r2.structured?["merged"] as? Bool) == true { fails.append("不同的事被字面并了") }
        let r3 = lib.remember(content: "随便", mergeInto: 99_999)
        if (r3.structured?["merged"] as? Bool) == true { fails.append("不存在的编号也并了") }
        NSLog(fails.isEmpty ? "[dedupe-selftest] PASS" : "[dedupe-selftest] FAILED: \(fails.joined(separator: "；"))")
        try? FileManager.default.removeItem(at: tmp)
    }
}
#endif
