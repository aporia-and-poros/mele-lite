import SwiftUI
import UIKit

/// 气泡里的一点点格式（10-01 Aporia：线下模式动作用斜体、重点加粗）：*动作* → 斜体 + 淡一点；**重点** → 加粗。
/// 中文没有斜体字形，系统也不会替它斜，所以斜体用字体矩阵自己斜（中英文都斜）。其余 Markdown（标题、列表、链接）一律当原文。
enum RichText {
    private static let slant = CGAffineTransform(a: 1, b: 0, c: 0.21, d: 1, tx: 0, ty: 0)

    static func render(_ text: String, size: CGFloat, ink: Color) -> AttributedString {
        guard text.contains("```") else { return inline(listed(text), size: size, ink: ink) }
        // 代码块（11-07 许愿）：等宽字 + 一层淡底，里面的字一个不动
        var out = AttributedString()
        for (i, piece) in text.components(separatedBy: "```").enumerated() {
            let isCode = i % 2 == 1
            var body = piece
            if isCode, let nl = body.firstIndex(of: "\n"), !body[..<nl].contains(" ") { body = String(body[body.index(after: nl)...]) }   // 第一行的语言名不显示
            body = body.trimmingCharacters(in: .newlines)
            guard !body.isEmpty else { continue }
            if !out.characters.isEmpty { out.append(AttributedString("\n")) }
            if isCode {
                var code = AttributedString(body)
                code.font = .system(size: size * 0.88, design: .monospaced)
                code.backgroundColor = ink.opacity(0.08)
                out.append(code)
            } else {
                out.append(inline(listed(body), size: size, ink: ink))
            }
        }
        return out
    }

    /// 列表、小标题（11-07 许愿）：「- 一条」画成「• 一条」，「# 标题」画成粗体
    private static func listed(_ text: String) -> String {
        var t = text.replacingOccurrences(of: #"(?m)^(\s*)[-*] +"#, with: "$1• ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(?m)^#{1,4} +(.+)$"#, with: "**$1**", options: .regularExpression)
        return t
    }

    private static func inline(_ text: String, size: CGFloat, ink: Color) -> AttributedString {
        guard text.contains("*") || text.contains("_") || text.contains("`"),
              var out = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        else { return AttributedString(text) }
        for run in out.runs {
            guard let intent = run.inlinePresentationIntent else { continue }
            if intent.contains(.code) {
                out[run.range].font = .system(size: size * 0.92, design: .monospaced)
                out[run.range].backgroundColor = ink.opacity(0.08)
                out[run.range].inlinePresentationIntent = nil
                continue
            }
            let bold = intent.contains(.stronglyEmphasized)
            if intent.contains(.emphasized) {
                var desc = UIFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular).fontDescriptor
                desc = desc.withMatrix(slant)
                out[run.range].font = Font(UIFont(descriptor: desc, size: size))
                out[run.range].foregroundColor = ink.opacity(0.7)
            } else if bold {
                out[run.range].font = .system(size: size, weight: .semibold)
            }
            out[run.range].inlinePresentationIntent = nil
            out[run.range].link = nil
        }
        for run in out.runs where run.link != nil { out[run.range].link = nil }   // 链接不变蓝、不能点（原样）
        return out
    }
}
