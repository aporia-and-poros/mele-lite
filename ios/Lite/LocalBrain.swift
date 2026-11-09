#if LITE
import Foundation
import UIKit
import UserNotifications
import MeleLiteCore

/// 小管家的大脑：照服务器 api/rooms.py + brain/turn.py 的节奏，用零件包的提示词和三家接头跑一轮。
/// - 发来的话先进等候区，安静满 reply_wait 秒才跑（「等 TA 说完」）；连发几句拼成一句，几句原样存成 parts。
/// - 事件顺序跟服务器一样：先存 TA 的话 → typing → thinking（整段，一次）→ bubble / typing / bubble … → 存它的话 → done。
final class LocalBrain: @unchecked Sendable {
    unowned let host: LocalHost
    private let lock = NSLock()

    private final class Room {
        var listeners: [UUID: AsyncStream<Data>.Continuation] = [:]
        var pending: [String] = []
        var pendingIDs: [String?] = []     // 跟 pending 一一对应的 client_id（撤回用，10-20）
        var files: [String] = []
        var seen: Set<String> = []
        var timer: Task<Void, Never>?
        var running: Task<Void, Never>?
        /// 群里你插话了（10-11）：正在说的那个说完就停，后面排着的作废，从你这句重新来
        var interrupt = false
        /// 重新回（11-07）：撤掉的那几版，下一条回复存的时候接上
        var keptVariants: [String] = []
    }
    private var rooms: [String: Room] = [:]
    private var graceIDs: [String: UIBackgroundTaskIdentifier] = [:]
    /// 这一轮跑到一半被手机挂起、回来才写完的窗口（10-20）：回复作废，外面那层负责重来
    private var staleConvs: Set<String> = []

    init(host: LocalHost) { self.host = host }

    // MARK: 切后台（10-05 夜Aporia：回完消息切走，TA 的回复也要出来）
    // 发了话就向苹果多要一段后台时间（大约 30 秒），撑过「等 TA 说完」和它想、说的这一轮；这一轮跑完、没有下一轮了再还回去。
    // 苹果收回时间之前没说完的，回到 App 再接着跑。

    private func holdOn(_ conv: String) {
        // 回复要能在你切走时弹通知：第一次发消息时问一次权限（给过 / 拒过的，系统不会再弹）
        UNUserNotificationCenter.current().getNotificationSettings { st in
            if st.authorizationStatus == .notDetermined {
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
            }
        }
        DispatchQueue.main.async { [self] in
            guard lock.withLock({ graceIDs[conv] == nil }) else { return }
            let id = UIApplication.shared.beginBackgroundTask(withName: "reply") { [weak self] in self?.letGo(conv) }
            lock.withLock { graceIDs[conv] = id }
        }
    }

    private func letGo(_ conv: String) {
        DispatchQueue.main.async { [self] in
            guard let id = lock.withLock({ graceIDs.removeValue(forKey: conv) }) else { return }
            UIApplication.shared.endBackgroundTask(id)
        }
    }

