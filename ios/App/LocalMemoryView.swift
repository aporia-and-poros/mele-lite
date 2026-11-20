#if LITE
import SwiftUI

// MARK: - 本地记忆库的原生页（10-11 第 20 版）：本地库没有网页，这页直接读写 LocalMemory，
// 列表能搜能改能钉；星图照 mele-memory 网页版的样子用 Canvas 自己画（球面力导向、呼吸的爱心、标签行星）。
// 10-15：连着 Mele Host 时同一页读 Host 上 TA 那本（server/api/routes_memories.py），数据从哪来看 MemoryShelf。

struct LocalMemoryItemRow: Identifiable, Equatable {
    let id: Int
    var kind: String
    var title: String
    var content: String
    var tags: [String]
    var importance: Int
    var resolved: Bool
    var createdAt: Date
    /// 记得这件事的 TA 名字（10-11 群聊：两个以上才显示「阿橘和小满都记得」）
    var byNames: [String]

    init(_ m: LocalMemory.Item) {
        id = m.id; kind = m.kind; title = m.title; content = m.content; tags = m.tags
        importance = m.importance; resolved = m.resolved; createdAt = m.createdAt
        let s = LocalHost.shared.store
        byNames = m.by.compactMap { s.companion($0) }.map { ($0["persona"] as? [String: Any])?["name"] as? String ?? "TA" }
    }

    /// Host 上的一条（routes_memories._view）：Host 的记忆没有标题，也不分谁记得
    init(host d: [String: Any]) {
        id = d["id"] as? Int ?? 0; kind = d["kind"] as? String ?? "memory"; title = ""
        content = d["content"] as? String ?? ""; tags = d["tags"] as? [String] ?? []
        importance = d["importance"] as? Int ?? 5; resolved = d["resolved"] as? Bool ?? false
        createdAt = LocalStore.date(d["created_at"]); byNames = []
    }

    var sharedLine: String? {
        guard byNames.count >= 2 else { return nil }
        let head = byNames.dropLast().joined(separator: "、")
        return String(localized: "\(head)和\(byNames.last!)都记得")
    }
}

/// 记忆库页看的是哪本（10-11 分仓）：记在本机，星图小组件跟着；那本没了（TA 关了单独一本 / 删了）就回共用
enum LocalMemoryVaultPick {
    static let key = "localMemoryVault"
    static var current: String {
        let v = UserDefaults.standard.string(forKey: key) ?? LocalMemory.sharedScope
        return LocalMemory.scopes(LocalHost.shared.store).contains { $0.id == v } ? v : LocalMemory.sharedScope
    }
    static var library: LocalMemory { LocalMemory.vault(current) }
}

/// 连着 Host 时看哪个 TA 的那本（记在本机）；没选过 / 那个 TA 没了就看第一个
enum HostMemoryPick {
    static let key = "hostMemoryCompanion"
    static func resolve(_ picked: String, _ companions: [CompanionDTO]) -> String {
        let ids = companions.map { $0.id.uuidString.lowercased() }
        return ids.contains(picked) ? picked : ids.first ?? ""
    }
}

/// 记忆库页的数据从哪来（10-15）：手机里那本，或 Mele Host 上某个 TA 那本。页面只认这几个动作
enum MemoryShelf {
    case local(LocalMemory)
    case host(APIClient, companion: String)

    /// 主屏星图小组件用：连 Host 看记忆库页选的那个 TA，本机看选的那本
    @MainActor static func current(_ model: AppModel) -> MemoryShelf {
        Lite.hosted ? .host(model.api, companion: HostMemoryPick.resolve(UserDefaults.standard.string(forKey: HostMemoryPick.key) ?? "", model.companions))
                    : .local(LocalMemoryVaultPick.library)
    }

    var isHost: Bool { if case .host = self { true } else { false } }

    private func path(_ api: APIClient, _ cid: String, _ tail: String = "") -> String { "companions/\(cid)/memories\(tail)" }

    func rows() async -> [LocalMemoryItemRow] {
        switch self {
        case .local(let lib): return lib.all.sorted { $0.createdAt > $1.createdAt }.map(LocalMemoryItemRow.init)
        case .host(let api, let cid):
            guard !cid.isEmpty, let raw = try? await api.raw("GET", path(api, cid)) as? [[String: Any]] else { return [] }
            return raw.map(LocalMemoryItemRow.init(host:))
        }
    }

