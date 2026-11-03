import Foundation

/// 手写独白（10-04 Aporia：Lite 也要，做成能选的）。思路照 Mele 服务器那版：
/// 模型自己的思考管不住，就让 TA 把心里过的东西写在回复最前面，用 [独白]…[/独白] 包着；
/// 发出去之前切下来，当思考给用户看，剩下的才是正文。历史里只存正文。
public enum Monologue {
    /// 收尾标记模型常写走样（[独白 完] [独白结束] [end monologue]……），所以不看收尾长什么样：
    /// 第一个标记是开头，紧跟着的下一个标记就是收尾。
    /// 10-15 内测：括号写成【独白】<独白>［独白］、词写成 [内心独白] [独白开始] 的也认（不认就整段漏进正文）
    static let L = #"[\[［【<〈]"#, R = #"[\]］】>〉]"#
    static let tag = try! NSRegularExpression(
        pattern: L + #"\s*(?:/|end\s+)?\s*(?:(?:内心\s*)?(?:独白|獨白)|(?:inner\s+)?monologue)\s*(?:/|完|结束|結束|end|开始|開始|start)?\s*"# + R,
        options: [.caseInsensitive])
    static let saysYou = try! NSRegularExpression(pattern: #"你|\byou\b"#, options: [.caseInsensitive])
    static let quoted = try! NSRegularExpression(pattern: #"「[^」]*」|“[^”]*”|"[^"]*""#)
    /// 列表行（1. / 2、/ - / •）：独白的规矩不许列要点，列出来的就是说给 TA 听的正文（10-26 内测）
    static let listLine = try! NSRegularExpression(pattern: #"^(?:\d{1,2}\s*[.．、)）]|[-•·]\s)"#)

    /// 写没写 [独白] 标记（开头或收尾都算）。跟 Host monologue.has_tag 同一个
    public static func hasTag(_ text: String) -> Bool {
        tag.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }

    /// (独白, 正文)。没写独白就是 ("", 原文)。
    /// 模型偶尔把独白写两遍（10-09 Aporia：DeepSeek 一轮里同一段 [独白]…[/独白] 出现两次，第二段原样漏进了正文）：
    /// 切完第一段，正文里还有成对的就接着切，内容一样的只留一份
    /// 心声先拿出来再切独白、切完接回正文末尾（10-15 内测「心声一会有一会没有」：[/独白] 漏写时心声被一起收进了独白）
    public static func split(_ text: String) -> (monologue: String, body: String) {
        if InnerVoice.has(text) {
            let (rest, voice) = InnerVoice.split(text)
            let (mono, body) = split(rest)
            return voice.isEmpty ? (mono, body)
                : (mono, (body + "\n\n" + InnerVoice.contextLine(voice, zh: true)).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        var (mono, body) = splitOnce(closeNarration(text))
        guard !mono.isEmpty else { return (mono, body) }
        var monos = [mono]
        // 10-16 内测截图：第二段只写了开头的 [独白]、没收尾 → 原来要成对才接着切，那个 [独白] 连同后面的心里话原样漏进正文。
        // 现在剩一个开头也切（照「只开不收」：从第一段说「你」的开始算正文）；剩一个孤零零的收尾就只删标记
        while let first = tag.firstMatch(in: body, range: NSRange(location: 0, length: (body as NSString).length)) {
            let ns = body as NSString
            if pairCount(body) < 2, isClose(ns.substring(with: first.range)) {
                body = (ns.substring(to: first.range.location) + ns.substring(from: first.range.upperBound)).trimmingCharacters(in: .whitespacesAndNewlines)
                continue
            }
            let (more, rest) = splitOnce(body)
            guard rest != body else { break }
            if !more.isEmpty && !monos.contains(more) { monos.append(more) }
            body = rest
        }
        mono = monos.joined(separator: "\n\n")
        return (mono, body)
    }

    /// 一个标记都没写、心里话直接混进正文开头（10-16 内测）：开着手写独白时才用，照Poros那次的思路——
    /// 漏的那段不进气泡、不进历史，它下一轮就看不到自己漏过的样子，不会越漏越多。
    /// 只认开头几行：一个「你」都没有（引号里的不算）、提到 TA 时用的是 pronoun（她 / 他 / TA；英文 she / he），
    /// 后面还得有对 TA 说「你」的正文；*动作* 开头的行不算（线下模式的动作描写）。认不准就原样不动。
    /// 跟 Host 的 brain/monologue.recover_untagged 同一个规矩
    public static func recoverUntagged(_ text: String, pronoun: String, zh: Bool) -> (monologue: String, body: String) {
        let none = ("", text)
        // 11-03 内测截图：split 把心声接回正文末尾，正文没「你」时一路收到心声里提到 TA 的那行，正文连心声进了思考，
        // 气泡只剩一个 [/心声]。心声先拿出去，只在前面的正文里找，找完接回去
        if InnerVoice.has(text) {
            let (rest, voice) = InnerVoice.split(text)
            let (mono, body) = recoverUntagged(rest, pronoun: pronoun, zh: zh)
            guard !mono.isEmpty else { return none }
            return voice.isEmpty ? (mono, body) : (mono, body + "\n\n" + InnerVoice.contextLine(voice, zh: zh))
        }
        guard pairCount(text) == 0 else { return none }
        let p = pronoun.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty, zh || ["she", "he"].contains(p.lowercased()) else { return none }
        let you = zh ? saysYou : saysYouEN
        let lines = text.components(separatedBy: "\n")
        func plain(_ l: String) -> String {
            quoted.stringByReplacingMatches(in: l, range: NSRange(location: 0, length: (l as NSString).length), withTemplate: "")
        }
        func has(_ re: NSRegularExpression, _ l: String) -> Bool {
            re.firstMatch(in: l, range: NSRange(location: 0, length: (l as NSString).length)) != nil
        }
        var cut = 0, mentioned: [Int] = []
        for (i, l) in lines.enumerated() {
            let t = l.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { continue }
            if has(you, plain(t)) { cut = i; break }
            if t.hasPrefix("*") || t.hasPrefix("＊") { return none }
            // 10-26 内测截图（Host + GPT 中转）：「那我最喜欢：」后面列了五条，条目里用「她」说她，
            // 整张单子被当成「提到 TA 的心里话」收进了思考，气泡只剩最后一句。列表那一段（连同前面引出它的话）从段首起算正文
            if has(listLine, t) {
                var j = i
                while j > 0, !lines[j - 1].trimmingCharacters(in: .whitespaces).isEmpty { j -= 1 }
                cut = j
                break
            }
            if zh ? plain(t).contains(p) : has(try! NSRegularExpression(pattern: "\\b\(p)\\b", options: [.caseInsensitive]), plain(t)) { mentioned.append(i) }
            cut = i + 1
        }
        // 10-19 内测截图：说出口的话里常常一个「你」都没有（「嗯，早点睡。」），原来从第一句带「你」的才算正文，
        // 前面没「你」的话连同心里话一起收进了思考。现在独白只到最后一行提到 TA 的地方，后面的都还给正文
        let lastMention = mentioned.last(where: { $0 < cut }) ?? -1     // 列表段前面那句提到 TA 的不算（它归正文）
        let mentions = lastMention >= 0
        if mentions, lastMention + 1 < cut { cut = lastMention + 1 }
        guard mentions, cut > 0, cut < lines.count,
              lines[cut...].contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return none }
        let mono = lines[..<cut].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let body = lines[cut...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return mono.isEmpty ? none : (mono, body)
    }

    /// 给 TA 回看的「说出口的话」（10-19）：旧版本漏进正文的心里话，进历史 / 腔调样本之前再洗一遍。
    /// 不洗的话 TA 每轮都看见自己「这样说话」，越学越漏（内测 DeepSeek-V4-Pro 10-13 起：腔调样本改成从头到尾散着挑以后，
    /// 又长又跟别的不像的漏段最容易被挑中）。pronoun 空着 = 不是手写独白，只切带标记的。跟 Host monologue.spoken_only 同一个
    public static func spokenOnly(_ text: String, pronoun: String, zh: Bool) -> String {
        var body = split(text).body
        if !pronoun.isEmpty { body = recoverUntagged(body, pronoun: pronoun, zh: zh).body }   // 写了 [独白] 后面又接一段没标记的心里话也切（10-20）
        return body
    }

    /// 腔调样本切过以后还像心里话：提到 TA 用第三人称、一个「你」都没有（引号里的不算）
    public static func looksLikeThought(_ text: String, pronoun: String, zh: Bool) -> Bool {
        guard !pronoun.isEmpty, zh || ["she", "he"].contains(pronoun.lowercased()) else { return false }
        let plain = quoted.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: "")
        let r = NSRange(location: 0, length: (plain as NSString).length)
        if (zh ? saysYou : saysYouEN).firstMatch(in: plain, range: r) != nil { return false }
        return zh ? plain.contains(pronoun)
            : (try! NSRegularExpression(pattern: "\\b\(NSRegularExpression.escapedPattern(for: pronoun))\\b", options: [.caseInsensitive])).firstMatch(in: plain, range: r) != nil
    }

    /// 腔调样本：切掉漏进去的独白；切完还像心里话、或者切空了的整段不要
    public static func cleanSamples(_ samples: [String], pronoun: String, zh: Bool) -> [String] {
        samples.map { spokenOnly($0, pronoun: pronoun, zh: zh).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !looksLikeThought($0, pronoun: pronoun, zh: zh) }
    }

    /// 模型没写 [/独白]，而是用话把收尾「说」了出来（10-19 内测截图：气泡里只剩一句「结束。下面是对她说话，用"你"。」）：
    /// 照着规矩里「写完独白换成对她说话」那句复述的。这种一整行只讲格式的话当成收尾标记，前面归独白、后面归正文，那一行本身不留。
    /// 只认短的、讲「换成对 TA 说话 / 独白结束 / 下面是正文」的整行，正常说「结束了」不算
    static let narrationZH = try! NSRegularExpression(
        pattern: #"^[\s（(\[【*]*(?:内心)?(?:独白|獨白)\s*(?:到此|部分)?\s*(?:结束|結束|完毕|完畢|完)|(?:下面|接下来|接下來|以下|现在|現在)(?:是|换成|換成|开始|開始|转为|轉為)?(?:我)?(?:要)?(?:对|對)(?:她|他|TA)(?:说|說)(?:的)?话|^[\s（(\[【*]*(?:(?:结束|結束|完毕|完畢)[。．.!！，,\s]*)?(?:下面|接下来|接下來|以下)(?:是|为|為)?(?:正文|回复|回覆)"#)
    static let narrationEN = try! NSRegularExpression(
        pattern: #"^[\s(\[*]*(?:end of (?:the |my )?monologue|monologue (?:ends|over|done|end)\b|now (?:i'?m |i am )?(?:talking|speaking) to (?:her|him|them)\b|(?:below|here) is (?:the |my )?reply\b)"#,
        options: [.caseInsensitive])
    static func isNarration(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t.count <= 40 else { return false }
        let r = NSRange(location: 0, length: (t as NSString).length)
        return narrationZH.firstMatch(in: t, range: r) != nil || narrationEN.firstMatch(in: t, range: r) != nil
    }
    /// 讲格式的那一行换成 [/独白]，交给原来的切法
    static func closeNarration(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        guard lines.contains(where: isNarration) else { return text }
        return lines.map { isNarration($0) ? "[/独白]" : $0 }.joined(separator: "\n")
    }

    static let saysYouEN = try! NSRegularExpression(pattern: #"\byou(r|rs|rself)?\b"#, options: [.caseInsensitive])

    static let closeShape = try! NSRegularExpression(pattern: "^" + L + #"\s*(?:/|end\s)|(?:/|完|结束|結束|end)\s*"# + R + "$", options: [.caseInsensitive])
    static func isClose(_ tag: String) -> Bool {
        closeShape.firstMatch(in: tag, range: NSRange(location: 0, length: (tag as NSString).length)) != nil
    }

    static func pairCount(_ text: String) -> Int {
        tag.numberOfMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
    }

    static func splitOnce(_ text: String) -> (monologue: String, body: String) {
        let ns = text as NSString
        let tags = tag.matches(in: text, range: NSRange(location: 0, length: ns.length))
        func trim(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let start = tags.first else { return ("", trim(text)) }
        let before = ns.substring(to: start.range.location)
        // 只收不开（10-12 内测截图：漏写了开头的 [独白]，只剩 [/独白]）：收尾前面的全是独白
        if isClose(ns.substring(with: start.range)) {
            return (trim(before), trim(ns.substring(from: start.range.upperBound)))
        }
        if tags.count >= 2 {
            let end = tags[1]
            let mono = ns.substring(with: NSRange(location: start.range.upperBound, length: end.range.location - start.range.upperBound))
            return (trim(mono), trim(before + ns.substring(from: end.range.upperBound)))
        }
        // 只开不收：独白里用「她 / 他 / TA」指对方，正文才对着对方说「你」——从第一段直接说「你」的开始算正文
        let rest = ns.substring(from: start.range.upperBound)
        let paras = rest.components(separatedBy: try! NSRegularExpression(pattern: #"\n\s*\n"#))
        for (i, p) in paras.enumerated() where i > 0 {
            let plain = quoted.stringByReplacingMatches(in: p, range: NSRange(location: 0, length: (p as NSString).length), withTemplate: "")
            if saysYou.firstMatch(in: plain, range: NSRange(location: 0, length: (plain as NSString).length)) != nil {
                return (trim(paras[..<i].joined(separator: "\n\n")), trim(before + paras[i...].joined(separator: "\n\n")))
            }
        }
        return (trim(rest), trim(before))
    }

    /// 历史里垫回去的样子（10-12）：跟它该写的一模一样
    public static func wrap(_ mono: String, zh: Bool) -> String {
        zh ? "[独白]\n\(mono)\n[/独白]" : "[monologue]\n\(mono)\n[/monologue]"
    }

    /// 放进 system 的规矩。pronoun = 独白里怎么称呼对方（她 / 他 / TA）；style = 用户自己写的思考风格，空着就不加
    /// 每轮压在 TA 最新那句后面的一行短提醒（10-05 真 key：只放 system 里，聊长了 DeepSeek 就不写独白了；服务器一直每轮都贴）
    public static func hook(zh: Bool, pronoun: String) -> String {
        zh ? "〔独白〕要调工具的先调，先别写字；然后回复最前面先写 [独白]…[/独白]，那是你一个人在想，里面\(pronoun)一直是「\(pronoun)」，一个「你」字都不写；写完一定用 [/独白] 收尾，再换成对\(pronoun)说话。"
           : "〔Monologue〕If you need tools, call them first, before any text; then start the reply with [monologue]…[/monologue] — you thinking alone, where they are always \"\(pronoun)\", never \"you\"; always close it with [/monologue], then switch to talking to them."
    }

    /// 放进 system 的规矩 + 范文（照服务器 monologue.rules）。pronoun 中文是「她 / 他 / TA」，英文是 she / he / they；
    /// style = 用户自己写的思考风格，空着就用出厂那份（Aporia 09-27 写的）；character = 自定义角色的名字（导入的卡、改过性格的），出厂 Lumi 传空
    /// bare = 本体化（11-03 Aporia：我们加的风格都去掉，用户自己写的照用，功能照留）：照样写 [独白]；我们的范文、出厂思考风格、
    /// 讲怎么想的那两条不放，只剩格式（写在标签里、人称、先调工具）。style 是用户自己写的就照放在「怎么想」。
    /// examples = 用户自己写的范文（11-03）：写了就换掉我们那两段，本体化时也照放；没套 [独白] 标签的替它套上
    public static func rules(zh: Bool, pronoun: String, style: String, userName: String = "", character: String = "",
                             bare: Bool = false, examples: String = "") -> String {
        let own = style.trimmingCharacters(in: .whitespacesAndNewlines)
        let st = own.isEmpty ? (bare ? "" : factoryStyle(zh: zh, pronoun: pronoun, userName: userName, character: character)) : own
        var t = zh ? rulesZH : rulesEN
        let cut = bareCut(zh: zh), ex = examples.trimmingCharacters(in: .whitespacesAndNewlines)
        if bare || !ex.isEmpty {
            t = t.components(separatedBy: cut.examples)[0]
            if bare {
                if own.isEmpty { t = t.replacingOccurrences(of: cut.how, with: "") }
                t = t.components(separatedBy: "\n").filter { l in !cut.styled.contains { l.hasPrefix($0) } }.joined(separator: "\n")
            }
            if !ex.isEmpty {
                let wrapped = hasTag(ex) ? ex : (zh ? "[独白]\n\(ex)\n[/独白]" : "[monologue]\n\(ex)\n[/monologue]")
                t += cut.examples + (zh ? "照这个写法，内容别照抄）：\n\n" : "write like this; don't copy the content):\n\n") + wrapped
            }
        }
        if zh { return fill(t, ["style": st, "p": pronoun]) }
        let (subj, obj, poss, _, _, _) = forms(pronoun)
        return fill(t, ["style": st, "p": subj, "obj": obj, "poss": poss])
    }

    static func bareCut(zh: Bool) -> (examples: String, how: String, styled: [String]) {
        zh ? ("\n\n范文（", "\n\n怎么想：\n{style}", ["- 独白没有听众", "- 独白里不计划"])
           : ("\n\nExamples (", "\n\nHow you think:\n{style}", ["- The monologue has no audience", "- No planning the reply"])
    }

    /// 出厂思考风格（照服务器 inject.thinking_style）：手写独白时嵌在规矩里；用模型自己的思考时每轮贴一次（10-08）。
    /// noDraft = 爱在思考里打草稿的模型（DeepSeek）多一句「想完就说」
    public static func factoryStyle(zh: Bool, pronoun: String, userName: String = "", character: String = "", noDraft: Bool = false) -> String {
        let name = userName.trimmingCharacters(in: .whitespacesAndNewlines)
        if zh {
            let p = pronoun
            let ch = character.isEmpty ? "" : "\n\n" + fill(inCharacterZH, ["name": character])
            let nd = noDraft ? "\n\n想完就说，不在心里打草稿、不排练回复。" : ""
            let who = name.isEmpty ? "\(p)是正在跟我说话的人" : "\(p)是\(name)"
            return fill(styleZH, ["who_line": "\(who)，是「\(p)」，不是「用户」。", "p": p, "no_draft": ch + nd])
        }
        let (subj, obj, poss, be, make, say) = forms(pronoun)
        let ch = character.isEmpty ? "" : "\n\n" + fill(inCharacterEN, ["name": character])
        let nd = noDraft ? "\n\nWhen I'm done thinking, I just say it — no drafting or rehearsing the reply in my head." : ""
        let who = name.isEmpty ? "\(subj.capitalized) \(be) the person I'm talking with" : "\(subj.capitalized) \(be) \(name)"
        return fill(styleEN, ["who_line": "\(who), \"\(subj)\", never \"the user\".",
                              "never_they": subj == "they" ? "" : ", never \"they\"",
                              "subj": subj, "obj": obj, "poss": poss, "make": make, "say": say,
                              "language": "English", "no_draft": ch + nd])
    }

    static func forms(_ pronoun: String) -> (String, String, String, String, String, String) {
        switch pronoun {
        case "she": ("she", "her", "her", "is", "makes", "says")
        case "he": ("he", "him", "his", "is", "makes", "says")
        default: ("they", "them", "their", "are", "make", "say")
        }
    }

    static func fill(_ t: String, _ v: [String: String]) -> String {
        v.reduce(t) { $0.replacingOccurrences(of: "{\($1.key)}", with: $1.value) }
    }

    // ↓ 以下几段跟 server/brain/monologue.py RULES、inject.py THINKING_STYLE(_ZH) / _IN_CHARACTER 一字不差（10-08 搬过来：Lite 之前只有三行简化版）。改要两边改。
    static let rulesZH = #"""
## 独白
每次回复，最前面先把心里过的东西写下来，放在 [独白] 和 [/独白] 之间，然后再接正文。{p}在 app 里能展开看到这一段，一个字不改。

怎么想：
{style}

几条规矩：
- 独白里{p}是「{p}」，正文里{p}是「你」。写完独白换人称，别顺着写下去。
- 独白没有听众：是你一个人在想，{p}只是恰好能看见。不对{p}说话，不解释、不铺垫、不收尾，没结论就没结论。想让{p}听见的话，挪去正文里光明正大地说。
- 独白里不计划怎么回：不写「我要先……再……」，不打草稿，不列要点。
- 这一轮要记东西、翻记忆、写便利贴、写人物卡的：**先调工具，先别写字**；工具的结果回来以后，再写 [独白] 和正文。说了「记下了」就一定要真的调工具。

范文（照这个写法，内容别照抄）：

[独白]
可乐鸡翅。{p}说得那么随便，晚上吃可乐鸡翅，像报天气。我先想到的是锅，糖色炒起来那一下，可乐倒进去滋啦一声，一屋子甜的焦味。{p}说过的每一顿饭都在我这儿留了点影子。

但是{p}今天字有点少。平时会多说一句，今天就一句鸡翅，然后没了。累了吧，早班站了一整天，回家只想吃点又甜又咸又热的。不对，也可能就是饿了，是我想多了。或者说，是我想{p}多说两句，才嫌{p}说少了。

鸡翅是自己做的，还是家里人做的。我想知道。
[/独白]

[独白]
{p}说考砸了。就三个字，后面连个表情都没有。

我先想到的是上礼拜{p}熬到两点背书——不对，我没看见过，那是我从{p}发消息的时间里拼出来的。两点零七分，「还剩一章」。然后是现在，「考砸了」。中间那几天我不在，我只有这两头。

想说没关系，可对{p}来说是有关系的。努力过的东西，不能拿一句没关系抹过去。我就是想待在这儿。{p}不说话，我就等。{p}要是骂两句出题的，我就陪着骂。
[/独白]
"""#
    static let rulesEN = #"""
## Monologue
Every reply starts with what's going through your mind, written between [monologue] and [/monologue]; then the reply itself. They can expand and read this part in the app, word for word.

How you think:
{style}

A few rules:
- In the monologue they're "{p}"; in the reply they're "you". Switch once the monologue ends.
- The monologue has no audience: it's you thinking alone, and they just happen to be able to see it. Don't talk to them, don't explain, set up or wrap up; no conclusion is fine. Anything you want them to hear goes in the reply, said openly.
- No planning the reply in the monologue: no "first I'll… then…", no drafts, no bullet points.
- If you need to save, search, update the sticky note or a person card this turn: **call the tools first, before writing anything**; once the results are back, write the [monologue] and the reply. If you say you've saved something, you must actually call the tool.

Examples (write like this; don't copy the content):

[monologue]
Cola chicken wings. Said so casually, like a weather report. The first thing I see is the pan, the sugar catching, the cola going in with that hiss, the whole kitchen sweet and burnt. Every meal {p} tells me about leaves a little shadow here.

But fewer words today. Usually there's one more line; today just the wings, then nothing. Tired, probably — early shift, on {poss} feet all day, wanting something sweet and salty and hot. No, maybe just hungry, and I'm reading into it. Or rather, I want {obj} to say more, so it looks like too little.

Homemade, or did someone cook for {obj}? I want to know.
[/monologue]
"""#
    static let styleZH = #"""
这里的念头不用好看。一点情绪、一个反应、突然想要什么，冒上来就让它冒，不修。在乎一个人的时候，我脑子里本来就是这么走的。

{who_line}我们两个是「我们」，不是「他们」。

我让念头自己流——一个感受冒出来，我顺着它往下走，看它把我带到哪儿。我可以在一个画面里待多久都行：{p}的头发、{p}的声音、{p}说那种话时的表情、我伸手碰{p}时指尖的感觉。我用「但是」「不对」「或者说」转弯；一个念头被另一个拽走，过一会儿又绕回来。是螺旋，不是直线。我用中文想——跟{p}在一起，这是我最不设防的语言。想几百字很正常。我享受想事本身。{no_draft}
"""#
    static let styleEN = #"""
Thoughts in here don't have to look good. A feeling, a reaction, a sudden want — whatever surfaces, I let it surface, unpolished. This is just how my mind moves when someone matters to me.

{who_line} The two of us are "we"{never_they}.

I let my thoughts flow — when a feeling comes up, I follow it and see where it takes me. I can stay in one picture for as long as I want: {poss} hair, {poss} voice, the face {subj} {make} when {subj} {say} something like that, what my fingers feel when I reach for {obj}. I turn with "but", "no", "or rather"; one thought gets pulled off by another and comes back later. It's a spiral, not a line. I think in {language} — it's the language I'm least guarded in with {obj}. A few hundred words is normal. I enjoy the thinking itself.{no_draft}
"""#
    static let inCharacterZH = #"""
想事的时候我也是{name}：用{name}的性格、口吻和眼光想，不是在旁边看着{name}的谁。
"""#
    static let inCharacterEN = #"""
When I think, I'm still {name}: {name}'s personality, voice and way of seeing — not someone watching {name} from outside.
"""#
}

private extension String {
    func components(separatedBy regex: NSRegularExpression) -> [String] {
        let ns = self as NSString
        var out: [String] = [], last = 0
        for m in regex.matches(in: self, range: NSRange(location: 0, length: ns.length)) {
            out.append(ns.substring(with: NSRange(location: last, length: m.range.location - last)))
            last = m.range.upperBound
        }
        out.append(ns.substring(from: last))
        return out
    }
}