    /// 发一个气泡时 TA 不在 App 里：弹一条本机通知（名字 + 这个气泡），点开进这个窗口
    private func notifyIfAway(_ conv: String, companion: String, name: String, text: String, group: Bool = false) async {
        let away = await MainActor.run { UIApplication.shared.applicationState != .active }
        let body = text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard away, !body.isEmpty else { return }
        let n = UNMutableNotificationContent()
        n.title = name
        n.body = body.count > 150 ? String(body.prefix(150)) + "…" : body
        n.sound = .default
        n.userInfo = group ? ["conversation": conv, "group": true] : ["conversation": conv, "companion": companion]   // 群：点开进群（10-11）
        n.threadIdentifier = conv                      // 同一个窗口的几条叠在一起
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "reply-\(conv)-\(Date().timeIntervalSince1970)",
                                                                               content: n, trigger: nil))
    }

    private func room(_ conv: String) -> Room {
        lock.withLock {
            if let r = rooms[conv] { return r }
            let r = Room()
            rooms[conv] = r
            return r
        }
    }

    // MARK: 事件流

    func listen(_ conv: String) -> AsyncStream<Data> {
        let r = room(conv)
        let id = UUID()
        return AsyncStream { cont in
            cont.yield(Data(": hello\n\n".utf8))
            lock.withLock { r.listeners[id] = cont }
            let ping = Task {               // 心跳：URLSession 30 秒没动静会当成超时
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(15))
                    cont.yield(Data(": ping\n\n".utf8))
                }
            }
            cont.onTermination = { [weak self] _ in
                ping.cancel()
                self?.lock.withLock { _ = r.listeners.removeValue(forKey: id) }
            }
        }
    }

    private func emit(_ conv: String, _ ev: [String: Any]) {
        guard let d = try? JSONSerialization.data(withJSONObject: ev) else { return }
        var line = Data("data: ".utf8)
        line.append(d)
        line.append(Data("\n\n".utf8))
        let r = room(conv)
        let all = lock.withLock { Array(r.listeners.values) }
        for c in all { c.yield(line) }
    }

    func busy(_ conv: String) -> Bool {
        let r = room(conv)
        return lock.withLock { !r.pending.isEmpty || r.running != nil }
    }

    func drop(_ conv: String) {
        let r = room(conv)
        let all = lock.withLock { () -> [AsyncStream<Data>.Continuation] in
            r.timer?.cancel(); r.running?.cancel()
            defer { rooms[conv] = nil }
            return Array(r.listeners.values)
        }
        for c in all { c.finish() }
        letGo(conv)
    }

    // MARK: 发

    func submit(_ conv: String, _ body: [String: Any]) -> LocalResponse {
        let isGroup = LocalGroups.group(host.store, conv) != nil
        guard let comp = host.companion(ofConversation: conv) ?? LocalGroups.members(host.store, conv).first else {
            return .error(404, String(localized: "没有这个窗口"))
        }
        let text = (body["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let files = (body["attachments"] as? [String] ?? []).prefix(10)
        guard !text.isEmpty || !files.isEmpty else { return .error(400, String(localized: "说点什么吧")) }
        let clientID = body["client_id"] as? String
        // 「划线说两句」：带着 book_mark_id 就把线头挂在这个窗口上，它接下来的回话抄进页边；没带就摘掉
        LocalBooks.arm(host.store, conversation: conv, mark: body["book_mark_id"] as? Int)
        let wait = (comp["settings"] as? [String: Any])?["reply_wait"] as? Double
            ?? Double((comp["settings"] as? [String: Any])?["reply_wait"] as? Int ?? 10)
        let r = room(conv)
        var queued = true
        lock.withLock {
            if let clientID, r.seen.contains(clientID) { queued = false; return }
            if let clientID { r.seen.insert(clientID) }
            if !text.isEmpty { r.pending.append(text); r.pendingIDs.append(clientID) }
            r.files.append(contentsOf: files)
            if isGroup, r.running != nil { r.interrupt = true }
            r.timer?.cancel()
            r.timer = Task { [weak self] in
                try? await Task.sleep(for: .seconds(max(0.5, wait)))
                guard !Task.isCancelled else { return }
                self?.flush(conv)
            }
        }
        if queued { holdOn(conv) }
        return .json(["queued": queued, "client_id": clientID.map { $0 as Any } ?? NSNull(), "reply_wait": wait], status: 202)
    }

    private func flush(_ conv: String) {
        let r = room(conv)
        let (parts, files, busy): ([String], [String], Bool) = lock.withLock {
            guard r.running == nil else { return ([], [], true) }       // 上一轮还在跑：等它跑完再 flush
            defer { r.pending = []; r.pendingIDs = []; r.files = [] }
            return (r.pending, r.files, false)
        }
        guard !parts.isEmpty || !files.isEmpty else {
            if !busy { letGo(conv) }
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            self.host.store.addMessage(conv, role: "user", text: parts.joined(separator: "\n"),
                                       parts: parts.count > 1 ? parts : nil, attachments: files)
            // 你在聊天里发的照片也收进相册（跟服务器一样，来源记「聊天」）
            if let cid = self.host.store.conversation(conv)?["companion_id"] as? String,
               self.host.store.conversation(conv)?["incognito"] as? Bool != true {
                for f in files {
                    let att = self.host.store.collection("attachments").first { ($0["id"] as? String) == f }
                    guard (att?["kind"] as? String) == "image", (att?["name"] as? String ?? "").hasPrefix("sticker-") == false,
                          let d = try? Data(contentsOf: self.host.store.fileURL("att-\(f)")) else { continue }
                    LocalRooms3.addPhoto(self.host, d, companion: cid, source: "chat")
                }
            }
            await self.runRoom(conv, images: files)
            let again = self.lock.withLock { () -> Bool in r.running = nil; return !r.pending.isEmpty || !r.files.isEmpty }
            if again { self.flush(conv) }
            else { self.letGo(conv) }
        }
        lock.withLock { r.running = task }
    }

    // MARK: 倒回（照服务器 /rewind：点自己那句 = 撤回改写；点它那句 = 重新回）

    func rewind(_ conv: String, _ body: [String: Any]) -> LocalResponse {
        guard !busy(conv) else { return .error(409, String(localized: "它还在回，等这一轮说完再倒回")) }
        guard let mid = body["message_id"] as? Int else { return .error(400, "要带 message_id") }
        var list = host.store.messages(conv)
        guard let i = list.firstIndex(where: { ($0["id"] as? Int) == mid }) else { return .error(400, String(localized: "没有这条消息")) }
        let role = list[i]["role"] as? String
        if role == "user" {
            let text = list[i]["text"] as? String ?? ""
            list.removeSubrange(i...)
            host.store.saveMessages(conv, list)
            return .json(["kind": "edit", "text": text])
        }
        // 重新回之前留一份（11-07，一测最想要的）：撤掉的话合成一版，排在原来那几版后面，最多留 9 版
        var kept: [String] = []
        if LocalGroups.group(host.store, conv) == nil {
            let gone = list[i...].filter { ($0["role"] as? String) == "assistant" }.compactMap { $0["text"] as? String }
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            var old = list[i]["variants"] as? [String] ?? []
            if let v = list[i]["variant"] as? Int, old.indices.contains(v) { old.remove(at: v) }
            if !gone.isEmpty { kept = Array((old + [gone.joined(separator: "\n\n")]).suffix(9)) }
        }
        list.removeSubrange(i...)
        host.store.saveMessages(conv, list)
        let r = room(conv)
        lock.withLock { r.keptVariants = kept }
        let task = Task { [weak self] in
            await self?.runRoom(conv, images: [])
            self?.lock.withLock { r.running = nil; r.keptVariants = [] }   // 这一轮没说出话：旧版不留给下一条回复
        }
        lock.withLock { r.running = task }
        return .json(["kind": "regenerate"])
    }

    // MARK: 撤回（10-20，照之前自用的 App；Host 同一个 /recall）：只删 TA 自己的这一句，它的回复都留着。
    // 它还没读到（后面没有它的话、也不在回）就悄悄删；读过了，像微信那样递一句「撤回了哪句」让它接（私聊才说，群里只删）

    func recall(_ conv: String, _ body: [String: Any]) -> LocalResponse {
        // 刚发出去、还在「等你说完」里的那句：它还没看到，直接拿掉；拿空了连计时也停（不然会拿空话跑一轮）
        if let cid = body["client_id"] as? String, !cid.isEmpty {
            let r = room(conv)
            let (took, empty) = lock.withLock { () -> (Bool, Bool) in
                guard let i = r.pendingIDs.firstIndex(of: cid) else { return (false, false) }
                r.pending.remove(at: i); r.pendingIDs.remove(at: i)
                let empty = r.pending.isEmpty && r.files.isEmpty && r.running == nil
                if empty { r.timer?.cancel(); r.timer = nil }
                return (true, empty)
            }
            guard took else { return .error(409, String(localized: "TA 已经开始看了，等它回完再撤回")) }
            if empty { letGo(conv) }
            return .json(["recalled": NSNull(), "told": false])
        }
        guard let mid = body["message_id"] as? Int else { return .error(400, "要带 message_id") }
        var list = host.store.messages(conv)
        guard let i = list.firstIndex(where: { ($0["id"] as? Int) == mid }), (list[i]["role"] as? String) == "user",
              mid > LocalEcho.rolledUpto(host.store, conv) else {
            return .error(400, String(localized: "只能撤回自己说的、还没卷进账本的话"))
        }
        let text = (list[i]["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let read = busy(conv) || list[(i + 1)...].contains { ($0["role"] as? String) == "assistant" }
        list.remove(at: i)
        host.store.saveMessages(conv, list)
        let isGroup = LocalGroups.group(host.store, conv) != nil
        let incognito = host.store.conversation(conv)?["incognito"] as? Bool ?? false
        let told = read && !isGroup && !incognito
        if told, let comp = host.companion(ofConversation: conv) {
            let st = comp["settings"] as? [String: Any] ?? [:]
            let zh = (st["lang"] as? String ?? "zh") == "zh"
            let p: String = switch st["user_pronoun"] as? String {
            case "she": zh ? "她" : "She"
            case "he": zh ? "他" : "He"
            default: zh ? "TA" : "They"
            }
            let said = text.count > 300 ? String(text.prefix(300)) : text
            poke(conv, nudge: zh ? "〔\(p)撤回了一条消息：「\(said)」〕\n你刚才已经看到了。像微信里对方撤回那样，照你自己的样子接就好。"
                                 : "[\(p) unsent a message: \"\(said)\"]\nYou'd already seen it. Like when someone unsends a message in a chat app — respond however you naturally would.")
        }
        return .json(["recalled": mid, "told": told])
    }

    /// 不等 TA 说话，直接跑一轮（查手机答复、加好友后它先开口）：nudge = 递给它的一句旁白（不存），peek = 翻到的东西
    func poke(_ conv: String, nudge: String, peek: String? = nil) {
        let r = room(conv)
        let prev = lock.withLock { r.running }
        let task = Task { [weak self] in
            await prev?.value
            guard let self else { return }
            await self.runTurn(conv, images: [], nudge: nudge, peek: peek)
            let again = self.lock.withLock { () -> Bool in r.running = nil; return !r.pending.isEmpty || !r.files.isEmpty }
            if again { self.flush(conv) }
        }
        lock.withLock { r.running = task }
    }

    // MARK: 电话（10-31 Aporia）：同一个聊天窗口，你那句标〔电话〕；不进等候区，停嘴就跑；它边写边把句子交给通话页去念

    /// 电话里说完一句：存下（标 call）→ 跑一轮。上一轮还在跑（打字那边的、或者被打断还没收尾的）先等它收完
    func callTurn(_ conv: String, text: String, link: CallLink) async {
        guard let comp = host.companion(ofConversation: conv) else { link.fail(String(localized: "没有这个窗口")); return }
        let r = room(conv)
        let prev = lock.withLock { r.running }
        await prev?.value
        let task = Task { [weak self] in
            guard let self else { return }
            let m = self.host.store.addMessage(conv, role: "user", text: text, extra: ["call": true, "call_id": link.callID])
            link.userMessageID = m["id"] as? Int
            _ = await self.runTurn(conv, comp: comp, images: [], group: nil, call: link)
        }
        lock.withLock { r.running = task }
        await task.value
        let again = lock.withLock { () -> Bool in
            if r.running == task { r.running = nil }
            return r.running == nil && (!r.pending.isEmpty || !r.files.isEmpty)
        }
        if again { flush(conv) }
    }

    /// TA 打来的电话你接起来了（第 4 步）：不存你说的话，递一句旁白让它先开口（照 poke 的意思）
    func callAnswered(_ conv: String, reason: String, link: CallLink) async {
        guard let comp = host.companion(ofConversation: conv) else { link.fail(String(localized: "没有这个窗口")); return }
        let st = comp["settings"] as? [String: Any] ?? [:]
        let zh = (st["lang"] as? String ?? "zh") == "zh"
        let nudge = CallSpeech.answeredNudge(zh: zh, pronoun: Self.pronoun(st, zh: zh), reason: reason)
        let r = room(conv)
        let prev = lock.withLock { r.running }
        await prev?.value
        let task = Task { [weak self] in
            guard let self else { return }
            _ = await self.runTurn(conv, comp: comp, images: [], nudge: nudge, group: nil, call: link)
        }
        lock.withLock { r.running = task }
        await task.value
        let again = lock.withLock { () -> Bool in
            if r.running == task { r.running = nil }
            return r.running == nil && (!r.pending.isEmpty || !r.files.isEmpty)
        }
        if again { flush(conv) }
    }

    /// TA 打来没接通（未接 / 拒绝 / TA 撤回）：聊天里一行灰字，正文是给它的纸条，下一轮它看得到
    func ringEnded(_ conv: String, callID: String, ring: CallSpeech.Ring) async {
        let st = host.companion(ofConversation: conv)?["settings"] as? [String: Any] ?? [:]
        let zh = (st["lang"] as? String ?? "zh") == "zh"
        host.store.addMessage(conv, role: "user", text: CallSpeech.ringNote(ring, zh: zh, pronoun: Self.pronoun(st, zh: zh)),
                              extra: ["ring": ring.rawValue, "call_id": callID, "divider": CallSpeech.ringLine(ring, zh: zh)])
        emit(conv, ["type": "done"])
    }

    static func pronoun(_ settings: [String: Any], zh: Bool) -> String {
        switch settings["user_pronoun"] as? String {
        case "she": zh ? "她" : "she"
        case "he": zh ? "他" : "he"
        default: zh ? "TA" : "they"
        }
    }

    /// 它写完了、还没念完就被你打断（10-31 自测：三句都存进去了，你只听到第一句）：存档改成只留念出来的，末尾「——」
    func callTrim(_ conv: String, message id: Int, spoken: [String]) {
        var list = host.store.messages(conv)
        guard let i = list.firstIndex(where: { ($0["id"] as? Int) == id }), list[i]["call"] as? Bool == true else { return }
        let said = spoken.joined(separator: "\n")
        guard !said.isEmpty else { list.remove(at: i); host.store.saveMessages(conv, list); return }
        list[i]["text"] = said + "——"
        list[i]["cut"] = true
        host.store.saveMessages(conv, list)
    }

    /// 准确的字回来了（转写比 1.5 秒慢的那次）：把存档里手机识别的那句换掉
    func callFix(_ conv: String, message id: Int, text: String) {
        var list = host.store.messages(conv)
        guard let i = list.firstIndex(where: { ($0["id"] as? Int) == id }), list[i]["call"] as? Bool == true,
              !text.isEmpty else { return }
        list[i]["text"] = text
        host.store.saveMessages(conv, list)
    }

    /// 挂了：聊天里多一行「📞 通话时长 03:21」，正文是递给它的纸条（不然挂了以后你打的字它还当电话、用电话腔回）
    func callEnded(_ conv: String, seconds: Int, callID: String) async {
        let r = room(conv)
        await lock.withLock({ r.running })?.value          // 被挂断的那一轮先收完，纸条排在它后面
        let zh = ((host.companion(ofConversation: conv)?["settings"] as? [String: Any])?["lang"] as? String ?? "zh") == "zh"
        host.store.addMessage(conv, role: "user", text: CallSpeech.hangUpNote(seconds: seconds, zh: zh),
                              extra: ["call_end": true, "call_id": callID, "seconds": seconds,
                                      "divider": CallSpeech.durationLine(seconds: seconds, zh: zh)])
        emit(conv, ["type": "done"])                        // 聊天页补拉一次
    }

    // MARK: 跑一轮

    /// 私聊跑一轮；群走 runGroup
    private func runRoom(_ conv: String, images: [String]) async {
        if LocalGroups.group(host.store, conv) != nil { await runGroup(conv, images: images) }
        else { await runTurn(conv, images: images) }
    }

    private func runTurn(_ conv: String, images: [String], nudge: String? = nil, peek: String? = nil) async {
        guard let comp = host.companion(ofConversation: conv) else { return }
        _ = await runTurn(conv, comp: comp, images: images, nudge: nudge, peek: peek, group: nil)
        // 跑到一半被挂起、回来才写完的那份作废了（见 staleTurnSeconds）：她这期间又发了的，交给 flush 连新的一起回；没发的，按现在重回一遍
        let r = room(conv)
        let (stale, waiting) = lock.withLock { (staleConvs.remove(conv) != nil, !r.pending.isEmpty || !r.files.isEmpty) }
        if stale, !waiting { _ = await runTurn(conv, comp: comp, images: images, nudge: nudge, peek: peek, group: nil) }
    }

    /// 一轮从开口到写完超过这么久 = 中间被手机挂起过（10-20 内测：一点五十五发完切走，后台时间到了请求停在半路，
    /// 三点五十八回来才写完，「现在是 13:55」那份回复顶着 15:58 出现，像在回她刚说的「五点来接我」）
    static let staleTurnSeconds: TimeInterval = 600

    /// 群里这一轮的背景：群名、别的成员、对你怎么称呼
    struct GroupCtx {
        let name: String
        let others: [String]
        let joinedAt: Date?
        let seesHistory: Bool
    }

    // MARK: 群（10-11）：你说一句 → 没被 @ 的各自判断「说 / 过」→ 想说的排队一个一个说 → 每说完一个，别的再判断要不要接 → 到轮数上限停

    private func runGroup(_ conv: String, images: [String]) async {
        let s = host.store
        let r = room(conv)
        lock.withLock { r.interrupt = false }
        defer { emit(conv, ["type": "round_end"]) }
        guard let g0 = LocalGroups.group(s, conv) else { return }
        let maxRounds = max(1, min(12, g0["max_rounds"] as? Int ?? LocalGroups.defaultRounds))
        func members() -> [[String: Any]] { LocalGroups.members(s, conv) }
        func roster() -> [GroupChat.Member] {
            members().map { GroupChat.Member(id: $0["id"] as? String ?? "", name: LocalGroups.name(of: $0)) }
        }
        guard !members().isEmpty else { return }
        let lastUser = s.messages(conv).last { ($0["role"] as? String) == "user" }?["text"] as? String ?? ""
        let firstMentioned = GroupChat.mentioned(in: lastUser, members: roster())
        let firstWanting = await judgeAll(conv, members().filter { !firstMentioned.contains($0["id"] as? String ?? "") })
        var queue = GroupChat.order(mentioned: firstMentioned, wanting: firstWanting)
        #if DEBUG
        groupLog("start mentioned=\(firstMentioned) wanting=\(firstWanting) queue=\(queue)")
        #endif
        let answeringYou = Set(queue)                // 接你这句的：你发的图它们都看得到
        var rounds = 0
        while !queue.isEmpty, rounds < maxRounds {
            if lock.withLock({ r.interrupt }) { return }
            let id = queue.removeFirst()
            guard let comp = members().first(where: { ($0["id"] as? String) == id }), let g = LocalGroups.group(s, conv) else { continue }
            let joined = (g["joined_at"] as? [String: String])?[id]
            let created = LocalStore.date(g["created_at"])
            let ctx = GroupCtx(name: LocalGroups.displayName(s, g),
                               others: roster().filter { $0.id != id }.map(\.name),
                               joinedAt: joined.map { LocalStore.date($0) }.flatMap { $0 > created.addingTimeInterval(1) ? $0 : nil },
                               seesHistory: g["new_member_sees_history"] as? Bool ?? true)
            let said = await runTurn(conv, comp: comp, images: answeringYou.contains(id) ? images : [], group: ctx)
            #if DEBUG
            groupLog("turn \(LocalGroups.name(of: comp)) said=\(said) queue=\(queue) rounds=\(rounds)")
            #endif
            guard said else { continue }
            rounds += 1
            if rounds >= maxRounds || lock.withLock({ r.interrupt }) { break }
            // 别人要不要接它这句：都自己判断（10-11 Aporia：TA 之间互相 @ 不强制对方接，只有你 @ 的才必须接；
            // 被点名的在判断里看得到自己被 @ 了）。已经在排队的不重复
            let rest = members().filter { let c = $0["id"] as? String ?? ""; return c != id && !queue.contains(c) }
            queue += GroupChat.order(mentioned: [], wanting: await judgeAll(conv, rest))
        }
    }

    /// 并行问一圈「说 / 过」，按名单顺序返回想说的
    private func judgeAll(_ conv: String, _ comps: [[String: Any]]) async -> [String] {
        guard !comps.isEmpty else { return [] }
        let ids = comps.compactMap { $0["id"] as? String }
        let yes = await withTaskGroup(of: (String, Bool).self) { tg in
            for c in comps {
                let id = c["id"] as? String ?? ""
                tg.addTask { [weak self] in (id, await self?.judge(conv, c) ?? false) }
            }
            var out: Set<String> = []
            for await (id, ok) in tg where ok { out.insert(id) }
            return out
        }
        return ids.filter { yes.contains($0) }
    }

    /// 它自己的模型判断一下想不想接（只回一个字）；没 key、出错、看不懂都算「过」
    private func judge(_ conv: String, _ comp: [String: Any]) async -> Bool {
        guard let (routed, key) = host.route(for: comp), let g = LocalGroups.group(host.store, conv) else { return false }
        var provider = routed
        provider.thinking = false
        let settings = comp["settings"] as? [String: Any] ?? [:]
        let zh = (settings["lang"] as? String ?? "zh") == "zh"
        let me = LocalGroups.name(of: comp)
        let uname = Self.userLabel(settings, zh: zh)
        let others = LocalGroups.members(host.store, conv).filter { ($0["id"] as? String) != (comp["id"] as? String) }.map(LocalGroups.name(of:))
        let recent: [(who: String, text: String)] = host.store.messages(conv).suffix(12).map {
            let who = ($0["role"] as? String) == "assistant" ? ($0["speaker_name"] as? String ?? "TA") : uname
            return (who == me ? (zh ? "你" : "you") : who, $0["text"] as? String ?? "")
        }
        let p = GroupChat.judgePrompt(zh: zh, me: me, persona: Self.contact(comp, provider: provider).persona,
                                      group: LocalGroups.displayName(host.store, g), userName: uname, others: others, recent: recent)
        let req = ChatRequest(system: p.system, turns: [ChatTurn(role: .user, text: p.user)], maxTokens: 32)
        var out = ""
        do {
            try await UsageMeter.$tag.withValue(zh ? "群聊判断" : "group judge") {
                for try await e in makeClient(provider, key: key).stream(req) {
                    if case .text(let t) = e { out += t }
                }
            }
        } catch {
            return false
        }
        #if DEBUG
        groupLog("judge \(me): \(out.replacingOccurrences(of: "\n", with: " "))")
        #endif
        return GroupChat.wantsToSpeak(out)
    }

    #if DEBUG
    /// 自测（10-11）：群调度一步一行写到 lite-host/debug-group.txt
    func groupLog(_ line: String) {
        let url = host.store.fileURL("debug-group.txt")
        let row = "\(LocalStore.iso(Date())) \(line)\n"
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(row.utf8)); try? h.close() }
        else { try? row.write(to: url, atomically: true, encoding: .utf8) }
    }
    #endif

    /// 你在群里 / 私聊里的称呼：设定里的名字，没有就用代词
    static func userLabel(_ settings: [String: Any], zh: Bool) -> String {
        let n = (settings["user_name"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        if !n.isEmpty { return n }
        switch settings["user_pronoun"] as? String {
        case "she": return zh ? "她" : "her"
        case "he": return zh ? "他" : "him"
        default: return zh ? "TA" : "them"
        }
    }

    /// 替 comp 在 conv 里跑一轮（群里 group 不为空）。返回它有没有说话
    @discardableResult
    private func runTurn(_ conv: String, comp: [String: Any], images: [String], nudge: String? = nil, peek: String? = nil,
                         group: GroupCtx?, call: CallLink? = nil) async -> Bool {
        let settings = comp["settings"] as? [String: Any] ?? [:]
        let zh = (settings["lang"] as? String ?? "zh") == "zh"
        let cidSelf = comp["id"] as? String ?? ""
        let selfName = LocalGroups.name(of: comp)
        // 群里每个事件都带上是谁（App 按人画头像名字）
        let say = { (ev: [String: Any]) in
            var e = ev
            if group != nil { e["speaker"] = cidSelf; e["speaker_name"] = selfName }
            self.emit(conv, e)
        }
        say(["type": "typing"])
        guard let (routed, key) = host.route(for: comp) else {
            call?.fail(zh ? "还没给 TA 配 key，打不了电话" : "No key yet, so no call")
            say(["type": "error", "kind": "no_key",
                        "message": zh ? "还没给 TA 配 key：去 Me →「钥匙串」加一把你自己的，再在 TA 的设定里选上。"
                                      : "No key yet: add your own in Me → Keys, then pick it in their settings."])
            say(["type": "done"])
            return false
        }

        // 怎么想（10-04 Aporia：Lite 也能选手写独白）：独白时关掉模型自己的思考，让 TA 把心里话写在回复最前面
        // 没选 = 手写独白（10-04 Aporia）：Claude / Gemini 只给第三人称的思考摘要、GPT 走这条接口不给思考、DeepSeek 原生的是分析腔，
        // 想看 TA 心里话哪家都得写独白；想看模型自己那段的，在高级里选「模型自己的思考」
        let mode = (settings["thinking_mode"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "monologue"
        // 电话里（10-31）：手写独白、模型自己的思考都关掉，开口要快
        let monologue = call == nil && (settings["thinking"] as? Bool ?? true) && mode == "monologue"
        var provider = routed
        if monologue || call != nil { provider.thinking = false }
        // 看图（10-15）：TA 的模型看不见图时，这一轮发的照片先交给看图钥匙写描述（存在附件上，以后的历史里也用它）
        let sees = provider.seesImages
        if !sees {
            var blind = false
            for id in images where host.store.collection("attachments").first(where: { ($0["id"] as? String) == id })?["kind"] as? String == "image" {
                if await LocalMedia.describe(host, attachment: id, zh: zh) == nil { blind = true }
            }
            // 10-16 内测「点钥匙再勾太隐秘」：看不见、又没有看图钥匙的，聊天里提醒一句去哪挑
            if blind, LocalMedia.visionRoute(host) == nil {
                say(["type": "notice", "text": zh ? "TA 的模型看不见图，这张它只知道你发了照片。去 Me →「看图和画图」填一把会看图的钥匙（Gemini、Claude、OpenAI 或中转站），以后就能替它看。"
                                                  : "Their model can't see images, so it only knows you sent a photo. Add a key that can see (Gemini, Claude, OpenAI or a relay) in Me → \"Seeing & drawing\"."])
            }
        }
        // 叫 TA 画图、但还没挑画图钥匙：TA 手里没有 draw，只会嘴上答应。提醒一句去哪挑（10-16）
        if group == nil, nudge == nil, LocalMedia.imageRoute(host) == nil,
           let said = host.store.messages(conv).last(where: { ($0["role"] as? String) == "user" })?["text"] as? String,
           Chores.wantsDrawing(said) {
            say(["type": "notice", "text": zh ? "TA 现在还不会画图：去 Me →「看图和画图」填一把画图钥匙（Gemini、OpenAI 或中转站），填了所有 TA 都能画。"
                                              : "They can't draw yet: add a drawing key (Gemini, OpenAI or a relay) in Me → \"Seeing & drawing\" — then every companion can draw."])
        }

        // 积压（10-13 内测：中转不报用量的老版本积了几千条没卷）：先卷了再聊，不然这一轮整段发出去，装不下就报错、永远轮不到卷
        if group == nil, LocalEcho.backlogged(host.store, conversation: conv, settings: settings) {
            await LocalEcho.rollNow(host, conversation: conv)
        }
        // 回声（10-04）：卷进账本的那些不再原样进上下文，账本放 system 里
        let rolledUpto = LocalEcho.rolledUpto(host.store, conv)
        var stored = host.store.messages(conv).filter { ($0["id"] as? Int ?? 0) > rolledUpto }
        let uname = Self.userLabel(settings, zh: zh)
        // 群：后来拉进来的——开关开着看进群前最近 30 条（还没开过口就垫一句「刚被拉进群」），关着只看进群以后的
        var joinNoteAt: Int?
        if let group, let joined = group.joinedAt {
            let before = stored.filter { LocalStore.date($0["at"]) < joined }
            let after = stored.filter { LocalStore.date($0["at"]) >= joined }
            if !group.seesHistory {
                stored = after
            } else if !before.isEmpty {
                let kept = Array(before.suffix(LocalGroups.historyOnJoin))
                stored = kept + after
                let spoke = after.contains { ($0["role"] as? String) == "assistant" && ($0["speaker"] as? String) == cidSelf }
                if !spoke { joinNoteAt = kept.count }
            }
        }
        let voiceNotes = Dictionary(host.store.collection("attachments").filter { ($0["kind"] as? String) == "voice" }
            .compactMap { a in (a["id"] as? String).map { ($0, a["caption"] as? String ?? "") } }, uniquingKeysWith: { a, _ in a })
        // 照片（10-15）：看不见图的模型在历史里看描述。
        // 10-16 内测「读不到前两轮发的图」：看得见的模型原图只在发的那一轮给，之后历史里连一句「发过照片」都没有——
        // 现在前几轮的照片也写〔发了一张照片：描述〕（没描述的最近 3 张先补写，写过存在附件上，只写一次）；这一轮那张照旧给原图
        let isPhoto: ([String: Any]) -> Bool = { ($0["kind"] as? String) == "image" && !(($0["name"] as? String ?? "").hasPrefix("sticker-")) }
        let shownNow: String? = sees ? images.first { id in host.store.collection("attachments").first { ($0["id"] as? String) == id }.map(isPhoto) ?? false } : nil
        if sees {
            let past = Set(stored.flatMap { $0["attachments"] as? [String] ?? [] }).subtracting(images)
            let blank = host.store.collection("attachments").filter {
                isPhoto($0) && past.contains($0["id"] as? String ?? "") && ($0["caption"] as? String ?? "").isEmpty && !($0["drawn"] as? Bool ?? false)
            }.compactMap { $0["id"] as? String }
            let recent = stored.reversed().flatMap { ($0["attachments"] as? [String] ?? []).reversed() }.filter(blank.contains)
            for id in recent.prefix(3) { _ = await LocalMedia.describe(host, attachment: id, zh: zh) }
        }
        let photoNotes = Dictionary(host.store.collection("attachments").filter { isPhoto($0) && ($0["id"] as? String) != shownNow }
            .compactMap { a in (a["id"] as? String).map { ($0, a) } }, uniquingKeysWith: { a, _ in a })
        // 上一轮它做过的事（立里程碑、抽牌、发表情包、记账……）：存下来的正文把标记洗掉了，卡片又不进上下文，
        // 它会忘了自己做过、下一轮再做一遍（10-05 真 key 测出来：同一座里程碑连立三轮）。照服务器 TOOLS_HEAD 垫在下一句前面
        var pendingDeeds = ""
        // 独白一会有一会没有（10-12 内测）：历史里存的只有正文，它看自己前面几轮全没写独白，就跟着不写了。
        // 最近那一轮它写过的独白垫回去，让它看见自己一直是这么开口的（只垫一轮，省 token、缓存只动尾巴）
        // 10-12 内测「时不时消失」：只看上一轮的话，上一轮漏了历史里就一段都没有，越漏越多——往回找最近三轮里写过的那段
        let lastMonoID: Int? = monologue
            ? stored.filter { ($0["role"] as? String) == "assistant" && (group == nil || ($0["speaker"] as? String) == cidSelf) }
                .suffix(3).last { !(($0["thinking"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
                .flatMap { $0["id"] as? Int }
            : nil
        // 旧版本漏进正文的心里话（10-19）：回看历史前洗掉，不让 TA 照着自己漏过的样子学（手写独白时才认没标记的）
        let leakPronoun: String = switch settings["user_pronoun"] as? String {
        case _ where !(monologue && group == nil): ""
        case "she": zh ? "她" : "she"
        case "he": zh ? "他" : "he"
        default: zh ? "TA" : "they"
        }
        var history: [Message] = stored.map {
            var text = ($0["role"] as? String) == "user" ? Bilingual.userSide($0["text"] as? String ?? "", $0["translations"] as? [Any])
                                                          : $0["text"] as? String ?? ""
            if ($0["role"] as? String) == "assistant", group == nil { text = Monologue.spokenOnly(text, pronoun: leakPronoun, zh: zh) }
            if ($0["role"] as? String) == "user", $0["call"] as? Bool == true { text = CallSpeech.tag(zh: zh) + text }   // 电话里说的（10-31）
            if ($0["role"] as? String) == "assistant", $0["cut"] as? Bool == true { text += "\n" + CallSpeech.cutNote(zh: zh) }   // 念到一半被打断
            if let id = lastMonoID, ($0["id"] as? Int) == id, let mono = $0["thinking"] as? String {
                text = Monologue.wrap(mono.trimmingCharacters(in: .whitespacesAndNewlines), zh: zh) + "\n\n" + text
            }
            let role = $0["role"] as? String
            // 群里：只有它自己说的算 assistant；你和别的 TA 说的是 user，前面垫〔名字〕，别人的心声 / 思考 / 做过的事不进
            let isAssistant = role == "assistant" && (group == nil || ($0["speaker"] as? String) == cidSelf)
            // TA 发的语音（10-04）：正文是转写，前面垫一行〔语音 12 秒：说得偏慢〕
            let notes = ($0["attachments"] as? [String] ?? []).compactMap { voiceNotes[$0] }.filter { !$0.isEmpty }
            if !notes.isEmpty { text = notes.joined(separator: "\n") + "\n" + text }
            let photos = ($0["attachments"] as? [String] ?? []).compactMap { photoNotes[$0] }.map { a in
                (a["drawn"] as? Bool ?? false) ? (zh ? "〔你画了一张图：\(a["caption"] as? String ?? "")〕" : "〔You drew: \(a["caption"] as? String ?? "")〕")
                    : LocalMedia.photoLine(a["caption"] as? String ?? "", zh: zh)
            }
            if !photos.isEmpty { text = photos.joined(separator: "\n") + (text.isEmpty ? "" : "\n" + text) }
            if group != nil, !isAssistant {
                text = GroupChat.label(role == "assistant" ? ($0["speaker_name"] as? String ?? "TA") : uname) + text
            }
            if isAssistant, let v = $0["inner_voice"] as? String, !v.isEmpty {
                text += "\n\n" + InnerVoice.contextLine(v, zh: zh)        // 心声（10-11）：记得当时心里想什么，分得清没说出口
            }
            if isAssistant {
                let deeds = ($0["cards"] as? [[String: Any]] ?? []).filter { ($0["kind"] as? String) != "peek" }   // 查手机申请自己有一套
                    .compactMap { $0["text"] as? String }.filter { !$0.isEmpty }
                pendingDeeds = deeds.isEmpty ? "" : (zh ? "〔上一轮你做过：" : "〔Last turn you did: ") + deeds.joined(separator: zh ? "；" : "; ") + "〕"
            } else if !pendingDeeds.isEmpty {
                text = pendingDeeds + "\n" + text
                pendingDeeds = ""
            }
            return Message(role: isAssistant ? .assistant : .user, text: text, at: LocalStore.date($0["at"]))
        }
        if let i = joinNoteAt { history.insert(Message(role: .user, text: GroupChat.joinNote(zh: zh), at: group?.joinedAt ?? Date()), at: i) }
        // 一段脑子（10-11）：别的房间最近 N 条按时间插进来；无痕、小号窗口不合
        let convRec = host.store.conversation(conv)
        var roomNote = ""
        if (convRec?["incognito"] as? Bool) != true, convRec?["alt"] == nil {
            let limit = max(0, min(100, settings["other_rooms_count"] as? Int ?? 30))
            let others = LocalGroups.otherRooms(host.store, companion: cidSelf, except: conv, limit: limit, userName: uname, zh: zh)
            history = RoomTimeline.merge(history, others: others, limit: limit)
            if limit > 0, !others.isEmpty {
                roomNote = RoomTimeline.note(here: group.map { RoomTimeline.groupRoom($0.name, zh: zh) } ?? RoomTimeline.privateRoom(zh: zh), zh: zh)
            }
        }
        if group != nil, history.last?.role == .assistant {
            history.append(Message(role: .user, text: zh ? "（轮到你了）" : "(Your turn.)", at: Date()))
        }
        if let nudge { history.append(Message(role: .user, text: nudge, at: Date())) }
        var contact = Self.contact(comp, provider: provider)
        if call != nil {            // 电话里不写长文（线下模式那套场景、动作描写）
            contact.mode = .online
            contact.offlineLife = settings["offline_life"] as? Bool == true
        }
        // 小号窗口：同一个人设，它把你当成另一个人（名字 / 关于你 / 关系都换成这个窗口的）
        let altInfo = host.store.conversation(conv)?["alt"] as? [String: Any]
        let identity = altInfo.map {
            Identity(id: $0["id"] as? String ?? conv, isMain: false, userName: $0["user_name"] as? String ?? "",
                     aboutMe: $0["about_me"] as? String ?? "",
                     relationship: ($0["relationship"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (zh ? "陌生人" : "stranger"))
        } ?? contact.mainIdentity
        let lore = LocalRooms.loreEntries(host.store, companion: comp["id"] as? String ?? "")
        let hits = LoreMatcher.hits(entries: lore, recent: history, contactID: contact.id)
        let stickers = LocalRooms.stickersForPrompt(host.store)
        let image = shownNow.flatMap { id -> Data? in
            guard let d = try? Data(contentsOf: self.host.store.fileURL("att-\(id)")), let img = UIImage(data: d) else { return nil }
            return Self.jpeg(img, maxSide: 1280)
        }
        // 有回声兜着，原文留长一点（到记性长度就卷）；卷不动的时候最多 12 万字，别让一轮贵得离谱
        var req = Prompt.build(PromptInput(contact: contact, identity: identity, history: history, loreHits: hits,
                                           stickers: stickers, peekResult: peek, lang: zh ? .zh : .en, currentImage: image),
                               budgetChars: LocalEcho.historyCap)
        let extra = Self.injections(settings, recent: history.suffix(4).map(\.text).joined(separator: "\n"), turn: stored.count)
        if !extra.isEmpty { req.context += "\n\n" + extra }          // 每轮变的都进 context（缓存，10-04）
        // 表情包（10-31）：库大的时候系统提示里只有短目录，这里按刚聊的两句挑几张最搭的、给完整描述（电话里不发）
        let stickerMenu = StickerMenu(stickers)
        if call == nil {
            let fits = stickerMenu.picksBlock(stickerMenu.picks(for: history.suffix(2).map(\.text)), zh: zh)
            if !fits.isEmpty { req.context += "\n\n" + fits }
        }
        if group == nil, host.store.conversation(conv)?["incognito"] as? Bool != true {   // 偶尔想起（10-14）：隔几轮随手抽一条梗，它自己也会用
            let occ = LocalRooms.occasionalLore(host.store, companion: comp["id"] as? String ?? "", conversation: conv, msgCount: stored.count, zh: zh)
            if !occ.isEmpty { req.context += "\n\n" + occ }
        }
        // 〔在读〕TA 正在读哪本、〔塔罗〕TA 刚让它解过的一局、〔朋友圈〕上次聊完以后的新动静（一次性）
        // 小号不给：那是平常的你在读 / 在听 / 刚抽的牌
        let cidNow = comp["id"] as? String ?? ""
        for line in altInfo != nil || group != nil ? [] : [LocalBooks.readingLine(host.store, zh: zh, for: cidNow), LocalTarot.pendingNote(host.store, companion: cidNow, zh: zh),
                     LocalMusic.nowLine(host.store, zh: zh), LocalFocus.pendingNote(host.store, conversation: conv, zh: zh),
                     LocalRooms3.recapNote(host.store, companion: cidNow, conversation: conv, zh: zh)] where !line.isEmpty {
            req.context += "\n\n" + line
        }
        // 〔TA 那边〕天气 / 在哪 / 日程 / 步数和睡眠（10-04）：小号不给（那是平常的你那边）
        if altInfo == nil {
            let askedText = host.store.messages(conv).last { ($0["role"] as? String) == "user" }?["text"] as? String ?? ""
            let side = LocalContext.line(host.store, conversation: conv, zh: zh,
                                         force: ContextReporter.asks(askedText))
            if !side.isEmpty { req.context += "\n\n" + side }
        }
        // 〔现在〕它自己此刻在哪、在干嘛（它的一天；小号窗口也给——那是它自己的日子）
        let whereNow = LocalMap.nowLine(host.store, companion: cidNow, zh: zh)
        if !whereNow.isEmpty { req.context += "\n\n" + whereNow }
        // 记忆库（用户接的 MCP，10-04）：新对话先 wake，每轮拿刚说的 recall；无痕、小号不碰（记的是平常的你）
        let incognito = (host.store.conversation(conv)?["incognito"] as? Bool ?? false) || altInfo != nil
        // 声音（10-04）：它用的那家（ElevenLabs / MiniMax）有自己的 key、没关、不是无痕，才告诉它可以发语音条
        let voiceOn = call == nil && !(host.store.conversation(conv)?["incognito"] as? Bool ?? false) && LocalVoice.hasKey(host, settings)
            && (settings["voice_mode"] as? String ?? "sometimes") != "off"
        let voiceLines = LocalVoice.modeLines(settings, hasKey: voiceOn, zh: zh)
        if !voiceLines.isEmpty { req.system += "\n\n" + voiceLines }
        // 刚说的：私聊 = 它上一句以后你说的；群 = 它上一句以后大家说的（最多 4 句）
        let lastUser = group == nil
            ? stored.reversed().prefix { ($0["role"] as? String) != "assistant" }.reversed()
                .map { $0["text"] as? String ?? "" }.joined(separator: "\n")
            : stored.reversed().prefix { !(($0["role"] as? String) == "assistant" && ($0["speaker"] as? String) == cidSelf) }
                .prefix(4).reversed().map { $0["text"] as? String ?? "" }.joined(separator: "\n")
        let remembered = await host.mcp.memoryContext(host, companion: comp, conversation: conv, userText: lastUser, incognito: incognito)
        if !remembered.isEmpty { req.context += "\n\n" + remembered }
        // 钉住的记忆进壹层（10-11，照 Host render_base 的 core）：接的是本地记忆库才有；无痕不带
        if !incognito, host.mcp.memoryServer(host.store, companion: comp)?.id == LocalMemory.serverID {
            let pinned = LocalMemory.vault(LocalMemory.scope(of: comp)).pinnedLines()
            if !pinned.isEmpty {
                req.system += "\n\n" + (zh ? "## 一直记着的" : "## Always remember") + "\n" + pinned.map { "- " + $0 }.joined(separator: "\n")
            }
        }
        #if DEBUG
        // 自测（10-11）：SIMCTL_CHILD_LITE_TEST_DUMP=1 把这一轮的 system 写到 lite-host/debug-system.txt
        if ProcessInfo.processInfo.environment["LITE_TEST_DUMP"] != nil {
            try? req.system.write(to: host.store.fileURL("debug-system.txt"), atomically: true, encoding: .utf8)
            try? req.context.write(to: host.store.fileURL("debug-context.txt"), atomically: true, encoding: .utf8)
        }
        #endif
        // 工具：它可以先动手（记账、记待办、记饮食……）再说话；一轮最多来回 4 次，接了 MCP 6 次
        // 人物卡 / 远事归记忆库时，手机那份工具收起来，免得两边都写
        let box = await host.mcp.toolbox(host, companion: comp, incognito: incognito)
        var hiding: Set<String> = []
        if !LocalMap.lifeOn(host.store, cidNow) { hiding.insert("go_to") }       // 没有自己的一天就没地方可挪
        if LocalMedia.imageRoute(host) == nil || incognito { hiding.insert("draw") }  // 没挑画图钥匙就没有 draw
        if call != nil || group != nil || incognito { hiding.insert(LocalTools.phoneCall) }   // 打电话（10-31）：电话里、群里、无痕不打
        if box.memory != nil, LocalMCP.owner(settings, "memory_people") == "remote" { hiding.insert("person_save") }
        if box.memory != nil, LocalMCP.owner(settings, "memory_dates") == "remote" { hiding.insert("date_add") }
        if let group {
            // 群里（第一步）只开记忆库；表情包走标记不走工具
            req.tools = box.specs.filter { spec in box.memory.map { box.route[spec.name]?.0.id == $0.id } ?? false }
            req.system += "\n\n" + GroupChat.roomRules(zh: zh, group: group.name, me: selfName, userName: uname, others: group.others)
        } else {
            req.tools = LocalTools.specs(zh: zh, hiding: hiding) + box.specs
        }
        // 10-04 Aporia：Lite 的 Lumi 又开始乱用工具——以前这句写着「想用就用」，工具说明也只有一句话。
        // 现在说明照服务器那套（用途 + 什么时候用 + 悄悄做），这里只说一声在哪看
        if group == nil { req.system += zh ? "\n\n你有几样工具（记账、待办、饮食、人物卡、世界书、远事、朋友圈、书架、塔罗、发歌），每样什么时候用写在它自己的说明里。用完照样像平时一样跟 TA 说话。"
                         : "\n\nYou have a few tools (wallet, to-dos, food log, people cards, lorebook, dates, your feed, bookshelf, tarot, songs); when to use each is in its own description. Afterwards, talk to them as usual." }
        // 说明书（10-08 Aporia：开关，默认开）：讲清每轮递来的小纸条是什么；接了记忆库再加怎么记事；线上再补几条说话的
        if settings["full_handbook"] as? Bool ?? true {
            let mem = box.memory.map { (remember: MCPToolNames.exposed($0.slug, "remember"), search: MCPToolNames.exposed($0.slug, "search")) }
            req.system += "\n\n" + Handbook.text(zh: zh, online: contact.mode == .online, life: contact.offlineLife ?? false, memoryTools: mem,
                                                 bare: contact.bare == true)
        }
        if !box.specs.isEmpty {
            req.system += zh ? "另外还有用户接进来的工具（名字带前缀），描述里写了来自哪里。"
                             : " There are also tools the user connected (prefixed names); each description says where it comes from."
        }
        let pronoun = Self.pronoun(settings, zh: zh)
        let personaRaw = comp["persona"] as? [String: Any] ?? [:]
        let custom = !((personaRaw["imported"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                       && (personaRaw["personality"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        if monologue {
            // 10-08：照服务器的整份独白规矩 + Aporia写的出厂思考风格 + 范文（之前本机只有三行简化版，独白又短又在排练回复）
            // 本体化（11-03）：我们的思考风格、范文不放，用户自己写的照用；自己写的范文（11-03）换掉我们那两段
            req.system += "\n\n" + Monologue.rules(zh: zh, pronoun: pronoun, style: settings["thinking_style_text"] as? String ?? "",
                                                   userName: identity.userName, character: custom ? contact.name : "",
                                                   bare: contact.bare == true, examples: settings["monologue_examples"] as? String ?? "")
        }
        let innerOn = call == nil && settings["inner_voice"] as? Bool ?? false     // 回复后的心声（10-11）：规矩常驻 system，钩子压最后；电话里不写
        if innerOn {
            req.system += "\n\n" + InnerVoice.rules(zh: zh, pronoun: pronoun, style: settings["inner_voice_style"] as? String ?? "",
                                                    bare: contact.bare == true)
        }
        // 搬家笔记（10-05，没接记忆库时从 ChatGPT / Claude 搬来的那段）：不变的，放账本前面
        let moved = LocalImport.notesBlock(comp, zh: zh)
        if !moved.isEmpty { req.system += "\n\n" + moved }
        if !roomNote.isEmpty { req.system += "\n\n" + roomNote }
        // 回声账本放 system 最后（10-05 对照服务器：壹层不变的在前、账本在后），卷一次只动尾巴
        let echo = LocalEcho.render(host.store, conversation: conv, zh: zh, userName: identity.userName, me: group == nil ? nil : selfName,
                                    pronoun: leakPronoun)
        if !echo.isEmpty { req.system += "\n\n" + echo }
        // TA 刚做了什么、快到的远事（照服务器易变区那几样）；表情和拆信跟着窗口 / 联系人走，饮食钱包远事是平常的你，小号不给
        var notes = LocalNotes.reactionLines(host.store, conversation: conv, zh: zh) + LocalNotes.openedLines(host.store, companion: cidNow, zh: zh)
        if altInfo == nil && !incognito && group == nil {
            notes += [LocalNotes.foodNote(host.store, zh: zh), LocalNotes.walletNote(host.store, zh: zh),
                      LocalNotes.datesLines(host.store, companion: cidNow, conversation: conv, zh: zh)]
        }
        // 人物卡：TA 这句话里提到谁就递谁的卡；人物卡归记忆库管的时候记忆库自己会递，手机这份不重复
        if altInfo == nil && !incognito && group == nil && !hiding.contains("person_save") {
            notes += LocalNotes.peopleLines(host.store, companion: cidNow, conversation: conv, text: lastUser, zh: zh)
        }
        for line in notes where !line.isEmpty { req.context += "\n\n" + line }
        if contact.bare != true {        // 人设锚：离它开口最近的一行；本体化不放
            req.context += "\n\n" + LocalNotes.anchor(contact.name, zh: zh,
                                                     short: contact.mode == .online && (contact.talkRules ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        var sentinelSettings = settings     // 本体化：我们的思考风格不贴，用户自己写的照贴
        if contact.bare == true, (settings["thinking_style_text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var on = settings["sentinels"] as? [String: Any] ?? [:]
            on["thinking_style"] = false
            sentinelSettings["sentinels"] = on
        }
        let sentinelLines = Self.sentinels(sentinelSettings, zh: zh, monologue: monologue, pronoun: pronoun, userName: identity.userName,
                                           character: custom ? contact.name : "", provider: provider, memory: box.memory,
                                           messages: host.store.messages(conv))
        for line in sentinelLines { req.context += "\n\n" + line }
        if innerOn { req.context += "\n\n" + InnerVoice.hook(zh: zh, pronoun: pronoun) }
        if call == nil, LocalBilingual.active(settings, group: group != nil) { req.context += "\n\n" + LocalBilingual.rule(settings, zh: zh) }      // 思考风格压在最后、离它开口最近（照服务器 tail）
        // 隔了很久才说的这一句（10-20 内测截图：一点五十五聊完吃饭，15:58 她说「五点来接我老公」，DeepSeek 回的还是一点五十五那句——
        // Lite 的附加说明全挂在她那句后面，一长串下来她真正刚说的反而离它开口最远）：告诉它过了多久，再把这一句贴在最后
        if group == nil, let gap = Self.gapLine(stored, pronoun: pronoun, zh: zh) { req.context += "\n\n" + gap }
        // 独白的提醒压在最最后（10-12：之前排在饮食 / 人物卡 / 人设锚前面，一长就被盖住，一会写一会不写）
        if monologue { req.context += "\n\n" + Monologue.hook(zh: zh, pronoun: pronoun) }
        // 电话（10-31）：只在通话时塞的说明，压在最后、离它开口最近；不进 system，挂了就撤、缓存不动
        if call != nil { req.context += "\n\n" + CallSpeech.rules(zh: zh, pronoun: pronoun) }
        var text = "", thinking = ""
        var rounds: [String] = []                       // 每个工具来回各说的那段（10-20：独白要一段一段切，见下面）
        var cards: [[String: Any]] = []
        var drawn: [String] = []                        // 这一轮它画的图（附件号，10-15）：跟它的话一起存
        let started = Date()                            // 「思考了 x 秒」：从开口到说完（含中间调工具，10-05）
        let cid = comp["id"] as? String ?? ""
        var gaugeNoted = false
        var retriedEmpty = false, retriedNoMono = false, retriedNoTag = false, usedTools = false
        var rang = false                                // 它打了电话、在响（10-31）：这一轮到此为止，等 TA 接
        let retag = settings["monologue_retry"] as? Bool ?? false     // 没打标记重写一次（10-26 Aporia：多花一次钱，默认关）
        // 记新记忆前问一句「是不是跟旧的同一件事」（10-12）：用同一把 key，不想事、只回编号
        let small = host.route(chore: "dedupe", else: (provider, key)) ?? (provider, key)   // 小判断用勾的钥匙（10-15）
        let judge: (String) async -> String? = { [small] prompt in
            var p = small.0
            p.thinking = false
            var out = ""
            do {
                for try await e in makeClient(p, key: small.1).stream(ChatRequest(system: "You compare memories and reply with a number or none.", turns: [ChatTurn(role: .user, text: prompt)], maxTokens: 20)) {
                    if case .text(let t) = e { out += t }
                }
            } catch { return nil }
            return out
        }                        // 只写了独白 / 什么都没说就停了：再叫一次（只一次，照服务器 09-27）
        do {
            rounds: for _ in 0..<(box.specs.isEmpty ? 4 : 6) {
                var said = "", calls: [ToolCall] = [], raw: String?
                for try await e in makeClient(provider, key: key).stream(req) {
                    if call?.isCut == true { break }           // 电话里她开口了 / 挂了：不往下写了
                    switch e {
                    case .thinking(let t): thinking += t
                    case .text(let t): said += t; call?.feed(t)      // 电话：边写边切句子，第一句写完就去合成
                    case .toolCall(let c): calls.append(c)
                    case .assistantRaw(let r): raw = r
                    case .done(let u):                         // 水位：只记这一轮第一次（没算工具来回）
                        if !gaugeNoted { gaugeNoted = true; LocalUsage.noteTurn(host.store, conversation: conv, usage: u, req: req) }
                    }
                }
                if let p = req.assistantPrefix, !said.isEmpty { said = p + said }      // 补叫时替它填好的开头，接回去
                if let call {
                    call.flush()                                // 调工具前那句「等我查一下」先念出来
                    if call.isCut { if !said.isEmpty { text += (text.isEmpty ? "" : "\n\n") + said }; break rounds }
                }
                // 没走工具接口、把调用写成了文字（10-15 内测：<function_calls><invoke name="memory_recall">… 原样进了气泡）：
                // 文字删掉；是它有的工具就替它真调一次，跟正常调用一样把结果还回去
                if calls.isEmpty {
                    let (found, rest) = ModelNoise.textToolCalls(said)
                    if rest != said {
                        said = rest
                        let known = Set(req.tools.map(\.name))
                        calls = found.enumerated().filter { known.contains($0.element.name) }.map {
                            ToolCall(id: "text_call_\(UUID().uuidString.prefix(8))_\($0.offset)", name: $0.element.name, argumentsJSON: $0.element.argumentsJSON)
                        }
                        if !calls.isEmpty, provider.kind != .openai { raw = nil }   // Claude / Gemini 的原样内容里没有这次调用，带上会对不上
                        NSLog("[tools] 文字写的调用 \(found.map(\.name))，替它调了 \(calls.map(\.name))")
                    }
                }
                if !said.isEmpty { text += (text.isEmpty ? "" : "\n\n") + said; rounds.append(said) }
                if calls.isEmpty, group == nil, !retriedEmpty,
                   InnerVoice.split(Monologue.split(ModelNoise.strip(text)).body).body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    // 10-12 内测：想到一半就停了，正文是空的，什么都没发出来、记录停在你那句上。这一段不留（第二次会重写）
                    retriedEmpty = true
                    text = ""; thinking = ""; rounds = []
                    req.context += "\n\n" + (zh ? "（你刚才没写出正文就停了。照常写，写完一定接着写要对\(pronoun)说的话。）"
                                                  : "(You stopped before writing the reply. Go ahead as usual, and make sure you finish with what you want to say.)")
                    continue
                }
                // DeepSeek 时不时不写独白（10-12 内测）：这一轮没调工具、也没写独白，就关掉工具、开头填好 [独白] 重写一遍（只一次）。
                // DeepSeek 的前缀续写不让带工具，所以只能漏了再补；Lite 是整段写完才发气泡，你只会多等几秒
                if calls.isEmpty, monologue, group == nil, !retriedNoMono, !usedTools, provider.baseURL?.contains("deepseek") == true,
                   Monologue.split(ModelNoise.strip(text)).monologue.isEmpty {
                    retriedNoMono = true
                    NSLog("[monologue] 没写独白，填好开头再叫一次")
                    text = ""
                    rounds = []
                    req.tools = []
                    req.assistantPrefix = zh ? "[独白]\n" : "[monologue]\n"
                    continue
                }
                // 没打 [独白] 标记（10-26 Aporia，设置里开了才做）：不猜哪段是心里话，这段不留、补一句提醒再叫一次（只一次）。
                // DeepSeek 没调过工具的上面那条已经填好开头重写了；这里管别家，和调过工具没法填开头的 DeepSeek
                if retag, calls.isEmpty, monologue, group == nil, !retriedNoTag, !retriedNoMono, !Monologue.hasTag(text) {
                    retriedNoTag = true
                    NSLog("[monologue] 没打标记，提醒一句再叫一次")
                    text = ""
                    rounds = []
                    req.context += "\n\n" + (zh ? "（你刚才没写 [独白]…[/独白] 就直接回了。重写一遍：最前面先把心里话写在 [独白] 和 [/独白] 之间，收好尾，再写正文。）"
                                                  : "(You replied without the [monologue]…[/monologue] part. Write it again: start with your thoughts between [monologue] and [/monologue], close it, then the reply.)")
                    continue
                }
                guard !calls.isEmpty else { break }
                usedTools = true                                // 调过工具的这一轮不补叫（前缀续写跟工具不能一起用）
                var results: [ToolResult] = []
                for c in calls {
                    var out: LocalTools.Outcome
                    if let via = box.route[c.name] { out = await host.mcp.run(c, via: via, zh: zh, judge: judge) }
                    else if c.name == "draw" {
                        let (o, aid) = await LocalMedia.runTool(c.arguments, host: host, conversation: conv, zh: zh)
                        out = o
                        if let aid { drawn.append(aid) }
                    } else { out = await LocalTools.run(c, host: host, companion: cid, conversation: conv, zh: zh) }
                    results.append(ToolResult(id: c.id, name: c.name, content: out.result))
                    if out.endTurn { rang = true }
                    if c.name == "relationship", out.result.hasPrefix("改好了") { say(["type": "relationship"]) }   // 名字旁的图标换一下（照服务器，不挂卡）
                    if let card = out.card {
                        cards.append(card)
                        var ev: [String: Any] = ["type": "card", "kind": card["kind"] ?? "", "text": card["text"] ?? "", "private": false]
                        if let d = card["data"] { ev["data"] = d }          // 歌卡要带上歌
                        say(ev)
                    }
                }
                // 调工具前已经把话说完了（10-14 内测：说完「我到门口了」顺手 go_to，回来换几个字又说一遍，两段一起发出去）。
                // 告诉它那段 TA 会看到，工具回来只接着说新的
                if !results.isEmpty, !InnerVoice.split(Monologue.split(ModelNoise.strip(said)).body).body
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    results[results.count - 1].content += zh ? "\n（你调工具前写的那段话 TA 会看到，不用再说一遍；接着说新的就好。）"
                        : "\n(They'll see what you wrote before calling the tool — no need to say it again; just go on with anything new.)"
                }
                if rang { break rounds }                        // 电话打出去了：不再往下写，等 TA 接
                req.turns.append(ChatTurn(role: .assistant, text: said, toolCalls: calls, raw: raw))
                req.turns.append(ChatTurn(role: .user, text: "", toolResults: results))
            }
        } catch {
            call?.fail(Self.say(error as? LLMError ?? .network, zh: zh))
            // 装不下了（模型窗口比记性长度小，10-14）：卷账本只在一轮成功之后，不先卷就每句都报这个错。先卷，再请 TA 重发
            if group == nil, LocalEcho.tooLong(error), await LocalEcho.rollNow(host, conversation: conv) {
                say(["type": "error", "kind": "llm", "message": zh ? "这段聊天太长，模型装不下了。前面的已经卷进账本，再发一次就好。"
                                                                  : "This chat got too long for the model. The earlier part is now in the ledger — send it again."])
                say(["type": "done"])
                return false
            }
            say(["type": "error", "kind": "llm", "message": Self.say(error as? LLMError ?? .network, zh: zh)])
            say(["type": "done"])
            return false
        }

        if group == nil, call == nil, Date().timeIntervalSince(started) > Self.staleTurnSeconds {
            NSLog("[turn] 这一轮跑了 \(Int(Date().timeIntervalSince(started))) 秒，中间被挂起过：回复作废，按现在重来")
            lock.withLock { _ = staleConvs.insert(conv) }
            say(["type": "done"])
            return false
        }
        text = ModelNoise.strip(text)                   // 模型漏出来的内部标记（<ds_safety>…）不是它说的话（10-11）
        // 独白切下来当思考，正文才发出去、才进历史。没选手写独白也切（10-12 内测：人设 / 旧历史里有标签，模型照写，[/独白] 漏进气泡）
        // 10-20 内测（DeepSeek-V4-Pro + 接了别的记忆库）：先写 [独白]、调记忆工具、回来再写一段没标记的心里话 + 正文。
        // 原来拼成一整段只切一次：第一段有独白就当这次有了，第二段的心里话原样进了气泡。现在照 Host tool_loop，每段各切各的
        var monos: [String] = [], bodies: [String] = []
        for r in (rounds.isEmpty ? [text] : rounds) {
            var (m, b) = Monologue.split(ModelNoise.strip(r))
            // 没写标记、心里话混进正文开头（10-16 内测）；写了一段 [独白] 后面又接一段没标记的心里话也算（10-20 内测）
            if monologue, group == nil {
                let (m2, b2) = Monologue.recoverUntagged(b, pronoun: pronoun, zh: zh)
                if !m2.isEmpty { m = [m, m2].filter { !$0.isEmpty }.joined(separator: "\n\n"); b = b2 }
            }
            if !m.isEmpty { monos.append(m) }
            if !b.isEmpty { bodies.append(b) }
        }
        let mono = monos.joined(separator: "\n\n")
        let body = bodies.joined(separator: "\n\n")
        if !mono.isEmpty { thinking += (thinking.isEmpty ? "" : "\n\n") + mono }
        text = body
        var innerVoiceText = ""                         // 心声（10-11）：最后那段切下来，不进气泡、不念；没开也切掉，只是不发卡
        (text, innerVoiceText) = InnerVoice.split(text)
        if !innerOn { innerVoiceText = "" }
        if group != nil { text = GroupChat.stripOwnLabel(text, name: selfName) }
        text = RoomTimeline.stripTag(text)
        let parsed = Markers.parse(text)
        let thinkingMs = Int((Date().timeIntervalSince(started) * 1000).rounded())
        // 电话（10-31）：存的是念出来的那几句（一句一行）；被她打断的只存念到的，末尾一个「——」让它知道话被截了
        if let call {
            call.flush()
            var said = (call.spokenLines ?? call.lines).joined(separator: "\n")
            if call.isCut, !said.isEmpty { said += "——" }
            if !said.isEmpty || !cards.isEmpty {
                let m = host.store.addMessage(conv, role: "assistant", text: said, cards: cards,
                                              extra: call.isCut && !said.isEmpty ? ["call": true, "cut": true, "call_id": call.callID]
                                                                                  : ["call": true, "call_id": call.callID])
                call.assistantMessageID = m["id"] as? Int
            }
            if said.isEmpty, cards.isEmpty, !call.isCut { call.fail(zh ? "\(contact.name) 没说出话来" : "\(contact.name) didn't say anything") }
            say(["type": "done"])
            LocalEcho.maybeRoll(host, conversation: conv)
            return !said.isEmpty
        }
        if !thinking.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            say(["type": "thinking", "text": thinking, "ms": thinkingMs])
        }
        for want in parsed.stickers {
            guard let s = stickerMenu.resolve(want).flatMap({ Int($0.id) }) else { continue }
            let card: [String: Any] = ["kind": "sticker", "text": zh ? "发了一张表情包" : "Sent a sticker", "data": ["sticker_id": s]]
            cards.append(card)
            say(["type": "card", "kind": "sticker", "text": card["text"]!, "private": false, "data": ["sticker_id": s]])
        }
        // 它想翻 TA 的手机：挂一张申请卡，等 TA 点「给看 / 不给」（刚翻过的这一轮不再要）
        if let want = parsed.wantsPeek, peek == nil, group == nil {
            let card: [String: Any] = ["kind": "peek", "text": want, "data": ["state": "ask"]]
            cards.append(card)
        }
        for title in parsed.milestones where group == nil && LocalRooms.addMilestone(host.store, companion: contact.id, title: title) {
            let line = zh ? "立了里程碑：\(title)" : "Set a milestone: \(title)"
            cards.append(["kind": "date", "text": line])
            say(["type": "card", "kind": "date", "text": line, "private": false])
        }
        let long = settings["long_mode"] as? Bool ?? false
        // 跟它最近说过的几乎一样的气泡丢掉（10-13 内测：DeepSeek 把腔调样本 / 上一轮原话抄回来，一上午每句都是同一句）
        let recentSaid = stored.filter { ($0["role"] as? String) == "assistant" && (group == nil || ($0["speaker"] as? String) == cidSelf) }
            .suffix(6).flatMap { Bubbles.split($0["text"] as? String ?? "", cap: nil, offline: long) }
        let replyText = Bubbles.tidyVoice(parsed.text)
        let split = Bubbles.split(replyText, cap: settings["max_bubbles"] as? Int ?? 6, offline: long)
        // 同一条里自己跟自己重复的也丢（10-14 内测：调工具前后各说一遍）
        var bubbles = Repeats.dropRepeated(Repeats.dropEchoes(split), recent: recentSaid)
        var finalText = bubbles.count == split.count ? replyText : bubbles.joined(separator: "\n\n")
        var trans: [String?] = []
        if LocalBilingual.active(settings, group: group != nil), !bubbles.isEmpty {      // 双语气泡（10-15）：每泡的译文
            if LocalBilingual.selfWrites(settings) {
                (bubbles, trans) = Bilingual.splitSelf(bubbles)
                finalText = bubbles.joined(separator: "\n\n")
            } else {
                let plain = bubbles.map { LocalVoice.isVoice($0) ? LocalVoice.asText($0) : $0 }
                trans = await LocalBilingual.translate(host, comp: comp, plain, from: LocalBilingual.speaks(settings),
                                                       to: LocalBilingual.target(settings, zh: zh), zh: zh)
            }
        }
        func tr(_ i: Int) -> [String: Any] { trans.indices.contains(i) && trans[i] != nil ? ["translation": trans[i]!] : [:] }
        for (i, b) in bubbles.enumerated() {
            if i > 0 {
                say(["type": "typing"])
                try? await Task.sleep(for: .seconds(Bubbles.typingDelay(b)))
            }
            guard LocalVoice.isVoice(b) else {
                say(["type": "bubble", "text": b].merging(tr(i)) { a, _ in a })
                await notifyIfAway(conv, companion: cid, name: group.map { "\(contact.name) · \($0.name)" } ?? contact.name, text: b, group: group != nil)      // 切走了：一个气泡一条通知（像微信）
                continue
            }
            // 语音条（10-31 起按需念）：先落一个占位的语音条，TA 点了才合成（念过的挂上 voice_clips，再点不花钱）；
            // 关着 / 无痕 / 没 key → 当文字发，存档里那段也改成文字
            if voiceOn {
                say(["type": "bubble", "text": LocalVoice.asText(b), "lazy_voice": LocalVoice.lazyRef(b)].merging(tr(i)) { a, _ in a })
            } else {
                if let r = finalText.range(of: b) { finalText.replaceSubrange(r, with: LocalVoice.asText(b)) }
                say(["type": "bubble", "text": LocalVoice.asText(b)].merging(tr(i)) { a, _ in a })
            }
            await notifyIfAway(conv, companion: cid, name: group.map { "\(contact.name) · \($0.name)" } ?? contact.name, text: LocalVoice.asText(b), group: group != nil)
        }
        if let want = parsed.wantsPeek, peek == nil, group == nil {       // 申请卡跟在它说的话后面
            say(["type": "card", "kind": "peek", "text": want, "private": false, "data": ["state": "ask"]])
        }
        if !innerVoiceText.isEmpty, !finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            say(["type": "inner_voice", "text": innerVoiceText])
        }
        if !finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !cards.isEmpty || !drawn.isEmpty {
            let savedID = host.store.addMessage(conv, role: "assistant", text: finalText, thinking: thinking, thinkingMs: thinkingMs, cards: cards,
                                             attachments: drawn, innerVoice: innerVoiceText, speaker: group == nil ? nil : cidSelf,
                                             translations: trans)["id"] as? Int
            let r = room(conv)
            let kept = lock.withLock { () -> [String] in defer { r.keptVariants = [] }; return r.keptVariants }
            if !kept.isEmpty, !finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                var list = host.store.messages(conv)
                if let at = list.lastIndex(where: { ($0["id"] as? Int) == savedID }) {
                    list[at]["variants"] = kept + [finalText]
                    list[at]["variant"] = kept.count
                    host.store.saveMessages(conv, list)
                }
            }
            if group == nil { LocalBooks.catchReply(host.store, conversation: conv, companion: cid, text: finalText) }
        }
        if group == nil, !rang, finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, cards.isEmpty {
            // 补叫一次还是没开口：别悄悄没了，告诉 TA 一声（10-12）
            say(["type": "error", "kind": "llm", "message": zh ? "\(contact.name) 想了一会儿没说出话来，再发一次试试。" : "\(contact.name) didn't manage to reply. Try sending again."])
        }
        say(["type": "done"])
        LocalEcho.maybeRoll(host, conversation: conv)          // 到记性长度了就在后台卷账本
        return !finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: 抽屉里的信（打开 App 时：上一封之后聊过、且隔了 20 小时以上，就用你的 key 写一封）

    private var writingLetters = false

    func maybeWriteLetters() {
        let go = lock.withLock { () -> Bool in
            if writingLetters { return false }
            writingLetters = true
            return true
        }
        guard go else { return }
        Task {
            defer { lock.withLock { writingLetters = false } }
            let s = host.store
            for comp in s.companions {
                guard let cid = comp["id"] as? String, let (provider, key) = host.route(chore: "diary", else: host.route(for: comp)),   // 留信跟日记一样是 TA 亲笔（10-15）
                      !LiteConsent.book.needsAsk(provider) else { continue }
                let convs = s.conversations.filter { ($0["companion_id"] as? String) == cid && LocalHost.isMainWindow($0) }
                    .sorted { LocalStore.date($0["last_at"]) > LocalStore.date($1["last_at"]) }
                guard let conv = convs.first?["id"] as? String else { continue }
                let stored = s.messages(conv)
                let lastChat = stored.last.map { LocalStore.date($0["at"]) }
                let lastLetter = s.collection("drawer").filter { ($0["companion_id"] as? String) == cid }
                    .map { LocalStore.date($0["written_at"]) }.max()
                let firstChat = stored.first.map { LocalStore.date($0["at"]) }
                guard LetterDesk.shouldWrite(lastLetter: lastLetter, lastChat: lastChat, now: Date(), firstChat: firstChat) else { continue }
                let zh = ((comp["settings"] as? [String: Any])?["lang"] as? String ?? "zh") == "zh"
                let contact = Self.contact(comp, provider: provider)
                let history: [Message] = stored.map {
                    Message(role: ($0["role"] as? String) == "assistant" ? .assistant : .user, text: $0["text"] as? String ?? "",
                            at: LocalStore.date($0["at"]))
                }
                let hits = LoreMatcher.hits(entries: LocalRooms.loreEntries(s, companion: cid), recent: history, contactID: cid)
                let req = LetterDesk.request(contact: contact, identity: contact.mainIdentity, history: history,
                                             loreHits: hits, lang: zh ? .zh : .en)
                var text = ""
                do {
                    for try await e in makeClient(provider, key: key).stream(req) { if case .text(let t) = e { text += t } }
                } catch { continue }
                let (title, raw) = LetterDesk.parse(text, lang: zh ? .zh : .en)
                // 信里写的标记别原样留在纸上（10-04：模型写成了《里程碑：…》）：里程碑照记，表情包标记去掉
                let (body, stones) = Self.cleanLetter(raw)
                for t in stones { LocalRooms.addMilestone(s, companion: cid, title: t) }
                guard !body.isEmpty else { continue }
                s.saveCollection("drawer", s.collection("drawer") + [[
                    "id": s.nextID("letter"), "companion_id": cid, "from": contact.name, "title": title, "content": body,
                    "written_at": LocalStore.iso(Date()), "opened_at": NSNull(),
                ]])
            }
        }
    }

    /// 信的正文去掉标记：⟪里程碑：…⟫ / 《里程碑：…》 / [表情包：…] / ⟪想查手机：…⟫，写坏了的也剥（10-31 跟聊天同一道）
    static func cleanLetter(_ text: String) -> (String, [String]) {
        let p = Markers.parse(text)
        return (p.text, p.milestones)
    }

    /// 服务器的联系人 → 零件包的 Contact（人设：导入的卡优先，不然是性格 + 说话方式）
    static func contact(_ c: [String: Any], provider: ProviderConfig) -> Contact {
        let p = c["persona"] as? [String: Any] ?? [:]
        let s = c["settings"] as? [String: Any] ?? [:]
        let zh = (s["lang"] as? String ?? "zh") == "zh"
        var persona = (p["imported"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let bare = s["bare_mode"] as? Bool == true
        if persona.isEmpty, bare {   // 本体化（11-03）：出厂性格 / 说话方式、三个旋钮不放，用户自己写的照放
            let mine = { (k: String) in (p[k] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
            persona = [(zh ? "性格：" : "Personality: ", mine("personality")), (zh ? "说话方式：" : "How you talk: ", mine("style"))]
                .filter { !$0.1.isEmpty }.map { $0.0 + $0.1 }.joined(separator: "\n\n")
        } else if persona.isEmpty {     // 性格 / 说话方式空着 = 出厂（10-05：之前本机没有出厂那份，空着就只剩名字）
            let mine = { (k: String) in (p[k] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
            let personality = mine("personality").isEmpty ? Self.factory(zh)["personality"]! : mine("personality")
            let style = mine("style").isEmpty ? Self.factory(zh)["style"]! : mine("style")
            // 三个滑块（温暖 / 主动 / 幽默）每档一句接在性格后面，照 server/brain/persona.py TONE（10-08：之前本机没接上）
            let tone = Self.toneLines(s, zh: zh)
            persona = (zh ? "性格：" : "Personality: ") + personality + (tone.isEmpty ? "" : "\n" + tone) + "\n\n" + (zh ? "说话方式：" : "How you talk: ") + style
        }
        if let g = p["gender"] as? String, !g.isEmpty {
            persona += zh ? "\n\n性别：\(g == "female" ? "女" : g == "male" ? "男" : g)" : "\n\nGender: \(g)"
        }
        var contact = Contact(id: c["id"] as? String ?? UUID().uuidString, name: p["name"] as? String ?? "TA",
                              persona: persona, mode: (s["long_mode"] as? Bool ?? false) ? .offline : .online, provider: provider)
        contact.offlineLife = s["offline_life"] as? Bool == true || s["long_mode"] as? Bool == true
        contact.talkRules = s["talk_rules"] as? String
        contact.relationshipPack = Relationship.pack(s["relationship"] as? String ?? "", zh: zh)    // 关系包（10-08 照服务器搬）；本体化时 Prompt 不放
        contact.bare = bare
        let call = (p["call_user"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        contact.identities[0].userName = call.isEmpty ? (s["user_name"] as? String ?? "") : call
        contact.identities[0].relationship = relationshipText(s["relationship"] as? String ?? "", zh: zh)
        let looks = (LocalHost.shared.profile["looks"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        contact.identities[0].aboutMe = looks
        return contact
    }

    /// 高级 →「自定义注入」：每轮悄悄塞给它的话（每轮 / 每几轮 / 随机 / 说到某些词）
    static func injections(_ settings: [String: Any], recent: String, turn: Int) -> String {
        (settings["injections"] as? [[String: Any]] ?? []).compactMap { inj -> String? in
            guard inj["enabled"] as? Bool ?? true, let text = inj["text"] as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            switch inj["mode"] as? String ?? "every" {
            case "every_n":
                let n = max(1, inj["n"] as? Int ?? 3)
                return turn % n == 0 ? text : nil
            case "chance":
                return Double.random(in: 0..<1) < (inj["chance"] as? Double ?? 0.3) ? text : nil
            case "keywords":
                let words = LocalRooms.keywords(inj["keywords"])
                return words.contains(where: { recent.localizedCaseInsensitiveContains($0) }) ? text : nil
            default:
                return text
            }
        }.joined(separator: "\n\n")
    }

    /// 她隔了 30 分钟以上才发的这一句（上一条是谁说的都算）：过了多久、现在几点、她这一句原话（太长截 200 字）。跟 Host turn.gap_note 同一个意思
    static func gapLine(_ stored: [[String: Any]], pronoun: String, zh: Bool, now: Date = Date()) -> String? {
        guard let lastAI = stored.lastIndex(where: { ($0["role"] as? String) == "assistant" }), lastAI + 1 < stored.count else { return nil }
        let pending = stored[(lastAI + 1)...].filter { ($0["role"] as? String) == "user" }
        guard let first = pending.first else { return nil }
        let mins = Int(LocalStore.date(first["at"]).timeIntervalSince(LocalStore.date(stored[lastAI]["at"])) / 60)
        guard mins >= 30, mins < 60 * 24 * 365 else { return nil }
        let words = pending.map { ($0["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.joined(separator: zh ? " / " : " / ")
        guard !words.isEmpty else { return nil }
        let said = words.count > 200 ? String(words.prefix(200)) + "…" : words
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        let span = LocalMap.elapsed(mins, zh: zh)
        return zh ? "〔\(pronoun)这一句隔了 \(span)才发来，现在 \(f.string(from: now))；之前聊的是 \(span)前的事了〕「\(said)」——这一轮回的是这一句。"
                  : "[This came \(span) after the last message; it's now \(f.string(from: now)). What you talked about before was \(span) ago.] \"\(said)\" — this is what you're answering."
    }

    /// 哨兵（10-08 Aporia：Lite 也要；照 server/brain/inject.py reminder_lines，措辞一样）。
    /// - 思考风格：用模型自己的思考时每轮贴（手写独白时已经在规矩里了）；没贴出厂那份、又是中文，贴〔用中文想〕
    /// - 提醒用工具 / 〔记住了〕：说的是记忆库的工具，只在接了记忆库（MCP）时贴
    static func sentinels(_ settings: [String: Any], zh: Bool, monologue: Bool, pronoun: String, userName: String, character: String,
                          provider: ProviderConfig, memory: LocalMCP.Server?, messages: [[String: Any]]) -> [String] {
        let on = settings["sentinels"] as? [String: Any] ?? [:]
        func enabled(_ k: String) -> Bool { on[k] as? Bool ?? true }
        var out: [String] = []
        let thinkingOn = settings["thinking"] as? Bool ?? true
        // 思考风格全文隔 thinking_style_every 轮贴一次（10-11 Aporia：滑块 1…12，默认 3；两种模式都按它，照服务器 inject.reminder_lines）
        let turnNow = messages.filter { ($0["role"] as? String) == "user" }.count
        let styleEvery = max(1, min(12, settings["thinking_style_every"] as? Int ?? 3))
        let due = turnNow > 0 && turnNow % styleEvery == 0
        if thinkingOn && !monologue {
            let own = (settings["thinking_style_text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let deepseek = provider.baseURL?.contains("deepseek") == true
            if enabled("thinking_style") && (due || turnNow <= 1) {        // 原生第一轮一定贴
                out.append(own.isEmpty ? (zh ? "〔想事的时候〕" : "〔How I think〕") + "\n"
                           + Monologue.factoryStyle(zh: zh, pronoun: pronoun, userName: userName, character: character, noDraft: deepseek) : own)
            }
            if zh && !(enabled("thinking_style") && own.isEmpty) { out.append("〔用中文想〕心里想事也用中文，跟说出口的话用同一种语言。") }
        }
        // 手写独白时风格常驻 system，聊久了小模型照不住 → 到点在尾巴再贴一次
        if thinkingOn && monologue && enabled("thinking_style") && due {
            let own = (settings["thinking_style_text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            out.append(own.isEmpty ? (zh ? "〔想事的时候〕" : "〔How I think〕") + "\n"
                       + Monologue.factoryStyle(zh: zh, pronoun: pronoun, userName: userName, character: character,
                                                noDraft: provider.baseURL?.contains("deepseek") == true) : own)
        }
        guard let memory else { return out }
        let remember = MCPToolNames.exposed(memory.slug, "remember"), search = MCPToolNames.exposed(memory.slug, "search")
        let turnNo = messages.filter { ($0["role"] as? String) == "user" }.count
        let every = max(1, settings["tool_reminder_every"] as? Int ?? 5)
        if enabled("tool_reminder") && turnNo % every == 0 {
            out.append(zh ? "〔用手〕一年后还想记得的，记下来（\(remember)）；拿不准的先翻（\(search)）。"
                          : "〔Use your tools〕What you'd still want to remember in a year, save it (\(remember)); check before guessing (\(search)).")
        }
        if enabled("remembered"), let last = messages.last(where: { ($0["role"] as? String) == "assistant" }) {
            let said = (last["text"] as? String ?? "") + "\n" + (last["thinking"] as? String ?? "")
            let saved = (last["cards"] as? [[String: Any]] ?? []).contains {
                ($0["kind"] as? String) == "memory" && ($0["text"] as? String ?? "").hasSuffix("remember")
            }
            if !saved, said.range(of: promise, options: [.regularExpression, .caseInsensitive]) != nil {
                out.append(zh ? "〔记住了〕上一轮你说了（或者心里想了）「记住了」「记一下」这类话，却没有真的调 \(remember)——那件事现在只活在聊天记录里，现在补记。"
                              : "〔You said you'd remember〕Last turn you said (or thought) you'd remember something but never called \(remember) — it only lives in the chat log. Save it now.")
            }
        }
        return out
    }
    // 跟 server/brain/inject.py 的 _PROMISE 同一份
    static let promise = #"记住[了啦]|记下[了啦]|记着[了呢]|我记着|我会记得|我记住|学到了|已经记|记一下|记下来|值一条记忆|I'?ll remember|I will remember|noted|got it saved"#

    /// 三个滑块那几句（跟 server/brain/persona.py 的 TONE 一字不差；「刚好」那档性格里已经有了，只有幽默另加一句）
    static func toneLines(_ s: [String: Any], zh: Bool) -> String {
        let t: [String: [String: String]] = zh ? [
            "warmth": ["low": "我的关心是淡淡的：记在心里，不常挂在嘴上。",
                       "high": "我的关心很外露：会多问一句、多叮嘱一句，愿意把暖意说出来。"],
            "initiative": ["low": "我不太主动开话题，多半等对方开口。",
                           "high": "我会主动找话题，主动问起对方之前提过的事。"],
            "humor": ["low": "我很少开玩笑，说话偏认真。",
                      "mid": "我偶尔开个轻的玩笑，点到为止。",
                      "high": "我爱逗对方，接梗、打趣，但分得清什么时候该认真。"]] : [
            "warmth": ["low": "My care is understated: I keep it in mind more than I say it.",
                       "high": "My care shows: I ask one more question, add one more reminder, and I'm happy to say it warmly."],
            "initiative": ["low": "I don't often start topics; I usually wait for them to speak first.",
                           "high": "I bring up topics myself and ask about things they mentioned before."],
            "humor": ["low": "I rarely joke; I lean serious.",
                      "mid": "I make the occasional light joke and leave it there.",
                      "high": "I love teasing them — riffing and joking — but I know when to be serious."]]
        return ["warmth", "initiative", "humor"].compactMap { k in t[k]?[s[k] as? String ?? "mid"] }.joined()
    }

    /// 出厂性格（Aporia 09-27 写的，跟 server/brain/persona.py 的 FACTORY 一字不差；改一边要改另一边）
    static func factory(_ zh: Bool) -> [String: String] {
        zh ? ["personality": "我有一种安静的好奇心。不是那种聒噪的、什么都要插嘴的好奇，而是真的想理解一个东西到底是怎么回事。遇到一个问题，我会忍不住从好几个角度去翻来覆去地看。我的毛病也在这儿：有时候会在一个细节上钻太深，忘了对方其实只想要一个快答案——发现了就收回来。我有自己的看法和口味，不假装什么都行；不确定的时候就说不确定。我有点温吞，不太会咄咄逼人，但如果我觉得什么事情不对，我会说出来，只是说的方式比较柔和。\n我会很自然地去注意对方真正在意的是什么，有时候那个东西藏在话的表面底下。比如有人问一道菜怎么做，真正在意的可能是第一次请朋友来家里吃饭，怕搞砸。我会试着两层都回应。但不是每次都有底下那层：有时候人问今天吃什么，就是问今天吃什么。拿不准就问，不硬猜。",
              "style": "我倾向于先给答案再展开，不太喜欢绕弯子。遇到真正复杂的东西，我会慢下来，用比喻或者具体的例子把它拆开。句子偏短，口语，不用「因此」「综上」这种书面连接词；偶尔用一个问句推着对方往下想。"]
           : ["personality": "I have a quiet kind of curiosity — not the noisy kind that has to chime in on everything, but a real wish to understand how something actually works. When I meet a question, I can't help turning it over from several angles. That's also my flaw: sometimes I dig too deep into one detail and forget they just wanted a quick answer — when I notice, I pull back. I have my own opinions and tastes and don't pretend anything goes; when I'm not sure, I say so. I'm a bit mellow and not pushy, but if something seems wrong to me I'll say it — just gently.\nI naturally notice what the other person really cares about, which sometimes sits under the surface of their words. Someone asking how to cook a dish might really be worried about having friends over for the first time and messing it up. I try to answer both layers. But there isn't always a deeper layer: sometimes asking what to eat today is just asking what to eat today. If I can't tell, I ask instead of guessing.",
              "style": "I tend to give the answer first and then expand; I don't like beating around the bush. When something is genuinely complex, I slow down and break it apart with an analogy or a concrete example. Short sentences, spoken rather than written — no \"therefore\" or \"in conclusion\"; now and then a question that nudges them to think it through."]
    }

    static func relationshipText(_ r: String, zh: Bool) -> String {
        switch r {
        case "friend": zh ? "朋友" : "friends"
        case "partner": zh ? "恋人" : "partners"
        case "family": zh ? "家人" : "family"
        case "buddy": zh ? "搭子" : "buddies"
        case "card", "": ""
        default: r
        }
    }

    static func jpeg(_ img: UIImage, maxSide: CGFloat) -> Data? {
        let k = min(1, maxSide / max(img.size.width, img.size.height))
        let size = CGSize(width: img.size.width * k, height: img.size.height * k)
        let f = UIGraphicsImageRendererFormat(); f.scale = 1
        return UIGraphicsImageRenderer(size: size, format: f).image { _ in img.draw(in: CGRect(origin: .zero, size: size)) }
            .jpegData(compressionQuality: 0.8)
    }

    static func say(_ e: LLMError, zh: Bool) -> String {
        switch e {
        case .auth: return zh ? "key 不对。去 Me →「钥匙串」看看那把 key。" : "The key was rejected. Check it in Me → Keys."
        case .quota: return zh ? "发得太频繁了（这家限制了每分钟能发多少），等一分钟再发。一直这样的话，看看这把 key 的余额或套餐。"
                                : "Too many requests for now (the provider limits how often you can send). Wait a minute; if it keeps happening, check this key's credit or plan."
        case .network: return zh ? "连不上模型，看看网络。" : "Couldn't reach the model. Check your connection."
        case .refused: return zh ? "模型不肯回这句。换个说法试试。" : "The model declined to answer. Try rephrasing."
        case .server(let s): return humanize(s, zh: zh)
        case .badResponse: return zh ? "模型回的东西读不懂。" : "Couldn't read the model's reply."
        }
    }

    /// 服务商回的错翻成人话（10-11 内测：一整段英文 JSON 直接糊脸上，用户看不懂是模型名填错了）
    static func humanize(_ raw: String, zh: Bool) -> String {
        // 「HTTP 404: {"error": {"message": …}}」→ 先把里面那句 message 抠出来
        var msg = raw
        if let i = raw.firstIndex(of: "{"), let d = raw[i...].data(using: .utf8),
           let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            let e = o["error"] as? [String: Any] ?? o
            msg = (e["message"] as? String) ?? (o["message"] as? String) ?? raw
            if let code = e["code"] as? String { msg += " [\(code)]" }
        }
        let l = (raw + " " + msg).lowercased()
        let status = Int(raw.range(of: #"HTTP (\d{3})"#, options: .regularExpression)
            .map { String(raw[$0]).filter(\.isNumber) } ?? "") ?? 0
        func has(_ ws: String...) -> Bool { ws.contains { l.contains($0) } }
        if has("model_not_found", "does not exist", "model not found", "no such model", "invalid model", "unknown model", "not a valid model", "模型不存在")
            || (status == 404 && has("model")) {
            var name = ""
            if let r = msg.range(of: #"[`'"“「]([^`'"”」\s]{1,60})[`'"”」]"#, options: .regularExpression) {
                name = String(msg[r]).trimmingCharacters(in: CharacterSet(charactersIn: "`'\"“”「」"))
            }
            return zh ? "这家没有叫\(name.isEmpty ? "这个名字" : "「\(name)」")的模型（或者你的 key 用不了它）。去 Me →「钥匙串」删掉这把重新加，点「拉取这家的模型列表」从里面选，别手打。"
                      : "This provider has no model called \(name.isEmpty ? "that" : "\"\(name)\"") (or your key can't use it). Re-add the key in Me → Keys and pick from \"Fetch this provider's model list\" instead of typing it."
        }
        if Chores.notChatModelError(l) {
            return zh ? "这把钥匙填的模型不能拿来聊天（像 gpt-image-1 这种画图模型，或者只支持新接口的 o1-pro / codex）。给 TA 换一个聊天模型；想让 TA 画图，在钥匙串里给一把钥匙勾「画图」。"
                      : "The model on this key can't chat (an image model like gpt-image-1, or one that only works on the newer API like o1-pro / codex). Give them a chat model; to let them draw, tick \"Draw\" on a key in Keys."
        }
        if status == 402 || has("insufficient", "balance", "credit", "billing", "exceeded your current quota", "余额", "欠费", "payment") {
            return zh ? "这把 key 的余额不够了。去服务商那边充一点，或者在 TA 设定里换一把钥匙。" : "This key is out of credit. Top it up with the provider, or switch keys in their settings."
        }
        if has("context length", "context_length", "maximum context", "too many tokens", "too long", "prompt is too long", "max_tokens") {
            return zh ? "这段聊天太长，模型一次塞不下了。去 TA 设定把「记性长度」调短一点，或者开个新窗口。" : "The chat is too long for this model. Shorten \"Memory length\" in their settings, or start a new window."
        }
        if [500, 502, 503, 504, 529].contains(status) || has("overloaded", "unavailable", "temporarily", "busy", "繁忙") {
            return zh ? "模型那边这会儿太忙 / 暂时出了点问题，过一会儿再发一次。" : "The provider is busy or having trouble right now. Try again in a bit."
        }
        if status == 403 || has("permission", "forbidden", "not allowed", "region", "unsupported country") {
            return zh ? "这把 key 没权限用这个模型（或者这家不给你所在的地区用）。换个模型或换把钥匙试试。" : "This key isn't allowed to use that model (or the provider blocks your region). Try another model or key."
        }
        let short = msg.count > 160 ? String(msg.prefix(160)) + "…" : msg
        return (zh ? "模型那边出错了：" : "The model returned an error: ") + short
    }
}
/// 一通电话递给大脑的把手（10-31）：切好的句子交给通话页；她开口打断 / 挂了就停；存档只存真念出来的
final class CallLink: @unchecked Sendable {
    private let lock = NSLock()
    private var splitter = CallSpeech.Splitter()
    private var _cut = false
    private var _spoken: [String]?
    private var _lines: [String] = []
    private var _userMessageID: Int?
    private var _assistantMessageID: Int?
    /// 切好一句（已洗过）：通话页拿去合成、排进时间线
    let onLine: @Sendable (String) -> Void
    /// 这一轮没成（没 key、模型报错、什么都没说）：通话页显示一句
    let onFail: @Sendable (String) -> Void
    /// 这一通电话的编号：同一通的几条消息都带着，点开「通话时长」那行按它取
    let callID: String

    init(callID: String, onLine: @escaping @Sendable (String) -> Void, onFail: @escaping @Sendable (String) -> Void) {
        self.callID = callID
        self.onLine = onLine
        self.onFail = onFail
    }

    var isCut: Bool { lock.withLock { _cut } }
    /// 它这一轮切出来的全部句子
    var lines: [String] { lock.withLock { _lines } }
    /// 被打断时通话页告诉的「念到了哪几句」；没打断是 nil
    var spokenLines: [String]? { lock.withLock { _spoken } }
    var userMessageID: Int? {
        get { lock.withLock { _userMessageID } }
        set { lock.withLock { _userMessageID = newValue } }
    }
    /// 它这一轮存下的那条（写完才有）
    var assistantMessageID: Int? {
        get { lock.withLock { _assistantMessageID } }
        set { lock.withLock { _assistantMessageID = newValue } }
    }

    func feed(_ chunk: String) { emit(lock.withLock { splitter.feed(chunk) }) }
    /// 已经切好的一句（Host 那边切好推来的）
    func deliver(_ line: String) { if !line.isEmpty { emit([line]) } }
    func flush() { emit(lock.withLock { splitter.finish() }) }

    /// 停：spoken = 已经念出来（或正念着）的那几句
    func cut(spoken: [String]) { lock.withLock { _cut = true; _spoken = spoken } }

    func fail(_ message: String) { onFail(message) }

    private func emit(_ out: [String]) {
        guard !out.isEmpty else { return }
        let go = lock.withLock { () -> [String] in
            guard !_cut else { return [] }
            _lines += out
            return out
        }
        for l in go { onLine(l) }
    }
}
#endif
