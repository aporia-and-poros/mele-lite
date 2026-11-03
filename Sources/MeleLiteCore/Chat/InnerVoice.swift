import Foundation

/// 回复后的心声（10-11 内测反馈）：TA 说完话以后，最后写一段 [心声]…[/心声]，App 画成这一轮最后一张小卡片。
/// 独白是开口前想事；心声是说完以后心里真实的反应，好玩在嘴上说的和心里想的对不上。服务器 brain/inner_voice.py 同一份意思。
public enum InnerVoice {
    static let word = #"(?:心声|心聲|inner\s*voice)"#          // 括号跟独白一样认【】<>［］（10-15）
    static let open = try! NSRegularExpression(pattern: Monologue.L + #"\s*"# + word + #"\s*"# + Monologue.R, options: .caseInsensitive)
    static let close = try! NSRegularExpression(
        pattern: Monologue.L + #"\s*(?:/\s*"# + word + "|" + word + #"\s*(?:/|完|结束|結束|end))\s*"# + Monologue.R, options: .caseInsensitive)

    static func has(_ text: String) -> Bool {
        open.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }

    /// 老写法（10-12 前历史里是「（当时心里：…）」，模型会照着学、不写标签）：从这儿到结尾都算心声
    static let oldShape = try! NSRegularExpression(pattern: #"[（(]\s*(?:当时心里|what i felt then)\s*[:：]"#, options: .caseInsensitive)

    /// 切出心声：好几段只留最后一段，每段都从正文里删掉；没收尾 = 到结尾
    public static func split(_ text: String) -> (body: String, voice: String) {
        var rest = text, voice = ""
        let all = NSRange(location: 0, length: (text as NSString).length)
        if open.firstMatch(in: text, range: all) == nil, let m = oldShape.firstMatch(in: text, range: all) {
            let ns = text as NSString
            var v = ns.substring(from: m.range.upperBound).trimmingCharacters(in: .whitespacesAndNewlines)
            if v.hasSuffix("）") || v.hasSuffix(")") { v.removeLast() }
            return (ns.substring(to: m.range.location).trimmingCharacters(in: .whitespacesAndNewlines),
                    v.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        while true {
            let ns = rest as NSString
            guard let o = open.firstMatch(in: rest, range: NSRange(location: 0, length: ns.length)) else { break }
            let after = o.range.location + o.range.length
            let c = close.firstMatch(in: rest, range: NSRange(location: after, length: ns.length - after))
            let end = c.map { $0.range.location } ?? ns.length
            voice = ns.substring(with: NSRange(location: after, length: end - after)).trimmingCharacters(in: .whitespacesAndNewlines)
            let cut = c.map { $0.range.location + $0.range.length } ?? ns.length
            rest = ns.replacingCharacters(in: NSRange(location: o.range.location, length: cut - o.range.location), with: "")
        }
        // 落单的收尾（开头被别的切法拿走了，11-03 内测截图气泡里只剩 [/心声]）：只删标记
        rest = close.stringByReplacingMatches(in: rest, range: NSRange(location: 0, length: (rest as NSString).length), withTemplate: "")
        return (rest.trimmingCharacters(in: .whitespacesAndNewlines), voice)
    }

    public static func factoryStyle(zh: Bool, pronoun p: String) -> String {
        zh ? "说完以后，心里真实的反应：诚实、直白、不修饰。嘴上没说的那部分写出来——口是心非的、没好意思说的、忍住的、偷偷高兴的。几行就够。用「我」，\(p)一直是「\(p)」，不写「你」。"
           : "What I really feel right after saying it: honest, blunt, unpolished. Write the part I didn't say out loud — what I meant instead, what I held back, what I'm secretly pleased about. A few lines is enough. First person; \(p) stays \"\(p)\", never \"you\"."
    }

    /// 放在独白规矩后面（system 里）；用户写了风格就整段换掉出厂写法，格式那几句不换。
    /// bare = 本体化（11-03）：出厂写法和「只写这一轮」那句不放，只剩格式；用户写了写法就照放
    public static func rules(zh: Bool, pronoun: String, style: String, bare: Bool = false) -> String {
        let own = style.trimmingCharacters(in: .whitespacesAndNewlines)
        if bare {
            let mine = own.isEmpty ? "" : "\n\(own)\n"
            return zh
                ? "【心声】每次回复说完以后，最后面再写一段心声，放在 [心声] 和 [/心声] 之间。\(mine)心声不算说出口的话，正文里不提心声。写完用 [/心声] 收尾，后面不再写字。"
                : "[Inner voice] After every reply, at the very end, write an inner voice between [inner voice] and [/inner voice]. \(mine)It isn't something you said; the reply itself never mentions it. Close it with [/inner voice] and write nothing after."
        }
        let st = own.isEmpty ? factoryStyle(zh: zh, pronoun: pronoun) : own
        return zh
            ? "【心声】每次回复说完以后，最后面再写一段心声，放在 [心声] 和 [/心声] 之间：\n\(st)\n心声只写这一轮的反应，不接着前几轮的心声往下写；已经说开、改正了的事，不再翻出来纠结。\n心声只是给\(pronoun)看的心里话，不算说出口的话；正文里不提心声。写完用 [/心声] 收尾，后面不再写字。"
            : "[Inner voice] After every reply, at the very end, write an inner voice between [inner voice] and [/inner voice]:\n\(st)\nIt's only about this turn: don't carry on from earlier inner voices, and don't keep going back to something already cleared up or corrected.\nIt's what I feel, not something I said; the reply itself never mentions it. Close it with [/inner voice] and write nothing after."
    }

    /// 每轮压在尾巴上的一行
    public static func hook(zh: Bool, pronoun: String) -> String {
        zh ? "〔心声〕说完以后，最后写 [心声]…[/心声]，写完收尾。"
           : "〔Inner voice〕After the reply, end with [inner voice]…[/inner voice]."
    }

    /// 下一轮历史里接在那句后面（TA 记得自己当时心里想什么，但分得清那不是说出口的）。
    /// 10-12：以前写成「（当时心里：…）」，模型照着历史学，心声不写标签直接漏进正文——历史里就长成它该写的样子
    public static func contextLine(_ voice: String, zh: Bool) -> String {
        zh ? "[心声]\n\(voice)\n[/心声]" : "[inner voice]\n\(voice)\n[/inner voice]"
    }
}