    func forget(_ id: Int) async {
        switch self {
        case .local(let lib): _ = lib.forget(id: id)
        case .host(let api, let cid): try? await api.send("DELETE", path(api, cid, "/\(id)"))
        }
    }

    func pin(_ id: Int, _ on: Bool) async {
        switch self {
        case .local(let lib): _ = lib.pin(id: id, pinned: on)
        case .host(let api, let cid): _ = try? await api.raw("PATCH", path(api, cid, "/\(id)"), json: ["pinned": on])
        }
    }

    func resolve(_ id: Int, _ on: Bool) async {
        switch self {
        case .local(let lib): _ = lib.resolve(id: id, resolved: on)
        case .host(let api, let cid): _ = try? await api.raw("PATCH", path(api, cid, "/\(id)"), json: ["resolved": on])
        }
    }

    /// item 为 nil = 新写一条
    func save(_ item: LocalMemoryItemRow?, content: String, title: String, tags: [String], importance: Int, pinned: Bool) async {
        switch self {
        case .local(let lib):
            if let item {
                _ = lib.update(id: item.id, content: content, title: title, tags: tags, importance: importance)
                if pinned != (item.kind == "core") { _ = lib.pin(id: item.id, pinned: pinned) }
            } else {
                let r = lib.remember(content: content, title: title, tags: tags, importance: importance)
                if pinned, let json = r.structuredJSON?.data(using: .utf8),
                   let d = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
                   let id = (d["memory"] as? [String: Any])?["id"] as? Int {
                    _ = lib.pin(id: id, pinned: true)
                }
            }
        case .host(let api, let cid):
            let body: [String: Any] = ["content": content, "tags": tags, "importance": importance, "pinned": pinned]
            if let item { _ = try? await api.raw("PATCH", path(api, cid, "/\(item.id)"), json: body) }
            else { _ = try? await api.raw("POST", path(api, cid), json: body) }
        }
    }

    func graph() async -> LocalMemory.StarGraph? {
        switch self {
        case .local(let lib): return lib.graph()
        case .host(let api, let cid):
            guard !cid.isEmpty, let d = try? await api.raw("GET", path(api, cid, "/stars")) as? [String: Any] else { return nil }
            let stars = (d["stars"] as? [[String: Any]] ?? []).map {
                LocalMemory.Star(id: $0["id"] as? Int ?? 0, label: $0["label"] as? String ?? "", title: "",
                                 tags: $0["tags"] as? [String] ?? [], weight: $0["weight"] as? Double ?? 0,
                                 content: $0["content"] as? String ?? "")
            }
            let edges = (d["edges"] as? [[String: Any]] ?? []).map {
                LocalMemory.StarEdge(a: $0["a"] as? Int ?? 0, b: $0["b"] as? Int ?? 0, strength: $0["strength"] as? Double ?? 0)
            }
            let hubs = (d["hubs"] as? [[String: Any]] ?? []).map {
                LocalMemory.StarHub(label: $0["label"] as? String ?? "", members: Set($0["members"] as? [Int] ?? []))
            }
            let me = d["user_label"] as? String ?? ""
            return LocalMemory.StarGraph(stars: stars, edges: edges, hubs: hubs, mine: Set(d["mine"] as? [Int] ?? []),
                                         userLabel: me.isEmpty ? String(localized: "你") : me)
        }
    }
}

/// 嵌在「记忆库」软件（MemoryRoomView）的 NavigationStack 里：工具栏按钮会并进外面的导航条
struct LocalMemoryListBody: View {
    @EnvironmentObject private var theme: AppTheme
    @EnvironmentObject private var model: AppModel
    var startOnGraph = false
    @State private var rows: [LocalMemoryItemRow] = []
    @State private var loaded = false
    @State private var query = ""
    @State private var editing: LocalMemoryEditTarget?
    @State private var showGraph = false
    @AppStorage(LocalMemoryVaultPick.key) private var vault = LocalMemory.sharedScope
    @AppStorage(HostMemoryPick.key) private var hostPick = ""
    @State private var scopes: [(id: String, name: String)] = []

    /// 本机：分仓里选的那本；连 Host：选的那个 TA（Host 上每个 TA 本来就各记各的）
    private var pick: String {
        Lite.hosted ? HostMemoryPick.resolve(hostPick, model.companions)
                    : (scopes.contains { $0.id == vault } ? vault : LocalMemory.sharedScope)
    }
    private var shelf: MemoryShelf { Lite.hosted ? .host(model.api, companion: pick) : .local(LocalMemory.vault(pick)) }

