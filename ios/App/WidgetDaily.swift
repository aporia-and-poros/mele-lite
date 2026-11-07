import SwiftUI

// MARK: - 每天看的四张小组件（11-07 Aporia定）：待办、今日一牌、今日饮食、翻到一句
//
// 都只读已有的接口，Lite 本机和连 Host 走同一套。主屏开着时隔一会儿重拉一次（从别的页面回来就是新的）。

private let widgetRefresh: Duration = .seconds(30)

// MARK: 待办：透明毛玻璃底，圆圈点一下就勾掉

struct TodoCard: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var theme: AppTheme
    let size: WidgetSize
    @State private var todos: [TodoDTO] = []
    @State private var loaded = false
    @State private var ticking: Set<Int> = []

    private var ink: Color { theme.homeLabelIsLight ? .white : theme.ink }
    private var limit: Int { size == .large ? 8 : 3 }
    private var open: [TodoDTO] { todos.filter { !$0.done } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { openPage() } label: {
                HStack {
                    Text("待办").font(Typo.sans(Typo.Size.callout, .semibold))
                    Spacer()
                    if open.count > limit {
                        Text("还有 \(open.count - limit) 件").font(Typo.sans(Typo.Size.caption)).opacity(0.65)
                    }
                }
                .foregroundStyle(ink)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open.isEmpty {
                Spacer(minLength: 0)
                Text(loaded ? String(localized: "没有要做的事") : "")
                    .font(Typo.sans(Typo.Size.callout)).foregroundStyle(ink.opacity(0.65))
                    .frame(maxWidth: .infinity)
                Spacer(minLength: 0)
            } else {
                ForEach(open.prefix(limit)) { row($0) }
                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Radii.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Radii.card, style: .continuous)
                .strokeBorder(Color.white.opacity(0.35), lineWidth: 0.5)
        }
        .task {
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: widgetRefresh)
            }
        }
    }

    private func row(_ t: TodoDTO) -> some View {
        HStack(spacing: 8) {
            Button { Task { await tick(t) } } label: {
                Image(systemName: ticking.contains(t.id) ? "checkmark.circle.fill" : "circle")
                    .font(Typo.icon(19))
                    .foregroundStyle(ticking.contains(t.id) ? theme.accent : ink.opacity(0.55))
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button { openPage() } label: {
                Text(t.what)
                    .font(Typo.sans(Typo.Size.callout))
                    .foregroundStyle(ink)
                    .strikethrough(ticking.contains(t.id))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func openPage() { NotificationCenter.default.post(name: .lumiOpenTodo, object: nil) }

    private func load() async {
        if let got: [TodoDTO] = try? await model.api.call("GET", "todos") { todos = got }
        loaded = true
    }

    private func tick(_ t: TodoDTO) async {
        guard !ticking.contains(t.id) else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.snappy) { _ = ticking.insert(t.id) }
        let got: TodoDTO? = try? await model.api.call("POST", "todos/\(t.id)/done", json: ["done": true])
        try? await Task.sleep(for: .milliseconds(450))     // 让人看见勾上了再收走
        withAnimation(.snappy) {
            ticking.remove(t.id)
            if let got { todos = todos.map { $0.id == got.id ? got : $0 } }
        }
    }
}

// MARK: 今日饮食：只有今天的总数和运动进度

struct FoodTodayCard: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var theme: AppTheme
    let size: WidgetSize
    /// 运动目标（千卡），在主屏编辑时改
    let exerciseGoal: Int
    @State private var summary: FoodSummary?

    static let defaultGoal = 300

    var body: some View {
        Button { NotificationCenter.default.post(name: .lumiOpenFood, object: nil) } label: {
            VStack(alignment: .leading, spacing: 8) {
                Text("今日饮食").font(Typo.sans(Typo.Size.caption, .medium)).foregroundStyle(theme.inkDim)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(summary?.kcal ?? 0)")
                        .font(.system(size: 30, weight: .bold).monospacedDigit())
                        .foregroundStyle(theme.ink)
                        .minimumScaleFactor(0.7)
                        .lineLimit(1)
                    Text("千卡").font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkDim)
                }
                HStack(spacing: 0) {
                    macro("蛋白质", summary?.protein ?? 0)
                    macro("碳水", summary?.carbs ?? 0)
                    macro("脂肪", summary?.fat ?? 0)
                }
                Spacer(minLength: 0)
                exercise
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .task {
            while !Task.isCancelled {
                if let d: FoodDay = try? await model.api.call("GET", "food/day/\(FoodStore.today())") { summary = d.summary }
                try? await Task.sleep(for: widgetRefresh)
            }
        }
    }

    private func macro(_ name: String, _ grams: Int) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(verbatim: "\(grams)g").font(Typo.sans(Typo.Size.callout, .semibold).monospacedDigit()).foregroundStyle(theme.ink)
            Text(LocalizedStringKey(name)).font(Typo.sans(11)).foregroundStyle(theme.inkFaint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var exercise: some View {
        let burned = summary?.exercise ?? 0
        let goal = max(1, exerciseGoal)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("运动").font(Typo.sans(11)).foregroundStyle(theme.inkFaint)
                Spacer()
                Text(verbatim: "\(burned) / \(goal)").font(Typo.sans(11).monospacedDigit()).foregroundStyle(theme.inkDim)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(theme.ink.opacity(0.1))
                    Capsule().fill(theme.accent)
                        .frame(width: geo.size.width * min(1, CGFloat(burned) / CGFloat(goal)))
                }
            }
            .frame(height: 5)
        }
    }
}

