import Foundation
import Testing
@testable import MeleLiteCore

@Suite struct RoomTimelineTests {
    func t(_ hm: String) -> Date {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.timeZone = TimeZone(identifier: "UTC")
        return f.date(from: "2026-10-11 " + hm)!
    }
    var room: String { RoomTimeline.groupRoom("三人行", zh: true) }

    /// spec 里的例子：阿橘在私聊里看到的六句
    @Test func interleavesByTime() {
        let dm = [Message(id: "1", role: .user, text: "今天好累", at: t("20:00")),
                  Message(id: "2", role: .assistant, text: "抱抱", at: t("20:01")),
                  Message(id: "6", role: .user, text: "我回来了", at: t("20:10"))]
        let group = [RoomTimeline.Item(id: "g3", room: room, who: "她", text: "@小满 你昨天说的那家店叫什么", at: t("20:05")),
                     RoomTimeline.Item(id: "g4", room: room, who: "小满", text: "叫「半糖」", at: t("20:06")),
                     RoomTimeline.Item(id: "g5", room: room, who: nil, text: "又背着我去吃好吃的？", at: t("20:06"))]
        let out = RoomTimeline.merge(dm, others: group, limit: 30)
        #expect(out.map(\.text) == ["今天好累", "抱抱", "〔群「三人行」 · 她〕@小满 你昨天说的那家店叫什么",
                                    "〔群「三人行」 · 小满〕叫「半糖」", "〔群「三人行」〕又背着我去吃好吃的？", "我回来了"])
        #expect(out.map(\.role) == [.user, .assistant, .user, .user, .assistant, .user])
    }
    @Test func keepsOnlyTheLatestN() {
        let others = (0..<5).map { RoomTimeline.Item(id: "g\($0)", room: room, who: "小满", text: "第\($0)句", at: t("19:0\($0)")) }
        let out = RoomTimeline.merge([Message(id: "1", role: .user, text: "在吗", at: t("20:00"))], others: others, limit: 2)
        #expect(out.map(\.text) == ["〔群「三人行」 · 小满〕第3句", "〔群「三人行」 · 小满〕第4句", "在吗"])
    }
    @Test func zeroMeansNoMerge() {
        let cur = [Message(id: "1", role: .user, text: "在吗", at: t("20:00"))]
        let o = [RoomTimeline.Item(id: "g", room: room, who: "小满", text: "嗨", at: t("19:00"))]
        #expect(RoomTimeline.merge(cur, others: o, limit: 0) == cur)
    }
    @Test func currentRoomFirstOnTies() {
        let cur = [Message(id: "1", role: .user, text: "这边", at: t("20:00"))]
        let o = [RoomTimeline.Item(id: "g", room: RoomTimeline.privateRoom(zh: true), who: "她", text: "那边", at: t("20:00"))]
        #expect(RoomTimeline.merge(cur, others: o, limit: 5).map(\.text) == ["这边", "〔私聊 · 她〕那边"])
    }
    @Test func ids_doNotCollide() {
        let cur = [Message(id: "1", role: .user, text: "a", at: t("20:00"))]
        let o = [RoomTimeline.Item(id: "1", room: room, who: "小满", text: "b", at: t("19:00"))]
        let ids = RoomTimeline.merge(cur, others: o, limit: 5).map(\.id)
        #expect(Set(ids).count == 2)
    }
    @Test func stripsLeakedRoomTag() {      // 10-31 内测：它学着历史在开头垫房间标签
        #expect(RoomTimeline.stripTag("〔群「三人行」 · 小满〕哈哈") == "哈哈")
        #expect(RoomTimeline.stripTag("〔私聊〕嗯") == "嗯")
        #expect(RoomTimeline.stripTag("〔现在〕不动") == "〔现在〕不动")
        #expect(RoomTimeline.note(here: RoomTimeline.privateRoom(zh: true), zh: true).contains("你现在在私聊"))
    }
}
