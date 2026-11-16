import Foundation

/// 回复里哪几段是网页（11-16）。只用 Foundation，方便 ios/tests 单独编出来测。卡片和沙盒在 HTMLPreview.swift
enum HTMLBlock {
    /// 一段 HTML 代码最少多长才算一页（太短的多半是在讲语法）
    private static let minLength = 40
    private static let fence = try! NSRegularExpression(pattern: "```[ \\t]*(?:html|htm|HTML)[ \\t]*\\n([\\s\\S]*?)```")

    /// (去掉网页之后剩下的字, 网页们)。没有网页就原样返回、空数组
    static func split(_ text: String) -> (rest: String, pages: [String]) {
        let ns = text as NSString
        var pages: [String] = []
        var rest = text
        let matches = fence.matches(in: text, range: NSRange(location: 0, length: ns.length))
        if !matches.isEmpty {
            var out = ""
            var cursor = 0
            for m in matches {
                let code = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                guard code.count >= minLength, looksLikePage(code) else { continue }
                out += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
                pages.append(code)
                cursor = m.range.location + m.range.length
            }
            out += ns.substring(from: cursor)
            rest = out
        } else {
            // 没套代码块、整条就是一页
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let head = t.prefix(200).lowercased()
            if t.count >= minLength, head.hasPrefix("<!doctype html") || head.hasPrefix("<html") {
                return ("", [t])
            }
        }
        return (rest.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines), pages)
    }

    private static func looksLikePage(_ code: String) -> Bool {
        let l = code.lowercased()
        return l.contains("<html") || l.contains("<body") || l.contains("<div") || l.contains("<canvas")
            || l.contains("<svg") || l.contains("<script") || l.contains("<style") || l.contains("<button")
    }

    /// 卡片上的名字：<title> 里写的，没有就「一页网页」
    static func title(_ html: String) -> String {
        guard let r = html.range(of: #"<title[^>]*>([\s\S]*?)</title>"#, options: [.regularExpression, .caseInsensitive]) else {
            return String(localized: "一页网页")
        }
        let inner = html[r].replacingOccurrences(of: #"</?title[^>]*>"#, with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return inner.isEmpty ? String(localized: "一页网页") : String(inner.prefix(40))
    }

    /// 只给了片段（没有 <html>）的补成一整页，手机上字号正常
    static func document(_ html: String) -> String {
        if html.lowercased().contains("<html") { return html }
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>body{font-family:-apple-system,sans-serif;margin:16px;}</style></head><body>
        \(html)
        </body></html>
        """
    }
}

