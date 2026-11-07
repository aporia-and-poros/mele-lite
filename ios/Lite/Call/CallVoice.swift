#if LITE
import AVFoundation
import Foundation

/// 电话里 TA 的声音（10-31）：用户自己的 ElevenLabs key，一句一合成，用流式接口——第一块声音到了就能排上时间线，不等整句。
/// 接口照 ElevenLabs 官方文档：POST /v1/text-to-speech/{voice_id}/stream，output_format=pcm_24000（16 位单声道，直接变成播放的格式）。
/// - 「快」= 低延迟那档（flash）；「有表情」= 语音条现在用的模型（流式不收这个模型时退回整句合成）
/// - 「iPhone 自带声音」是用户在设置里明着选的；合成失败时不偷偷换成它（声音突然变成另一个人比安静一秒更难受）
enum CallVoice {
    static let fastModel = "eleven_flash_v2_5"

    enum Kind: String { case fast, expressive, system }

    /// TA 设定里「电话的声音」：没选过 = 快
    static func kind(_ settings: [String: Any]) -> Kind { Kind(rawValue: settings["call_voice"] as? String ?? "") ?? .fast }

    /// 一句 → 一串声音块（24k Float32 单声道）。ElevenLabs 那边的错照语音条那套归类（auth / quota / network …）
    static func eleven(_ text: String, key: String, voiceID: String, kind: Kind, expressiveModel: String, prev: String?) -> AsyncThrowingStream<AVAudioPCMBuffer, Error> {
        AsyncThrowingStream { cont in
            let job = Task {
                let model = kind == .expressive ? expressiveModel : fastModel
                // 有表情那档：跟语音条同一个模型、同一套稿子（认标签的垫一个，不认的去掉）
                let said = kind == .expressive ? LocalVoice.script(text, model: model) : text
                var body: [String: Any] = ["text": said, "model_id": model, "voice_settings": ["stability": 0.5]]
                if let prev, !prev.isEmpty, LocalVoice.takesContext(model) { body["previous_text"] = prev }
                do {
                    do {
                        try await streamPCM("/v1/text-to-speech/\(voiceID)/stream", key: key, body: body, cont: cont)
                    } catch let f as LocalVoice.Fail where f.kind == "bad_request" && kind == .expressive {
                        // 这个模型不收流式：整句合成完再切块排上去（慢一点，但还是那个声音）
                        try await streamPCM("/v1/text-to-speech/\(voiceID)", key: key, body: body, cont: cont)
                    }
                    cont.finish()
                } catch {
                    cont.finish(throwing: error)
                }
            }
            cont.onTermination = { _ in job.cancel() }
        }
    }

    private static func streamPCM(_ path: String, key: String, body: [String: Any],
                                  cont: AsyncThrowingStream<AVAudioPCMBuffer, Error>.Continuation) async throws {
        var c = URLComponents(string: "https://api.elevenlabs.io" + path)!
        c.queryItems = [URLQueryItem(name: "output_format", value: "pcm_24000")]
        var req = URLRequest(url: c.url!, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "xi-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        try await pump(req, cont: cont)
    }

    /// 连着 Host（10-31）：Host 转来的 24k PCM 流，照样切块
    static func pcm(_ req: URLRequest) -> AsyncThrowingStream<AVAudioPCMBuffer, Error> {
        AsyncThrowingStream { cont in
            let job = Task {
                do { try await pump(req, cont: cont); cont.finish() } catch { cont.finish(throwing: error) }
            }
            cont.onTermination = { _ in job.cancel() }
        }
    }

    /// 读一个 24k 16 位 PCM 的回应，按块交出去（第一块 0.1 秒好早点出声，后面 0.2 秒一块）
    private static func pump(_ req: URLRequest, cont: AsyncThrowingStream<AVAudioPCMBuffer, Error>.Continuation) async throws {
        let bytes: URLSession.AsyncBytes, resp: URLResponse
        do { (bytes, resp) = try await URLSession.shared.bytes(for: req) } catch { throw LocalVoice.Fail(kind: "network") }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status >= 400 {
            var err = Data()
            for try await b in bytes { err.append(b); if err.count > 4000 { break } }
            NSLog("[call] ElevenLabs \(status): \(String(decoding: err, as: UTF8.self).prefix(300))")
            throw LocalVoice.Fail(kind: LocalVoice.failKind(status: status, body: err))
        }
        var pending = Data(), want = 4_800
        do {
            for try await b in bytes {
                pending.append(b)
                if pending.count >= want {
                    let cut = pending.count - pending.count % 2
                    cont.yield(pcm16(pending.prefix(cut)))
                    pending = Data(pending.dropFirst(cut))
                    want = 9_600
                }
            }
        } catch is CancellationError { return } catch { throw LocalVoice.Fail(kind: "network") }
        if pending.count >= 2 { cont.yield(pcm16(pending.prefix(pending.count - pending.count % 2))) }
    }

    /// 16 位小端 PCM → 播放用的 Float32 块
    static func pcm16(_ d: Data) -> AVAudioPCMBuffer {
        let n = d.count / 2
        let buf = AVAudioPCMBuffer(pcmFormat: CallAudio.voiceFormat, frameCapacity: AVAudioFrameCount(max(n, 1)))!
        buf.frameLength = AVAudioFrameCount(n)
        let dst = buf.floatChannelData![0]
        d.withUnsafeBytes { raw in
            let src = raw.bindMemory(to: Int16.self)
            for i in 0..<n { dst[i] = Float(Int16(littleEndian: src[i])) / 32768 }
        }
        return buf
    }

    /// 合成失败时那一句的说法（只说一次，显示在通话页）
    static func failText(_ e: Error, zh: Bool) -> String {
        let kind = (e as? LocalVoice.Fail)?.kind ?? "network"
        let why = LocalVoice.errors[kind] ?? LocalVoice.errors["network"]!
        return zh ? "TA 的声音没出来（\(why)），这几句先只出字幕" : "Their voice didn't come through (\(why)) — captions only for now"
    }
}

/// iPhone 自带的声音（用户自己选的免费那档）：AVSpeechSynthesizer.write 拿到声音块，自己重采样成 24k，排进同一条时间线。
/// （系统的格式转换器碰到一小块一小块的声音常常一帧都不吐，10-31 模拟器里整句没声，所以自己插值）
final class CallSystemVoice: @unchecked Sendable {
    private let synth = AVSpeechSynthesizer()

