#if LITE
import BackgroundTasks
import Foundation

/// 切走以后接着回（11-13 内测：本机版发完就退出，收不到回复通知）。
/// 苹果平常只给切走的 App 大约 30 秒；iOS 26 起可以要一段「接着做完」的时间，代价是做的时候锁屏 / 灵动岛上挂一条进度。
/// 「Me → 切走以后」里开关，默认关（Aporia 11-13：进度条是苹果画的、有点丑；快模型靠「切走马上回」那 30 秒就够）。
enum KeepReplying {
    static let key = "lite.keepReplying"
    static var enabled: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? false }
    static var supported: Bool {
        if #available(iOS 26, *) { return true }
        return false
    }
}

/// 每个窗口一条进度：切走时这个窗口还有话没回完就要一条，这一轮回完（letGo）就收掉。
/// 苹果要求一直报进度，不报会被当成卡住收走：等你说完、它在想、每冒一个气泡都往前走一格。
@available(iOS 26, *)
final class ReplyContinuation: @unchecked Sendable {
    static let shared = ReplyContinuation()
    private static let prefix = "chat.mele.app.reply."     // Info.plist 里登记的是 chat.mele.app.reply.*
    private static let steps: Int64 = 10

    private struct Slot {
        let id: String
        var task: BGContinuedProcessingTask?
        var done = false
        var bubbles = 0
    }
    private let lock = NSLock()
    private var slots: [String: Slot] = [:]

    func start(_ conv: String, name: String) {
        guard KeepReplying.enabled else { return }
        let id = Self.prefix + UUID().uuidString.prefix(8)
        let fresh = lock.withLock { () -> Bool in
            if let s = slots[conv], !s.done { return false }      // 这个窗口已经挂着一条
            slots[conv] = Slot(id: id)
            return true
        }
        guard fresh else { return }
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: nil) { [weak self] t in
            guard let self, let task = t as? BGContinuedProcessingTask else { t.setTaskCompleted(success: false); return }
            task.progress.totalUnitCount = Self.steps
            let already = self.lock.withLock { () -> Bool in
                guard self.slots[conv]?.id == id, self.slots[conv]?.done == false else { return true }
                self.slots[conv]?.task = task
                return false
            }
            if already {                                           // 苹果排到它之前这一轮已经回完了
                task.progress.completedUnitCount = Self.steps
                task.setTaskCompleted(success: true)
                self.lock.withLock { if self.slots[conv]?.id == id { self.slots[conv] = nil } }
                return
            }
            task.progress.completedUnitCount = 1
            task.expirationHandler = { [weak self] in self?.finish(conv, success: false) }   // 苹果收回：回到 App 再接着回
        }
        guard registered else {
            NSLog("[keep] 登记失败（Info.plist 里没有 \(Self.prefix)*？）")
            lock.withLock { slots[conv] = nil }
            return
        }
        let req = BGContinuedProcessingTaskRequest(identifier: id, title: name,
                                                    subtitle: String(localized: "在回你的消息"))
        req.strategy = .fail            // 苹果这会儿排不上就算了，还有那 30 秒
        do {
            try BGTaskScheduler.shared.submit(req)
            NSLog("[keep] 要到了 \(id)")
        } catch {
            NSLog("[keep] 没要到：\(error)")
            lock.withLock { if slots[conv]?.id == id { slots[conv] = nil } }
        }
    }

    /// 这一轮又往前走了一步（事件流里的每个事件）
    func step(_ conv: String, _ type: String?) {
        let (task, bubbles) = lock.withLock { () -> (BGContinuedProcessingTask?, Int) in
            guard slots[conv] != nil else { return (nil, 0) }
            if type == "bubble" { slots[conv]?.bubbles += 1 }
            return (slots[conv]?.task, slots[conv]?.bubbles ?? 0)
        }
        guard let task else { return }
        let p = task.progress
        p.completedUnitCount = min(Self.steps - 1, p.completedUnitCount + 1)
        switch type {
        case "thinking": task.updateTitle(task.title, subtitle: String(localized: "在想怎么回你"))
        case "bubble": task.updateTitle(task.title, subtitle: String(localized: "回了 \(bubbles) 句"))
        default: break
        }
    }

    func finish(_ conv: String, success: Bool = true) {
        let task = lock.withLock { () -> BGContinuedProcessingTask? in
            guard let s = slots[conv] else { return nil }
            if let t = s.task { slots[conv] = nil; return t }
            slots[conv]?.done = true                               // 苹果还没排到：排到时直接收
            return nil
        }
        guard let task else { return }
        task.progress.completedUnitCount = Self.steps
        task.setTaskCompleted(success: success)
    }
}
#endif
