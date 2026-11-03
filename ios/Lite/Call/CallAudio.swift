#if LITE
import AVFoundation
import Speech

/// 电话的耳朵和嘴（10-31）：一台 AVAudioEngine，话筒和 TA 的声音都走它。
/// - 语音通话模式 + 开 voice processing = 系统的回声消除：它只认得同一台引擎放出来的声音，所以 TA 说话时话筒也能开着，你一开口能打断。
///   开不成（少数蓝牙耳机）就退回半双工：TA 说话时话筒的声音整个不听，不能插嘴，但不会自己回答自己。
/// - 判断开口 / 说完照之前自用的 App（咱们自己摸出来的）：按秒数不按块数（蓝牙耳机一块长一倍）、背景噪声跟着环境走、TA 说话时门槛抬高。
/// - 你一开口就起一段手机识别（灰字），说完把这一句的录音（16k 单声道）交出去，外面压成 AAC 送去准确转写。
/// - 嘴：一个 AVAudioPlayerNode，所有句子的声音按顺序排在它的一条时间线上，句子之间不断、不「啪」。
final class CallAudio: @unchecked Sendable {
    /// 一句话的灰字：识别回调一路往里写，说完以后外面再来拿（下一句已经开始了也不串）
    final class Heard: @unchecked Sendable {
        private let lock = NSLock()
        private var _text = "", _final = false
        let id = UUID()
        var text: String { lock.withLock { _text } }
        var isFinal: Bool { lock.withLock { _final } }
        func set(_ t: String, final: Bool) { lock.withLock { _text = t; if final { _final = true } } }

        /// 等手机的最终结果，最多等这么久；拿到什么算什么
        func settled(within seconds: Double) async -> String {
            let deadline = Date().addingTimeInterval(seconds)
            while !isFinal, Date() < deadline { try? await Task.sleep(for: .milliseconds(80)) }
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    static let voiceFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false)!

    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    private(set) var echoCancel = false
    private let lock = NSLock()

    // 外面设的（主线程写，音频线程读）
    private var _muted = false, _taActive = false, _endSeconds = 1.0
    var muted: Bool { get { lock.withLock { _muted } } set { lock.withLock { _muted = newValue } } }
    /// TA 在想或在说：开口门槛抬高、要说够久才算打断
    var taActive: Bool { get { lock.withLock { _taActive } } set { lock.withLock { _taActive = newValue } } }
    /// 静音多久算一句说完（快 / 中 / 慢）
    var endSeconds: Double { get { lock.withLock { _endSeconds } } set { lock.withLock { _endSeconds = newValue } } }

    // 事件（都从音频线程 / 识别回调来，外面自己切回主线程）
    var onSpeechStart: ((Heard) -> Void)?
    /// 说够久了：TA 正在想 / 说的话，这时候才真打断
    var onSpeechConfirmed: (() -> Void)?
    /// 一句说完：(16k Int16 PCM, 最后一次出声的时刻, 这一句的灰字)
    var onUtterance: ((Data, Date, Heard) -> Void)?
    /// 只是一下响动（太短），不算一句
    var onDiscard: (() -> Void)?
    var onPartial: ((Heard, String) -> Void)?
    /// 引擎重启不起来（耳机拔了之类）
    var onBroken: ((String) -> Void)?
    /// TA 的声音此刻多响（0～1，大约 20 次一秒）：通话页头像外面那圈呼吸的音波
    var onVoiceLevel: ((Float) -> Void)?
    private var levelTick = 0

    // 识别（灰字）
    var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var heard = Heard()

    // 判断开口 / 说完（只在音频线程碰）
    private let startRMS: Float = 0.006
    private let interruptRMS: Float = 0.012
    private let endRMS: Float = 0.003
    private let secondsToStart = 0.21
    private let secondsToStartWhileTA = 0.38
    private let confirmSeconds = 0.5          // TA 在的时候，说够这么久才打断（「嗯嗯」这种附和不算）
    private let minSpeech = 0.25              // 一句至少有这么久出声
    private var noiseFloor: Float = 0
    private var inSpeech = false
    private var confirmed = false
    private var startRun = 0.0, silenceRun = 0.0, voiced = 0.0
    private var lastVoiceAt = Date()
    private var utterance = Data()
    private var preroll: [(Data, AVAudioPCMBuffer)] = []
    private var step = 3.0, phase = 0.0
    private var tapCalls = 0
    #if DEBUG
    private var debugPeak: Float = 0, debugSecs = 0.0
    /// SIMCTL_CHILD_LITE_TEST_CALL_GAIN=4：模拟器自测时把音量放大再判断（真手机不设）
    static let debugGain = Float(ProcessInfo.processInfo.environment["LITE_TEST_CALL_GAIN"] ?? "") ?? 1
    #endif