    private var shown: [LocalMemoryItemRow] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return rows }
        return rows.filter {
            $0.content.lowercased().contains(q) || $0.title.lowercased().contains(q)
                || $0.tags.contains { $0.lowercased().contains(q) }
        }
    }

    var body: some View {
            List {
                // 分仓（10-11）：有 TA 单独记一本时，顶上选看哪本
                if scopes.count > 1 {
                    Picker(String(localized: "看哪本"), selection: Binding(get: { pick }, set: {
                        if Lite.hosted { hostPick = $0 } else { vault = $0 }
                        Task { await reload() }
                    })) {
                        ForEach(scopes, id: \.id) { sc in Text(sc.name).tag(sc.id) }
                    }
                    .pickerStyle(.menu)
                    .listRowBackground(Color.clear)
                }
                if !loaded {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 40).listRowBackground(Color.clear)
                } else if rows.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "sparkles").font(Typo.icon(28)).foregroundStyle(theme.inkFaint)
                        Text("聊着聊着 TA 会自己记下来").font(Typo.sans(Typo.Size.callout)).foregroundStyle(theme.inkDim)
                        Text("也可以点右上角，替 TA 写下第一条。").font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkFaint)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                    .listRowBackground(Color.clear)
                } else {
                    Text("\(rows.count) 条记忆 · 钉住 \(rows.filter { $0.kind == "core" }.count) 条")
                        .font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkFaint)
                        .listRowBackground(Color.clear)
                }
                ForEach(shown) { m in
                    Button { editing = LocalMemoryEditTarget(item: m) } label: { row(m) }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                rows.removeAll { $0.id == m.id }
                                Task { await shelf.forget(m.id); await reload() }
                            } label: { Label(String(localized: "删除"), systemImage: "trash") }
                        }
                        .swipeActions(edge: .leading) {
                            Button {
                                Task { await shelf.pin(m.id, m.kind != "core"); await reload() }
                            } label: { Label(m.kind == "core" ? String(localized: "取消钉住") : String(localized: "钉住"), systemImage: "pin") }
                                .tint(theme.accentDeep)
                            Button {
                                Task { await shelf.resolve(m.id, !m.resolved); await reload() }
                            } label: { Label(m.resolved ? String(localized: "重新打开") : String(localized: "了结"), systemImage: "checkmark.circle") }
                                .tint(.green.opacity(0.7))
                        }
                }
            }
            .searchable(text: $query, prompt: Text("搜记忆"))
            .scrollContentBackground(.hidden)
            .background(AppBackground())
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showGraph = true } label: { Image(systemName: "sparkles") }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { editing = LocalMemoryEditTarget(item: nil) } label: { Image(systemName: "plus") }
                }
            }
            .refreshable { await reload() }
            .task {
                if startOnGraph { showGraph = true }
                await reload()
            }
            .sheet(item: $editing, onDismiss: { Task { await reload() } }) { t in
                LocalMemoryEditView(item: t.item, shelf: shelf).environmentObject(theme)
                    .environment(\.colorScheme, .light)
            }
            .fullScreenCover(isPresented: $showGraph) {
                LocalStarmapView(shelf: shelf).environmentObject(theme)
            }
    }

    private func reload() async {
        scopes = Lite.hosted ? model.companions.map { ($0.id.uuidString.lowercased(), $0.name) }
                             : LocalMemory.scopes(LocalHost.shared.store)
        rows = await shelf.rows()
        loaded = true
    }

    private func row(_ m: LocalMemoryItemRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if m.kind == "core" { Image(systemName: "pin.fill").font(Typo.icon(10)).foregroundStyle(theme.accentDeep) }
                // 没有标题的：正文直接顶上来，不再重复一行
                Text(m.title.isEmpty ? m.content : m.title)
                    .font(Typo.sans(Typo.Size.body, .semibold)).foregroundStyle(theme.ink).lineLimit(m.title.isEmpty ? 2 : 1)
                Spacer()
                Text(m.createdAt.formatted(.dateTime.month().day()))
                    .font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkFaint)
            }
            if !m.title.isEmpty {
                Text(m.content).font(Typo.sans(Typo.Size.callout)).foregroundStyle(theme.inkDim).lineLimit(2)
            }
            HStack(spacing: 6) {
                ForEach(m.tags.prefix(4), id: \.self) { t in
                    Text("#\(t)").font(Typo.sans(11)).foregroundStyle(theme.accentDeep)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(theme.accentDeep.opacity(0.1), in: Capsule())
                }
                if m.resolved {
                    Text("已了结").font(Typo.sans(11)).foregroundStyle(theme.inkFaint)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(theme.inkFaint.opacity(0.12), in: Capsule())
                }
                Spacer()
                Text("重要 \(m.importance)").font(Typo.sans(11)).foregroundStyle(theme.inkFaint)
            }
            if let line = m.sharedLine {
                Text(line).font(Typo.sans(11)).foregroundStyle(theme.inkFaint)
            }
        }
        .contentShape(Rectangle())
    }
}

