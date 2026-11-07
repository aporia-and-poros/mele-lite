import AVFoundation
import SwiftUI

// MARK: - 联系人设置里的「声音」（10-03）：档位、选嗓子（试听）、音色库 / 填音色 ID、模型（11-07）、描述一把、额度、自己的 ElevenLabs key

struct VoicePresetDTO: Decodable, Identifiable, Hashable {
    let key: String
    let voiceID: String
    let name: String
    let gender: String
    let about: String
    let preview: String
    var id: String { key }
    enum CodingKeys: String, CodingKey { case key, name, gender, about, preview; case voiceID = "voice_id" }
}

struct VoiceModelDTO: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let tags: Bool      // 认不认 [soft] 这种语气标签
}

struct VoiceQuotaDTO: Decodable {
    let charsLeft: Int
    let ownKey: Bool
    enum CodingKeys: String, CodingKey { case charsLeft = "chars_left", ownKey = "own_key" }
}

/// 试听：一段内存里的 mp3（预设的试听、设计出来的三把）
@MainActor
final class VoicePreviewPlayer: ObservableObject {
    static let shared = VoicePreviewPlayer()
    @Published private(set) var playing: String?
    private var player: AVAudioPlayer?

    func play(_ key: String, data: Data) {
        VoicePlayer.shared.stop()
        if playing == key { stop(); return }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        player = try? AVAudioPlayer(data: data)
        player?.play()
        playing = player == nil ? nil : key
    }

    func stop() { player?.stop(); player = nil; playing = nil }
}

struct VoiceSettingsSection: View {
    @EnvironmentObject private var theme: AppTheme
    @ObservedObject var store: CompanionSettingsStore
    let companionID: UUID
    @ObservedObject private var preview = VoicePreviewPlayer.shared
    @State private var presets: [VoicePresetDTO] = []
    @State private var quota: VoiceQuotaDTO?
    @State private var cache: [String: Data] = [:]
    @State private var models: [VoiceModelDTO] = []
    @State private var designing = false
    @State private var browsing = false
    @State private var note: String?
    @State private var open = false          // 平时只露频次 + 选中的嗓子，点开才展开（10-03）

    private var currentID: String { store.settings["voice_id"] as? String ?? "" }

