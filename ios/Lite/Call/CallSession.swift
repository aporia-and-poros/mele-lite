#if LITE
import AVFoundation
import Speech
import SwiftUI
import UIKit
import MeleLiteCore

/// 一通电话（10-31，Lite 本机，你打给 TA）。设计在 docs/superpowers/specs/2026-10-31-call-design.md。
///
/// 你说话 → CallAudio 判断说完（默认静音 1 秒）→ 这一句压成 AAC 送去准确转写（Scribe / OpenAI，限时 1.5 秒，
/// 超时先拿手机识别的字递给 TA，准确的回来再换字幕和存档）→ LocalBrain.callTurn 一边写一边切句子 →
/// 一句一合成（ElevenLabs 流式）→ 所有句子按顺序排在 CallAudio 的一条时间线上连着放。
/// 你在 TA 想或说的时候开口：先把 TA 压低，说够半秒才真打断——正念的停下、没念的扔掉，存档只留念出来的。
@MainActor
final class CallSession: ObservableObject {
    enum Phase { case connecting, live, ended }
    enum TA { case listening, thinking, speaking }
    struct Caption: Identifiable, Equatable {
        let id = UUID()
        let mine: Bool
        var text: String
        var gray: Bool
    }

    @Published private(set) var phase: Phase = .connecting
    @Published private(set) var ta: TA = .listening
    @Published private(set) var seconds = 0
    @Published var muted = false { didSet { audio.muted = muted } }
    @Published var speaker = false {
        didSet { audio.setSpeaker(speaker); UIDevice.current.isProximityMonitoringEnabled = !speaker && phase == .live }
    }
    @Published private(set) var captions: [Caption] = []
    @Published private(set) var notice: String?
    /// 这通没有声音可放（没填 ElevenLabs key、又没选 iPhone 自带）：通话页自己把字幕打开（11-03 内测：字幕默认关，TA 的话哪都看不到）
    @Published private(set) var textOnly = false
    /// 上一句各段花了多久（「···」里看，第 2 步的计时）
    @Published private(set) var lastTiming: String?
    /// TA 的声音多响（0～1，起得快落得慢，像呼吸）
    @Published private(set) var voiceLevel: Float = 0

    let conv: String
    private let callID: String
    /// TA 打来、你接起来的这通（第 4 步）：接通以后 TA 先开口
    private let incoming: IncomingCalls.Ring?
    private let host = LocalHost.shared
    private let audio = CallAudio()
    private let system = CallSystemVoice()
    /// 谁来听、谁来想、谁来说：Lite 本机 / 连着 Mele Host（第 3 步）
    private let backend: CallBackend
    private var zh: Bool { backend.zh }
    private var voiceKind: CallVoice.Kind {
        #if DEBUG
        // 自测（10-31）：SIMCTL_CHILD_LITE_TEST_CALL_VOICE=system 模拟器里没有 ElevenLabs key 也能听见
        if let k = ProcessInfo.processInfo.environment["LITE_TEST_CALL_VOICE"].flatMap(CallVoice.Kind.init(rawValue:)) { return k }
        #endif
        return backend.voiceKind
    }
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []

    // TA 这一轮
    private var link: CallLink?
    private var turnSeq = 0
    private var turnRunning = false
    private var timing: Timing?

    // 时间线：一代 = 一次没被打断的念；打断就换一代，旧代的回调全不认
    private final class Clip {
        let text: String
        let key: String
        let source: AsyncThrowingStream<AVAudioPCMBuffer, Error>
        var startFrame: Int64 = -1
        var shown = false
        init(text: String, key: String, source: AsyncThrowingStream<AVAudioPCMBuffer, Error>) {
            self.text = text; self.key = key; self.source = source
        }
    }
    private var clips: [Clip] = []
    private var inFlight = 0
    private var gen = 0
    private var scheduled: Int64 = 0, played: Int64 = 0
    private var feeder: AsyncStream<Clip>.Continuation?
    private var cache: [String: [AVAudioPCMBuffer]] = [:]      // 按句缓存：同一通电话里同一句不重复合成、不重复花钱
    private var prevLine: String?
    private var voiceFailNoted = false

    // 你这一句
    private var mineCaption: [UUID: UUID] = [:]                // 灰字（Heard.id）→ 字幕那一行
    private var startedWhileTA = false
    #if DEBUG
    private var debugSaidIndex = 0
    #endif
    private var bargedThisTime = false

