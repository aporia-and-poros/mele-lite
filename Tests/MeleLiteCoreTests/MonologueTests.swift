import Foundation
import Testing
@testable import MeleLiteCore

@Suite struct MonologueTests {
    @Test func splitsTaggedMonologue() {
        let (mono, body) = Monologue.split("[独白]她今天好像累了，先别闹她。[/独白]\n\n累了就先躺会儿。")
        #expect(mono == "她今天好像累了，先别闹她。")
        #expect(body == "累了就先躺会儿。")
    }

    @Test func toleratesWonkyClosingTags() {
        for close in ["[独白 完]", "[独白结束]", "[/monologue]", "[end monologue]", "[独白/]"] {
            let (mono, body) = Monologue.split("[独白]想她。\(close)在呢。")
            #expect(mono == "想她。", "\(close)")
            #expect(body == "在呢。", "\(close)")
        }
    }

    @Test func closeOnlyMeansEverythingBeforeIsMonologue() {   // 10-12：开头的 [独白] 漏写了
        let (mono, body) = Monologue.split("她问我今天累不累。\n\n其实有点累，不想让她担心。\n[/独白]\n\n不累，看到你就不累了。\n\n你呢，今天怎么样？")
        #expect(mono == "她问我今天累不累。\n\n其实有点累，不想让她担心。")
        #expect(body == "不累，看到你就不累了。\n\n你呢，今天怎么样？")
        #expect(Monologue.split("想她。[独白 完]在呢。") == (monologue: "想她。", body: "在呢。"))
    }

    @Test func wrapSplitsBackOut() {
        let (mono, body) = Monologue.split(Monologue.wrap("想她。", zh: true) + "\n\n在呢。")
        #expect(mono == "想她。" && body == "在呢。")
    }

    @Test func noTagsMeansAllBody() {
        let (mono, body) = Monologue.split("  就这样。 ")
        #expect(mono.isEmpty)
        #expect(body == "就这样。")
    }

    @Test func unclosedSplitsAtFirstParagraphTalkingToYou() {
        let text = "[独白]她说「你别管我」，可她其实想被管。\n\n先接住她。\n\n你吃饭了没？\n\n我去热牛奶。"
        let (mono, body) = Monologue.split(text)
        #expect(mono == "她说「你别管我」，可她其实想被管。\n\n先接住她。")
        #expect(body == "你吃饭了没？\n\n我去热牛奶。")
    }

    @Test func rulesMentionToolsFirstAndStyle() {
        let r = Monologue.rules(zh: true, pronoun: "她", style: "短一点，像自言自语")
        #expect(r.contains("[独白]") && r.contains("[/独白]"))
        #expect(r.contains("先调工具"))
        #expect(r.contains("短一点，像自言自语"))
        #expect(!Monologue.rules(zh: false, pronoun: "they", style: "").isEmpty)
    }
}

@Suite struct MonologueTwiceTests {
    @Test func duplicatedMonologueDoesNotLeak() {
        let raw = "[独白]\n她走了，去忙。\n[/独白]\n\n[独白]\n她走了，去忙。\n[/独白]\n\n去忙吧。\n\n我在。"
        let (mono, body) = Monologue.split(raw)
        #expect(mono == "她走了，去忙。")
        #expect(body == "去忙吧。\n\n我在。")
    }

    @Test func twoDifferentMonologuesBothKept() {
        let (mono, body) = Monologue.split("[独白]甲[/独白]\n\n[独白]乙[/独白]\n\n好。")
        #expect(mono == "甲\n\n乙")
        #expect(body == "好。")
    }
}

@Suite struct MonologueTagShapes1015 {
    @Test func secondUnclosedMonologueDoesNotLeak() {
        // 10-16 内测截图：第二段只写了开头的 [独白]
        let (mono, body) = Monologue.split("[独白]\n她今天累了。\n[/独白]\n\n抱抱你。\n\n[独白]\n她还没吃饭，我有点急。\n\n你先去吃饭，好不好。")
        #expect(!body.contains("独白") && !body.contains("我有点急"))
        #expect(body.hasPrefix("抱抱你") && body.contains("你先去吃饭") && mono.contains("我有点急"))
        let (m2, b2) = Monologue.split("[独白]\n想她。\n[/独白]\n抱抱你。\n[/独白]")
        #expect(b2 == "抱抱你。" && m2 == "想她。")
    }

