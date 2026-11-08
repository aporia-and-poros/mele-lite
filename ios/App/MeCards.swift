import PhotosUI
import SwiftUI
import UIKit

// MARK: - 「Me」的几张卡（第二块第 11 步）：我的设定、钥匙串、账号。外观在 MeView.swift。

struct CardTitle: View {
    @EnvironmentObject private var theme: AppTheme
    let text: String
    var body: some View { Text(text).font(Typo.sans(Typo.Size.headline, .semibold)).foregroundStyle(theme.ink) }
}

struct Hint: View {
    @EnvironmentObject private var theme: AppTheme
    let text: String
    var body: some View { Text(text).font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkFaint) }
}

/// 我的设定：名字、怎么称呼我、外貌、几点睡几点起
struct ProfileCard: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var theme: AppTheme
    @EnvironmentObject private var avatars: AvatarStore
    @State private var pickedAvatar: PhotosPickerItem?
    @State private var name = ""
    @State private var pronoun = "they"
    @State private var looks = ""
    @State private var sleepFrom = Self.hm("00:00")
    @State private var sleepTo = Self.hm("08:00")
    @State private var saved = false
    @State private var error: String?

    static func hm(_ s: String) -> Date {
        let p = s.split(separator: ":").compactMap { Int($0) }
        return Calendar.current.date(bySettingHour: p.first ?? 0, minute: p.count > 1 ? p[1] : 0, second: 0, of: Date()) ?? Date()
    }

    private func str(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            CardTitle(text: String(localized: "我的设定"))
            // 我的头像（10-11 内测反馈）：聊天里「我」那边用的就是这张；存本机，不发给 TA
            HStack(spacing: 14) {
                PhotosPicker(selection: $pickedAvatar, matching: .images) {
                    AvatarView(who: .me, size: 60)
                        .overlay(alignment: .bottomTrailing) {
                            Image(systemName: "camera.fill")
                                .font(Typo.icon(10, .semibold)).foregroundStyle(.white)
                                .frame(width: 22, height: 22)
                                .background(Circle().fill(theme.accentDeep))
                                .overlay(Circle().stroke(.white, lineWidth: 1.5))
                                .offset(x: 3, y: 3)
                        }
                }
                .buttonStyle(.plain)
                VStack(alignment: .leading, spacing: 4) {
                    PhotosPicker(selection: $pickedAvatar, matching: .images) {
                        Text("换头像").font(Typo.sans(Typo.Size.body, .medium)).foregroundStyle(theme.accentDeep)
                    }
                    .buttonStyle(.plain)
                    if avatars.me != nil {
                        Button { withAnimation(.snappy) { avatars.clear(.me) } } label: {
                            Text("用回默认").font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkDim)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Hint(text: String(localized: "聊天里你那边的头像"))
                    }
                }
                Spacer()
            }
            .onChange(of: pickedAvatar) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self) { avatars.set(.me, data: data) }
                    pickedAvatar = nil
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Hint(text: String(localized: "你叫什么"))
                TextField("名字", text: $name)
                    .font(Typo.sans(Typo.Size.body))
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: Radii.chip + 4).fill(Color.white.opacity(0.6)))
            }
            VStack(alignment: .leading, spacing: 6) {
                Hint(text: String(localized: "TA 们提到你时用"))
                Picker("", selection: $pronoun) {
                    Text("她").tag("she")
                    Text("他").tag("he")
                    Text("TA").tag("they")
                }
                .pickerStyle(.segmented)
            }
            VStack(alignment: .leading, spacing: 6) {
                Hint(text: String(localized: "你长什么样（可以不写；写了 TA 们就知道）"))
                TextEditor(text: $looks)
                    .font(Typo.sans(Typo.Size.callout))
                    .frame(minHeight: 70)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: Radii.chip + 4).fill(Color.white.opacity(0.6)))
            }
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("几点睡、几点起").font(Typo.sans(Typo.Size.body)).foregroundStyle(theme.ink)
                    Hint(text: String(localized: "这段时间算深夜，TA 们会收着点"))
                }
                Spacer()
                DatePicker("", selection: $sleepFrom, displayedComponents: .hourAndMinute).labelsHidden()
                Text("–").foregroundStyle(theme.inkDim)
                DatePicker("", selection: $sleepTo, displayedComponents: .hourAndMinute).labelsHidden()
            }
            if let error { Text(error).font(Typo.sans(Typo.Size.callout)).foregroundStyle(.red) }
            Button { Task { await save() } } label: {
                Text(saved ? String(localized: "存好了") : String(localized: "保存"))
                    .font(Typo.sans(Typo.Size.body, .semibold)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).padding(.vertical, 10)
                    .background(Capsule().fill(theme.accentDeep))
            }
            .buttonStyle(.plain)
            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
        .task { await fill() }
    }

    private func fill() async {
        if let p = model.profile { name = p.name; pronoun = p.pronoun; looks = p.looks }
        if let c = model.companions.first,
           let s = (try? await model.api.raw("GET", "companions/\(c.id.lowercased)") as? [String: Any])?["settings"] as? [String: Any] {
            sleepFrom = Self.hm(s["sleep_from"] as? String ?? "00:00")
            sleepTo = Self.hm(s["sleep_to"] as? String ?? "08:00")
        }
    }

    private func save() async {
        do {
            try await model.saveProfile(ProfileDTO(name: name.trimmingCharacters(in: .whitespaces), pronoun: pronoun, looks: looks))
            await model.setSleep(from: str(sleepFrom), to: str(sleepTo))
            error = nil
            withAnimation { saved = true }
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation { saved = false }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// 钥匙串：免费额度进度条、每把钥匙一行、加钥匙
struct KeychainCard: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var theme: AppTheme
    @State private var keys: [KeyDTO] = []
    @State private var adding = false
    @State private var deleting: KeyDTO?
    @State private var choosing: KeyDTO?         // 点开勾活（10-15）

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            CardTitle(text: String(localized: "钥匙串"))
            if let trial = model.me?.trial {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("免费额度").font(Typo.sans(Typo.Size.callout)).foregroundStyle(theme.inkDim)
                        Spacer()
                        Text("\(Int((trial.ratio * 100).rounded()))%").font(Typo.number(Typo.Size.callout)).foregroundStyle(theme.ink)
                    }
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.black.opacity(0.06))
                            Capsule().fill(theme.accentDeep).frame(width: max(6, g.size.width * trial.ratio))
                        }
                    }
                    .frame(height: 8)
                    Hint(text: String(localized: "每天早上 5 点补一些（\(trial.refillAt.formatted(.dateTime.month().day().hour().minute()))）"))
                }
            }
            ForEach(keys) { k in
                HStack(spacing: 10) {
                    Image(systemName: "key.fill").font(Typo.icon(13)).foregroundStyle(theme.accentDeep)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Self.voiceOnly(k.provider) ? Self.providerName(k.provider) : "\(Self.providerName(k.provider)) · \(k.chatModel)")
                            .font(Typo.sans(Typo.Size.body)).foregroundStyle(theme.ink)
                        Text("••••\(k.last4)").font(Typo.number(Typo.Size.caption, .regular)).foregroundStyle(theme.inkFaint)
                        let tags = ChoreNames.tags(k.chores)
                        if !tags.isEmpty {
                            Text(tags.joined(separator: " · ")).font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.accentDeep)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { choosing = k }
                    Spacer()
                    Button { deleting = k } label: {
                        Image(systemName: "trash").font(Typo.icon(13)).foregroundStyle(theme.inkFaint)
                    }
                    .buttonStyle(.plain)
                }
            }
            Button { adding = true } label: {
                Label("加一把钥匙", systemImage: "plus").font(Typo.sans(Typo.Size.body)).foregroundStyle(theme.accentDeep)
            }
            .buttonStyle(.plain)
            Hint(text: String(localized: "用自己的 key，聊天不限量；钱直接付给模型那家。看图、画图在下面那张卡里直接填；别的后台活点一把钥匙勾。"))
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
        .task { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .meleMediaChanged)) { _ in Task { await load() } }
        .sheet(isPresented: $adding) {
            AddKeyView { newKey in
                Task { if !newKey.isEmpty { await model.useKeyWhereFree(newKey) }; await load() }
            }
            .environmentObject(model).environmentObject(theme)
            .environment(\.colorScheme, .light)
        }
        .confirmationDialog("删掉这把钥匙？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("删掉", role: .destructive) {
                if let k = deleting { Task { try? await model.api.send("DELETE", "keys/\(k.id)"); await load(); await model.refresh() } }
                deleting = nil
            }
        } message: { Text("用它的联系人会回到免费额度。") }
        .sheet(item: $choosing) { k in
            KeyChoresSheet(key: k, names: Dictionary(uniqueKeysWithValues: keys.map { ($0.id, Self.providerName($0.provider)) })) {
                Task { await load() }
            }
            .environmentObject(model).environmentObject(theme)
        }
    }

    private func load() async {
        keys = (try? await model.api.call("GET", "keys")) ?? []
        NotificationCenter.default.post(name: .meleKeysChanged, object: nil)      // 看图和画图那张卡跟着刷
        await model.refreshMe()
    }

    static func providerName(_ p: String) -> String {
        ["deepseek": "DeepSeek", "anthropic": "Claude", "openai": "OpenAI", "gemini": "Gemini",
         "openai-compatible": String(localized: "兼容 OpenAI"), "elevenlabs": "ElevenLabs", "minimax": "MiniMax"][p] ?? p
    }

    /// 只管声音的几家（不聊天、不选模型）
    static func voiceOnly(_ p: String) -> Bool { p == "elevenlabs" || p == "minimax" }
}

