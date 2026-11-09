import Foundation

/// 重复（10-13 内测：一上午每句都是「汤」、后来每句都是「等天黑去河边」，关了线下生活还这样）。
/// 真因在账本的腔调样本：卷上下文时原来直接取被卷掉的最后 6 句原话，每轮放进 system 写着「照这个接着说」，
/// DeepSeek 不是学腔调，是把那几句抄回来；而最后 6 句恰恰是重复得最凶的那几句——一直抄到下次卷（又 3 万 token）。
/// 这里两件事：① 挑样本时去掉长得像的、从头到尾散着挑；② 回话里跟它最近说过的几乎一样的气泡，丢掉。
public enum Repeats {
    /// 两句话像不像：中文一个字一个词、英文一个单词一个词，去掉标点；重叠占短的那句的比例（换了说法的同一句也抓得到）
    public static func similarity(_ a: String, _ b: String) -> Double {
        let x = tokens(a), y = tokens(b)
        if x.isEmpty || y.isEmpty { return a == b ? 1 : 0 }
        return Double(x.intersection(y).count) / Double(min(x.count, y.count))
    }

    static func tokens(_ s: String) -> Set<String> {
        var out = Set<String>(), word = ""
        func flush() { if !word.isEmpty { out.insert(word); word = "" } }
        for ch in s.lowercased() {
            if ch.isLetter || ch.isNumber {
                if ch.isASCII { word.append(ch) } else { flush(); out.insert(String(ch)) }
            } else { flush() }
        }
        flush()
        return out
    }

    /// 腔调样本：从被卷掉的它自己的话里挑 max 句——太短的不要，长得像的（≥ 0.6）只留一句，从头到尾散着取而不是只取最后几句
    public static func pickSamples(_ lines: [String], max: Int = 6, minChars: Int = 8) -> [String] {
        var distinct: [String] = []
        for l in lines.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where l.count >= minChars {
            if !distinct.contains(where: { similarity($0, l) >= 0.6 }) { distinct.append(l) }
        }
        guard distinct.count > max, max > 0 else { return distinct }
        // 均匀散开：第 i 句取 distinct[round(i * (n-1) / (max-1))]
        let n = distinct.count
        return (0..<max).map { distinct[Int((Double($0) * Double(n - 1) / Double(max - 1)).rounded())] }
    }

    /// 回话里的气泡跟它最近说过的几乎一样（≥ threshold）就丢；全丢光了留第一句（总得回点什么）
    public static func dropRepeated(_ bubbles: [String], recent: [String], threshold: Double = 0.75) -> [String] {
        // 语音条不丢（11-09：短语音跟不相干的长话也算像，被悄悄吞掉）
        let kept = bubbles.filter { b in b.hasPrefix(Bubbles.voice) || !recent.contains { similarity($0, b) >= threshold } }
        return kept.isEmpty ? Array(bubbles.prefix(1)) : kept
    }

    /// 同一条回话里自己跟自己重复（10-14 内测）：它先把话说完、顺手调个工具（比如 go_to），工具回来又换几个字说一遍，
    /// 两段拼在一起发出去。后面的气泡跟这条回话里前面已经留下的几乎一样（≥ threshold）就丢，第一次说的留着
    public static func dropEchoes(_ bubbles: [String], threshold: Double = 0.75) -> [String] {
        var kept: [String] = []
        for b in bubbles where b.hasPrefix(Bubbles.voice) || !kept.contains(where: { similarity($0, b) >= threshold }) { kept.append(b) }
        return kept
    }
}
