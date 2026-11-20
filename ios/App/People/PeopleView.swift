import SwiftUI

/// 人物卡（10-01）：TA 身边的人，每人一张，所有联系人共用。能看、能改、能删，还能「对谁隐藏」——
/// 选中的联系人翻不到这张卡，也不会自动想起这个人。样子先能用，统一调 UI 时再说。

extension Notification.Name {
    static let lumiOpenPeople = Notification.Name("LumiOpenPeople")
}

struct PersonCard: Decodable, Identifiable, Equatable {
    let id: Int
    let name: String
    let aliases: [String]
    let relation: String
    let facts: String
    let impression: String
    /// 手机里的卡：每个 TA 各自的印象（联系人 id → 那句，10-12）；Host 的卡没有，只有上面一栏
    var impressions: [String: String]? = nil
    let created_by: String
    let hidden_from: [String]
}

struct PeopleSource: Decodable, Identifiable, Hashable {
    let id: String?
    let name: String
}

@MainActor
final class PeopleStore: ObservableObject {
    @Published var people: [PersonCard] = []
    @Published var error: String?
    /// 有 TA 把人物卡交给记忆库时（10-04 接 MCP）：顶上分页「手机」和每个记忆库；nil = 手机
    @Published var sources: [PeopleSource] = []
    @Published var source: String?
    @Published var offline = false
    var api: APIClient?

    private var query: [URLQueryItem] { source.map { [URLQueryItem(name: "source", value: $0)] } ?? [] }

    func load() async {
        if Lite.local { sources = (try? await api?.call("GET", "people/sources", as: [PeopleSource].self)) ?? [] }
        do {
            people = try await api?.call("GET", "people", query: query, as: [PersonCard].self) ?? people
            offline = false
        } catch {
            if source != nil { people = []; offline = true }
        }
    }

    func save(_ existing: PersonCard?, body: [String: Any]) async -> Bool {
        error = nil
        do {
            if let p = existing {
                let got: PersonCard = try await api!.call("PATCH", "people/\(p.id)", json: body)
                people = people.map { $0.id == got.id ? got : $0 }
            } else {
                let got: PersonCard = try await api!.call("POST", "people", query: query, json: body)
                people.append(got)
                people.sort { $0.name.lowercased() < $1.name.lowercased() }
            }
            return true
        } catch let e as APIError {
            error = e.message
        } catch {
            self.error = String(localized: "没连上服务器，过会儿再试")
        }
        return false
    }

    func delete(_ p: PersonCard) async {
        try? await api?.send("DELETE", "people/\(p.id)")
        people.removeAll { $0.id == p.id }
    }
}

