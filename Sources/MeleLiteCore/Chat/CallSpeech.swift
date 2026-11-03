import Foundation

/// 打电话（10-31 Aporia）：TA 一边写一边念，这里管「写出来的字 → 一句一句能念的话」，和电话里才递的几张纸条。
/// - 一句一行：模型按电话说明一句一行写；有人一行写好几句，就在句号问号这类地方再切一刀（太短的跟下一句并着念）。
/// - 念之前洗掉动作描写（（笑）、*抱住你*）、[表情包：…]、⟪…⟫ 标记、音频标签、开头的 🎤 和列表符号；漏写的 [独白] 整段不念。
/// - 只在通话时塞的说明、你那句前面的〔电话〕、挂断时的纸条和「📞 通话时长 03:21」那一行。
public enum CallSpeech {

    // MARK: 纸条

    /// 你在电话里说的那句前面垫的
    public static func tag(zh: Bool) -> String { zh ? "〔电话〕" : "[On the phone]" }

    /// 只在通话时塞进这一轮的说明（不进人设，挂了就撤）
    public static func rules(zh: Bool, pronoun: String) -> String {
        zh ? """
            〔现在在打电话〕\(pronoun)在电话那头听你说话，你说的每个字都会被念出来。
            - 像真打电话那样说：一轮两三句短句，说完就停下等\(pronoun)接话。
            - 一句一行。
            - 只写说出口的话：不写动作、神态、括号里的描写，不发表情包，不用 Markdown 和列表。
            - 要用工具（查记忆、记东西）的时候，先说一句「等我查一下」这样的话，再去用。
            - 标〔电话〕的是\(pronoun)在电话里说的，是语音转成的字，偶尔有错字，照意思接。
            """ : """
            [You're on a phone call] \(pronoun.prefix(1).uppercased() + pronoun.dropFirst()) is listening on the other end; every word you write is spoken aloud.
            - Talk like a real phone call: two or three short sentences per turn, then stop and let them answer.
            - One sentence per line.
            - Only words said out loud: no actions, expressions or bracketed descriptions, no stickers, no Markdown or lists.
            - If you need a tool (looking something up, saving a note), first say something like "hang on, let me check", then use it.
            - Lines marked [On the phone] are what they said on the call, transcribed from speech — the odd word may be off; go by the meaning.
            """
    }

    /// 它念到一半被你打断的那条，回看历史时接在后面（光一个「——」它常看不出来）
    public static func cutNote(zh: Bool) -> String {
        zh ? "〔说到这里被打断了，后面的没说出口〕" : "[Cut off here — the rest went unsaid]"
    }

    /// 挂断后递给 TA 的纸条（存进聊天记录，它下一轮看得到；屏幕上只画「📞 通话时长」那一行）
    public static func hangUpNote(seconds: Int, zh: Bool) -> String {
        let m = seconds / 60, s = seconds % 60
        if zh {
            let long = m > 0 ? "\(m) 分 \(s) 秒" : "\(s) 秒"
            return "〔电话挂了，这通打了 \(long)。接下来回到打字聊天。〕"
        }
        let long = m > 0 ? "\(m) min \(s) s" : "\(s) s"
        return "[The call ended after \(long). Back to texting from here.]"
    }

    // MARK: TA 打过来（第 4 步）

    /// TA 打来的这通怎么没接通：响了 60 秒没接 / 你按了拒绝 / TA 自己撤回了
    public enum Ring: String, Sendable, CaseIterable {
        case missed, declined, withdrawn
    }

    /// 递给 TA 的纸条（存进聊天记录，它下一轮看得到）
    public static func ringNote(_ r: Ring, zh: Bool, pronoun: String) -> String {
        switch r {
        case .missed:
            return zh ? "〔你给\(pronoun)打了电话，响了一分钟\(pronoun)没接。〕"
                      : "[You called them; it rang for a minute and they didn't pick up.]"
        case .declined:
            return zh ? "〔你给\(pronoun)打了电话，\(pronoun)按了拒绝，没接。〕"
                      : "[You called them; they declined the call.]"
        case .withdrawn:
            return zh ? "〔你给\(pronoun)打了电话，还没接通你就挂了。〕"
                      : "[You called them, then hung up before they answered.]"
        }
    }

    /// 屏幕上那一行（照微信）
    public static func ringLine(_ r: Ring, zh: Bool) -> String {
        switch r {
        case .missed: zh ? "📞 未接来电" : "📞 Missed call"
        case .declined: zh ? "📞 已拒绝" : "📞 Declined"
        case .withdrawn: zh ? "📞 对方已取消" : "📞 Canceled by caller"
        }
    }

