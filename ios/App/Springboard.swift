import SwiftUI

// MARK: - 主屏（10-04 Aporia：整个 App 做成一部手机——每个功能一个软件图标，每页都能放小组件，底下 Dock + 页码点）

/// 一个「软件」：功能入口
enum HomeApp: String, CaseIterable, Codable {
    case messages, me, food, music, lore, people, todo, stickers, wallet, books, tarot, calendar, moments
    case drawer, diary, album, favorites, record, offline, wakes, focus
    case memory     // 记忆库（10-04 Aporia）：用户自己部署的 mele-memory 网页，手机版；没接就灰着带锁

    var title: String {
        switch self {
        case .messages: String(localized: "聊天")
        case .me: String(localized: "我")
        case .food: String(localized: "饮食")
        case .music: String(localized: "音乐")
        case .lore: String(localized: "世界书")
        case .people: String(localized: "人物卡")
        case .todo: String(localized: "待办")
        case .stickers: String(localized: "表情包")
        case .wallet: String(localized: "钱包")
        case .books: String(localized: "书架")
        case .tarot: String(localized: "塔罗")
        case .calendar: String(localized: "日历")
        case .moments: String(localized: "朋友圈")
        case .drawer: String(localized: "信")
        case .diary: String(localized: "日记")
        case .album: String(localized: "相册")
        case .favorites: String(localized: "收藏夹")
        case .record: String(localized: "档案袋")
        case .offline: String(localized: "线下")
        case .wakes: String(localized: "自唤醒")
        case .focus: String(localized: "专注")
        case .memory: String(localized: "记忆库")
        }
    }

    var symbol: String {
        switch self {
        case .messages: "bubble.left.and.bubble.right.fill"
        case .me: "star.fill"
        case .food: "fork.knife"
        case .music: "music.note"
        case .lore: "book.closed.fill"
        case .people: "person.crop.rectangle.stack.fill"
        case .todo: "checklist"
        case .stickers: "face.smiling.inverse"
        case .wallet: "wallet.pass.fill"
        case .books: "books.vertical.fill"
        case .tarot: "moon.stars.fill"
        case .calendar: "calendar"
        case .moments: "camera.aperture"
        case .drawer: "envelope.fill"
        case .diary: "book.pages.fill"
        case .album: "photo.on.rectangle.angled"
        case .favorites: "heart.fill"
        case .record: "archivebox.fill"
        case .offline: "map.fill"
        case .wakes: "sparkles"
        case .focus: "timer"
        case .memory: "sparkle"
        }
    }

    /// Lite 里要 Mele Host 的：图标灰着带锁
    var needsHost: Bool { self == .memory && Lite.local && !MemoryLink.connected }
    /// 连着 Host 时先收起来的（只在手机里做的，还没搬上服务器；10-04）
    var localOnly: Bool { false }      // 音乐 10-05 夜放开；记忆库 10-15 放开（Host 上看 TA 那本）。眼下没有只在手机里的
    /// 只有 Mele 有的
    var available: Bool { Lite.on ? (Lite.hosted || self != .wakes) : self != .memory }
}

/// 主屏上的一格：一个软件，或者一张小组件
struct HomeItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var app: HomeApp?
    var widget: WidgetSlot?
    /// 在这一页的哪一格（左上角）。nil = 还没定（旧排法 / 刚加的），排的时候找第一个空位
    var row: Int? = nil
    var col: Int? = nil

    /// 占几列几行（4 列的格子）
    var span: (w: Int, h: Int) {
        guard let w = widget else { return (1, 1) }
        switch w.kind.fixedSize ?? w.size {
        case .small: return (2, 2)
        case .medium: return (4, 2)
        case .large: return (4, 4)
        }
    }
}

/// 排法存本机
enum HomeLayout {
    private static let key = "springboard.v1"
    static let dockDefault: [HomeApp] = [.messages, .food, .diary, .me]

    struct Saved: Codable { var pages: [[HomeItem]]; var dock: [HomeApp] }

    static func load() -> Saved {
        guard let d = UserDefaults.standard.data(forKey: key), var s = try? JSONDecoder().decode(Saved.self, from: d) else {
            return Saved(pages: defaults, dock: dockDefault)
        }
        s.pages = s.pages.map { $0.filter { ($0.app?.available ?? true) && ($0.widget.map { WidgetKind.available.contains($0.kind) } ?? true) } }
        // 专注 10-05 夜才进 Lite：以前存的排法里没有，放到最后一页末尾（只补一次，TA 删了就不再补）
        if Lite.on, !UserDefaults.standard.bool(forKey: "springboard.focusAdded") {
            UserDefaults.standard.set(true, forKey: "springboard.focusAdded")
            let shown = Set(s.pages.flatMap { $0.compactMap(\.app) } + s.dock)
            if !shown.contains(.focus) {
                if s.pages.isEmpty { s.pages = [[]] }
                s.pages[s.pages.count - 1].append(HomeItem(app: .focus))
                save(s)
            }
        }
        return s
    }

    static func save(_ s: Saved) {
        if let d = try? JSONEncoder().encode(s) { UserDefaults.standard.set(d, forKey: key) }
    }