    /// 收起时露出来的那一行：现在用的嗓子，能直接试听
    @ViewBuilder
    private var chosenRow: some View {
        if let p = presets.first(where: { isChosen($0) }) {
            HStack(spacing: 12) {
                Button { Task { await listen(p) } } label: {
                    Image(systemName: preview.playing == p.key ? "stop.circle.fill" : "play.circle")
                        .font(.system(size: 24)).foregroundStyle(theme.accent)
                }
                .buttonStyle(.plain)
                Text(p.name).font(Typo.sans(Typo.Size.body, .medium)).foregroundStyle(theme.ink)
                Spacer()
                Image(systemName: "checkmark").foregroundStyle(theme.accent)
            }
        } else if let name = store.settings["voice_name"] as? String, !name.isEmpty {
            HStack {
                Text(name).font(Typo.sans(Typo.Size.body, .medium)).foregroundStyle(theme.ink).lineLimit(1)
                Text("我的音色").font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkFaint)
                Spacer()
                Image(systemName: "checkmark").foregroundStyle(theme.accent)
            }
        }
    }

    /// 选模型：没选过（空）显示默认那个；选过的模型表里没有了也留着显示
    private var modelID: Binding<String> {
        let s = store.s("voice_model", Self.defaultModel)
        return Binding(get: { s.wrappedValue.isEmpty ? Self.defaultModel : s.wrappedValue }, set: { s.wrappedValue = $0 })
    }
    private static let defaultModel = "eleven_v4"
    private var modelChoices: [VoiceModelDTO] {
        let id = modelID.wrappedValue
        return models.contains { $0.id == id } ? models : models + [VoiceModelDTO(id: id, name: id, tags: id.hasPrefix("eleven_v"))]
    }
    private var modelNote: String {
        let tags = modelChoices.first { $0.id == modelID.wrappedValue }?.tags ?? true
        return tags ? String(localized: "语音条、念给我听、电话的「有表情」都用它。这个模型认语气标签。")
                    : String(localized: "语音条、念给我听、电话的「有表情」都用它。这个模型不认语气标签，念之前会把 [标签] 去掉，语气会平一点。")
    }

    var body: some View {
        Tile {
            Picker("语音条", selection: store.s("voice_mode", "sometimes")) {
                Text("不发").tag("off")
                Text("偶尔").tag("sometimes")
                Text("常常").tag("often")
            }
            .pickerStyle(.segmented)
            if !open {
                chosenRow
            }
            // 打电话时 TA 用哪种声音（10-31）：快 = 低延迟那档；有表情 = 语音条那个模型；iPhone 自带 = 免费、不用 key（明着选的，不是失败时偷换）
            // 11-03：连 Host 也给（第 3 步 Host 能打电话以后这里还只认本机，连 Host 的人选不到）
            if Lite.on {
                VStack(alignment: .leading, spacing: 6) {
                    Text("电话里的声音").font(Typo.sans(Typo.Size.callout)).foregroundStyle(theme.inkDim)
                    Picker("电话里的声音", selection: store.s("call_voice", "fast")) {
                        Text("快").tag("fast")
                        Text("有表情").tag("expressive")
                        Text("iPhone 自带").tag("system")
                    }
                    .pickerStyle(.segmented)
                    Text(callVoiceNote).font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkFaint)
                }
            }
            ExpandRow(open: $open) {
                Text(open ? "收起" : "换嗓子、音色库、模型、ElevenLabs key")
                    .font(Typo.sans(Typo.Size.callout)).foregroundStyle(theme.inkDim)
            } content: {
              VStack(alignment: .leading, spacing: 14) {
                ForEach(presets) { p in
                    HStack(spacing: 12) {
                        Button { Task { await listen(p) } } label: {
                            Image(systemName: preview.playing == p.key ? "stop.circle.fill" : "play.circle")
                                .font(.system(size: 24)).foregroundStyle(theme.accent)
                        }
                        .buttonStyle(.plain)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.name).font(Typo.sans(Typo.Size.body, .medium)).foregroundStyle(theme.ink)
                            Text(p.about).font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkFaint)
                        }
                        Spacer()
                        if isChosen(p) {
                            Image(systemName: "checkmark").foregroundStyle(theme.accent)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { Task { await choose(p) } }
                }
                if let name = store.settings["voice_name"] as? String, !name.isEmpty,
                   !presets.contains(where: { $0.voiceID == currentID }) {
                    HStack {
                        Text(name).font(Typo.sans(Typo.Size.body, .medium)).foregroundStyle(theme.ink).lineLimit(1)
                        Text("我的音色").font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkFaint)
                        Spacer()
                        Image(systemName: "checkmark").foregroundStyle(theme.accent)
                    }
                }
                Button { browsing = true } label: {
                    Label("我的音色库 / 填音色 ID", systemImage: "music.mic")
                }
                .buttonStyle(.plain).foregroundStyle(theme.accent)
                .disabled(quota?.ownKey != true)
                Button { designing = true } label: {
                    Label("描述一把嗓子", systemImage: "wand.and.stars")
                }
                .buttonStyle(.plain).foregroundStyle(theme.accent)
                .disabled(quota?.ownKey != true)
                if quota?.ownKey == true, !models.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("模型").font(Typo.sans(Typo.Size.body, .medium)).foregroundStyle(theme.ink)
                            Spacer()
                            Picker("模型", selection: modelID) {
                                ForEach(modelChoices) { Text($0.name).tag($0.id) }
                            }
                            .pickerStyle(.menu).tint(theme.accent)
                        }
                        Hint(text: modelNote)
                    }
                }
                if let quota {
                    Text(quota.ownKey ? String(localized: "用的是你自己的 ElevenLabs key")
                         : Lite.on ? String(localized: "填了自己的 ElevenLabs key 才有声音")
                                   : String(localized: "声音额度还剩 \(quota.charsLeft) 字"))
                        .font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkFaint)
                }
                Hint(text: String(localized: "声音 key 在 Me → 钥匙串里加（选 ElevenLabs）。"))
              }
            }
            if let note { Text(note).font(Typo.sans(Typo.Size.caption)).foregroundStyle(.red) }
        } header: { GlassHeader(String(localized: "声音")) } footer: {
            if open {
                Text(Lite.on ? "TA 想说出声的时候会发语音条；长按 TA 的任何一句也能「念给我听」；你也能按住麦克风发语音。都走你自己的 ElevenLabs key。"
                             : "TA 想说出声的时候会发语音条；长按 TA 的任何一句也能「念给我听」。描述一把嗓子要会员或者自己的 ElevenLabs key。")
            }
        }
        .task { await load() }
        .sheet(isPresented: $designing) {
            VoiceDesignView(api: store.api, companionID: companionID) { id, name in
                store.settings["voice_id"] = id
                store.settings["voice_name"] = name
            }
            .presentationDetents([.large])
        }
        .sheet(isPresented: $browsing) {
            VoiceLibraryView(api: store.api, companionID: companionID, currentID: currentID.isEmpty ? presets.first?.voiceID ?? "" : currentID) { id, name in
                store.settings["voice_id"] = id
                store.settings["voice_name"] = name
                note = nil
            }
            .presentationDetents([.large])
        }
    }

    private var callVoiceNote: String {
        switch store.settings["call_voice"] as? String ?? "fast" {
        case "expressive": Lite.hosted ? String(localized: "跟语音条同一个模型，语气更丰富，开口慢一点。走 Host 上的 ElevenLabs key。")
                                       : String(localized: "跟语音条同一个模型，语气更丰富，开口慢一点。走你的 ElevenLabs key。")
        case "system": String(localized: "iPhone 自带的声音，免费、不用 ElevenLabs key，听起来是机器念的。")
        default: Lite.hosted ? String(localized: "开口最快的那档，走 Host 上的 ElevenLabs key。")
                             : String(localized: "开口最快的那档，走你的 ElevenLabs key。")
        }
    }

    private func isChosen(_ p: VoicePresetDTO) -> Bool {
        currentID.isEmpty ? p.key == presets.first?.key : p.voiceID == currentID
    }

    private func load() async {
        let lang = Locale.current.language.languageCode?.identifier == "en" ? "en" : "zh"
        presets = (try? await store.api.call("GET", "voice/presets", query: [URLQueryItem(name: "lang", value: lang)])) ?? []
        quota = try? await store.api.call("GET", "voice/quota")
        models = (try? await store.api.call("GET", "voice/models")) ?? []     // 旧 Host 没这个接口：不露选模型那行
    }

    private func listen(_ p: VoicePresetDTO) async {
        if let d = cache[p.key] { preview.play(p.key, data: d); return }
        guard let d = try? await store.api.data(p.preview) else { return }
        cache[p.key] = d
        preview.play(p.key, data: d)
    }

    private func choose(_ p: VoicePresetDTO) async {
        do {
            _ = try await store.api.raw("POST", "companions/\(companionID.uuidString.lowercased())/voice",
                                        json: ["voice_id": p.voiceID, "name": p.name])
            store.settings["voice_id"] = p.voiceID
            store.settings["voice_name"] = p.name
            note = nil
        } catch {
            note = (error as? APIError)?.message ?? String(localized: "没换成")
        }
    }
}

