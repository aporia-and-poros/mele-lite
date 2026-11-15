#if LITE
import Foundation

/// TA 那边（10-04 Aporia：Lite 也要）：手机读的天气 / 在哪 / 日程 / 步数和睡眠（`ContextReporter`，跟正式版同一份），
/// 回前台时 PUT me/context/{kind} 交给管家存着；聊天时拼成一行〔TA 那边〕。照 server/brain/context_line.py 搬。
/// - 每样只存最新一份（覆盖，不留轨迹）；太旧的不写，免得它拿旧消息当现在。
/// - 不是每轮都给（09-28 Aporia：每轮都给它就每条思考都在念天气和步数）：这个窗口第一次、隔了两小时、换了地方，才给。
/// - 在听的歌不在这行里，〔在听〕那行管。
enum LocalContext {
    static let kinds = ["weather", "place", "calendar", "health", "cycle"]
    static let maxAge: [String: TimeInterval] = ["weather": 3 * 3600, "place": 3 * 3600, "calendar": 12 * 3600, "health": 3 * 3600,
                                                 "cycle": 36 * 3600]
    static let reshow: TimeInterval = 2 * 3600
    private static let file = "context.json"
    private static let shownFile = "context-shown.json"

    static func save(_ s: LocalStore, kind: String, body: [String: Any]) -> LocalResponse {
        guard kinds.contains(kind) else { return .error(400, String(localized: "不认识这一样")) }
        var all = s.read(file) as? [String: Any] ?? [:]
        all[kind] = ["data": body, "at": LocalStore.iso(Date())]
        s.write(file, all)
        return .empty
    }

    /// 这一轮要不要给、给的话是哪一行（给了就记下这个窗口给过）
    /// force：她这句在问这些（ContextReporter.asks），隔多久都给（10-13）
    static func line(_ s: LocalStore, conversation: String, zh: Bool, force: Bool = false, companion: String? = nil,
                     now: Date = Date()) -> String {
        let items = fresh(s, now: now)
        let text = render(items, now: now, zh: zh, companion: companion)
        guard !text.isEmpty else { return "" }
        var shown = s.read(shownFile) as? [String: Any] ?? [:]
        let last = shown[conversation] as? [String: Any]
        let key = placeKey(items)
        if !force, let last, now.timeIntervalSince(LocalStore.date(last["at"])) < reshow, last["key"] as? String == key { return "" }
        shown[conversation] = ["at": LocalStore.iso(now), "key": key]
        s.write(shownFile, shown)
        return text
    }

    private static func fresh(_ s: LocalStore, now: Date) -> [String: ([String: Any], Date)] {
        let all = s.read(file) as? [String: Any] ?? [:]
        var out: [String: ([String: Any], Date)] = [:]
        for kind in kinds {
            guard let e = all[kind] as? [String: Any], let data = e["data"] as? [String: Any] else { continue }
            let at = LocalStore.date(e["at"])
            if now.timeIntervalSince(at) <= maxAge[kind] ?? 0 { out[kind] = (data, at) }
        }
        return out
    }

    /// 「TA 那边有没有变」只看在哪、经期那一句（天气、步数一直在小变，不算）
    private static func placeKey(_ items: [String: ([String: Any], Date)]) -> String {
        let cycle = items["cycle"].map { "|" + ($0.0["key"] as? String ?? "") } ?? ""
        guard let p = items["place"]?.0 else { return cycle }
        return ((p["at_home"] as? Bool ?? false) ? "home" : (p["name"] as? String ?? "")) + cycle
    }

    static func render(_ items: [String: ([String: Any], Date)], now: Date, zh: Bool, companion: String? = nil) -> String {
        var parts: [String] = []
        for kind in kinds {
            guard let (d, at) = items[kind] else { continue }
            let s: String
            switch kind {
            case "cycle": s = cycle(d, zh: zh, companion: companion)
            case "weather": s = weather(d)
            case "place": s = place(d, ago: now.timeIntervalSince(at), zh: zh)
            case "calendar": s = calendar(d, now: now, zh: zh)
            default: s = health(d, zh: zh)
            }
            if !s.isEmpty { parts.append(s) }
        }
        guard !parts.isEmpty else { return "" }
        return zh ? "〔TA 那边〕" + parts.joined(separator: "；") : "〔Their side〕" + parts.joined(separator: "; ")
    }

