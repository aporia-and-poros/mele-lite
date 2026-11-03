import Testing
@testable import MeleLiteCore

@Suite struct VoiceNoteLengthTests {
    @Test func roughSeconds() {
        #expect(VoiceNoteLength.estimateMs("[soft] 晚安…早点睡，明天见。") / 1000 == 2)   // 9 个字 ≈ 2.5 秒
        #expect(VoiceNoteLength.estimateMs("Goodnight, sleep well, see you tomorrow.") / 1000 == 2)
        #expect(VoiceNoteLength.estimateMs("嗯") == 1000)
    }
}