struct ModelDTO: Decodable, Identifiable, Hashable {
    let id: String
    let provider: String
    let label: String
    let priceIn: Double
    let priceOut: Double
    enum CodingKeys: String, CodingKey { case id, provider, label; case priceIn = "price_in"; case priceOut = "price_out" }
}

/// 加钥匙：选哪家 → 贴 key → 选模型（写着多贵）→ 服务器试打一次，通了才存
struct AddKeyView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var theme: AppTheme
    @Environment(\.dismiss) private var dismiss
    let onAdded: (String) -> Void
    @State private var provider = "deepseek"
    @State private var apiKey = ""
    @State private var baseURL = ""
    @State private var models: [ModelDTO] = []
    @State private var customModel = ""
    @State private var trying = false
    @State private var error: String?
    @State private var fetched: [String] = []       // 兼容 OpenAI：从 /v1/models 拉到的模型
    @State private var picks: [String] = []         // 拉到的里面勾了哪几个：一个模型一把钥匙（10-11 内测反馈：多选）
    @State private var fetching = false
    @State private var fetchNote: String?

    private let providers = ["deepseek", "anthropic", "openai", "gemini", "openai-compatible", "elevenlabs", "minimax"]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("哪家", selection: $provider) {
                        ForEach(providers, id: \.self) { Text(KeychainCard.providerName($0)).tag($0) }
                    }
                    SecureField("把 key 贴在这里", text: $apiKey)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    if provider == "openai-compatible" {
                        TextField("接口地址（https://…/v1）", text: $baseURL)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    } else if provider == "anthropic" {
                        // 中转站的 Claude 原生接口（11-03 一测：中转用 OpenAI 格式调 Claude 没有缓存，每句全价）
                        TextField("中转站地址（选填，直连 Claude 不用填）", text: $baseURL)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        #if LITE
                        Text("key 只存在这台手机的钥匙串里，不经过任何服务器；这里只显示后 4 位。")
                        #else
                        Text("key 加密存在服务器上，谁都看不到原文；这里只显示后 4 位。")
                        #endif
                        if provider == "minimax" {
                            Text("MiniMax 只管声音（语音条、念给我听、电话、听你的语音）。国内版（minimaxi.com）、国际版（minimax.io）的 key 都行，会自己认出来。")
                        }
                        if provider == "openai-compatible" || provider == "anthropic" {
                            Text("在中转站用 Claude 的模型：选「Claude」、填中转站地址（中转站要支持 Claude 原生接口）。这样才走缓存，每句便宜很多；选「兼容 OpenAI」用 Claude 是每句全价。")
                        }
                    }
                }

                if !KeychainCard.voiceOnly(provider) {      // ElevenLabs / MiniMax 只管声音，不选模型（10-15）
                Section {
                    // 目录里的（带价钱）+ 从这家拉到的 + 手填的，都能多选：一个模型存一把钥匙（10-11 内测反馈）
                    ForEach(models) { m in
                        pickRow(m.id, title: m.label,
                                note: String(format: String(localized: "每百万 token：输入 $%.2f · 输出 $%.2f"), m.priceIn, m.priceOut))
                    }
                    ForEach(fetched.filter { id in !models.contains { $0.id == id } }, id: \.self) { id in
                        pickRow(id, title: id, note: nil)
                    }
                    TextField(models.isEmpty && fetched.isEmpty ? String(localized: "模型名") : String(localized: "或者手填模型名"),
                              text: $customModel)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button {
                        Task { await fetchModels() }
                    } label: {
                        if fetching { ProgressView() } else { Text(fetched.isEmpty ? "拉取这家的模型列表" : "重新拉取") }
                    }
                    .disabled(fetching || apiKey.count < 8
                              || (provider == "openai-compatible" && URL(string: baseURL.trimmingCharacters(in: .whitespaces)) == nil))
                    if let fetchNote {
                        Text(fetchNote).font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkFaint)
                    }
                } header: { Text("聊天用哪个模型") } footer: {
                    Text(pickedModels.count > 1
                         ? String(format: String(localized: "会存成 %d 把钥匙（同一个 key，各配一个模型），联系人那边各挑各的。"), pickedModels.count)
                         : String(localized: "可以多选：选几个就存几把钥匙（同一个 key，各配一个模型）。列表里没有的，拉一下或者手填。"))
                }
                }

                if let error {
                    Text(error).font(Typo.sans(Typo.Size.callout)).foregroundStyle(.red)
                }
            }
            .navigationTitle("加一把钥匙")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if trying { ProgressView() } else {
                        Button("存") { Task { KeychainCard.voiceOnly(provider) ? await saveVoiceKey() : await save() } }
                            .disabled(apiKey.count < 8 || (!KeychainCard.voiceOnly(provider) && pickedModels.isEmpty))
                    }
                }
            }
            .overlay(alignment: .bottom) {
                if trying {
                    Text("试一下这把 key…").font(Typo.sans(Typo.Size.callout)).foregroundStyle(theme.inkDim)
                        .padding(.horizontal, 16).padding(.vertical, 10).background(Capsule().fill(.regularMaterial))
                        .padding(.bottom, 30)
                }
            }
        }
        .task(id: provider) { await loadModels() }
    }

    /// 要存的模型：勾上的（目录里的、拉到的）+ 手填的
    private var pickedModels: [String] {
        let typed = customModel.trimmingCharacters(in: .whitespaces)
        return typed.isEmpty || picks.contains(typed) ? picks : picks + [typed]
    }

    private func pickRow(_ id: String, title: String, note: String?) -> some View {
        Button {
            if let i = picks.firstIndex(of: id) { picks.remove(at: i) } else { picks.append(id) }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(Typo.sans(Typo.Size.body)).foregroundStyle(theme.ink).lineLimit(1).truncationMode(.middle)
                    if let note { Text(note).font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkFaint) }
                }
                Spacer()
                Image(systemName: picks.contains(id) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(picks.contains(id) ? theme.accentDeep : theme.inkFaint)
            }
        }
    }

    private func loadModels() async {
        models = (try? await model.api.call("GET", "models", query: [URLQueryItem(name: "provider", value: provider)])) ?? []
        picks = models.first.map { [$0.id] } ?? []
        fetched = []; fetchNote = nil
    }

    /// 从这家直接拉模型列表（手机直连，key 只发给这家自己）：各家的「列模型」接口
    private func fetchModels() async {
        fetching = true
        defer { fetching = false }
        fetchNote = nil
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        var req: URLRequest
        switch provider {
        case "anthropic":
            let relay = Self.claudeBase(baseURL)
            req = URLRequest(url: URL(string: (relay ?? "https://api.anthropic.com") + "/v1/models?limit=1000")
                             ?? URL(string: "https://api.anthropic.com/v1/models?limit=1000")!, timeoutInterval: 15)
            req.setValue(key, forHTTPHeaderField: "x-api-key")
            if relay != nil { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case "gemini":
            req = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models?pageSize=1000")!, timeoutInterval: 15)
            req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        default:
            var base = provider == "openai" ? "https://api.openai.com/v1"
                : provider == "deepseek" ? "https://api.deepseek.com" : baseURL.trimmingCharacters(in: .whitespaces)
            while base.hasSuffix("/") { base.removeLast() }
            guard let url = URL(string: base + "/models") else { fetchNote = String(localized: "地址不对"); return }
            req = URLRequest(url: url, timeoutInterval: 15)
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            var ids: [String] = []
            if let list = obj?["data"] as? [[String: Any]] {                       // OpenAI / DeepSeek / Claude / 兼容
                ids = list.compactMap { $0["id"] as? String }
            } else if let list = obj?["models"] as? [[String: Any]] {              // Gemini：只要能聊天的
                ids = list.filter { ($0["supportedGenerationMethods"] as? [String] ?? []).contains("generateContent") }
                    .compactMap { ($0["name"] as? String)?.replacingOccurrences(of: "models/", with: "") }
            }
            guard status == 200, !ids.isEmpty else {
                fetchNote = status == 401 || status == 403 ? String(localized: "key 不对，这家不认")
                    : status == 200 ? String(localized: "拉到了，但列表是空的；下面手填模型名就好")
                    : provider == "openai-compatible" ? String(localized: "这家没有标准的模型列表接口，下面手填模型名就好")
                    : String(localized: "没拉到（\(status)），下面手填模型名就好")
                return
            }
            // 聊不了天的（向量、语音、画图、审核）不列
            let notChat = ["embed", "tts", "whisper", "dall-e", "moderation", "transcribe", "image", "audio", "realtime", "veo", "imagen"]
            let chatty = ids.filter { id in !notChat.contains { id.lowercased().contains($0) } }
            fetched = Array(Set(chatty.isEmpty ? ids : chatty)).sorted()
            if picks.isEmpty, customModel.isEmpty, let first = fetched.first { picks = [first] }
        } catch {
            fetchNote = provider == "openai-compatible" ? String(localized: "连不上这个地址，看看写对了没（要到 /v1 为止）")
                : String(localized: "连不上这家，看看网络")
        }
    }

    /// Claude 中转地址收成到域名为止（Lite 的 AnthropicClient 和 Host 的 anthropic 包都会自己接 /v1/messages）；空着 = 直连
    static func claudeBase(_ raw: String) -> String? {
        var b = raw.trimmingCharacters(in: .whitespaces)
        while b.hasSuffix("/") { b.removeLast() }
        if b.hasSuffix("/messages") { b.removeLast("/messages".count) }
        if b.hasSuffix("/v1") { b.removeLast(3) }
        return b.isEmpty ? nil : b
    }

    private func saveVoiceKey() async {
        trying = true; defer { trying = false }
        do {
            _ = try await model.api.raw("POST", "keys/\(provider)", json: ["api_key": apiKey.trimmingCharacters(in: .whitespacesAndNewlines)])
            onAdded("")
            dismiss()
        } catch {
            self.error = (error as? APIError)?.message ?? String(localized: "key 没存上")
        }
    }

    private func save() async {
        trying = true
        defer { trying = false }
        var first: String?
        for m in pickedModels {
            var body: [String: Any] = ["provider": provider, "api_key": apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
                                       "chat_model": m]
            if provider == "openai-compatible" { body["base_url"] = baseURL.trimmingCharacters(in: .whitespaces) }
            if provider == "anthropic", let relay = Self.claudeBase(baseURL) { body["base_url"] = relay }   // 中转站的 Claude（11-03）
            do {
                let k: KeyDTO = try await model.api.call("POST", "keys", json: body)
                if first == nil { first = k.id }
            } catch {
                self.error = first == nil ? error.localizedDescription
                    : String(format: String(localized: "存到 %@ 时出错：%@（前面的已经存好了）"), m, error.localizedDescription)
                if let first { onAdded(first) }
                return
            }
        }
        if let first { onAdded(first) }
        dismiss()
    }
}

