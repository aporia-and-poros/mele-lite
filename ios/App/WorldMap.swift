import SwiftUI

/// 地图入口：Lite = 每个人自己的世界 + 它的一天（10-04 Aporia定 B）；连 Host 的 11-11 起也有（Host 要更新到 11-11 以后）；
/// Mele 正式版（服务器没接这套）和没更新的 Host = 挑人去线下
struct MapSheet: View {
    var body: some View {
        if Lite.local || (Lite.hosted && HostLink.hostHas(since: HostLink.worldSince)) { WorldMapView() } else { OfflineSheet() }
    }
}

// MARK: - 数据

struct WorldPlace: Identifiable, Hashable {
    let id: Int
    var name: String
    var desc: String
    var icon: String
    var slot: Int
    var home: Bool

    init?(_ d: [String: Any]) {
        guard let id = d["id"] as? Int else { return nil }
        self.id = id
        name = d["name"] as? String ?? ""
        desc = d["desc"] as? String ?? ""
        icon = d["icon"] as? String ?? "park"
        slot = d["slot"] as? Int ?? 0
        home = d["home"] as? Bool ?? false
    }

    static func symbol(_ icon: String) -> String {
        switch icon {
        case "home": "house.fill"
        case "cafe": "cup.and.saucer.fill"
        case "library": "books.vertical.fill"
        case "office": "building.2.fill"
        case "park": "tree.fill"
        case "shop": "bag.fill"
        case "restaurant": "fork.knife"
        case "gym": "dumbbell.fill"
        case "music": "music.note"
        case "studio": "paintbrush.pointed.fill"
        case "school": "graduationcap.fill"
        case "hospital": "cross.case.fill"
        case "beach": "beach.umbrella.fill"
        case "mountain": "mountain.2.fill"
        case "station": "tram.fill"
        case "bar": "wineglass.fill"
        case "temple": "building.columns.fill"
        case "garden": "leaf.fill"
        default: "mappin"
        }
    }
    static let allIcons = ["home", "cafe", "library", "office", "park", "shop", "restaurant", "gym", "music", "studio",
                           "school", "hospital", "beach", "mountain", "station", "bar", "temple", "garden"]
}

struct WorldDay: Hashable {
    let time: String
    let placeID: Int
    let place: String
    let doing: String
    var later = false        // 还没到点：只露时间和地点（10-05 Aporia）
}

struct WorldSnapshot {
    var places: [WorldPlace] = []
    var today: [WorldDay] = []
    var now: WorldDay?
    var generating = false
    var off = false              // 这个 TA 的线下生活关着（10-05）

    init() {}
    init(_ d: [String: Any]) {
        places = (d["places"] as? [[String: Any]] ?? []).compactMap(WorldPlace.init)
        func day(_ x: [String: Any]) -> WorldDay {
            WorldDay(time: x["time"] as? String ?? "", placeID: x["place_id"] as? Int ?? 0,
                     place: x["place"] as? String ?? "", doing: x["doing"] as? String ?? "", later: x["later"] as? Bool ?? false)
        }
        off = d["off"] as? Bool ?? false
        today = (d["today"] as? [[String: Any]] ?? []).map(day)
        now = (d["now"] as? [String: Any]).map(day)
        generating = d["generating"] as? Bool ?? false
    }
}

// MARK: - 地图页

