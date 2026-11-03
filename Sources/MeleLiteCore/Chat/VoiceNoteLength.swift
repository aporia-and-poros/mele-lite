import Foundation

/// 语音条按需念（10-31）：先落一个占位的语音条，点了才合成。占位上的秒数按字数估。
/// 中文一秒约 4.5 个字、英文一秒约 2.7 个词，再加半秒起头；[soft] 这类音频标签不算。
public enum VoiceNoteLength {
    static let tag = try! NSRegularExpression(pattern: #"\[[^\[\]\n]{1,60}\]"#)

    public static func estimateMs(_ script: String) -> Int {
        let ns = script as NSString
        let plain = tag.stringByReplacingMatches(in: script, range: NSRange(location: 0, length: ns.length), withTemplate: " ")
        let han = plain.unicodeScalars.filter { (0x4E00...0x9FFF).contains($0.value) }.count
        let words = plain.unicodeScalars.map { (0x4E00...0x9FFF).contains($0.value) ? " " : String($0) }.joined()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).count
        let seconds = Double(han) / 4.5 + Double(words) / 2.7 + 0.5
        return max(1000, Int(seconds * 1000))
    }
}
