import SwiftUI
import UniformTypeIdentifiers

// MARK: - 小组件墙（第二块第 8 步）
//
// 两列格子，卡分小（半宽方块）/ 中（整宽矮条）/ 大（整宽高块）。长按任意一张进编辑：
// 卡轻轻晃，拖着换位置、角上 − 删、「尺寸」切换、底下「＋」从卡片库加。排法存本机。
// 以后加卡 = 往 WidgetKind 添一项、在 WidgetCard 里画出来，墙不用改。

enum WidgetKind: String, Codable, CaseIterable, Identifiable {
    case days       // 认识第几天
    case wakes      // 今天来找过你
    case drawer     // 抽屉（09-28）：几封信、几封能拆了
    case focus      // 专注（09-29）：开始专注 / 还剩多久
    case photo      // 照片（10-03）：导入一张，无边框
    case polaroid   // 拍立得（10-04 Aporia）：照片套白边，底下宽一截
    case anniversary // 纪念日（10-03）：自己写标题、选日子、置顶一个
    case health     // 健康（10-04）：默认步数，点卡选显示哪一项
    case chat       // 最近聊天（10-04 主屏改版：原来首页顶上那张聊天卡）
    case pegboard   // 洞洞板（10-04 主屏改版：原来 Memory 那一页）
    case todo       // 待办（11-07 Aporia）：毛玻璃底，圆圈点一下勾掉
    case tarot      // 今日一牌（11-07）：点开写问题、翻一张
    case foodToday  // 今日饮食（11-07）：今天的总数和运动进度
    case quote      // 翻到一句（11-07）：从收藏里翻一句，底图自己换，点一下回到那天
    case starmap    // 星图（10-04 Aporia）：毛玻璃底，中间是记忆库那颗自己转的星球；没接记忆库就灰着

    var id: String { rawValue }
    /// 编辑时角上有「换照片」的
    var takesPhoto: Bool { self == .photo || self == .polaroid || self == .quote }
    /// 自己就是一张卡、外面不再套卡底的
    var bare: Bool { self == .chat || self == .pegboard || self == .polaroid || self == .starmap || self == .todo || self == .quote }
    /// Lite 本机没有服务器：自唤醒（它自己醒来）不给加；专注 10-05 夜起 Lite 两边都有
    static var available: [WidgetKind] {
        Lite.local ? allCases.filter { $0 != .wakes }
            : Lite.hosted ? allCases
            : allCases.filter { $0 != .starmap }
    }
    var title: String {
        switch self {
        case .days: return String(localized: "认识第几天")
        case .wakes: return String(localized: "今天来找过你")
        case .drawer: return String(localized: "抽屉")
        case .focus: return String(localized: "专注")
        case .photo: return String(localized: "照片")
        case .polaroid: return String(localized: "拍立得")
        case .anniversary: return String(localized: "纪念日")
        case .health: return String(localized: "健康")
        case .chat: return String(localized: "最近聊天")
        case .pegboard: return String(localized: "洞洞板")
        case .starmap: return String(localized: "星图")
        case .todo: return String(localized: "待办")
        case .tarot: return String(localized: "今日一牌")
        case .foodToday: return String(localized: "今日饮食")
        case .quote: return String(localized: "翻到一句")
        }
    }
    /// 只有一种大小的（主屏改版）：最近聊天 = 中，洞洞板 = 大
    var fixedSize: WidgetSize? {
        switch self {
        case .drawer, .focus: return .small
        case .chat: return .medium
        case .pegboard: return .large
        default: return nil
        }
    }
    /// 添加页上的名字（10-03 Aporia：「今天来找过你」在添加页叫「自唤醒」，卡本身不改）
    /// 只有小号、永远排在最上面那一排的（10-04 Aporia）
    var smallOnly: Bool { self == .drawer || self == .focus }
    var catalogTitle: String { self == .wakes ? String(localized: "自唤醒") : title }
    var about: String {
        switch self {
        case .days: return String(localized: "从认识那天算起")
        case .wakes: return String(localized: "今天它自己醒来找过你几次")
        case .drawer: return String(localized: "抽屉里几封信、几封能拆了")
        case .focus: return String(localized: "开始专注、还剩多久")
        case .photo: return String(localized: "放一张你喜欢的照片")
        case .polaroid: return String(localized: "照片套上拍立得的白边")
        case .anniversary: return String(localized: "记住重要的日子，可以置顶一个")
        case .health: return String(localized: "步数、睡眠、心率……点一下换")
        case .chat: return String(localized: "最近跟谁聊、聊到哪了")
        case .pegboard: return String(localized: "信、相册、档案袋、地图，还能挂贴纸")
        case .starmap: return String(localized: "记忆库里的星球，点进去看记忆")
        case .todo: return String(localized: "还没做的事，圆圈点一下就勾掉")
        case .tarot: return String(localized: "问一句，每天翻一张")
        case .foodToday: return String(localized: "今天吃了多少、运动到哪了")
        case .quote: return String(localized: "从收藏里翻一句，点一下回到那天")
        }
    }
    var icon: String {
        switch self {
        case .days: return "calendar"
        case .wakes: return "sparkles"
        case .drawer: return "envelope"
        case .focus: return "timer"
        case .photo: return "photo"
        case .polaroid: return "photo.artframe"
        case .anniversary: return "heart.text.square"
        case .health: return "heart.circle"
        case .chat: return "bubble.left.and.bubble.right"
        case .pegboard: return "square.grid.3x3"
        case .todo: return "checklist"
        case .tarot: return "sparkles"
        case .foodToday: return "fork.knife"
        case .quote: return "quote.opening"
        case .starmap: return "sparkle"
        }
    }
}

