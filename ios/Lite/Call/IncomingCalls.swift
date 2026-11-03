#if LITE
import AVFoundation
import AudioToolbox
import SwiftUI
import UIKit
import UserNotifications
import MeleLiteCore

/// TA 打给你（10-31 第 4 步）。TA 用「打电话」工具决定打，这一轮到此结束，这边开始响：
/// - Lite 本机：盖一层自己的来电页（照微信），在哪一页都盖得上（单独一个 UIWindow）；
///   App 在后台时（10-31 Aporia）每 5 秒弹一条来电通知，响满一分钟算未接，你一打开 App 就收掉通知、接着响来电页
/// - 连着 Mele Host：VoIP 推送叫醒手机、系统来电横幅在响（HostVoIP），这里只记着状态、接了以后开通话页
/// 60 秒没接 = 未接；你按拒绝 = 已拒绝；TA 没等接通就撤回 = 对方已取消。三种都在聊天里留一行灰字，TA 下一轮看得到纸条。
@MainActor
final class IncomingCalls: NSObject, ObservableObject {
    static let shared = IncomingCalls()

    struct Ring: Identifiable, Equatable {
        let id: String              // 通话编号：接通以后这通电话的存档都带它
        let conversation: String
        let companion: String
        let reason: String
        let at: Date
        /// 连着 Host：系统来电横幅在响，不画自己的来电页
        let system: Bool
    }

    @Published private(set) var ringing: Ring?
    @Published private(set) var answered: Ring?
    /// 接起来的这通：一接就开始（锁屏上接的也是，那时还没有通话页），通话页出来时接着用它
    @Published private(set) var session: CallSession?
    weak var model: AppModel?
    var api: APIClient?
    /// 正在打电话（你打的或者接起来的）：TA 这时候再打进来就是占线
    var busy = false
    /// Host 那边的这通结束了（未接 / 撤回）：系统横幅要跟着收起来（HostVoIP 接）
    var onSystemRingEnded: ((String) -> Void)?
    /// 接起来的那通挂了：系统那边的通话也要结束（HostVoIP 接）
    var onSystemCallEnded: ((String) -> Void)?

    static let ringSeconds: Double = 60
    private var window: UIWindow?
    private var timeout: Task<Void, Never>?
    private var poll: Task<Void, Never>?
    private var bell: AVAudioPlayer?
    private var buzz: Timer?