struct LocalMemoryEditTarget: Identifiable {
    let item: LocalMemoryItemRow?
    var id: String { item.map { "\($0.id)" } ?? "new" }
}

struct LocalMemoryEditView: View {
    @EnvironmentObject private var theme: AppTheme
    @Environment(\.dismiss) private var dismiss
    let item: LocalMemoryItemRow?
    var shelf: MemoryShelf = .local(.shared)
    @State private var saving = false
    @State private var title = ""
    @State private var content = ""
    @State private var tags = ""
    @State private var importance = 5
    @State private var pinned = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if !shelf.isHost {      // Host 上的记忆没有标题
                        TextField(String(localized: "一行标题（可以空着）"), text: $title)
                    }
                    IMETextEditor(text: $content).frame(minHeight: 120)
                }
                Section {
                    TextField(String(localized: "标签，用逗号隔开"), text: $tags)
                    Stepper(String(localized: "重要 \(importance)（10 = 永远不淡）"), value: $importance, in: 1...10)
                }
                // 10-11 Aporia：钉住原来只能在列表里右滑，没人找得到 → 改的地方也放一个
                Section {
                    Toggle(String(localized: "钉住"), isOn: $pinned).tint(theme.accentDeep)
                } footer: {
                    Text("钉住的记忆不会淡，TA 每次都会想起来。适合「永远要记得」的事，别钉太多。")
                }
                if let item {
                    Section {
                        Button(String(localized: "删除这条记忆"), role: .destructive) {
                            Task { await shelf.forget(item.id); dismiss() }
                        }
                    }
                }
            }
            .navigationTitle(item == nil ? String(localized: "写一条记忆") : String(localized: "改这条记忆"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(String(localized: "取消")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "存")) { Task { await save() } }
                        .disabled(saving || content.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                guard let item else { return }
                title = item.title; content = item.content
                tags = item.tags.joined(separator: ", "); importance = item.importance
                pinned = item.kind == "core"
            }
        }
    }

    private func save() async {
        saving = true
        let list = tags.replacingOccurrences(of: "，", with: ",").replacingOccurrences(of: "、", with: ",")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        await shelf.save(item, content: content, title: title, tags: list, importance: importance, pinned: pinned)
        dismiss()
    }
}

// MARK: - 星图（照 mele-memory/web 的星球搬成 Canvas）：记忆是球面上的星星，连着的越多颜色越深；
// 一个标签挂的记忆够多就大一号、带名字，点进去只看这些；正中间一颗会呼吸的爱心是「你」。

private let starBlueLight = (r: 196.0, g: 211.0, b: 244.0)
private let starBlueDeep = (r: 126.0, g: 160.0, b: 236.0)
private let starHeart = Color(red: 246 / 255, green: 164 / 255, blue: 186 / 255)

/// 摆好的一颗星：先均匀撒在球面上（斐波那契球），再互相推开 + 连线拉近，拉回单位球面
struct StarPlaced: Identifiable {
    let id: Int          // 记忆 id；标签行星用负数
    var x: Double, y: Double, z: Double
    var degree: Int
    var weight: Double
    var label: String
    var title: String
    var tags: [String]
    var content: String
    var isHub: Bool
    var members: Set<Int> = []
}

struct StarScene {
    var stars: [StarPlaced] = []
    var edges: [(Int, Int)] = []        // stars 下标
    var mine: Set<Int> = []             // 跟「你」有关的记忆 id
    var userLabel = ""
    var maxDegree = 1
}