enum WidgetSize: String, Codable, CaseIterable {
    case small, medium, large
    var next: WidgetSize {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
    var label: String {
        switch self {
        case .small: return String(localized: "小")
        case .medium: return String(localized: "中")
        case .large: return String(localized: "大")
        }
    }
}

struct WidgetSlot: Codable, Identifiable, Equatable {
    var id = UUID()
    var kind: WidgetKind
    var size: WidgetSize
    /// 跟哪个联系人；nil = 跟首页主聊天人那个走
    var companion: UUID?
    /// 照片小组件的那张图（Documents/widget-photos/ 下的文件名）
    var photo: String? = nil
    /// 健康小组件显示哪一项（HealthMetric 的 rawValue；空 = 步数）
    var metric: String? = nil
}

/// 排法存本机（UserDefaults 里一段 JSON）
enum WidgetLayout {
    private static let key = "homeWidgets"
    static var defaults: [WidgetSlot] {
        Lite.on ? [WidgetSlot(kind: .days, size: .small), WidgetSlot(kind: .drawer, size: .small)]
                : [WidgetSlot(kind: .days, size: .small), WidgetSlot(kind: .wakes, size: .small)]
    }

    static func load() -> [WidgetSlot] {
        guard let data = UserDefaults.standard.data(forKey: key),
              var slots = try? JSONDecoder().decode([WidgetSlot].self, from: data) else { return defaults }
        for i in slots.indices where slots[i].kind.smallOnly { slots[i].size = .small }
        return slots.filter { WidgetKind.available.contains($0.kind) }
    }

    static func save(_ slots: [WidgetSlot]) {
        if let data = try? JSONEncoder().encode(slots) { UserDefaults.standard.set(data, forKey: key) }
    }
}

struct WidgetWall: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var theme: AppTheme
    @State private var slots = WidgetLayout.load()
    @Binding var editing: Bool
    @State private var dragging: UUID?
    @State private var showCatalog = false
    @State private var wiggle = false
    let onOpenWakes: (UUID) -> Void

    private let gap: CGFloat = 12

    var body: some View {
        VStack(spacing: gap) {
            ForEach(rows, id: \.self) { row in
                HStack(spacing: gap) {
                    ForEach(row, id: \.self) { id in
                        if let i = slots.firstIndex(where: { $0.id == id }) { cell(i) }
                    }
                    if row.count == 1, let s = slots.first(where: { $0.id == row[0] }), s.size == .small {
                        Color.clear.frame(maxWidth: .infinity)          // 单个小卡占左半边
                    }
                }
            }
            if editing { addTile }
        }
        .onChange(of: slots) { _, s in WidgetLayout.save(s) }
        .onChange(of: editing) { _, on in
            if on { withAnimation(.easeInOut(duration: 0.13).repeatForever(autoreverses: true)) { wiggle = true } }
            else { wiggle = false }
        }
        .sheet(isPresented: $showCatalog) {
            WidgetGallery { kind, size in
                withAnimation(.snappy) { slots.append(WidgetSlot(kind: kind, size: size)) }
                showCatalog = false
            }
            .presentationDetents([.large])
            .environment(\.colorScheme, .light)
        }
    }

