import Foundation

/// 给模型看的表情包表（10-31）：它写 `[表情包：#12]` 就发那一张，不走工具。
///
/// - 库小（≤ fullUpTo 张）：系统提示里整张表，每张完整描述。
/// - 库大：系统提示里一张短目录（每张一个短名，知道库里有什么）；每一轮再按刚聊的话挑最搭的几张，
///   带完整描述递过去（`picks` / `picksBlock`，放在每轮会变的那一段）。Aporia 10-31：只给半截描述，它会用得不贴。
/// - 编号：库里的 id 都是数字就用 id（换了顺序、删了别的也不变）；不是数字就按表里的顺序 1、2、3。
public struct StickerMenu: Sendable {
    public static let fullUpTo = 30
    public static let shortName = 12
    public static let pickLimit = 6

    public let stickers: [Sticker]
    let numbers: [String: Int]

    public init(_ stickers: [Sticker]) {
        let usable = stickers.filter { !$0.caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        self.stickers = usable
        let ints = usable.compactMap { Int($0.id) }
        if ints.count == usable.count, Set(ints).count == ints.count {
            numbers = Dictionary(uniqueKeysWithValues: usable.map { ($0.id, Int($0.id)!) })
        } else {
            numbers = Dictionary(uniqueKeysWithValues: usable.enumerated().map { ($1.id, $0 + 1) })
        }
    }

    public var isEmpty: Bool { stickers.isEmpty }
    public var isLarge: Bool { stickers.count > Self.fullUpTo }

    public func number(of s: Sticker) -> Int { numbers[s.id] ?? 0 }

    /// 它写的那一段（`#12`、`12`、旧写法的描述）→ 哪一张
    public func resolve(_ wanted: String) -> Sticker? {
        let w = wanted.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = w.replacingOccurrences(of: #"^[#＃№]?\s*(\d+)\b.*$"#, with: "$1", options: .regularExpression)
        if let n = Int(digits), let hit = stickers.first(where: { number(of: $0) == n }) { return hit }
        let lw = w.lowercased()
        guard !lw.isEmpty else { return nil }
        if let exact = stickers.first(where: { $0.caption.lowercased() == lw }) { return exact }
        let near = stickers.filter { let c = $0.caption.lowercased(); return c.contains(lw) || lw.contains(c) }
        if let best = near.max(by: { min($0.caption.count, lw.count) < min($1.caption.count, lw.count) }) { return best }
        // 抄错几个字：按字面最像的那张，像到一半以上才算
        let scored = stickers.map { ($0, Self.overlap(lw, $0.caption.lowercased())) }.max { $0.1 < $1.1 }
        return scored.flatMap { $0.1 >= 0.5 ? $0.0 : nil }
    }

    /// 系统提示里那一节
    public func block(zh: Bool) -> String {
        guard !isEmpty else { return "" }
        let head = zh ? "## 你的表情包\n" : "## Your stickers\n"
        if !isLarge {
            return head + stickers.map { "#\(number(of: $0)) \(Self.oneLine($0.caption))" }.joined(separator: "\n")
        }
        let note = zh ? "（目录只写了短名；每一轮会递几张跟此刻最搭的完整描述，在〔可以发的表情包〕里）\n"
                      : "(Short names only; each turn the ones that fit the moment come with full descriptions in [Stickers that fit].)\n"
        return head + note + stickers.map { "#\(number(of: $0)) \(Self.short($0.caption))" }.joined(separator: "\n")
    }

    /// 这一轮最搭的几张：字面重合（中文两个字一组算一分、单个字算 0.35 分；英文按词）+ 外面算好的相关度
    /// （Lite 有手机自带的向量，传进来的是已经压成 0～1 的加分，不是原始余弦）
    public func picks(for texts: [String], similarity: [String: Double] = [:], limit: Int = pickLimit) -> [Sticker] {
        guard isLarge else { return [] }
        let q = Self.grams(texts.joined(separator: "\n").lowercased())
        let scored: [(Sticker, Double)] = stickers.map { s in
            let g = Self.grams(s.caption.lowercased())
            let kw = Double(g.pairs.intersection(q.pairs).count) + 0.35 * Double(g.chars.intersection(q.chars).count)
            return (s, kw + max(0, similarity[s.id] ?? 0))
        }
        return scored.filter { $0.1 >= 0.35 }.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    /// 每轮那一段
    public func picksBlock(_ picks: [Sticker], zh: Bool) -> String {
        guard !picks.isEmpty else { return "" }
        let head = zh ? "〔可以发的表情包〕跟此刻最搭的几张（想发就写 [表情包：#编号]，不想发就不发）：\n"
                      : "[Stickers that fit] The ones closest to this moment (write [sticker: #number] to send one):\n"
        return head + picks.map { "#\(number(of: $0)) \(Self.oneLine($0.caption))" }.joined(separator: "\n")
    }

    static func oneLine(_ s: String) -> String {
        s.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    /// 短名：第一个逗号 / 句号前面那截，最多 shortName 个字
    static func short(_ caption: String) -> String {
        let line = oneLine(caption)
        let head = line.split(whereSeparator: { "，。,.;；!！?？".contains($0) }).first.map(String.init) ?? line
        return head.count > shortName ? String(head.prefix(shortName)) + "…" : head
    }

    static let stop: Set<Character> = Set("的了是我你他她它在有不这那就也都和吗呢吧啊呀哦嗯个一着把被给很太又还说好想看要会能去来到么什")

    /// 中文：单个字（跳过虚字）+ 相邻两个字一组；英文：三个字母以上的词（算进两边）
    static func grams(_ s: String) -> (chars: Set<String>, pairs: Set<String>) {
        var chars = Set<String>(), pairs = Set<String>()
        var han: [Character] = []
        func flush() {
            for c in han where !stop.contains(c) { chars.insert(String(c)) }
            for i in han.indices.dropLast() where !(stop.contains(han[i]) && stop.contains(han[i + 1])) {
                pairs.insert(String(han[i...i + 1]))
            }
            han = []
        }
        var word = ""
        func word0() { if word.count >= 3 { pairs.insert(word) }; word = "" }
        for ch in s {
            if ch.unicodeScalars.allSatisfy({ (0x4E00...0x9FFF).contains($0.value) }) {
                word0(); han.append(ch)
            } else {
                flush()
                if ch.isLetter { word.append(ch) } else { word0() }
            }
        }
        flush(); word0()
        return (chars, pairs)
    }

    static func overlap(_ a: String, _ b: String) -> Double {
        let ga = grams(a).pairs, gb = grams(b).pairs
        guard !ga.isEmpty, !gb.isEmpty else { return 0 }
        return Double(ga.intersection(gb).count) / Double(min(ga.count, gb.count))
    }
}
