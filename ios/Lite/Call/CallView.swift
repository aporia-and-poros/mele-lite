#if LITE
import PhotosUI
import SwiftUI
import MeleLiteCore

/// 通话页（10-31，照微信语音通话）：中间大头像 + 名字，计时在三个键上面；静音 / 挂断 / 免提。
/// 右上「···」：字幕开关、说完判定快 / 中 / 慢、上一句各段花了多久。
/// 字幕开着时头像缩到上面，下面是两边的气泡：你那句先灰、认准了变实；TA 那句念到哪出到哪。
struct CallView: View {
    @StateObject private var call: CallSession
    let name: String
    let avatar: UIImage?
    let onClose: () -> Void
    @AppStorage("callCaptions") private var captionsOn = false
    @AppStorage("callEndpoint") private var endpoint = "mid"
    /// 自己导入的背景（10-31 Aporia）：每个 TA 一张，存在 Documents/call-bg-<TA>.jpg；没有就用糊开的头像
    @State private var custom: UIImage?
    @State private var picking = false
    @State private var picked: PhotosPickerItem?
    private let bgURL: URL

    init(conversation: String, api: APIClient?, name: String, avatar: UIImage?, onClose: @escaping () -> Void) {
        self.init(session: CallSession(conversation: conversation, api: api), conversation: conversation, name: name, avatar: avatar,
                  onClose: onClose)
    }

    /// TA 打来、接起来的那通（10-31 第 4 步）：通话已经在 IncomingCalls 里开始了，这里接着画
    init(session: CallSession, conversation: String, name: String, avatar: UIImage?, onClose: @escaping () -> Void) {
        _call = StateObject(wrappedValue: session)
        let who = LocalHost.shared.companion(ofConversation: conversation)?["id"] as? String ?? conversation
        bgURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("call-bg-\(who).jpg")
        _custom = State(initialValue: UIImage(contentsOfFile: bgURL.path))
        self.name = name
        self.avatar = avatar
        self.onClose = onClose
    }