    private override init() {
        super.init()
        // 你打开 App 的时候 TA 还在打：收掉通知，来电页接着响；已经响过一分钟了就记未接
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cameBack() }
        }
    }

    // MARK: Lite 本机：工具调用时

    enum Placed { case ringing, busy }

    /// 「打电话」工具：App 开着就盖来电页响铃；在后台就连着弹来电通知
    func place(conversation: String, companion: String, reason: String) -> Placed {
        if busy || ringing != nil || answered != nil { return .busy }
        let r = Ring(id: UUID().uuidString.lowercased(), conversation: conversation, companion: companion,
                     reason: reason, at: Date(), system: false)
        ringing = r
        present()
        if UIApplication.shared.applicationState == .active { startBell() } else { notify(r) }
        #if DEBUG
        // 自测（10-31）：SIMCTL_CHILD_LITE_TEST_RING=accept|decline|<空> 过 3 秒自动接 / 拒；空着就等 60 秒未接
        switch ProcessInfo.processInfo.environment["LITE_TEST_RING"] {
        case "accept": Task { try? await Task.sleep(for: .seconds(3)); if ringing?.id == r.id { accept() } }
        case "decline": Task { try? await Task.sleep(for: .seconds(3)); if ringing?.id == r.id { decline() } }
        default: break
        }
        #endif
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.ringSeconds))
            guard !Task.isCancelled, self?.ringing?.id == r.id else { return }
            self?.finish(.missed)
        }
        return .ringing
    }

    /// TA 反悔了（还没接的时候）：一行「对方已取消」
    func withdraw(conversation: String) -> Bool {
        guard let r = ringing, r.conversation == conversation else { return false }
        finish(.withdrawn)
        return true
    }

    // MARK: 连着 Host：VoIP 推送来了

    /// HostVoIP 收到推送、已经报给系统来电以后调；响铃期间每 3 秒问一次 Host 这通还在不在（撤回 / 未接由 Host 定）
    func incomingFromHost(callID: String, conversation: String, companion: String, reason: String) {
        guard ringing?.id != callID else { return }
        ringing = Ring(id: callID, conversation: conversation, companion: companion, reason: reason, at: Date(), system: true)
        poll?.cancel()
        poll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let self, let r = self.ringing, r.id == callID, let api = self.api else { return }
                guard let d = try? await api.raw("GET", "conversations/\(conversation)/call/ring/\(callID)") as? [String: Any] else { continue }
                let state = d["state"] as? String ?? "ringing"
                if state != "ringing", state != "answered", self.ringing?.id == callID {
                    self.ringing = nil
                    self.onSystemRingEnded?(callID)
                    return
                }
            }
        }
    }

    // MARK: 你按的

    func accept() {
        guard let r = ringing else { return }
        stopRinging()
        ringing = nil
        answered = r
        busy = true
        let s = CallSession(conversation: r.conversation, api: r.system ? api : nil, incoming: r)
        session = s
        let api = api
        Task {
            if r.system, let api { _ = try? await api.raw("POST", "conversations/\(r.conversation)/call/ring/\(r.id)/answer") }
            await s.start(endpoint: UserDefaults.standard.string(forKey: "callEndpoint") ?? "mid")
        }
        present()
    }

    /// 系统通话界面上按了挂断（Host 来电接起来以后）
    func hangUpFromSystem() {
        session?.hangUp()
        callClosed()
    }

    func decline() { finish(.declined) }

    /// 通话页关了（接起来的那通挂了）
    func callClosed() {
        if let r = answered, r.system { onSystemCallEnded?(r.id) }
        answered = nil
        session = nil
        busy = false
        dismiss()
    }

    private func finish(_ kind: CallSpeech.Ring) {
        guard let r = ringing else { return }
        ringing = nil
        stopRinging()
        if !r.system { unnotify(r, keepMissed: kind == .missed) }     // 在后台响完一分钟的：「未接来电」那条留在通知里
        dismiss()
        if r.system {
            // Host 自己记未接 / 撤回；拒绝是你按的，告诉它一声
            if kind == .declined, let api {
                Task { _ = try? await api.raw("POST", "conversations/\(r.conversation)/call/ring/\(r.id)/decline") }
            }
            if kind != .declined { onSystemRingEnded?(r.id) }
        } else {
            Task { await LocalHost.shared.brain.ringEnded(r.conversation, callID: r.id, ring: kind) }
        }
    }

    private func cameBack() {
        guard let r = ringing, !r.system else { return }
        unnotify(r, keepMissed: false)
        if Date().timeIntervalSince(r.at) >= Self.ringSeconds { finish(.missed); return }
        present()
        if bell == nil { startBell() }
    }

    // MARK: 后台：来电通知（每 5 秒一条，一分钟那条是「未接来电」）

    static let notifyEvery: Double = 5

    private func noteIDs(_ r: Ring) -> [String] {
        (0..<Int(Self.ringSeconds / Self.notifyEvery)).map { "ring-\(r.id)-\($0)" }
    }

    private func notify(_ r: Ring) {
        let name = who(r).name
        let st = LocalHost.shared.companion(ofConversation: r.conversation)?["settings"] as? [String: Any] ?? [:]
        let zh = (st["lang"] as? String ?? "zh") == "zh"                     // 跟 TA 说的语言走
        let info: [String: Any] = ["conversation": r.conversation, "companion": r.companion, "ring": r.id]
        let center = UNUserNotificationCenter.current()
        for (i, id) in noteIDs(r).enumerated() {
            let n = UNMutableNotificationContent()
            n.title = name
            n.body = r.reason.isEmpty ? (zh ? "📞 邀请你语音通话…" : "📞 Calling you…")
                                      : (zh ? "📞 邀请你语音通话：\(r.reason)" : "📞 Calling you: \(r.reason)")
            n.sound = .default
            n.threadIdentifier = "ring-\(r.id)"
            n.userInfo = info
            let when = i == 0 ? nil : UNTimeIntervalNotificationTrigger(timeInterval: Double(i) * Self.notifyEvery, repeats: false)
            center.add(UNNotificationRequest(identifier: id, content: n, trigger: when))
        }
        let m = UNMutableNotificationContent()
        m.title = name
        m.body = zh ? "📞 未接来电" : "📞 Missed call"
        m.sound = .default
        m.threadIdentifier = "ring-\(r.id)"
        m.userInfo = info
        center.add(UNNotificationRequest(identifier: "ring-\(r.id)-missed", content: m,
                                         trigger: UNTimeIntervalNotificationTrigger(timeInterval: Self.ringSeconds, repeats: false)))
    }

    /// 收掉这通的来电通知（响过一分钟记了未接的，「未接来电」那条留着）
    private func unnotify(_ r: Ring, keepMissed: Bool) {
        let ids = noteIDs(r) + (keepMissed ? [] : ["ring-\(r.id)-missed"])
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ids)
        center.removeDeliveredNotifications(withIdentifiers: ids)
    }

    private func stopRinging() {
        if let r = ringing ?? answered, !r.system { unnotify(r, keepMissed: false) }
        timeout?.cancel(); timeout = nil
        poll?.cancel(); poll = nil
        bell?.stop(); bell = nil
        buzz?.invalidate(); buzz = nil
    }

    // MARK: 铃声：自己合成两个音（像风铃），跟着静音键走；一起振动

    private func startBell() {
        try? AVAudioSession.sharedInstance().setCategory(.soloAmbient)
        try? AVAudioSession.sharedInstance().setActive(true)
        if let p = try? AVAudioPlayer(data: Self.chime()) {
            p.numberOfLoops = -1
            p.volume = 0.8
            p.play()
            bell = p
        }
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        buzz = Timer.scheduledTimer(withTimeInterval: 2.4, repeats: true) { _ in AudioServicesPlaySystemSound(kSystemSoundID_Vibrate) }
    }

    /// 两个音（E5 → C5）各 0.4 秒慢慢弱下去，后面空 1.6 秒；16 位单声道 WAV
    static func chime() -> Data {
        let rate = 22050.0
        var samples: [Int16] = []
        for (freq, len) in [(659.25, 0.42), (523.25, 0.55)] {
            let n = Int(rate * len)
            for i in 0..<n {
                let t = Double(i) / rate
                let env = min(1, t / 0.01) * exp(-t * 5.5)
                let v = (sin(2 * .pi * freq * t) + 0.25 * sin(4 * .pi * freq * t)) * env * 0.5
                samples.append(Int16(max(-1, min(1, v)) * 32767))
            }
        }
        samples += Array(repeating: 0, count: Int(rate * 1.6))
        var d = Data()
        func put<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2)
        d.append(contentsOf: Array("RIFF".utf8)); put(36 + bytes)
        d.append(contentsOf: Array("WAVEfmt ".utf8)); put(UInt32(16)); put(UInt16(1)); put(UInt16(1))
        put(UInt32(rate)); put(UInt32(rate * 2)); put(UInt16(2)); put(UInt16(16))
        d.append(contentsOf: Array("data".utf8)); put(bytes)
        for s in samples { put(s) }
        return d
    }

    // MARK: 盖在最上面的一层（在哪一页、开着哪个 sheet 都盖得上）

    private var waitingForScene: NSObjectProtocol?

    private func present() {
        guard window == nil else { return }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else {
            // 锁屏上接的：App 还没有画面，等你点开 App 再盖上通话页（电话已经在通了）
            guard waitingForScene == nil else { return }
            waitingForScene = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil,
                                                                     queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let o = self.waitingForScene { NotificationCenter.default.removeObserver(o) }
                    self.waitingForScene = nil
                    if self.answered != nil || self.ringing.map({ !$0.system }) == true { self.present() }
                }
            }
            return
        }
        let w = UIWindow(windowScene: scene)
        w.windowLevel = .alert + 1
        w.backgroundColor = .clear
        let vc = UIHostingController(rootView: IncomingCallScreen(center: self))
        vc.view.backgroundColor = .clear
        w.rootViewController = vc
        w.makeKeyAndVisible()
        window = w
    }

    private func dismiss() {
        window?.isHidden = true
        window = nil
    }

    func who(_ r: Ring) -> (name: String, avatar: UIImage?) {
        let c = model?.companions.first { $0.id.uuidString.lowercased() == r.companion.lowercased() }
        let name = c?.name ?? (LocalHost.shared.companion(ofConversation: r.conversation)?["name"] as? String ?? "")
        return (name, c.flatMap { model?.avatarImages[$0.id] })
    }
}

