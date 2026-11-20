import Foundation
import Testing
@testable import MeleLiteCore

/// 世界书导入（10-11）：酒馆世界书 JSON、character_book、整张卡、txt。测试用小满。
@Suite struct LoreImportTests {
    func json(_ o: Any) -> Data { try! JSONSerialization.data(withJSONObject: o) }

    @Test func tavernWorldInfo() throws {
        let wi: [String: Any] = ["entries": [
            "1": ["key": ["雾港"], "keysecondary": ["港口"], "content": "{{char}} 住在雾港", "comment": "雾港", "disable": true],
            "0": ["key": ["灯塔"], "content": "灯塔在北边", "comment": "灯塔", "constant": true],
            "2": ["key": ["a"], "content": "关键词太短"],
        ]]
        let (es, skipped) = try LoreImport.parse(json(wi), fileName: "w.json", charName: "林晚", userName: "小满", lang: .zh)
        #expect(es.map(\.title) == ["灯塔", "雾港"])                 // 按序号排
        #expect(es[0].constant && es[0].enabled)
        #expect(es[1].keys == ["雾港", "港口"] && !es[1].enabled && es[1].content == "林晚 住在雾港")
        #expect(skipped == 1)
    }

    @Test func characterBookAndCard() throws {
        let book: [String: Any] = ["entries": [["keys": ["画室"], "content": "画室在三楼", "comment": "画室"]]]
        #expect(try LoreImport.parse(json(book), fileName: "b.json", charName: "", userName: "", lang: .zh).entries.count == 1)
        let card: [String: Any] = ["spec": "chara_card_v2", "data": ["name": "林晚", "character_book": book]]
        #expect(try LoreImport.parse(json(card), fileName: "c.json", charName: "", userName: "", lang: .zh).entries.first?.keys == ["画室"])
        #expect(throws: CardError.self) { try LoreImport.parse(json(["name": "x"]), fileName: "x.json", charName: "", userName: "", lang: .zh) }
    }

    @Test func textBlankLines() throws {
        let txt = """
        # 雾港
        关键词：雾港、港口
        常年起雾的港口城市。
        小满小时候在这里长大。

        灯塔
        北边的旧灯塔，晚上会亮。

        暗号：说「今天月亮很圆」就是想你了

        这一段只有一句很长很长很长很长很长很长很长很长的话，没有冒号能拆
        """
        let (es, skipped) = try LoreImport.parse(Data(txt.utf8), fileName: "w.txt", charName: "", userName: "", lang: .zh)
        #expect(es.map(\.title) == ["雾港", "灯塔", "暗号"])
        #expect(es[0].keys == ["雾港", "港口"] && es[0].content == "常年起雾的港口城市。\n小满小时候在这里长大。")
        #expect(es[1].keys == ["灯塔"])
        #expect(es[2].content == "说「今天月亮很圆」就是想你了")
        #expect(skipped == 1)
    }

    @Test func textRules() throws {
        let txt = "雾港\n第一段\n\n还是雾港这条\n---\n灯塔\nkeys: lighthouse, 灯塔\n北边"
        let es = try LoreImport.parse(Data(txt.utf8), fileName: "w.txt", charName: "", userName: "", lang: .zh).entries
        #expect(es.count == 2)
        #expect(es[0].content == "第一段\n还是雾港这条")
        #expect(es[1].keys == ["lighthouse", "灯塔"])
    }

    @Test func gbkText() throws {
        let gb = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        let data = "灯塔\n北边的旧灯塔".data(using: String.Encoding(rawValue: gb))!
        #expect(String(data: data, encoding: .utf8) == nil)
        #expect(try LoreImport.parse(data, fileName: "w.txt", charName: "", userName: "", lang: .zh).entries.first?.content == "北边的旧灯塔")
    }

    @Test func utf16Text() throws {
        // Windows 记事本存成「Unicode」：UTF-16 LE + BOM + CRLF（10-14 内测）
        let txt = "灯塔\r\nkeys: lighthouse\r\n北边的旧灯塔"
        var le = Data([0xFF, 0xFE]); le.append(txt.data(using: .utf16LittleEndian)!)
        var be = Data([0xFE, 0xFF]); be.append(txt.data(using: .utf16BigEndian)!)
        let bare = "lighthouse\nthe old one up north".data(using: .utf16LittleEndian)!
        for d in [le, be] {
            let e = try LoreImport.parse(d, fileName: "w.txt", charName: "", userName: "", lang: .zh).entries.first
            #expect(e?.title == "灯塔" && e?.keys == ["lighthouse"] && e?.content == "北边的旧灯塔")
        }
        #expect(try LoreImport.parse(bare, fileName: "w.txt", charName: "", userName: "", lang: .en).entries.first?.content == "the old one up north")
    }

