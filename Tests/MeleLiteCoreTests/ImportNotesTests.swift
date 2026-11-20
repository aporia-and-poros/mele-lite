import Foundation
import Testing
@testable import MeleLiteCore

/// 搬家也收「不是聊天记录的笔记 / 总结」（10-13 内测：自己用 GPT 总结的聊天记录搬不进来）；
/// 表情包描述：不会看图的模型（DeepSeek）别去问。测试数据用小满。
@Suite struct ImportNotesTests {
    @Test func plainTextFilesBecomeNotes() {
        let md = Data("# 关于小满\n\n- 小满养了一只橘猫叫年糕\n- 小满下个月去东京\n".utf8)
        #expect(ChatImport.plainNotes([md]) == "# 关于小满\n\n- 小满养了一只橘猫叫年糕\n- 小满下个月去东京")
        #expect(ChatImport.plainNotes([Data("[{\"a\":1}]".utf8)]) == nil)        // JSON 是别的格式认错了，不当笔记
        #expect(ChatImport.plainNotes([Data([0x50, 0x4B, 0x03, 0x04, 0x00])]) == nil)   // zip
        #expect(ChatImport.plainNotes([Data("   \n".utf8)]) == nil)
        #expect(ChatImport.plainNotes([md, Data("第二份".utf8)]) == "# 关于小满\n\n- 小满养了一只橘猫叫年糕\n- 小满下个月去东京\n\n第二份")
    }

    @Test func notesAreChunkedOnParagraphs() {
        let text = (1...5).map { "第\($0)段" + String(repeating: "字", count: 50) }.joined(separator: "\n\n")
        let parts = ImportMemory.notesChunks(text, size: 120)
        #expect(parts.count == 3)
        #expect(parts.allSatisfy { $0.count <= 120 })
        #expect(parts.joined(separator: "\n\n") == text)
        #expect(ImportMemory.notesChunks(String(repeating: "长", count: 300), size: 100).count == 3)   // 没有空行就硬切
    }

    @Test func notesPromptSaysItIsNotesNotAChat() {
        let p = ImportMemory.pickPrompt("小满喜欢芒果", name: "Lumi", userName: "小满", zh: true, notes: true)
        #expect(p.contains("小满自己写的") && p.contains("笔记"))
        #expect(!p.contains("聊天记录") && !p.contains("〔日期〕"))
        let chat = ImportMemory.pickPrompt("x", name: "Lumi", userName: "小满", zh: true)
        #expect(chat.contains("聊天记录"))
        #expect(ChatSource.notes.appName == "笔记")
        let n = ImportMemory.notesPrompt([.init(day: "", text: "小满喜欢芒果")], extra: [], source: .notes, name: "Lumi", userName: "小满", zh: true)
        #expect(n.contains("小满自己写的笔记") && !n.contains("聊过很久"))
    }

    @Test func deepSeekCannotSeeImages() {
        #expect(!ProviderConfig(kind: .openai, baseURL: "https://api.deepseek.com", model: "deepseek-chat").seesImages)
        #expect(ProviderConfig(kind: .openai, baseURL: nil, model: "gpt-5").seesImages)
        #expect(!ProviderConfig(kind: .openai, baseURL: "https://api.siliconflow.cn/v1", model: "deepseek-ai/DeepSeek-V3.2").seesImages)
        #expect(ProviderConfig(kind: .openai, baseURL: "https://api.siliconflow.cn/v1", model: "deepseek-ai/deepseek-vl2").seesImages)
        #expect(ProviderConfig(kind: .anthropic, model: "claude").seesImages)
        #expect(ProviderConfig(kind: .gemini, model: "gemini").seesImages)
    }
}