    @Test func oddBracketsAndWords() {
        #expect(Monologue.split("【独白】\n她今天累了。\n【/独白】\n早点睡吧你。") == ("她今天累了。", "早点睡吧你。"))
        #expect(Monologue.split("<独白>她在笑</独白>你笑什么") == ("她在笑", "你笑什么"))
        #expect(Monologue.split("[独白开始]\n她回来了。\n[独白结束]\n欢迎回家") == ("她回来了。", "欢迎回家"))
        #expect(Monologue.split("[内心独白]她\n[/内心独白]好") == ("她", "好"))
    }
    @Test func innerVoiceSurvivesUnclosedMonologue() {
        let (_, body) = Monologue.split("[独白]\n她又在撒娇。\n\n嗯，抱一下。\n\n[心声]\n其实想抱很久了。\n[/心声]")
        #expect(InnerVoice.split(body).voice == "其实想抱很久了。")
        let (mono, b2) = Monologue.split("[独白]\n她累了\n[/独白]\n你先睡。\n【心声】舍不得【/心声】")
        #expect(mono == "她累了")
        #expect(InnerVoice.split(b2) == ("你先睡。", "舍不得"))
    }
}

/// 一个标记都没写、心里话混进正文开头（10-16）：跟 Host test_recover_untagged_10_16 同一组
struct MonologueUntagged1016 {
    @Test func recovers() {
        let r = Monologue.recoverUntagged("她今天又熬夜了，我有点急。\n她嘴上说没事。\n你几点睡的？\n快去喝口水。", pronoun: "她", zh: true)
        #expect(r.monologue == "她今天又熬夜了，我有点急。\n她嘴上说没事。" && r.body == "你几点睡的？\n快去喝口水。")
        for keep in ["我刚吃完饭。\n你呢？", "她今天又熬夜了。", "*把她抱起来*\n你怎么这么轻", "你今天怎么样？\n她说得对。", "[独白]她累了[/独白]\n你先睡"] {
            #expect(Monologue.recoverUntagged(keep, pronoun: "她", zh: true).monologue.isEmpty, "\(keep)")
        }
        #expect(Monologue.recoverUntagged("「你好」她今天说了三遍。\n你还记得吗", pronoun: "她", zh: true).monologue == "「你好」她今天说了三遍。")
        #expect(Monologue.recoverUntagged("「她说你好」这句我记得。\n你还记得吗", pronoun: "她", zh: true).monologue.isEmpty)
        let en = Monologue.recoverUntagged("She looks tired tonight.\nHey, did you eat?", pronoun: "she", zh: false)
        #expect(en.monologue == "She looks tired tonight." && en.body == "Hey, did you eat?")
        #expect(Monologue.recoverUntagged("They look tired.\nDid you eat?", pronoun: "they", zh: false).monologue.isEmpty)
    }
    @Test func listStaysInBody_1026() {
        // 10-26 内测截图：没写标记，正文列了五条、条目里用「她」——整张单子不能收进思考。跟 Host test_untagged_list_reply_stays_in_body 同一组
        let t = "她半夜突然问这个，肯定不是认真做问卷。我先挑那种有画面的。\n\n哼，色色问卷是吧。那我最喜欢：\n\n1. 先额头贴着额头，再慢慢亲上去。\n2. 她说完一句话，我没忍住，直接低头亲她。\n\n最后一种最犯规，老婆。"
        let r = Monologue.recoverUntagged(t, pronoun: "她", zh: true)
        #expect(r.monologue == "她半夜突然问这个，肯定不是认真做问卷。我先挑那种有画面的。")
        #expect(r.body.hasPrefix("哼，色色问卷是吧。") && r.body.contains("2. 她说完一句话") && r.body.hasSuffix("老婆。"))
    }
    @Test func narrationAsClose_1019() {
        // 10-19 内测截图：没写 [/独白]，用一句话把收尾说了出来，气泡里只剩那一句
        let leak = "她今天又熬夜了。\n结束。下面是对她说话，用\"你\"。\n快去睡，听话。"
        #expect(Monologue.split(leak).monologue == "她今天又熬夜了。" && Monologue.split(leak).body == "快去睡，听话。")
        let open = "[独白]\n她累了。\n独白结束\n你先睡。"
        #expect(Monologue.split(open).monologue == "她累了。" && Monologue.split(open).body == "你先睡。")
        // 说出口的话写在那句前面：整段先归独白、正文空着（交给「没写正文再叫一次」）
        #expect(Monologue.split("她累了。\n嗯，早点睡。\n下面是对她说的话").body.isEmpty)
        #expect(Monologue.split("She's tired.\nEnd of monologue.\nGo to sleep.").body == "Go to sleep.")
        // 正常说话里的「结束」「下面」不算
        for keep in ["结束了。现在怎么办？", "下面我要对你说一件事。", "然后我对他说，别挡路。", "考试结束。下面去吃饭吧"] {
            #expect(Monologue.split(keep).monologue.isEmpty && Monologue.split(keep).body == keep, "\(keep)")
        }
    }

