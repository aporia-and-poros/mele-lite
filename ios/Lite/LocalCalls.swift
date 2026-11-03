#if LITE
import AVFoundation
import Foundation
import MeleLiteCore

/// 通话记录（10-31，第 5 步；照之前自用的 App「通话历史逐句页」的思路，那是咱们自己的）：
/// 按通话编号把一通电话的几条消息收拢；TA 每句的声音打电话时就存下来（call-ta-<指纹>.m4a），这里能逐句重听。
/// 左滑只是藏起来（calls-hidden.json），聊天里那行「📞 通话时长」和 TA 的记性都不动。
enum LocalCalls {
    struct Line: Identifiable {
        let id: Int
        let mine: Bool
        let text: String
        let audio: URL?
        var remote: String? = nil          // 连着 Host：声音在 Host 上（call/audio/…）
    }
    struct Call: Identifiable {
        let id: String
        let at: Date
        let seconds: Int
        /// 挂断那条的消息号；App 在通话中被关掉、没留下挂断那条的是 nil
        let endMessage: Int?
        let lines: [Line]
    }

    /// TA 那一句的声音文件名：通话编号 + 这句话（同一通里同一句共用一个）
    static func audioName(call: String, line: String) -> String {
        "call-ta-" + String(LocalVoice.sha(call + "\n" + line).prefix(24)) + ".m4a"
    }

    /// 打电话时存一句的声音（24k 单声道 → AAC，几 KB 一句）
    static func saveAudio(_ buffers: [AVAudioPCMBuffer], call: String, line: String) {
        let url = LocalHost.shared.store.fileURL(audioName(call: call, line: line))
        guard !buffers.isEmpty, !FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            let f = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 24_000,
                                                               AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 48_000],
                                    commonFormat: .pcmFormatFloat32, interleaved: false)
            for b in buffers { try f.write(from: b) }
        } catch {
            try? FileManager.default.removeItem(at: url)
        }
    }

    static func hidden() -> Set<String> {
        Set(LocalHost.shared.store.read("calls-hidden.json") as? [String] ?? [])
    }

    static func hide(_ id: String) {
        LocalHost.shared.store.write("calls-hidden.json", Array(hidden().union([id])).sorted())
    }

    /// 这个窗口打过的电话，新的在前（藏起来的不给）
    static func list(_ conv: String) -> [Call] {
        let hide = hidden()
        return calls(conv).filter { !hide.contains($0.id) }.reversed()
    }

    /// 聊天里那行「📞 通话时长」点开的那通
    static func call(_ conv: String, endMessage id: Int) -> Call? {
        calls(conv).first { $0.endMessage == id }
    }

    /// 按顺序收拢：带同一个编号的连着几条是一通；老的（没编号）按「连着的电话消息 + 挂断那条」算一通
    private static func calls(_ conv: String) -> [Call] {
        let store = LocalHost.shared.store
        var out: [Call] = []
        var cur: (id: String, first: Date, last: Date, rows: [[String: Any]])?
        func close(end: [String: Any]?) {
            guard let c = cur else { return }
            cur = nil
            var lines: [Line] = []
            for m in c.rows {
                let mine = (m["role"] as? String) == "user"
                let text = m["text"] as? String ?? ""
                if mine {
                    lines.append(Line(id: lines.count, mine: true, text: text, audio: nil))
                } else {
                    for part in text.split(separator: "\n").map(String.init) where !part.isEmpty {
                        let plain = part.hasSuffix("——") ? String(part.dropLast(2)) : part
                        let url = store.fileURL(audioName(call: c.id, line: plain))
                        lines.append(Line(id: lines.count, mine: false, text: part,
                                          audio: FileManager.default.fileExists(atPath: url.path) ? url : nil))
                    }
                }
            }
            let secs = (end?["seconds"] as? Int) ?? seconds(fromLine: end?["divider"] as? String)
                ?? Int(c.last.timeIntervalSince(c.first))
            out.append(Call(id: c.id, at: c.first, seconds: secs, endMessage: end?["id"] as? Int, lines: lines))
        }
        for m in store.messages(conv) {
            let id = m["call_id"] as? String
            if m["call_end"] as? Bool == true {
                if cur == nil { cur = (id ?? "end-\(m["id"] as? Int ?? 0)", LocalStore.date(m["at"]), LocalStore.date(m["at"]), []) }
                close(end: m)
            } else if m["call"] as? Bool == true {
                let key = id ?? "old-\(m["id"] as? Int ?? 0)"
                if let c = cur, id != nil, c.id != key { close(end: nil) }          // 上一通没留下挂断那条
                if cur == nil { cur = (key, LocalStore.date(m["at"]), LocalStore.date(m["at"]), []) }
                cur?.rows.append(m)
                cur?.last = LocalStore.date(m["at"])
            } else if cur != nil {
                close(end: nil)
            }
        }
        close(end: nil)
        return out
    }

    // MARK: 连着 Mele Host（第 3 步）：通话记录在 Host 上（api/routes_call.py /calls）

    static func list(api: APIClient, _ conv: String) async -> [Call] {
        guard let arr = try? await api.raw("GET", "conversations/\(conv)/calls") as? [[String: Any]] else { return [] }
        return arr.map { c in
            let lines = (c["lines"] as? [[String: Any]] ?? []).enumerated().map { i, l in
                Line(id: i, mine: l["mine"] as? Bool ?? false, text: l["text"] as? String ?? "", audio: nil, remote: l["audio"] as? String)
            }
            return Call(id: c["id"] as? String ?? UUID().uuidString, at: APIClient.parseDate(c["at"] as? String ?? "") ?? Date(),
                        seconds: c["seconds"] as? Int ?? 0, endMessage: c["end_message"] as? Int, lines: lines)
        }
    }

    static func hide(api: APIClient, _ conv: String, _ id: String) async {
        _ = try? await api.raw("POST", "conversations/\(conv)/calls/\(id)/hide")
    }

    private static func seconds(fromLine line: String?) -> Int? {
        guard let line, let r = line.range(of: #"(\d+:)?\d{2}:\d{2}"#, options: .regularExpression) else { return nil }
        let parts = line[r].split(separator: ":").compactMap { Int($0) }
        return parts.reduce(0) { $0 * 60 + $1 }
    }
}
#endif