struct WorldMapView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var theme: AppTheme
    @Environment(\.dismiss) private var dismiss

    @State private var selected: UUID?
    @State private var worlds: [UUID: WorldSnapshot] = [:]
    @State private var opened: WorldPlace?
    @State private var adding = false
    @State private var error: String?

    private var current: CompanionDTO? { model.companions.first { $0.id == selected } ?? model.companions.first }
    private var world: WorldSnapshot { current.flatMap { worlds[$0.id] } ?? WorldSnapshot() }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Map").font(Typo.accent(Typo.Size.title)).foregroundStyle(theme.ink)
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(Typo.icon(14, .semibold)).foregroundStyle(theme.inkDim)
                            .frame(width: 36, height: 36).background(Circle().fill(Color.white.opacity(0.7)))
                    }
                    .buttonStyle(.plain)
                }
                people
                if world.off { lifeOffCard } else { mapCard }
                if let error { Text(error).font(Typo.sans(Typo.Size.caption)).foregroundStyle(.red) }
                if !world.off && !world.today.isEmpty { dayList }
            }
            .padding(20)
        }
        .background(AppBackground().ignoresSafeArea())
        .environment(\.colorScheme, .light)
        .task {
            if selected == nil { selected = model.companions.first?.id }
            await loadAll()
            // 起世界 / 排行程在后台跑：开着页面就隔几秒看一眼
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                if worlds.values.contains(where: { $0.generating }) || (current.map { !(worlds[$0.id]?.off ?? false) && (worlds[$0.id]?.places.isEmpty ?? true) } ?? false) {
                    await loadAll()
                }
            }
        }
        .sheet(item: $opened) { p in
            if let c = current {
                PlaceSheet(companion: c, place: p, isNow: world.now?.placeID == p.id, doing: world.now?.placeID == p.id ? world.now?.doing ?? "" : "",
                           onVisit: { visit(c, p) }, onChanged: { Task { await load(c) } })
                    .environmentObject(model).environmentObject(theme)
                    .presentationDetents([.height(world.now?.placeID == p.id ? 420 : 360), .large])
            }
        }
        .sheet(isPresented: $adding) {
            if let c = current {
                PlaceSheet(companion: c, place: nil, isNow: false, doing: "", onVisit: {}, onChanged: { Task { await load(c) } })
                    .environmentObject(model).environmentObject(theme)
                    .presentationDetents([.height(360), .large])
            }
        }
    }

    // 顶上一排头像，头像下写此刻在哪
    private var people: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                ForEach(model.companions) { c in
                    let on = c.id == current?.id
                    Button { withAnimation(.snappy) { selected = c.id } } label: {
                        VStack(spacing: 6) {
                            CompanionAvatar(companion: c, size: 52)
                                .padding(3)
                                .overlay(Circle().stroke(on ? theme.accent : .clear, lineWidth: 2))
                            Text(c.name).font(Typo.sans(Typo.Size.caption, .semibold)).foregroundStyle(theme.ink).lineLimit(1)
                            Text(worlds[c.id]?.now?.place ?? " ")
                                .font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkFaint).lineLimit(1)
                        }
                        .frame(width: 72)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var mapCard: some View {
        ZStack {
            MapPaper()
            if world.places.isEmpty {
                emptyMap
            } else {
                GeometryReader { geo in
                    ForEach(world.places) { p in
                        let pt = MapSlots.point(p.slot, in: geo.size)
                        PlacePin(place: p, here: world.now?.placeID == p.id, companion: current)
                            .position(pt)
                            .onTapGesture { opened = p }
                    }
                }
                .padding(8)
            }
        }
        .aspectRatio(0.86, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(Color.white.opacity(0.8), lineWidth: 1))
        .shadow(color: .black.opacity(0.06), radius: 14, y: 6)
        .overlay(alignment: .bottomTrailing) {
            if !world.places.isEmpty {
                Button { adding = true } label: {
                    Image(systemName: "plus").font(Typo.icon(15, .semibold)).foregroundStyle(theme.accentDeep)
                        .frame(width: 40, height: 40).background(Circle().fill(.ultraThinMaterial))
                }
                .buttonStyle(.plain)
                .padding(12)
            }
        }
    }

    private var emptyMap: some View {
        VStack(spacing: 12) {
            if world.generating {
                ProgressView()
                Text("\(current?.name ?? "TA")在画自己的世界…").font(Typo.sans(Typo.Size.callout)).foregroundStyle(theme.inkDim)
            } else {
                Image(systemName: "map").font(Typo.icon(28)).foregroundStyle(theme.accent)
                Text("这里还是一张白纸").font(Typo.sans(Typo.Size.headline, .semibold)).foregroundStyle(theme.ink)
                Text("让\(current?.name ?? "TA")照自己的样子，画出常去的几个地方。会用你的 key 跑一次。")
                    .font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkDim).multilineTextAlignment(.center)
                Button { generate() } label: {
                    Text("让 TA 画").font(Typo.sans(Typo.Size.callout, .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 22).padding(.vertical, 10)
                        .background(Capsule().fill(theme.accentDeep))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(30)
    }

    private var dayList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(current?.name ?? "TA")的今天").font(Typo.sans(Typo.Size.callout, .semibold)).foregroundStyle(theme.inkDim)
            VStack(spacing: 0) {
                ForEach(Array(world.today.enumerated()), id: \.offset) { i, d in
                    let isNow = world.now?.time == d.time && world.now?.placeID == d.placeID
                    HStack(alignment: .top, spacing: 12) {
                        Text(d.time).font(Typo.number(Typo.Size.callout, isNow ? .semibold : .regular))
                            .foregroundStyle(isNow ? theme.accentDeep : theme.inkFaint)
                            .frame(width: 48, alignment: .leading)
                        Circle().fill(isNow ? theme.accent : theme.inkFaint.opacity(0.35)).frame(width: 7, height: 7).padding(.top, 6)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(d.place).font(Typo.sans(Typo.Size.callout, d.later ? .regular : .semibold))
                                .foregroundStyle(d.later ? theme.inkFaint : theme.ink)
                            if !d.doing.isEmpty {
                                Text(d.doing).font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkDim)
                            }
                        }
                        Spacer()
                        if isNow {
                            Text("现在").font(Typo.sans(Typo.Size.caption, .semibold)).foregroundStyle(theme.accentDeep)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Capsule().fill(theme.accentSoft.opacity(0.4)))
                        }
                    }
                    .padding(.vertical, 9)
                    if i < world.today.count - 1 { Divider().padding(.leading, 67) }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color.white.opacity(0.6)))
        }
    }

    // MARK: 读写

    /// 线下生活关着：没有地图和自己的一天，点一下就在 TA 设定里打开
    private var lifeOffCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(current?.name ?? "TA") 的线下生活关着").font(Typo.sans(Typo.Size.body, .semibold)).foregroundStyle(theme.ink)
            Text("关着的时候，TA 的日子就是和你聊天，没有地图，也不排自己的一天。打开以后，TA 会有自己的地方和行程。")
                .font(Typo.sans(Typo.Size.callout)).foregroundStyle(theme.inkDim)
            Button {
                guard let c = current else { return }
                Task {
                    try? await model.api.send("PATCH", "companions/\(c.id.uuidString.lowercased())", json: ["settings": ["offline_life": true]])
                    await load(c)
                }
            } label: {
                Text("打开线下生活").font(Typo.sans(Typo.Size.callout, .medium)).foregroundStyle(theme.accentDeep)
            }
            .buttonStyle(.plain)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    private func loadAll() async {
        for c in model.companions { await load(c) }
    }

    private func load(_ c: CompanionDTO) async {
        if let d = try? await model.api.raw("GET", "world/\(c.id.uuidString.lowercased())") as? [String: Any] {
            worlds[c.id] = WorldSnapshot(d)
        }
    }

    private func generate() {
        guard let c = current else { return }
        error = nil
        worlds[c.id, default: WorldSnapshot()].generating = true
        Task {
            do { _ = try await model.api.raw("POST", "world/\(c.id.uuidString.lowercased())/generate") }
            catch { self.error = error.localizedDescription }
        }
    }

    private func visit(_ c: CompanionDTO, _ p: WorldPlace) {
        Task {
            guard let out = try? await model.api.raw("POST", "world/\(c.id.uuidString.lowercased())/visit", json: ["place_id": p.id]) as? [String: Any],
                  let conv = (out["conversation"] as? String).flatMap(UUID.init(uuidString:)) else { return }
            opened = nil
            dismiss()
            try? await Task.sleep(for: .milliseconds(350))
            await model.refresh()
            model.openChat(c, conversation: conv)
        }
    }
}