    /// 排成行：抽屉、专注先占最上面一排；其余小卡两两一行，中、大卡独占一行
    private var rows: [[UUID]] {
        var out: [[UUID]] = []
        let top = slots.filter { $0.kind.smallOnly }
        if !top.isEmpty {
            for pair in stride(from: 0, to: top.count, by: 2) { out.append(top[pair..<min(pair + 2, top.count)].map(\.id)) }
        }
        var pending: UUID?
        for s in slots where !s.kind.smallOnly {
            if s.size == .small {
                if let p = pending { out.append([p, s.id]); pending = nil } else { pending = s.id }
            } else {
                if let p = pending { out.append([p]); pending = nil }
                out.append([s.id])
            }
        }
        if let p = pending { out.append([p]) }
        return out
    }

    private func height(_ size: WidgetSize) -> CGFloat { size == .large ? 320 : 150 }

    @ViewBuilder private func cell(_ i: Int) -> some View {
        let slot = slots[i]
        let card = WidgetCard(slot: slot, onOpenWakes: onOpenWakes, onSetPhoto: { name in slots[i].photo = name },
                              onSetCompanion: { id in slots[i].companion = id },
                              onSetMetric: { m in slots[i].metric = m })
            .allowsHitTesting(!editing)                     // 编辑时卡里的按钮不响（不用 disabled：按钮会变灰）
            .frame(maxWidth: .infinity)
            .frame(height: height(slot.size))
            .cardSurface()
            .contentShape(RoundedRectangle(cornerRadius: Radii.card, style: .continuous))
            .overlay(alignment: .topLeading) { if editing { removeButton(slot) } }
            .overlay(alignment: .bottomTrailing) { if editing && !slot.kind.smallOnly { sizeButton(i) } }
            .overlay(alignment: .bottomLeading) {
                if editing && slot.kind.takesPhoto {
                    ChangePhotoButton(aspect: slot.kind == .polaroid ? PolaroidCard.windowAspect : { $0.width / $0.height }) { name in slots[i].photo = name }
                }
            }
            .rotationEffect(.degrees(editing ? (wiggle ? 0.9 : -0.9) * (i.isMultiple(of: 2) ? 1 : -1) : 0))
            .opacity(dragging == slot.id ? 0.4 : 1)
            .onDrop(of: [UTType.text], delegate: SlotDrop(target: slot.id, slots: $slots, dragging: $dragging))
        if editing {
            // 拖动只在编辑时开：平时长按是「进编辑」，不能被拖拽抢走
            card.onDrag {
                dragging = slot.id
                return NSItemProvider(object: slot.id.uuidString as NSString)
            }
        } else {
            card.simultaneousGesture(LongPressGesture(minimumDuration: 0.45).onEnded { _ in
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                withAnimation(.snappy) { editing = true }
            })
        }
    }

    private func removeButton(_ slot: WidgetSlot) -> some View {
        Button {
            withAnimation(.snappy) { slots.removeAll { $0.id == slot.id } }
        } label: {
            Image(systemName: "minus")
                .font(Typo.icon(12, .bold))
                .foregroundStyle(theme.ink)
                .frame(width: 26, height: 26)
                .background(Circle().fill(.regularMaterial))
        }
        .buttonStyle(.plain)
        .offset(x: -8, y: -8)
    }

    private func sizeButton(_ i: Int) -> some View {
        Button {
            withAnimation(.snappy) { slots[i].size = slots[i].size.next }
        } label: {
            Text(slots[i].size.label)
                .font(Typo.sans(Typo.Size.caption, .semibold))
                .foregroundStyle(theme.ink)
                .frame(width: 28, height: 28)
                .background(Circle().fill(.regularMaterial))
        }
        .buttonStyle(.plain)
        .padding(8)
    }

