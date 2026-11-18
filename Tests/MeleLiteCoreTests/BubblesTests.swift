import Testing
@testable import MeleLiteCore

/// 跟 Mele 服务器同一套： tests/test_bubbles.py 的例子（我们自己的规则），输入输出一字不差。
@Suite struct BubblesTests {
    @Test func blankLinesMakeBubbles() {
        #expect(Bubbles.split("早呀\n\n今天怎么样？\n\n\n我在。") == ["早呀", "今天怎么样？", "我在。"])
    }
    @Test func shortParagraphKeptWhole() {
        let p = "我今天去了海边。风很大。"
        #expect(Bubbles.split(p) == [p])
    }
    @Test func longParagraphSplitAtSentenceEnds() {
        let p = String(repeating: "这是一句话，里面有一些字。", count: 30)
        let out = Bubbles.split(p, cap: nil)
        #expect(out.count == 4 && out.allSatisfy { $0.count <= 120 })
        #expect(out.joined() == p && out.allSatisfy { $0.hasSuffix("。") })
    }
    @Test func closingQuoteStaysWithSentence() {
        #expect(Bubbles.sentences("她说：「好。」然后走了。") == ["她说：「好。」", "然后走了。"])
        #expect(Bubbles.sentences("真的吗？！太好了") == ["真的吗？！", "太好了"])
    }
    @Test func englishRejoinedWithSpaces() {
        let p = String(repeating: "This is a sentence that goes on. ", count: 12).trimmingCharacters(in: .whitespaces)
        let out = Bubbles.split(p, cap: nil)
        #expect(out.count > 1 && out.joined(separator: " ") == p)
    }
    @Test func rawHTMLPageGetsFencedAndStaysWhole() {
        let page = "<!DOCTYPE html>\n<html lang=\"zh\">\n<head><title>猜词</title></head>\n<body>" + String(repeating: "<p>猜错了范围会收窄！再来一次？</p>\n", count: 20) + "</body>\n</html>"
        let out = Bubbles.split("写好了，在下面。\n\n代码在下面，可以整段复制：\n\n" + page + "\n\n玩得开心！")
        #expect(out == ["写好了，在下面。", "代码在下面，可以整段复制：", "```html\n" + page + "\n```", "玩得开心！"])
    }
    @Test func fencedHTMLUntouched() {
        let t = "看：\n\n```html\n<!doctype html><html><body>hi</body></html>\n```"
        #expect(Bubbles.fenceRawHTML(t) == t)
        #expect(Bubbles.fenceRawHTML("我们聊聊 HTML 吧！") == "我们聊聊 HTML 吧！")
    }
    @Test func offlineDoesNotSplit() {
        let p = String(repeating: "这是一句话，里面有一些字。", count: 30)
        #expect(Bubbles.split(p, offline: true) == [p])
    }
    @Test func tagOnlyMergesBack() {
        #expect(Bubbles.split("好的\n\n<mood>calm</mood>") == ["好的 <mood>calm</mood>"])
    }
    @Test func balanceEvenly() {
        let ten = String(repeating: "一", count: 10)
        let three = [ten, ten, ten].joined(separator: "\n\n")
        #expect(Bubbles.balance(Array(repeating: ten, count: 9), cap: 3) == [three, three, three])
    }
    @Test func balanceKeepsOrderAndMinimisesLargest() {
        let x = String(repeating: "x", count: 100), y = String(repeating: "y", count: 10)
        let z = String(repeating: "z", count: 10), w = String(repeating: "w", count: 10)
        #expect(Bubbles.balance([x, y, z, w], cap: 2) == [x, [y, z, w].joined(separator: "\n\n")])
    }
    @Test func underCapUntouched() {
        #expect(Bubbles.balance(["a", "b"], cap: nil) == ["a", "b"])
        #expect(Bubbles.balance(["a", "b"], cap: 6) == ["a", "b"])
    }
    @Test func respectsCapAndLosesNothing() {
        let text = (0..<10).map { "第\($0)段" }.joined(separator: "\n\n")
        let out = Bubbles.split(text, cap: 4)
        #expect(out.count == 4 && out.joined(separator: "\n\n") == text)
    }
    @Test func capOneMergesAll() {
        #expect(Bubbles.split("一\n\n二\n\n三", cap: 1) == ["一\n\n二\n\n三"])
    }
    @Test func empty() { #expect(Bubbles.split("   ").isEmpty) }
    @Test func typingDelay() {
        #expect(Bubbles.typingDelay("") == 0.4)
        #expect(Bubbles.typingDelay(String(repeating: "字", count: 1000)) == 2.5)
    }
}