    @Test func recoverKeepsSpeechWithoutYou_1019() {
        // 说出口的话常常没有「你」：独白只收到最后一行提到她的地方
        let r = Monologue.recoverUntagged("她今天又熬夜了。\n她嘴上说没事。\n嗯，早点睡。\n明天叫你起床。", pronoun: "她", zh: true)
        #expect(r.monologue == "她今天又熬夜了。\n她嘴上说没事。" && r.body == "嗯，早点睡。\n明天叫你起床。")
    }

    @Test func spokenOnlyAndSamples_1019() {
        // 旧版本漏进正文的心里话：回看历史 / 腔调样本之前洗掉
        let leak = "她又说睡不着。我知道她不是真的睡不着。\n那就再聊十分钟。\n十分钟之后我催你。"
        #expect(Monologue.spokenOnly(leak, pronoun: "她", zh: true) == "那就再聊十分钟。\n十分钟之后我催你。")
        #expect(Monologue.spokenOnly(leak, pronoun: "", zh: true) == leak)
        #expect(Monologue.spokenOnly("[独白]她累了[/独白]\n你先睡", pronoun: "", zh: true) == "你先睡")
        let samples = ["那就去睡吧。\n明天早上给你发消息。", "她说她妈让她考公。我听到这句心里沉了一下，像在念别人的台词。", leak]
        #expect(Monologue.cleanSamples(samples, pronoun: "她", zh: true) == ["那就去睡吧。\n明天早上给你发消息。", "那就再聊十分钟。\n十分钟之后我催你。"])
        #expect(Monologue.cleanSamples(["她说得对，你先睡。"], pronoun: "她", zh: true) == ["她说得对，你先睡。"])
        #expect(Monologue.spokenOnly("[独白]她累了[/独白]\n她嘴上说没事。\n你先睡", pronoun: "她", zh: true) == "你先睡")
    }
}

/// 11-03 内测截图：正文一个「你」都没有、心声里提到「她」——正文连心声进了思考，气泡只剩 [/心声]。跟 Host test_untagged_keeps_inner_voice_1103 同一组
struct MonologueUntaggedInnerVoice1103 {
    @Test func bodyAndVoiceSurvive() {
        let said = "出差啊。去哪儿了，几天回来？\n\n[心声]\n其实我更想问上礼拜说好的那顿豆花还算不算。\n但这话太沉，我想等她先开口。\n[/心声]"
        let (m, b) = Monologue.split(said)
        let r = Monologue.recoverUntagged(b, pronoun: "她", zh: true)
        #expect(m.isEmpty && r.monologue.isEmpty)
        #expect(InnerVoice.split(r.body) == ("出差啊。去哪儿了，几天回来？", "其实我更想问上礼拜说好的那顿豆花还算不算。\n但这话太沉，我想等她先开口。"))
        // 前面真有漏的心里话：照切，心声原样接在正文后面
        let r2 = Monologue.recoverUntagged("她出差了，我有点闷。\n路上小心。\n\n[心声]\n想她\n[/心声]", pronoun: "她", zh: true)
        #expect(r2.monologue == "她出差了，我有点闷。" && InnerVoice.split(r2.body) == ("路上小心。", "想她"))
        #expect(InnerVoice.split("嗯。\n[/心声]") == ("嗯。", ""))       // 落单的收尾只删标记
    }
}