struct PeopleRoomView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var theme: AppTheme
    @Environment(\.dismiss) private var dismiss
    @StateObject private var store = PeopleStore()
    @State private var editing: PersonEditTarget?

    var body: some View {
        NavigationStack {
            List {
                if store.sources.count > 1 {
                    Picker(String(localized: "存在哪"), selection: $store.source) {
                        ForEach(store.sources) { Text($0.name).tag($0.id) }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                }
                if store.offline {
                    Text(String(localized: "连不上记忆库。看看 Me →「MCP 服务」里它是不是红点。"))
                        .font(Typo.sans(Typo.Size.callout)).foregroundStyle(theme.inkDim)
                } else if store.people.isEmpty {
                    Text(String(localized: "还没有人物卡。你身边的人——家人、朋友、同学——写一张，说到 Ta 们的时候它就会想起来。聊天时它也会自己建。"))
                        .font(Typo.sans(Typo.Size.callout)).foregroundStyle(theme.inkDim)
                }
                ForEach(store.people) { p in
                    Button { editing = PersonEditTarget(person: p) } label: { row(p) }
                        .buttonStyle(.plain)
                        .swipeActions {
                            Button(role: .destructive) { Task { await store.delete(p) } } label: {
                                Label(String(localized: "删除"), systemImage: "trash")
                            }
                        }
                }
            }
            .navigationTitle(String(localized: "人物卡"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { editing = PersonEditTarget(person: nil) } label: { Image(systemName: "plus") }
                }
            }
            .task {
                store.api = model.api
                await store.load()
            }
            .onChange(of: store.source) { _, _ in Task { await store.load() } }
            .sheet(item: $editing) { t in
                PersonEditView(store: store, person: t.person).environmentObject(model).environmentObject(theme)
            }
        }
    }

    private func row(_ p: PersonCard) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(p.name).font(Typo.sans(Typo.Size.body, .semibold)).foregroundStyle(theme.ink)
                if !p.relation.isEmpty {
                    Text(p.relation).font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkDim)
                }
                if p.created_by == "ai" {
                    Text(String(localized: "Ta 建的")).font(Typo.sans(11)).foregroundStyle(theme.accentDeep)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(theme.accentDeep.opacity(0.12), in: Capsule())
                }
                if !p.hidden_from.isEmpty { Image(systemName: "eye.slash").font(Typo.icon(11)).foregroundStyle(theme.inkDim) }
            }
            if !p.facts.isEmpty {
                Text(p.facts).font(Typo.sans(Typo.Size.callout)).foregroundStyle(theme.inkDim).lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

struct PersonEditTarget: Identifiable {
    let person: PersonCard?
    var id: String { person.map { "\($0.id)" } ?? "new" }
}

struct PersonEditView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: PeopleStore
    let person: PersonCard?

    @State private var name = ""
    @State private var aliases = ""
    @State private var relation = ""
    @State private var facts = ""
    @State private var impression = ""
    @State private var perTA: [String: String] = [:]     // 联系人 id（小写）→ 印象
    @State private var hidden: Set<String> = []
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(String(localized: "名字"), text: $name)
                    TextField(String(localized: "别名，用逗号隔开（外号、昵称）"), text: $aliases)
                    TextField(String(localized: "是谁，比如：大学室友"), text: $relation)
                }
                Section(String(localized: "要记得")) {
                    IMETextEditor(text: $facts).frame(minHeight: 90)
                }
                if separateImpressions {
                    // 每个 TA 各记各的：只有它自己那句会递给它（10-12 内测：原来一栏大家共用，别人的看法被当成自己的）
                    Section {
                        ForEach(model.companions) { c in
                            let key = c.id.uuidString.lowercased()
                            VStack(alignment: .leading, spacing: 4) {
                                Text(c.name).font(Typo.sans(Typo.Size.caption)).foregroundStyle(.secondary)
                                IMETextEditor(text: Binding(get: { perTA[key] ?? "" }, set: { perTA[key] = $0 })).frame(minHeight: 50)
                            }
                        }
                    } header: {
                        Text(String(localized: "Ta 们的印象"))
                    } footer: {
                        Text(String(localized: "聊天的时候每个 Ta 自己补自己的，别的 Ta 看不到。你也可以改。"))
                    }
                } else {
                    Section {
                        IMETextEditor(text: $impression).frame(minHeight: 70)
                    } header: {
                        Text(String(localized: "Ta 的印象"))
                    } footer: {
                        Text(String(localized: "这一栏是聊天的时候 Ta 自己补的，你也可以改。"))
                    }
                }
                if model.companions.count > 0 {
                    Section {
                        ForEach(model.companions) { c in
                            let key = c.id.uuidString.lowercased()
                            Toggle(c.name, isOn: Binding(get: { hidden.contains(key) },
                                                         set: { on in if on { hidden.insert(key) } else { hidden.remove(key) } }))
                        }
                    } header: {
                        Text(String(localized: "对谁隐藏"))
                    } footer: {
                        Text(String(localized: "打开的联系人看不到这张卡：说到这个人时不会想起来，翻也翻不到。"))
                    }
                }
                if let e = store.error { Text(e).foregroundStyle(.red) }
                if let person {
                    Section {
                        Button(String(localized: "删除这张卡"), role: .destructive) {
                            Task { await store.delete(person); dismiss() }
                        }
                    }
                }
            }
            .navigationTitle(person?.name ?? String(localized: "加一张卡"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(String(localized: "取消")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "存")) { Task { await save() } }
                        .disabled(saving || name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear(perform: fill)
        }
    }

    /// 手机里的卡（Lite 本机）按 TA 分开记印象；Host 上的、记忆库里的还是一栏
    private var separateImpressions: Bool { Lite.local && store.source == nil && (person == nil || person?.impressions != nil) }

    private func fill() {
        store.error = nil
        guard let p = person else { return }
        name = p.name; aliases = p.aliases.joined(separator: ", "); relation = p.relation
        facts = p.facts; impression = p.impression; hidden = Set(p.hidden_from.map { $0.lowercased() })
        perTA = Dictionary(uniqueKeysWithValues: (p.impressions ?? [:]).map { ($0.key.lowercased(), $0.value) })
    }

    private func save() async {
        saving = true
        defer { saving = false }
        let list = aliases.replacingOccurrences(of: "，", with: ",").replacingOccurrences(of: "、", with: ",")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var body: [String: Any] = ["name": name.trimmingCharacters(in: .whitespaces), "aliases": list,
                                   "relation": relation, "facts": facts, "hidden_from": Array(hidden)]
        if separateImpressions {
            // 每个联系人都带上（空的 = 删掉那个 TA 的）
            body["impressions"] = Dictionary(uniqueKeysWithValues: model.companions.map { c in
                let k = c.id.uuidString.lowercased()
                return (k, perTA[k] ?? "")
            })
        } else {
            body["impression"] = impression
        }
        if await store.save(person, body: body) { dismiss() }
    }
}
