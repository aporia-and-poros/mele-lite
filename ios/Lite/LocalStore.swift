#if LITE
import Foundation

/// 小管家的存储：照服务器的形状存在手机上（Documents/lite-host/）。
/// - 账号级：profile、keys（只存元数据，key 本身在钥匙串）、companions（persona / settings 是字典，跟服务器一样合并着改）
/// - 每个窗口一个消息文件；消息号全局自增（跟服务器一样是 Int）
/// - 其他房间（收藏、世界书……）一个房间一个 JSON 数组：`collection(_:)`
final class LocalStore: @unchecked Sendable {
    static let shared = LocalStore()

    let root: URL
    private let lock = NSRecursiveLock()
    private let fm = FileManager.default

    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("lite-host", isDirectory: true)
        try? fm.createDirectory(at: self.root.appendingPathComponent("conversations"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: self.root.appendingPathComponent("files"), withIntermediateDirectories: true)
    }

    // MARK: 通用：一个 JSON 文件 = 一个值

    func read(_ name: String) -> Any? {
        lock.withLock {
            guard let d = try? Data(contentsOf: root.appendingPathComponent(name)) else { return nil }
            return try? JSONSerialization.jsonObject(with: d, options: .fragmentsAllowed)
        }
    }

    func write(_ name: String, _ value: Any) {
        lock.withLock {
            let url = root.appendingPathComponent(name)
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            // 单独一个字符串 / 数字（比如「今天推过了」存的日期）也要能存；存不了的（不是 JSON 的东西）跳过——
            // data(withJSONObject:) 碰到不合法的会抛 ObjC 异常，try? 接不住，整个 App 闪退（10-05 夜推歌就这么崩的）
            let ok = JSONSerialization.isValidJSONObject(value) || value is String || value is NSNumber || value is NSNull
            if ok, let d = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]) {
                try? d.write(to: url, options: .atomic)
            }
        }
    }

    /// 一个房间的全部条目（[[String: Any]]）
    func collection(_ name: String) -> [[String: Any]] { read("rooms/\(name).json") as? [[String: Any]] ?? [] }
    func saveCollection(_ name: String, _ items: [[String: Any]]) { write("rooms/\(name).json", items) }

    /// 自增号（消息、表情包、收藏……各自一个计数）
    func nextID(_ counter: String) -> Int {
        lock.withLock {
            var meta = read("meta.json") as? [String: Any] ?? [:]
            let n = (meta[counter] as? Int ?? 0) + 1
            meta[counter] = n
            write("meta.json", meta)
            return n
        }
    }

    // MARK: 文件（头像、附件、表情包图……）

    func fileURL(_ name: String) -> URL { root.appendingPathComponent("files").appendingPathComponent(name) }

    func saveFile(_ data: Data, name: String) {
        try? data.write(to: fileURL(name), options: .atomic)
    }

    func removeFile(_ name: String) { try? fm.removeItem(at: fileURL(name)) }

    // MARK: 联系人

    var companions: [[String: Any]] {
        get { read("companions.json") as? [[String: Any]] ?? [] }
        set { write("companions.json", newValue) }
    }

    func companion(_ id: String) -> [String: Any]? { companions.first { ($0["id"] as? String) == id } }

    func saveCompanion(_ c: [String: Any]) {
        lock.withLock {
            var all = companions
            if let i = all.firstIndex(where: { ($0["id"] as? String) == (c["id"] as? String) }) { all[i] = c } else { all.append(c) }
            companions = all
        }
    }

    // MARK: 窗口

    var conversations: [[String: Any]] {
        get { read("conversations.json") as? [[String: Any]] ?? [] }
        set { write("conversations.json", newValue) }
    }

    func conversation(_ id: String) -> [String: Any]? { conversations.first { ($0["id"] as? String) == id } }

    func saveConversation(_ c: [String: Any]) {
        lock.withLock {
            var all = conversations
            if let i = all.firstIndex(where: { ($0["id"] as? String) == (c["id"] as? String) }) { all[i] = c } else { all.append(c) }
            conversations = all
        }
    }

    // MARK: 消息（一个窗口一个文件）

    func messages(_ conv: String) -> [[String: Any]] { read("conversations/\(conv).json") as? [[String: Any]] ?? [] }

    func saveMessages(_ conv: String, _ list: [[String: Any]]) { write("conversations/\(conv).json", list) }

    @discardableResult
    func addMessage(_ conv: String, role: String, text: String, thinking: String = "", thinkingMs: Int? = nil,
                    parts: [String]? = nil, cards: [[String: Any]] = [], attachments: [String] = [],
                    innerVoice: String = "", speaker: String? = nil, translations: [String?] = [], at: Date = Date(),
                    extra: [String: Any] = [:]) -> [String: Any] {
        lock.withLock {
            var m: [String: Any] = ["id": nextID("message"), "role": role, "text": text, "thinking": thinking,
                                    "at": LocalStore.iso(at), "cards": cards, "attachments": attachments]
            m.merge(extra) { a, _ in a }                                    // 电话（10-31）：call / call_end / divider
            if let parts { m["parts"] = parts }
            if let thinkingMs, !thinking.isEmpty { m["thinking_ms"] = thinkingMs }
            if !innerVoice.isEmpty { m["inner_voice"] = innerVoice }        // 回复后的心声（10-11）
            if translations.contains(where: { $0 != nil }) {                // 双语气泡（10-15）：跟气泡一一对应
                m["translations"] = translations.map { $0 as Any? ?? NSNull() }
            }
            if let speaker {                                                 // 群里是哪个 TA 说的（10-11）；名字一起留，TA 删了也认得
                m["speaker"] = speaker
                m["speaker_name"] = (companion(speaker)?["persona"] as? [String: Any])?["name"] as? String ?? "TA"
            }
            var list = messages(conv)
            list.append(m)
            saveMessages(conv, list)
            if var c = conversation(conv) {
                c["last_at"] = LocalStore.iso(at)
                if let speaker { c["last_speaker"] = speaker }
                saveConversation(c)
            }
            m["conversation"] = conv
            return m
        }
    }

    /// 找一条消息在哪个窗口
    func locate(message id: Int) -> (conv: String, index: Int)? {
        for c in conversations {
            guard let cid = c["id"] as? String else { continue }
            if let i = messages(cid).firstIndex(where: { ($0["id"] as? Int) == id }) { return (cid, i) }
        }
        return nil
    }

    // MARK: 时间

    static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: d)
    }

    /// 带不带小数秒都认（10-13 内测：朋友圈「N 条新互动」每次进去都在——App 发来的 since 没有小数秒，这里认不出就当成「从头算」）
    static func date(_ s: Any?) -> Date {
        guard let s = s as? String else { return .distantPast }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s) ?? .distantPast
    }
}
#endif
