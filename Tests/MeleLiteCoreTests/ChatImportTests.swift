import Foundation
import Testing
@testable import MeleLiteCore

/// 导入官方聊天记录（10-05，设计 new-app docs/superpowers/specs/2026-10-05-chat-import-design.md）。假导出包是小满 / Mia。
@Suite struct ChatImportTests {
    func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: Bundle.module.resourceURL!.appendingPathComponent("Fixtures/\(name)"))
    }

    @Test func zipFindsConversationsInDeflatedAndStoredArchives() throws {
        for name in ["chatgpt-export.zip", "claude-export.zip"] {
            let json = try #require(try MiniZip.entry("conversations.json", in: fixture(name)))
            #expect((try JSONSerialization.jsonObject(with: json) as? [Any])?.count == 2)
        }
        #expect(try MiniZip.entry("nope.json", in: fixture("claude-export.zip")) == nil)
    }

    @Test func chatGPTFollowsTheBranchTheyLastSaw() throws {
        let got = try ChatImport.parse(fixture("chatgpt-export.zip"))
        #expect(got.source == .chatgpt)
        let beach = try #require(got.conversations.first { $0.title == "周末去哪" })
        #expect(beach.messages.map(\.text) == ["周末想去海边，你觉得呢", "去吧，记得带外套", "这是那天拍的", "好看。\n风大吗"])
        #expect(beach.messages.map(\.role) == [.user, .assistant, .user, .assistant])   // 系统、工具、被重新生成掉的都不要
        #expect(beach.messages[0].at == Date(timeIntervalSince1970: 1727000010))
        #expect(beach.createdAt == Date(timeIntervalSince1970: 1727000000))
    }

    @Test func claudeUsesContentTextAndFallsBackToText() throws {
        let got = try ChatImport.parse(fixture("claude-export.zip"))
        #expect(got.source == .claude)
        #expect(got.conversations.count == 1)                                     // 空对话不要
        let c = got.conversations[0]
        #expect(c.title == "睡不着")
        #expect(c.messages.map(\.text) == ["睡不着，陪我聊会儿", "好，我在", "只有 text 字段的老格式"])   // 思考、只调工具的不要
        #expect(c.messages.map(\.role) == [.user, .assistant, .user])
        #expect(abs(c.messages[1].at.timeIntervalSince(ISO8601DateFormatter().date(from: "2025-09-20T14:00:09Z")!) - 0.123456) < 0.001)
    }

    @Test func deepSeekWalksFromRootTakingTheNewestBranch() throws {
        let got = try ChatImport.parse(fixture("deepseek-export.zip"))
        #expect(got.source == .deepseek)                                              // 有 mapping 也不能认成 ChatGPT
        #expect(got.conversations.count == 1)                                         // 空对话不要
        let c = got.conversations[0]
        #expect(c.title == "周末去哪")
        #expect(c.messages.map(\.text) == ["周末想去海边，你觉得呢", "去吧，记得带外套", "风大吗", "有点大，戴帽子"])   // 思考、联网、旧分支不要
        #expect(c.messages.map(\.role) == [.user, .assistant, .user, .assistant])
        #expect(c.messages[0].at == ISO8601DateFormatter().date(from: "2025-09-20T06:00:01Z"))
    }

    @Test func deepSeekFollowsTheBranchWithTheLatestMessage() throws {
        // 10-11 内测：10-03 重新生成过一次（新枝更晚建、没接着聊），主线（旧枝）一直聊到 10-11
        func node(_ id: String, _ parent: String?, _ kids: [String], _ type: String?, _ text: String, _ at: String) -> [String: Any] {
            var n: [String: Any] = ["id": id, "children": kids]
            if let parent { n["parent"] = parent }
            if let type { n["message"] = ["inserted_at": at, "fragments": [["type": type, "content": text]]] }
            return n
        }
        let mapping: [String: Any] = [
            "root": node("root", nil, ["1"], nil, "", ""),
            "1": node("1", "root", ["2"], "REQUEST", "早", "2026-10-03T01:00:00Z"),
            "2": node("2", "1", ["3"], "RESPONSE", "早呀", "2026-10-03T01:00:05Z"),
            "3": node("3", "2", ["4a", "4b"], "REQUEST", "今天去哪", "2026-10-03T01:01:00Z"),
            "4a": node("4a", "3", ["5"], "RESPONSE", "去海边", "2026-10-03T01:01:05Z"),
            "4b": node("4b", "3", [], "RESPONSE", "去山里（重新生成的）", "2026-10-03T02:00:00Z"),
            "5": node("5", "4a", ["6"], "REQUEST", "好", "2026-10-11T03:00:00Z"),
            "6": node("6", "5", [], "RESPONSE", "11 号的话", "2026-10-11T03:00:05Z"),
        ]
        let conv: [String: Any] = ["id": "x", "title": "白露", "inserted_at": "2026-10-03T01:00:00Z", "mapping": mapping]
        let data = try JSONSerialization.data(withJSONObject: [conv])
        let got = try ChatImport.parse(data)
        #expect(got.source == .deepseek)
        #expect(got.conversations[0].messages.map(\.text) == ["早", "早呀", "今天去哪", "去海边", "好", "11 号的话"])
    }

    @Test func geminiTakeoutIsGroupedByDayAndOnlyKeepsQuestions() throws {
        let got = try ChatImport.parse(fixture("gemini-takeout.zip"), timeZone: TimeZone(identifier: "UTC")!)
        #expect(got.source == .gemini)
        #expect(got.conversations.map(\.title) == ["Gemini · 2025-09-20", "Gemini · 2025-09-21"])   // YouTube 那份不算
        let first = got.conversations[0]
        #expect(first.messages.map(\.text) == ["养猫要准备什么", "猫砂盆\n\n猫粮和水碗", "那狗呢", "狗要\n牵引绳"])  // 只发图、Canvas、反馈不要
        #expect(first.messages.map(\.role) == [.user, .assistant, .user, .assistant])
        #expect(got.conversations[1].messages[1].text == "要的，早晚凉。\n\n- 薄外套\n- 围巾 & 帽子")
    }

    @Test func geminiHTMLTakeoutAsksForJSON() throws {
        #expect(throws: ChatImportError.needsJSON) { try ChatImport.parse(fixture("gemini-takeout-html.zip")) }
    }

    @Test func plainJSONWorksToo() throws {
        let json = try #require(try MiniZip.entry("conversations.json", in: fixture("claude-export.zip")))
        #expect(try ChatImport.parse(json).source == .claude)
    }

    @Test func unknownFileIsRejected() {
        #expect(throws: ChatImportError.unrecognized) { try ChatImport.parse(Data("[{\"foo\":1}]".utf8)) }
        #expect(throws: ChatImportError.unrecognized) { try ChatImport.parse(Data("not json".utf8)) }
    }

    @Test func timelineMergesByTimeWithADividerPerConversation() throws {
        let got = try ChatImport.parse(fixture("chatgpt-export.zip"))
        let t = ChatImport.timeline(got.conversations, source: got.source)
        guard case let .divider(first, _) = t[0] else { Issue.record("第一条应该是分隔行"); return }
        #expect(first == "考试")                                                 // 早的那段在前
        #expect(t.filter { if case .divider = $0 { return true } else { return false } }.count == 2)
        #expect(t.count == 2 + 2 + 4)
    }
}

