#if LITE
import AVFoundation
import SwiftUI
import MeleLiteCore

/// 通话记录（10-31，第 5 步）：跟这个 TA 打过的每一通，新的在前；点开逐句看，TA 的每句能重听；左滑只藏不删。
struct CallHistoryView: View {
    @EnvironmentObject private var theme: AppTheme
    let conversation: String
    let name: String
    let api: APIClient?
    @State private var calls: [LocalCalls.Call] = []

    var body: some View {
        NavigationStack {
            List {
                if calls.isEmpty {
                    Text("还没打过电话").font(Typo.sans(Typo.Size.callout)).foregroundStyle(theme.inkFaint)
                }
                ForEach(calls) { c in
                    NavigationLink {
                        CallDetailView(call: c, name: name, api: api)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "phone.fill").foregroundStyle(theme.accent)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(c.at.formatted(date: .abbreviated, time: .shortened))
                                    .font(Typo.sans(Typo.Size.body)).foregroundStyle(theme.ink)
                                Text(c.endMessage == nil ? String(localized: "\(CallSpeech.clock(c.seconds)) · 没正常挂断")
                                                         : CallSpeech.clock(c.seconds))
                                    .font(Typo.sans(Typo.Size.caption).monospacedDigit()).foregroundStyle(theme.inkFaint)
                            }
                            Spacer()
                            Text(String(localized: "\(c.lines.count) 句")).font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkFaint)
                        }
                    }
                    .swipeActions {
                        Button {
                            if Lite.hosted, let api { Task { await LocalCalls.hide(api: api, conversation, c.id) } }
                            else { LocalCalls.hide(c.id) }
                            withAnimation { calls.removeAll { $0.id == c.id } }
                        } label: { Label("藏起来", systemImage: "eye.slash") }
                        .tint(.gray)
                    }
                }
            }
            .navigationTitle("通话记录")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                if Lite.hosted, let api { calls = await LocalCalls.list(api: api, conversation) }
                else { calls = LocalCalls.list(conversation) }
            }
        }
    }
}

/// 一通电话：你在右、TA 在左；TA 那句有声音的，点一下重听
struct CallDetailView: View {
    @EnvironmentObject private var theme: AppTheme
    let call: LocalCalls.Call
    let name: String
    let api: APIClient?
    @StateObject private var player = CallLinePlayer()

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                Text("\(call.at.formatted(date: .abbreviated, time: .shortened)) · \(CallSpeech.clock(call.seconds))")
                    .font(Typo.sans(Typo.Size.caption).monospacedDigit()).foregroundStyle(theme.inkFaint)
                    .padding(.bottom, 4)
                ForEach(call.lines) { l in
                    HStack(alignment: .center, spacing: 8) {
                        if l.mine { Spacer(minLength: 48) }
                        Text(l.text)
                            .font(Typo.sans(Typo.Size.body))
                            .foregroundStyle(theme.ink)
                            .padding(.horizontal, 13).padding(.vertical, 9)
                            .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(l.mine ? theme.accent.opacity(0.22) : theme.ink.opacity(0.06)))
                            .textSelection(.enabled)
                        if l.audio != nil || l.remote != nil {
                            Button { player.toggle(l, api: api) } label: {
                                Image(systemName: player.playing == l.text + "\(l.id)" ? "stop.circle.fill" : "play.circle")
                                    .font(.system(size: 22)).foregroundStyle(theme.accent)
                            }
                            .buttonStyle(.plain)
                        }
                        if !l.mine { Spacer(minLength: 24) }
                    }
                }
            }
            .padding(16)
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { player.stop() }
    }
}

/// 从聊天里那行「📞 通话时长」直接点开的那一通（外面套个导航栏）
struct CallDetailSheet: View {
    let conversation: String
    let endMessage: Int
    let name: String
    let api: APIClient?
    @EnvironmentObject private var theme: AppTheme
    @State private var found: LocalCalls.Call?
    @State private var looked = false

    var body: some View {
        NavigationStack {
            if let c = found {
                CallDetailView(call: c, name: name, api: api)
            } else if looked {
                Text("找不到这通电话的记录").font(Typo.sans(Typo.Size.callout)).foregroundStyle(theme.inkFaint)
            } else {
                ProgressView()
            }
        }
        .task {
            if Lite.hosted, let api { found = await LocalCalls.list(api: api, conversation).first { $0.endMessage == endMessage } }
            else { found = LocalCalls.call(conversation, endMessage: endMessage) }
            looked = true
        }
    }
}

@MainActor
final class CallLinePlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    /// 正在放的那句（这句话 + 第几句）
    @Published private(set) var playing: String?
    private var player: AVAudioPlayer?

    func toggle(_ line: LocalCalls.Line, api: APIClient?) {
        let key = line.text + "\(line.id)"
        if playing == key { stop(); return }
        stop()
        playing = key
        Task {
            var data: Data?
            if let url = line.audio { data = try? Data(contentsOf: url) }
            else if let path = line.remote, let api { data = try? await api.data(path) }      // 连着 Host：现拿
            guard playing == key, let data, let p = try? AVAudioPlayer(data: data) else {
                if playing == key { playing = nil }
                return
            }
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try? AVAudioSession.sharedInstance().setActive(true)
            p.delegate = self
            p.play()
            player = p
        }
    }

    func stop() {
        player?.stop()
        player = nil
        playing = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.stop() }
    }
}
#endif
