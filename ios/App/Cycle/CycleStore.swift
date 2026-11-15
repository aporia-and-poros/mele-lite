import Foundation
import HealthKit
import UserNotifications

// MARK: - 经期（11-15 Aporia：Mele 最后一个功能，做完上架）
//
// 记录存在手机上（Lite 本机和连 Host 一样），跟苹果健康双向同步流量；症状、心情只在 Mele 里。
// 预测：最近 6 次周期取平均，不够两次按 28 / 5 天；不算易孕期（她定的）。
// TA 知道：算好一句交给〔TA 那边〕（PUT me/context/cycle，Host 和 Lite 管家都认），变了才给；能关、能只给主联系人。
// 提醒：快来前几天本机通知，不经过服务器。

struct CycleDay: Codable, Equatable {
    /// 流量：nil = 没来；1 少 · 2 中 · 3 多 · 4 很多
    var flow: Int?
    var symptoms: [String] = []
    var mood: String?
    var note: String = ""
    /// 从苹果健康读进来的（没在 Mele 里改过）
    var fromHealth: Bool = false

    var isEmpty: Bool { flow == nil && symptoms.isEmpty && mood == nil && note.isEmpty }
}

struct CycleSettings: Codable, Equatable {
    /// 手动定的周期 / 经期天数（nil = 按记录自己算）
    var cycleLength: Int?
    var periodLength: Int?
    /// 提前几天提醒（0 = 不提醒）
    var remindDays: Int = 2
    var healthSync: Bool = false
    /// TA 知道：all 所有联系人 · main 只给主联系人 · off 关
    var share: String = "all"
}

struct CyclePeriod: Equatable {
    let start: Date
    let end: Date          // 最后一天（含）
    var days: Int { Calendar.current.dateComponents([.day], from: start, to: end).day! + 1 }
}

enum CycleStatus: Equatable {
    case none                                   // 一条记录都没有
    case inPeriod(day: Int)                     // 经期第几天
    case upcoming(days: Int)                    // 还有几天来（0 = 今天预计来）
    case late(days: Int)                        // 推迟了几天
}

enum CycleCatalog {
    static let flows: [(Int, String)] = [(1, String(localized: "少")), (2, String(localized: "中")),
                                         (3, String(localized: "多")), (4, String(localized: "很多"))]
    static let symptoms: [(id: String, zh: String, en: String, symbol: String)] = [
        ("cramps", "痛经", "cramps", "bolt.heart"),
        ("backache", "腰酸", "back pain", "figure.stand"),
        ("headache", "头痛", "headache", "brain.head.profile"),
        ("acne", "长痘", "breakouts", "circle.dotted"),
        ("breasts", "胸胀", "sore breasts", "heart"),
        ("bloating", "肚子胀", "bloating", "circle.circle"),
        ("tired", "累", "tired", "battery.25percent"),
        ("cravings", "想吃东西", "cravings", "fork.knife"),
    ]
    static let moods: [(id: String, zh: String, en: String, emoji: String)] = [
        ("ok", "还好", "okay", "🙂"), ("happy", "开心", "happy", "😊"), ("annoyed", "烦", "irritated", "😤"),
        ("low", "低落", "low", "😔"), ("teary", "想哭", "teary", "🥲"), ("angry", "易怒", "on edge", "😠"),
    ]
    static func flowZh(_ f: Int) -> String { ["", "少", "中", "多", "很多"][max(0, min(4, f))] }
    static func flowEn(_ f: Int) -> String { ["", "light", "medium", "heavy", "very heavy"][max(0, min(4, f))] }
}

@MainActor
final class CycleStore: ObservableObject {
    static let shared = CycleStore()

    @Published private(set) var days: [String: CycleDay] = [:]
    @Published var settings = CycleSettings() { didSet { if settings != oldValue { saveSettings(); afterChange() } } }
    /// 手机那会儿的主联系人（只给主联系人看时用；页面打开时 AppModel 递进来）
    var primaryCompanionID: String? {
        get { UserDefaults.standard.string(forKey: "cycle.primary") }
        set { UserDefaults.standard.set(newValue, forKey: "cycle.primary") }
    }