    private var addTile: some View {
        Button { showCatalog = true } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus").font(Typo.icon(14, .semibold))
                Text("添加小组件").font(Typo.sans(Typo.Size.callout, .medium))
            }
            .foregroundStyle(theme.inkDim)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(RoundedRectangle(cornerRadius: Radii.card, style: .continuous)
                .strokeBorder(theme.inkFaint.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
        }
        .buttonStyle(.plain)
    }

}

/// 拖到另一张卡上 = 插到它的位置
private struct SlotDrop: DropDelegate {
    let target: UUID
    @Binding var slots: [WidgetSlot]
    @Binding var dragging: UUID?

    func dropEntered(info: DropInfo) {
        guard let from = dragging, from != target,
              let a = slots.firstIndex(where: { $0.id == from }),
              let b = slots.firstIndex(where: { $0.id == target }) else { return }
        withAnimation(.snappy) { slots.move(fromOffsets: IndexSet(integer: a), toOffset: b > a ? b + 1 : b) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

// MARK: - 卡

struct WidgetCard: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("primaryPick") private var pick = "recent"
    let slot: WidgetSlot
    let onOpenWakes: (UUID) -> Void
    var onSetPhoto: (String) -> Void = { _ in }
    var onSetCompanion: (UUID?) -> Void = { _ in }
    var onSetMetric: (String) -> Void = { _ in }

    private var companion: CompanionDTO? {
        if let id = slot.companion, let c = model.companion(id) { return c }
        return pick == "busiest" ? (model.busiestCompanion ?? model.recentCompanion) : model.recentCompanion
    }

    var body: some View {
        if let c = companion {
            switch slot.kind {
            case .days: DaysCard(companion: c, size: slot.size, pinned: slot.companion != nil, onPick: onSetCompanion)
            case .wakes: WakesCard(companion: c, size: slot.size, onOpen: { onOpenWakes(c.id) })
            case .drawer: DrawerCard(size: slot.size)
            case .focus: FocusCard(size: slot.size)
            case .photo: PhotoCard(photo: slot.photo, onPick: onSetPhoto)
            case .polaroid: PolaroidCard(photo: slot.photo, onPick: onSetPhoto)
            case .anniversary: AnniversaryCard(size: slot.size)
            case .health: HealthCard(metric: HealthMetric(rawValue: slot.metric ?? "") ?? .steps, size: slot.size,
                                     onPick: { onSetMetric($0.rawValue) })
            case .chat: ChatWidget()
            case .pegboard: PegboardWidget()
            case .starmap: StarmapWidget()
            case .todo: TodoCard(size: slot.size)
            case .tarot: DailyTarotCard(size: slot.size)
            case .foodToday: FoodTodayCard(size: slot.size, exerciseGoal: Int(slot.metric ?? "") ?? FoodTodayCard.defaultGoal)
            case .quote: QuoteCard(size: slot.size, photo: slot.photo)
            }
        }
    }
}

/// 卡的通用骨架：左上角小标题，中间大数字（点缀字），底下一行小字
private struct NumberCard<Extra: View>: View {
    @EnvironmentObject private var theme: AppTheme
    let title: String
    let number: Int
    let unit: String
    let caption: String
    let size: WidgetSize
    @ViewBuilder var extra: () -> Extra

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(Typo.sans(Typo.Size.callout)).foregroundStyle(theme.inkDim)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(number)")
                    .font(Typo.accent(size == .large ? Typo.Size.largeTitle * 1.6 : Typo.Size.largeTitle))
                    .foregroundStyle(theme.ink)
                    .contentTransition(.numericText())
                Text(unit).font(Typo.sans(Typo.Size.body)).foregroundStyle(theme.inkDim)
            }
            if size != .small { extra() }
            Spacer(minLength: 0)
            Text(caption).font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkFaint).lineLimit(1)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())          // 整张卡都能点，不只是有字的地方
    }
}