/// 账号：邮箱、导出、退出登录、删号
struct AccountCard: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var theme: AppTheme
    @State private var exportURL: URL?
    @State private var exporting = false
    @State private var confirmLogout = false
    @State private var deleting = false
    @State private var deleteWord = ""
    @State private var toured = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            CardTitle(text: String(localized: "账号"))
            if let email = model.me?.email {
                Text(email).font(Typo.sans(Typo.Size.body)).foregroundStyle(theme.inkDim)
            }
            Button { Task { await export() } } label: {
                HStack {
                    Label("导出我的数据", systemImage: "square.and.arrow.up").font(Typo.sans(Typo.Size.body))
                    if exporting { ProgressView().padding(.leading, 6) }
                }
                .foregroundStyle(theme.ink)
            }
            .buttonStyle(.plain)
            Button { confirmLogout = true } label: {
                Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right").font(Typo.sans(Typo.Size.body))
                    .foregroundStyle(theme.ink)
            }
            .buttonStyle(.plain)
            Button { CoachTour.arm(); toured = true } label: {
                Label(toured ? String(localized: "好了，去聊天页看看") : String(localized: "重看功能导览"),
                      systemImage: "sparkles").font(Typo.sans(Typo.Size.body)).foregroundStyle(theme.ink)
            }
            .buttonStyle(.plain)
            Button { deleting = true } label: {
                Label("删除账号", systemImage: "trash").font(Typo.sans(Typo.Size.body)).foregroundStyle(.red)
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
        .sheet(item: Binding(get: { exportURL.map { ShareItem(url: $0) } }, set: { exportURL = $0?.url })) { item in
            ActivityView(items: [item.url])
        }
        .confirmationDialog("退出登录？", isPresented: $confirmLogout, titleVisibility: .visible) {
            Button("退出登录", role: .destructive) { session.logout() }
        } message: { Text("聊天记录都在服务器上，登录回来还在。") }
        .alert("删除账号", isPresented: $deleting) {
            TextField("打「删除」两个字", text: $deleteWord)
            Button("删除", role: .destructive) {
                if deleteWord.trimmingCharacters(in: .whitespaces) == "删除" {
                    Task {
                        try? await model.api.send("DELETE", "me")
                        session.logout(local: true)
                    }
                }
                deleteWord = ""
            }
            Button("算了", role: .cancel) { deleteWord = "" }
        } message: {
            Text("所有联系人、聊天、TA 们记得的事、钥匙都会真删掉，找不回来。确定的话打「删除」两个字。")
        }
    }

    private func export() async {
        exporting = true
        defer { exporting = false }
        guard let data = try? await model.api.data("me/export") else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lumi-export.json")
        try? data.write(to: url)
        exportURL = url
    }

    struct ShareItem: Identifiable { let url: URL; var id: String { url.path } }
}