    static var defaults: [[HomeItem]] {
        func a(_ x: HomeApp) -> HomeItem { HomeItem(app: x) }
        func w(_ k: WidgetKind, _ s: WidgetSize = .small) -> HomeItem { HomeItem(widget: WidgetSlot(kind: k, size: s)) }
        var p1: [HomeItem] = [w(.chat, .medium), w(.days), w(.drawer)]
        p1 += [.food, .todo, .wallet, .calendar, .moments, .stickers, .lore, .people].map(a)
        var p2: [HomeItem] = [w(.pegboard, .large)]
        p2 += [.album, .favorites, .record, .drawer, .offline].map(a)
        var p3: [HomeItem] = [.music, .books, .tarot].map(a)
        if Lite.on { p3 += [a(.memory), a(.focus)] }
        if !Lite.on { p3 += [a(.wakes), a(.focus)] }
        return [p1, p2, p3]
    }
}

/// 4 列格子里排（10-04 Aporia：照 iOS 18，软件能放进空格，不再一律从左上角往后挤）。
/// 每样东西记着自己在哪一格：先按数组顺序放有位置的（越靠前越优先，拖着的那个放最前）；
/// 位置被占了的、还没位置的，从它自己那格往后找第一个空位，找不到再从头找。小组件左右只能对齐半边。
enum HomeGrid {
    struct Placed { let item: HomeItem; let row: Int; let col: Int }

    static func pack(_ items: [HomeItem], rows: Int) -> [Placed] {
        var used = Array(repeating: Array(repeating: false, count: 4), count: max(rows, 1) + 8)
        func aligned(_ c: Int, _ w: Int) -> Bool { w == 1 || (w == 2 ? c % 2 == 0 : c == 0) }
        func free(_ r: Int, _ c: Int, _ w: Int, _ h: Int) -> Bool {
            r >= 0 && c >= 0 && c + w <= 4 && r + h <= used.count && aligned(c, w)
                && (r..<r + h).allSatisfy { rr in (c..<c + w).allSatisfy { !used[rr][$0] } }
        }
        func take(_ r: Int, _ c: Int, _ w: Int, _ h: Int) {
            for rr in r..<r + h { for cc in c..<c + w { used[rr][cc] = true } }
        }
        var out: [Placed] = [], pending: [HomeItem] = []
        for item in items {
            let (w, h) = item.span
            if let r = item.row, let c = item.col, free(r, c, w, h) {
                take(r, c, w, h)
                out.append(Placed(item: item, row: r, col: c))
            } else {
                pending.append(item)
            }
        }
        let total = used.count * 4
        for item in pending {
            let (w, h) = item.span
            let start = min(total, max(0, (item.row ?? 0) * 4 + (item.col ?? 0)))
            if let cell = (Array(start..<total) + Array(0..<start)).first(where: { free($0 / 4, $0 % 4, w, h) }) {
                take(cell / 4, cell % 4, w, h)
                out.append(Placed(item: item, row: cell / 4, col: cell % 4))
            }
        }
        return out
    }

    /// 把排出来的位置记回每一样上（放下之后调，空格就这样留住了）
    static func pinned(_ items: [HomeItem], rows: Int) -> [HomeItem] {
        var at: [UUID: (Int, Int)] = [:]
        for p in pack(items, rows: rows) { at[p.item.id] = (p.row, p.col) }
        return items.map { x in
            var x = x
            if let (r, c) = at[x.id] { x.row = r; x.col = c }
            return x
        }
    }
}

// MARK: - 格子尺寸（一页里每一格多宽多高、在哪）

struct HomeMetrics {
    let width: CGFloat
    let height: CGFloat
    static let maxRows = 6
    static let padX: CGFloat = 22
    static let gapX: CGFloat = 18
    static let gapY: CGFloat = 16
    static let label: CGFloat = 20
    static let top: CGFloat = 56

    var cw: CGFloat { (width - Self.padX * 2 - Self.gapX * 3) / 4 }
    var icon: CGFloat { min(64, cw - 4) }
    var rh: CGFloat { min(icon + Self.label, (height - Self.top - Self.gapY * CGFloat(Self.maxRows - 1)) / CGFloat(Self.maxRows)) }

    func frame(_ p: HomeGrid.Placed) -> CGRect {
        let (w, h) = p.item.span
        let width = CGFloat(w) * cw + CGFloat(w - 1) * Self.gapX
        let height = CGFloat(h) * rh + CGFloat(h - 1) * Self.gapY - (p.item.widget != nil ? Self.label * 0.6 : 0)
        return CGRect(x: Self.padX + CGFloat(p.col) * (cw + Self.gapX), y: Self.top + CGFloat(p.row) * (rh + Self.gapY),
                      width: width, height: height)
    }
}

// MARK: - 主屏

/// 拖着走的那一格（照 iPhone：手指拖到哪格子就让到哪；停在左右边缘会翻页；拖到 Dock 上放进 Dock）
struct HomeDrag: Equatable {
    var item: HomeItem
    var at: CGPoint
    var edge: Int = 0                 // -1 左边缘 / 1 右边缘 / 0 不在边上
    var edgeSince: Date?
}