    private static func ago(_ t: TimeInterval, zh: Bool) -> String {
        let m = max(0, Int(t / 60))
        if zh { return m < 2 ? "刚刚" : m < 60 ? "\(m) 分钟前" : "\(m / 60) 小时前" }
        return m < 2 ? "just now" : m < 60 ? "\(m) min ago" : "\(m / 60) h ago"
    }

    private static func weather(_ d: [String: Any]) -> String {
        let t = (d["temp_c"] as? Double).map { "\(Int($0.rounded()))°C" } ?? ""
        return [d["place"] as? String ?? "", t, d["desc"] as? String ?? ""]
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static func place(_ d: [String: Any], ago t: TimeInterval, zh: Bool) -> String {
        if d["at_home"] as? Bool ?? false { return zh ? "在家" : "at home" }
        let name = (d["name"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return "" }
        let km = (d["km"] as? Double).flatMap { $0 >= 1 ? Int($0.rounded()) : nil }
        if zh { return "在 \(name)（\(km.map { "离家 \($0) 公里，" } ?? "")\(ago(t, zh: true))）" }
        return "at \(name) (\(km.map { "\($0) km from home, " } ?? "")\(ago(t, zh: false)))"
    }

    private static func calendar(_ d: [String: Any], now: Date, zh: Bool) -> String {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let iso = ISO8601DateFormatter()
        let hm = DateFormatter(); hm.dateFormat = "HH:mm"
        var out: [String] = []
        for ev in (d["events"] as? [[String: Any]] ?? []).prefix(5) {
            guard let start = (ev["start"] as? String).flatMap(iso.date(from:)) else { continue }
            let day = cal.startOfDay(for: start)
            guard day >= today else { continue }
            let n = cal.dateComponents([.day], from: today, to: day).day ?? 0
            let word: String
            if zh { word = [0: "今天", 1: "明天", 2: "后天"][n] ?? "\(cal.component(.month, from: start))月\(cal.component(.day, from: start))日" }
            else { word = [0: "today", 1: "tomorrow"][n] ?? start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) }
            let title = String((ev["title"] as? String ?? "").trimmingCharacters(in: .whitespaces).prefix(40))
            out.append((ev["all_day"] as? Bool ?? false) ? "\(word) \(title)" : "\(word) \(hm.string(from: start)) \(title)")
        }
        return out.joined(separator: zh ? "；" : "; ")
    }

    /// 经期（11-15 Aporia）：手机算好的一句；只给主联系人时别的联系人不给。照 server context_line._cycle
    private static func cycle(_ d: [String: Any], zh: Bool, companion: String?) -> String {
        if (d["share"] as? String) == "main", companion == nil || (d["companion_id"] as? String)?.lowercased() != companion?.lowercased() { return "" }
        return String(((zh ? d["text_zh"] : d["text_en"]) as? String ?? "").prefix(200))
    }

    private static func health(_ d: [String: Any], zh: Bool) -> String {
        var bits: [String] = []
        if let steps = d["steps"] as? Int {
            let n = steps.formatted(.number)
            bits.append(zh ? "今天走了 \(n) 步" : "\(n) steps today")
        }
        if let h = d["sleep_h"] as? Double, h > 0 {
            let v = (h * 2).rounded() / 2           // 半小时一档：5.5 小时
            let s = v == v.rounded() ? "\(Int(v))" : "\(v)"
            bits.append(zh ? "昨晚睡了 \(s) 小时" : "slept \(s) h last night")
        }
        return bits.joined(separator: zh ? "，" : ", ")
    }
}
#endif