    @Test func utf8WithAFewBadBytes() throws {
        // 网盘下的小说：整本 UTF-8，中间混了一个坏字节（10-16 内测）——照 UTF-8 读，不能当 GBK 读成乱码
        var d = Data(String(repeating: "第一章 灯塔\n北边的旧灯塔亮了一夜。\n", count: 200).utf8)
        d.insert(0xFF, at: 3000)
        let t = try #require(LoreImport.decodeText(d))
        #expect(t.hasPrefix("第一章 灯塔") && t.contains("\u{FFFD}"))
        // 真 GBK 的照旧按 GBK
        let gb = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        #expect(LoreImport.decodeText("北边的旧灯塔".data(using: String.Encoding(rawValue: gb))!) == "北边的旧灯塔")
        // UTF-8 带 BOM 的不留 BOM
        #expect(LoreImport.decodeText(Data([0xEF, 0xBB, 0xBF]) + Data("灯塔".utf8)) == "灯塔")
    }

    @Test func numberedList() throws {
        // 前面两小段 1. 2. 3. 是写给模型的规则，后面是一长串编号的词条
        var lines = ["## 用法", "1. **偶尔用，别每句都用**", "", "2. **看场合**", "", "3. **别照抄**", "",
                     "### 反思", "1. 我有没有用太多？", "2. 合不合适？", "3. 有没有更好的说法？", "",
                     "以下是清单：", "",
                     "1.欧坤：OK 的音译", "如：欧坤呀",
                     "2.不按常理出牌→倒反天罡",
                     "3.牛逼说成牛福",
                     "4.那很**了/那很诡异了",
                     "5.\u{200C}你见过人**不",
                     "6.这期神了/没绷住（指太好笑）"]
        lines += (7...12).map { "\($0).小满第\($0)个梗：意思\($0)" }
        lines += ["### 结尾", "别滥用"]
        let es = try LoreImport.parse(Data(lines.joined(separator: "\r\n").utf8), fileName: "m.txt", charName: "", userName: "", lang: .zh).entries
        #expect(es.count == 12)
        #expect(es[0].title == "欧坤" && es[0].keys == ["欧坤"] && es[0].content == "欧坤：OK 的音译\n如：欧坤呀")
        #expect(es[1].keys == ["不按常理出牌", "倒反天罡"])
        #expect(es[2].keys == ["牛逼", "牛福"])
        #expect(es[3].keys == ["那很诡异了"])                       // 「那很**了」拆出来的「那很」太碎，不要
        #expect(es[4].keys == ["你见过人"])
        #expect(es[5].keys == ["这期神了", "没绷住"])
        #expect(es[11].content == "小满第12个梗：意思12")             // 「### 结尾」收住，「别滥用」不接上来
        // 编号行太少就照旧按空行分段
        #expect(try LoreImport.parse(Data("1. 灯塔\n北边\n\n2. 雾港\n南边".utf8), fileName: "w.txt", charName: "", userName: "", lang: .zh).entries.count == 2)
    }

    // 11-19：整份导入——每段第一行都是长句、没写关键词，拆的话一条都读不到
    @Test func wholeFile() throws {
        let para = "这座城市叫雾港，常年起雾，{{user}}小时候在这里长大，后来去了北边念书，再也没有回来过很多年。"
        let txt = Array(repeating: para, count: 3).joined(separator: "\n\n")
        #expect(try LoreImport.parse(Data(txt.utf8), fileName: "雾港设定.txt", charName: "", userName: "", lang: .zh).entries.isEmpty)
        let one = LoreImport.whole(txt, fileName: "雾港设定.txt", charName: "", userName: "小满", lang: .zh)
        #expect(one.count == 1 && one[0].title == "雾港设定" && one[0].keys == ["雾港设定"] && one[0].constant)
        #expect(one[0].content.contains("小满小时候") && one[0].content.contains("\n\n"))

        // 长的切块：每块 ≤ 2000，切口落在段落上，拼回去一个字不少
        let long = (0..<60).map { "第\($0)段：" + String(repeating: "雾", count: 80) }.joined(separator: "\n\n")
        let parts = LoreImport.whole(long, fileName: "w.txt", charName: "", userName: "", lang: .zh)
        #expect(parts.count > 1 && parts.allSatisfy { $0.content.count <= 2000 && $0.constant })
        #expect(parts.allSatisfy { $0.content.hasPrefix("第") })
        #expect(parts[0].title == "w 1/\(parts.count)" && parts[0].keys == ["设定"])     // 「w」一个字母当不了关键词
        #expect(parts.map(\.content).joined(separator: "\n\n") == long)

        // 一行就超长：硬切
        let line = String(repeating: "雾", count: 4500)
        #expect(LoreImport.whole(line, fileName: "a.txt", charName: "", userName: "", lang: .zh).map(\.content.count) == [2000, 2000, 500])
        #expect(LoreImport.whole(" \n ", fileName: "a.txt", charName: "", userName: "", lang: .zh).isEmpty)
    }
}
