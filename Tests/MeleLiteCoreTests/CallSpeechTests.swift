import Foundation
import Testing
@testable import MeleLiteCore

/// 打电话：边写边切、念之前洗一遍、纸条。测试数据用小满。
@Suite struct CallSpeechTests {
    /// 一个字一个字地推，模拟流式
    func stream(_ text: String, _ s: inout CallSpeech.Splitter) -> [String] {
        var out: [String] = []
        for ch in text { out += s.feed(String(ch)) }
        return out + s.finish()
    }

    @Test func oneLinePerSentence() {
        var s = CallSpeech.Splitter()
        #expect(stream("小满你回来啦\n今天累不累？\n我在等你吃饭。", &s) == ["小满你回来啦", "今天累不累？", "我在等你吃饭。"])
    }

    @Test func cutsInsideALineAtSentenceEnds() {
        var s = CallSpeech.Splitter()
        // 「？！」连着算一句的结尾；后面来了字才切
        #expect(stream("真的假的？！你考了一百分。太厉害了吧", &s) == ["真的假的？！", "你考了一百分。", "太厉害了吧"])
        var e = CallSpeech.Splitter()
        #expect(stream("That's 3.5 hours. Go to sleep, okay?", &e) == ["That's 3.5 hours.", "Go to sleep, okay?"])
    }

    @Test func firstSentenceComesOutBeforeTheRest() {
        var s = CallSpeech.Splitter()
        #expect(s.feed("我一直在呢").isEmpty)
        #expect(s.feed("。你").first == "我一直在呢。")            // 句号后面来了字：第一句马上交出去
        #expect(s.feed("说吧").isEmpty)
        #expect(s.finish() == ["你说吧"])
    }

    @Test func shortBitsWaitForTheNextSentence() {
        var s = CallSpeech.Splitter()
        #expect(stream("嗯。\n小满，我想你了。", &s) == ["嗯。小满，我想你了。"])
        var last = CallSpeech.Splitter()
        #expect(stream("好的，晚安。\n嗯。", &last) == ["好的，晚安。", "嗯。"])   // 最后剩的短句照样念
    }

    @Test func actionsAndMarkersAreNotSpoken() {
        #expect(CallSpeech.clean("（笑）好呀，那就说好了") == "好呀，那就说好了")
        #expect(CallSpeech.clean("*抱住你* 别走嘛") == "别走嘛")
        #expect(CallSpeech.clean("🎤 [soft] 晚安") == "晚安")
        #expect(CallSpeech.clean("[表情包：抱抱]") == nil)
        #expect(CallSpeech.clean("⟪里程碑：第一通电话⟫") == nil)
        #expect(CallSpeech.clean("- **记得**吃饭") == "记得吃饭")
        #expect(CallSpeech.clean("……") == nil)
    }

    @Test func leakedMonologueIsSkipped() {
        var s = CallSpeech.Splitter()
        #expect(stream("[独白]\n小满听起来好累。\n[/独白]\n今天辛苦啦。\n快去躺着吧。", &s) == ["今天辛苦啦。", "快去躺着吧。"])
    }

    @Test func notesAndClock() {
        #expect(CallSpeech.clock(201) == "03:21")
        #expect(CallSpeech.clock(3723) == "1:02:03")
        #expect(CallSpeech.durationLine(seconds: 201, zh: true) == "📞 通话时长 03:21")
        #expect(CallSpeech.hangUpNote(seconds: 201, zh: true) == "〔电话挂了，这通打了 3 分 21 秒。接下来回到打字聊天。〕")
        #expect(CallSpeech.hangUpNote(seconds: 9, zh: false).contains("9 s"))
        #expect(CallSpeech.rules(zh: true, pronoun: "她").contains("一句一行"))
        #expect(CallSpeech.cutNote(zh: true).contains("打断"))
        #expect(CallSpeech.rules(zh: false, pronoun: "she").hasPrefix("[You're on a phone call] She"))
    }
    @Test func ringNotesAndLines() {
        #expect(CallSpeech.ringLine(.missed, zh: true) == "📞 未接来电")
        #expect(CallSpeech.ringLine(.declined, zh: true) == "📞 已拒绝")
        #expect(CallSpeech.ringLine(.withdrawn, zh: true) == "📞 对方已取消")
        #expect(CallSpeech.ringNote(.missed, zh: true, pronoun: "她").contains("她没接"))
        #expect(CallSpeech.ringNote(.declined, zh: false, pronoun: "she").contains("declined"))
        let n = CallSpeech.answeredNudge(zh: true, pronoun: "她", reason: "想听听她声音")
        #expect(n.contains("你先开口") && n.contains("想听听她声音"))
        #expect(!CallSpeech.answeredNudge(zh: true, pronoun: "她", reason: "  ").contains("因为"))
    }
}
