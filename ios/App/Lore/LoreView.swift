import SwiftUI

/// 世界书（09-30，设计 specs/2026-09-30-worldbook-design.md）：密语、网络梗、世界观。
/// 按联系人分组 + 一组「所有人都知道」；TA 能改任何一条（包括它记的）。样子先能用，统一调 UI 时Aporia细说。

extension Notification.Name {
    static let lumiOpenLore = Notification.Name("LumiOpenLore")
}

struct LoreEntry: Decodable, Identifiable, Equatable {
    let id: Int
    let companionID: String?
    let name: String
    let keywords: [String]
    let content: String
    let createdBy: String
    let enabled: Bool
    let constant: Bool
    var source: String? = nil        // 从哪个文件导进来的，同一个文件一组（10-14；旧 Host 没有这一项）
    var occasional: Bool? = nil      // 偶尔想起：隔几轮随手抽一条递给它（10-14）

    var group: String { source ?? "" }
    var isOccasional: Bool { occasional ?? false }

    enum CodingKeys: String, CodingKey {
        case id, name, keywords, content, enabled, constant, source, occasional
        case companionID = "companion_id", createdBy = "created_by"
    }
}

@MainActor
final class LoreStore: ObservableObject {
    @Published var entries: [LoreEntry] = []
    @Published var error: String?
    var api: APIClient?

    func load() async {
        entries = (try? await api?.call("GET", "lore", as: [LoreEntry].self)) ?? entries
    }

    /// existing 空 = 加一条。成功返回 true。
    func save(_ existing: LoreEntry?, body: [String: Any]) async -> Bool {
        error = nil
        do {
            if let e = existing {
                let got: LoreEntry = try await api!.call("PATCH", "lore/\(e.id)", json: body)
                entries = entries.map { $0.id == got.id ? got : $0 }
            } else {
                let got: LoreEntry = try await api!.call("POST", "lore", json: body)
                entries.append(got)
            }
            return true
        } catch let e as APIError {
            error = e.message
        } catch {
            self.error = String(localized: "没连上服务器，过会儿再试")
        }
        return false
    }

    /// 偶尔想起隔几轮抽一条（10-15）：整个账号一个数；旧 Host 没这个接口时是 nil，滑块不显示
    struct OccasionalSettings: Decodable { let every: Int; let min: Int; let max: Int }
    @Published var occasional: OccasionalSettings?

    func loadOccasional() async {
        occasional = try? await api?.call("GET", "lore/settings", as: OccasionalSettings.self)
    }

    func setEvery(_ n: Int) async {
        guard let api else { return }
        if let got = try? await api.call("PUT", "lore/settings", json: ["every": n], as: OccasionalSettings.self) { occasional = got }
    }

    func delete(_ e: LoreEntry) async {
        try? await api?.send("DELETE", "lore/\(e.id)")
        entries.removeAll { $0.id == e.id }
    }

    /// 一组一起改（10-14）：整组开 / 关偶尔想起，或者整组删掉；改完重新拉一遍
    func batch(_ ids: [Int], occasional: Bool? = nil, delete: Bool = false) async {
        error = nil
        var body: [String: Any] = ["ids": ids]
        if let occasional { body["occasional"] = occasional }
        if delete { body["delete"] = true }
        do {
            try await api?.send("POST", "lore/batch", json: body)
        } catch let e as APIError {
            error = e.message
        } catch {
            self.error = String(localized: "没连上服务器，过会儿再试")
        }
        await load()
    }
}