enum StarLayout {
    static func build(_ g: LocalMemory.StarGraph, members: Set<Int>? = nil) -> StarScene {
        let kept = members.map { ms in g.stars.filter { ms.contains($0.id) } } ?? g.stars
        let n = kept.count
        var placed: [StarPlaced] = kept.enumerated().map { i, s in
            let y = 1 - (2 * Double(i) + 1) / Double(max(1, n))
            let r = (1 - y * y).squareRoot()
            let th = Double(i) * 2.399963
            return StarPlaced(id: s.id, x: cos(th) * r, y: y, z: sin(th) * r,
                              degree: 0, weight: s.weight, label: s.label, title: s.title, tags: s.tags, content: s.content, isHub: false)
        }
        var index: [Int: Int] = [:]
        for (i, p) in placed.enumerated() { index[p.id] = i }
        var edges: [(Int, Int)] = []
        for e in g.edges {
            guard let a = index[e.a], let b = index[e.b] else { continue }
            edges.append((a, b))
            placed[a].degree += 1
            placed[b].degree += 1
        }
        // 力导向：互相推开 + 连线拉近，每步拉回球面；星星越多推得越轻
        let strong = min(1.0, 40.0 / Double(max(1, n)))
        var fx = [Double](repeating: 0, count: n), fy = fx, fz = fx
        for step in 0..<160 {
            let cool = 1 - Double(step) / 160
            for i in 0..<n { fx[i] = 0; fy[i] = 0; fz[i] = 0 }
            for i in 0..<n {
                for j in (i + 1)..<n {
                    let dx = placed[i].x - placed[j].x, dy = placed[i].y - placed[j].y, dz = placed[i].z - placed[j].z
                    let f = 0.012 * strong / (dx * dx + dy * dy + dz * dz + 1e-4)
                    fx[i] += dx * f; fy[i] += dy * f; fz[i] += dz * f
                    fx[j] -= dx * f; fy[j] -= dy * f; fz[j] -= dz * f
                }
            }
            for (a, b) in edges {
                let dx = placed[b].x - placed[a].x, dy = placed[b].y - placed[a].y, dz = placed[b].z - placed[a].z
                let f = 0.06 / max(1.0, Double(max(placed[a].degree, placed[b].degree)).squareRoot())
                fx[a] += dx * f; fy[a] += dy * f; fz[a] += dz * f
                fx[b] -= dx * f; fy[b] -= dy * f; fz[b] -= dz * f
            }
            for i in 0..<n {
                placed[i].x += fx[i] * cool; placed[i].y += fy[i] * cool; placed[i].z += fz[i] * cool
                let r = max(1e-9, (placed[i].x * placed[i].x + placed[i].y * placed[i].y + placed[i].z * placed[i].z).squareRoot())
                placed[i].x /= r; placed[i].y /= r; placed[i].z /= r
            }
        }
        // 标签行星：放在它那些记忆的中间、略高一层（只在全景画，飞进去之后不画）
        if members == nil {
            for h in g.hubs {
                var x = 0.0, y = 0.0, z = 0.0
                for id in h.members { if let i = index[id] { x += placed[i].x; y += placed[i].y; z += placed[i].z } }
                let r = max(1e-9, (x * x + y * y + z * z).squareRoot())
                placed.append(StarPlaced(id: -(placed.count + 1), x: x / r * 1.08, y: y / r * 1.08, z: z / r * 1.08,
                                         degree: 0, weight: 1, label: h.label, title: "", tags: [], content: "", isHub: true, members: h.members))
            }
        }
        return StarScene(stars: placed, edges: edges, mine: g.mine, userLabel: g.userLabel,
                         maxDegree: max(1, placed.filter { !$0.isHub }.map(\.degree).max() ?? 1))
    }
}

/// 画一帧：全屏星图和小组件的星球共用
enum StarPainter {
    struct Projected { var sx: Double; var sy: Double; var pz: Double; var f: Double }

    static func project(_ p: StarPlaced, yaw: Double, pitch: Double, w: Double, h: Double, radius: Double) -> Projected {
        let cy = cos(yaw), sy = sin(yaw), cp = cos(pitch), sp = sin(pitch)
        let x1 = p.x * cy + p.z * sy, z1 = -p.x * sy + p.z * cy
        let y2 = p.y * cp - z1 * sp, z2 = p.y * sp + z1 * cp
        let f = 5 / (5 - z2)
        return Projected(sx: w / 2 + x1 * radius * f, sy: h / 2 - y2 * radius * f, pz: z2, f: f)
    }