struct Springboard: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var theme: AppTheme
    @State private var saved = HomeLayout.load()
    @State private var page = 0
    @State private var swipe: CGFloat = 0
    @State private var editing = false
    @State private var wiggle = false
    @State private var drag: HomeDrag?
    @State private var pageSize: CGSize = .zero
    /// Dock 在哪：页面区和页码点下面那一条就是 Dock（量出来的不准，直接按版面算）
    private var dockFrame: CGRect {
        CGRect(x: 22, y: pageSize.height + 30, width: max(1, pageSize.width - 44), height: 140)
    }
    @State private var showGallery = false
    @State private var showAppPicker = false
    @State private var confirmRemove: HomeItem?
    /// 洞洞板自己在摆东西：主屏别跟着翻页
    @State private var innerArranging = false
    @State private var showMe = false
    @State private var showRecord = false
    @State private var showOffline = false
    @State private var hostAlert = false
    @State private var localOnlyAlert = false
    @State private var memoryAlert = false
    @State private var showMemory = false
    @AppStorage(MemoryLink.key) private var memoryConnected = false   // 接上 / 断开记忆库时图标跟着变
    @State private var wakeFor: HomeView.WakeTarget?
    // 主屏导览（10-10 Aporia：新用户不知道设置在星星里）。旧首页那段 10-04 换成主屏后就没人放了
    @State private var coachFrames: [String: CGRect] = [:]
    @State private var showTour = false

    private let tick = Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()
    private var current: Int { min(max(page, 0), max(saved.pages.count - 1, 0)) }
    private var metrics: HomeMetrics { HomeMetrics(width: pageSize.width, height: pageSize.height) }

    var body: some View {
        VStack(spacing: 0) {
            pager
                // 删除确认挂在这里：跟下面「连上 Mele Host」那个 alert 挂在同一层的话只会弹一个
                .alert(removeTitle, isPresented: Binding(get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } })) {
                    Button("删除", role: .destructive) {
                        if let it = confirmRemove { withAnimation(.snappy) { remove(it) } }
                        confirmRemove = nil
                    }
                    Button("取消", role: .cancel) { confirmRemove = nil }
                } message: {
                    Text(confirmRemove?.app != nil
                         ? "只是从主屏拿掉，里面的东西都还在。编辑时左上角 ＋ →「加软件」可以找回来。"
                         : "只是拿掉这张小组件，之后可以从左上角 ＋ →「加小组件」再加回来。")
                }
            dots
            dock
        }
        .coordinateSpace(name: "spring")
        // 编辑时的拖动挂在整个主屏上（挂在格子上的话，格子换页时被重建，手指就松了）
        .simultaneousGesture(editing ? boardDrag : nil)
        .overlay {
            if let d = drag {
                floating(d.item)
                    .scaleEffect(1.06)
                    .shadow(color: .black.opacity(0.18), radius: 12, y: 8)
                    .position(d.at)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .top) { if editing { editBar } }
        .onReceive(tick) { _ in edgeFlip() }
        .onChange(of: editing) { _, on in
            if on { withAnimation(.easeInOut(duration: 0.13).repeatForever(autoreverses: true)) { wiggle = true } }
            else {
                wiggle = false
                saved.pages.removeAll { $0.isEmpty }
                if saved.pages.isEmpty { saved.pages = [[]] }
                page = min(current, saved.pages.count - 1)
                HomeLayout.save(saved)
            }
        }
        .sheet(isPresented: $showGallery) {
            WidgetGallery { kind, size in
                add(HomeItem(widget: WidgetSlot(kind: kind, size: size)))
                showGallery = false
            }
            .presentationDetents([.large])
            .environment(\.colorScheme, .light)
        }
        .fullScreenCover(isPresented: $showMe) {
            NavigationStack {
                MeView()
                    .background(AppBackground())
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button { showMe = false } label: { Image(systemName: "xmark") } } }
            }
            .environmentObject(model).environmentObject(theme)
        }
        .sheet(isPresented: $showRecord) {
            RecordHall().environmentObject(model).environmentObject(theme)
                .presentationDetents([.medium, .large])
                .presentationBackground { ZStack { Rectangle().fill(.ultraThinMaterial); Color.white.opacity(0.22); theme.accent.opacity(0.05) } }
        }
        .sheet(isPresented: $showOffline) {
            MapSheet().environmentObject(model).environmentObject(theme).presentationDetents(Lite.on ? [.large] : [.medium])
        }
        .sheet(isPresented: $showAppPicker) {
            AppPicker(apps: hiddenApps) { app in
                addApp(app)
                showAppPicker = false
            }
            .environmentObject(theme)
            .presentationDetents([.medium, .large])
        }
        .fullScreenCover(item: $wakeFor) { t in SelfWakeView(companionID: t.id) }
        .alert("连上记忆库才能用", isPresented: $memoryAlert) { Button("好") {} } message: {
            Text("去 Me →「MCP 服务」接一个你自己部署的记忆库（mele-memory），这里就能看它的记忆和星图。")
        }
        .fullScreenCover(isPresented: $showMemory) {
            MemoryRoomView().environmentObject(model).environmentObject(theme)
        }
        .task { await MemoryLink.refresh(model.api); memoryConnected = MemoryLink.connected }
        .alert("连上 Mele Host 才能用", isPresented: $hostAlert) { Button("好") {} } message: {
            Text("这个功能要一直醒着的服务器。Mele Lite 只在你的手机上，先把它留着。")
        }
        .alert("连着 Mele Host 时先收起来了", isPresented: $localOnlyAlert) { Button("好") {} } message: {
            Text("这个现在只在手机里做，还没搬到 Host 上。去 Me → Mele Host 断开，就回到手机里那份。")
        }
        // 别的页上的图标也会报位置（在屏幕外），只留看得见的
        .onPreferenceChange(CoachFrameKey.self) { f in
            let screen = UIScreen.main.bounds
            coachFrames = f.filter { screen.contains(CGPoint(x: $0.value.midX, y: $0.value.midY)) }
        }
        .overlay {
            if showTour {
                CoachOverlay(steps: [
                    CoachStep(id: "me", text: String(localized: "设置都在这颗星星里：换模型和 key、外观、接记忆库")),
                    CoachStep(id: "dock", text: String(localized: "长按任何一个图标：挪位置、加小组件、找回收起来的软件")),
                ], frames: coachFrames) {
                    withAnimation { showTour = false }
                    CoachTour.done(CoachTour.homeKey)
                }
                .transition(.opacity)
            }
        }
        .onAppear { armTour() }
        .onChange(of: model.chat) { _, _ in armTour() }
        .onChange(of: model.listOpen) { _, _ in armTour() }
    }

    /// 聊天页那段看完、回到主屏时放一次（看过记本机；Me 里「再看一遍导览」会重新排上）
    private func armTour() {
        guard !showTour, CoachTour.pending(CoachTour.homeKey), !CoachTour.pending(CoachTour.chatKey),
              model.chat == nil, !model.listOpen else { return }
        Task {
            try? await Task.sleep(for: .seconds(0.8))
            guard model.chat == nil, !model.listOpen else { return }
            withAnimation { showTour = true }
        }
    }

    // MARK: 几页横着滑（自己写的翻页：编辑时手指拖到边缘也能翻，系统的分页滚动做不到）

    private var pager: some View {
        GeometryReader { geo in
            let w = geo.size.width
            HStack(spacing: 0) {
                ForEach(saved.pages.indices, id: \.self) { i in
                    pageView(i, metrics: HomeMetrics(width: w, height: geo.size.height))
                        .frame(width: w, height: geo.size.height)
                }
            }
            .frame(width: w, alignment: .leading)
            .offset(x: -CGFloat(current) * w + swipe)
            .contentShape(Rectangle())
            .simultaneousGesture(editing || innerArranging ? nil : DragGesture(minimumDistance: 18)
                .onChanged { v in
                    guard abs(v.translation.width) > abs(v.translation.height) else { return }
                    let atEdge = (current == 0 && v.translation.width > 0) || (current == saved.pages.count - 1 && v.translation.width < 0)
                    swipe = atEdge ? v.translation.width / 3 : v.translation.width
                }
                .onEnded { v in
                    let fling = v.predictedEndTranslation.width
                    var next = current
                    if swipe < -w / 4 || fling < -w / 2 { next += 1 }
                    if swipe > w / 4 || fling > w / 2 { next -= 1 }
                    withAnimation(.snappy(duration: 0.32)) {
                        page = max(0, min(saved.pages.count - 1, next))
                        swipe = 0
                    }
                })
            .onPreferenceChange(InnerArrangeKey.self) { innerArranging = $0 }
            .onAppear { pageSize = geo.size }
            .onChange(of: geo.size) { _, s in pageSize = s }
        }
        .clipped()
    }

    private func pageView(_ i: Int, metrics m: HomeMetrics) -> some View {
        let items = saved.pages[i]
        let placed = HomeGrid.pack(items, rows: HomeMetrics.maxRows)
        return ZStack(alignment: .topLeading) {
            ForEach(Array(placed.enumerated()), id: \.element.item.id) { n, p in
                let f = m.frame(p)
                cell(p.item, index: n, size: f.size, icon: m.icon)
                    .frame(width: f.width, height: f.height, alignment: .top)
                    .opacity(drag?.item.id == p.item.id ? 0 : 1)
                    .offset(x: f.minX, y: f.minY)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(.snappy(duration: 0.28), value: items)
        // 长按空白处也进编辑（垫在最底下：压在洞洞板这种自己会长按的小组件上时不抢）
        .background { Color.clear.contentShape(Rectangle()).onLongPressGesture(minimumDuration: 0.5) { startEditing() } }
        .environment(\.homeEditing, editing)
    }

    @ViewBuilder
    private func cell(_ item: HomeItem, index: Int, size: CGSize, icon: CGFloat) -> some View {
        let view = Group {
            if let app = item.app {
                AppIcon(app: app, size: icon, showLabel: true, onWallpaper: true, onRemove: editing ? { confirmRemove = item } : nil) { open(app) }
                    .coachMark("me", when: app == .me)
            } else if let slot = item.widget {
                widget(item, slot)
            }
        }
        .rotationEffect(.degrees(editing ? (wiggle ? 1.1 : -1.1) * (index.isMultiple(of: 2) ? 1 : -1) : 0))
        if editing || item.widget?.kind == .pegboard {
            // 洞洞板长按是它自己的摆放模式（挪图标、换相册照片）；要挪整块洞洞板，长按别处进编辑再拖
            view
        } else {
            view.simultaneousGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in startEditing() })
        }
    }

    private func widget(_ item: HomeItem, _ slot: WidgetSlot) -> some View {
        let bare = slot.kind.bare
        return WidgetCard(slot: slot, onOpenWakes: { wakeFor = HomeView.WakeTarget(id: $0) },
                          onSetPhoto: { name in update(item.id) { $0.widget?.photo = name } },
                          onSetCompanion: { id in update(item.id) { $0.widget?.companion = id } },
                          onSetMetric: { m in update(item.id) { $0.widget?.metric = m } })
            .allowsHitTesting(!editing)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .modifier(CardIf(on: !bare))
            .overlay(alignment: .topLeading) {
                if editing {
                    Button { confirmRemove = item } label: {
                        Image(systemName: "minus").font(Typo.icon(13, .bold)).foregroundStyle(theme.ink)
                            .frame(width: 30, height: 30).background(Circle().fill(.regularMaterial))
                            .frame(width: 54, height: 54).contentShape(Rectangle())   // 11-07：看着 30，点得到 54
                    }
                    .buttonStyle(.plain)
                    .offset(x: -22, y: -22)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if editing && slot.kind.takesPhoto {
                    ChangePhotoButton(aspect: slot.kind == .polaroid ? PolaroidCard.windowAspect : { $0.width / $0.height }) { name in
                        update(item.id) { $0.widget?.photo = name }
                    }
                }
            }
            .overlay(alignment: .topTrailing) {
                if editing && slot.kind == .foodToday {   // 运动目标（11-07）：存在 metric 里
                    ExerciseGoalButton(goal: Int(slot.metric ?? "") ?? FoodTodayCard.defaultGoal) { n in
                        update(item.id) { $0.widget?.metric = String(n) }
                    }
                }
            }
    }

    /// 拖着走时手指下面那一格（照原样画，大小跟格子一样）
    @ViewBuilder private func floating(_ item: HomeItem) -> some View {
        let m = metrics
        let f = m.frame(HomeGrid.Placed(item: item, row: 0, col: 0))
        if let app = item.app {
            AppIcon(app: app, size: m.icon, showLabel: false) {}
        } else if let slot = item.widget {
            WidgetCard(slot: slot, onOpenWakes: { _ in })
                .frame(width: f.width, height: f.height)
                .modifier(CardIf(on: !slot.kind.bare))
                .background { if slot.kind == .pegboard { BoardSurface() } }
        }
    }

    // MARK: 拖

    private func startEditing() {
        guard !editing else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        withAnimation(.snappy) { editing = true }
    }

    private var boardDrag: some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named("spring"))
            .onChanged { v in
                if drag == nil {
                    guard let item = itemAt(v.startLocation) else { return }
                    drag = HomeDrag(item: item, at: v.location)
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
                drag?.at = v.location
                hover(v.location)
            }
            .onEnded { _ in finishDrag() }
    }

    /// 手指按下去的地方是哪一格（Dock 里的软件、或者这一页上的图标 / 小组件）
    private func itemAt(_ pt: CGPoint) -> HomeItem? {
        if dockFrame.contains(pt), !saved.dock.isEmpty {
            let n = Int((pt.x - dockFrame.minX) / (dockFrame.width / CGFloat(saved.dock.count)))
            let app = saved.dock[max(0, min(saved.dock.count - 1, n))]
            return HomeItem(id: Self.dockID(app), app: app)
        }
        guard pt.y < pageSize.height, saved.pages.indices.contains(current) else { return nil }
        return HomeGrid.pack(saved.pages[current], rows: HomeMetrics.maxRows)
            .first { metrics.frame($0).contains(pt) }?.item
    }

    private func hover(_ pt: CGPoint) {
        guard var d = drag else { return }
        let w = pageSize.width
        // 边缘留宽一点（10-04 Aporia：真机上手指很难挤进 26pt 那条缝，拖着翻不了页）
        let zone: CGFloat = 46
        let edge = pt.y < pageSize.height ? (pt.x < zone ? -1 : (pt.x > w - zone ? 1 : 0)) : 0
        if edge != d.edge { d.edge = edge; d.edgeSince = edge == 0 ? nil : Date() }
        drag = d
        if dockFrame.insetBy(dx: 0, dy: -10).contains(pt) {
            hoverDock(pt)
        } else if pt.y < pageSize.height {
            hoverPage(pt)
        }
    }

    /// 停在左右边缘一会儿就翻页（往右翻到底会开一页新的）
    private func edgeFlip() {
        guard let d = drag, d.edge != 0, let since = d.edgeSince, Date().timeIntervalSince(since) > 0.5 else { return }
        let target = current + d.edge
        guard target >= 0 else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if target >= saved.pages.count { saved.pages.append([]) }
        withAnimation(.snappy(duration: 0.3)) { page = target }
        drag?.edgeSince = Date()
        hoverPage(d.at)
    }

    /// 手指在这一页的哪一格，就放到那一格（空格也行，10-04 Aporia）；那格有东西的话，它往后让到最近的空位。
    /// 小组件按它左上角算，左右对齐半边、往下不超出这一页。
    private func hoverPage(_ pt: CGPoint) {
        guard let d = drag else { return }
        let p = current
        let m = metrics
        let (w, h) = d.item.span
        var col = Int(((pt.x - HomeMetrics.padX) / (m.cw + HomeMetrics.gapX)).rounded(.down))
        var row = Int(((pt.y - HomeMetrics.top) / (m.rh + HomeMetrics.gapY)).rounded(.down))
        if w > 1 { col -= w / 2 - (w == 4 ? 0 : 0); row -= h / 2 }          // 手指在小组件中间：换算成它的左上角
        col = w == 1 ? max(0, min(3, col)) : (w == 4 ? 0 : (col >= 1 ? 2 : 0))
        row = max(0, min(HomeMetrics.maxRows - h, row))
        if let cur = saved.pages[p].first(where: { $0.id == d.item.id }), cur.row == row, cur.col == col { return }
        var moved = d.item
        moved.row = row
        moved.col = col
        var others = saved.pages[p].filter { $0.id != d.item.id }
        others.insert(moved, at: 0)                // 放最前：它占这一格，被挤到的往后让
        withAnimation(.snappy(duration: 0.25)) {
            detach(d.item.id)
            saved.pages[p] = others
        }
    }

    /// Dock：只放软件，最多 4 个；在 Dock 里挪就是换顺序
    private func hoverDock(_ pt: CGPoint) {
        guard let d = drag, let app = d.item.app else { return }
        var dock = saved.dock.filter { $0 != app }
        guard saved.dock.contains(app) || dock.count < 4 else { return }
        let slot = max(0, min(dock.count, Int((pt.x - dockFrame.minX) / max(1, dockFrame.width / CGFloat(max(dock.count + 1, 1))))))
        dock.insert(app, at: slot)
        guard dock != saved.dock else { return }
        withAnimation(.snappy(duration: 0.25)) {
            for i in saved.pages.indices { saved.pages[i].removeAll { $0.id == d.item.id } }
            saved.dock = dock
        }
    }

    private func finishDrag() {
        guard drag != nil else { return }
        withAnimation(.snappy(duration: 0.25)) {
            drag = nil
            settle()
        }
        HomeLayout.save(saved)
    }

    // MARK: 排法

    private func locate(_ id: UUID) -> (page: Int, index: Int)? {
        for (p, items) in saved.pages.enumerated() { if let i = items.firstIndex(where: { $0.id == id }) { return (p, i) } }
        return nil
    }

    /// 从原来的地方拿起来（主屏哪一页、或者 Dock）
    private func detach(_ id: UUID) {
        for p in saved.pages.indices { saved.pages[p].removeAll { $0.id == id } }
        if let app = drag?.item.app, drag?.item.id == id { saved.dock.removeAll { $0 == app } }
    }

    /// 一页放不下的挤到下一页最前面（没有下一页就开一页）
    private func reflow() {
        var p = 0
        while p < saved.pages.count {
            let placed = HomeGrid.pack(saved.pages[p], rows: HomeMetrics.maxRows)
            let fits = Set(placed.filter { $0.row + $0.item.span.h <= HomeMetrics.maxRows }.map(\.item.id))
            let over = saved.pages[p].filter { !fits.contains($0.id) }
            if !over.isEmpty {
                saved.pages[p].removeAll { !fits.contains($0.id) }
                let over = over.map { x in var x = x; x.row = nil; x.col = nil; return x }   // 到下一页找空位
                if p + 1 >= saved.pages.count { saved.pages.append([]) }
                saved.pages[p + 1].insert(contentsOf: over, at: 0)
            }
            p += 1
        }
    }

    /// 挤完再把每样的位置记下来
    private func settle() {
        reflow()
        for p in saved.pages.indices { saved.pages[p] = HomeGrid.pinned(saved.pages[p], rows: HomeMetrics.maxRows) }
    }

    private func update(_ id: UUID, _ change: (inout HomeItem) -> Void) {
        guard let (p, i) = locate(id) else { return }
        change(&saved.pages[p][i])
        HomeLayout.save(saved)
    }

    private func remove(_ item: HomeItem) {
        for p in saved.pages.indices { saved.pages[p].removeAll { $0.id == item.id } }
        if let app = item.app, item.id == Self.dockID(app) { saved.dock.removeAll { $0 == app } }
        HomeLayout.save(saved)
    }

    private var removeTitle: String {
        guard let it = confirmRemove else { return "" }
        if let app = it.app { return String(localized: "确定删除「\(app.title)」吗？") }
        return String(localized: "确定删除这个小组件吗？")
    }

    /// 收起来的软件：主屏和 Dock 上都没有的
    private var hiddenApps: [HomeApp] {
        let shown = Set(saved.pages.flatMap { $0.compactMap(\.app) } + saved.dock)
        return HomeApp.allCases.filter { $0.available && !shown.contains($0) }
    }

    /// 找回来的软件放在当前这一页最后，放不下往后挤
    private func addApp(_ app: HomeApp) {
        withAnimation(.snappy) {
            if saved.pages.isEmpty { saved.pages = [[]] }
            saved.pages[current].append(HomeItem(app: app))
            settle()
        }
        HomeLayout.save(saved)
    }

    /// 加到当前这一页最前面，放不下的往后挤（跟 iPhone 加小组件一样）
    private func add(_ item: HomeItem) {
        withAnimation(.snappy) {
            if saved.pages.isEmpty { saved.pages = [[]] }
            var item = item
            item.row = 0                            // 新小组件放最上面，原来的往后让
            item.col = 0
            saved.pages[current].insert(item, at: 0)
            settle()
        }
        HomeLayout.save(saved)
    }

    // MARK: 打开一个软件

    private func open(_ app: HomeApp) {
        guard !editing else { return }
        if app.localOnly { localOnlyAlert = true; return }
        if app == .memory { if memoryConnected { showMemory = true } else { memoryAlert = true }; return }
        if app.needsHost { hostAlert = true; return }
        let post = { (n: Notification.Name) in NotificationCenter.default.post(name: n, object: nil) }
        switch app {
        case .messages: withAnimation(MainTabView.slide) { model.listOpen = true }
        case .me: showMe = true
        case .food: post(.lumiOpenFood)
        case .music: post(.lumiOpenMusic)
        case .lore: post(.lumiOpenLore)
        case .people: post(.lumiOpenPeople)
        case .todo: post(.lumiOpenTodo)
        case .stickers: post(.lumiOpenStickers)
        case .wallet: post(.lumiOpenWallet)
        case .books: post(.lumiOpenBooks)
        case .tarot: post(.lumiOpenTarot)
        case .calendar: post(.lumiOpenCalendar)
        case .moments: post(.lumiOpenMoments)
        case .drawer: post(.lumiOpenDrawer)
        case .diary: post(.lumiOpenDiary)
        case .album: post(.lumiOpenAlbum)
        case .favorites: post(.lumiOpenFavorites)
        case .record: showRecord = true
        case .offline: showOffline = true
        case .wakes: if let c = model.primaryCompanion { wakeFor = HomeView.WakeTarget(id: c.id) }
        case .focus: NotificationCenter.default.post(name: .lumiOpenFocus, object: nil)
        case .memory: break
        }
    }

    // MARK: 页码点、Dock、编辑条

    private var dots: some View {
        HStack(spacing: 8) {
            ForEach(saved.pages.indices, id: \.self) { i in
                Circle().fill(i == current ? theme.ink.opacity(0.75) : theme.ink.opacity(0.22)).frame(width: 7, height: 7)
                    .onTapGesture { withAnimation(.snappy) { page = i } }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Capsule().fill(.ultraThinMaterial).opacity(0.8))
        .padding(.vertical, 8)
        .animation(.snappy(duration: 0.2), value: current)
    }

    private var dock: some View {
        HStack(spacing: 0) {
            ForEach(Array(saved.dock.enumerated()), id: \.element) { n, app in
                AppIcon(app: app, size: metrics.icon > 0 ? metrics.icon : 60, showLabel: false,
                        onRemove: editing ? { confirmRemove = HomeItem(id: Self.dockID(app), app: app) } : nil) { open(app) }
                    .coachMark("me", when: app == .me)
                    .rotationEffect(.degrees(editing ? (wiggle ? 1.1 : -1.1) * (n.isMultiple(of: 2) ? -1 : 1) : 0))
                    .opacity(drag?.item.app == app ? 0 : 1)
                    .frame(maxWidth: .infinity)
                    .simultaneousGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in startEditing() })
            }
            if saved.dock.isEmpty { Color.clear.frame(height: 60) }
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 10)
        .background {
            RoundedRectangle(cornerRadius: 30, style: .continuous).fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 30, style: .continuous).fill(theme.accentSoft.opacity(0.12))
            RoundedRectangle(cornerRadius: 30, style: .continuous).stroke(Color.white.opacity(0.45), lineWidth: 1)
        }
        .coachMark("dock")
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }

    /// Dock 上的软件拿起来时用的编号：同一个软件同一个号，拖回主屏还是它
    static func dockID(_ app: HomeApp) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", (HomeApp.allCases.firstIndex(of: app) ?? 0) + 1)) ?? UUID()
    }

    private func afterMenu(_ open: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            open()
        }
    }

    private var editBar: some View {
        HStack {
            Menu {
                // 等菜单收完再弹（10-12 内测：16 Pro / iOS 26 上菜单还在收、弹窗被吞掉，点了没反应）
                Button { afterMenu { showGallery = true } } label: { Label("加小组件", systemImage: "square.grid.2x2") }
                Button { afterMenu { showAppPicker = true } } label: { Label("加软件", systemImage: "app.badge") }
            } label: {
                Image(systemName: "plus").font(Typo.icon(16, .bold)).foregroundStyle(theme.ink)
                    .frame(width: 34, height: 34).background(Circle().fill(.regularMaterial))
            }
            Spacer()
            Button { withAnimation(.snappy) { editing = false } } label: {
                Text("完成").font(Typo.sans(Typo.Size.body, .semibold)).foregroundStyle(theme.accentDeep)
                    .padding(.horizontal, 16).padding(.vertical, 8).background(Capsule().fill(.regularMaterial))
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 20)
        .padding(.top, 4)
    }
}