/// 系统的分享面板（存到文件、发给自己）
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

/// TA 们能看到（第三块）：天气、在哪、日程、步数和睡眠四个开关 + 设家 + 快捷指令入口
struct ContextCard: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var theme: AppTheme
    @ObservedObject private var reporter = ContextReporter.shared
    @State private var hook: Hook?
    @State private var showHook = false
    @State private var copied = false

    struct Hook: Decodable { let url: String; let token: String }

    private let rows: [(ContextReporter.Kind, String, String)] = [
        (.weather, "天气", "你那边的天气"),
        (.place, "在哪", "离家 300 米以外才告诉 TA 地名；只在打开 app 时看"),
        (.calendar, "日程", "接下来 3 天有什么事，只看标题和时间"),
        (.health, "步数和睡眠", "今天走了多少、昨晚睡了多久"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("TA 们能看到").font(Typo.sans(Typo.Size.headline, .semibold)).foregroundStyle(theme.ink)
            ForEach(rows, id: \.0) { kind, title, sub in
                Toggle(isOn: Binding(get: { reporter.enabled.contains(kind) },
                                     set: { on in Task { await reporter.set(kind, on: on) } })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(Typo.sans(Typo.Size.body)).foregroundStyle(theme.ink)
                        Text(sub).font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkFaint)
                    }
                }
                .tint(theme.accentDeep)
                if kind == .place && reporter.enabled.contains(.place) {
                    HStack {
                        Text(reporter.homeSet ? String(localized: "家已经设好了") : String(localized: "还没设家，先设了才会报"))
                            .font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkDim)
                        Spacer()
                        Button(reporter.homeSet ? String(localized: "重设为这里") : String(localized: "把这里设为家")) {
                            Task { await reporter.setHomeHere() }
                        }
                        .font(Typo.sans(Typo.Size.callout, .medium)).foregroundStyle(theme.accentDeep)
                    }
                    .padding(.leading, 4)
                }
            }
            if !Lite.local { shortcut }     // 快捷指令要一个网址收，手机里的小管家没有（连着 Host 就有）
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    @ViewBuilder private var shortcut: some View {
            Divider()
            Button { Task { await loadHook(); withAnimation { showHook.toggle() } } } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("快捷指令").font(Typo.sans(Typo.Size.body)).foregroundStyle(theme.ink)
                        Text("自己的快捷指令往这里报一句（「在健身房」），TA 们就知道").font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkFaint)
                    }
                    Spacer()
                    Image(systemName: showHook ? "chevron.up" : "chevron.down").font(Typo.icon(12)).foregroundStyle(theme.inkFaint)
                }
            }
            .buttonStyle(.plain)
            if showHook, let hook {
                VStack(alignment: .leading, spacing: 6) {
                    Text("网址").font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkFaint)
                    Text(hook.url).font(Typo.sans(Typo.Size.callout)).foregroundStyle(theme.ink).textSelection(.enabled)
                    Text("口令（放在请求头 Authorization: Bearer 后面）").font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkFaint)
                    Text(hook.token).font(Typo.number(Typo.Size.callout, .regular)).foregroundStyle(theme.ink).textSelection(.enabled)
                    Text("内容：{\"text\": \"在健身房\"}，或者直接一句话").font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkFaint)
                    HStack(spacing: 16) {
                        Button(copied ? String(localized: "复制好了") : String(localized: "复制口令")) {
                            UIPasteboard.general.string = hook.token
                            copied = true
                        }
                        Button(String(localized: "换一个口令")) { Task { await resetHook() } }
                    }
                    .font(Typo.sans(Typo.Size.callout, .medium)).foregroundStyle(theme.accentDeep)
                }
            }
    }

    private func loadHook() async {
        if hook == nil { hook = try? await model.api.call("GET", "me/hook") }
    }

    private func resetHook() async {
        hook = try? await model.api.call("POST", "me/hook/reset")
        copied = false
    }
}