struct DaysCard: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var theme: AppTheme
    let companion: CompanionDTO
    let size: WidgetSize
    var pinned = false
    var onPick: (UUID?) -> Void = { _ in }
    @State private var choosing = false

    private func days(_ c: CompanionDTO) -> Int {
        guard let start = c.createdAt else { return 1 }
        let cal = Calendar.current
        return (cal.dateComponents([.day], from: cal.startOfDay(for: start), to: cal.startOfDay(for: Date())).day ?? 0) + 1
    }

    private var since: String {
        guard let start = companion.createdAt else { return "" }
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("yMMMd")
        return f.string(from: start)
    }

    /// 认识最久的、聊得最多的（大号用；选的就是它们时不重复写）
    private var oldest: CompanionDTO? { model.companions.min { ($0.createdAt ?? .distantFuture) < ($1.createdAt ?? .distantFuture) } }
    private var chattiest: CompanionDTO? { model.companions.max { $0.totalMessages < $1.totalMessages } }

    var body: some View {
        Button { choosing = true } label: {
            NumberCard(title: String(localized: "认识第几天"), number: days(companion), unit: String(localized: "天"),
                       caption: String(localized: "和 \(companion.name)"), size: size) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(String(localized: "从 \(since) 开始 · 聊了 \(companion.totalMessages) 条"))
                        .font(Typo.sans(Typo.Size.callout)).foregroundStyle(theme.inkDim)
                    if size == .large {
                        VStack(alignment: .leading, spacing: 10) {
                            if let o = oldest, o.id != companion.id {
                                fact(String(localized: "认识最久"), "\(o.name) · \(days(o)) 天")
                            }
                            if let m = chattiest, m.id != companion.id, m.totalMessages > 0 {
                                fact(String(localized: "聊得最多"), "\(m.name) · \(m.totalMessages) 条")
                            }
                        }
                        .padding(.top, 8)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .confirmationDialog("显示哪个联系人", isPresented: $choosing, titleVisibility: .visible) {
            ForEach(model.companions, id: \.id) { c in
                Button(c.name) { onPick(c.id) }
            }
            if pinned { Button("跟着首页主聊天人") { onPick(nil) } }
        }
    }

    /// 一行：主题色竖杠 + 小标题 + 内容
    private func fact(_ title: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1).fill(theme.accent).frame(width: 2.5, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkFaint)
                Text(value).font(Typo.sans(Typo.Size.callout, .medium)).foregroundStyle(theme.ink)
            }
        }
    }
}

struct WakesCard: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var theme: AppTheme
    let companion: CompanionDTO
    let size: WidgetSize
    let onOpen: () -> Void

    private var wakes: WakesDTO? { model.wakes[companion.id] }
    /// 自唤醒链：最近几次开口（新的在前）
    private var chain: [WakesDTO.Item] { (wakes?.items ?? []).filter { $0.outcome == "said" && $0.text != nil } }

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: 14) {
                left
                if size != .small {
                    WakeChain(items: Array(chain.prefix(size == .large ? 5 : 2)), lines: size == .large ? 3 : 2)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .task(id: companion.id) { await model.loadWakes(companion.id, days: 3) }
    }

    /// 左边：标题、大数字；大号再多两行「今天醒了几次」「花了多少」
    private var left: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("今天来找过你").font(Typo.sans(Typo.Size.callout)).foregroundStyle(theme.inkDim)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(wakes?.today.said ?? 0)")
                    .font(Typo.accent(size == .large ? Typo.Size.largeTitle * 1.6 : Typo.Size.largeTitle))
                    .foregroundStyle(theme.ink)
                    .contentTransition(.numericText())
                Text("次").font(Typo.sans(Typo.Size.body)).foregroundStyle(theme.inkDim)
            }
            if size == .large {
                VStack(alignment: .leading, spacing: 3) {
                    Text(String(localized: "今天醒了 \(wakes?.today.woke ?? 0) 次"))
                    Text(String(format: String(localized: "花了 $%.3f"), wakes?.today.costUsd ?? 0))
                }
                .font(Typo.sans(Typo.Size.callout)).foregroundStyle(theme.inkDim)
            }
            Spacer(minLength: 0)
            Text("\(companion.name) · \(String(localized: "自唤醒")) ›")
                .font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkFaint).lineLimit(1)
        }
        .frame(width: size == .small ? nil : 118, alignment: .leading)
        .frame(maxWidth: size == .small ? .infinity : nil, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// 卡里的一小段自唤醒链：竖线串起几个点，每个点旁边几点 + 它那句的开头。用主题色浅一档（accent）
struct WakeChain: View {
    @EnvironmentObject private var theme: AppTheme
    let items: [WakesDTO.Item]
    let lines: Int

    var body: some View {
        if items.isEmpty {
            Text("还没自己醒过来找你").font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkDim)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { i, e in
                    HStack(alignment: .top, spacing: 8) {
                        VStack(spacing: 0) {
                            Circle().fill(theme.accent).frame(width: 5, height: 5).padding(.top, 5)
                            if i < items.count - 1 {
                                Rectangle().fill(theme.accent.opacity(0.7)).frame(width: 1).frame(maxHeight: .infinity)
                            }
                        }
                        .frame(width: 5)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(e.at, format: .dateTime.hour().minute())
                                .font(Typo.number(Typo.Size.caption, .semibold))
                                .foregroundStyle(theme.accent)
                            Text((e.text ?? "").replacingOccurrences(of: "\n\n", with: " "))
                                .font(Typo.sans(Typo.Size.caption)).lineLimit(lines)
                                .foregroundStyle(theme.inkDim)
                        }
                        .padding(.bottom, i < items.count - 1 ? 8 : 0)
                    }
                }
            }
        }
    }
}