// MARK: - 手绘底图：纸、河、路、几簇树

/// 地方填进去的固定空位（相对坐标，按顺序填）
enum MapSlots {
    static let all: [CGPoint] = [
        .init(x: 0.24, y: 0.17), .init(x: 0.72, y: 0.14), .init(x: 0.50, y: 0.36), .init(x: 0.17, y: 0.52),
        .init(x: 0.80, y: 0.46), .init(x: 0.40, y: 0.68), .init(x: 0.76, y: 0.78), .init(x: 0.18, y: 0.86),
        .init(x: 0.56, y: 0.88), .init(x: 0.88, y: 0.28), .init(x: 0.32, y: 0.36), .init(x: 0.62, y: 0.58),
    ]
    static func point(_ slot: Int, in size: CGSize) -> CGPoint {
        let p = all[((slot % all.count) + all.count) % all.count]
        return CGPoint(x: p.x * size.width, y: p.y * size.height)
    }
}

struct MapPaper: View {
    @EnvironmentObject private var theme: AppTheme

    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(red: 0.985, green: 0.972, blue: 0.948)))
            // 空地：几块淡绿
            for (x, y, r) in [(0.12, 0.30, 0.16), (0.86, 0.66, 0.14), (0.55, 0.12, 0.10), (0.30, 0.94, 0.12)] {
                ctx.fill(Path(ellipseIn: CGRect(x: x * w - r * w, y: y * h - r * w * 0.8, width: r * w * 2, height: r * w * 1.6)),
                         with: .color(Color(red: 0.86, green: 0.92, blue: 0.84).opacity(0.55)))
            }
            // 河：从左上斜到右下的一条弯
            var river = Path()
            river.move(to: CGPoint(x: -0.05 * w, y: 0.40 * h))
            river.addCurve(to: CGPoint(x: 0.55 * w, y: 0.52 * h), control1: CGPoint(x: 0.20 * w, y: 0.30 * h), control2: CGPoint(x: 0.35 * w, y: 0.62 * h))
            river.addCurve(to: CGPoint(x: 1.05 * w, y: 0.66 * h), control1: CGPoint(x: 0.75 * w, y: 0.42 * h), control2: CGPoint(x: 0.88 * w, y: 0.70 * h))
            ctx.stroke(river, with: .color(Color(red: 0.76, green: 0.86, blue: 0.93)), style: StrokeStyle(lineWidth: 18, lineCap: .round))
            ctx.stroke(river, with: .color(Color.white.opacity(0.5)), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [6, 10]))
            // 路：两条，白底灰边，中间虚线
            var roads = Path()
            roads.move(to: CGPoint(x: 0.08 * w, y: -0.02 * h))
            roads.addCurve(to: CGPoint(x: 0.42 * w, y: 1.02 * h), control1: CGPoint(x: 0.30 * w, y: 0.30 * h), control2: CGPoint(x: 0.20 * w, y: 0.70 * h))
            roads.move(to: CGPoint(x: -0.02 * w, y: 0.76 * h))
            roads.addCurve(to: CGPoint(x: 1.02 * w, y: 0.22 * h), control1: CGPoint(x: 0.40 * w, y: 0.86 * h), control2: CGPoint(x: 0.62 * w, y: 0.18 * h))
            ctx.stroke(roads, with: .color(Color.black.opacity(0.07)), style: StrokeStyle(lineWidth: 15, lineCap: .round))
            ctx.stroke(roads, with: .color(.white), style: StrokeStyle(lineWidth: 12, lineCap: .round))
            ctx.stroke(roads, with: .color(Color.black.opacity(0.10)), style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [5, 7]))
            // 树：几簇小圆
            for (x, y) in [(0.10, 0.26), (0.14, 0.33), (0.88, 0.62), (0.83, 0.70), (0.58, 0.10), (0.33, 0.92), (0.92, 0.90)] {
                let r = 0.022 * w
                ctx.fill(Path(ellipseIn: CGRect(x: x * w - r, y: y * h - r, width: r * 2, height: r * 2)),
                         with: .color(Color(red: 0.62, green: 0.76, blue: 0.62).opacity(0.75)))
            }
        }
    }
}

