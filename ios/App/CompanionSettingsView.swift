import UniformTypeIdentifiers
import PhotosUI
import SwiftUI
#if LITE
import MeleLiteCore
#endif

// MARK: - TA 的设定（第二块第 10 步）
//
// 外层是常用的，里层「高级」多点一下。每项一句人话说明。改了就存（停手 0.6 秒后只发改过的那几项）。
// 设置的键很多，这里不一个个定类型：拿服务器回来的 JSON 字典，按键读写（键名跟 server/brain/settings.py、persona.py 一一对应）。

@MainActor
final class CompanionSettingsStore: ObservableObject {
    let api: APIClient
    let companionID: UUID
    @Published var persona: [String: Any] = [:]
    @Published var settings: [String: Any] = [:]
    @Published var keyID: String?
    @Published var loaded = false
    @Published var error: String?
    @Published var keys: [KeyDTO] = []
    @Published var traitsCatalog: [TraitDTO] = []
    @Published var estimate: EstimateDTO?
    @Published var clocks: [ClockDTO] = []
    @Published var dates: [FarDateDTO] = []

    private var pendingPersona: [String: Any] = [:]
    private var pendingSettings: [String: Any] = [:]
    private var saveTask: Task<Void, Never>?

    init(api: APIClient, companionID: UUID) {
        self.api = api
        self.companionID = companionID
    }

    var path: String { "companions/\(companionID.lowercased)" }

    func load() async {
        do {
            let c = try await api.raw("GET", path) as? [String: Any] ?? [:]
            persona = c["persona"] as? [String: Any] ?? [:]
            settings = c["settings"] as? [String: Any] ?? [:]
            keyID = c["key_id"] as? String
            keys = (try? await api.call("GET", "keys")) ?? []
            traitsCatalog = (try? await api.call("GET", "traits")) ?? []
            clocks = (try? await api.call("GET", "\(path)/clocks")) ?? []
            dates = (try? await api.call("GET", "\(path)/dates")) ?? []
            await loadEstimate()
            loaded = true
        } catch {
            self.error = error.localizedDescription
        }
    }

    func loadEstimate() async {
        estimate = try? await api.call("GET", "\(path)/patrol/estimate")
    }

    // 按键读写
    func s<T>(_ key: String, _ fallback: T) -> Binding<T> {
        Binding(get: { (self.settings[key] as? T) ?? fallback },
                set: { v in self.settings[key] = v; self.pendingSettings[key] = v; self.scheduleSave() })
    }

    func p<T>(_ key: String, _ fallback: T) -> Binding<T> {
        Binding(get: { (self.persona[key] as? T) ?? fallback },
                set: { v in self.persona[key] = v; self.pendingPersona[key] = v; self.scheduleSave() })
    }

    /// 可以为空的数字（null = 跟默认）
    func optionalInt(_ key: String) -> Binding<Int?> {
        Binding(get: { self.settings[key] as? Int },
                set: { v in
                    self.settings[key] = v ?? NSNull()
                    self.pendingSettings[key] = v ?? NSNull()
                    self.scheduleSave()
                })
    }