    private let health = HKHealthStore()
    private let cal = Calendar.current
    private static let defaultCycle = 28, defaultPeriod = 5

    private static var dir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private static var daysFile: URL { dir.appendingPathComponent("cycle-days.json") }
    private static let settingsKey = "cycle.settings"

    private init() {
        if let d = try? Data(contentsOf: Self.daysFile), let v = try? JSONDecoder().decode([String: CycleDay].self, from: d) {
            days = v
        }
        if let d = UserDefaults.standard.data(forKey: Self.settingsKey), let v = try? JSONDecoder().decode(CycleSettings.self, from: d) {
            settings = v
        }
    }

    // MARK: 日期

    static let keyFormat: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    func key(_ d: Date) -> String { Self.keyFormat.string(from: d) }
    func date(_ k: String) -> Date? { Self.keyFormat.date(from: k) }
    var today: Date { cal.startOfDay(for: Date()) }

    func day(_ d: Date) -> CycleDay { days[key(d)] ?? CycleDay() }
    func isPeriod(_ d: Date) -> Bool { (days[key(d)]?.flow ?? 0) > 0 }

    // MARK: 改

    func set(_ d: Date, _ value: CycleDay) {
        let k = key(cal.startOfDay(for: d))
        let old = days[k]
        var v = value
        v.fromHealth = false
        if v.isEmpty { days.removeValue(forKey: k) } else { days[k] = v }
        saveDays()
        if settings.healthSync, old?.flow != v.flow { Task { await writeHealth(day: cal.startOfDay(for: d), flow: v.flow) } }
        afterChange()
    }

    /// 「来了」：没记过流量的给个「中」；「没来」：去掉流量，症状心情留着
    func togglePeriod(_ d: Date) {
        var v = day(d)
        v.flow = (v.flow ?? 0) > 0 ? nil : 2
        set(d, v)
    }

    private func saveDays() {
        if let d = try? JSONEncoder().encode(days) { try? d.write(to: Self.daysFile, options: .atomic) }
    }

