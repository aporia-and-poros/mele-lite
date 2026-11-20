import Foundation

/// 世界书：最近几句里说到关键词才把那一条递给它；常驻的总在。
public enum LoreMatcher {
    public static func hits(entries: [LoreEntry], recent: [Message], contactID: String,
                            scan: Int = 4, maxHits: Int = 8) -> [LoreEntry] {
        let haystack = normalize(recent.suffix(scan).map(\.text).joined(separator: "\n"))
        // 常驻的不占 maxHits（11-19：整份导入切成好几块常驻，前 8 块把关键词那几条全挤掉了）
        var out: [LoreEntry] = [], hit = 0
        for e in entries where e.enabled && (e.contactIDs == nil || e.contactIDs!.contains(contactID)) {
            if e.constant { out.append(e); continue }
            guard hit < maxHits else { continue }
            if e.keys.contains(where: { k in
                let n = normalize(k)
                return !n.isEmpty && haystack.contains(n)
            }) {
                out.append(e)
                hit += 1
            }
        }
        return out
    }

    /// 全角转半角、大小写不分
    static func normalize(_ s: String) -> String {
        (s.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? s).lowercased()
    }
}
