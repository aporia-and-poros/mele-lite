import Foundation
import Testing
@testable import MeleLiteCore

private func msgs(_ texts: String...) -> [Message] { texts.map { Message(role: .user, text: $0) } }

@Suite struct LoreMatcherTests {
    let cat = LoreEntry(title: "猫", keys: ["年糕"], content: "年糕是她养的橘猫")
    let slang = LoreEntry(title: "梗", keys: ["日久方长"], content: "日久方长 = 我们的暗号")

    @Test func hitsOnlyRecentWindow() {
        let recent = msgs("年糕今天好乖", "嗯", "然后呢", "睡了", "早")
        #expect(LoreMatcher.hits(entries: [cat], recent: recent, contactID: "c").isEmpty)
        #expect(LoreMatcher.hits(entries: [cat], recent: Array(recent.prefix(4)), contactID: "c").map(\.title) == ["猫"])
    }

    @Test func constantAlwaysIn() {
        var rule = LoreEntry(title: "世界观", keys: [], content: "这是一个有魔法的世界")
        rule.constant = true
        #expect(LoreMatcher.hits(entries: [rule, cat], recent: msgs("hi"), contactID: "c").map(\.title) == ["世界观"])
    }

    @Test func scopedToContacts() {
        var only = slang
        only.contactIDs = ["a"]
        #expect(LoreMatcher.hits(entries: [only], recent: msgs("日久方长"), contactID: "b").isEmpty)
        #expect(LoreMatcher.hits(entries: [only], recent: msgs("日久方长"), contactID: "a").count == 1)
    }

    @Test func disabledSkipped() {
        var off = cat
        off.enabled = false
        #expect(LoreMatcher.hits(entries: [off], recent: msgs("年糕"), contactID: "c").isEmpty)
    }

    @Test func caseAndWidthInsensitive() {
        let e = LoreEntry(title: "x", keys: ["Mele"], content: "app")
        #expect(LoreMatcher.hits(entries: [e], recent: msgs("我在用ＭＥＬＥ"), contactID: "c").count == 1)
    }

    @Test func capsAtMax() {
        let many = (0..<12).map { LoreEntry(title: "\($0)", keys: ["词\($0)"], content: "") }
        let text = (0..<12).map { "词\($0)" }.joined(separator: " ")
        #expect(LoreMatcher.hits(entries: many, recent: msgs(text), contactID: "c").count == 8)
    }

    @Test func constantsDontCountTowardMax() {
        let parts = (0..<10).map { LoreEntry(title: "设定 \($0)", keys: ["设定"], content: "第\($0)块", constant: true) }
        let many = (0..<12).map { LoreEntry(title: "\($0)", keys: ["词\($0)"], content: "") }
        let text = (0..<12).map { "词\($0)" }.joined(separator: " ")
        let got = LoreMatcher.hits(entries: parts + many, recent: msgs(text), contactID: "c")
        #expect(got.filter(\.constant).count == 10 && got.filter { !$0.constant }.count == 8)
    }
}
