import Foundation

/// 发出去的话排成一条线（11-10）：一句到了才发下一句，先说的先到。
/// 以前每句各发各的，攒好几句一起发时谁先到不一定，TA 那边看到的顺序就乱了（c b a、c a b 都有）。
/// 一句没发到（断网）就停在它那儿，后面的不越过去；再有新的进来、或者看门狗重发时，从它那儿接着来。
/// Lite 本机和连着 Host 都走这条线（ChatStore 两边共用）。测试：ios/tests/run.sh
@MainActor
final class SendLine<Item: Equatable> {
    private var waiting: [Item] = []
    private var running = false
    /// 正在路上的那一句（它还排在 waiting 最前面，到了才摘）
    private var flying: Item?
    private let deliver: (Item) async -> Bool

    /// deliver：把这一句送到，送到了返回 true
    init(deliver: @escaping (Item) async -> Bool) { self.deliver = deliver }

    /// 排到队尾。前面有卡住的，先从卡住的那句重试
    func add(_ item: Item) {
        waiting.append(item)
        pump()
    }

    /// 重发：整条线换成这些，按顺序从头来（看门狗用；同一句发两次服务器认得，不会排两次）
    func restart(with items: [Item]) {
        waiting = items
        pump()
    }

    /// 还排着没发的那句拿掉（撤回）。已经在路上 / 已经到了的拿不掉，返回 false
    func take(_ item: Item) -> Bool {
        guard item != flying, let i = waiting.firstIndex(of: item) else { return false }
        waiting.remove(at: i)
        return true
    }

    private func pump() {
        guard !running else { return }
        running = true
        Task {
            while let next = waiting.first {
                flying = next
                let ok = await deliver(next)
                flying = nil
                guard ok else { break }                                  // 没到：停在这儿，后面的不越过去
                if waiting.first == next { waiting.removeFirst() }      // 路上被 restart 换过队就不动，接着按新队走
            }
            running = false
        }
    }
}