/// 音色库（11-07，内测）：拉这把 key 账号里的嗓子，或者直接粘贴一个音色 ID
struct VoiceLibraryView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var theme: AppTheme
    @ObservedObject private var preview = VoicePreviewPlayer.shared
    let api: APIClient
    let companionID: UUID
    let currentID: String
    let onSaved: (String, String) -> Void

    struct Item: Decodable, Identifiable, Hashable {
        let voiceID: String
        let name: String
        let category: String
        let about: String
        let preview: String
        var id: String { voiceID }
        enum CodingKeys: String, CodingKey { case name, category, about, preview; case voiceID = "voice_id" }
    }

    @State private var items: [Item] = []
    @State private var loading = true
    @State private var loadError: String?
    @State private var typed = ""
    @State private var query = ""
    @State private var busy = false
    @State private var error: String?

    private var shown: [Item] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? items : items.filter { $0.name.localizedCaseInsensitiveContains(q) || $0.about.localizedCaseInsensitiveContains(q) }
    }
    private var mine: [Item] { shown.filter { $0.category != "premade" } }
    private var official: [Item] { shown.filter { $0.category == "premade" } }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("粘贴音色 ID", text: $typed)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button(busy ? "存着呢…" : "用这个 ID") { Task { await use(typed.trimmingCharacters(in: .whitespacesAndNewlines), name: "") } }
                        .disabled(busy || typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if let error { Text(error).font(Typo.sans(Typo.Size.caption)).foregroundStyle(.red) }
                } footer: { Text("在 ElevenLabs 的 Voices 页面，点一把声音的 ⋯ 就能复制 ID。公共声音库里的也能用。") }
                if loading {
                    Section { HStack { ProgressView(); Text("正在拉音色库…").foregroundStyle(theme.inkDim) } }
                } else if let loadError {
                    Section { Text(loadError).font(Typo.sans(Typo.Size.caption)).foregroundStyle(.red) }
                } else {
                    if !mine.isEmpty { Section("我的音色") { ForEach(mine) { row($0) } } }
                    if !official.isEmpty { Section("ElevenLabs 官方") { ForEach(official) { row($0) } } }
                    if shown.isEmpty { Section { Text("没有找到").foregroundStyle(theme.inkFaint) } }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: Text("搜名字"))
            .navigationTitle("音色库")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { preview.stop(); dismiss() } } }
            .task { await load() }
        }
    }

    private func row(_ v: Item) -> some View {
        HStack(spacing: 12) {
            if !v.preview.isEmpty {
                Button { Task { await listen(v) } } label: {
                    Image(systemName: preview.playing == v.id ? "stop.circle.fill" : "play.circle")
                        .font(.system(size: 24)).foregroundStyle(theme.accent)
                }
                .buttonStyle(.plain)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(v.name).font(Typo.sans(Typo.Size.body, .medium)).foregroundStyle(theme.ink).lineLimit(2)
                if !v.about.isEmpty {
                    Text(v.about).font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkFaint).lineLimit(2)
                }
            }
            Spacer()
            if v.voiceID == currentID { Image(systemName: "checkmark").foregroundStyle(theme.accent) }
        }
        .contentShape(Rectangle())
        .onTapGesture { Task { await use(v.voiceID, name: v.name) } }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            items = try await api.call("GET", "voice/library")
            loadError = nil
        } catch {
            let e = error as? APIError
            loadError = e?.status == 404 ? String(localized: "这台 Host 还没更新，暂时拉不了音色库；上面填音色 ID 还能用。")
                                         : e?.message ?? String(localized: "没拉下来，等会儿再试")
        }
    }

    /// 试听是 ElevenLabs 公开的音频链接，不用带 key
    private func listen(_ v: Item) async {
        if preview.playing == v.id { preview.stop(); return }
        guard let url = URL(string: v.preview), url.scheme == "https",
              let (d, _) = try? await URLSession.shared.data(from: url) else { return }
        preview.play(v.id, data: d)
    }

    private func use(_ id: String, name: String) async {
        busy = true; error = nil
        defer { busy = false }
        do {
            var body = ["voice_id": id]
            if !name.isEmpty { body["name"] = name }
            let r: [String: String] = try await api.call("POST", "companions/\(companionID.uuidString.lowercased())/voice", json: body)
            onSaved(r["voice_id"] ?? id, r["voice_name"] ?? name)
            preview.stop()
            dismiss()
        } catch {
            self.error = (error as? APIError)?.message ?? String(localized: "没换成")
        }
    }
}