extension Notification.Name {
    static let meleKeysChanged = Notification.Name("MeleKeysChanged")
    static let meleMediaChanged = Notification.Name("MeleMediaChanged")     // 看图和画图那张卡改了，钥匙串跟着刷标签
}

/// 看图和画图（10-15 Aporia）。10-16 Aporia：从钥匙串挑太绕（还得先填个聊天模型，内测把画图模型填成了聊天模型）、
/// 看图画图一般不是同一把——改成两栏直接填：哪家 / key / 中转站地址 / 模型。不进钥匙串，TA 的聊天钥匙里选不到。
/// 存的时候查一遍那家的模型列表（不花钱），当场说 key 对不对、有没有这个模型、中转站的画图模型叫什么。
/// 接口 GET me/media、PUT me/media/direct/{vision|draw}（Lite 本机 LocalMedia；Host routes_account）；旧 Host 没这个接口就不显示
struct MediaKeysCard: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var theme: AppTheme
    @State private var media: Media?
    @State private var editing: String?

    struct Slot: Decodable {
        var provider: String
        var baseURL: String?
        var model: String
        var last4: String
        enum CodingKeys: String, CodingKey { case provider, model, last4, baseURL = "base_url" }
    }
    struct Media: Decodable {
        var visionKey: String?
        var imageKey: String?
        var defaultModels: [String: String]
        var visionDefaults: [String: String]?
        var direct: [String: Slot?]?
        enum CodingKeys: String, CodingKey {
            case visionKey = "vision_key", imageKey = "image_key", defaultModels = "default_models"
            case visionDefaults = "vision_defaults", direct
        }
        func slot(_ s: String) -> Slot? { (direct?[s]) ?? nil }
    }

    var body: some View {
        Group {
            if let m = media {
                VStack(alignment: .leading, spacing: 14) {
                    CardTitle(text: String(localized: "看图和画图"))
                    row("vision", String(localized: "看图"), m)
                    Hint(text: String(localized: "TA 用的模型看不见图（DeepSeek 这类）时，你发的照片先给这把看、写一段描述递给 TA，以后翻旧账也记得。"))
                    Divider().opacity(0.4)
                    row("draw", String(localized: "画图"), m)
                    Hint(text: String(localized: "填了以后所有 TA 都会画：跟 TA 说「画一张……」就行，画好的跟它的话一起发过来，花这把 key 的钱。"))
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardSurface()
            }
        }
        .task { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .meleKeysChanged)) { _ in Task { await load() } }
        .sheet(item: Binding(get: { editing.map(SlotID.init) }, set: { editing = $0?.id })) { e in
            MediaKeySheet(slot: e.id, current: media?.slot(e.id),
                          defaults: e.id == "draw" ? media?.defaultModels ?? [:] : media?.visionDefaults ?? [:]) { m in media = m }
                .environmentObject(model).environmentObject(theme)
                .environment(\.colorScheme, .light)
        }
    }

    struct SlotID: Identifiable { let id: String }

    private func row(_ slot: String, _ title: String, _ m: Media) -> some View {
        Button { editing = slot } label: {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(Typo.sans(Typo.Size.body)).foregroundStyle(theme.ink)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    if let d = m.slot(slot) {
                        Text("\(KeychainCard.providerName(d.provider)) · \(d.model.isEmpty ? String(localized: "默认模型") : d.model)")
                            .font(Typo.sans(Typo.Size.callout)).foregroundStyle(theme.accentDeep)
                        Text("••••\(d.last4)").font(Typo.number(Typo.Size.caption, .regular)).foregroundStyle(theme.inkFaint)
                    } else {
                        Text(String(localized: "填一把")).font(Typo.sans(Typo.Size.callout)).foregroundStyle(theme.accentDeep)
                        if (slot == "vision" ? m.visionKey : m.imageKey) != nil {
                            Text(String(localized: "现在用钥匙串里勾的那把")).font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkFaint)
                        }
                    }
                }
                Image(systemName: "chevron.right").font(Typo.icon(11)).foregroundStyle(theme.inkFaint)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func load() async {
        if let m: Media = try? await model.api.call("GET", "me/media") { media = m }
    }
}