struct CardIf: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        if on { content.cardSurface() } else { content }
    }
}

// MARK: - 软件图标

/// 圆角方块 + 主题色的小图形，下面一行名字。要 Mele Host 的灰着、角上一把小锁
struct AppIcon: View {
    @AppStorage(MemoryLink.key) private var memoryConnected = false   // 让「记忆库」图标跟着灰 / 不灰
    private var locked: Bool { app.localOnly || (app == .memory ? !memoryConnected : app.needsHost) }
    @EnvironmentObject private var theme: AppTheme
    @ObservedObject private var icons = AppIconStore.shared
    let app: HomeApp
    var size: CGFloat = 60
    var showLabel = true
    /// 名字压在壁纸上（主屏）：颜色跟着壁纸深浅；软件库那种有底色的页面不用
    var onWallpaper = false
    /// 编辑时左上角的「－」
    var onRemove: (() -> Void)? = nil
    let action: () -> Void

    var body: some View {
        // 不用 Button：主屏横着滑的时候手指从图标上起步，Button 松手还会触发；点按手势一动就作废
        VStack(spacing: 6) {
                ZStack {
                    if let custom = icons.images[app] {
                        // 自己换的照片（Me 最底下「软件图标」）
                        Image(uiImage: custom).resizable().scaledToFill()
                            .frame(width: size, height: size)
                            .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
                    } else {
                        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                            .fill(LinearGradient(colors: [Color.white.opacity(0.95), theme.wash(0.86)], startPoint: .top, endPoint: .bottom))
                        Image(systemName: app.symbol)
                            .font(.system(size: size * 0.42, weight: .medium))
                            .foregroundStyle(LinearGradient(colors: [theme.wash(0.25), theme.accent], startPoint: .top, endPoint: .bottom))
                    }
                    RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                        .stroke(Color.white.opacity(0.7), lineWidth: 0.8)
                }
                .frame(width: size, height: size)
                .shadow(color: .black.opacity(0.08), radius: 1, y: 1)
                .shadow(color: .black.opacity(0.08), radius: 6, y: 4)
                .saturation(locked ? 0 : 1)
                .opacity(locked ? 0.55 : 1)
                .overlay(alignment: .topLeading) {
                    if let onRemove {
                        Button(action: onRemove) {
                            Image(systemName: "minus").font(Typo.icon(12, .bold)).foregroundStyle(theme.ink)
                                .frame(width: 26, height: 26).background(Circle().fill(.regularMaterial))
                                .frame(width: 46, height: 46).contentShape(Rectangle())   // 11-07：看着 26，点得到 46
                        }
                        .buttonStyle(.plain)
                        .offset(x: -17, y: -17)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if locked {
                        Image(systemName: "lock.fill").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                            .padding(4).background(Circle().fill(theme.ink.opacity(0.45))).offset(x: 4, y: -4)
                    }
                }
                if showLabel {
                    Text(app.title)
                        .font(Typo.sans(11, .medium))
                        .foregroundStyle(onWallpaper && theme.homeLabelIsLight ? Color.white : theme.ink)
                        .shadow(color: onWallpaper && theme.homeLabelIsLight ? .black.opacity(0.45) : .clear, radius: 2, y: 1)
                        .lineLimit(1)
                }
            }
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(app.title)
    }
}

// MARK: - 自己换的软件图标（10-04 Aporia：Me 最底下选一个软件，导入自己的照片当图标）

final class AppIconStore: ObservableObject {
    static let shared = AppIconStore()
    @Published private(set) var images: [HomeApp: UIImage] = [:]

