import AVFoundation
import SwiftUI

// MARK: - 语音条（10-03，服务器 server/brain/voice.py / api/routes_voice.py；设计 docs/specs/2026-10-03-voice-notes-design.md）
//
// 它在回复里用 🎤 标的那条，服务器念好挂在气泡上（事件流 / 历史里的 voice: {id, duration_ms}）。
// 气泡里：播放键 + 波形条 + 时长；点一下逐字稿展开 / 收起。一次只放一条。
// 样子先跟着 Mele 气泡走，统一调 UI 那一轮用Aporia的 Canva 稿重画。

struct VoiceRef: Decodable, Hashable {
    let id: String
    let durationMs: Int
    /// 从哪取音频；空 = 它念的那段（voice/clips/<id>）。TA 自己的语音是附件（attachments/<id>）
    var path: String?
    /// 还没念（10-31 按需念）：id 是稿子的指纹、秒数是估的；点了才去念（messages/<mid>/speak），念好换成真的那段
    var lazy = false
    enum CodingKeys: String, CodingKey { case id, lazy; case durationMs = "duration_ms" }

    init(id: String, durationMs: Int, path: String? = nil) {
        self.id = id; self.durationMs = durationMs; self.path = path
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        durationMs = try c.decode(Int.self, forKey: .durationMs)
        lazy = (try? c.decodeIfPresent(Bool.self, forKey: .lazy)) ?? false
    }
}

@MainActor
final class VoicePlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = VoicePlayer()

    @Published private(set) var playing: String?
    @Published private(set) var loading: String?
    @Published private(set) var progress: Double = 0
    /// 按需念的语音条（10-31）：占位编号 → 念好的那段；念不出来的那条说一声为什么
    @Published private(set) var resolved: [String: String] = [:]
    @Published private(set) var failed: [String: String] = [:]
    private var player: AVAudioPlayer?
    private var timer: Timer?

    private static var cacheDir: URL {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("voice")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func toggle(_ id: String, path: String? = nil, api: APIClient) {
        if playing == id { stop(); return }
        Task { await play(id, path: path, api: api) }
    }

    /// 气泡上那颗键：念好的照常放；还没念的先去念（只有这一下花钱），念好接着放
    func toggle(_ ref: VoiceRef, message: Int?, bubble: Int?, api: APIClient) {
        guard ref.lazy else { toggle(ref.id, path: ref.path, api: api); return }
        if let real = resolved[ref.id], playing == real { stop(); return }
        Task { await playLazy(ref, message: message, bubble: bubble, api: api) }
    }

    func playLazy(_ ref: VoiceRef, message: Int?, bubble: Int?, api: APIClient) async {
        if let real = resolved[ref.id] { await play(real, api: api); return }
        guard let mid = message, let index = bubble else {       // 这一轮还在推，消息号还没回来
            failed[ref.id] = String(localized: "还在发，等一下再点")
            return
        }
        stop()
        loading = ref.id
        defer { if loading == ref.id { loading = nil } }
        do {
            let clip: VoiceRef = try await api.call("POST", "messages/\(mid)/speak", json: ["index": index])
            resolved[ref.id] = clip.id
            failed[ref.id] = nil
            await play(clip.id, api: api)
        } catch {
            failed[ref.id] = (error as? APIError)?.message ?? String(localized: "没念出来")
        }
    }

    func play(_ id: String, path: String? = nil, api: APIClient) async {
        stop()
        let file = Self.cacheDir.appendingPathComponent(path == nil ? "\(id).mp3" : "\(id).m4a")
        if !FileManager.default.fileExists(atPath: file.path) {
            loading = id
            defer { if loading == id { loading = nil } }
            guard let data = try? await api.data(path ?? "voice/clips/\(id)") else { return }
            try? data.write(to: file)
        }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        guard let p = try? AVAudioPlayer(contentsOf: file) else { return }
        p.delegate = self
        p.play()
        player = p
        playing = id
        progress = 0
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let p = self.player, p.duration > 0 else { return }
                self.progress = p.currentTime / p.duration
            }
        }
    }

    func stop() {
        player?.stop()
        player = nil
        timer?.invalidate()
        timer = nil
        playing = nil
        progress = 0
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.stop() }
    }
}