struct LoreRoomView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var theme: AppTheme
    @Environment(\.dismiss) private var dismiss
    @StateObject private var store = LoreStore()
    @State private var editing: LoreEditTarget?
    #if LITE
    @State private var importingFile = false
    @State private var importPlan: LoreImportFile?
    @State private var importError: String?
    #endif

    var body: some View {
        NavigationStack {
            List {
                if store.entries.isEmpty {
                    Text(String(localized: "还没有词条。你们的密语、刚火的梗、你的世界观都可以写进来——说到关键词的时候，它就会想起来。"))
                        .font(Typo.sans(Typo.Size.callout)).foregroundStyle(theme.inkDim)
                }
                ForEach(groups, id: \.title) { g in
                    Section(g.title) {
                        // 同一个文件导进来的折成一组（10-14：一百多条的梗清单），点进去整组管
                        ForEach(sources(g.items), id: \.self) { src in
                            let items = g.items.filter { $0.group == src }
                            NavigationLink {
                                LoreSourceView(store: store, source: src, companionID: items.first?.companionID, onEdit: { editing = LoreEditTarget(entry: $0) })
                            } label: { sourceRow(src, items) }
                        }
                        ForEach(g.items.filter { $0.group.isEmpty }) { e in
                            Button { editing = LoreEditTarget(entry: e) } label: { row(e) }
                                .buttonStyle(.plain)
                                .swipeActions {
                                    Button(role: .destructive) { Task { await store.delete(e) } } label: {
                                        Label(String(localized: "删除"), systemImage: "trash")
                                    }
                                }
                        }
                    }
                }
            }
            .navigationTitle(String(localized: "世界书"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                }
                ToolbarItem(placement: .primaryAction) {
                    #if LITE
                    // 导入（10-11 内测反馈）：酒馆世界书 JSON / 角色卡里的世界书 / txt
                    Menu {
                        Button { editing = LoreEditTarget(entry: nil) } label: { Label(String(localized: "加一条"), systemImage: "square.and.pencil") }
                        Button { importingFile = true } label: { Label(String(localized: "从文件导入（JSON / txt）"), systemImage: "square.and.arrow.down") }
                    } label: { Image(systemName: "plus") }
                    #else
                    Button { editing = LoreEditTarget(entry: nil) } label: { Image(systemName: "plus") }
                    #endif
                }
            }
            .task {
                store.api = model.api
                await store.load()
            }
            .sheet(item: $editing) { t in
                LoreEditView(store: store, entry: t.entry).environmentObject(model).environmentObject(theme)
            }
            #if LITE
            .fileImporter(isPresented: $importingFile, allowedContentTypes: [.json, .plainText]) { result in
                guard case .success(let url) = result else { return }
                switch LoreImportSheet.read(url, charName: model.primaryCompanion?.name ?? "", userName: model.profile?.name ?? "") {
                case .success(let f): importPlan = f
                case .failure(let e): importError = e.message
                }
            }
            .sheet(item: $importPlan, onDismiss: { Task { await store.load() } }) { f in
                LoreImportSheet(store: store, file: f).environmentObject(model).environmentObject(theme)
            }
            .alert(String(localized: "没导进来"), isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
                Button(String(localized: "好")) { importError = nil }
            } message: { Text(importError ?? "") }
            #endif
        }
    }

    private struct Group { let title: String; let items: [LoreEntry] }

    /// 每个联系人一组（按联系人顺序），最后「所有人都知道」
    private var groups: [Group] {
        var out: [Group] = model.companions.compactMap { c in
            let items = store.entries.filter { $0.companionID?.lowercased() == c.id.uuidString.lowercased() }
            return items.isEmpty ? nil : Group(title: c.name, items: items)
        }
        let shared = store.entries.filter { $0.companionID == nil }
        if !shared.isEmpty { out.append(Group(title: String(localized: "所有人都知道"), items: shared)) }
        return out
    }

    private func sources(_ items: [LoreEntry]) -> [String] {
        var seen = Set<String>()
        return items.map(\.group).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private func sourceRow(_ src: String, _ items: [LoreEntry]) -> some View {
        let occ = items.filter(\.isOccasional).count
        return VStack(alignment: .leading, spacing: 4) {
            Label(src, systemImage: "doc.text").font(Typo.sans(Typo.Size.body, .semibold)).foregroundStyle(theme.ink)
            Text(occ == 0 ? String(localized: "\(items.count) 条 · 说到关键词才想起")
                 : occ == items.count ? String(localized: "\(items.count) 条 · 都会偶尔想起")
                 : String(localized: "\(items.count) 条 · \(occ) 条会偶尔想起"))
                .font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkDim)
        }
    }

    private func row(_ e: LoreEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(e.name).font(Typo.sans(Typo.Size.body, .semibold)).foregroundStyle(theme.ink)
                if e.createdBy == "ai" {
                    Text(String(localized: "它记的")).font(Typo.sans(11)).foregroundStyle(theme.accentDeep)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(theme.accentDeep.opacity(0.12), in: Capsule())
                }
                if e.constant { Image(systemName: "pin.fill").font(Typo.icon(11)).foregroundStyle(theme.inkDim) }
                if e.isOccasional { Image(systemName: "sparkles").font(Typo.icon(11)).foregroundStyle(theme.inkDim) }
                if !e.enabled { Text(String(localized: "已关")).font(Typo.sans(11)).foregroundStyle(theme.inkDim) }
            }
            Text(e.keywords.joined(separator: " · ")).font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkDim)
            Text(e.content).font(Typo.sans(Typo.Size.callout)).foregroundStyle(theme.inkDim).lineLimit(2)
        }
        .opacity(e.enabled ? 1 : 0.55)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

