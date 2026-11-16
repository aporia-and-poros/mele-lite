import Foundation

/// 回复里的网页挑出来（11-16）。跟 App/HTMLBlock.swift 一起用 swiftc 编：ios/tests/run.sh
@main
struct HTMLBlockTests {
    static func check(_ ok: Bool, _ what: String) {
        if !ok { print("FAIL: \(what)"); exit(1) }
    }

    static func main() {
        let page = "<!doctype html><html><head><title>小游戏</title></head><body><button>点我</button></body></html>"
        // 代码块里的一页：前后的话留着，代码换成卡片
        var r = HTMLBlock.split("给你做了个小游戏：\n\n```html\n\(page)\n```\n\n玩玩看？")
        check(r.pages == [page], "fenced page picked")
        check(r.rest == "给你做了个小游戏：\n\n玩玩看？", "text around kept: \(r.rest)")
        check(HTMLBlock.title(r.pages[0]) == "小游戏", "title read")
        // 整条就是一页
        r = HTMLBlock.split(page)
        check(r.pages == [page] && r.rest.isEmpty, "bare page")
        // 讲语法的小片段不算
        r = HTMLBlock.split("用 ```html\n<b>粗</b>\n``` 就能加粗")
        check(r.pages.isEmpty, "tiny snippet ignored")
        // 别的语言的代码块不动
        r = HTMLBlock.split("```python\nprint('<html>')\n```")
        check(r.pages.isEmpty, "python untouched")
        // 两页
        let frag = "<div style='color:red'>第二页的内容，够长够长够长够长</div>"
        r = HTMLBlock.split("一\n```html\n\(page)\n```\n二\n```html\n\(frag)\n```")
        check(r.pages.count == 2 && r.rest == "一\n\n二", "two pages: \(r.rest)")
        check(HTMLBlock.title(frag) == "一页网页", "default title")
        check(HTMLBlock.document(frag).contains("<html>") && HTMLBlock.document(page) == page, "document wrap")
        print("html block ok")
    }
}