/// 哪几条语音展开了文字（长按 →「转文字」，10-03 Aporia：像微信那样）
@MainActor
final class VoiceTranscripts: ObservableObject {
    static let shared = VoiceTranscripts()
    @Published var open: Set<String> = []
    func toggle(_ id: String) { if open.contains(id) { open.remove(id) } else { open.insert(id) } }
}

/// 气泡里面那一块（外面的底色、长按菜单照普通气泡）
struct VoiceNoteContent: View {
    @EnvironmentObject private var session: SessionStore
    @ObservedObject private var player = VoicePlayer.shared
    @ObservedObject private var transcripts = VoiceTranscripts.shared
    let voice: VoiceRef
    let transcript: String
    let ink: Color
    let accent: Color
    let fontSize: CGFloat
    /// 按需念的那种要知道是哪条消息的第几泡（10-31）
    var messageID: Int? = nil
    var bubble: Int? = nil
    private var failure: String? { player.failed[voice.id] }
    private var showText: Bool { transcripts.open.contains(voice.id) || failure != nil }   // 念不出来：把字摊开

    /// 正在放的那段的编号：按需念的念好以后换成真的那段
    private var playingID: String { voice.lazy ? player.resolved[voice.id] ?? voice.id : voice.id }
    private var isPlaying: Bool { player.playing == playingID }
    private func tap() { player.toggle(voice, message: messageID, bubble: bubble, api: session.api) }
    private var seconds: Int { max(1, Int((Double(voice.durationMs) / 1000).rounded())) }
    /// 波形条：按编号散出来的固定高度（假的，但每条长得不一样、刷新不变）
    private var bars: [CGFloat] {
        let n = min(28, max(12, seconds * 2))
        var h = voice.id.unicodeScalars.reduce(UInt64(1469598103934665603)) { ($0 ^ UInt64($1.value)) &* 1099511628211 }
        return (0..<n).map { _ in
            h = h &* 6364136223846793005 &+ 1442695040888963407
            return 0.28 + CGFloat(h >> 40 % 1000) / 1000 * 0.72
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button { tap() } label: {
                    ZStack {
                        Circle().fill(accent.opacity(0.9)).frame(width: 30, height: 30)
                        if player.loading == voice.id || player.loading == playingID {
                            ProgressView().tint(.white).scaleEffect(0.6)
                        } else {
                            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                                .offset(x: isPlaying ? 0 : 1)
                        }
                    }
                }
                .buttonStyle(.plain)
                HStack(alignment: .center, spacing: 2) {
                    ForEach(Array(bars.enumerated()), id: \.offset) { i, h in
                        let lit = isPlaying && Double(i) / Double(bars.count) <= player.progress
                        Capsule().fill(ink.opacity(lit ? 0.9 : 0.35)).frame(width: 2.5, height: 22 * h)
                    }
                }
                .frame(height: 22)
                Text("\(seconds)″").font(.system(size: fontSize * 0.8, weight: .medium).monospacedDigit())
                    .foregroundStyle(ink.opacity(0.7))
            }
            .contentShape(Rectangle())
            .onTapGesture { tap() }   // 点气泡 = 放 / 停；长按菜单里「转文字」
            if let failure {
                Text(failure).font(.system(size: fontSize * 0.72)).foregroundStyle(ink.opacity(0.55))
            }
            if showText && !transcript.isEmpty {
                Text(transcript)
                    .font(Typo.sans(fontSize * 0.88))
                    .foregroundStyle(ink.opacity(0.78))
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
        }
        .frame(minWidth: 150, alignment: .leading)
    }
}