struct LoreEditTarget: Identifiable {
    let entry: LoreEntry?
    var id: String { entry.map { "\($0.id)" } ?? "new" }
}

struct LoreEditView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: LoreStore
    let entry: LoreEntry?

    @State private var name = ""
    @State private var keywords = ""
    @State private var content = ""
    @State private var forWho = ""           // 联系人 id；空 = 所有人都知道
    @State private var enabled = true
    @State private var constant = false
    @State private var occasional = false
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(String(localized: "名字，比如「日久方长」"), text: $name)
                    TextField(String(localized: "关键词，用逗号隔开（中文一个字也行）"), text: $keywords)
                } footer: {
                    Text(String(localized: "说到这些词的时候，它就会想起这一条。"))
                }
                Section(String(localized: "内容")) {
                    IMETextEditor(text: $content).frame(minHeight: 140)
                }
                Section {
                    Picker(String(localized: "给谁"), selection: $forWho) {
                        ForEach(model.companions) { c in Text(c.name).tag(c.id.uuidString.lowercased()) }
                        Text(String(localized: "所有人都知道")).tag("")
                    }
                    Toggle(String(localized: "开着"), isOn: $enabled)
                }
                Section {
                    Toggle(String(localized: "偶尔想起"), isOn: $occasional)
                } footer: {
                    Text(String(localized: "不用等说到关键词，隔几轮它会随手想起一条，自己拿来用。适合梗、口头禅。"))
                }
                Section {
                    Toggle(String(localized: "常驻"), isOn: $constant)
                } header: {
                    Text(String(localized: "高级"))
                } footer: {
                    Text(String(localized: "常驻的每一轮都在，不用等说到关键词。适合一直要记着的世界观；改一次会让缓存作废一次。"))
                }
                if let e = store.error {
                    Text(e).foregroundStyle(.red)
                }
                if let entry {
                    Section {
                        Button(String(localized: "删除这一条"), role: .destructive) {
                            Task { await store.delete(entry); dismiss() }
                        }
                    }
                }
            }
            .navigationTitle(entry == nil ? String(localized: "加一条") : entry!.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(String(localized: "取消")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "存")) { Task { await save() } }
                        .disabled(saving || name.trimmingCharacters(in: .whitespaces).isEmpty
                                  || content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear(perform: fill)
        }
    }

    private func fill() {
        store.error = nil
        if let e = entry {
            name = e.name; keywords = e.keywords.joined(separator: ", "); content = e.content
            forWho = e.companionID?.lowercased() ?? ""; enabled = e.enabled; constant = e.constant; occasional = e.isOccasional
        } else {
            forWho = model.primaryCompanion?.id.uuidString.lowercased() ?? ""
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        let kw = keywords.trimmingCharacters(in: .whitespaces).isEmpty ? name : keywords
        let body: [String: Any] = ["name": name, "keywords": kw, "content": content, "enabled": enabled,
                                   "constant": constant, "occasional": occasional, "companion_id": forWho.isEmpty ? NSNull() : forWho]
        if await store.save(entry, body: body) { dismiss() }
    }
}

