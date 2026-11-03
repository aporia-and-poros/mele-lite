#if LITE
import AVFoundation
import Foundation

/// 通话流程里「谁来听、谁来想、谁来说」（10-31）：判断说完、灰字、时间线、插嘴都在手机上（CallSession / CallAudio），
/// 剩下这几样 Lite 本机和连着 Mele Host 各走各的——本机用手机里的小管家和你填在手机上的钥匙，Host 用服务器和它那边的钥匙。
@MainActor
protocol CallBackend: AnyObject {
    var zh: Bool { get }
    var voiceKind: CallVoice.Kind { get }
    /// 有没有准确转写（没有就只用手机识别的字）
    var canHear: Bool { get }
    /// 有没有 ElevenLabs 那种声音（没有就只出字幕，除非选了 iPhone 自带）
    var canSpeak: Bool { get }
    /// 计时那行里写的：Scribe / OpenAI / Host
    var hearLabel: String { get }
    /// 接通前准备（Host：问一声能不能听、能不能说、用哪种声音）
    func prepare() async
    func transcribe(_ aac: Data) async -> String?
    /// 一句的声音（24k Float32 块）；只在 canSpeak 时调
    func voice(_ line: String, prev: String?, callID: String) -> AsyncThrowingStream<AVAudioPCMBuffer, Error>
    /// 跑一轮：切好的句子从 link.onLine 出来；整轮跑完才返回
    func turn(_ text: String, link: CallLink) async
    /// TA 打来、你接通了：TA 先开口（递一句旁白，不存成你说的话）
    func answer(link: CallLink, reason: String) async
    /// 准确的字回来了，换掉存档里那句
    func fix(_ link: CallLink, text: String)
    /// 她开口打断 / 挂了：spoken = 念出来的那几句
    func cut(_ link: CallLink, spoken: [String])
    func end(callID: String, seconds: Int) async
    /// 存一句的声音给通话记录重听（Host 合成时自己存，这里不用管）
    func keep(_ buffers: [AVAudioPCMBuffer], line: String, callID: String)
}

/// Lite 本机：手机里的小管家（LocalBrain）+ 手机上的钥匙
@MainActor
final class LocalCallBackend: CallBackend {
    private let conv: String
    private let host = LocalHost.shared
    let zh: Bool
    let voiceKind: CallVoice.Kind
    private let voiceID: String

    init(conversation: String) {
        conv = conversation
        let settings = LocalHost.shared.companion(ofConversation: conversation)?["settings"] as? [String: Any] ?? [:]
        zh = (settings["lang"] as? String ?? "zh") == "zh"
        voiceKind = CallVoice.kind(settings)
        voiceID = LocalVoice.voiceID(settings)
    }

    var canHear: Bool { CallHearing.route(host) != nil }
    var canSpeak: Bool { LocalVoice.key(host) != nil }
    var hearLabel: String { CallHearing.route(host)?.label ?? "手机识别" }
    func prepare() async {}

    func transcribe(_ aac: Data) async -> String? {
        guard let route = CallHearing.route(host) else { return nil }
        return await CallHearing.transcribe(aac, via: route)
    }

    func voice(_ line: String, prev: String?, callID: String) -> AsyncThrowingStream<AVAudioPCMBuffer, Error> {
        guard let k = LocalVoice.key(host) else { return AsyncThrowingStream { $0.finish() } }
        return CallVoice.eleven(line, key: k, voiceID: voiceID, kind: voiceKind, prev: prev)
    }

    func turn(_ text: String, link: CallLink) async { await host.brain.callTurn(conv, text: text, link: link) }
    func answer(link: CallLink, reason: String) async { await host.brain.callAnswered(conv, reason: reason, link: link) }

    func fix(_ link: CallLink, text: String) {
        let conv = conv, brain = host.brain
        Task {
            for _ in 0..<50 where link.userMessageID == nil { try? await Task.sleep(for: .milliseconds(100)) }
            if let id = link.userMessageID { brain.callFix(conv, message: id, text: text) }
        }
    }

    func cut(_ link: CallLink, spoken: [String]) {
        link.cut(spoken: spoken)
        // 它已经写完存好了、只是还没念完：存档回头改成念到的那几句
        if let mid = link.assistantMessageID, spoken.count < link.lines.count {
            host.brain.callTrim(conv, message: mid, spoken: spoken)
        }
    }

