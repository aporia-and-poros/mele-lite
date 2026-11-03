import Foundation

/// 一个 TA 一段脑子（10-11 Aporia：私聊和群聊合在一起，「不然不太像一个人」）：
/// TA 在哪个房间说话，都把它待过的别的房间最近 N 条按真实时间插进来，前面标房间和说话人。
/// 只按条数截、不限时间（「太久之前才显得真」）。Host 的 brain/timeline.py 同一份意思。
public enum RoomTimeline {
    public struct Item: Sendable, Equatable {
        public let id: String
        /// 排好的房间名：群「三人行」/ 私聊
        public let room: String
        /// 说话人名字；nil = 就是这个 TA 自己说的
        public let who: String?
        public let text: String
        public let at: Date
        public init(id: String, room: String, who: String?, text: String, at: Date) {
            self.id = id; self.room = room; self.who = who; self.text = text; self.at = at
        }
    }

    public static func groupRoom(_ name: String, zh: Bool) -> String { zh ? "群「\(name)」" : "group \"\(name)\"" }
    public static func privateRoom(zh: Bool) -> String { zh ? "私聊" : "DM" }

    /// 合了别的房间时放进系统提示（10-31 内测：群里的话被它接到私聊里回）：告诉它现在在哪、标了房间的是别处的话
    public static func note(here: String, zh: Bool) -> String {
        zh ? "〔房间〕你现在在\(here)。历史里开头标着〔群「…」〕〔私聊〕的，是你在别的房间听到、说过的话，放进来只是让你知道那边聊过什么。这里只回这个房间里的话：别接那边的话头，回话开头也不写房间标签。"
           : "[Room] You're in the \(here) right now. Lines in the history that start with a room tag like 〔group \"…\"〕 or 〔DM〕 are things you heard or said in other rooms — they're there so you know what was said over there. Here, only answer what's said in this room: don't pick up threads from over there, and don't start your reply with a room tag."
    }

    /// 回话开头学着历史垫的房间标签（〔群「三人行」〕、〔私聊〕…）去掉
    public static func stripTag(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let r = t.range(of: #"^〔(群「[^」]*」|私聊|group "[^"]*"|DM)( · [^〕]*)?〕\s*"#, options: .regularExpression) else { return t }
        return String(t[r.upperBound...])
    }

    /// 别的房间最近 limit 条按时间插进当前历史：TA 自己说的 = assistant「〔房间〕…」，别人说的 = user「〔房间 · 名字〕…」。
    /// 同一时刻当前房间的在前；limit ≤ 0 原样返回
    public static func merge(_ current: [Message], others: [Item], limit: Int) -> [Message] {
        guard limit > 0, !others.isEmpty else { return current }
        let picked = others.sorted { $0.at < $1.at }.suffix(limit)
        let extra = picked.map { o in
            Message(id: "room-\(o.id)", role: o.who == nil ? .assistant : .user,
                    text: "〔\(o.room)\(o.who.map { " · " + $0 } ?? "")〕" + o.text, at: o.at)
        }
        var out: [Message] = []
        var i = 0, j = 0
        while i < current.count || j < extra.count {
            if j >= extra.count || (i < current.count && current[i].at <= extra[j].at) {
                out.append(current[i]); i += 1
            } else {
                out.append(extra[j]); j += 1
            }
        }
        return out
    }
}