    private func saveSettings() {
        if let d = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(d, forKey: Self.settingsKey) }
    }

    private func afterChange() {
        Task { await reschedule() }
        Task { await report() }
    }

    // MARK: 算

    /// 连着的经期日子并成一次（中间空一天也算同一次）
    var periods: [CyclePeriod] {
        let dates = days.filter { ($0.value.flow ?? 0) > 0 }.keys.compactMap(date).sorted()
        var out: [CyclePeriod] = []
        for d in dates {
            if let last = out.last, let gap = cal.dateComponents([.day], from: last.end, to: d).day, gap <= 2 {
                out[out.count - 1] = CyclePeriod(start: last.start, end: d)
            } else {
                out.append(CyclePeriod(start: d, end: d))
            }
        }
        return out
    }

    /// 平均周期（最近 6 次，只认 15～60 天的间隔），记录不够就 28
    var averageCycle: Int {
        if let m = settings.cycleLength { return m }
        let starts = periods.map(\.start)
        let gaps = zip(starts, starts.dropFirst()).compactMap { cal.dateComponents([.day], from: $0, to: $1).day }
            .filter { (15...60).contains($0) }.suffix(6)
        return gaps.isEmpty ? Self.defaultCycle : Int((Double(gaps.reduce(0, +)) / Double(gaps.count)).rounded())
    }

    var averagePeriod: Int {
        if let m = settings.periodLength { return m }
        // 还在进行的那次不算（天数还没定）
        let done = periods.filter { cal.dateComponents([.day], from: $0.end, to: today).day ?? 0 > 1 }.suffix(6)
        return done.isEmpty ? Self.defaultPeriod : max(2, Int((Double(done.map(\.days).reduce(0, +)) / Double(done.count)).rounded()))
    }

    var hasHistory: Bool { !periods.isEmpty }

    /// 下一次预计哪天来（最近一次开始 + 平均周期；早就过了就一直往后推）
    var nextStart: Date? {
        guard let last = periods.last else { return nil }
        guard let next = cal.date(byAdding: .day, value: averageCycle, to: last.start) else { return nil }
        return next
    }

    var status: CycleStatus {
        guard let last = periods.last else { return .none }
        let sinceEnd = cal.dateComponents([.day], from: last.end, to: today).day ?? 99
        if sinceEnd <= 1, let n = cal.dateComponents([.day], from: last.start, to: today).day, n >= 0, n < 12 {
            // 今天或昨天还记着来、离开始不到 12 天：算在经期里
            if sinceEnd == 0 || n + 1 <= averagePeriod { return .inPeriod(day: n + 1) }
        }
        guard let next = nextStart, let d = cal.dateComponents([.day], from: today, to: next).day else { return .none }
        return d >= 0 ? .upcoming(days: d) : .late(days: -d)
    }

    /// 日历上画虚线圈的预测日子：接下来三次
    var predictedDays: Set<String> {
        guard let next = nextStart else { return [] }
        var out = Set<String>()
        // 正在来：这一次剩下的几天也画虚线圈
        if case .inPeriod(let n) = status, n < averagePeriod, let start = periods.last?.start {
            for j in n..<averagePeriod {
                if let d = cal.date(byAdding: .day, value: j, to: start), d > today, !isPeriod(d) { out.insert(key(d)) }
            }
        }
        for i in 0..<3 {
            guard let s = cal.date(byAdding: .day, value: averageCycle * i, to: next) else { continue }
            for j in 0..<averagePeriod {
                if let d = cal.date(byAdding: .day, value: j, to: s), d >= today, !isPeriod(d) { out.insert(key(d)) }
            }
        }
        return out
    }

    // MARK: TA 知道

    /// 给〔TA 那边〕的一句：经期里、快来了（7 天内）、推迟了才说；别的时候空着
    func contextLines() -> (zh: String, en: String, key: String) {
        switch status {
        case .inPeriod(let n):
            let t = day(today)
            let y = cal.date(byAdding: .day, value: -1, to: today).map(day) ?? CycleDay()
            let flow = t.flow ?? y.flow ?? 2
            let sym = CycleCatalog.symptoms.filter { t.symptoms.contains($0.id) }
            let mood = CycleCatalog.moods.first { $0.id == t.mood }
            var zh = "经期第 \(n) 天，流量\(CycleCatalog.flowZh(flow))"
            var en = "day \(n) of her period, \(CycleCatalog.flowEn(flow)) flow"
            if !sym.isEmpty { zh += "，" + sym.map(\.zh).joined(separator: "、"); en += ", " + sym.map(\.en).joined(separator: ", ") }
            if let mood { zh += "，心情\(mood.zh)"; en += ", feeling \(mood.en)" }
            return (zh, en, "in|\(n)|\(flow)|\(t.symptoms.sorted().joined(separator: ","))|\(t.mood ?? "")")
        case .upcoming(let d) where d <= 7:
            let zh = d == 0 ? "经期预计今天来" : d == 1 ? "经期预计明天来" : "经期预计 \(d) 天后来"
            let en = d == 0 ? "her period is due today" : d == 1 ? "her period is due tomorrow" : "her period is due in \(d) days"
            return (zh, en, "up|\(d)")
        case .late(let d) where d <= 14:
            return ("经期推迟了 \(d) 天", "her period is \(d) day\(d == 1 ? "" : "s") late", "late|\(d)")
        default:
            return ("", "", "")
        }
    }

    /// 报给 TA 那边（关了就报一句空的，盖掉旧的）
    func report() async {
        guard let api = ContextReporter.shared.api else { return }
        let lines: (zh: String, en: String, key: String) = settings.share == "off" ? ("", "", "off") : contextLines()
        var body: [String: Any] = ["text_zh": lines.zh, "text_en": lines.en, "key": lines.key, "share": settings.share]
        if let id = primaryCompanionID { body["companion_id"] = id }
        try? await api.send("PUT", "me/context/cycle", json: body)
    }

    // MARK: 提醒

    static let remindID = "cycle.remind"

    func reschedule() async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.remindID])
        guard settings.remindDays > 0, let next = nextStart,
              let fire = cal.date(byAdding: .day, value: -settings.remindDays, to: next),
              let at = cal.date(bySettingHour: 9, minute: 0, second: 0, of: fire), at > Date() else { return }
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        guard granted else { return }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "经期快到了")
        content.body = settings.remindDays == 1 ? String(localized: "预计明天来，记得带上卫生巾。")
            : String(localized: "预计 \(settings.remindDays) 天后来，记得带上卫生巾。")
        content.sound = .default
        let comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: at)
        let req = UNNotificationRequest(identifier: Self.remindID, content: content,
                                        trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false))
        try? await center.add(req)
    }

    // MARK: 苹果健康

    private var flowType: HKCategoryType { HKCategoryType(.menstrualFlow) }

    /// 打开同步：要读写「月经」的权限，然后读一遍
    func enableHealth() async -> Bool {
        guard HKHealthStore.isHealthDataAvailable() else { return false }
        do {
            try await health.requestAuthorization(toShare: [flowType], read: [flowType])
        } catch { return false }
        settings.healthSync = true
        await importHealth()
        return true
    }

    /// 健康里记过的经期读进来：Mele 里那天没记过的才补（Mele 里改过的以 Mele 为准）
    func importHealth() async {
        guard settings.healthSync, HKHealthStore.isHealthDataAvailable() else { return }
        let from = cal.date(byAdding: .day, value: -420, to: today)!
        let pred = HKQuery.predicateForSamples(withStart: from, end: Date().addingTimeInterval(86400))
        let samples: [HKCategorySample] = await withCheckedContinuation { cont in
            let q = HKSampleQuery(sampleType: flowType, predicate: pred, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, s, _ in
                cont.resume(returning: (s as? [HKCategorySample]) ?? [])
            }
            health.execute(q)
        }
        var changed = false
        for s in samples {
            guard let v = HKCategoryValueMenstrualFlow(rawValue: s.value), v != .none else { continue }
            let flow: Int = v == .light ? 1 : v == .heavy ? 3 : 2
            var d = cal.startOfDay(for: s.startDate)
            let last = cal.startOfDay(for: s.endDate.addingTimeInterval(-1))
            while d <= last {
                let k = key(d)
                if days[k] == nil || (days[k]?.fromHealth == true && days[k]?.flow != flow) {
                    var e = days[k] ?? CycleDay()
                    e.flow = flow
                    e.fromHealth = true
                    days[k] = e
                    changed = true
                }
                d = cal.date(byAdding: .day, value: 1, to: d)!
            }
        }
        if changed {
            saveDays()
            afterChange()
        }
    }

    /// Mele 里改了某天的流量：先删掉 Mele 以前写进健康的那天，再写新的（没来就只删）
    private func writeHealth(day: Date, flow: Int?) async {
        guard HKHealthStore.isHealthDataAvailable(), health.authorizationStatus(for: flowType) == .sharingAuthorized else { return }
        let next = cal.date(byAdding: .day, value: 1, to: day)!
        let pred = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForSamples(withStart: day, end: next, options: .strictStartDate),
            HKQuery.predicateForObjects(from: HKSource.default()),
        ])
        _ = try? await health.deleteObjects(of: flowType, predicate: pred)
        guard let flow, flow > 0 else { return }
        let value: HKCategoryValueMenstrualFlow = flow == 1 ? .light : flow >= 3 ? .heavy : .medium
        let prev = cal.date(byAdding: .day, value: -1, to: day)!
        let isStart = !isPeriod(prev) && !isPeriod(cal.date(byAdding: .day, value: -2, to: day)!)
        let sample = HKCategorySample(type: flowType, value: value.rawValue, start: day, end: next,
                                      metadata: [HKMetadataKeyMenstrualCycleStart: isStart])
        try? await health.save(sample)
    }
}
