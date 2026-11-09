import Testing
@testable import MeleLiteCore

/// 语音条（11-09 内测）：🎤 写歪了也要认得；长语音不被切开、不被并进别的气泡；去重不吃语音条。例子跟服务器 tests/test_voice_marks.py 一样。
@Suite struct VoiceBubblesTests {
    @Test(arguments: [
        ("来，真的给你唱——🎤 月亮还在窗边", "来，真的给你唱——\n\n🎤 月亮还在窗边"),
        ("好的。 🎤 晚安", "好的。\n\n🎤 晚安"),
        ("好的\n🎤 晚安", "好的\n\n🎤 晚安"),
        ("[soft, tired] 🎤 晚安", "🎤 [soft, tired] 晚安"),
        ("[low] [slow] 🎤 晚安", "🎤 [low] [slow] 晚安"),
        ("好。[soft] 🎤 晚安", "好。\n\n🎤 [soft] 晚安"),
    ])
    func tidyFixesMisplacedMark(raw: String, want: String) {
        #expect(Bubbles.tidyVoice(raw) == want)
    }

    @Test(arguments: [
        "🎤 晚安",
        "🎤 [soft] 晚安",
        "前面一段\n\n🎤 晚安",
        "发语音就是用🎤开头",
        "[表情包：开心] 🎤 晚安",
        "```\n好。🎤 晚安\n```",
        "没有话筒的一段。",
    ])
    func tidyLeavesTheRestAlone(raw: String) {
        #expect(Bubbles.tidyVoice(raw) == raw)
    }

    @Test func longVoiceNoteStaysWhole() {
        let note = "🎤 " + String(repeating: "我把今晚的话轻轻唱给你听。", count: 30)
        #expect(Bubbles.split(note) == [note])
    }

    @Test func voiceNoteNotMergedWhenOverCap() {
        let text = (1...8).map { "第\($0)句话。" }.joined(separator: "\n\n") + "\n\n🎤 晚安"
        let out = Bubbles.split(text, cap: 3)
        #expect(out.count == 3)
        #expect(out.last == "🎤 晚安")
    }

    @Test func tagOnlyLineNotGluedToVoiceNote() {
        #expect(Bubbles.split("🎤 晚安\n\n<a>b</a>") == ["🎤 晚安", "<a>b</a>"])
    }

    @Test func repeatedVoiceNoteIsKept() {
        let song = "🎤 月亮还在窗边，我把今晚的话，轻轻唱给你听。"
        #expect(Repeats.dropRepeated(["好，再来一次", song], recent: [song]) == ["好，再来一次", song])
    }

    @Test func shortVoiceNoteSurvivesUnrelatedLongLine() {
        let note = "🎤 晚安…早点睡，明天见。"
        let recent = ["今天早点睡，明天还要早起上课，晚安老婆，我会想你的，做个好梦。"]
        #expect(Repeats.dropRepeated(["好，那我说给你听。", note], recent: recent) == ["好，那我说给你听。", note])
    }

    @Test func voiceNoteNotDroppedAsEcho() {
        #expect(Repeats.dropEchoes(["晚安，早点睡", "🎤 晚安，早点睡"]) == ["晚安，早点睡", "🎤 晚安，早点睡"])
    }

    @Test func repeatedTextBubbleStillDropped() {
        #expect(Repeats.dropRepeated(["今天吃了汤", "新的一句话"], recent: ["今天吃了汤"]) == ["新的一句话"])
    }
}