    private static var dir: URL {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("app-icons", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private static func file(_ app: HomeApp) -> URL { dir.appendingPathComponent(app.rawValue + ".jpg") }

    private init() {
        for app in HomeApp.allCases {
            if let img = UIImage(contentsOfFile: Self.file(app).path) { images[app] = img }
        }
    }

    func set(_ app: HomeApp, _ image: UIImage) {
        let small = image.squareCropped(to: 360)
        try? small.jpegData(compressionQuality: 0.88)?.write(to: Self.file(app), options: .atomic)
        images[app] = small
    }

    func reset(_ app: HomeApp) {
        try? FileManager.default.removeItem(at: Self.file(app))
        images[app] = nil
    }
}

// MARK: - 洞洞板和主屏互相知会

/// 主屏是不是在编辑（洞洞板看到了就收起自己的摆放模式）
private struct HomeEditingKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var homeEditing: Bool {
        get { self[HomeEditingKey.self] }
        set { self[HomeEditingKey.self] = newValue }
    }
}

/// 洞洞板在摆东西（主屏看到了就先不翻页）
struct InnerArrangeKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

// MARK: - 加软件：收起来的软件在这里找回

private struct AppPicker: View {
    @EnvironmentObject private var theme: AppTheme
    @Environment(\.dismiss) private var dismiss
    let apps: [HomeApp]
    let onPick: (HomeApp) -> Void

    var body: some View {
        NavigationStack {
            Group {
                if apps.isEmpty {
                    Text("所有软件都在主屏上了")
                        .font(Typo.sans(Typo.Size.callout)).foregroundStyle(theme.inkDim)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 18) {
                            ForEach(apps, id: \.self) { app in
                                AppIcon(app: app, size: 58, showLabel: true) { onPick(app) }
                            }
                        }
                        .padding(20)
                    }
                }
            }
            .navigationTitle("加软件")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        }
        .environment(\.colorScheme, .light)
    }
}