/// 填一栏：哪家 / key / 中转站地址 / 模型。存了当场查模型列表，说通没通
struct MediaKeySheet: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var theme: AppTheme
    @Environment(\.dismiss) private var dismiss
    let slot: String
    let current: MediaKeysCard.Slot?
    let defaults: [String: String]
    let onSaved: (MediaKeysCard.Media) -> Void
    @State private var provider = "gemini"
    @State private var apiKey = ""
    @State private var baseURL = ""
    @State private var modelName = ""
    @State private var saving = false
    @State private var result: (ok: Bool, text: String)?

    struct Saved: Decodable {
        struct Check: Decodable { let ok: Bool; let message: String }
        let check: Check?
    }

    private var providers: [String] { slot == "draw" ? ["gemini", "openai", "openai-compatible"] : ["gemini", "anthropic", "openai", "openai-compatible"] }
    private var relay: Bool { provider == "openai-compatible" }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("哪家", selection: $provider) {
                        ForEach(providers, id: \.self) { Text(KeychainCard.providerName($0)).tag($0) }
                    }
                    SecureField(current == nil ? String(localized: "把 key 贴在这里") : String(localized: "已存 ••••\(current!.last4)，不换就空着"), text: $apiKey)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    if relay {
                        TextField("接口地址（https://…/v1）", text: $baseURL)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    }
                    TextField(relay ? String(localized: "模型名（必填）") : String(localized: "模型名（空着用 \(defaults[provider] ?? "")）"), text: $modelName)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                } footer: {
                    Text(slot == "draw"
                         ? String(localized: "只填一个模型名，是这家的画图模型；空着用默认的。中转站填它后台里画图模型的名字。这把只管画图，不会拿去聊天。")
                         : String(localized: "填一个会看图的模型；空着用默认的。中转站填它后台里会看图的模型名字。这把只管看图，不会拿去聊天。"))
                }
                if let result {
                    Section { Label(result.text, systemImage: result.ok ? "checkmark.circle" : "exclamationmark.triangle")
                        .foregroundStyle(result.ok ? theme.accentDeep : .red) }
                }
                if current != nil {
                    Section { Button("清掉这一栏", role: .destructive) { Task { await save(clear: true) } } }
                }
            }
            .navigationTitle(slot == "draw" ? String(localized: "画图钥匙") : String(localized: "看图钥匙"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(result?.ok == true ? "好" : "取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if saving { ProgressView() } else {
                        Button("存") { Task { await save(clear: false) } }
                            .disabled((current == nil && apiKey.trimmingCharacters(in: .whitespaces).isEmpty)
                                      || (relay && (baseURL.trimmingCharacters(in: .whitespaces).isEmpty || modelName.trimmingCharacters(in: .whitespaces).isEmpty)))
                    }
                }
            }
            .onAppear {
                if let c = current { provider = c.provider; baseURL = c.baseURL ?? ""; modelName = c.model }
            }
        }
    }

    private func save(clear: Bool) async {
        saving = true
        defer { saving = false }
        let body: [String: Any] = clear ? [:] : ["provider": provider, "api_key": apiKey, "base_url": relay ? baseURL : "", "model": modelName]
        do {
            let r: Saved = try await model.api.call("PUT", "me/media/direct/\(slot)", json: body)
            if let m: MediaKeysCard.Media = try? await model.api.call("GET", "me/media") { onSaved(m) }
            if clear { dismiss(); return }
            apiKey = ""
            result = r.check.map { ($0.ok, $0.message) } ?? (true, String(localized: "存好了"))
        } catch let e as APIError {
            result = (false, e.message)
        } catch {
            result = (false, String(localized: "没存上，过会儿再试"))
        }
    }
}