/// 主屏编辑时，今日饮食角上改运动目标
struct ExerciseGoalButton: View {
    @EnvironmentObject private var theme: AppTheme
    let goal: Int
    let onSet: (Int) -> Void
    @State private var asking = false
    @State private var draft = ""

    var body: some View {
        Button { draft = String(goal); asking = true } label: {
            Text("运动目标").font(Typo.sans(11, .medium)).foregroundStyle(theme.ink)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Capsule().fill(.regularMaterial))
        }
        .buttonStyle(.plain)
        .padding(8)
        .alert("每天运动消耗目标", isPresented: $asking) {
            TextField("千卡", text: $draft).keyboardType(.numberPad)
            Button("存") { if let n = Int(draft), n > 0 { onSet(min(n, 9999)) } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只用来画今日饮食上那条进度，单位是千卡。")
        }
    }
}

// MARK: 今日一牌：点开写一句问题，翻一张；今天翻过了，点开就是这一局

/// 今天翻的那张记在手机上（本机和连 Host 各记各的，牌局编号不通用）
struct DailyTarotMemo: Codable, Equatable {
    let date: String
    let readingID: Int
    let card: String
    let reversed: Bool
    let name: String

    private static var key: String { Lite.hosted ? "dailyTarot-host" : "dailyTarot" }

    @MainActor static func today() -> DailyTarotMemo? {
        guard let d = UserDefaults.standard.data(forKey: key),
              let m = try? JSONDecoder().decode(DailyTarotMemo.self, from: d), m.date == FoodStore.today() else { return nil }
        return m
    }

    func save() {
        if let d = try? JSONEncoder().encode(self) { UserDefaults.standard.set(d, forKey: Self.key) }
    }

    var face: TarotCardDTO { TarotCardDTO(position: "", card: card, reversed: reversed) }
}

