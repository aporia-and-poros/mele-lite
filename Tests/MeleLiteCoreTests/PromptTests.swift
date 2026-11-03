import Foundation
import Testing
@testable import MeleLiteCore

@Suite struct PromptTests {
    func input(_ c: Contact, identity: Identity? = nil, history: [Message] = [], lore: [LoreEntry] = [],
               stickers: [Sticker] = [], peek: String? = nil, lang: Lang = .zh, image: Data? = nil) -> PromptInput {
        PromptInput(contact: c, identity: identity ?? c.mainIdentity, history: history, loreHits: lore, stickers: stickers,
                    peekResult: peek, lang: lang, now: Date(timeIntervalSince1970: 1_791_000_000), timeZone: TimeZone(identifier: "Asia/Singapore")!,
                    currentImage: image)
    }

    @Test func sectionsInOrder() {
        var c = sampleContact()
        c.identities[0].userName = "小满"
        c.identities[0].relationship = "恋人"
        let r = Prompt.build(input(c, history: [Message(role: .user, text: "在吗")],
                                   lore: [LoreEntry(title: "年糕", keys: ["年糕"], content: "她的橘猫")],
                                   stickers: [Sticker(sha: "a", file: "a.png", caption: "猫猫比心")], peek: "## 表情包\n狗狗"))
        let s = r.system
        let order = ["你有自己的情绪", "你是 Lumi", "温柔、话少", "小满", "恋人", "现在是线上", "猫猫比心"]
        let idx = order.map { s.range(of: $0)?.lowerBound }
        #expect(idx.allSatisfy { $0 != nil })
        #expect(zip(idx, idx.dropFirst()).allSatisfy { $0! < $1! })
        // 每轮会变的不进 system（缓存吃得住），在 context 里
        #expect(!s.contains("年糕") && !s.contains("狗狗") && !s.contains("现在是 20"))
        #expect(r.context.hasPrefix("〔以下是 app 附上的参考，不是对方说的话〕\n现在是 20") && r.context.contains("年糕") && r.context.contains("狗狗"))
    }

    @Test func noStickerSectionWhenEmpty() {
        let s = Prompt.build(input(sampleContact())).system
        #expect(!s.contains("## 你的表情包"))
        #expect(!Prompt.build(input(sampleContact())).context.contains("## 你翻到的"))
    }

    @Test func altIdentityUsed() {
        var c = sampleContact()
        let alt = c.addAltIdentity(userName: "小雨", aboutMe: "刚搬来的邻居")
        let s = Prompt.build(input(c, identity: alt)).system
        #expect(s.contains("小雨") && s.contains("刚搬来的邻居") && s.contains("陌生人"))
    }

    @Test func offlineLine() {
        var c = sampleContact(); c.mode = .offline
        let s = Prompt.build(input(c)).system
        #expect(s.contains("现在是线下"))
        #expect(!s.contains("发消息"))                  // 线下不再带「像发消息那样说话」
    }

    @Test func trimsOldestKeepsLast() {
        let history = (0..<50).map { Message(role: $0 % 2 == 0 ? .user : .assistant, text: String(repeating: "字", count: 100) + "\($0)") }
        let r = Prompt.build(input(sampleContact(), history: history), budgetChars: 1000)
        let total = r.turns.reduce(0) { $0 + $1.text.count }
        #expect(total <= 1100)
        #expect(r.turns.last?.text.hasSuffix("49") == true)
        #expect(r.turns.first?.role == .user)
    }

    @Test func mergesConsecutiveSameRoleAndQuotes() {
        let a = Message(role: .assistant, text: "第一条"), b = Message(role: .assistant, text: "第二条")
        let u = Message(role: .user, text: "那我呢", quoteOf: a.id)
        let r = Prompt.build(input(sampleContact(), history: [Message(role: .user, text: "嗨"), a, b, u]))
        #expect(r.turns.map(\.role) == [.user, .assistant, .user])
        #expect(r.turns[1].text == "第一条\n\n第二条")
        #expect(r.turns[2].text.hasPrefix("（回复：第一条）"))
    }

    @Test func leadingAssistantGetsAStart() {
        let r = Prompt.build(input(sampleContact(), history: [Message(role: .assistant, text: "你来了。"), Message(role: .user, text: "嗯")]))
        #expect(r.turns.first?.role == .user)
        #expect(r.turns.count == 3)
    }

    @Test func imageOnLastUserTurn() {
        let r = Prompt.build(input(sampleContact(), history: [Message(role: .user, text: "看")], image: Data([1])))
        #expect(r.turns.last?.imageJPEG == Data([1]))
    }

    @Test func english() {
        let s = Prompt.build(input(sampleContact(), lang: .en)).system
        #expect(s.contains("You have your own feelings") && s.contains("You're online") && s.contains("You are Lumi"))
    }