    func setNow(settings patch: [String: Any]) {
        for (k, v) in patch { settings[k] = v; pendingSettings[k] = v }
        scheduleSave()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(600))
            if Task.isCancelled { return }
            await flush()
        }
    }

    func flush() async {
        var body: [String: Any] = [:]
        if !pendingSettings.isEmpty { body["settings"] = pendingSettings }
        if !pendingPersona.isEmpty { body["persona"] = pendingPersona }
        guard !body.isEmpty else { return }
        let touchedPatrol = pendingSettings.keys.contains { ["patrol_level", "sleep_from", "sleep_to", "patrol_overrides"].contains($0) }
        pendingSettings = [:]
        pendingPersona = [:]
        do {
            _ = try await api.raw("PATCH", path, json: body)
            error = nil
            if touchedPatrol { await loadEstimate() }
        } catch {
            self.error = "没存上：\(error.localizedDescription)"
            await load()            // 回到服务器上的真值
        }
    }

    func useKey(_ id: String?) async {
        do {
            _ = try await api.raw("PATCH", path, json: ["key_id": id.map { $0 as Any } ?? NSNull()])
            keyID = id
            await loadEstimate()
        } catch { self.error = error.localizedDescription }
    }

    func syncAdvanced() async -> Int? {
        await flush()
        struct Out: Decodable { let copied: Int }
        return (try? await api.call("POST", "\(path)/sync-advanced", as: Out.self))?.copied
    }

    // 钟
    func addClock(shape: String, spec: [String: Any], note: String) async {
        do {
            let c: ClockDTO = try await api.call("POST", "\(path)/clocks", json: ["shape": shape, "spec": spec, "note": note])
            clocks.append(c)
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    // 它记着的事（09-28）
    func saveDate(_ existing: FarDateDTO?, body: [String: Any]) async {
        do {
            if let existing {
                let d: FarDateDTO = try await api.call("PATCH", "dates/\(existing.id)", json: body)
                dates = dates.map { $0.id == d.id ? d : $0 }
            } else {
                let d: FarDateDTO = try await api.call("POST", "\(path)/dates", json: body)
                dates.append(d)
            }
            dates.sort { ($0.day, $0.time) < ($1.day, $1.time) }
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    func deleteDate(_ d: FarDateDTO) async {
        do {
            try await api.send("DELETE", "dates/\(d.id)")
            dates.removeAll { $0.id == d.id }
        } catch { self.error = error.localizedDescription }
    }

    func deleteClock(_ c: ClockDTO) async {
        do {
            try await api.send("DELETE", "clocks/\(c.id)")
            clocks.removeAll { $0.id == c.id }
        } catch { self.error = error.localizedDescription }
    }
}

struct KeyDTO: Decodable, Identifiable, Hashable {
    let id: String
    let provider: String
    let chatModel: String
    let last4: String
    var ledgerModel: String? = nil      // Host 旧的后台模型（10-13）；10-15 起界面不显示，照旧生效
    var chores: [String] = []           // 钥匙串分活（10-15）
    var can: [String] = []
    var drawModel: String = ""
    enum CodingKeys: String, CodingKey {
        case id, provider, last4, chores, can
        case chatModel = "chat_model"; case ledgerModel = "ledger_model"; case drawModel = "draw_model"
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id); provider = try c.decode(String.self, forKey: .provider)
        chatModel = try c.decodeIfPresent(String.self, forKey: .chatModel) ?? ""; last4 = try c.decode(String.self, forKey: .last4)
        ledgerModel = try c.decodeIfPresent(String.self, forKey: .ledgerModel)
        chores = try c.decodeIfPresent([String].self, forKey: .chores) ?? []
        can = try c.decodeIfPresent([String].self, forKey: .can) ?? []
        drawModel = try c.decodeIfPresent(String.self, forKey: .drawModel) ?? ""
    }
}

struct TraitDTO: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let desc: String
}

struct EstimateDTO: Decodable {
    struct Level: Decodable { let wakesPerMonth: Int; let usdPerMonth: Double?
        enum CodingKeys: String, CodingKey { case wakesPerMonth = "wakes_per_month"; case usdPerMonth = "usd_per_month" } }
    let levels: [String: Level]?
}

/// 它记着的事：有日子、还远的（服务器 brain/far_dates.py）
struct FarDateDTO: Decodable, Identifiable, Hashable {
    let id: Int
    let day: String          // YYYY-MM-DD
    let time: String         // HH:MM 或空
    let title: String
    let note: String
    let daysLeft: Int
    enum CodingKeys: String, CodingKey { case id, day, time, title, note; case daysLeft = "days_left" }

    var date: Date? {
        let f = DateFormatter(); f.calendar = Calendar(identifier: .gregorian); f.dateFormat = "yyyy-MM-dd"
        return f.date(from: day)
    }

    /// 12月1日 14:30 · 还有 64 天
    var summary: String {
        let when = (date?.formatted(.dateTime.month().day()) ?? day) + (time.isEmpty ? "" : " \(time)")
        let left: String
        switch daysLeft {
        case ..<0: left = String(localized: "昨天")
        case 0: left = String(localized: "今天")
        case 1: left = String(localized: "明天")
        default: left = String(localized: "还有 \(daysLeft) 天")
        }
        return "\(when) · \(left)"
    }
}

struct ClockDTO: Decodable, Identifiable, Hashable {
    let id: Int
    let shape: String
    let note: String
    let nextAt: Date?
    let spec: [String: SpecValue]
    enum CodingKeys: String, CodingKey { case id, shape, note, spec; case nextAt = "next_at" }

    /// spec 里的值：字符串、数字或数字列表
    enum SpecValue: Decodable, Hashable {
        case s(String), n(Int), list([Int])
        init(from d: Decoder) throws {
            let c = try d.singleValueContainer()
            if let v = try? c.decode(Int.self) { self = .n(v) }
            else if let v = try? c.decode([Int].self) { self = .list(v) }
            else { self = .s((try? c.decode(String.self)) ?? "") }
        }
        var string: String { if case .s(let v) = self { return v }; if case .n(let v) = self { return "\(v)" }; return "" }
    }

    /// 一句人话：每天 08:00 / 9月30日 20:00 一次 / 09:00–21:00 每 2 小时 / 19:00–22:00 随机一次
    var summary: String {
        switch shape {
        case "at": return String(localized: "每天 \(spec["time"]?.string ?? "")")
        case "once":
            if let d = APIClient.parseDate(spec["at"]?.string ?? "") {
                return d.formatted(.dateTime.month().day().hour().minute()) + String(localized: " 一次")
            }
            return String(localized: "一次")
        case "every":
            let m = Int(spec["every_min"]?.string ?? "") ?? 0
            let gap = m % 60 == 0 ? String(localized: "\(m / 60) 小时") : String(localized: "\(m) 分钟")
            return "\(spec["from"]?.string ?? "")–\(spec["to"]?.string ?? "") " + String(localized: "每 \(gap)")
        case "window": return "\(spec["from"]?.string ?? "")–\(spec["to"]?.string ?? "") " + String(localized: "随机一次")
        default: return shape
        }
    }
}

// MARK: - 外层

struct CompanionSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var theme: AppTheme
    @Environment(\.dismiss) private var dismiss
    @StateObject private var store: CompanionSettingsStore
    @State private var picked: PhotosPickerItem?
    @State private var addingClock = false
    @State private var toneOpen = false          // 温暖 / 主动 / 幽默：收在性格下面，点开才出来（10-03）
    @State private var personalityOpen = false   // 性格 / 导入的卡太长默认收起（10-20 内测：设定太长，每次要划很久才到下面的开关）
    @State private var importedOpen = false
    @State private var customRel = ""
    @State private var writingOwn = false       // 出厂性格清空了、正在自己写
    @State private var wechatDraft = ""         // 微信号先在本地编辑，合法才存（10-11）
    @State private var wechatNote: String?
    @State private var readingTxt = false       // 性格从 txt / md 读进来（10-11 内测反馈）
    @State private var txtNote: String?
    @State private var exportingChat = false     // 导出这个 TA 的聊天记录（10-17）
    @State private var chatFile: ChatExport.File?
    @State private var chatExportNote: String?
    let companion: CompanionDTO

    init(companion: CompanionDTO, api: APIClient) {
        self.companion = companion
        _store = StateObject(wrappedValue: CompanionSettingsStore(api: api, companionID: companion.id))
    }

    private var genderWord: String {
        switch store.persona["gender"] as? String {
        case "female": return String(localized: "她")
        case "male": return String(localized: "他")
        default: return "TA"
        }
    }

    var body: some View {
        NavigationStack {
            TilePage {
                if let err = store.error {
                    Text(err).font(Typo.sans(Typo.Size.callout)).foregroundStyle(.red)
                }
                if store.loaded {
                    identity
                    who
                    if !store.traitsCatalog.isEmpty { traits }
                    VoiceSettingsSection(store: store, companionID: companion.id)   // Lite 也能用：填自己的 ElevenLabs key（10-04）
                    bilingual
                    patrol
                    memory
                    key
                    Tile {
                        NavigationLink {
                            AdvancedSettingsView(store: store, companion: companion)
                        } label: {
                            HStack {
                                row("高级", "细读、哨兵、等你说完再回、思考方式、注入……")
                                Spacer()
                                Image(systemName: "chevron.right").font(Typo.icon(13)).foregroundStyle(theme.inkFaint)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .background(AppBackground())
            .navigationTitle(String(localized: "\(genderWord)的设定"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { Task {
                        try? await Task.sleep(for: .milliseconds(450))     // 长文字框停手 0.4 秒才写回（DraftTextEditor），等它写完再存
                        await store.flush(); await model.refresh(); dismiss()
                    } }
                }
            }
        }
        .environment(\.colorScheme, .light)
        .task { await store.load(); customRel = customRelationship }
        .sheet(item: $chatFile) { f in ActivityView(items: [f.url]) }
        .sheet(isPresented: $addingClock) {
            AddClockView { shape, spec, note in Task { await store.addClock(shape: shape, spec: spec, note: note) } }
                .environment(\.colorScheme, .light)
                .presentationDetents([.medium, .large])
        }
        .onChange(of: picked) { _, item in
            Task {
                guard let data = try? await item?.loadTransferable(type: Data.self), let img = UIImage(data: data),
                      let jpg = img.squareCropped(to: 512).jpegData(compressionQuality: 0.88) else { return }
                _ = try? await store.api.uploadAvatar(companion: companion.id, data: jpg)
                await model.refresh()
            }
        }
    }

    private func exportChat() async {
        exportingChat = true
        chatExportNote = nil
        defer { exportingChat = false }
        do {
            let me = model.profile?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let url = try await ChatExport.markdown(api: store.api, companion: companion,
                                                   myName: me.isEmpty ? String(localized: "我") : me)
            chatFile = ChatExport.File(url: url)
        } catch {
            chatExportNote = String(localized: "没导出来：\(error.localizedDescription)")
        }
    }

    // 说明一行
    private func note(_ s: String) -> some View {
        Text(s).font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkFaint)
    }

    private func row(_ title: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(Typo.sans(Typo.Size.body)).foregroundStyle(theme.ink)
            note(sub)
        }
    }

    private var identity: some View {
        Tile {
            HStack(spacing: 14) {
                PhotosPicker(selection: $picked, matching: .images) {
                    CompanionAvatar(companion: model.companion(companion.id) ?? companion, size: 56)
                        .overlay(alignment: .bottomTrailing) {
                            Image(systemName: "camera.fill").font(Typo.icon(10)).foregroundStyle(.white)
                                .padding(5).background(Circle().fill(theme.accentDeep))
                        }
                }
                .buttonStyle(.plain)
                VStack(alignment: .leading, spacing: 4) {
                    TextField("名字", text: store.p("name", companion.name))
                        .font(Typo.sans(Typo.Size.headline, .semibold))
                    note("改了名字 TA 自己会知道")
                }
            }
            // 微信号（Lite，10-04 Aporia）：别人（你的小号）靠它搜到 TA、申请加好友。
            // 10-11 内测反馈「改不了」：以前边打边存，半截号被校验打回、整页回滚把字顶掉。
            // 现在本地先校验，打完、合法才真的存；没打完只给提示不发请求。
            if Lite.local {
                VStack(alignment: .leading, spacing: 6) {
                    row("微信号", wechatNote ?? String(localized: "小号加 TA 好友时搜这个；6～20 位，字母开头"))
                    TextField("比如：lumi_0417", text: $wechatDraft)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .font(Typo.sans(Typo.Size.body))
                        .onChange(of: wechatDraft) { _, v in
                            let w = v.trimmingCharacters(in: .whitespaces)
                            if w == (store.persona["wechat_id"] as? String ?? "") { wechatNote = nil; return }
                            if (6...20).contains(w.count), w.first?.isLetter == true, w.first?.isASCII == true,
                               w.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) {
                                store.p("wechat_id", "").wrappedValue = w
                                wechatNote = nil
                            } else {
                                wechatNote = String(localized: "要 6～20 位，字母开头，只能有字母、数字、_ 和 -（打完合法就自动存）")
                            }
                        }
                        .task(id: store.loaded) {
                            if store.loaded, wechatDraft.isEmpty { wechatDraft = store.persona["wechat_id"] as? String ?? "" }
                        }
                }
            }
        }
    }

    /// txt 读法跟世界书同一个（BOM / UTF-16 / 坏几个字节的 UTF-8 / GBK / Big5）
    static func decodeText(_ data: Data) -> String? {
        #if LITE
        return LoreImport.decodeText(data)
        #else
        if let s = String(data: data, encoding: .utf8) { return s }
        let gb = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        return String(data: data, encoding: String.Encoding(rawValue: gb))
        #endif
    }

    /// 长设定默认收起（10-20 内测）：收着是一个固定高的框，在框里也能滑、能改；点「展开全部」才整段铺开
    @ViewBuilder
    private func foldingEditor(_ text: Binding<String>, open: Binding<Bool>) -> some View {
        let long = text.wrappedValue.count > 240 || text.wrappedValue.split(separator: "\n", omittingEmptySubsequences: false).count > 8
        DraftTextEditor(text: text)
            .font(Typo.sans(Typo.Size.callout))
            .frame(minHeight: 120, maxHeight: long && !open.wrappedValue ? 160 : .infinity)
            .scrollContentBackground(.hidden)
        if long {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { open.wrappedValue.toggle() }
            } label: {
                Label(open.wrappedValue ? "收起" : "展开全部", systemImage: open.wrappedValue ? "chevron.up" : "chevron.down")
            }
            .font(Typo.sans(Typo.Size.callout))
            .foregroundStyle(theme.accentDeep)
        }
    }

    private var who: some View {
        Tile {
            // 出厂性格是底子，看不见（09-29 Aporia）：服务器只说「还是出厂的」，想自己写就清空重写；写空了 = 回到出厂
            if isFactory("personality") && !writingOwn {
                VStack(alignment: .leading, spacing: 8) {
                    row("性格", "TA 出厂就有自己的性格。想照你的想法来，就清空重写")
                    HStack(spacing: 18) {
                        Button("清空，自己写") { writingOwn = true }
                        Button("从 txt / md 读进来") { readingTxt = true }
                    }
                    .font(Typo.sans(Typo.Size.callout, .semibold))
                    .foregroundStyle(theme.accentDeep)
                    if let txtNote { Text(txtNote).font(Typo.sans(Typo.Size.caption)).foregroundStyle(.red.opacity(0.8)) }
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    row("性格", "你写的 TA：是什么样的人、怎么说话")
                    foldingEditor(store.p("personality", ""), open: $personalityOpen)
                    HStack(spacing: 18) {
                        Button("恢复出厂") {
                            store.p("personality", "").wrappedValue = ""
                            store.persona["factory"] = Array(Set((store.persona["factory"] as? [String] ?? []) + ["personality"]))
                            writingOwn = false
                        }
                        Button("从 txt / md 读进来") { readingTxt = true }
                    }
                    .font(Typo.sans(Typo.Size.callout))
                    .foregroundStyle(theme.accentDeep)
                    if let txtNote { Text(txtNote).font(Typo.sans(Typo.Size.caption)).foregroundStyle(.red.opacity(0.8)) }
                }
            }
            // 读进来是整段换掉（不是接在后面）；读不了给一句人话
            Color.clear.frame(height: 0)
                .fileImporter(isPresented: $readingTxt, allowedContentTypes: [.plainText, UTType(filenameExtension: "md") ?? .plainText]) { result in
                    guard case .success(let url) = result else { return }
                    let ok = url.startAccessingSecurityScopedResource()
                    defer { if ok { url.stopAccessingSecurityScopedResource() } }
                    guard let data = try? Data(contentsOf: url), let text = Self.decodeText(data)?
                        .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                        txtNote = String(localized: "这个文件读不出来"); return
                    }
                    guard text.count <= 30_000 else { txtNote = String(localized: "太长了（最多 3 万字）"); return }
                    txtNote = nil
                    writingOwn = true
                    // 酒馆写法的占位符照导卡一样换掉：{{char}} → TA 的名字，{{user}} → 你的名字
                    let me = model.profile?.name.trimmingCharacters(in: .whitespaces) ?? ""
                    store.p("personality", "").wrappedValue = text
                        .replacingOccurrences(of: #"\{\{\s*char\s*\}\}"#, with: companion.name, options: [.regularExpression, .caseInsensitive])
                        .replacingOccurrences(of: #"\{\{\s*user\s*\}\}"#, with: me.isEmpty ? String(localized: "你") : me,
                                              options: [.regularExpression, .caseInsensitive])
                }
            // 从角色卡导入的设定（10-11 内测反馈：以前没有入口，删性格没用、卡那层一直在）
            if !((store.persona["imported"] as? String) ?? "").isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    row("导入的卡", "从角色卡带来的设定，跟上面的性格一起生效。想改就改")
                    foldingEditor(store.p("imported", ""), open: $importedOpen)
                    Button("删掉卡设定", role: .destructive) {
                        store.p("imported", "").wrappedValue = ""
                    }
                    .font(Typo.sans(Typo.Size.callout))
                    .foregroundStyle(.red.opacity(0.8))
                }
            }
            ExpandRow(open: $toneOpen) {
                row("温暖 · 主动 · 幽默", "说话的温度，点开调")
            } content: {
                VStack(alignment: .leading, spacing: 14) { toneRows }
            }
            RowPicker(selection: store.p("gender", "")) {
                Text("不说").tag("")
                Text("女").tag("female")
                Text("男").tag("male")
            } label: { row("性别", "不说的话，界面里提到 TA 就写「TA」") }
            VStack(alignment: .leading, spacing: 6) {
                row("TA 怎么叫你", "空着就叫你的名字")
                TextField("比如：小满", text: store.p("call_user", ""))
                    .font(Typo.sans(Typo.Size.body))
            }
            relationshipRows
            if Lite.on {         // 线下生活（10-05 Aporia：谈人机恋的有人不喜欢 AI 角色扮演，默认关；进线下模式自动打开）
                Toggle(isOn: store.s("offline_life", false)) {
                    row("线下生活", Lite.local ? "开着：TA 有自己的一天，会聊自己在哪、在干嘛，有地图。关着：TA 的日子就是和你聊天。进线下模式时会自动打开"
                        : "开着：TA 有自己的一天，会聊自己吃饭、出门这些事。关着：TA 的日子就是和你聊天。进线下模式时会自动打开")
                }
            }
            // 本体化（11-03 Aporia）：Mele 加的说话 / 思考风格都不放；你自己写的照用，功能都在，关回去一切照旧
            Toggle(isOn: store.s("bare_mode", false)) {
                row("本体化", "不加 Mele 的口气，让 TA 用模型自己的样子说话。你自己写的设定照用，功能都还在")
            }
        } header: { GlassHeader(String(localized: "关于 \(genderWord)")) }
    }

    private func isFactory(_ key: String) -> Bool {
        (store.persona["factory"] as? [String] ?? []).contains(key)
    }

    private var traits: some View {
        Tile {
            let on = Set(store.persona["traits"] as? [String] ?? [])
            FlowChips(items: store.traitsCatalog.map { ($0.id, $0.name) }, selected: on) { id in
                var next = on
                if next.contains(id) { next.remove(id) } else if next.count < 3 { next.insert(id) }
                store.p("traits", [String]()).wrappedValue = Array(next)
            }
            note("最多挑 3 个")
        } header: { GlassHeader("Traits") }
    }

    private var toneRows: some View {
        Group {
            ForEach([("warmth", "温暖", "说话暖不暖"), ("initiative", "主动", "会不会自己找话、追问"),
                     ("humor", "幽默", "爱不爱开玩笑")], id: \.0) { key, title, sub in
                VStack(alignment: .leading, spacing: 6) {
                    row(title, sub)
                    Picker(title, selection: store.s(key, "mid")) {
                        Text("少一点").tag("low")
                        Text("刚好").tag("mid")
                        Text("多一点").tag("high")
                    }
                    .pickerStyle(.segmented)
                }
            }
        }
    }

    private var customRelationship: String {
        let r = store.settings["relationship"] as? String ?? ""
        return ["", "friend", "partner", "family", "buddy", "card"].contains(r) ? "" : r
    }

    @ViewBuilder
    private var relationshipRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            row("你们是什么关系", "TA 醒来找你时会按这个拿捏分寸")
            let current = store.settings["relationship"] as? String ?? ""
            // 导入的角色卡多一个「照角色卡」（10-01）：关系照卡里的场景，不套我们的关系包。
            // 只要卡设定还在就一直给（10-12 内测：原来只在选中时出现，点了别的它就没了，再也选不回来）
            let hasCard = !((store.persona["imported"] as? String) ?? "").isEmpty
            FlowChips(items: [("friend", "朋友"), ("partner", "恋人"), ("family", "家人"), ("buddy", "搭子")]
                      + (current == "card" || hasCard ? [("card", "照角色卡")] : []),
                      selected: [current]) { id in
                store.setNow(settings: ["relationship": current == id ? "" : id])
                customRel = ""
            }
            TextField("或者自己写，比如：饭搭子", text: $customRel)
                .font(Typo.sans(Typo.Size.body))
                .onSubmit { store.setNow(settings: ["relationship": customRel.trimmingCharacters(in: .whitespaces)]) }
        }
    }

    private func price(_ level: String) -> String {
        guard let l = store.estimate?.levels?[level] else { return "" }
        if let usd = l.usdPerMonth { return String(format: String(localized: "一个月最多 %d 次 · 约 $%.2f"), l.wakesPerMonth, usd) }
        return String(localized: "一个月最多 \(l.wakesPerMonth) 次")
    }

    @ViewBuilder private var patrol: some View {
        Tile {
            let level = store.s("patrol_level", "mid")
            Picker("多久来找你", selection: level) {
                Text("低").tag("low")
                Text("中").tag("mid")
                Text("高").tag("high")
                Text("极高").tag("max")
            }
            .pickerStyle(.segmented)
            note(price(level.wrappedValue))
            if model.companions.first?.id == companion.id {      // 早上那次只由主联系人来（10-01，跟心跳分开）
                Toggle(isOn: store.s("morning_on", true)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("早上先来").font(Typo.sans(Typo.Size.body)).foregroundStyle(theme.ink)
                        note("起床前半小时把你今天的事过一遍，静音发过来，不吵醒你")
                    }
                }
                if store.keyID != nil && !Lite.local {            // 日记（10-01 Aporia）：付费的能关、能调长短；免费固定 300 字（本机的在下面单独一格）
                    Toggle(isOn: store.s("diary_on", true)) {
                        Text("每晚写日记").font(Typo.sans(Typo.Size.body)).foregroundStyle(theme.ink)
                    }
                }
                if store.keyID != nil && !Lite.local && (store.settings["diary_on"] as? Bool ?? true) {
                    let chars = store.s("diary_chars", 600)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(String(localized: "日记最多写 \(chars.wrappedValue) 字")).font(Typo.sans(Typo.Size.body)).foregroundStyle(theme.ink)
                        Slider(value: Binding(get: { Double(chars.wrappedValue) }, set: { chars.wrappedValue = Int($0 / 100) * 100 }),
                               in: 300...1500, step: 100)
                        note("每天凌晨等你睡着了写前一天；写得越长，每晚花得越多（用的是你自己的 key）")
                    }
                } else if store.keyID == nil {
                    note("每天凌晨等你睡着了，它会写前一天的日记（最多 300 字，不占你的免费额度）")
                }
            }
            note("你约的时间（以前的「钟」）都搬进了 Library → 待办：到点、到了或离开某个地方，它一定来。")
        } header: { GlassHeader("TA 多久来找你") } footer: {
            Text("档位管 TA 自己想起你的频率。")
        }
        .needsHost()
        if Lite.local || (model.companions.first?.id != companion.id && store.keyID != nil) {
            localDiary          // 本机：每个联系人；Host / 服务器：别的联系人（10-27，主联系人的在上面那格）
        }
    }

    /// 本机的日记（10-05）：打开 App 时补写昨天的，所以不用灰着。
    /// 10-12：别的联系人也能写，开关是 diary_also、默认关（主联系人还是 diary_on、默认开）
    /// 双语气泡（10-15）：TA 的泡原文在上、译文在下；你那句不翻
    private var bilingual: some View {
        Tile {
            Toggle(isOn: store.s("bilingual", false)) {
                Text("双语气泡").font(Typo.sans(Typo.Size.body)).foregroundStyle(theme.ink)
            }
            if store.settings["bilingual"] as? Bool ?? false {
                RowPicker(selection: store.s("bilingual_lang", "English")) {
                    ForEach(["English", "日本語", "한국어", "Français", "Español", "Deutsch", "Русский", "Italiano"], id: \.self) { Text($0).tag($0) }
                } label: { Text("TA 说").font(Typo.sans(Typo.Size.body)).foregroundStyle(theme.ink) }
                RowPicker(selection: store.s("bilingual_to", "")) {
                    Text("跟 App 一样").tag("")
                    ForEach(["中文", "English", "日本語"], id: \.self) { Text($0).tag($0) }
                } label: { Text("译成").font(Typo.sans(Typo.Size.body)).foregroundStyle(theme.ink) }
                RowPicker(selection: store.s("bilingual_by", "key")) {
                    Text("翻译钥匙（便宜）").tag("key")
                    Text("TA 自己写").tag("self")
                } label: { Text("译文谁写").font(Typo.sans(Typo.Size.body)).foregroundStyle(theme.ink) }
            }
        } header: { GlassHeader("双语") } footer: {
            Text("TA 一直用选的语言说话，每个气泡下面一行译文；你照常打字，原话发给 TA，不翻。「翻译钥匙」用钥匙串里勾了「翻译」的那把（没勾就用聊天那把），每句多一次便宜的调用；「TA 自己写」不多调用，但译文是聊天模型写的，聊天模型贵的话更花钱。群聊里也按这里的设定，没开的 TA 照常说。")
        }
    }

    private var localDiary: some View {
        let main = model.companions.first?.id == companion.id
        let key = main ? "diary_on" : "diary_also"
        return Tile {
            Toggle(isOn: store.s(key, main)) {
                Text("写日记").font(Typo.sans(Typo.Size.body)).foregroundStyle(theme.ink)
            }
            if store.settings[key] as? Bool ?? main {
                let chars = store.s("diary_chars", 600)
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(localized: "日记最多写 \(chars.wrappedValue) 字")).font(Typo.sans(Typo.Size.body)).foregroundStyle(theme.ink)
                    Slider(value: Binding(get: { Double(chars.wrappedValue) }, set: { chars.wrappedValue = Int($0 / 100) * 100 }),
                           in: 300...1500, step: 100)
                }
            }
        } header: { GlassHeader("日记") } footer: {
            if main {
                Text("每天第一次打开 App 时，昨天你们聊过的话，TA 会写一篇昨天的日记；你那天写了日记，TA 会在页边留一句。用的是你自己的 key，写得越长越贵。")
            } else if !Lite.local {
                Text("打开后，每天凌晨等你睡着了，昨天你们聊过的话，TA 也会写一篇日记，在日记页多出 TA 的一本。你的日记只给主联系人读。用的是 TA 这把 key，多一个人写就多花一份。")
            } else {
                Text("打开后，每天第一次打开 App 时，昨天你们聊过的话，TA 会写一篇昨天的日记，在日记页多出 TA 的一本。你的日记只给主联系人读。用的是你自己的 key，多一个人写就多花一份。")
            }
        }
    }

    private var memory: some View {
        Tile {
            // 接 MCP（10-04）：Lite 能接用户自己部署的记忆库；接上了「联想」就亮
            if Lite.on { MemoryLinkRows(store: store, hosted: !Lite.local) }
            if Lite.hosted { ShareMemoryRows(store: store) }      // 让别的 AI 连上 TA 的记忆（10-16，Host）
            let linked = Lite.local && store.settings["memory_server"] is String
            Group {
                if linked { recallPicker } else { recallPicker.needsHost(note: false) }
            }
            RowPicker(selection: store.optionalInt("memory_length")) {
                Text("跟模型").tag(Int?.none)
                Text("短 · 1 万").tag(Int?.some(10_000))
                Text("中 · 3 万").tag(Int?.some(30_000))
                Text("长 · 6 万").tag(Int?.some(60_000))
            } label: { row("记性长度", "原话留多长再卷进账本。越长越贵") }
            // 一段脑子（10-11 群聊）：私聊和群里的事按时间穿插进来；只按条数，不限时间（本机和 Host 都有）
            if Lite.on {
                let n = store.s("other_rooms_count", 30)
                VStack(alignment: .leading, spacing: 4) {
                    row(String(localized: "别的房间记多少 · \(n.wrappedValue) 条"),
                        String(localized: "在私聊里看得到群里最近的话，在群里看得到私聊最近的话（按时间穿插）。0 = 不合"))
                    Slider(value: Binding(get: { Double(n.wrappedValue) }, set: { n.wrappedValue = Int($0 / 5) * 5 }), in: 0...100, step: 5)
                }
            }
            // 回声（Lite 本机也卷了，10-04）：按天记的账本，默认收着，点开能改；10-27 Host 也有（服务器 /companions/{id}/echo）
            if Lite.on {
                NavigationLink {
                    EchoView(companion: companion).environmentObject(theme)
                } label: {
                    HStack {
                        row("回声", "聊久了，旧的按天卷进这本账，远的模糊、近的清楚")
                        Spacer()
                        Image(systemName: "chevron.right").font(Typo.icon(13)).foregroundStyle(theme.inkFaint)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            // 搬家（10-05）：导入 ChatGPT / Claude / DeepSeek / Gemini 官方导出的聊天记录；连着 Host 也能搬（包在手机上认）
            if Lite.on {
                NavigationLink {
                    ImportChatsView(companion: companion).environmentObject(theme)
                } label: {
                    HStack {
                        row("从别的 AI 搬过来", "ChatGPT、Claude、DeepSeek、Gemini、Kelivo 导出的聊天记录或 md 文件，再挑出值得记住的事")
                        Spacer()
                        Image(systemName: "chevron.right").font(Typo.icon(13)).foregroundStyle(theme.inkFaint)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            // 导出聊天记录（10-17 内测）：只要这一个 TA 的，拼成 md 交给分享面板（存到「文件」、发给自己都行）
            Button { Task { await exportChat() } } label: {
                HStack {
                    row("导出聊天记录", "把跟 TA 的所有窗口存成一份能看的 md 文件。一键备份是整个 Mele 一起、只能整包恢复")
                    Spacer()
                    if exportingChat { ProgressView() }
                    else { Image(systemName: "square.and.arrow.up").font(Typo.icon(14)).foregroundStyle(theme.inkFaint) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(exportingChat)
            if let chatExportNote { note(chatExportNote) }
            if Lite.local { note(linked ? "TA 每句话都会先去记忆库想一下，「联想」管想起多少。"
                                     : "接上记忆库，TA 每句话都会先去想一下；没接的话，Lite 记得的是最近的聊天和回声。") }
            Toggle(isOn: store.s("long_mode", false)) { row("长文模式", "回复整段发，不切成一条条") }
        } header: { GlassHeader("记性") }
    }

    private var recallPicker: some View {
        RowPicker(selection: store.s("recall_level", "medium")) {
            Text("关").tag("off")
            Text("少").tag("light")
            Text("中").tag("medium")
            Text("多").tag("rich")
        } label: { row("联想", "聊天时想起旧事的多少") }
    }

    private var key: some View {
        Tile {
            RowPicker(selection: Binding(get: { store.keyID }, set: { v in Task { await store.useKey(v) } })) {
                Text(Lite.on ? "还没选" : "免费额度").tag(String?.none)
                ForEach(store.keys.filter { !KeychainCard.voiceOnly($0.provider) }) { k in
                    Text("\(k.chatModel) ··\(k.last4)").tag(String?.some(k.id))
                }
            } label: { row("用哪把钥匙", "也就是用哪个模型。钥匙在「Me」里加") }
        }
    }
}

/// 一排可以换行的小胶囊（关系、traits）
struct FlowChips: View {
    @EnvironmentObject private var theme: AppTheme
    let items: [(String, String)]
    let selected: Set<String>
    let tap: (String) -> Void

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(items, id: \.0) { id, label in
                let on = selected.contains(id)
                Button { tap(id) } label: {
                    Text(label)
                        .font(Typo.sans(Typo.Size.callout, on ? .semibold : .regular))
                        .foregroundStyle(on ? .white : theme.ink)
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(Capsule().fill(on ? theme.accentDeep : Color.black.opacity(0.05)))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// 从左到右排，放不下就换行
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > w { x = 0; y += line + spacing; line = 0 }
            x += s.width + spacing
            line = max(line, s.height)
        }
        return CGSize(width: w == .infinity ? x : w, height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX { x = bounds.minX; y += line + spacing; line = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            line = max(line, s.height)
        }
    }
}

// MARK: - 加一个钟

struct AddClockView: View {
    @Environment(\.dismiss) private var dismiss
    let onAdd: (String, [String: Any], String) -> Void
    @State private var shape = "at"
    @State private var time = Calendar.current.date(bySettingHour: 8, minute: 0, second: 0, of: Date())!
    @State private var once = Date().addingTimeInterval(3600)
    @State private var from = Calendar.current.date(bySettingHour: 19, minute: 0, second: 0, of: Date())!
    @State private var to = Calendar.current.date(bySettingHour: 22, minute: 0, second: 0, of: Date())!
    @State private var everyHours = 2
    @State private var noteText = ""

    private func hm(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("怎么响", selection: $shape) {
                    Text("每天").tag("at")
                    Text("一次").tag("once")
                    Text("每隔").tag("every")
                    Text("时段里随机").tag("window")
                }
                .pickerStyle(.segmented)
                switch shape {
                case "at": DatePicker("几点", selection: $time, displayedComponents: .hourAndMinute)
                case "once": DatePicker("什么时候", selection: $once, in: Date()...)
                case "every":
                    Stepper("每 \(everyHours) 小时", value: $everyHours, in: 1...12)
                    DatePicker("从", selection: $from, displayedComponents: .hourAndMinute)
                    DatePicker("到", selection: $to, displayedComponents: .hourAndMinute)
                default:
                    DatePicker("从", selection: $from, displayedComponents: .hourAndMinute)
                    DatePicker("到", selection: $to, displayedComponents: .hourAndMinute)
                }
                Section {
                    TextField("想让 TA 来干嘛（比如：问我今天的安排）", text: $noteText)
                } footer: { Text("TA 到点醒来会看到这句。") }
            }
            .navigationTitle("加一个钟")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("加") {
                        var spec: [String: Any] = [:]
                        switch shape {
                        case "at": spec = ["time": hm(time)]
                        case "once":
                            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"
                            spec = ["at": f.string(from: once)]
                        case "every": spec = ["every_min": everyHours * 60, "from": hm(from), "to": hm(to)]
                        default: spec = ["from": hm(from), "to": hm(to)]
                        }
                        onAdd(shape, spec, noteText.trimmingCharacters(in: .whitespaces))
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - 记一件 / 改一件（它记着的事）

struct AddDateView: View {
    @Environment(\.dismiss) private var dismiss
    let existing: FarDateDTO?
    let onSave: ([String: Any]) -> Void
    var onDelete: (() -> Void)?
    @State private var day = Date().addingTimeInterval(7 * 86400)
    @State private var hasTime = false
    @State private var time = Calendar.current.date(bySettingHour: 14, minute: 0, second: 0, of: Date())!
    @State private var title = ""
    @State private var noteText = ""

    /// startDay = 从日历某一天点进来的（10-01）；onDelete = 日历里改的时候能删
    init(existing: FarDateDTO?, startDay: Date? = nil, onDelete: (() -> Void)? = nil, onSave: @escaping ([String: Any]) -> Void) {
        self.existing = existing
        self.onSave = onSave
        self.onDelete = onDelete
        if let startDay { _day = State(initialValue: startDay) }
        if let e = existing {
            _day = State(initialValue: e.date ?? Date())
            _title = State(initialValue: e.title)
            _noteText = State(initialValue: e.note)
            if !e.time.isEmpty, let t = Self.hmFormatter.date(from: e.time) {
                let c = Calendar.current.dateComponents([.hour, .minute], from: t)
                _hasTime = State(initialValue: true)
                _time = State(initialValue: Calendar.current.date(bySettingHour: c.hour ?? 0, minute: c.minute ?? 0, second: 0, of: Date())!)
            }
        }
    }

    private static let hmFormatter: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter(); f.calendar = Calendar(identifier: .gregorian); f.dateFormat = "yyyy-MM-dd"; return f
    }()

    var body: some View {
        NavigationStack {
            Form {
                TextField("什么事（比如：坐飞机去墨尔本）", text: $title)
                DatePicker("哪天", selection: $day, in: Calendar.current.startOfDay(for: Date())..., displayedComponents: .date)
                Toggle("有具体时间", isOn: $hasTime)
                if hasTime { DatePicker("几点", selection: $time, displayedComponents: .hourAndMinute) }
                Section {
                    TextField("备注（可以不写）", text: $noteText)
                } footer: { Text("前一晚、当天、第二天 TA 都会来找你。") }
                if let onDelete {
                    Button("删掉这件", role: .destructive) { onDelete(); dismiss() }
                }
            }
            .navigationTitle(existing == nil ? "记一件" : "改一改")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("好") {
                        onSave(["day": Self.dayFormatter.string(from: day), "time": hasTime ? Self.hmFormatter.string(from: time) : "",
                                "title": title.trimmingCharacters(in: .whitespaces),
                                "note": noteText.trimmingCharacters(in: .whitespaces)])
                        dismiss()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}


/// 长文字框（10-31 内测：人设、说话规矩写长了以后打字卡）：先改自己手上的草稿，停手一会儿再写回设定。
/// 直接绑设定的话，每敲一个字整页设定都要重画一遍，字一多就卡。外面改了（看出厂的、导入）照样跟上。
struct DraftTextEditor: View {
    @Binding var text: String
    @State private var draft = ""
    @State private var ready = false
    @State private var commit: Task<Void, Never>?

    var body: some View {
        TextEditor(text: $draft)
            .onAppear {
                if !ready { draft = text; ready = true }
            }
            .onChange(of: draft) { _, v in
                guard ready, v != text else { return }
                commit?.cancel()
                commit = Task {
                    try? await Task.sleep(for: .milliseconds(400))
                    if Task.isCancelled { return }
                    text = v
                    commit = nil
                }
            }
            .onChange(of: text) { _, v in
                if commit == nil, v != draft { draft = v }      // 正在打字时不抢；停手写回去以后两边一样
            }
            .onDisappear {
                commit?.cancel()
                commit = nil
                if ready, draft != text { text = draft }
            }
    }
}
