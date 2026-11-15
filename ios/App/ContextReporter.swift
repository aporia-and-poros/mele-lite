import CoreLocation
import EventKit
import HealthKit
import SwiftUI
import MediaPlayer
import MusicKit
import WeatherKit

/// TA 那边（第三块第 4 步，照之前自用的 App EnvironmentReporter / WhereaboutsReporter）：
/// 天气、在哪、日程、步数和睡眠，app 回前台时报给服务器（PUT /me/context/{kind}），Lumi 们在〔TA 那边〕里看得到。
/// 每样在 Me 里单独打开（默认关），打开那一下才问系统权限。只在 app 打开时看，不在后台盯。
@MainActor
final class ContextReporter: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = ContextReporter()
    static let homeRadius: CLLocationDistance = 300

    enum Kind: String, CaseIterable { case weather, place, calendar, health }

    @Published var enabled: Set<Kind> = Set((UserDefaults.standard.stringArray(forKey: "ctxEnabled") ?? []).compactMap(Kind.init))
    @Published private(set) var homeSet = UserDefaults.standard.object(forKey: "homeLat") != nil
    @Published private(set) var lastPlace = ""

    var api: APIClient?
    private let location = CLLocationManager()
    private let events = EKEventStore()
    private let health = HKHealthStore()
    private var locationWaiters: [CheckedContinuation<CLLocation?, Never>] = []
    private var activeTimer: Timer?

    private override init() {
        super.init()
        location.delegate = self
        location.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    // MARK: 开关

    func set(_ kind: Kind, on: Bool) async {
        if on {
            enabled.insert(kind)
            await requestPermission(kind)
            await report(kind, force: true)
        } else {
            enabled.remove(kind)
        }
        UserDefaults.standard.set(enabled.map(\.rawValue), forKey: "ctxEnabled")
    }

    private func requestPermission(_ kind: Kind) async {
        switch kind {
        case .weather, .place:
            if location.authorizationStatus == .notDetermined { location.requestWhenInUseAuthorization() }
        case .calendar:
            _ = try? await events.requestFullAccessToEvents()
        case .health:
            guard HKHealthStore.isHealthDataAvailable() else { return }
            let types: Set<HKObjectType> = [HKQuantityType(.stepCount), HKCategoryType(.sleepAnalysis)]
            try? await health.requestAuthorization(toShare: [], read: types)
        }
    }

    // MARK: 回前台

    /// app 回前台：报一声「在」、各样该报的报一遍，之后每 3 分钟报一次「在」
    func foreground() {
        Task { await ping() }
        activeTimer?.invalidate()
        activeTimer = Timer.scheduledTimer(withTimeInterval: 180, repeats: true) { _ in
            Task { @MainActor in await ContextReporter.shared.ping() }
        }
        Task { for k in Kind.allCases where enabled.contains(k) { await report(k, force: false) } }
        reportMusicNow()
        Task { await CycleStore.shared.importHealth(); await CycleStore.shared.report(); await CycleStore.shared.reschedule() }   // 经期（11-15）
    }

    /// 报一次「音乐」在放什么、放到第几秒（连了 Apple Music、授权过的才报；09-30）。
    /// 回前台时报；发消息前也报（onlyPlaying：只在放着的时候）——耳朵按这个位置算 Lumi 此刻听到哪句。
    func reportMusicNow(onlyPlaying: Bool = false) {
        if Lite.on {                                 // Lite：读系统播放器（不用开发者凭证）
            let p = MPMusicPlayerController.systemMusicPlayer
            guard MusicAuthorization.currentStatus == .authorized, let it = p.nowPlayingItem, let title = it.title else { return }
            let playing = p.playbackState == .playing
            if onlyPlaying && !playing { return }
            Task { try? await api?.send("POST", "music/now", json: ["song_id": it.playbackStoreID, "name": title,
                                                                      "artist": it.artist ?? "", "playing": playing,
                                                                      "position_s": p.currentPlaybackTime,
                                                                      "duration_s": it.playbackDuration]) }
            return
        }
        guard MusicAuthorization.currentStatus == .authorized, MusicStore.shared.appleLinked,
              case .song(let s) = SystemMusicPlayer.shared.queue.currentEntry?.item else { return }
        let playing = SystemMusicPlayer.shared.state.playbackStatus == .playing
        if onlyPlaying && !playing { return }
        let position = SystemMusicPlayer.shared.playbackTime
        Task { try? await api?.send("POST", "music/now", json: ["song_id": s.id.rawValue, "name": s.title,
                                                                  "artist": s.artistName, "playing": playing,
                                                                  "position_s": position]) }
    }

    func background() {
        activeTimer?.invalidate()
        activeTimer = nil
    }

    private func ping() async {
        try? await api?.send("POST", "me/active")
    }

    private func put(_ kind: Kind, _ body: [String: Any]) async {
        try? await api?.send("PUT", "me/context/\(kind.rawValue)", json: body)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "ctxSent-\(kind.rawValue)")
    }

    /// 同一样多久报一次：天气一小时，别的每次回前台都报（便宜）
    private func due(_ kind: Kind) -> Bool {
        let last = UserDefaults.standard.double(forKey: "ctxSent-\(kind.rawValue)")
        let gap: TimeInterval = kind == .weather ? 3600 : kind == .calendar ? 1800 : 0
        return Date().timeIntervalSince1970 - last >= gap
    }

    func report(_ kind: Kind, force: Bool) async {
        guard enabled.contains(kind), force || due(kind) else { return }
        switch kind {
        case .weather: await reportWeather()
        case .place: await reportPlace()
        case .calendar: await reportCalendar()
        case .health: await reportHealth()
        }
    }

    // MARK: 位置（天气和 whereabouts 共用）

    private var locationAllowed: Bool {
        location.authorizationStatus == .authorizedWhenInUse || location.authorizationStatus == .authorizedAlways
    }

    private func currentLocation() async -> CLLocation? {
        guard locationAllowed else { return nil }
        return await withCheckedContinuation { c in
            locationWaiters.append(c)
            if locationWaiters.count == 1 { location.requestLocation() }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in self.finishLocation(locations.last) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.finishLocation(nil) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            guard self.locationAllowed else { return }
            for k in [Kind.weather, .place] where self.enabled.contains(k) { await self.report(k, force: true) }
        }
    }

    private func finishLocation(_ loc: CLLocation?) {
        let waiters = locationWaiters
        locationWaiters = []
        waiters.forEach { $0.resume(returning: loc) }
    }

    // MARK: 天气

    private func reportWeather() async {
        guard let here = await currentLocation(),
              let w = try? await WeatherService.shared.weather(for: here, including: .current) else { return }
        let city = (try? await CLGeocoder().reverseGeocodeLocation(here).first)?.locality ?? ""
        await put(.weather, ["place": city, "temp_c": w.temperature.converted(to: .celsius).value,
                             "desc": w.condition.description])
    }

    // MARK: whereabouts（照之前自用的 App：离家 300 米以外才报地名，回家报一声）

    func setHomeHere() async {
        await requestPermission(.place)
        guard let here = await currentLocation() else { return }
        UserDefaults.standard.set(here.coordinate.latitude, forKey: "homeLat")
        UserDefaults.standard.set(here.coordinate.longitude, forKey: "homeLon")
        homeSet = true
        await put(.place, ["at_home": true])
        lastPlace = String(localized: "家")
    }

    func clearHome() {
        UserDefaults.standard.removeObject(forKey: "homeLat")
        UserDefaults.standard.removeObject(forKey: "homeLon")
        homeSet = false
    }

    private func reportPlace() async {
        guard homeSet, let here = await currentLocation() else { return }
        let home = CLLocation(latitude: UserDefaults.standard.double(forKey: "homeLat"),
                              longitude: UserDefaults.standard.double(forKey: "homeLon"))
        let meters = here.distance(from: home)
        if meters <= Self.homeRadius {
            lastPlace = String(localized: "家")
            await put(.place, ["at_home": true])
            return
        }
        let mark = try? await CLGeocoder().reverseGeocodeLocation(here).first
        let poi = mark?.areasOfInterest?.first ?? ""
        let name = mark?.name ?? ""
        let area = mark?.subLocality ?? mark?.locality ?? ""
        let place = !poi.isEmpty ? poi : (!name.isEmpty ? name : area)
        lastPlace = place
        await put(.place, ["at_home": false, "name": place, "km": (meters / 100).rounded() / 10])
    }

    // MARK: 日历（接下来 3 天，只报标题和时间）

    private func reportCalendar() async {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return }
        let now = Date()
        let until = Calendar.current.date(byAdding: .day, value: 3, to: Calendar.current.startOfDay(for: now)) ?? now
        let found = PhoneCalendar.events(events, from: now, to: until)
            .sorted { $0.startDate < $1.startDate }
            .prefix(8)
        let iso = ISO8601DateFormatter()
        await put(.calendar, ["events": found.map { ["title": $0.title ?? "", "start": iso.string(from: $0.startDate),
                                                     "all_day": $0.isAllDay] }])
    }

    // MARK: 步数和睡眠

    /// 她这句话在问步数 / 睡眠 / 天气 / 在哪 / 日程（10-13 内测：聊到一半问「我昨晚睡了多久」，
    /// 它手上没有这行，就编了句「防火墙很严密」）——发出去之前当场重读一遍，这一轮一定给它
    nonisolated static let askPattern = try! NSRegularExpression(
        pattern: "步数|走了多少|走路|睡|觉|失眠|天气|下雨|日程|行程|steps?|walk|sleep|slept|weather|calendar|schedule",
        options: [.caseInsensitive])

    nonisolated static func asks(_ text: String) -> Bool {
        askPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    func refreshForQuestion(_ text: String) async {
        guard Self.asks(text) else { return }
        for k in Kind.allCases where enabled.contains(k) { await report(k, force: true) }
    }

    private func reportHealth() async {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        // 每次读之前问一遍（10-13）：已经答过的不会再弹；早先只问过步数、没问过睡眠的这次补问。
        // 读权限被拒 iOS 不告诉 app，只会读出空——所以拒了的那样就是没有，不报
        let types: Set<HKObjectType> = [HKQuantityType(.stepCount), HKCategoryType(.sleepAnalysis)]
        try? await health.requestAuthorization(toShare: [], read: types)
        let cal = Calendar.current
        let now = Date()
        let steps = await sum(.stepCount, from: cal.startOfDay(for: now), to: now)
        // 昨晚：昨天 18:00 到今天 12:00 之间「睡着」的时长
        let from = cal.date(byAdding: .hour, value: -6, to: cal.startOfDay(for: now)) ?? now
        let to = cal.date(byAdding: .hour, value: 12, to: cal.startOfDay(for: now)) ?? now
        let sleep = await sleepHours(from: from, to: min(to, now))
        var body: [String: Any] = [:]
        if let steps { body["steps"] = Int(steps) }
        if sleep > 0 { body["sleep_h"] = (sleep * 10).rounded() / 10 }
        if !body.isEmpty { await put(.health, body) }
    }

    private func sum(_ id: HKQuantityTypeIdentifier, from: Date, to: Date) async -> Double? {
        await withCheckedContinuation { c in
            let q = HKStatisticsQuery(quantityType: HKQuantityType(id),
                                      quantitySamplePredicate: HKQuery.predicateForSamples(withStart: from, end: to),
                                      options: .cumulativeSum) { _, stats, _ in
                c.resume(returning: stats?.sumQuantity()?.doubleValue(for: .count()))
            }
            health.execute(q)
        }
    }

    private func sleepHours(from: Date, to: Date) async -> Double {
        await withCheckedContinuation { c in
            let asleep: Set<Int> = [HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
                                    HKCategoryValueSleepAnalysis.asleepCore.rawValue,
                                    HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
                                    HKCategoryValueSleepAnalysis.asleepREM.rawValue]
            let q = HKSampleQuery(sampleType: HKCategoryType(.sleepAnalysis),
                                  predicate: HKQuery.predicateForSamples(withStart: from, end: to),
                                  limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, _ in
                // 手表和手机可能各记一份：按时间合并重叠的段再加
                let spans = (samples as? [HKCategorySample] ?? []).filter { asleep.contains($0.value) }
                    .map { ($0.startDate, $0.endDate) }.sorted { $0.0 < $1.0 }
                var total: TimeInterval = 0
                var cur: (Date, Date)?
                for s in spans {
                    if let c0 = cur, s.0 <= c0.1 { cur = (c0.0, max(c0.1, s.1)) }
                    else { if let c0 = cur { total += c0.1.timeIntervalSince(c0.0) }; cur = s }
                }
                if let c0 = cur { total += c0.1.timeIntervalSince(c0.0) }
                // 没戴手表的只有「在床上」（iPhone 睡眠计划记的就是这个，10-13 内测读不到睡眠的真因之一）：
                // 一段「睡着」都没有时，退回用在床上的时长
                if total == 0 {
                    let bed = (samples as? [HKCategorySample] ?? [])
                        .filter { $0.value == HKCategoryValueSleepAnalysis.inBed.rawValue }
                        .map { ($0.startDate, $0.endDate) }.sorted { $0.0 < $1.0 }
                    var cur2: (Date, Date)?
                    for s in bed {
                        if let c0 = cur2, s.0 <= c0.1 { cur2 = (c0.0, max(c0.1, s.1)) }
                        else { if let c0 = cur2 { total += c0.1.timeIntervalSince(c0.0) }; cur2 = s }
                    }
                    if let c0 = cur2 { total += c0.1.timeIntervalSince(c0.0) }
                }
                c.resume(returning: total / 3600)
            }
            health.execute(q)
        }
    }
}
