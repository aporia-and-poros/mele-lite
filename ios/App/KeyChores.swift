import SwiftUI

/// 钥匙串分活（10-15）：活儿的名字、分组，和点开一把钥匙的活儿单。文案用「TA」。
enum ChoreNames {
    static let main = ["vision", "draw", "ledger"]
    static let media = ["vision", "draw"]          // 10-16：在 Me 的「看图和画图」卡里挑，勾选单里不放
    static var sheet: [String] { main.filter { !media.contains($0) } }
    static let odd = ["dedupe", "food", "caption", "import", "music", "translate"]
    static let own = ["diary", "day", "moments", "tarot", "focus"]

    static func label(_ c: String) -> String {
        [
            "vision": String(localized: "看图"), "draw": String(localized: "画图"), "ledger": String(localized: "写账本"),
            "dedupe": String(localized: "小判断"), "food": String(localized: "饮食估算"), "caption": String(localized: "配文和表情包描述"),
            "import": String(localized: "读导入的聊天"), "music": String(localized: "每日推歌"), "translate": String(localized: "翻译"),
            "diary": String(localized: "日记"), "day": String(localized: "TA 的一天"), "moments": String(localized: "朋友圈和相册"),
            "tarot": String(localized: "解牌"), "focus": String(localized: "专注点评"), "voice": String(localized: "声音"),
        ][c] ?? c
    }

    static func note(_ c: String) -> String? {
        [
            "vision": String(localized: "TA 的模型看不见图时，先给这把看、写段描述递给 TA"),
            "ledger": String(localized: "卷账本、压旧天；写不好会换回聊天那把再试"),
            "diary": String(localized: "日记，还有 TA 给你留的信"),
            "translate": String(localized: "双语气泡、思考链翻译"),
            "dedupe": String(localized: "记忆判重、想起旧事前先听懂、群聊谁接话"),
        ][c]
    }

    /// 标签一排：大类合并显示（杂活勾了几样就写「杂活 3」）
    static func tags(_ chores: [String]) -> [String] {
        var out = main.filter(chores.contains).map(label)
        let n = chores.filter { odd.contains($0) || own.contains($0) }.count
        if n > 0 { out.append(String(localized: "杂活 \(n)")) }
        if chores.contains("voice") { out.append(label("voice")) }
        return out
    }
}

struct KeyChoresSheet: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var theme: AppTheme
    @Environment(\.dismiss) private var dismiss
    let key: KeyDTO
    let names: [String: String]          // 钥匙 id → 「DeepSeek」这种，挪活提示用
    let onChanged: () -> Void
    @State private var picked: Set<String> = []
    @State private var drawModel = ""
    @State private var chatModel = ""
    @State private var openOdd = false
    @State private var note: String?

    struct Saved: Decodable {
        struct Move: Decodable { let chore: String; let fromKey: String
            enum CodingKeys: String, CodingKey { case chore; case fromKey = "from_key" } }
        let moved: [Move]
    }

    var body: some View {
        NavigationStack {
            Form {
                if key.provider == "elevenlabs" {
                    Section { Label(ChoreNames.label("voice"), systemImage: "checkmark") } footer: {
                        Text("ElevenLabs 只管声音。TA 的档位和嗓子在 TA 的设定 → 声音里挑。")
                    }
                } else {
                    Section {
                        TextField("模型名字", text: $chatModel)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    } header: { Text("聊天模型") } footer: {
                        Text("用这把钥匙聊天的 TA，下一句就换成这个模型。名字填错会聊不上，改回来就好。")
                    }
                    Section {
                        ForEach(ChoreNames.sheet, id: \.self) { row($0) }
                        DisclosureGroup(isExpanded: $openOdd) {
                            ForEach(ChoreNames.odd, id: \.self) { row($0) }
                            Text("TA 亲笔的（默认跟聊天）").font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkFaint)
                            ForEach(ChoreNames.own, id: \.self) { row($0) }
                        } label: {
                            Toggle(isOn: Binding(
                                get: { ChoreNames.odd.filter { key.can.contains($0) }.allSatisfy(picked.contains) },
                                set: { on in for c in ChoreNames.odd where key.can.contains(c) { if on { picked.insert(c) } else { picked.remove(c) } } }
                            )) { Text("后台杂活") }
                        }
                    } footer: {
                        Text("一样活只归一把钥匙；没勾的活用 TA 聊天那把。TA 亲笔的是 TA 本人在写，换便宜模型会变味，要单独勾。看图、画图在 Me 的「看图和画图」里直接填。")
                    }
                    if let note { Section { Text(note).foregroundStyle(theme.inkDim) } }
                }
            }
            .navigationTitle("\(KeychainCard.providerName(key.provider)) ··\(key.last4)")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("存") { Task { await save() } } }
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            }
            .onAppear { picked = Set(key.chores); drawModel = key.drawModel; chatModel = key.chatModel }
        }
    }

    private func row(_ c: String) -> some View {
        let ok = key.can.contains(c)
        return Toggle(isOn: Binding(get: { picked.contains(c) }, set: { if $0 { picked.insert(c) } else { picked.remove(c) } })) {
            VStack(alignment: .leading, spacing: 2) {
                Text(ChoreNames.label(c))
                if let n = ChoreNames.note(c) { Text(n).font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkFaint) }
                if !ok { Text("这家干不了").font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkFaint) }
            }
        }
        .disabled(!ok)
    }

    private func save() async {
        // 看图 / 画图不在这页改：这把原来有的照旧带上，别存的时候被抹掉
        let list = ChoreNames.media.filter(key.chores.contains) + ChoreNames.sheet.filter(picked.contains)
            + ChoreNames.odd.filter(picked.contains) + ChoreNames.own.filter(picked.contains)
        do {
            var body: [String: Any] = ["chores": list, "draw_model": drawModel]
            let m = chatModel.trimmingCharacters(in: .whitespacesAndNewlines)
            if key.provider != "elevenlabs", m != key.chatModel {
                guard !m.isEmpty else { note = String(localized: "要填一个聊天用的模型"); return }
                body["chat_model"] = m
            }
            let r: Saved = try await model.api.call("PATCH", "keys/\(key.id)", json: body)
            onChanged()
            if r.moved.isEmpty { dismiss(); return }
            note = r.moved.map { String(localized: "「\(ChoreNames.label($0.chore))」从 \(names[$0.fromKey] ?? "另一把") 那把挪过来了") }
                .joined(separator: "\n")
        } catch {
            note = (error as? APIError)?.message ?? String(localized: "没存上")
        }
    }
}