/// 那一层里放什么：在响 → 来电页；接了 → 通话页
private struct IncomingCallScreen: View {
    @ObservedObject var center: IncomingCalls

    var body: some View {
        if let r = center.answered, let s = center.session {
            let w = center.who(r)
            CallView(session: s, conversation: r.conversation, name: w.name, avatar: w.avatar) {
                center.callClosed()
            }
        } else if let r = center.ringing, !r.system {
            let w = center.who(r)
            IncomingCallView(name: w.name, avatar: w.avatar, reason: r.reason,
                             onAccept: { center.accept() }, onDecline: { center.decline() })
        }
    }
}

/// 来电页（照微信）：糊开的头像当背景，大头像 + 名字 +「邀请你语音通话…」，下面拒绝 / 接听
struct IncomingCallView: View {
    let name: String
    let avatar: UIImage?
    let reason: String
    let onAccept: () -> Void
    let onDecline: () -> Void
    @State private var pulse = false

    var body: some View {
        ZStack {
            Color(red: 0.11, green: 0.11, blue: 0.12)
            if let avatar {
                Image(uiImage: avatar).resizable().scaledToFill().blur(radius: 60).opacity(0.55)
            }
            Color.black.opacity(0.35)
            VStack(spacing: 0) {
                VStack(spacing: 14) {
                    face
                        .scaleEffect(pulse ? 1.04 : 1)
                        .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: pulse)
                        .padding(.vertical, 18)
                    Text(name).font(.system(size: 26, weight: .medium)).foregroundStyle(.white)
                    Text("邀请你语音通话…").font(Typo.sans(Typo.Size.body)).foregroundStyle(.white.opacity(0.6))
                    if !reason.isEmpty {
                        Text(reason)
                            .font(Typo.sans(Typo.Size.callout))
                            .foregroundStyle(.white.opacity(0.75))
                            .multilineTextAlignment(.center)
                            .lineLimit(3)
                            .padding(.horizontal, 16).padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white.opacity(0.1)))
                            .padding(.horizontal, 32).padding(.top, 6)
                    }
                }
                .padding(.top, 144)
                Spacer()
                HStack(alignment: .top) {
                    key(icon: "phone.down.fill", color: Color(red: 0.98, green: 0.26, blue: 0.25), label: "拒绝", action: onDecline)
                    Spacer()
                    key(icon: "phone.fill", color: Color(red: 0.2, green: 0.78, blue: 0.35), label: "接听", action: onAccept)
                }
                .padding(.horizontal, 56)
                .padding(.bottom, 64)
            }
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .onAppear { pulse = true }
    }

    private var face: some View {
        Group {
            if let avatar {
                Image(uiImage: avatar).resizable().scaledToFill()
            } else {
                ZStack {
                    Color.white.opacity(0.15)
                    Text(String(name.prefix(1))).font(.system(size: 45, weight: .medium)).foregroundStyle(.white)
                }
            }
        }
        .frame(width: 112, height: 112)
        .clipShape(RoundedRectangle(cornerRadius: 13.4, style: .continuous))
    }

    private func key(icon: String, color: Color, label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        VStack(spacing: 10) {
            Button(action: action) {
                Image(systemName: icon)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 72, height: 72)
                    .background(Circle().fill(color))
            }
            Text(label).font(Typo.sans(Typo.Size.callout)).foregroundStyle(.white.opacity(0.8))
        }
    }
}
#endif