    /// 接通那一下递给 TA 的旁白（不存成你说的话）：这通是 TA 打的，TA 先开口
    public static func answeredNudge(zh: Bool, pronoun: String, reason: String?) -> String {
        let why = (reason ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if zh {
            return "〔你打给\(pronoun)的电话接通了，\(pronoun)刚接起来。是你打的，你先开口。〕"
                + (why.isEmpty ? "" : "\n（你打这通电话是因为：\(why)）")
        }
        return "[The call you placed just connected — they picked up. You called, so you speak first.]"
            + (why.isEmpty ? "" : "\n(You called because: \(why))")
    }

    /// 屏幕上那一行
    public static func durationLine(seconds: Int, zh: Bool) -> String {
        (zh ? "📞 通话时长 " : "📞 Call ") + clock(seconds)
    }

    /// 03:21；一小时以上 1:03:21
    public static func clock(_ seconds: Int) -> String {
        let s = max(0, seconds)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
    }

    // MARK: 洗一句

    static let action = try! NSRegularExpression(pattern: #"（[^（）\n]{0,80}）|\([^()\n]{0,80}\)|\*[^*\n]{1,80}\*|【[^【】\n]{0,80}】"#)
    static let square = try! NSRegularExpression(pattern: #"\[[^\[\]\n]{0,80}\]|［[^［］\n]{0,80}］|⟪[^⟫\n]{0,80}⟫"#)
    static let leading = try! NSRegularExpression(pattern: #"^\s*(?:🎤|[-•·>]\s|\d{1,2}[.．、)）]\s*|#+\s)+"#)
    static let wordish = CharacterSet.letters.union(.decimalDigits)

    /// 要念的那句：洗掉不该念出来的；洗完没剩能念的字 → nil
    public static func clean(_ line: String) -> String? {
        var t = Markers.scrub(ModelNoise.strip(line)).replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
        for re in [action, square, leading] {
            t = re.stringByReplacingMatches(in: t, range: NSRange(location: 0, length: (t as NSString).length), withTemplate: "")
        }
        t = t.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.unicodeScalars.contains(where: { wordish.contains($0) }) else { return nil }
        return t
    }

    // MARK: 边写边切

    /// 模型一边推字，这边一边切：一行写完、或者一行里一句话说完（后面又来了字），就交出去一句。
    /// 太短的（不到 minUnits 个字）先攒着跟下一句一起念，免得一个「嗯。」单独去合成一次。
    public struct Splitter: Sendable {
        var buffer = ""
        var carry = ""
        var inMonologue = false
        let minUnits: Int

        public init(minUnits: Int = 4) { self.minUnits = minUnits }

        static let enders: Set<Character> = ["。", "！", "？", "!", "?", "…", "；", ";", "~", "～"]
        static let closers: Set<Character> = ["」", "』", "”", "\"", "’", "'", "）", ")", "】", "》"]

        /// 推一段字，拿回这次切出来的几句（已经洗好）
        public mutating func feed(_ chunk: String) -> [String] {
            buffer += chunk
            var out: [String] = []
            while let cut = nextCut() {
                let piece = String(buffer[..<cut])
                buffer = String(buffer[cut...])
                out += take(piece, final: false)
            }
            return out
        }

        /// 写完了：剩下的全交出去
        public mutating func finish() -> [String] {
            let rest = buffer
            buffer = ""
            var out = take(rest, final: true)
            if !carry.isEmpty, let c = CallSpeech.clean(carry) { out.append(c) }
            carry = ""
            return out
        }

        /// 下一刀切在哪：换行；或者句末标点（连着的标点、收尾引号算一起）后面又来了别的字。
        /// 英文的句号要后面跟空格才算（3.5、e.g. 不切）
        func nextCut() -> String.Index? {
            var i = buffer.startIndex
            while i < buffer.endIndex {
                let c = buffer[i]
                if c == "\n" { return buffer.index(after: i) }
                let isEnd = Self.enders.contains(c) || (c == "." && {
                    let n = buffer.index(after: i)
                    return n < buffer.endIndex && buffer[n] == " "
                }())
                if isEnd {
                    var j = buffer.index(after: i)
                    while j < buffer.endIndex, Self.enders.contains(buffer[j]) || Self.closers.contains(buffer[j]) || buffer[j] == "." {
                        j = buffer.index(after: j)
                    }
                    guard j < buffer.endIndex else { return nil }        // 后面还没来字：可能还有「？！」要跟上，先等
                    return j
                }
                i = buffer.index(after: i)
            }
            return nil
        }

        mutating func take(_ piece: String, final: Bool) -> [String] {
            // 漏写的 [独白]：第一个标记开头、下一个收尾，中间的整段不念（电话里本来关着独白，人设 / 旧历史里有标签时模型会照写）
            var rest = piece, line = ""
            while true {
                let ns = rest as NSString
                guard let m = Monologue.tag.firstMatch(in: rest, range: NSRange(location: 0, length: ns.length)) else {
                    if !inMonologue { line += rest }
                    break
                }
                if !inMonologue { line += ns.substring(to: m.range.location) }
                inMonologue.toggle()
                rest = ns.substring(from: m.range.upperBound)
            }
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("<") { return [] }                     // 写成文字的工具调用之类
            guard !trimmed.isEmpty else { return [] }
            let joined = carry.isEmpty ? trimmed : carry + (Self.needsSpace(carry, trimmed) ? " " : "") + trimmed
            guard let cleaned = CallSpeech.clean(joined) else { carry = ""; return [] }
            if !final, Self.units(cleaned) < minUnits {
                carry = joined
                return []
            }
            carry = ""
            return [cleaned]
        }

        static func needsSpace(_ a: String, _ b: String) -> Bool {
            guard let x = a.last, let y = b.first else { return false }
            return x.isASCII && y.isASCII && (x.isLetter || x.isPunctuation) && y.isLetter
        }

        /// 粗算有几个「字」：汉字一个算一个，英文一个词算一个
        static func units(_ s: String) -> Int {
            let cjk = s.unicodeScalars.filter { (0x3040...0x9FFF).contains($0.value) || (0xAC00...0xD7AF).contains($0.value) }.count
            let words = s.split(whereSeparator: { !(($0.isLetter || $0.isNumber) && $0.isASCII) }).count
            return cjk + words
        }
    }
}
