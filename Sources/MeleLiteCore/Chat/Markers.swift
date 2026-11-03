import Foundation

/// 它在回复里写的小标记（提示词里教的写法），解出来以后从正文里拿掉：
/// - 发表情包：`[表情包：#12]`（编号照「你的表情包」那张表）/ 旧写法 `[表情包：描述]` / `[sticker: #12]`
/// - 立里程碑：`⟪里程碑：标题⟫` / `⟪milestone: …⟫`
/// - 想查手机：`⟪想查手机：想看什么⟫` / `⟪peek: …⟫`
///
/// 这些是「说了就算、不用看结果」的动作，不走工具（10-31：省掉工具说明和一来一回）。
/// 可以夹在句子中间，拿掉以后正文不留痕；括号写歪了（【】［］《》〈〉）也认；
/// 写坏了的（没闭合、少了冒号）解不出来也一律剥掉——标记绝不能漏进气泡。
public struct ParsedReply: Equatable, Sendable {
    public var text: String
    public var stickers: [String]
    public var milestones: [String]
    public var wantsPeek: String?
}

public enum Markers {
    static let open = #"[\[【［⟪《〈<]"#
    static let close = #"[\]】］⟫》〉>]"#
    static let sticker = try! NSRegularExpression(
        pattern: open + #"\s*(?:表情包|表情|sticker)\s*[:：]\s*([^\]】］⟫》〉>\n]+?)\s*"# + close, options: .caseInsensitive)
    static let milestone = try! NSRegularExpression(
        pattern: open + #"\s*(?:里程碑|milestone)\s*[:：]\s*([^\]】］⟫》〉>\n]+?)\s*"# + close, options: .caseInsensitive)
    static let peek = try! NSRegularExpression(
        pattern: open + #"\s*(?:想查手机|peek)\s*[:：]\s*([^\]】］⟫》〉>\n]+?)\s*"# + close, options: .caseInsensitive)
    /// 兜底：写坏了的。没闭合的吃到行尾（后面那截多半也是标记里的字）；闭合了但没冒号的整个拿掉
    static let broken = try! NSRegularExpression(
        pattern: open + #"\s*(?:表情包|sticker|里程碑|milestone|想查手机|peek)(?:[^\]】］⟫》〉>\n]*"# + close + "|[^\\n]*)",
        options: .caseInsensitive)
    /// 拿掉一个标记时先占个位，最后再按左右的空白收拾（夹在句中不留双空格、在行首行尾不留空格）
    static let hole = "\u{1}"

    public static func parse(_ reply: String) -> ParsedReply {
        var text = reply
        let stickers = pull(sticker, from: &text)
        let milestones = pull(milestone, from: &text)
        let peeks = pull(peek, from: &text)
        _ = pull(broken, from: &text)
        return ParsedReply(text: tidy(fill(text)), stickers: stickers, milestones: milestones, wantsPeek: peeks.first)
    }

    /// 只剥不解：推送、信、念出来的话这些出口用（解析在别处做过了，这里保证一个标记都不漏）
    public static func scrub(_ text: String) -> String {
        var t = text
        for re in [sticker, milestone, peek, broken] { _ = pull(re, from: &t) }
        return tidy(fill(t))
    }

    static func pull(_ re: NSRegularExpression, from text: inout String) -> [String] {
        let ns = text as NSString
        let ms = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
        let found = ms.compactMap { $0.numberOfRanges > 1 && $0.range(at: 1).location != NSNotFound ? ns.substring(with: $0.range(at: 1)) : nil }
        text = re.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: ns.length), withTemplate: hole)
        return found
    }

    /// 占位那里：左右都有空白 → 留一个空格；否则什么都不留
    static func fill(_ s: String) -> String {
        guard s.contains(hole) else { return s }
        let re = try! NSRegularExpression(pattern: "([ \\t\\u3000]*)(?:\u{1})+([ \\t\\u3000]*)")
        let ns = s as NSString
        var out = "", last = 0
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            if m.range(at: 1).length > 0 && m.range(at: 2).length > 0 { out += " " }
            last = m.range.location + m.range.length
        }
        return out + ns.substring(from: last)
    }

    /// 拿掉标记后：每行去掉行尾空格，连着的空段并成一个空行，首尾空白去掉。
    static func tidy(_ s: String) -> String {
        let paras = s.split(separator: try! Regex(#"\n\s*\n"#))
            .map { $0.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: "\n") }
            .filter { !$0.isEmpty }
        return paras.joined(separator: "\n\n")
    }
}