    init(conversation: String, api: APIClient?, incoming: IncomingCalls.Ring? = nil) {
        conv = conversation
        self.incoming = incoming
        callID = incoming?.id ?? UUID().uuidString.lowercased()
        if Lite.hosted, let api { backend = HostCallBackend(conversation: conversation, api: api) }
        else { backend = LocalCallBackend(conversation: conversation) }
    }

    /// 说完判定：快 / 中 / 慢（秒）
    static let endpoints: [(key: String, seconds: Double)] = [("fast", 0.7), ("mid", 1.0), ("slow", 1.4)]
    func setEndpoint(_ key: String) { audio.endSeconds = Self.endpoints.first { $0.key == key }?.seconds ?? 1.0 }

    // MARK: 接通 / 挂断

    private var starting = false

    func start(endpoint: String) async {
        guard phase == .connecting, !starting else { return }      // 接来电时 IncomingCalls 先开、通话页再叫一次
        starting = true
        guard await AVAudioApplication.requestRecordPermission() else {
            notice = String(localized: "要允许 Mele 用麦克风才能打电话（设置 → Mele Lite → 麦克风）")
            return
        }
        let speechOK = await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
        await backend.prepare()
        if !speechOK && !backend.canHear {
            notice = String(localized: "听不见你说什么：打开语音识别（设置 → Mele Lite → 语音识别），或者在钥匙串里加 ElevenLabs / OpenAI 的 key")
            return
        }
        audio.recognizer = SFSpeechRecognizer(locale: Locale(identifier: zh ? "zh-CN" : "en-US"))
        wire()
        setEndpoint(endpoint)
        do { try audio.start() } catch {
            notice = String(localized: "话筒打不开，等一下再打")
            return
        }
        startFeeder()
        #if DEBUG
        audio.debugFeedFromEnv()
        #endif
        phase = .live
        IncomingCalls.shared.busy = true
        UIApplication.shared.isIdleTimerDisabled = true
        UIDevice.current.isProximityMonitoringEnabled = !speaker
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.seconds += 1 }
        }
        if voiceKind == .system { system.warmUp(zh: zh) }
        if voiceKind != .system && !backend.canSpeak {
            textOnly = true
            notice = Lite.hosted ? String(localized: "Host 上还没有 ElevenLabs key，TA 的话只出字幕。想听声音：TA 的设定 → 声音 → 电话里的声音，选「iPhone 自带」")
                                 : String(localized: "还没填 ElevenLabs key，TA 的话只出字幕。想听声音：TA 的设定 → 声音 → 电话里的声音，选「iPhone 自带」")
        }
        // 来电、闹钟打断了音频：这通就算挂了
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
            guard (n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init) == .began else { return }
            MainActor.assumeIsolated { self?.hangUp() }
        })
        if let r = incoming { answer(r) }
    }

    func hangUp() {
        guard phase != .ended else { return }
        let wasLive = phase == .live
        phase = .ended
        if let l = link { backend.cut(l, spoken: clips.filter(\.shown).map(\.text)) }     // 挂的时候还没念完：存档只留念到的
        gen += 1
        feeder?.finish()
        system.stop()
        audio.stop()
        timer?.invalidate()
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers = []
        UIApplication.shared.isIdleTimerDisabled = false
        UIDevice.current.isProximityMonitoringEnabled = false
        if incoming == nil { IncomingCalls.shared.busy = false }     // 接起来的那通由 IncomingCalls.callClosed 放
        guard wasLive else { return }
        voiceLevel = 0
        let secs = seconds, backend = backend, id = callID
        Task { await backend.end(callID: id, seconds: secs) }
    }

    // MARK: 耳朵

    /// 音频线程 / 识别回调 → 主线程，按发生的顺序（Task 不保证先后）
    nonisolated private func onMain(_ f: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async { MainActor.assumeIsolated { f() } }
    }

    private func wire() {
        audio.onSpeechStart = { [weak self] h in self?.onMain { self?.speechStarted(h) } }
        audio.onPartial = { [weak self] h, t in self?.onMain { self?.partial(h, t) } }
        audio.onSpeechConfirmed = { [weak self] in self?.onMain { self?.confirmed() } }
        audio.onDiscard = { [weak self] in self?.onMain { self?.discarded() } }
        audio.onUtterance = { [weak self] pcm, at, h in self?.onMain { self?.utterance(pcm, at: at, heard: h) } }
        audio.onBroken = { [weak self] m in self?.onMain { self?.notice = m } }
        audio.onVoiceLevel = { [weak self] v in
            self?.onMain {
                guard let self, self.phase == .live else { return }
                var next = v > self.voiceLevel ? v : max(v, self.voiceLevel * 0.82)
                if next < 0.03 { next = 0 }                 // 落到很小就归零（不然卡在一圈淡线上退不下去）
                if abs(next - self.voiceLevel) > 0.005 || (next == 0 && self.voiceLevel != 0) { self.voiceLevel = next }
            }
        }
    }

    private func speechStarted(_ h: CallAudio.Heard) {
        startedWhileTA = ta != .listening
        bargedThisTime = false
        if startedWhileTA { audio.duck(true) }
        let c = Caption(mine: true, text: "", gray: true)
        captions.append(c)
        mineCaption[h.id] = c.id
    }

    private func partial(_ h: CallAudio.Heard, _ text: String) {
        guard let cid = mineCaption[h.id], let i = captions.firstIndex(where: { $0.id == cid }), captions[i].gray else { return }
        captions[i].text = text
    }

    private func confirmed() {
        audio.duck(false)
        guard startedWhileTA, ta != .listening else { return }
        bargedThisTime = true
        bargeIn()
    }

    private func discarded() {
        audio.duck(false)
        dropEmptyGray()
    }

    private func dropEmptyGray(_ id: UUID? = nil) {
        captions.removeAll { $0.mine && $0.gray && (id == nil ? $0.text.isEmpty : $0.id == id) }
    }

    private func utterance(_ pcm: Data, at stopped: Date, heard h: CallAudio.Heard) {
        audio.duck(false)
        let cid = mineCaption.removeValue(forKey: h.id)
        // TA 在说的时候「嗯」「对」一下、没说够半秒：是附和，不打断、不算一句
        if startedWhileTA && !bargedThisTime && ta != .listening {
            if let cid { dropEmptyGray(cid) }
            return
        }
        var t = Timing(stopMouth: stopped, endpoint: Date())
        let backend = backend
        Task {
            var text = "", late: Task<String?, Never>?
            if backend.canHear, let aac = await Task.detached(operation: { CallAudio.aac(pcm) }).value {
                t.via = backend.hearLabel
                let job = Task { await backend.transcribe(aac) }
                if let quick = await Self.race(job, seconds: 1.5) {
                    text = quick
                } else {
                    text = await h.settled(within: 0.2)
                    if text.isEmpty { text = await job.value ?? "" } else { late = job; t.via += "（超时，先用手机识别的）" }
                }
            } else {
                t.via = "手机识别"
                text = await h.settled(within: 0.8)
            }
            #if DEBUG
            // 自测（10-31）：模拟器认不出中文时，SIMCTL_CHILD_LITE_TEST_CALL_SAID="第一句|第二句" 按顺序顶上
            if text.isEmpty, let said = ProcessInfo.processInfo.environment["LITE_TEST_CALL_SAID"] {
                let all = said.split(separator: "|").map(String.init)
                if debugSaidIndex < all.count { text = all[debugSaidIndex]; t.via += "（自测顶上的字）" }
                debugSaidIndex += 1
            }
            #endif
            #if DEBUG
            NSLog("[call] 认出来的（\(t.via)）：\(text)")
            #endif
            guard phase == .live else { return }
            guard !text.isEmpty else { if let cid { dropEmptyGray(cid) }; return }
            t.recognized = Date()
            setMine(cid, text)
            say(text, timing: t)
            if let late {
                let l = link
                Task {
                    guard let better = await late.value, better != text else { return }
                    setMine(cid, better)
                    if let l { backend.fix(l, text: better) }
                }
            }
        }
    }

    private func setMine(_ cid: UUID?, _ text: String) {
        if let cid, let i = captions.firstIndex(where: { $0.id == cid }) {
            captions[i].text = text
            captions[i].gray = false
        } else {
            captions.append(Caption(mine: true, text: text, gray: false))
        }
    }

    /// 准确转写跟 1.5 秒比谁先到；转写先到（哪怕是失败的 nil）就用它的结果
    nonisolated private static func race(_ job: Task<String?, Never>, seconds: Double) async -> String? {
        let once = Once()
        return await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
            Task { let v = await job.value; once.resume(c, v) }
            Task { try? await Task.sleep(for: .seconds(seconds)); once.resume(c, nil) }
        }
    }

    // MARK: TA 想

    private func say(_ text: String, timing t: Timing) {
        let backend = backend
        runTA(timing: t) { link in await backend.turn(text, link: link) }
    }

    /// 接通了，这通是 TA 打的：不等你说话，TA 先开口（递一句旁白，不存成你说的）
    private func answer(_ r: IncomingCalls.Ring) {
        let backend = backend
        var t = Timing(stopMouth: Date(), endpoint: Date(), via: "TA 打来的，接通先开口")
        t.recognized = t.endpoint
        runTA(timing: t) { link in
            await backend.answer(link: link, reason: r.reason)
        }
    }

    private func runTA(timing t: Timing, _ go: @escaping (CallLink) async -> Void) {
        if ta != .listening { bargeIn() }
        turnSeq += 1
        let seq = turnSeq
        let l = CallLink(callID: callID, onLine: { [weak self] line in self?.onMain { self?.gotLine(line, seq: seq) } },
                         onFail: { [weak self] m in self?.onMain { self?.notice = m } })
        link = l
        turnRunning = true
        timing = t
        prevLine = nil
        updateTA()
        Task {
            await go(l)
            onMain { [weak self] in
                guard let self, seq == self.turnSeq else { return }
                self.turnRunning = false
                self.updateTA()
                self.finishTiming()
            }
        }
    }

    private func gotLine(_ line: String, seq: Int) {
        #if DEBUG
        NSLog("[call] TA 写出一句：\(line)")
        #endif
        guard seq == turnSeq, phase == .live, link?.isCut == false else { return }
        if timing?.firstLine == nil { timing?.firstLine = Date() }
        let key = "\(voiceKind.rawValue)|\(line)"
        let clip = Clip(text: line, key: key, source: source(for: line, key: key))
        prevLine = line
        clips.append(clip)
        inFlight += 1
        feeder?.yield(clip)
        updateTA()
    }

    /// 一句的声音从哪来：缓存 → 自带声音 / ElevenLabs；都没有就是空的（只出字幕）
    private func source(for line: String, key: String) -> AsyncThrowingStream<AVAudioPCMBuffer, Error> {
        if let hit = cache[key] {
            return AsyncThrowingStream { c in for b in hit { c.yield(b) }; c.finish() }
        }
        if voiceKind == .system { return system.speak(line, zh: zh) }
        guard backend.canSpeak else { return AsyncThrowingStream { $0.finish() } }
        return backend.voice(line, prev: prevLine, callID: callID)
    }

    // MARK: TA 说（一条时间线）

    private func startFeeder() {
        let (stream, cont) = AsyncStream<Clip>.makeStream()
        feeder = cont
        let g = gen
        Task { [weak self] in
            for await clip in stream {
                guard let self, self.gen == g else { return }
                await self.play(clip, gen: g)
            }
        }
    }

    private func play(_ clip: Clip, gen g: Int) async {
        var got: [AVAudioPCMBuffer] = []
        defer { if gen == g { inFlight -= 1; updateTA() } }
        do {
            for try await buf in clip.source {
                guard gen == g else { return }
                if got.isEmpty, timing?.firstAudio == nil { timing?.firstAudio = Date() }
                got.append(buf)
                let start = scheduled
                let frames = Int64(buf.frameLength)
                scheduled += frames
                audio.schedule(buf) { [weak self] in self?.onMain { self?.didPlay(frames, gen: g) } }
                if clip.startFrame < 0 {
                    clip.startFrame = start
                    if start <= played { reveal(clip) }        // 前面都放完了：这句现在就出声
                }
                updateTA()
            }
            if !got.isEmpty {
                cache[clip.key] = got
                // 通话记录里能重听（第 5 步）：整句收齐了才存
                backend.keep(got, line: clip.text, callID: callID)
            }
        } catch {
            guard gen == g else { return }
            if !voiceFailNoted {
                voiceFailNoted = true
                notice = CallVoice.failText(error, zh: zh)
            }
        }
        if clip.startFrame < 0 {                     // 没出声的这句：轮到它时只出字幕
            clip.startFrame = scheduled
            if scheduled <= played { reveal(clip) }
        }
    }

    private func didPlay(_ frames: Int64, gen g: Int) {
        guard g == gen else { return }
        played += frames
        for c in clips where !c.shown && c.startFrame >= 0 && c.startFrame <= played { reveal(c) }
        updateTA()
    }

    private func reveal(_ c: Clip) {
        guard !c.shown else { return }
        c.shown = true
        captions.append(Caption(mine: false, text: c.text, gray: false))
        if timing?.firstSound == nil {
            timing?.firstSound = Date()
            finishTiming()
        }
    }

    private func updateTA() {
        let speaking = scheduled > played
        let waiting = (turnRunning && link?.isCut == false) || inFlight > 0
        let now: TA = speaking ? .speaking : waiting ? .thinking : .listening
        if ta != now { ta = now }
        audio.taActive = now != .listening
    }

    /// 你开口打断：正念的停下、没念的扔掉；告诉大脑念到了哪几句（存档只存这些）
    private func bargeIn() {
        let spoken = clips.filter(\.shown).map(\.text)
        #if DEBUG
        NSLog("[call] 她开口了，TA 停下（念到：\(spoken)）")
        #endif
        if let l = link { backend.cut(l, spoken: spoken) }
        gen += 1
        feeder?.finish()
        clips = []
        inFlight = 0
        scheduled = 0
        played = 0
        system.stop()
        audio.hush()
        startFeeder()
        updateTA()
    }

    // MARK: 计时（第 2 步）：停嘴 → 判定说完 → 认完字 → 第一句写出来 → 第一块声音到 → 第一声响

    struct Timing {
        var stopMouth: Date
        var endpoint: Date
        var via = ""
        var recognized: Date?
        var firstLine: Date?
        var firstAudio: Date?
        var firstSound: Date?
        var logged = false
    }

    private func finishTiming() {
        guard var t = timing, !t.logged, t.firstSound != nil || !turnRunning else { return }
        t.logged = true
        timing = t
        func ms(_ d: Date?) -> Int? { d.map { Int(($0.timeIntervalSince(t.stopMouth) * 1000).rounded()) } }
        var row: [String: Any] = ["at": LocalStore.iso(Date()), "via": t.via, "endpoint_ms": ms(t.endpoint) ?? 0,
                                  "voice": voiceKind.rawValue, "echo_cancel": audio.echoCancel]
        for (k, d) in [("recognized_ms", t.recognized), ("first_line_ms", t.firstLine), ("first_audio_ms", t.firstAudio), ("first_sound_ms", t.firstSound)] {
            row[k] = ms(d) ?? NSNull()
        }
        if let d = try? JSONSerialization.data(withJSONObject: row), let line = String(data: d, encoding: .utf8) {
            let url = host.store.fileURL("call-timing.jsonl")
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile(); h.write(Data((line + "\n").utf8)); try? h.close()
            } else {
                try? Data((line + "\n").utf8).write(to: url)
            }
            NSLog("[call] timing \(line)")
        }
        func sec(_ a: Date?, _ b: Date?) -> String {
            guard let a, let b else { return "–" }
            return String(format: "%.1f", b.timeIntervalSince(a))
        }
        let total = t.firstSound.map { String(format: "%.1f", $0.timeIntervalSince(t.stopMouth)) } ?? "–"
        lastTiming = zh
            ? "停嘴→出声 \(total) 秒：判定 \(sec(t.stopMouth, t.endpoint)) · 认字 \(sec(t.endpoint, t.recognized)) · 想 \(sec(t.recognized, t.firstLine)) · 合成 \(sec(t.firstLine, t.firstAudio))"
            : "Stop → sound \(total)s: endpoint \(sec(t.stopMouth, t.endpoint)) · transcribe \(sec(t.endpoint, t.recognized)) · think \(sec(t.recognized, t.firstLine)) · voice \(sec(t.firstLine, t.firstAudio))"
    }
}

extension CallHearing.Route {
    var label: String {
        switch self {
        case .scribe: "Scribe"
        case .openai: "OpenAI"
        }
    }
}

/// 只 resume 一次
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func resume(_ c: CheckedContinuation<String?, Never>, _ v: String?) {
        let go = lock.withLock { () -> Bool in defer { done = true }; return !done }
        if go { c.resume(returning: v) }
    }
}
#endif