    /// 四个角往里凹的星星
    static func sparkle(_ x: Double, _ y: Double, _ R: Double) -> Path {
        var p = Path()
        let r = R * 0.1
        p.move(to: CGPoint(x: x, y: y - R))
        p.addQuadCurve(to: CGPoint(x: x + R, y: y), control: CGPoint(x: x + r, y: y - r))
        p.addQuadCurve(to: CGPoint(x: x, y: y + R), control: CGPoint(x: x + r, y: y + r))
        p.addQuadCurve(to: CGPoint(x: x - R, y: y), control: CGPoint(x: x - r, y: y + r))
        p.addQuadCurve(to: CGPoint(x: x, y: y - R), control: CGPoint(x: x - r, y: y - r))
        p.closeSubpath()
        return p
    }

    static func heart(_ x: Double, _ y: Double, _ s: Double) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: x, y: y + s * 0.9))
        p.addCurve(to: CGPoint(x: x, y: y - s * 0.38),
                   control1: CGPoint(x: x - s * 1.25, y: y + s * 0.05), control2: CGPoint(x: x - s * 0.95, y: y - s * 1.0))
        p.addCurve(to: CGPoint(x: x, y: y + s * 0.9),
                   control1: CGPoint(x: x + s * 0.95, y: y - s * 1.0), control2: CGPoint(x: x + s * 1.25, y: y + s * 0.05))
        p.closeSubpath()
        return p
    }

    static func starColor(_ p: StarPlaced, maxDegree: Int) -> Color {
        if p.isHub { return Color(red: starBlueDeep.r / 255, green: starBlueDeep.g / 255, blue: starBlueDeep.b / 255) }
        let k = (Double(p.degree) / Double(maxDegree)).squareRoot()
        return Color(red: (starBlueLight.r + (starBlueDeep.r - starBlueLight.r) * k) / 255,
                     green: (starBlueLight.g + (starBlueDeep.g - starBlueLight.g) * k) / 255,
                     blue: (starBlueLight.b + (starBlueDeep.b - starBlueLight.b) * k) / 255)
    }

    /// heartLabel 空 = 不画爱心（飞进行星时中间是那颗星的名字）
    static func draw(_ ctx: inout GraphicsContext, size: CGSize, scene: StarScene, yaw: Double, pitch: Double,
                     t: Double, focus: Int?, drawEdges: Bool, heartOn: Bool, centerLabel: String = "", lineColor: Color) {
        let w = size.width, h = size.height
        let radius = min(w * 0.3, h * 0.3)
        var proj: [Projected] = []
        proj.reserveCapacity(scene.stars.count)
        for p in scene.stars { proj.append(project(p, yaw: yaw, pitch: pitch, w: w, h: h, radius: radius)) }

        ctx.stroke(Path(ellipseIn: CGRect(x: w / 2 - radius * 1.04, y: h / 2 - radius * 1.04,
                                          width: radius * 2.08, height: radius * 2.08)),
                   with: .color(lineColor.opacity(0.08)), lineWidth: 1)

        let focusMembers: Set<Int>? = focus.flatMap { f in
            guard scene.stars.indices.contains(f) else { return nil }
            let s = scene.stars[f]
            if s.isHub { return s.members }
            var near: Set<Int> = [s.id]
            for (a, b) in scene.edges {
                if scene.stars[a].id == s.id { near.insert(scene.stars[b].id) }
                if scene.stars[b].id == s.id { near.insert(scene.stars[a].id) }
            }
            return near
        }

        if drawEdges {
            for (a, b) in scene.edges {
                let pa = proj[a], pb = proj[b]
                let on = focus == a || focus == b
                let depth = (pa.pz + pb.pz + 2) / 4
                let alpha = on ? 0.7 : (focus != nil ? 0.03 : 0.05 + 0.15 * depth)
                var line = Path()
                line.move(to: CGPoint(x: pa.sx, y: pa.sy))
                line.addLine(to: CGPoint(x: pb.sx, y: pb.sy))
                ctx.stroke(line, with: .color(lineColor.opacity(alpha)), lineWidth: on ? 0.9 : 0.5)
            }
        }

        for i in proj.indices.sorted(by: { proj[$0].pz < proj[$1].pz }) {       // 远的先画
            let p = scene.stars[i], pr = proj[i]
            let depth = (pr.pz + 1) / 2
            let twinkle = 1 + 0.07 * sin(t * 1.7 + Double(abs(p.id)) * 2.3)
            let big = p.isHub ? 1.5 : 1.0
            let R = (3.2 + 5.0 * min(1, max(0, p.weight))) * big * pr.f * (focus == i ? 1.3 : 1) * twinkle
            if let lit = focusMembers, !lit.contains(p.id), focus != i, !p.isHub {
                ctx.fill(sparkle(pr.sx, pr.sy, R * 0.8), with: .color(Color(white: 0.7).opacity(0.16)))
                continue
            }
            let rgb = starColor(p, maxDegree: scene.maxDegree)
            let a = 0.45 + 0.55 * depth
            let halo = R * 2
            ctx.fill(Path(ellipseIn: CGRect(x: pr.sx - halo, y: pr.sy - halo, width: halo * 2, height: halo * 2)),
                     with: .radialGradient(Gradient(colors: [rgb.opacity(a * 0.3), rgb.opacity(0)]),
                                           center: CGPoint(x: pr.sx, y: pr.sy), startRadius: 0, endRadius: halo))
            ctx.fill(sparkle(pr.sx, pr.sy, R), with: .color(rgb.opacity(a)))
            ctx.fill(sparkle(pr.sx, pr.sy, R * 0.32), with: .color(.white.opacity(a * 0.75)))
            if p.isHub {
                ctx.draw(Text(p.label).font(.system(size: 10, weight: .medium)).foregroundStyle(rgb.opacity(0.9)),
                         at: CGPoint(x: pr.sx, y: pr.sy + R + 9))
            }
        }

        if heartOn {        // 正中间：会呼吸的空心爱心是「你」
            let breathe = 1 + 0.1 * sin(t * 2.1)
            let s = min(13.0, radius * 0.12) * breathe
            let glow = s * 3
            ctx.fill(Path(ellipseIn: CGRect(x: w / 2 - glow, y: h / 2 - glow, width: glow * 2, height: glow * 2)),
                     with: .radialGradient(Gradient(colors: [starHeart.opacity(0.25 + 0.1 * sin(t * 2.1)), starHeart.opacity(0)]),
                                           center: CGPoint(x: w / 2, y: h / 2), startRadius: 0, endRadius: glow))
            ctx.stroke(heart(w / 2, h / 2, s), with: .color(starHeart), lineWidth: 1.3)
        } else if !centerLabel.isEmpty {
            ctx.draw(Text(centerLabel).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.white.opacity(0.85)),
                     at: CGPoint(x: w / 2, y: h / 2))
        }
    }
}