    @Test func offlineLifeSwitchesTheOwnDayLine() {
        var c = sampleContact()
        func sys() -> String { Prompt.build(input(c)).system }
        #expect(sys().contains("吃饭、出门") && !sys().contains("{life}"))          // 老数据（nil）照旧有自己的一天
        c.offlineLife = false
        #expect(sys().contains("你的日子就是和对方说话的这些时候") && !sys().contains("出门"))
        c.mode = ChatMode.offline
        #expect(!sys().contains("你的日子就是"))                                       // 线下那段不受影响
    }

    @Test func customTalkRulesReplaceTheFactoryOnes() {
        var c = sampleContact()
        #expect(Prompt.build(input(c)).system.contains("大多数时候回一两句就够") && !Prompt.build(input(c)).system.contains("{talk}"))
        c.talkRules = "每次都写满三段，多用颜文字。"
        let s = Prompt.build(input(c)).system
        #expect(s.contains("每次都写满三段，多用颜文字。") && !s.contains("大多数时候回一两句就够"))
        #expect(s.contains("一条消息一段"))                                   // 分段发消息是机制，不归用户换
        c.talkRules = "  "
        #expect(Prompt.build(input(c)).system.contains("大多数时候回一两句就够"))
    }
}

/// 本体化（11-03 Aporia）：我们加的风格都去掉，用户自己写的照用，功能照留。跟 Host test_bare_mode_* 同一组
@Suite struct BareModeTests {
    func input(_ c: Contact) -> PromptInput {
        PromptInput(contact: c, identity: c.mainIdentity, history: [], stickers: [Sticker(sha: "a", file: "a.png", caption: "猫猫比心")],
                    lang: .zh, now: Date(timeIntervalSince1970: 1_791_000_000), timeZone: TimeZone(identifier: "Asia/Singapore")!)
    }

    @Test func dropsOurVoiceKeepsFeatures() {
        var c = sampleContact()
        c.bare = true
        c.relationshipPack = Relationship.pack("partner", zh: true)
        c.identities[0].relationship = "恋人"
        let s = Prompt.build(input(c)).system
        #expect(s.hasPrefix("这是一个聊天 app，你在里面跟对方说话。"))
        #expect(!s.contains("住在手机 app 里") && !s.contains("你有自己的情绪") && s.contains("对方发来图片，你看得见。"))
        #expect(s.contains("[表情包：#编号]") && s.contains("⟪里程碑") && s.contains("⟪想查手机") && s.contains("猫猫比心"))   // 功能照留
        #expect(s.contains("你们的关系：恋人") && !s.contains("撒娇"))
        #expect(s.contains("现在是线上") && s.contains("写纯文字") && !s.contains("一两句就够") && !s.contains("嗯」「行」"))
        c.talkRules = "不用敬语"
        #expect(Prompt.build(input(c)).system.contains("不用敬语"))          // 用户自己写的说话规矩照用
        c.mode = .offline
        let off = Prompt.build(input(c)).system
        #expect(off.contains("现在是线下") && off.contains("*单星号*") && !off.contains("三到六段"))
        #expect(!Handbook.text(zh: true, online: true, life: false, memoryTools: nil, bare: true).contains("说话再补几条"))
    }

    @Test func monologueAndInnerVoiceStayAsFormat() {
        let r = Monologue.rules(zh: true, pronoun: "她", style: "", bare: true)
        #expect(r.contains("[独白] 和 [/独白]") && r.contains("先调工具") && !r.contains("范文") && !r.contains("怎么想") && !r.contains("没有听众") && !r.contains("打草稿"))
        #expect(Monologue.rules(zh: true, pronoun: "她", style: "想得慢一点", bare: true).contains("怎么想：\n想得慢一点"))
        let v = InnerVoice.rules(zh: true, pronoun: "她", style: "", bare: true)
        #expect(v.contains("[心声] 和 [/心声]") && !v.contains("诚实、直白") && !v.contains("只写这一轮"))
        #expect(InnerVoice.rules(zh: true, pronoun: "她", style: "只写一句", bare: true).contains("只写一句"))
    }

    @Test func ownExamplesReplaceOurs() {
        let r = Monologue.rules(zh: true, pronoun: "她", style: "", examples: "她今天话很少。")
        #expect(r.contains("范文（照这个写法，内容别照抄）：\n\n[独白]\n她今天话很少。\n[/独白]") && !r.contains("可乐鸡翅"))
        #expect(Monologue.rules(zh: true, pronoun: "她", style: "", bare: true, examples: "[独白]\n嗯。\n[/独白]").hasSuffix("[独白]\n嗯。\n[/独白]"))
        #expect(Monologue.rules(zh: true, pronoun: "她", style: "").contains("可乐鸡翅"))         // 没写就是我们的
    }
}