/// 地图上一个地方：圆章 + 名字；它在这儿就顶上插它的头像
struct PlacePin: View {
    @EnvironmentObject private var theme: AppTheme
    let place: WorldPlace
    let here: Bool
    let companion: CompanionDTO?
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                if here {
                    Circle().fill(theme.accent.opacity(0.25)).frame(width: 58, height: 58)
                        .scaleEffect(pulse ? 1.15 : 0.9).opacity(pulse ? 0.2 : 0.7)
                }
                Circle().fill(place.home ? theme.accentSoft : Color.white)
                    .frame(width: 40, height: 40)
                    .overlay(Circle().stroke(here ? theme.accent : Color.black.opacity(0.08), lineWidth: here ? 2 : 1))
                    .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
                Image(systemName: WorldPlace.symbol(place.icon)).font(Typo.icon(16)).foregroundStyle(theme.accentDeep)
            }
            .overlay(alignment: .topTrailing) {
                if here, let c = companion {
                    CompanionAvatar(companion: c, size: 24)
                        .overlay(Circle().stroke(.white, lineWidth: 2))
                        .offset(x: 10, y: -10)
                }
            }
            Text(place.name).font(Typo.sans(Typo.Size.caption, .semibold)).foregroundStyle(theme.ink)
                .lineLimit(1).padding(.horizontal, 7).padding(.vertical, 2)
                .background(Capsule().fill(Color.white.opacity(0.85)))
                .fixedSize()
        }
        .contentShape(Rectangle())
        .onAppear { if here { withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) { pulse = true } } }
    }
}

