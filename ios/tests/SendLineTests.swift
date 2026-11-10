import Foundation

/// 攒好几句一起发，到的顺序要跟攒的顺序一样（11-10 内测：a b c 发出去变成 c b a / c a b）。
/// App 里没有单元测试工程，这个文件跟 App/SendLine.swift 一起用 swiftc 编出来在 Mac 上跑：ios/tests/run.sh
@MainActor
final class Wire {
    var arrived: [String] = []
    var inFlight = 0, mostAtOnce = 0
    var down: Set<String> = []                       // 这几句现在发不出去（断网）
    var slow: [String: Int] = [:]                    // 这几句路上要走多少毫秒

    func send(_ s: String) async -> Bool {
        inFlight += 1
        mostAtOnce = max(mostAtOnce, inFlight)
        defer { inFlight -= 1 }
        try? await Task.sleep(for: .milliseconds(slow[s] ?? 5))
        guard !down.contains(s) else { return false }
        arrived.append(s)
        return true
    }
}

@MainActor
func check(_ ok: Bool, _ what: String) {
    print(ok ? "  ✓ \(what)" : "  ✗ \(what)")
    if !ok { failures += 1 }
}
@MainActor var failures = 0

@MainActor
func settle(_ ms: Int = 400) async { try? await Task.sleep(for: .milliseconds(ms)) }

@main
struct SendLineTests {
    @MainActor
    static func main() async {
        print("先说的先到（第一句路上最慢）")
        do {
            let wire = Wire()
            wire.slow = ["第一句": 120, "第二句": 40, "第三句": 5]
            let line = SendLine<String> { await wire.send($0) }
            for s in ["第一句", "第二句", "第三句"] { line.add(s) }
            await settle()
            check(wire.arrived == ["第一句", "第二句", "第三句"], "到的顺序 = 攒的顺序，实际 \(wire.arrived)")
            check(wire.mostAtOnce == 1, "一次只发一句，实际同时 \(wire.mostAtOnce) 句")
        }

        print("中间一句没发到：后面的不越过去")
        do {
            let wire = Wire()
            wire.down = ["第二句"]
            let line = SendLine<String> { await wire.send($0) }
            for s in ["第一句", "第二句", "第三句"] { line.add(s) }
            await settle()
            check(wire.arrived == ["第一句"], "第三句没抢在第二句前头，实际 \(wire.arrived)")
            wire.down = []
            line.add("第四句")                                  // 网好了，又发一句：从卡住的那句接着来
            await settle()
            check(wire.arrived == ["第一句", "第二句", "第三句", "第四句"], "补发还是原来的顺序，实际 \(wire.arrived)")
        }

        print("看门狗重发：整条线从头按顺序来")
        do {
            let wire = Wire()
            wire.down = ["第一句"]
            let line = SendLine<String> { await wire.send($0) }
            for s in ["第一句", "第二句"] { line.add(s) }
            await settle()
            wire.down = []
            line.restart(with: ["第一句", "第二句"])
            await settle()
            check(wire.arrived == ["第一句", "第二句"], "实际 \(wire.arrived)")
        }

        print("还排着没发的那句可以拿掉（撤回）")
        do {
            let wire = Wire()
            wire.slow = ["第一句": 150]
            let line = SendLine<String> { await wire.send($0) }
            for s in ["第一句", "第二句", "第三句"] { line.add(s) }
            try? await Task.sleep(for: .milliseconds(30))
            check(line.take("第二句"), "第二句还没发，拿得掉")
            check(!line.take("第一句"), "第一句已经在路上，拿不掉")
            await settle()
            check(wire.arrived == ["第一句", "第三句"], "实际 \(wire.arrived)")
        }

        print(failures == 0 ? "全过" : "\(failures) 处不对")
        exit(failures == 0 ? 0 : 1)
    }
}
