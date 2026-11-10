import Foundation
import Testing
@testable import MeleLiteCore

/// 电话里一轮的把手：存档和打断谁先谁后，存下来的都得是真念出口的那几句。
/// 「回顾里有、通话里没有」就出在这两件事撞在一起的时候。
@Suite struct CallLinkTests {
    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var _lines: [String] = []
        var lines: [String] { lock.withLock { _lines } }
        func add(_ l: String) { lock.withLock { _lines.append(l) } }
    }

    private func link(_ box: Box = Box()) -> CallLink {
        CallLink(callID: "c1", onLine: { box.add($0) }, onFail: { _ in })
    }

    private func write(_ l: CallLink, _ text: String) {
        for ch in text { l.feed(String(ch)) }
        l.flush()
    }

    @Test func everyTurnHasItsOwnID() {
        #expect(link().turnID != link().turnID)
        #expect(!link().turnID.isEmpty)
    }

    @Test func cutBeforeSavingStoresOnlyWhatWasSpoken() {
        let box = Box(), l = link(box)
        write(l, "小满你回来啦。\n今天累不累？")
        #expect(box.lines == ["小满你回来啦。", "今天累不累？"])
        #expect(l.cut(spoken: ["小满你回来啦。"]) == nil)            // 还没存：存的那头自己照念到的存
        let take = l.takeForSaving()
        #expect(take.lines == ["小满你回来啦。"])
        #expect(take.cut)
        #expect(l.saved(as: 7) == nil)                               // 存的就是对的，不用再改
    }

    @Test func cutAfterSavingHandsBackTheMessageToTrim() {
        let l = link()
        write(l, "小满你回来啦。\n今天累不累？")
        let take = l.takeForSaving()
        #expect(take.lines.count == 2)
        #expect(!take.cut)
        #expect(l.saved(as: 7) == nil)
        #expect(l.cut(spoken: []) == 7)                       // 已经存了：打断的那头去改
    }

    /// 11-10：正存着的那一会儿对面开口。打断来时这条还没编号（改不了），存的那头又以为没被打断（存了整段）——
    /// 两头都没改，当时一句没听到的话就留在了记录里。
    @Test func cutWhileSavingIsCaughtBySaver() {
        let l = link()
        write(l, "小满你回来啦。\n今天累不累？")
        let take = l.takeForSaving()
        #expect(!take.cut)
        #expect(l.cut(spoken: []) == nil)                            // 存到一半，对面开口了，一句都还没念
        #expect(l.saved(as: 7) == [])                         // 存的那头被告知：改回「一句都没念」
    }

    @Test func nothingComesOutAfterCut() {
        let box = Box(), l = link(box)
        write(l, "第一句话来了。")
        l.cut(spoken: [])
        l.feed("第二句也来了。\n")
        l.deliver("服务器推来的一句")
        l.flush()
        #expect(box.lines == ["第一句话来了。"])
    }
}