    private var configObserver: NSObjectProtocol?

    // MARK: 开 / 关

    func start() throws {
        let s = AVAudioSession.sharedInstance()
        try s.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP])
        try s.setActive(true)
        try setUp()
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            self?.restart()           // 插拔耳机、连上蓝牙：格式变了，重新挂
        }
    }

    private func setUp() throws {
        let input = engine.inputNode
        // 回声消除要在读格式之前开（之前自用的 App踩过）
        do {
            try input.setVoiceProcessingEnabled(true)
            input.isVoiceProcessingAGCEnabled = false            // 自动增益会把底噪放大，门槛是按没开它定的
            input.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)
            echoCancel = true
        } catch {
            echoCancel = false
            NSLog("[call] 回声消除开不了，TA 说话时不听：\(error)")
        }
        let fmt = input.outputFormat(forBus: 0)
        guard fmt.sampleRate > 0, fmt.channelCount > 0 else { throw NSError(domain: "call", code: 1) }
        step = fmt.sampleRate / 16_000
        phase = 0
        if player.engine == nil { engine.attach(player) }
        engine.connect(player, to: engine.mainMixerNode, format: Self.voiceFormat)
        tapCalls = 0
        // 放出去的声音有多响：混音器出口上听（只有 TA 的声音走这台引擎）
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buf, _ in self?.measureVoice(buf) }
        input.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buf, _ in self?.consume(buf) }
        engine.prepare()
        try engine.start()
        player.play()
        // 看门狗：1.5 秒一次回调都没来 = 引擎哑跑，重来一次（之前自用的 App踩过）
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.engine.isRunning, self.tapCalls == 0 else { return }
            self.restart()
        }
    }

    func restart() {
        engine.inputNode.removeTap(onBus: 0)
        engine.mainMixerNode.removeTap(onBus: 0)
        engine.stop()
        resetEar()
        do { try setUp() } catch { onBroken?(String(localized: "话筒用不了了")) }
    }

    func stop() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.mainMixerNode.removeTap(onBus: 0)
        player.stop()
        engine.stop()
        endRecognition()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
    }

    func setSpeaker(_ on: Bool) {
        try? AVAudioSession.sharedInstance().overrideOutputAudioPort(on ? .speaker : .none)
    }

    // MARK: 嘴

    /// 排一块声音到时间线末尾；played 在它真放完时回调（音频线程）
    func schedule(_ buf: AVAudioPCMBuffer, played: @escaping @Sendable () -> Void) {
        player.scheduleBuffer(buf, completionCallbackType: .dataPlayedBack) { _ in played() }
        if !player.isPlaying { player.play() }
    }

    /// 停下 TA 正念的、扔掉排着的
    func hush() {
        player.stop()
        player.volume = 1
        player.play()
    }

    /// 你像要开口：先把 TA 压低（不当真）；说够了才 hush，没说够就放回来
    func duck(_ on: Bool) { player.volume = on ? 0.3 : 1 }

    private func measureVoice(_ buf: AVAudioPCMBuffer) {
        levelTick += 1
        guard levelTick % 2 == 0, let ch = buf.floatChannelData?[0], buf.frameLength > 0 else { return }
        let n = Int(buf.frameLength)
        var sum: Float = 0
        for i in 0..<n { sum += ch[i] * ch[i] }
        onVoiceLevel?(min(1, (sum / Float(n)).squareRoot() * 7))
    }

    // MARK: 耳朵

    private func resetEar() {
        lock.withLock {
            inSpeech = false; confirmed = false
            startRun = 0; silenceRun = 0; voiced = 0
            utterance = Data(); preroll = []
            noiseFloor = 0
        }
        endRecognition()
    }

    private func consume(_ buf: AVAudioPCMBuffer, fake: Bool = false) {
        tapCalls += 1
        #if DEBUG
        if debugFeeding && !fake { return }
        #endif
        guard let ch = buf.floatChannelData?[0] else { return }
        let n = Int(buf.frameLength)
        guard n > 0 else { return }
        let (muted, ta, endSec) = lock.withLock { (_muted, _taActive, _endSeconds) }
        var sum: Float = 0
        for i in 0..<n { sum += ch[i] * ch[i] }
        var rms = (sum / Float(n)).squareRoot()
        #if DEBUG
        rms *= Self.debugGain          // 自测：模拟器里 Mac 喇叭绕到麦克风太轻
        #endif
        if muted || (ta && !echoCancel) { rms = 0 }               // 静音 / 半双工时 TA 在说：当没声音
        let secs = Double(n) / buf.format.sampleRate
        #if DEBUG
        debugPeak = max(debugPeak, rms); debugSecs += secs
        if debugSecs >= 2 {
            NSLog("[call] ear peak=%.4f floor=%.4f rate=%.0f speech=%d ta=%d", debugPeak, noiseFloor, buf.format.sampleRate, inSpeech ? 1 : 0, ta ? 1 : 0)
            debugPeak = 0; debugSecs = 0
        }
        #endif
        let chunk = muted ? Data(count: Int(Double(n) / step) * 2) : downsample(ch, n)

        // 背景噪声：只拿不像说话的声音（低于开口门槛）来学；一直很吵（放着歌）才慢慢往上跟。
        // 不这么分的话，刚开口那半秒的话声会把底抬上去、门槛跟着涨，字和字之间一有空隙就永远开不了口（10-31 自测）
        let startGate = max(ta ? interruptRMS : startRMS, noiseFloor * 2.4)
        if !inSpeech && !ta {
            if noiseFloor == 0 { noiseFloor = min(rms, startRMS) }
            else if rms < startGate { noiseFloor = noiseFloor * 0.97 + rms * 0.03 }
            else { noiseFloor = noiseFloor * 0.998 + rms * 0.002 }
        } else if inSpeech && rms < noiseFloor {
            noiseFloor = noiseFloor * 0.9 + rms * 0.1
        }
        let endThreshold = max(endRMS, noiseFloor * 1.6)

        if inSpeech {
            utterance.append(chunk)
            if !muted { request?.append(buf) }
            if rms >= endThreshold {
                voiced += secs
                silenceRun = 0
                lastVoiceAt = Date()
                if !confirmed && voiced >= confirmSeconds {
                    confirmed = true
                    onSpeechConfirmed?()
                }
            } else {
                silenceRun += secs
            }
            // 说完：安静够了；或者一句太长（30 秒）先切一段
            if silenceRun >= endSec || utterance.count > 16_000 * 2 * 30 { endUtterance() }
        } else {
            preroll.append((chunk, Self.copy(buf)))
            var have = preroll.reduce(0.0) { $0 + Double($1.1.frameLength) / $1.1.format.sampleRate }
            while have > 0.45, preroll.count > 1 {
                have -= Double(preroll[0].1.frameLength) / preroll[0].1.format.sampleRate
                preroll.removeFirst()
            }
            if rms > startGate {
                startRun += secs
                if startRun >= (ta ? secondsToStartWhileTA : secondsToStart) { beginUtterance() }
            } else {
                startRun = max(0, startRun - secs)          // 字和字之间的空隙：往回扣，不清零
            }
        }
    }

    private func beginUtterance() {
        inSpeech = true
        confirmed = false
        silenceRun = 0
        voiced = startRun
        startRun = 0
        lastVoiceAt = Date()
        utterance = preroll.reduce(into: Data()) { $0.append($1.0) }
        let early = preroll.map(\.1)
        preroll = []
        startRecognition(with: early)
        NSLog("[call] 开口了（识别器 %@）", recognizer.map { $0.isAvailable ? "可用" : "不可用" } ?? "没有")
        onSpeechStart?(heard)
    }

    private func endUtterance() {
        inSpeech = false
        let pcm = utterance, at = lastVoiceAt, enough = voiced >= minSpeech, h = heard, voicedWas = voiced
        utterance = Data()
        silenceRun = 0; voiced = 0
        request?.endAudio()
        #if DEBUG
        NSLog("[call] 说完一句：出声 %.2f 秒、录音 %.1f 秒、灰字「%@」", voicedWas, Double(pcm.count) / 32_000, h.text)
        #endif
        if enough { onUtterance?(pcm, at, h) } else { cancelRecognition(); onDiscard?() }
    }

    /// 16k 单声道 Int16：线性插值降采样（48k 正好取一存三，蓝牙 16k / 8k 也照算）
    private func downsample(_ src: UnsafePointer<Float>, _ n: Int) -> Data {
        var out = Data(capacity: Int(Double(n) / step + 2) * 2)
        var pos = phase
        while pos < Double(n) {
            let i = Int(pos)
            let f = Float(pos - Double(i))
            let a = src[i], b = i + 1 < n ? src[i + 1] : a
            var v = Int16(max(-1, min(1, a + (b - a) * f)) * 32767)
            withUnsafeBytes(of: &v) { out.append(contentsOf: $0) }
            pos += step
        }
        phase = pos - Double(n)
        return out
    }

    private static func copy(_ b: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
        let c = AVAudioPCMBuffer(pcmFormat: b.format, frameCapacity: b.frameLength)!
        c.frameLength = b.frameLength
        if let s = b.floatChannelData, let d = c.floatChannelData {
            for ch in 0..<Int(b.format.channelCount) { memcpy(d[ch], s[ch], Int(b.frameLength) * MemoryLayout<Float>.size) }
        }
        return c
    }

    #if DEBUG
    private var debugFeeding = false
    /// 自测（10-31）：SIMCTL_CHILD_LITE_TEST_CALL_WAV=a.wav,b.wav —— 接通后每隔 LITE_TEST_CALL_GAP 秒（默认 15）
    /// 把一段录好的话当成话筒的声音按实时速度喂进来（模拟器里 Mac 喇叭绕到麦克风太不稳）；喂的时候真话筒不听
    func debugFeedFromEnv() {
        let env = ProcessInfo.processInfo.environment
        guard let list = env["LITE_TEST_CALL_WAV"], !list.isEmpty else { return }
        let gap = Double(env["LITE_TEST_CALL_GAP"] ?? "") ?? 15
        let urls = list.split(separator: ",").map { URL(fileURLWithPath: String($0)) }
        Thread.detachNewThread { [weak self] in
            Thread.sleep(forTimeInterval: 3)
            for url in urls {
                guard let self, let f = try? AVAudioFile(forReading: url) else { NSLog("[call] 自测文件读不了 \(url.path)"); continue }
                NSLog("[call] 自测：开始喂 \(url.lastPathComponent)")
                self.debugFeeding = true
                let fmt = f.processingFormat
                while let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 1024), (try? f.read(into: b)) != nil, b.frameLength > 0 {
                    self.consume(b, fake: true)
                    Thread.sleep(forTimeInterval: Double(b.frameLength) / fmt.sampleRate)
                }
                // 说完后接着喂安静，让「说完判定」走完
                let quiet = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 1024)!
                quiet.frameLength = 1024
                for _ in 0..<Int(2.5 * fmt.sampleRate / 1024) {
                    self.consume(quiet, fake: true)
                    Thread.sleep(forTimeInterval: 1024 / fmt.sampleRate)
                }
                self.debugFeeding = false
                Thread.sleep(forTimeInterval: gap)
            }
        }
    }
    #endif

    // MARK: 灰字（手机识别）

    /// requiresOnDeviceRecognition 不设 true：设了的话关了 Siri 和听写的人识别会一声不吭地失灵（Ariakitty 踩过）
    private func startRecognition(with early: [AVAudioPCMBuffer]) {
        endRecognition()
        let h = Heard()
        heard = h
        guard let recognizer, recognizer.isAvailable, SFSpeechRecognizer.authorizationStatus() == .authorized else { h.set("", final: true); return }
        let r = SFSpeechAudioBufferRecognitionRequest()
        r.shouldReportPartialResults = true
        r.requiresOnDeviceRecognition = false
        r.addsPunctuation = true
        r.taskHint = .dictation
        for b in early { r.append(b) }
        request = r
        task = recognizer.recognitionTask(with: r) { [weak self] result, error in
            if let result {
                let t = result.bestTranscription.formattedString
                h.set(t, final: result.isFinal)
                self?.onPartial?(h, t)
            } else if let error {
                NSLog("[call] 识别出错：\(error)")
                h.set(h.text, final: true)
            }
        }
    }

    private func cancelRecognition() {
        task?.cancel()
        task = nil
        request = nil
    }

    /// 上一句的识别交给它自己收尾（endAudio 以后最终结果还会来），这边放手
    private func endRecognition() {
        request?.endAudio()
        task = nil
        request = nil
    }

    // MARK: AAC

    /// 16k 单声道 Int16 → AAC（.m4a，32kbps，几十 KB），准确转写传这个；压不成返回 nil
    static func aac(_ pcm: Data) -> Data? {
        let frames = pcm.count / 2
        guard frames > 0, let fmt = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true),
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(frames)),
              let dst = buf.int16ChannelData?[0] else { return nil }
        buf.frameLength = AVAudioFrameCount(frames)
        pcm.withUnsafeBytes { if let src = $0.baseAddress { memcpy(dst, src, frames * 2) } }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("call-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            do {        // 文件出了这层才写完收尾
                let f = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16_000,
                                                                   AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32_000],
                                        commonFormat: .pcmFormatInt16, interleaved: true)
                try f.write(from: buf)
            }
            return try Data(contentsOf: url)
        } catch {
            NSLog("[call] AAC 压不成：\(error)")
            return nil
        }
    }
}
#endif