    func end(callID: String, seconds: Int) async { await host.brain.callEnded(conv, seconds: seconds, callID: callID) }

    func keep(_ buffers: [AVAudioPCMBuffer], line: String, callID: String) {
        Task.detached(priority: .utility) { LocalCalls.saveAudio(buffers, call: callID, line: line) }
    }
}

/// 连着 Mele Host（第 3 步）：api/routes_call.py。转写、想、合成都在服务器，钥匙也在服务器
@MainActor
final class HostCallBackend: CallBackend {
    private let conv: String
    private let api: APIClient
    private(set) var zh = true
    private(set) var voiceKind: CallVoice.Kind = .fast
    private(set) var canHear = false
    private(set) var canSpeak = false
    let hearLabel = "Host"

    init(conversation: String, api: APIClient) {
        conv = conversation
        self.api = api
    }

    private var base: String { "conversations/\(conv)" }

    func prepare() async {
        guard let d = try? await api.raw("GET", "\(base)/call/info") as? [String: Any] else { return }
        zh = (d["lang"] as? String ?? "zh") == "zh"
        voiceKind = CallVoice.Kind(rawValue: d["call_voice"] as? String ?? "") ?? .fast
        canHear = d["hear"] as? Bool ?? false
        canSpeak = d["voice"] as? Bool ?? false
    }

    func transcribe(_ aac: Data) async -> String? {
        guard let d = try? await api.multipartFields("POST", "\(base)/call/hear", fields: [:], files: [("audio", "call.m4a", "audio/mp4", aac)]),
              let t = (try? JSONSerialization.jsonObject(with: d) as? [String: Any])?["text"] as? String,
              !t.isEmpty else { return nil }
        return t
    }

    func voice(_ line: String, prev: String?, callID: String) -> AsyncThrowingStream<AVAudioPCMBuffer, Error> {
        var body: [String: Any] = ["text": line, "call_id": callID, "kind": voiceKind.rawValue]
        if let prev { body["prev"] = prev }
        guard let req = try? api.request("POST", "\(base)/call/tts", json: body) else { return AsyncThrowingStream { $0.finish() } }
        return CallVoice.pcm(req)
    }

    func turn(_ text: String, link: CallLink) async { await stream(["text": text, "call_id": link.callID], link: link) }

    func answer(link: CallLink, reason: String) async {
        await stream(["text": "", "call_id": link.callID, "answered": true, "reason": reason], link: link)
    }

    /// call/turn 的 SSE：Host 切好一句推一句
    private func stream(_ body: [String: Any], link: CallLink) async {
        guard var req = try? api.request("POST", "\(base)/call/turn", json: body) else {
            link.fail(zh ? "连不上 Host" : "Can't reach your Host")
            return
        }
        req.timeoutInterval = 120
        do {
            let (bytes, resp) = try await URLSession.shared.bytes(for: req)
            guard ((resp as? HTTPURLResponse)?.statusCode ?? 500) < 400 else {
                link.fail(zh ? "Host 那边接不了电话（要先 mele-host update）" : "Your Host can't take calls yet (run mele-host update)")
                return
            }
            for try await line in bytes.lines where line.hasPrefix("data: ") {
                guard let ev = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(6).utf8)) as? [String: Any] else { continue }
                switch ev["type"] as? String {
                case "line": link.deliver(ev["text"] as? String ?? "")
                case "error": link.fail(ev["message"] as? String ?? "")
                default: break
                }
            }
        } catch {
            link.fail(zh ? "跟 Host 断开了" : "Lost the Host")
        }
    }

    func fix(_ link: CallLink, text: String) {
        let api = api, path = "\(base)/call/fix", id = link.callID
        Task { _ = try? await api.raw("POST", path, json: ["call_id": id, "text": text]) }
    }

    func cut(_ link: CallLink, spoken: [String]) {
        link.cut(spoken: spoken)
        let api = api, path = "\(base)/call/cut", id = link.callID
        Task { _ = try? await api.raw("POST", path, json: ["call_id": id, "spoken": spoken]) }
    }

    func end(callID: String, seconds: Int) async {
        _ = try? await api.raw("POST", "\(base)/call/end", json: ["call_id": callID, "seconds": seconds])
    }

    func keep(_ buffers: [AVAudioPCMBuffer], line: String, callID: String) {}
}
#endif