/// 描述一把：写一句 → 三把试听 → 挑一把、起个名字存下
struct VoiceDesignView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var theme: AppTheme
    @ObservedObject private var preview = VoicePreviewPlayer.shared
    let api: APIClient
    let companionID: UUID
    let onSaved: (String, String) -> Void

    struct Option: Decodable, Identifiable {
        let generatedVoiceID: String
        let audioBase64: String
        var id: String { generatedVoiceID }
        enum CodingKeys: String, CodingKey { case generatedVoiceID = "generated_voice_id", audioBase64 = "audio_base_64" }
    }

    @State private var text = ""
    @State private var name = ""
    @State private var options: [Option] = []
    @State private var picked: String?
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("比如：低一点、懒洋洋的、带点气声", text: $text, axis: .vertical).lineLimit(2...4)
                    Button(busy && options.isEmpty ? "生成中…" : "生成三把试听") { Task { await design() } }
                        .disabled(busy || text.trimmingCharacters(in: .whitespaces).count < 8)
                } footer: { Text("写 8～400 个字。每生成一次会花一点钱。") }
                if !options.isEmpty {
                    Section {
                        ForEach(Array(options.enumerated()), id: \.element.id) { i, o in
                            HStack {
                                Button {
                                    if let d = Data(base64Encoded: o.audioBase64) { preview.play(o.id, data: d) }
                                } label: {
                                    Image(systemName: preview.playing == o.id ? "stop.circle.fill" : "play.circle")
                                        .font(.system(size: 24)).foregroundStyle(theme.accent)
                                }
                                .buttonStyle(.plain)
                                Text(String(localized: "第 \(i + 1) 把")).foregroundStyle(theme.ink)
                                Spacer()
                                if picked == o.id { Image(systemName: "checkmark").foregroundStyle(theme.accent) }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { picked = o.id }
                        }
                        TextField("给这把嗓子起个名字", text: $name)
                        Button("用这把") { Task { await save() } }.disabled(picked == nil || busy)
                    }
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("描述一把嗓子")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { preview.stop(); dismiss() } } }
        }
    }

    private func design() async {
        busy = true; error = nil
        defer { busy = false }
        do {
            options = try await api.call("POST", "voice/design", json: ["description": text])
            picked = options.first?.id
        } catch {
            self.error = (error as? APIError)?.message ?? String(localized: "没生成出来")
        }
    }

    private func save() async {
        guard let picked else { return }
        busy = true
        defer { busy = false }
        let n = name.trimmingCharacters(in: .whitespaces).isEmpty ? String(localized: "我的嗓子") : name
        do {
            let r: [String: String] = try await api.call("POST", "companions/\(companionID.uuidString.lowercased())/voice",
                                                         json: ["generated_voice_id": picked, "name": n, "description": text])
            onSaved(r["voice_id"] ?? "", r["voice_name"] ?? n)
            preview.stop()
            dismiss()
        } catch {
            self.error = (error as? APIError)?.message ?? String(localized: "没存上")
        }
    }
}