/// 一组（同一个文件导进来的，10-14）：顶上总开关，下面一条条勾哪些会被偶尔想起
struct LoreSourceView: View {
    @EnvironmentObject private var theme: AppTheme
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: LoreStore
    let source: String
    let companionID: String?
    let onEdit: (LoreEntry) -> Void
    @State private var confirmDelete = false
    @State private var every: Double?

    private var items: [LoreEntry] { store.entries.filter { $0.group == source && $0.companionID == companionID } }

    var body: some View {
        List {
            Section {
                Toggle(String(localized: "偶尔想起"), isOn: Binding(
                    get: { !items.isEmpty && items.allSatisfy(\.isOccasional) },
                    set: { on in Task { await store.batch(items.map(\.id), occasional: on) } }))
            } footer: {
                Text(String(localized: "开着：不用等说到关键词，隔几轮它会随手想起其中一条，自己拿来用。关着：说到关键词才想起。也可以在下面一条条挑。"))
            }
            if let o = store.occasional {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(String(localized: "隔 \(Int(every ?? Double(o.every))) 轮想起一条"))
                            .font(Typo.sans(Typo.Size.body)).foregroundStyle(theme.ink)
                        Slider(value: Binding(get: { every ?? Double(o.every) }, set: { every = $0.rounded() }),
                               in: Double(o.min)...Double(o.max), step: 1) { editing in
                            if !editing, let v = every { Task { await store.setEvery(Int(v)) } }
                        }
                        .tint(theme.accentDeep)
                    }
                } footer: {
                    Text(String(localized: "你说一句、TA 回一句算一轮。所有开了「偶尔想起」的组一起轮，所有 TA 都照这个数。"))
                }
            }
            Section {
                ForEach(items) { e in
                    HStack(alignment: .top, spacing: 10) {
                        Button {
                            Task { _ = await store.save(e, body: ["occasional": !e.isOccasional]) }
                        } label: {
                            Image(systemName: e.isOccasional ? "checkmark.circle.fill" : "circle")
                                .font(Typo.icon(18)).foregroundStyle(e.isOccasional ? theme.accentDeep : theme.inkFaint)
                        }
                        .buttonStyle(.plain)
                        Button { onEdit(e) } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(e.name).font(Typo.sans(Typo.Size.body, .medium)).foregroundStyle(theme.ink)
                                Text(e.keywords.joined(separator: " · ")).font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkDim).lineLimit(1)
                                Text(e.content).font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkFaint).lineLimit(2)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .opacity(e.enabled ? 1 : 0.55)
                    .swipeActions {
                        Button(role: .destructive) { Task { await store.delete(e) } } label: {
                            Label(String(localized: "删除"), systemImage: "trash")
                        }
                    }
                }
            } header: {
                Text(String(localized: "勾上的会被偶尔想起"))
            }
            if let err = store.error { Text(err).foregroundStyle(.red) }
            Section {
                Button(String(localized: "删掉这一组（\(items.count) 条）"), role: .destructive) { confirmDelete = true }
            }
        }
        .navigationTitle(source)
        .navigationBarTitleDisplayMode(.inline)
        .task { await store.loadOccasional() }
        .confirmationDialog(String(localized: "删掉「\(source)」这一组？"), isPresented: $confirmDelete, titleVisibility: .visible) {
            Button(String(localized: "删掉 \(items.count) 条"), role: .destructive) {
                Task { await store.batch(items.map(\.id), delete: true); dismiss() }
            }
        }
    }
}