struct DailyTarotCard: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var theme: AppTheme
    let size: WidgetSize
    @State private var memo = DailyTarotMemo.today()
    @State private var asking = false
    @State private var reading: TarotReadingDTO?

    var body: some View {
        Button { Task { await tap() } } label: {
            Group {
                if size == .small {
                    VStack(spacing: 6) {
                        card(width: 62)
                        caption.multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    HStack(spacing: 14) {
                        card(width: size == .large ? 110 : 62)
                        caption.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $asking, onDismiss: { memo = DailyTarotMemo.today() }) {
            DailyTarotSheet().environmentObject(model).environmentObject(theme)
                .presentationDetents([.large])
        }
        .fullScreenCover(item: $reading) { r in
            TarotReadingView(reading: r).environmentObject(model).environmentObject(theme)
        }
        .task {
            while !Task.isCancelled {       // 过了零点换回牌背
                memo = DailyTarotMemo.today()
                try? await Task.sleep(for: widgetRefresh)
            }
        }
    }

    @ViewBuilder private func card(width: CGFloat) -> some View {
        if let memo {
            TarotCardFace(card: memo.face, width: width)
        } else {
            TarotCardBack(width: width, glow: false)
        }
    }

    private var caption: some View {
        VStack(alignment: size == .small ? .center : .leading, spacing: 2) {
            Text("今日一牌").font(Typo.sans(Typo.Size.caption, .medium)).foregroundStyle(theme.inkDim)
            if let memo {
                Text(memo.name)
                    .font(Typo.sans(Typo.Size.callout, .semibold))
                    .foregroundStyle(theme.ink)
                    .lineLimit(2)
            }
        }
    }

    private func tap() async {
        memo = DailyTarotMemo.today()
        guard let memo else { asking = true; return }
        if let r: TarotReadingDTO = try? await model.api.call("GET", "tarot/readings/\(memo.readingID)") {
            reading = r
        } else {
            NotificationCenter.default.post(name: .lumiOpenTarot, object: nil)   // 那一局删掉了：去塔罗房间
        }
    }
}

/// 写问题 → 翻牌 → 看牌，想看解读再进牌局页
private struct DailyTarotSheet: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var theme: AppTheme
    @Environment(\.dismiss) private var dismiss
    @AppStorage("tarotDark") private var tarotDark = true
    @State private var question = ""
    @State private var result: TarotReadingDTO?
    @State private var angle = 0.0
    @State private var busy = false
    @State private var error: String?
    @State private var opening: TarotReadingDTO?
    @FocusState private var typing: Bool

    private var ink: Color { tarotDark ? .white : theme.ink }
    private var drawn: TarotCardDTO? { result?.cards.first }

    var body: some View {
        ZStack {
            TarotBackground(dark: tarotDark).ignoresSafeArea()
            VStack(spacing: 20) {
                HStack {
                    Text("今日一牌").font(Typo.sans(Typo.Size.headline, .semibold))
                    Spacer()
                    Button("关闭") { dismiss() }.font(Typo.sans(Typo.Size.callout))
                }
                .foregroundStyle(ink)
                Spacer(minLength: 0)
                if let drawn {
                    TarotFlipCard(angle: angle, card: drawn, width: 170)
                        .onAppear { withAnimation(.easeInOut(duration: 0.7)) { angle = 180 } }
                } else {
                    TarotCardBack(width: 170, glow: !busy)
                }
                if let drawn, angle == 180 {
                    VStack(spacing: 6) {
                        Text(drawn.name).font(Typo.sans(Typo.Size.headline, .semibold))
                        Text(drawn.keywords.joined(separator: " · ")).font(Typo.sans(Typo.Size.caption)).opacity(0.75)
                    }
                    .foregroundStyle(ink)
                    .multilineTextAlignment(.center)
                    .transition(.opacity)
                }
                Spacer(minLength: 0)
                if let result {
                    if !result.question.isEmpty {
                        Text("「\(result.question)」").font(Typo.sans(Typo.Size.callout)).foregroundStyle(ink.opacity(0.8))
                            .multilineTextAlignment(.center)
                    }
                    Button { opening = result } label: {
                        Text("看解读").font(Typo.sans(Typo.Size.body, .semibold))
                            .frame(maxWidth: .infinity).padding(.vertical, 12)
                            .background(Capsule().fill(theme.accent)).foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                } else {
                    TextField("", text: $question, prompt: Text("今天想问什么？").foregroundStyle(ink.opacity(0.5)), axis: .vertical)
                        .lineLimit(1...3)
                        .focused($typing)
                        .font(Typo.sans(Typo.Size.body))
                        .foregroundStyle(ink)
                        .padding(14)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(ink.opacity(0.1)))
                    if let error { Text(error).font(Typo.sans(Typo.Size.caption)).foregroundStyle(.red) }
                    Button { Task { await draw() } } label: {
                        Text(busy ? "正在洗牌…" : "翻牌").font(Typo.sans(Typo.Size.body, .semibold))
                            .frame(maxWidth: .infinity).padding(.vertical, 12)
                            .background(Capsule().fill(theme.accent)).foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .disabled(busy)
                }
            }
            .padding(20)
        }
        .fullScreenCover(item: $opening) { r in
            TarotReadingView(reading: r).environmentObject(model).environmentObject(theme)
        }
    }

    private func draw() async {
        typing = false
        busy = true
        error = nil
        defer { busy = false }
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let deck = try await TarotAPI.deck(model.api, trail: UUID().uuidString)
            let reader = model.recentCompanion?.id
            let r = try await TarotAPI.save(model.api, deck: deck.deckID, spread: "single",
                                            question: q.isEmpty ? String(localized: "今天") : q,
                                            reader: reader, from: reader, picks: [0], mode: "auto")
            if let c = r.cards.first {
                DailyTarotMemo(date: FoodStore.today(), readingID: r.id, card: c.card, reversed: c.reversed, name: c.name).save()
            }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            result = r
        } catch {
            self.error = (error as? APIError)?.message ?? String(localized: "没抽成，再试一次")
        }
    }
}

// MARK: 翻到一句：从收藏里随机翻一句，底图自己换，点一下回到那天

struct QuoteCard: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var theme: AppTheme
    @ObservedObject private var favorites = FavoritesStore.shared
    let size: WidgetSize
    let photo: String?
    @State private var current: FavoriteDTO?
    @State private var moment: QuoteMoment?
    @State private var gone = false

    private struct QuoteMoment: Identifiable {
        let companion: UUID
        let conversation: UUID
        let message: Int
        var id: Int { message }
    }

    private var image: UIImage? { WidgetPhotos.image(photo) }
    private var ink: Color { image != nil || theme.homeLabelIsLight ? .white : theme.ink }

    var body: some View {
        Button { jump() } label: {
            GeometryReader { geo in
                ZStack(alignment: .bottomLeading) {
                    background(geo.size)
                    content
                }
                .clipShape(RoundedRectangle(cornerRadius: Radii.card, style: .continuous))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fullScreenCover(item: $moment) { m in
            MomentRoom(companionID: m.companion, conversation: m.conversation, anchor: m.message, api: model.api)
        }
        .alert("那个窗口已经删掉了", isPresented: $gone) {
            Button("好") {}
        } message: {
            Text("收藏还留着，只是回不到原来的位置了。")
        }
        .task {
            await favorites.load(model.api)
            pick()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in pick() }
        .onChange(of: favorites.items) { _, items in
            if let c = current, !items.contains(c) { pick() } else if current == nil { pick() }
        }
    }

    @ViewBuilder private func background(_ size: CGSize) -> some View {
        if let image {
            Image(uiImage: image).resizable().scaledToFill()
                .frame(width: size.width, height: size.height).clipped()
                .overlay {
                    LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
                }
        } else {
            Rectangle().fill(.ultraThinMaterial)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(current?.text ?? String(localized: "还没有收藏。长按 TA 的话，点「收藏」，这里就会翻到。"))
                .font(Typo.sans(self.size == .small ? Typo.Size.callout : Typo.Size.body, .medium))
                .foregroundStyle(ink)
                .lineLimit(self.size == .large ? 10 : self.size == .medium ? 4 : 5)
            if let current {
                Text(verbatim: footer(current)).font(Typo.sans(11)).foregroundStyle(ink.opacity(0.75)).lineLimit(1)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func footer(_ f: FavoriteDTO) -> String {
        let day = f.saidAt.formatted(.dateTime.year().month().day())
        guard let name = model.companion(f.companionID)?.name, !name.isEmpty else { return day }
        return "\(name) · \(day)"
    }

    /// TA 说的优先；你只收过自己的话就翻你自己的
    private func pick() {
        let texts = favorites.items.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let theirs = texts.filter { !$0.mine }
        current = (theirs.isEmpty ? texts : theirs).randomElement()
    }

    private func jump() {
        guard let f = current else { return }
        if (model.conversations[f.companionID] ?? []).contains(where: { $0.id == f.conversationID }) {
            moment = QuoteMoment(companion: f.companionID, conversation: f.conversationID, message: f.messageID)
        } else {
            gone = true
        }
    }
}