    var body: some View {
        ZStack {
            backdrop
            VStack(spacing: 0) {
                topBar
                if captionsOn {
                    compactHeader
                    captionList
                } else {
                    bigHeader
                        .padding(.top, 100)         // 照微信：头像在上三分之一（10-31 Aporia：往上去一点，又说下来一点点）
                    Spacer()
                }
                if let n = call.notice {
                    Text(n)
                        .font(Typo.sans(Typo.Size.callout))
                        .foregroundStyle(.white.opacity(0.85))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(Capsule().fill(.white.opacity(0.12)))
                        .padding(.horizontal, 24).padding(.bottom, 14)
                }
                if !captionsOn && call.phase == .live {
                    Text(CallSpeech.clock(call.seconds))
                        .font(.system(size: 17, weight: .regular).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.bottom, 28)
                }
                buttons
                    .padding(.bottom, 36)
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(false)
        .task { await call.start(endpoint: endpoint) }
        .photosPicker(isPresented: $picking, selection: $picked, matching: .images)
        .onChange(of: picked) { _, item in
            guard let item else { return }
            Task {
                if let d = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: d),
                   let jpg = LocalBrain.jpeg(img, maxSide: 1600) {
                    try? jpg.write(to: bgURL)
                    custom = UIImage(data: jpg)
                }
                picked = nil
            }
        }
        .onChange(of: endpoint) { _, v in call.setEndpoint(v) }
        .onDisappear { call.hangUp() }
    }

    // MARK: 背景：头像糊开 + 压暗（微信那样）

    private var backdrop: some View {
        ZStack {
            Color(red: 0.11, green: 0.11, blue: 0.12)
            if let custom {
                // 自己挑的图照原样铺满，上下压一层暗，字和键看得清
                Color.clear.overlay { Image(uiImage: custom).resizable().scaledToFill() }.clipped()
                LinearGradient(colors: [.black.opacity(0.45), .black.opacity(0.1), .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
            } else if let avatar {
                Image(uiImage: avatar)
                    .resizable().scaledToFill()
                    .blur(radius: 60)
                    .opacity(0.55)
            }
            if custom == nil { Color.black.opacity(0.35) }
        }
        .ignoresSafeArea()
    }

    private var topBar: some View {
        HStack {
            Spacer()
            Menu {
                Toggle(isOn: $captionsOn) { Label("字幕", systemImage: "captions.bubble") }
                Picker(selection: $endpoint) {
                    Text("快（停 0.7 秒）").tag("fast")
                    Text("中（停 1 秒）").tag("mid")
                    Text("慢（停 1.4 秒）").tag("slow")
                } label: { Label("说完判定", systemImage: "waveform.badge.mic") }
                Button { picking = true } label: { Label("换背景", systemImage: "photo") }
                if custom != nil {
                    Button {
                        try? FileManager.default.removeItem(at: bgURL)
                        custom = nil
                    } label: { Label("换回头像背景", systemImage: "arrow.uturn.backward") }
                }
                if let t = call.lastTiming {
                    Section("上一句") { Text(t) }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
            }
        }
        .padding(.horizontal, 12)
    }

    private var statusText: String {
        switch call.phase {
        case .connecting: String(localized: "正在接通…")
        case .ended: String(localized: "通话结束")
        case .live:
            switch call.ta {
            case .listening: String(localized: "在听")
            case .thinking: String(localized: "在想…")
            case .speaking: String(localized: "在说")
            }
        }
    }

    private func face(_ side: CGFloat) -> some View {
        Group {
            if let avatar {
                Image(uiImage: avatar).resizable().scaledToFill()
            } else {
                ZStack {
                    Color.white.opacity(0.15)
                    Text(String(name.prefix(1))).font(.system(size: side * 0.4, weight: .medium)).foregroundStyle(.white)
                }
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: side * 0.12, style: .continuous))
    }

    /// TA 说话时头像外面的音波：两圈跟着声音大小一胀一缩，像呼吸
    private func breathing(_ side: CGFloat) -> some View {
        let v = CGFloat(call.voiceLevel)
        return ZStack {
            ForEach(0..<2, id: \.self) { i in
                let grow = 1 + v * (i == 0 ? 0.12 : 0.24)
                RoundedRectangle(cornerRadius: side * 0.16, style: .continuous)
                    .stroke(Color.white.opacity((i == 0 ? 0.45 : 0.25) * Double(v > 0 ? 0.35 + v * 0.65 : 0)), lineWidth: i == 0 ? 2 : 1.5)
                    .frame(width: side * grow + 12, height: side * grow + 12)
            }
        }
        .animation(.easeOut(duration: 0.12), value: call.voiceLevel)
    }

    private var bigHeader: some View {
        VStack(spacing: 14) {
            face(112)
                .background(breathing(112))
                .padding(.vertical, 18)          // 外圈胀开时不碰到名字
            Text(name)
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(.white)
            Text(statusText)
                .font(Typo.sans(Typo.Size.body))
                .foregroundStyle(.white.opacity(0.6))
                .animation(.easeOut(duration: 0.2), value: statusText)
        }
    }

    private var compactHeader: some View {
        HStack(spacing: 12) {
            face(52)
                .background(breathing(52))
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(.system(size: 18, weight: .medium)).foregroundStyle(.white)
                Text(call.phase == .live ? "\(CallSpeech.clock(call.seconds)) · \(statusText)" : statusText)
                    .font(Typo.sans(Typo.Size.callout).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.6))
            }
            Spacer()
        }
        .padding(.horizontal, 20).padding(.bottom, 10)
    }

    private var captionList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(call.captions) { c in
                        HStack {
                            if c.mine { Spacer(minLength: 48) }
                            Text(c.text.isEmpty ? "…" : c.text)
                                .font(Typo.sans(16))
                                .foregroundStyle(c.mine ? (c.gray ? Color.white.opacity(0.45) : Color.black) : Color.white)
                                .padding(.horizontal, 13).padding(.vertical, 9)
                                .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(c.mine ? (c.gray ? Color.white.opacity(0.12) : Color(red: 0.58, green: 0.92, blue: 0.42))
                                                 : Color.white.opacity(0.16)))
                                .animation(.easeOut(duration: 0.2), value: c.gray)
                            if !c.mine { Spacer(minLength: 48) }
                        }
                        .id(c.id)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
            }
            .onChange(of: call.captions.last?.id) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .bottom) }
            }
            .onChange(of: call.captions.last?.text) { _, _ in
                if let id = call.captions.last?.id { proxy.scrollTo(id, anchor: .bottom) }
            }
        }
    }

    // MARK: 三个键

    private var buttons: some View {
        HStack(alignment: .top) {
            roundKey(icon: call.muted ? "mic.slash.fill" : "mic.fill", label: call.muted ? "麦克风已关" : "麦克风已开",
                     on: call.muted) { call.muted.toggle() }
                .disabled(call.phase != .live)
            Spacer()
            VStack(spacing: 10) {
                Button {
                    call.hangUp()
                    onClose()
                } label: {
                    Image(systemName: "phone.down.fill")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 72, height: 72)
                        .background(Circle().fill(Color(red: 0.98, green: 0.26, blue: 0.25)))
                }
                Text(call.phase == .live ? "挂断" : "取消").font(Typo.sans(Typo.Size.callout)).foregroundStyle(.white.opacity(0.8))
            }
            Spacer()
            roundKey(icon: call.speaker ? "speaker.wave.2.fill" : "speaker.fill", label: call.speaker ? "扬声器已开" : "扬声器已关",
                     on: call.speaker) { call.speaker.toggle() }
                .disabled(call.phase != .live)
        }
        .padding(.horizontal, 36)
    }

    private func roundKey(icon: String, label: LocalizedStringKey, on: Bool, action: @escaping () -> Void) -> some View {
        VStack(spacing: 10) {
            Button(action: action) {
                Image(systemName: icon)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(on ? Color.black : Color.white)
                    .frame(width: 72, height: 72)
                    .background(Circle().fill(on ? Color.white : Color.white.opacity(0.16)))
            }
            Text(label).font(Typo.sans(Typo.Size.callout)).foregroundStyle(.white.opacity(0.8))
        }
    }
}
#endif
