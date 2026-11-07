import Foundation

/// 分条发：模型写完整段以后切成几条气泡（照 Mele 服务器 brain/bubbles.py，我们自己的规则）。
/// 1. 按空行分段，它自己的排版一字不动。
/// 2. 超过 250 字的段，在句末切成 120 字左右的小条（线下不细切）。
/// 3. 只有标签、没有话的一条，并回上一条。
/// 4. 条数超过 cap 时按顺序合成 cap 份，让最长那份尽量短，只在条和条之间合，一个字都不丢。
public enum Bubbles {
    static let longPara = 250
    static let piece = 120
    static let ends: Set<Character> = Set("。！？!?…～~")
    static let closers: Set<Character> = Set("」』”’）)】")

    /// 按句末标点切句；连着的标点和跟在后面的引号括号算在同一句里。
    static func sentences(_ p: String) -> [String] {
        var out: [String] = []
        var buf = ""
        let chars = Array(p)
        for (i, ch) in chars.enumerated() {
            buf.append(ch)
            let nxt: Character? = i + 1 < chars.count ? chars[i + 1] : nil
            if let n = nxt, ends.contains(n) || closers.contains(n) { continue }
            let prev: Character? = buf.count >= 2 ? buf[buf.index(buf.endIndex, offsetBy: -2)] : nil
            if ends.contains(ch) || (closers.contains(ch) && prev.map { ends.contains($0) } == true) {
                out.append(buf); buf = ""
            } else if ch == ".", nxt == nil || nxt!.isWhitespace {
                out.append(buf); buf = ""
            }
        }
        if !buf.isEmpty { out.append(buf) }
        return out.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    static func join(_ a: String, _ b: String) -> String {
        guard let last = a.last else { return b }
        let asciiTail = last.isASCII && (last.isLetter || last.isNumber || ",.;:!?'\"".contains(last))
        return a + (asciiTail ? " " : "") + b
    }

    static func splitLong(_ p: String) -> [String] {
        var out: [String] = []
        var cur = ""
        for s in sentences(p) {
            if !cur.isEmpty && cur.count + s.count > piece {
                out.append(cur); cur = s
            } else {
                cur = join(cur, s)
            }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    /// 按顺序把 chunks 合成 cap 份，让最长那份尽量短。
    static func balance(_ chunks: [String], cap: Int?) -> [String] {
        guard let cap, chunks.count > cap else { return chunks }
        let n = chunks.count
        var pre = [0]
        for c in chunks { pre.append(pre.last! + c.count) }
        let inf = Int.max
        var best = Array(repeating: Array(repeating: inf, count: n + 1), count: cap + 1)
        var cut = Array(repeating: Array(repeating: 0, count: n + 1), count: cap + 1)
        best[0][0] = 0
        for k in 1...cap {
            for i in k...n {
                for j in (k - 1)..<i where best[k - 1][j] != inf {
                    let v = max(best[k - 1][j], pre[i] - pre[j])
                    if v < best[k][i] { best[k][i] = v; cut[k][i] = j }
                }
            }
        }
        var groups: [[String]] = []
        var i = n
        for k in stride(from: cap, through: 1, by: -1) {
            let j = cut[k][i]
            groups.append(Array(chunks[j..<i]))
            i = j
        }
        return groups.reversed().map { $0.joined(separator: "\n\n") }
    }

    static let tagOnly = try! NSRegularExpression(pattern: #"^\s*<(\w+)[^>]*>[^<]*</\1>\s*$"#)

    public static func split(_ text: String, cap: Int? = 6, offline: Bool = false) -> [String] {
        // 代码块里的空行不算分段（11-07，照服务器 bubbles.py）
        var paras: [String] = []
        for piece in text.split(separator: try! Regex(#"\n\s*\n"#), omittingEmptySubsequences: false).map(String.init) {
            if let last = paras.last, last.components(separatedBy: "```").count % 2 == 0 {
                paras[paras.count - 1] = last + "\n\n" + piece
            } else if !piece.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                paras.append(piece)
            }
        }
        paras = paras.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        var chunks: [String] = []
        for p in paras {
            // 代码、列表切开就乱了
            let keep = offline || p.count <= longPara || p.contains("```") || p.range(of: #"(?m)^\s*(?:[-*•]|\d+[.、]) "#, options: .regularExpression) != nil
            chunks.append(contentsOf: keep ? [p] : splitLong(p))
        }
        var merged: [String] = []
        for c in chunks {
            let r = NSRange(c.startIndex..., in: c)
            if !merged.isEmpty, tagOnly.firstMatch(in: c, range: r) != nil {
                merged[merged.count - 1] += " " + c.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                merged.append(c)
            }
        }
        return balance(merged, cap: cap)
    }

    /// 下一条推出去之前「正在输入」停多久：按字数算，有上限。
    public static func typingDelay(_ text: String) -> Double {
        min(2.5, 0.4 + 0.03 * Double(text.count))
    }
}
