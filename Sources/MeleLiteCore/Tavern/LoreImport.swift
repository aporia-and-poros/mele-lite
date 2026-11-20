import Foundation

/// 世界书导入（10-11 内测反馈）：酒馆的世界书 JSON、角色卡里的 character_book、或者一份 txt。
/// 都先摊成同一个样子，再走 CardParser.loreEntries（关键词去重、太短的不要、内容截 2000 字），规则跟导卡一样。
///
/// txt 的写法：一段一条（空行隔开；有 `---` 分隔线就按分隔线）。第一行是标题，
/// 可以有一行「关键词：a、b、c」；没写关键词就用标题当关键词。只有一行的写成「标题：内容」也认。
public enum LoreImport {
    static let maxBytes = 5 * 1024 * 1024
    static let maxEntries = 500

    public static func parse(_ data: Data, fileName: String, charName: String, userName: String,
                             lang: Lang) throws -> (entries: [LoreEntry], skipped: Int) {
        let zh = lang == .zh
        guard data.count <= maxBytes else { throw CardError(message: zh ? "文件太大了（最多 5MB）" : "File too large (5MB max)") }
        let raw: [[String: Any]]
        if let obj = try? JSONSerialization.jsonObject(with: data) {
            raw = jsonEntries(obj)
        } else if let text = decodeText(data) {
            raw = textEntries(text)
        } else {
            throw CardError(message: zh ? "只认世界书 JSON 或 txt" : "Only lorebook JSON or .txt")
        }
        guard !raw.isEmpty else { throw CardError(message: zh ? "这个文件里没读到词条" : "No entries found in this file") }
        let user = userName.isEmpty ? (zh ? "你" : "you") : userName
        var (out, skipped) = CardParser.loreEntries(raw, name: charName, user: user)
        if out.count > maxEntries { skipped += out.count - maxEntries; out = Array(out.prefix(maxEntries)) }
        return (out, skipped)
    }