// MARK: - 点开一个地方：看 / 改 / 删；它在这儿就能「去找 TA」

struct PlaceSheet: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var theme: AppTheme
    @Environment(\.dismiss) private var dismiss
    let companion: CompanionDTO
    let place: WorldPlace?          // nil = 新加一个
    let isNow: Bool
    let doing: String
    let onVisit: () -> Void
    let onChanged: () -> Void

    @State private var name = ""
    @State private var desc = ""
    @State private var icon = "park"
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if isNow {
                HStack(spacing: 10) {
                    CompanionAvatar(companion: companion, size: 34)
                    Text(doing.isEmpty ? "\(companion.name)现在在这儿" : "\(companion.name)正在\(doing)")
                        .font(Typo.sans(Typo.Size.callout, .semibold)).foregroundStyle(theme.ink)
                }
                Button(action: onVisit) {
                    Label("去这儿找\(companion.name)", systemImage: "figure.walk")
                        .font(Typo.sans(Typo.Size.headline, .semibold)).foregroundStyle(.white)
                        .frame(maxWidth: .infinity).padding(.vertical, 13)
                        .background(Capsule().fill(theme.accentDeep))
                }
                .buttonStyle(.plain)
                Text("会切成线下（长文），\(companion.name)先开场。").font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkFaint)
                Divider()
            }
            TextField("地方的名字", text: $name).font(Typo.sans(Typo.Size.headline, .semibold))
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: Radii.control).fill(Color.white.opacity(0.7)))
            TextField("一句话说说这里", text: $desc).font(Typo.sans(Typo.Size.callout))
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: Radii.control).fill(Color.white.opacity(0.7)))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(WorldPlace.allIcons, id: \.self) { ic in
                        Button { icon = ic } label: {
                            Image(systemName: WorldPlace.symbol(ic)).font(Typo.icon(14))
                                .foregroundStyle(icon == ic ? .white : theme.accentDeep)
                                .frame(width: 36, height: 36)
                                .background(Circle().fill(icon == ic ? theme.accentDeep : Color.white.opacity(0.7)))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if let error { Text(error).font(Typo.sans(Typo.Size.caption)).foregroundStyle(.red) }
            HStack {
                if let place, !place.home {
                    Button(role: .destructive) { Task { await remove(place) } } label: {
                        Text("删掉").font(Typo.sans(Typo.Size.callout, .semibold)).foregroundStyle(.red.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Button { Task { await save() } } label: {
                    Text(place == nil ? "加上" : "保存").font(Typo.sans(Typo.Size.callout, .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 22).padding(.vertical, 10)
                        .background(Capsule().fill(theme.accentDeep))
                }
                .buttonStyle(.plain)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Spacer(minLength: 0)
        }
        .padding(22)
        .background(AppBackground().ignoresSafeArea())
        .environment(\.colorScheme, .light)
        .onAppear {
            name = place?.name ?? ""
            desc = place?.desc ?? ""
            icon = place?.icon ?? "park"
        }
    }

    private var base: String { "world/\(companion.id.uuidString.lowercased())/places" }

    private func save() async {
        do {
            let body: [String: Any] = ["name": name.trimmingCharacters(in: .whitespaces), "desc": desc, "icon": icon]
            if let place { _ = try await model.api.raw("PATCH", "\(base)/\(place.id)", json: body) }
            else { _ = try await model.api.raw("POST", base, json: body) }
            onChanged()
            dismiss()
        } catch { self.error = error.localizedDescription }
    }

    private func remove(_ p: WorldPlace) async {
        do {
            try await model.api.send("DELETE", "\(base)/\(p.id)")
            onChanged()
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