@Suite struct ChatImportSplitTests {
    func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: Bundle.module.resourceURL!.appendingPathComponent("Fixtures/\(name)"))
    }

    @Test func numberedConversationFileInsideAFolderIsFound() throws {
        let got = try ChatImport.parse(fixture("claude-part1.zip"))
        #expect(got.source == .claude && got.conversations.map(\.title) == ["第二包里的"])
    }

    @Test func severalPackagesAreMergedAndDeduped() throws {
        let got = try ChatImport.parse([fixture("claude-export.zip"), fixture("claude-part1.zip"), fixture("claude-export.zip")])
        #expect(got.source == .claude)
        #expect(Set(got.conversations.map(\.title)) == ["睡不着", "第二包里的"])
    }

    @Test func mixingTwoAppsIsRejected() {
        #expect(throws: ChatImportError.mixed) {
            try ChatImport.parse([try fixture("claude-export.zip"), try fixture("chatgpt-export.zip")])
        }
    }
}

@Suite struct ImportMemoryTests {
    func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: Bundle.module.resourceURL!.appendingPathComponent("Fixtures/\(name)"))
    }

    @Test func claudeMemoriesAreRead() throws {
        #expect(try ClaudeMemories.parse(fixture("claude-memories.zip")) == ["小满在读高三，喜欢秋天。", "小满养了一只橘猫叫年糕。"])
        #expect(try ClaudeMemories.parse(fixture("claude-export.zip")).isEmpty)          // 不是记忆包
        // 10-20 内测：zip 解开、只选了里面那个 json；整份导出里那种一串对象的也认
        let bare = Data(#"{"conversations_memory":"小满在读高三。","project_memories":{"p1":"小满养了猫。"}}"#.utf8)
        #expect(try ClaudeMemories.parse(bare) == ["小满在读高三。", "小满养了猫。"])
        #expect(try ClaudeMemories.parse(Data(#"[{"conversations_memory":"小满喜欢秋天。"}]"#.utf8)) == ["小满喜欢秋天。"])
        #expect(try ClaudeMemories.parse(Data(#"{"title":"别的东西"}"#.utf8)).isEmpty)
        #expect(try ClaudeMemories.parse(Data(#"[{"uuid":"x","name":"对话"}]"#.utf8)).isEmpty)
        // 字段名跟整份导出的不一样（设置里「导出记忆」那种）：键名带 memor 的底下的文字都收，编号 / 时间不收
        let other = Data(#"{"uuid":"ec991c08-4cd9-46ca-9f00-000000000032","created_at":"2026-10-20T12:00:00Z","memories":[{"id":"ec991c08-4cd9-46ca-9f00-000000000033","content":"小满在读高三，喜欢秋天。","updated_at":"2026-10-20T12:00:00.123Z"}]}"#.utf8)
        #expect(try ClaudeMemories.parse(other) == ["小满在读高三，喜欢秋天。"])
        #expect(try ClaudeMemories.parse(Data(#"{"memory":"小满养了一只橘猫叫年糕。"}"#.utf8)) == ["小满养了一只橘猫叫年糕。"])
        #expect(try ClaudeMemories.parse(Data(#"[{"uuid":"x","name":"对话","chat_messages":[{"text":"memory 这个词"}]}]"#.utf8)).isEmpty)
    }

    @Test func chunksKeepSpeakersAndDatesAndStayUnderSize() {
        let day = ISO8601DateFormatter().date(from: "2025-09-20T14:00:00Z")!
        let msgs = (0..<30).map { i in
            ImportedMessage(role: i % 2 == 0 ? .user : .assistant, text: String(repeating: "字", count: 300), at: day.addingTimeInterval(Double(i) * 60))
        }
        let c = ImportedConversation(id: "c", title: "睡不着", createdAt: day, messages: msgs)
        let chunks = ImportMemory.chunks(c, userName: "小满", size: 2000, timeZone: TimeZone(identifier: "UTC")!)
        #expect(chunks.count > 1 && chunks.allSatisfy { $0.count <= 2000 + 400 })
        #expect(chunks[0].hasPrefix("〔2025-09-20〕") && chunks[0].contains("小满：") && chunks[0].contains("我："))
    }

    @Test func pickedLinesAreParsedAndJunkDropped() {
        let reply = """
        - 2025-09-20｜小满养了一只橘猫叫年糕
        - 2025-09-21 | 我们说好十二月一起看雪
        - 没有日期的一条
        无关的废话
        （没有值得记的）
        """
        let got = ImportMemory.parsePicked(reply)
        #expect(got.map(\.day) == ["2025-09-20", "2025-09-21", ""])
        #expect(got.map(\.text) == ["小满养了一只橘猫叫年糕", "我们说好十二月一起看雪", "没有日期的一条"])
    }

    @Test func promptsSwapSpeakersAndAvoidGuessedPronouns() {
        let pick = ImportMemory.pickPrompt("〔2025-09-20〕\n小满：我爸说我是北方人", name: "Mia", userName: "小满", zh: true)
        #expect(pick.contains("「小满的爸爸……」") && pick.contains("不用「他」「她」"))
        let notes = ImportMemory.notesPrompt([.init(day: "2025-09-20", text: "小满的爸爸说她是北方人")], extra: [],
                                             source: .claude, name: "Mia", userName: "小满", zh: true)
        #expect(notes.contains("2400 字以内") && notes.contains("不写「已合并」"))
    }

    @Test func notesOverLimitAreClippedAtSentenceEnd() {
        let long = String(repeating: "小满喜欢吃饺子。", count: 600) + "小满说以"
        let got = ImportMemory.clipNotes(long, limit: 3000)
        #expect(got.count <= 3900 && got.hasSuffix("。"))
        #expect(ImportMemory.clipNotes("  短的  ", limit: 3000) == "短的")
        #expect(ImportMemory.clipNotes(String(repeating: "字", count: 5000), limit: 3000).count == 3900)
    }

    // MARK: Kelivo（10-11）：假整包是 Tests/fixture-tools/make_kelivo_backup.py 造的

    @Test func kelivoZip64BackupIsReadFromMemoryAndFromDisk() throws {
        let url = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/kelivo-backup.zip")
        let fromDisk = try #require(try MiniZip.entry(path: "database/kelivo.db", inFileAt: url))
        let fromMemory = try #require(try MiniZip.entries(in: fixture("kelivo-backup.zip"), path: { $0 == "database/kelivo.db" }).first?.data)
        #expect(fromDisk == fromMemory && ChatImport.isSQLite(fromDisk))
        let manifest = try #require(try MiniZip.entry("manifest.json", in: fixture("kelivo-backup.zip")))   // 没走 ZIP64 附加块的那个也拿得到
        #expect(String(decoding: manifest, as: UTF8.self).contains("kelivo-backup"))
        #expect(try MiniZip.entry(path: "nope", inFileAt: url) == nil)
    }

    @Test func kelivoFollowsTheChosenVersionAndKeepsOnlyText() throws {
        let got = try ChatImport.parse(fixture("kelivo-backup.zip"))
        #expect(got.source == .kelivo)
        #expect(got.conversations.map(\.title) == ["周末去哪", "睡不着"])                     // 空对话不要
        let beach = got.conversations[0]
        #expect(beach.assistant == "Mia")
        #expect(beach.messages.map(\.text) == ["周末想去海边，你觉得呢", "去吧\n记得带外套", "这是那天拍的"])   // 没选过 → 最新版；思考、工具、只有图的不要
        #expect(beach.messages.map(\.role) == [.user, .assistant, .user])
        #expect(beach.messages[0].at == Date(timeIntervalSince1970: 1_760_000_010))
        #expect(beach.createdAt == Date(timeIntervalSince1970: 1_760_000_000))
        let sleep = got.conversations[1]
        #expect(sleep.assistant == nil)
        #expect(sleep.messages.map(\.text) == ["睡不着，陪我聊会儿", "好，我在"])               // 选过旧版本就用旧的；system 不要
    }

    @Test func kelivoBareDatabaseAndMemoriesWork() throws {
        let db = try #require(ChatImport.kelivoDatabase(in: fixture("kelivo-backup.zip")))
        #expect(try ChatImport.parse(db).conversations.count == 2)                           // 解压出来的 kelivo.db 也认
        #expect(ChatImport.kelivoMemories(try fixture("kelivo-backup.zip")) == ["小满喜欢海", "小满怕冷"])
        #expect(ChatImport.kelivoMemories(try fixture("claude-export.zip")).isEmpty)
    }

    @Test func markdownChatExport() throws {
        let md = """
        # Chat with 阿橘

        *Exported on 2026年10月11日, 6:54 PM*
        *3 messages in this export*

        ---
        ## 2026年10月11日星期日

        ### 6:49 PM — 小满

        晚上好！吃了没？

        ### 6:49 PM — 阿橘 *(proactive)*

        *把爪子从画上收回来*

        吃了。

        ### Day plan - morning

        这一行是正文里的小标题，不是一条消息。

        ---
        ## Monday, October 12, 2026

        ### 9:05 AM — 小满

        早
        """
        let tz = TimeZone(identifier: "Asia/Singapore")!
        let got = try ChatImport.parse(Data(md.utf8), timeZone: tz)
        #expect(got.source == .markdown && got.conversations.count == 1)
        let c = got.conversations[0]
        #expect(c.assistant == "阿橘" && c.title == "Chat with 阿橘")
        #expect(c.messages.map(\.role) == [.user, .assistant, .user])
        #expect(c.messages[0].text == "晚上好！吃了没？")
        #expect(c.messages[1].text == "*把爪子从画上收回来*\n\n吃了。\n\n### Day plan - morning\n\n这一行是正文里的小标题，不是一条消息。")
        var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
        #expect(cal.dateComponents([.month, .day, .hour, .minute], from: c.messages[0].at) == DateComponents(month: 10, day: 11, hour: 18, minute: 49))
        #expect(c.messages[1].at > c.messages[0].at)                     // 同一分钟也分得出先后
        #expect(cal.dateComponents([.day, .hour, .minute], from: c.messages[2].at) == DateComponents(day: 12, hour: 9, minute: 5))
        #expect(throws: ChatImportError.self) { try ChatImport.parse(Data("# 随便写的笔记\n\n没有消息头".utf8)) }
    }

    /// Mele 自己「导出聊天记录」写出来的 md 要能原样导回来（11-28 内测反馈）。
    /// 样本照 App 里 ChatExport.render 的写法逐行拼的：改那边的格式要回来改这里。
    @Test func meleOwnExportRoundTrips() throws {
        let md = [
            "# 和阿橘的聊天记录",
            "",
            "导出于 Nov 28, 2026 at 4:50 PM · 2 个窗口 · 6 条",
            "",
            "",
            "## 第一次聊天（试试）",
            "",
            "### 2026-10-17 周六",
            "",
            "**小满** 18:49",
            "晚上好！",
            "",
            "吃了没？",
            "",
            "**阿橘** 18:49",
            "吃了。",
            "",
            "## 今天的菜单",
            "",
            "番茄炒蛋",
            "",
            "> 心声：她又来问我吃没吃",
            "> 其实是她自己饿了",
            "",
            "### 2026-10-18 周日",
            "",
            "— 新的一天 —",
            "",
            "**小满** 09:05",
            "早",
            "",
            "［图片］",
            "",
            "**阿栗** 09:06",
            "我也在",
            "",
            "",
            "## 悄悄话（小号：阿满 · 无痕）",
            "",
            "### 2026-10-19 Mon",
            "",
            "**阿满** 23:10",
            "睡了吗",
            "",
            "**阿橘** 23:11",
            "没有，在等你。",
            "",
        ].joined(separator: "\n")
        let tz = TimeZone(identifier: "Asia/Singapore")!
        let got = try ChatImport.parse(Data(md.utf8), timeZone: tz)
        #expect(got.source == .markdown && got.conversations.count == 2)
        let a = got.conversations[0], b = got.conversations[1]
        #expect(a.title == "第一次聊天（试试）" && a.assistant == "阿橘")        // 标题自己带的括号不动
        #expect(b.title == "悄悄话" && b.assistant == "阿橘")                    // 小号 / 无痕是标签，摘掉
        #expect(a.messages.map(\.role) == [.user, .assistant, .user, .assistant])   // 群里别的 TA（阿栗）算对面
        #expect(a.messages[0].text == "晚上好！\n\n吃了没？")                    // 一条里的两个气泡
        #expect(a.messages[1].text == "吃了。\n\n## 今天的菜单\n\n番茄炒蛋")      // 正文里的小标题不是新窗口；心声不搬
        #expect(a.messages[2].text == "早\n\n［图片］")                          // 分隔线不进正文
        #expect(b.messages.map(\.role) == [.user, .assistant])                   // 这个窗口里小号才是「你」
        #expect(b.messages.map(\.text) == ["睡了吗", "没有，在等你。"])
        var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
        #expect(cal.dateComponents([.month, .day, .hour, .minute], from: a.messages[0].at) == DateComponents(month: 10, day: 17, hour: 18, minute: 49))
        #expect(a.messages[1].at > a.messages[0].at)                             // 同一分钟也分得出先后
        #expect(cal.dateComponents([.day, .hour, .minute], from: a.messages[2].at) == DateComponents(day: 18, hour: 9, minute: 5))
        #expect(cal.dateComponents([.day, .hour, .minute], from: b.messages[1].at) == DateComponents(day: 19, hour: 23, minute: 11))
        #expect(a.id != b.id)

        // 一句都没聊过的导出：没有可搬的，照旧报认不出
        let empty = "# 和阿橘的聊天记录\n\n导出于 Nov 28, 2026 · 0 个窗口 · 0 条\n\n（还没有聊过）\n"
        #expect(throws: ChatImportError.self) { try ChatImport.parse(Data(empty.utf8)) }
    }
}