    /// txt 先看开头的 BOM（10-14 内测：Windows 记事本存成「Unicode」= UTF-16 LE，一个字都读不出），
    /// 没 BOM 再按 UTF-8 读，不行再按 GB18030（中文 Windows 存的 txt 常是 GBK）
    public static func decodeText(_ data: Data) -> String? {
        let b = [UInt8](data.prefix(4))
        if b.starts(with: [0xFF, 0xFE, 0x00, 0x00]) { return String(data: data, encoding: .utf32LittleEndian).map(dropBOM) }
        if b.starts(with: [0x00, 0x00, 0xFE, 0xFF]) { return String(data: data, encoding: .utf32BigEndian).map(dropBOM) }
        if b.starts(with: [0xFF, 0xFE]) { return String(data: data.dropFirst(2), encoding: .utf16LittleEndian) }
        if b.starts(with: [0xFE, 0xFF]) { return String(data: data.dropFirst(2), encoding: .utf16BigEndian) }
        // 没 BOM 的 UTF-16：英文 / 符号那半边全是 0 字节；单数位多是 0 → LE，双数位多是 0 → BE
        // （先判这个：0 字节在 UTF-8 里也算合法，纯英文的 UTF-16 会被当成 UTF-8 读通、满屏空字符）
        let bytes = [UInt8](data.prefix(4096))
        let zeroOdd = stride(from: 1, to: bytes.count, by: 2).filter { bytes[$0] == 0 }.count
        let zeroEven = stride(from: 0, to: bytes.count, by: 2).filter { bytes[$0] == 0 }.count
        if bytes.count >= 4, max(zeroOdd, zeroEven) * 4 >= bytes.count / 2,
           let s = String(data: data, encoding: zeroOdd >= zeroEven ? .utf16LittleEndian : .utf16BigEndian) { return s }
        if let s = String(data: data, encoding: .utf8) { return dropBOM(s) }
        // 10-16 内测：百度网盘下的小说 txt 读不进书架——UTF-8 里混了几个坏字节（下载截断 / 拼接），整本被拒，
        // 再按 GBK 读就是满屏乱码。坏的极少（百分之一以内；一个坏字节会拆出好几个 �）就当 UTF-8，坏字节换成 �
        let loose = String(decoding: data, as: UTF8.self)
        let bad = loose.unicodeScalars.lazy.filter { $0 == "\u{FFFD}" }.count
        if bad * 100 <= loose.count { return dropBOM(loose) }
        let gb = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        if let s = String(data: data, encoding: String.Encoding(rawValue: gb)) { return s }
        let big5 = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.big5_HKSCS_1999.rawValue))
        return String(data: data, encoding: String.Encoding(rawValue: big5))
    }

    static func dropBOM(_ s: String) -> String { s.hasPrefix("\u{FEFF}") ? String(s.dropFirst()) : s }

    // MARK: 整份导入（11-19 内测：一份完整设定不想被拆成词条，拆完每段都没关键词 → 读到 0 条）

    /// 整份当「一直记着的」：一条最多 2000 字，长的按段落切成几块（一段本身太长就硬切），
    /// 标题「文件名 1/3」，关键词用文件名（存的时候至少要一个）
    public static func whole(_ text: String, fileName: String, charName: String, userName: String,
                             lang: Lang) -> [LoreEntry] {
        let zh = lang == .zh
        let user = userName.isEmpty ? (zh ? "你" : "you") : userName
        let body = CardParser.fill(dropBOM(text).replacingOccurrences(of: "\r\n", with: "\n"), char: charName, user: user)
        guard !body.isEmpty else { return [] }
        let chunks = split(body, max: 2000)
        var base = cleanTitle((fileName as NSString).deletingPathExtension)
        if base.isEmpty { base = zh ? "设定" : "Setting" }
        base = String(base.prefix(32))
        let key = CardParser.keywordOK(base) ? base : (zh ? "设定" : "Setting")
        return chunks.enumerated().map { i, c in
            LoreEntry(title: chunks.count == 1 ? base : "\(base) \(i + 1)/\(chunks.count)", keys: [key], content: c, constant: true)
        }
    }

    /// 按行攒，攒满 max 就切；切口尽量落在空行（段落）上
    static func split(_ text: String, max: Int) -> [String] {
        var out: [String] = [], cur = ""
        func flush() {
            let t = cur.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { out.append(t) }
            cur = ""
        }
        for var line in text.components(separatedBy: "\n") {
            while line.count > max {                             // 一行就超了：硬切
                flush()
                out.append(String(line.prefix(max)))
                line = String(line.dropFirst(max))
            }
            if cur.count + line.count + 1 > max {
                // 先退回到这一块里最后一个空行，后半截带进下一块，免得把一段从中间切开
                if let r = cur.range(of: "\n\n", options: .backwards), cur.distance(from: cur.startIndex, to: r.lowerBound) > max / 2 {
                    let tail = String(cur[r.upperBound...])
                    cur = String(cur[..<r.lowerBound]); flush(); cur = tail
                }
                if cur.count + line.count + 1 > max { flush() }
            }
            cur += cur.isEmpty ? line : "\n" + line
        }
        flush()
        return out
    }

    // MARK: JSON

    /// 酒馆世界书 {entries: {"0": {...}}}、character_book {entries: [...]}、整张卡、或者直接一个数组
    static func jsonEntries(_ obj: Any) -> [[String: Any]] {
        if let list = obj as? [Any] { return list.compactMap { $0 as? [String: Any] }.map(normalize) }
        guard let d = obj as? [String: Any] else { return [] }
        if let book = ((d["data"] as? [String: Any])?["character_book"] ?? d["character_book"]) as? [String: Any] {
            return jsonEntries(book)
        }
        if let list = d["entries"] as? [Any] { return list.compactMap { $0 as? [String: Any] }.map(normalize) }
        if let dict = d["entries"] as? [String: Any] {
            let sorted = dict.sorted { (Int($0.key) ?? .max, $0.key) < (Int($1.key) ?? .max, $1.key) }
            return sorted.compactMap { $0.value as? [String: Any] }.map(normalize)
        }
        return []
    }

    /// 酒馆世界书的字段名（key / keysecondary / disable）→ 卡里的写法（keys / secondary_keys / enabled）
    static func normalize(_ e: [String: Any]) -> [String: Any] {
        var o = e
        if o["keys"] == nil { o["keys"] = e["key"] }
        if o["secondary_keys"] == nil { o["secondary_keys"] = e["keysecondary"] }
        if o["enabled"] == nil, let off = e["disable"] as? Bool { o["enabled"] = !off }
        return o
    }

    // MARK: txt

    static let rule = try! NSRegularExpression(pattern: #"^\s*(-{3,}|={3,}|\*{3,})\s*$"#)
    static let keysLine = try! NSRegularExpression(pattern: #"^\s*(关键词|关键字|触发词|keywords?|keys?)\s*[:：]\s*(.*)$"#,
                                                   options: .caseInsensitive)

    static func textEntries(_ text: String) -> [[String: Any]] {
        let lines = text.replacingOccurrences(of: "\u{FEFF}", with: "").replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
        if let list = numberedEntries(lines) { return list }
        let ruled = lines.contains { matches(rule, $0) }
        var blocks: [[String]] = [], cur: [String] = []
        for l in lines {
            let cut = ruled ? matches(rule, l) : l.trimmingCharacters(in: .whitespaces).isEmpty
            if cut { if !cur.isEmpty { blocks.append(cur) }; cur = [] } else { cur.append(l) }
        }
        if !cur.isEmpty { blocks.append(cur) }
        return blocks.compactMap(block)
    }

    // MARK: 编号清单（10-14 内测：一份梗清单 txt，一百多个梗一行一个编号，前面还有两小段 1. 2. 3. 的用法规则）

    static let numberedLine = try! NSRegularExpression(pattern: #"^\s*(\d{1,3})\s*[.、．)）]\s*(.*)$"#)
    static let invisible = CharacterSet(charactersIn: "\u{200B}\u{200C}\u{200D}\u{FEFF}")

    /// 一个编号一条，下面没编号的几行接在它后面（# 标题 / <标签> 收住）。编号从头数起算新的一组；
    /// 有 ≥ 10 条的组就只要这些组——前面那几组「1. 2. 3.」多半是写给模型的用法规则，不是词条。编号行不到 5 行就不按清单读
    static func numberedEntries(_ lines: [String]) -> [[String: Any]]? {
        var runs: [[(head: String, body: [String])]] = [], run: [(head: String, body: [String])] = []
        var last = 0, open = false
        for l in lines {
            let t = l.trimmingCharacters(in: .whitespaces.union(invisible))
            if let m = numberedLine.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)),
               let nr = Range(m.range(at: 1), in: t), let n = Int(t[nr]), let hr = Range(m.range(at: 2), in: t) {
                if n <= last, !run.isEmpty { runs.append(run); run = [] }
                run.append((String(t[hr]).trimmingCharacters(in: .whitespaces.union(invisible)), []))
                last = n; open = true
            } else if t.hasPrefix("#") || t.hasPrefix("<") {
                open = false
            } else if open, !t.isEmpty, !run.isEmpty {
                run[run.count - 1].body.append(t)
            }
        }
        if !run.isEmpty { runs.append(run) }
        guard runs.reduce(0, { $0 + $1.count }) >= 5 else { return nil }
        let big = runs.filter { $0.count >= 10 }
        return (big.isEmpty ? runs : big).flatMap { $0 }.map { listItem($0.head, $0.body) }
    }

    /// 标题 = 冒号前（30 字内）或整行；内容 = 整条原文（梗的意思就在整条里）；关键词从标题里拆
    static func listItem(_ head: String, _ body: [String]) -> [String: Any] {
        var name = head
        if let i = head.firstIndex(where: { $0 == "：" || $0 == ":" }), head.distance(from: head.startIndex, to: i) <= 30,
           head.distance(from: head.startIndex, to: i) > 0 {
            name = String(head[..<i])
        }
        let content = ([head] + body).joined(separator: "\n")
        return ["keys": listKeys(name), "content": content, "comment": cleanTitle(String(name.prefix(20)))]
    }

    static let keySegments = try! NSRegularExpression(pattern: #"[/／→=＝，,、;；|\s]+|说成"#)
    static let keyHoles = try! NSRegularExpression(pattern: #"\*+|[xX]{2,}|…+|\.{3,}|[？?！!。]"#)
    static let keyParens = try! NSRegularExpression(pattern: #"[（(][^）)]*[）)]"#)
    /// 太常见的词当关键词会句句都触发
    static let commonWords: Set<String> = ["比如", "例如", "示例", "怎么", "什么", "没有", "知道", "可以", "我们", "你们", "他们",
                                           "这个", "那个", "就是", "不是", "一个", "自己", "真的", "现在", "这期", "我的", "你的", "你看"]

    /// 「这期神了/没绷住/破绷」「不按常理出牌→倒反天罡」「牛逼说成牛福」「你见过人**不」→ 拆成能在聊天里碰到的几截；
    /// 括号里的说明、引号不算。带 ** / xx 占位的那截是句式，拆出来的碎片至少 3 个字（不然「那很」「我在」句句都触发）
    static func listKeys(_ name: String) -> [String] {
        var s = name.trimmingCharacters(in: invisible)
        s = keyParens.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: " ")
        s = s.filter { !"“”\"「」『』‘’'【】《》".contains($0) }
        s = keySegments.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "\u{1}")
        var seen = Set<String>(), out: [String] = []
        for seg in s.split(separator: "\u{1}").map(String.init) {
            let holed = keyHoles.stringByReplacingMatches(in: seg, range: NSRange(seg.startIndex..., in: seg), withTemplate: "\u{1}")
            let minLen = holed == seg ? 2 : 3
            for k in holed.split(separator: "\u{1}").map({ $0.trimmingCharacters(in: .whitespaces.union(invisible)) })
            where k.count >= minLen && k.count <= 20 && !commonWords.contains(k) && !k.allSatisfy(\.isNumber)
                && seen.insert(k.lowercased()).inserted {
                out.append(k)
            }
        }
        return Array(out.prefix(6))
    }

    static func block(_ ls: [String]) -> [String: Any]? {
        var rest = ls.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !rest.isEmpty else { return nil }
        var keys: [String] = []
        rest = rest.filter { l in
            guard let m = keysLine.firstMatch(in: l, range: NSRange(l.startIndex..., in: l)),
                  let r = Range(m.range(at: 2), in: l) else { return true }
            keys += l[r].split(whereSeparator: { ",，、;；|/".contains($0) }).map { $0.trimmingCharacters(in: .whitespaces) }
            return false
        }
        guard let first = rest.first else { return nil }
        var title = cleanTitle(first)
        var content = rest.dropFirst().joined(separator: "\n")
        if content.isEmpty {                                  // 只有一行：「标题：内容」
            if let i = first.firstIndex(where: { $0 == "：" || $0 == ":" }), first.distance(from: first.startIndex, to: i) <= 20 {
                title = cleanTitle(String(first[..<i]))
                content = String(first[first.index(after: i)...]).trimmingCharacters(in: .whitespaces)
            } else {
                content = first
                title = ""
            }
        }
        if keys.isEmpty, !title.isEmpty, title.count <= 20 { keys = [title] }
        return ["keys": keys.filter { !$0.isEmpty }, "content": content, "comment": title]
    }

    static func cleanTitle(_ s: String) -> String {
        s.trimmingCharacters(in: CharacterSet(charactersIn: "#【】[]「」《》*：: ").union(.whitespaces))
    }

    static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }
}