/// 全屏星图：拖着转、点一颗星看正文、点大一号的行星飞进去只看这些、点爱心看跟你有关的
struct LocalStarmapView: View {
    @EnvironmentObject private var theme: AppTheme
    @Environment(\.dismiss) private var dismiss
    var shelf: MemoryShelf = .local(LocalMemoryVaultPick.library)
    @State private var graph: LocalMemory.StarGraph?
    @State private var scene: StarScene?
    @State private var stack: [StarScene] = []
    @State private var centerLabel = ""
    @State private var yaw = 0.0
    @State private var pitch = -0.35
    @State private var dragStart: (yaw: Double, pitch: Double)?
    @State private var spinBase = 0.0        // 自转攒下的角度（手放开接着转）
    @State private var lastT = 0.0
    @State private var picked: StarPlaced?
    @State private var pickedIndex: Int?

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                Canvas { ctx, size in
                    guard let scene else { return }
                    StarPainter.draw(&ctx, size: size, scene: scene, yaw: yaw + spinBase, pitch: pitch, t: t,
                                     focus: pickedIndex, drawEdges: true, heartOn: stack.isEmpty && !scene.mine.isEmpty,
                                     centerLabel: centerLabel, lineColor: .white)
                }
                .onChange(of: t) { old, new in
                    // 自转只在没人碰的时候走表（攒进 spinBase，拖动和看星时就停在原地）
                    if dragStart == nil && picked == nil { spinBase += (new - lastT) * 0.18 }
                    lastT = new
                }
            }
            .background(
                LinearGradient(colors: [Color(red: 0.07, green: 0.08, blue: 0.16), Color(red: 0.11, green: 0.1, blue: 0.22)],
                               startPoint: .top, endPoint: .bottom)
            )
            .gesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { v in
                        if dragStart == nil { dragStart = (yaw, pitch) }
                        yaw = dragStart!.yaw + v.translation.width / 160
                        pitch = min(1.2, max(-1.2, dragStart!.pitch + v.translation.height / 200))
                    }
                    .onEnded { _ in dragStart = nil }
            )
            .onTapGesture { pt in tap(at: pt, size: geo.size) }
        }
        .ignoresSafeArea()
        .overlay(alignment: .top) { topBar }
        .overlay(alignment: .bottom) { infoCard }
        .task {
            guard let g = await shelf.graph() else { return }
            graph = g
            scene = StarLayout.build(g)
        }
    }

    private var topBar: some View {
        HStack {
            Button {
                if let back = stack.popLast() { scene = back; centerLabel = ""; picked = nil; pickedIndex = nil }
                else { dismiss() }
            } label: {
                Image(systemName: stack.isEmpty ? "xmark" : "chevron.left")
                    .font(Typo.icon(15)).foregroundStyle(.white.opacity(0.8))
                    .padding(10).background(.white.opacity(0.1), in: Circle())
            }
            Spacer()
            if let scene {
                Text(stack.isEmpty ? "\(scene.stars.filter { !$0.isHub }.count) 颗星" : centerLabel)
                    .font(Typo.sans(Typo.Size.caption)).foregroundStyle(.white.opacity(0.6))
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    @ViewBuilder private var infoCard: some View {
        if let p = picked {
            VStack(alignment: .leading, spacing: 6) {
                if p.isHub || !p.title.isEmpty {        // 没标题的记忆别拿截断正文当标题，直接看正文
                    HStack {
                        Text(p.isHub ? "#\(p.label)" : p.title)
                            .font(Typo.sans(Typo.Size.body, .semibold)).foregroundStyle(.white.opacity(0.95))
                        Spacer()
                        Button { picked = nil; pickedIndex = nil } label: {
                            Image(systemName: "xmark").font(Typo.icon(11)).foregroundStyle(.white.opacity(0.5))
                        }
                    }
                }
                if p.isHub {
                    Text("\(p.members.count) 条记忆 · 再点一下飞进去")
                        .font(Typo.sans(Typo.Size.caption)).foregroundStyle(.white.opacity(0.6))
                } else {
                    Text(p.content).font(Typo.sans(Typo.Size.callout)).foregroundStyle(.white.opacity(0.8)).lineLimit(5)
                    if !p.tags.isEmpty {
                        Text(p.tags.map { "#\($0)" }.joined(separator: " "))
                            .font(Typo.sans(Typo.Size.caption)).foregroundStyle(starHeart.opacity(0.9))
                    }
                }
            }
            .padding(14)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(.white.opacity(0.1)))
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        } else {
            Text("拖着转 · 点星星看正文 · 点大一号的星星飞进去")
                .font(Typo.sans(Typo.Size.caption)).foregroundStyle(.white.opacity(0.35))
                .padding(.bottom, 24)
        }
    }

    private func tap(at pt: CGPoint, size: CGSize) {
        guard let scene else { return }
        let total = yaw + spinBase
        var best: (i: Int, d: Double, pz: Double)?
        for (i, s) in scene.stars.enumerated() {
            let pr = StarPainter.project(s, yaw: total, pitch: pitch, w: size.width, h: size.height,
                                         radius: min(size.width * 0.3, size.height * 0.3))
            let d = hypot(pr.sx - pt.x, pr.sy - pt.y)
            if d < 26, best == nil || pr.pz > best!.pz { best = (i, d, pr.pz) }
        }
        guard let hit = best else { picked = nil; pickedIndex = nil; return }
        let star = scene.stars[hit.i]
        if star.isHub, picked?.id == star.id {        // 再点一下：飞进去只看这些
            guard let graph else { return }
            stack.append(scene)
            self.scene = StarLayout.build(graph, members: star.members)
            centerLabel = "#\(star.label)"
            picked = nil; pickedIndex = nil
            return
        }
        picked = star
        pickedIndex = hit.i
    }
}

/// 小组件里的星球：只画，不能碰；不在屏幕上就停
struct LocalStarGlobeView: View {
    var paused = false
    var shelf: MemoryShelf? = nil       // nil = 记忆库页选的那本（本机）
    @State private var scene: StarScene?
    @State private var spin = 0.0
    @State private var lastT = 0.0

    var body: some View {
        TimelineView(.animation(paused: paused)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                guard let scene else { return }
                StarPainter.draw(&ctx, size: size, scene: scene, yaw: spin, pitch: -0.35, t: t,
                                 focus: nil, drawEdges: false, heartOn: !scene.mine.isEmpty, lineColor: .primary)
            }
            .onChange(of: t) { old, new in
                if !paused { spin += (new - lastT) * 0.12 }
                lastT = new
            }
        }
        .task {                                                   // 记忆库页选的那本 / 那个 TA
            if let g = await (shelf ?? .local(LocalMemoryVaultPick.library)).graph() { scene = StarLayout.build(g) }
        }
    }
}
#endif