    /// 被打断 / 挂了：排着没念的也不要了
    func stop() { synth.stopSpeaking(at: .immediate) }

    /// 接通时先空念一句（10-31 模拟器：第一次 write 整句一块声音都不给）
    func warmUp(zh: Bool) {
        let u = AVSpeechUtterance(string: zh ? "嗯" : "Hm")
        u.voice = AVSpeechSynthesisVoice(language: zh ? "zh-CN" : "en-US")
        synth.write(u) { _ in }
    }

    func speak(_ text: String, zh: Bool) -> AsyncThrowingStream<AVAudioPCMBuffer, Error> {
        AsyncThrowingStream { cont in
            let u = AVSpeechUtterance(string: text)
            u.voice = AVSpeechSynthesisVoice(language: zh ? "zh-CN" : "en-US")
            let rs = Resampler()
            synth.write(u) { b in
                guard let pcm = b as? AVAudioPCMBuffer else { return }
                if pcm.frameLength == 0 { cont.finish(); return }          // 最后一块是空的 = 念完了
                if let out = rs.convert(pcm) { cont.yield(out) }
            }
        }
    }

    /// 一句一个：跨块接着走的读头
    private final class Resampler: @unchecked Sendable {
        var phase = 0.0
        func convert(_ b: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
            let n = Int(b.frameLength)
            var src = [Float](repeating: 0, count: n)
            if let f = b.floatChannelData?[0] { for i in 0..<n { src[i] = f[i] } }
            else if let s = b.int16ChannelData?[0] {
                let stride = b.format.isInterleaved ? Int(b.format.channelCount) : 1
                for i in 0..<n { src[i] = Float(s[i * stride]) / 32768 }
            } else { return nil }
            let step = b.format.sampleRate / CallAudio.voiceFormat.sampleRate
            var out: [Float] = []
            out.reserveCapacity(Int(Double(n) / step) + 2)
            var pos = phase
            while pos < Double(n) {
                let i = Int(pos), f = Float(pos - Double(i))
                let a = src[i], c = i + 1 < n ? src[i + 1] : a
                out.append(a + (c - a) * f)
                pos += step
            }
            phase = pos - Double(n)
            guard !out.isEmpty, let buf = AVAudioPCMBuffer(pcmFormat: CallAudio.voiceFormat, frameCapacity: AVAudioFrameCount(out.count)) else { return nil }
            buf.frameLength = AVAudioFrameCount(out.count)
            out.withUnsafeBufferPointer { memcpy(buf.floatChannelData![0], $0.baseAddress!, out.count * MemoryLayout<Float>.size) }
            return buf
        }
    }
}

/// 说完那一句的准确转写（10-31）：有 ElevenLabs key 用 Scribe（同一把，不用多填），否则 OpenAI 的转写，都没有就用手机识别的。
enum CallHearing {
    enum Route { case scribe(String), openai(String) }

    static func route(_ host: LocalHost) -> Route? {
        if let k = LocalVoice.key(host) { return .scribe(k) }
        for k in host.keys where (k["provider"] as? String) == "openai" {
            let base = (k["base_url"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            guard base.isEmpty || base.contains("api.openai.com"), let id = k["id"] as? String, let secret = host.vault.get(id) else { continue }
            return .openai(secret)
        }
        return nil
    }

    /// 转不出来 / 出错 = nil
    static func transcribe(_ aac: Data, via route: Route) async -> String? {
        do {
            let text: String
            switch route {
            case .scribe(let key):
                let d = try await ElevenLabs(key: key).request("POST", "/v1/speech-to-text",
                                                               multipart: (["model_id": "scribe_v2", "tag_audio_events": "false"], aac))
                text = (try? JSONSerialization.jsonObject(with: d) as? [String: Any])?["text"] as? String ?? ""
            case .openai(let key):
                text = try await openAI(aac, key: key)
            }
            // （笑声）[music] 这类不是她说的话
            let t = text.replacingOccurrences(of: #"\s*[(\[（][^)\]）]{1,30}[)\]）]\s*"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        } catch {
            NSLog("[call] 转写失败：\(error)")
            return nil
        }
    }

    private static func openAI(_ aac: Data, key: String) async throws -> String {
        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let boundary = "mele-\(UUID().uuidString)"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        for (k, v) in ["model": "gpt-4o-mini-transcribe", "response_format": "json"] {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(v)\r\n".utf8))
        }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"call.m4a\"\r\nContent-Type: audio/mp4\r\n\r\n".utf8))
        body.append(aac)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        req.httpBody = body
        let (d, resp) = try await URLSession.shared.data(for: req)
        guard ((resp as? HTTPURLResponse)?.statusCode ?? 500) < 400 else { throw LocalVoice.Fail(kind: "server") }
        return (try? JSONSerialization.jsonObject(with: d) as? [String: Any])?["text"] as? String ?? ""
    }
}
#endif
