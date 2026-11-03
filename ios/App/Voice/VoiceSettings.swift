import AVFoundation
import SwiftUI

// MARK: - 联系人设置里的「声音」（10-03）：档位、选嗓子（试听）、描述一把、额度、自己的 ElevenLabs key

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
    @State private var designing = false
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
                Text(name).font(Typo.sans(Typo.Size.body, .medium)).foregroundStyle(theme.ink)
                Text("自己描述的").font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkFaint)
                Spacer()
                Image(systemName: "checkmark").foregroundStyle(theme.accent)
            }
        }
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
            if Lite.local {
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
                Text(open ? "收起" : "换嗓子、描述一把、ElevenLabs key")
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
                        Text(name).font(Typo.sans(Typo.Size.body, .medium)).foregroundStyle(theme.ink)
                        Text("自己描述的").font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkFaint)
                        Spacer()
                        Image(systemName: "checkmark").foregroundStyle(theme.accent)
                    }
                }
                Button { designing = true } label: {
                    Label("描述一把嗓子", systemImage: "wand.and.stars")
                }
                .buttonStyle(.plain).foregroundStyle(theme.accent)
                .disabled(quota?.ownKey != true)
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
    }

    private var callVoiceNote: String {
        switch store.settings["call_voice"] as? String ?? "fast" {
        case "expressive": String(localized: "跟语音条同一个模型，语气更丰富，开口慢一点。走你的 ElevenLabs key。")
        case "system": String(localized: "iPhone 自带的声音，免费、不用 ElevenLabs key，听起来是机器念的。")
        default: String(localized: "开口最快的那档，走你的 ElevenLabs key。")
        }
    }

    private func isChosen(_ p: VoicePresetDTO) -> Bool {
        currentID.isEmpty ? p.key == presets.first?.key : p.voiceID == currentID
    }

    private func load() async {
        let lang = Locale.current.language.languageCode?.identifier == "en" ? "en" : "zh"
        presets = (try? await store.api.call("GET", "voice/presets", query: [URLQueryItem(name: "lang", value: lang)])) ?? []
        quota = try? await store.api.call("GET", "voice/quota")
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