/// 抽屉卡：一共几封、几封今天能拆了。点开进抽屉。
struct DrawerCard: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var theme: AppTheme
    let size: WidgetSize
    @State private var items: [DrawerItemDTO] = []

    private var ready: Int { items.filter { $0.openable && !$0.opened }.count }

    var body: some View {
        Button { NotificationCenter.default.post(name: .lumiOpenDrawer, object: nil) } label: {
            NumberCard(title: String(localized: "抽屉"), number: items.count, unit: String(localized: "封"),
                       caption: ready > 0 ? String(localized: "\(ready) 封能拆了") : String(localized: "都还锁着"), size: size) {
                EmptyView()
            }
        }
        .buttonStyle(.plain)
        .task { items = (try? await model.api.call("GET", "drawer")) ?? [] }
    }
}

// MARK: - 添加小组件（10-03 Aporia：照苹果原生那种，看得见每个组件长什么样）

struct WidgetGallery: View {
    @EnvironmentObject private var theme: AppTheme
    @Environment(\.dismiss) private var dismiss
    let onAdd: (WidgetKind, WidgetSize) -> Void
    @State private var sizes: [WidgetKind: WidgetSize] = [:]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    ForEach(WidgetKind.available) { kind in entry(kind) }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .background(AppBackground())
            .navigationTitle("添加小组件")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.tint(theme.accent) } }
        }
    }

    private func entry(_ kind: WidgetKind) -> some View {
        let size = kind.fixedSize ?? sizes[kind] ?? .small
        return VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.catalogTitle).font(Typo.sans(Typo.Size.headline, .semibold)).foregroundStyle(theme.ink)
                Text(kind.about).font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkFaint)
            }
            preview(kind, size)
                .frame(maxWidth: .infinity)
                .animation(.snappy, value: size)
            HStack {
                if let f = kind.fixedSize {
                    Text(f == .small ? "只有小号" : f == .medium ? "只有中号" : "只有大号").font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkFaint)
                } else {
                    Picker("大小", selection: Binding(get: { size }, set: { sizes[kind] = $0 })) {
                        ForEach(WidgetSize.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 180)
                }
                Spacer()
                Button {
                    onAdd(kind, kind.fixedSize ?? size)
                } label: {
                    Label("添加", systemImage: "plus")
                        .font(Typo.sans(Typo.Size.callout, .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(Capsule().fill(theme.accent))
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// 真卡缩一点当预览：小 = 半宽方块，中 = 整宽矮条，大 = 整宽高块
    private func preview(_ kind: WidgetKind, _ size: WidgetSize) -> some View {
        GeometryReader { geo in
            let w = geo.size.width
            let cardW = size == .small ? (w - 12) / 2 : w
            WidgetCard(slot: WidgetSlot(kind: kind, size: size), onOpenWakes: { _ in })
                .environment(\.widgetPreview, true)
                .allowsHitTesting(false)
                .frame(width: cardW, height: size == .large ? 320 : 150)
                .modifier(CardIf(on: !kind.bare))
                .frame(width: w, alignment: .center)
        }
        .frame(height: size == .large ? 320 : 150)
    }
}
