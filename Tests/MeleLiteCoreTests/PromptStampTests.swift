import Foundation
import Testing
@testable import MeleLiteCore

/// 11-18 内测：「AI 对时间感知不好」——历史里 TA 那句前面标时间（第一句、换天、隔两小时以上）。跟服务器 test_history_stamps_new_day_and_long_gaps 一样
@Suite struct PromptStampTests {
    let tz8 = TimeZone(identifier: "Asia/Shanghai")!
    let t = Date(timeIntervalSince1970: 1_794_924_000)          // 2026-11-17 14:00 UTC = UTC+8 22:00 周二

    @Test func stampsFirstNewDayAndLongGapsOnly() {
        #expect(Prompt.stamp(prev: nil, at: t, tz8, .zh) == "〔11月17日 周二 22:00〕")
        #expect(Prompt.stamp(prev: nil, at: t, tz8, .en) == "[Tue 17 Nov, 22:00]")
        #expect(Prompt.stamp(prev: t, at: t + 40 * 60, tz8, .zh) == nil)
        #expect(Prompt.stamp(prev: t, at: t + 11 * 3600, tz8, .zh) == "〔11月18日 周三 09:00〕")
        #expect(Prompt.stamp(prev: t + 11 * 3600, at: t + 14 * 3600, tz8, .zh) == "〔11月18日 周三 12:00〕")
    }

    @Test func turnsStampUserSideButNotTheLatest() {
        let h = [Message(role: .user, text: "我去吃饭了", at: t), Message(role: .assistant, text: "去吧", at: t + 60),
                 Message(role: .user, text: "早", at: t + 11 * 3600), Message(role: .assistant, text: "早呀", at: t + 11 * 3600 + 60),
                 Message(role: .user, text: "在吗", at: t + 14 * 3600)]
        let c = sampleContact(); let input = PromptInput(contact: c, identity: c.identities[0], history: h, lang: .zh, now: t + 14 * 3600, timeZone: tz8)
        #expect(Prompt.turns(input, budget: 24000).map(\.text) == ["〔11月17日 周二 22:00〕\n我去吃饭了", "去吧", "〔11月18日 周三 09:00〕\n早", "早呀", "在吗"])
    }
}
