import SwiftUI

/// TA 的设定 · 高级（第二块第 10 步）。每项一句人话；最上面一键同步给所有联系人，最底下删除这个联系人。
struct AdvancedSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var theme: AppTheme
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: CompanionSettingsStore
    let companion: CompanionDTO
    @State private var confirmSync = false
    @State private var synced: Int?
    @State private var confirmDelete = false
    @State private var deleteFailed: String?
    @State private var deleting = false

    /// 出厂的说话规矩（跟 MeleLiteCore Prompts/zh/modes.md 的 [talk]、服务器说明书「格式」那两条同一个意思）
    static var factoryTalk: String {
        Locale.current.language.languageCode?.identifier == "en"
            ? "Write the way you'd text someone you know; if it fits in one line, keep it to one.\nMost of the time a line or two is enough, like a quick text back: pick up what they just said, add a bit of your own reaction or ask one small thing, and stop. When they write a lot or it's something that matters, say more.\nOnline, you're just texting: say what you want to say straight out, every line is a line you actually send."
            : "像你平时给熟人发消息那样说话，能一句说完就一句。\n大多数时候回一两句就够，像随手回微信：接住对方这一句，加一点你自己的反应，或者问一件小事，就停。对方说得长、聊到要紧的事，你再多说几句。\n线上就是发消息：想说的直接说出来，一句是一句。"
    }

    private func note(_ s: String) -> some View {
        Text(s).font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkFaint)
    }

    private func row(_ title: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(Typo.sans(Typo.Size.body)).foregroundStyle(theme.ink)
            note(sub)
        }
    }

    var body: some View {
        TilePage {
          Group {
            if model.companions.count > 1 {
                Tile {
                    Button { confirmSync = true } label: {
                        Label("同步到全部联系人", systemImage: "arrow.triangle.2.circlepath").font(Typo.sans(Typo.Size.body))
                    }
                    if let synced { note(String(localized: "抄给了 \(synced) 个联系人")) }
                } footer: { Text("把这一页的设置抄给其他所有联系人；名字、性格、关系、钥匙不动。") }
            }

            Tile {
                Toggle(isOn: store.s("careful_read", true)) { row("细读", "想起来的旧事拿不准时，请便宜的模型再判一次") }
                Toggle(isOn: store.s("recall_probe", true)) { row("先听懂再翻", "翻记忆前先弄明白你在说什么（每句约 0.0003 美元）") }
            } header: { GlassHeader(String(localized: "联想")) }
            .needsHost()

            Tile {
                Stepper(value: store.s("reply_wait", 10), in: 0...60) {
                    row(String(localized: "等你说完再回 · \(store.settings["reply_wait"] as? Int ?? 10) 秒"),
                        "你连着发几条时，安静满这么久才回；0 = 马上回")
                }
                Stepper(value: Binding(get: { store.settings["max_bubbles"] as? Int ?? 0 },
                                       set: { store.optionalInt("max_bubbles").wrappedValue = $0 == 0 ? nil : $0 }),
                        in: 0...12) {
                    let n = store.settings["max_bubbles"] as? Int ?? 0
                    row(n == 0 ? String(localized: "每次最多 · 不限") : String(localized: "每次最多 \(n) 条"),
                        "一次回复最多切成几条消息")
                }
                // 说话规矩（10-05 Aporia：用户能自己改出厂的说话风格；分段发消息、记东西这些不归这里）
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        row("说话规矩", "日常聊天时说多长、怎么接话。空着用出厂的；写了就换成你的")
                        Spacer()
                        Button("看出厂的") { store.s("talk_rules", "").wrappedValue = Self.factoryTalk }
                            .font(Typo.sans(Typo.Size.caption, .medium)).foregroundStyle(theme.accentDeep).buttonStyle(.plain)
                    }
                    DraftTextEditor(text: store.s("talk_rules", ""))
                        .font(Typo.sans(Typo.Size.callout)).frame(minHeight: 90).scrollContentBackground(.hidden)
                }
            } header: { GlassHeader(String(localized: "回话")) } footer: {
                Text("说话规矩只管说话的样子；分段发消息、记东西、发表情包这些不受影响。线下（长文）有自己的写法，不看这里。")
            }

            Tile {
                Toggle(isOn: store.s("thinking", true)) { row("想事", "回话前先想一想（关了就没有思考过程）") }
                VStack(alignment: .leading, spacing: 14) {
                RowPicker(selection: Binding(get: { store.settings["thinking_mode"] as? String ?? "" },
                                          set: { store.setNow(settings: ["thinking_mode": $0.isEmpty ? NSNull() : $0]) })) {
                    Text("手写独白（默认）").tag("")
                    Text("模型自己的思考").tag("native")
                    Text("手写独白").tag("monologue")
                } label: { row("怎么想", Lite.on ? "手写独白 = TA 先把心里话写下来，你在思考里看得到；模型自己的思考多半是第三人称的摘要"
                                                 : "手写独白 = TA 先把心里话写下来；模型自己的思考多半是第三人称的摘要") }
                // 没打标记重写一次（10-26 Aporia：用人话说、默认关，碰上一次多花一次钱）
                if (store.settings["thinking_mode"] as? String ?? "") != "native" {
                    Toggle(isOn: store.s("monologue_retry", false)) {
                        row("忘了框心里话就重写", "TA 有时忘了把心里话框起来，App 只好猜哪段是心里话，偶尔会猜错：心里话跑进气泡，或者回复被收进思考。开了就让 TA 重写一遍，碰上的那次多花一次钱、多等几秒。DeepSeek 最常忘")
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    row("思考风格", Lite.on ? "手写独白时照这个写；空着就随 TA" : "空着用出厂的；写了就换成你的")
                    DraftTextEditor(text: store.s("thinking_style_text", ""))
                        .font(Typo.sans(Typo.Size.callout)).frame(minHeight: 90).scrollContentBackground(.hidden)
                }
                // 自己写的独白范文（11-03 Aporia）：换掉出厂那两段；本体化时也照用
                if (store.settings["thinking_mode"] as? String ?? "") != "native" {
                    VStack(alignment: .leading, spacing: 6) {
                        row("独白范文", "写一两段你想要的心里话的样子，TA 照这个写法写独白（内容不照抄）。空着用出厂的")
                        DraftTextEditor(text: store.s("monologue_examples", ""))
                            .font(Typo.sans(Typo.Size.callout)).frame(minHeight: 90).scrollContentBackground(.hidden)
                    }
                }
                // 回复后的心声（10-11 内测反馈）：说完以后在最后写几行心里话，聊天里是一张小卡片
                Toggle(isOn: store.s("inner_voice", false)) {
                    row("回复后的心声", "TA 说完话以后，在最后写几行心里话（嘴上没说的那部分），显示成一张小卡片")
                }
                if store.settings["inner_voice"] as? Bool ?? false {
                    VStack(alignment: .leading, spacing: 6) {
                        row("心声风格", "空着用出厂的；写了就换成你的")
                        DraftTextEditor(text: store.s("inner_voice_style", ""))
                            .font(Typo.sans(Typo.Size.callout)).frame(minHeight: 70).scrollContentBackground(.hidden)
                    }
                }
                }
            } header: { GlassHeader(String(localized: "思考")) }

            if store.keys.first(where: { $0.id == store.keyID })?.provider == "anthropic" {
                Tile {
                    Toggle(isOn: store.s("cache_keepalive", false)) {
                        row("缓存保活", "隔很久才聊也不用整段重算。你睡觉的时候停")
                    }
                } header: { GlassHeader(String(localized: "省钱")) } footer: {
                    Text("Claude 的缓存一小时没人用就过期，下次聊天要按两倍价重写一遍。开了以后，你没说话时每 55 分钟替你续一下，每次只花读缓存的钱（大约一次重写的二十分之一）。一天最多续 16 次。")
                }
                .needsHost()
            }

            if Lite.local {       // 说明书开关（10-08 Aporia：默认开）
                Tile {
                    Toggle(isOn: store.s("full_handbook", true)) {
                        row("完整说明书", "开着：告诉 TA 每轮递过去的小纸条（饮食、日子、在听……）是什么、怎么接；接了记忆库再加怎么记事")
                    }
                } header: { GlassHeader(String(localized: "说明书")) } footer: {
                    Text("关着只留最简短的规矩。开着每轮多一千字左右，大部分走缓存，多花得很少。")
                }
            }

            Tile {
                Toggle(isOn: store.s("ledger_same_as_chat", false)) { row("账本用聊天的模型", "默认用同一家便宜的写，开了更准也更贵") }
                    .hiddenInLite()          // Lite 本机的账本钥匙在上面「回声」那格
                ForEach([("thinking_style", "提醒思考风格", "隔几轮提醒 TA 想事的样子"),
                         ("tool_reminder", "提醒用工具", "隔几轮提醒 TA 该记的记下来"),
                         ("remembered", "〔记住了〕", "TA 记下东西后告诉 TA 一声")], id: \.0) { key, title, sub in
                    Toggle(isOn: sentinel(key)) { row(title, sub) }
                    if key == "thinking_style" {
                        // 10-11 Aporia：思考风格隔几轮提醒一次（1…12，默认 3；两种想法都按它，照之前自用的 App）
                        let n = store.settings["thinking_style_every"] as? Int ?? 3
                        VStack(alignment: .leading, spacing: 4) {
                            row(n == 1 ? String(localized: "每轮都提醒") : String(localized: "每 \(n) 轮提醒一次"),
                                "在最后贴一次思考风格的全文，离 TA 开口最近")
                            Slider(value: Binding(get: { Double(n) },
                                                  set: { store.setNow(settings: ["thinking_style_every": Int($0.rounded())]) }),
                                   in: 1...12, step: 1)
                                .tint(theme.accentDeep)
                        }
                        .disabled(!sentinel("thinking_style").wrappedValue)
                        .opacity(sentinel("thinking_style").wrappedValue ? 1 : 0.4)
                    }
                }
            } header: { GlassHeader(String(localized: "哨兵")) } footer: {
                // 10-08 Aporia：Lite 也要哨兵。后两个说的是记忆库的工具，没接记忆库时不贴
                if Lite.local { Text("提醒思考风格：按上面的轮数在最后贴一次全文（手写独白时风格本来就在设定里，这是怕聊久了忘了）。提醒用工具、〔记住了〕要接上记忆库才会贴。") }
            }

            Tile {
                let inj = injections
                ForEach(inj.indices, id: \.self) { i in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            TextField("名字", text: injBinding(i, "name", ""))
                                .font(Typo.sans(Typo.Size.body, .semibold))
                            Toggle("", isOn: injBinding(i, "enabled", true)).labelsHidden()
                        }
                        TextEditor(text: injBinding(i, "text", ""))
                            .font(Typo.sans(Typo.Size.callout)).frame(minHeight: 60).scrollContentBackground(.hidden)
                        Picker("什么时候塞", selection: injBinding(i, "mode", "every")) {
                            Text("每轮").tag("every")
                            Text("每几轮").tag("every_n")
                            Text("随机").tag("chance")
                            Text("说到某些词").tag("keywords")
                        }
                        .pickerStyle(.segmented)
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            var list = injections; list.remove(at: i); store.setNow(settings: ["injections": list])
                        } label: { Label("删掉", systemImage: "trash") }
                    }
                }
                Button {
                    var list = injections
                    list.append(["id": UUID().uuidString, "name": String(localized: "新的一段"), "text": "", "enabled": true, "mode": "every"])
                    store.setNow(settings: ["injections": list])
                } label: { Label("加一段", systemImage: "plus").font(Typo.sans(Typo.Size.body)) }
            } header: { GlassHeader(String(localized: "自定义注入")) } footer: { Text("每轮悄悄塞给 TA 的话，TA 看得到，你们的聊天里不显示。") }

            Tile {
                Toggle(isOn: store.s("heartbeat_on", true)) { row("心跳", "TA 隔一阵自己醒来想想要不要找你") }
                overrideStepper("day_gap_min", "白天间隔", "分钟", 10...1440, step: 10)
                overrideStepper("night_awake_max", "深夜你醒着，一晚最多找几次", "次", 0...20, step: 1)
                overrideStepper("asleep_gap_min", "你睡着时间隔（0 = 不叫醒）", "分钟", 0...1440, step: 15)
                overrideStepper("daily_cap", "一天最多醒几次", "次", 1...100, step: 1)
                if !(store.settings["patrol_overrides"] as? [String: Any] ?? [:]).isEmpty {
                    Button("回到档位的数字") { store.setNow(settings: ["patrol_overrides": [String: Any]()]) }
                        .font(Typo.sans(Typo.Size.body))
                }
            } header: { GlassHeader(String(localized: "巡逻的细数字")) } footer: { Text("不改就跟「多久来找你」那一档走。") }
            .needsHost()

            Tile {
                VStack(alignment: .leading, spacing: 6) {
                    row("导入人设", "贴一整份人设进来，替换出厂的性格")
                    DraftTextEditor(text: store.p("imported", ""))
                        .font(Typo.sans(Typo.Size.callout)).frame(minHeight: 90).scrollContentBackground(.hidden)
                }
            }

            if model.companions.count > 1 {
                Tile {
                    Button(role: .destructive) { confirmDelete = true } label: {
                        Text(deleting ? String(localized: "正在先留一份备份……") : String(localized: "删除 TA（所有窗口一起删）")).font(Typo.sans(Typo.Size.body)).frame(maxWidth: .infinity)
                    }
                    .disabled(deleting)
                }
            }
          }
        }
        .background(AppBackground())
        .navigationTitle("高级")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("同步到全部联系人？", isPresented: $confirmSync, titleVisibility: .visible) {
            Button("同步") { Task { synced = await store.syncAdvanced() } }
        } message: { Text("其他联系人这一页的设置会被换成现在这样。") }
        .confirmationDialog("删除 \(companion.name)？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                Task {
                    deleting = true
                    let why = await model.deleteCompanion(companion)
                    deleting = false
                    if let why { deleteFailed = why; return }
                    if model.chat?.companion.id == companion.id { model.chat = nil }
                    dismiss()
                }
            }
        } message: { Text("TA 所有窗口的聊天、TA 记得的事、设定都会一起删掉。" + MessageListView.deleteSafetyNote + "\n只想删一个窗口的话：回消息列表，点 TA 那行右边的窗口数，再点那个窗口右边的「⋯」。") }
        .alert(String(localized: "没删成"), isPresented: Binding(get: { deleteFailed != nil }, set: { if !$0 { deleteFailed = nil } })) {
            Button(String(localized: "好")) { deleteFailed = nil }
        } message: { Text(deleteFailed ?? "") }
    }

    // MARK: 小工具

    private func sentinel(_ key: String) -> Binding<Bool> {
        Binding(get: { (store.settings["sentinels"] as? [String: Any])?[key] as? Bool ?? true },
                set: { v in
                    var all = store.settings["sentinels"] as? [String: Any] ?? [:]
                    all[key] = v
                    store.setNow(settings: ["sentinels": all])
                })
    }

    private var injections: [[String: Any]] { store.settings["injections"] as? [[String: Any]] ?? [] }

    private func injBinding<T>(_ i: Int, _ key: String, _ fallback: T) -> Binding<T> {
        Binding(get: { i < injections.count ? (injections[i][key] as? T ?? fallback) : fallback },
                set: { v in
                    var list = injections
                    guard i < list.count else { return }
                    list[i][key] = v
                    store.setNow(settings: ["injections": list])
                })
    }

    private func overrideStepper(_ key: String, _ title: String, _ unit: String, _ range: ClosedRange<Int>, step: Int) -> some View {
        let overrides = store.settings["patrol_overrides"] as? [String: Any] ?? [:]
        let value = overrides[key] as? Int
        return Stepper(value: Binding(get: { value ?? range.lowerBound },
                                      set: { v in
                                          var o = store.settings["patrol_overrides"] as? [String: Any] ?? [:]
                                          o[key] = (key == "asleep_gap_min" && v > 0 && v < 15) ? 15 : v
                                          store.setNow(settings: ["patrol_overrides": o])
                                      }),
                       in: range, step: step) {
            row(title, value.map { "\($0) \(unit)" } ?? String(localized: "跟档位"))
        }
    }
}
