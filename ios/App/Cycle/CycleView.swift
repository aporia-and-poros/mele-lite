import SwiftUI

// MARK: - 经期页（11-15）：顶上一张状态卡（环 + 第几天 / 还有几天）、今天一键记、月历、最近几次

extension Notification.Name {
    static let lumiOpenCycle = Notification.Name("LumiOpenCycle")
}

struct CycleRoomView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var theme: AppTheme
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = CycleStore.shared
    @State private var month = Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: Date()))!
    @State private var editing: CycleEditTarget?
    @State private var showSettings = false

    private let cal = Calendar.current

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    statusCard
                    todayRow
                    monthCard
                    if store.periods.count > 0 { historyCard }
                    Text("记录只存在这台手机上；打开苹果健康同步后，流量也会存一份到「健康」。")
                        .font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkFaint)
                        .multilineTextAlignment(.center).padding(.horizontal, 24).padding(.top, 4)
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
            }
            .background(AppBackground())
            .navigationTitle("经期")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关上") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { showSettings = true } label: { Image(systemName: "slider.horizontal.3") }
                }
            }
            .sheet(item: $editing) { t in
                CycleDayEditor(date: t.date).environmentObject(theme)
                    .presentationDetents([.large])
            }
            .sheet(isPresented: $showSettings) {
                CycleSettingsView().environmentObject(theme)
            }
        }
        .environment(\.colorScheme, .light)
        .task {
            store.primaryCompanionID = model.primaryCompanion?.id.uuidString.lowercased()
            await store.importHealth()
            await store.report()
        }
    }

    // MARK: 状态卡

    private var statusCard: some View {
        PhoneGlassCard(padding: 20) {
            HStack(spacing: 20) {
                ring
                VStack(alignment: .leading, spacing: 6) {
                    Text(headline.small).font(Typo.sans(Typo.Size.callout)).foregroundStyle(theme.inkDim)
                    Text(headline.big).font(Typo.number(30)).foregroundStyle(theme.ink)
                        .minimumScaleFactor(0.6).lineLimit(1)
                    if store.hasHistory {
                        Text(String(localized: "平均周期 \(store.averageCycle) 天 · 经期 \(store.averagePeriod) 天"))
                            .font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkFaint)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var headline: (small: String, big: String) {
        switch store.status {
        case .none: return (String(localized: "还没有记录"), String(localized: "从今天记起"))
        case .inPeriod(let n): return (String(localized: "经期"), String(localized: "第 \(n) 天"))
        case .upcoming(let d):
            if d == 0 { return (String(localized: "预计"), String(localized: "今天来")) }
            if d == 1 { return (String(localized: "预计"), String(localized: "明天来")) }
            return (String(localized: "预计还有"), String(localized: "\(d) 天"))
        case .late(let d): return (String(localized: "比预计晚了"), String(localized: "\(d) 天"))
        }
    }

    /// 环：这一个周期走到哪了（经期那段用主题色，剩下的淡）
    private var ring: some View {
        let total = Double(store.averageCycle)
        let since: Double = {
            guard let s = store.periods.last?.start else { return 0 }
            return Double(cal.dateComponents([.day], from: s, to: store.today).day ?? 0)
        }()
        let progress = store.hasHistory ? min(1, max(0, since / total)) : 0
        let periodShare = store.hasHistory ? min(1, Double(store.averagePeriod) / total) : 0
        return ZStack {
            Circle().stroke(theme.accentSoft.opacity(0.55), lineWidth: 9)
            Circle().trim(from: 0, to: periodShare)
                .stroke(theme.accent.opacity(0.35), style: StrokeStyle(lineWidth: 9, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Circle().trim(from: 0, to: progress)
                .stroke(theme.accent, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: "drop.fill").font(Typo.icon(22)).foregroundStyle(theme.accent)
        }
        .frame(width: 78, height: 78)
        .animation(.snappy, value: progress)
    }

    // MARK: 今天

    private var todayRow: some View {
        let on = store.isPeriod(store.today)
        return HStack(spacing: 10) {
            Button {
                UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                withAnimation(.snappy) { store.togglePeriod(store.today) }
            } label: {
                Label(String(localized: "今天来了"), systemImage: on ? "checkmark.circle.fill" : "drop.fill")
                    .font(Typo.sans(Typo.Size.body, .semibold))
                    .frame(maxWidth: .infinity).padding(.vertical, 13)
                    .foregroundStyle(on ? theme.accentDeep : .white)
                    .background(Capsule().fill(on ? theme.accentSoft : theme.accent))
            }
            .buttonStyle(.plain)
            Button { editing = CycleEditTarget(date: store.today) } label: {
                Label(String(localized: "记录今天"), systemImage: "square.and.pencil")
                    .font(Typo.sans(Typo.Size.body, .semibold))
                    .frame(maxWidth: .infinity).padding(.vertical, 13)
                    .foregroundStyle(theme.accentDeep)
                    .background(Capsule().fill(.ultraThinMaterial))
                    .overlay(Capsule().stroke(theme.accent.opacity(0.35), lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: 月历

    private var monthCard: some View {
        PhoneGlassCard(padding: 16) {
            VStack(spacing: 12) {
                HStack {
                    Text(month.formatted(.dateTime.year().month(.wide)))
                        .font(Typo.sans(Typo.Size.headline, .semibold)).foregroundStyle(theme.ink)
                    Spacer()
                    Button { shift(-1) } label: { Image(systemName: "chevron.left").frame(width: 32, height: 32) }
                    Button { shift(1) } label: { Image(systemName: "chevron.right").frame(width: 32, height: 32) }
                }
                .font(Typo.icon(15, .semibold)).foregroundStyle(theme.accentDeep)
                let symbols = weekdaySymbols
                HStack(spacing: 0) {
                    ForEach(symbols.indices, id: \.self) { i in
                        Text(symbols[i]).font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkFaint)
                            .frame(maxWidth: .infinity)
                    }
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 6) {
                    ForEach(cells, id: \.self) { d in
                        if let d { dayCell(d) } else { Color.clear.frame(height: 40) }
                    }
                }
                legend
            }
        }
        .gesture(DragGesture(minimumDistance: 30).onEnded { v in
            if v.translation.width < -40 { shift(1) } else if v.translation.width > 40 { shift(-1) }
        })
    }

    private func dayCell(_ d: Date) -> some View {
        let k = store.key(d)
        let entry = store.days[k]
        let period = (entry?.flow ?? 0) > 0
        let predicted = store.predictedDays.contains(k)
        let isToday = cal.isDate(d, inSameDayAs: store.today)
        let marked = !(entry?.symptoms.isEmpty ?? true) || entry?.mood != nil || !(entry?.note.isEmpty ?? true)
        return Button { editing = CycleEditTarget(date: d) } label: {
            VStack(spacing: 2) {
                ZStack {
                    if period {
                        Circle().fill(theme.accent)
                    } else if predicted {
                        Circle().strokeBorder(theme.accent.opacity(0.7), style: StrokeStyle(lineWidth: 1.4, dash: [3, 3]))
                    } else if isToday {
                        Circle().strokeBorder(theme.ink.opacity(0.35), lineWidth: 1.2)
                    }
                    Text("\(cal.component(.day, from: d))")
                        .font(Typo.sans(Typo.Size.body, isToday ? .bold : .regular))
                        .foregroundStyle(period ? .white : d > store.today ? theme.inkDim : theme.ink)
                }
                .frame(width: 34, height: 34)
                Circle().fill(marked ? theme.accentDeep.opacity(0.7) : .clear).frame(width: 4, height: 4)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var legend: some View {
        HStack(spacing: 16) {
            HStack(spacing: 5) { Circle().fill(theme.accent).frame(width: 9, height: 9); Text("经期") }
            HStack(spacing: 5) {
                Circle().strokeBorder(theme.accent.opacity(0.7), style: StrokeStyle(lineWidth: 1.2, dash: [2, 2]))
                    .frame(width: 9, height: 9)
                Text("预测")
            }
            HStack(spacing: 5) { Circle().fill(theme.accentDeep.opacity(0.7)).frame(width: 4, height: 4); Text("有记录") }
            Spacer()
        }
        .font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkDim)
    }

    private var weekdaySymbols: [String] {
        let s = cal.veryShortStandaloneWeekdaySymbols
        let first = cal.firstWeekday - 1
        return Array(s[first...] + s[..<first])
    }

    private var cells: [Date?] {
        guard let range = cal.range(of: .day, in: .month, for: month) else { return [] }
        let lead = (cal.component(.weekday, from: month) - cal.firstWeekday + 7) % 7
        return Array(repeating: nil, count: lead) + range.compactMap { cal.date(byAdding: .day, value: $0 - 1, to: month) }
    }

    private func shift(_ n: Int) {
        if let m = cal.date(byAdding: .month, value: n, to: month) { withAnimation(.snappy) { month = m } }
    }

    // MARK: 最近几次

    private var historyCard: some View {
        let list = Array(store.periods.suffix(6).reversed())
        return PhoneGlassCard(padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                Text("最近几次").font(Typo.sans(Typo.Size.headline, .semibold)).foregroundStyle(theme.ink)
                ForEach(list.indices, id: \.self) { i in
                    let p = list[i]
                    let next = i > 0 ? list[i - 1] : nil
                    HStack {
                        Text(p.start.formatted(.dateTime.month().day()) + " – " + p.end.formatted(.dateTime.month().day()))
                            .font(Typo.sans(Typo.Size.body)).foregroundStyle(theme.ink)
                        Spacer()
                        Text(String(localized: "\(p.days) 天")).font(Typo.sans(Typo.Size.callout)).foregroundStyle(theme.inkDim)
                        if let next, let gap = cal.dateComponents([.day], from: p.start, to: next.start).day {
                            Text(String(localized: "周期 \(gap) 天")).font(Typo.sans(Typo.Size.callout))
                                .foregroundStyle(theme.inkFaint).frame(width: 72, alignment: .trailing)
                        } else {
                            Color.clear.frame(width: 72, height: 1)
                        }
                    }
                    if i < list.count - 1 { Divider().opacity(0.5) }
                }
            }
        }
    }
}

struct CycleEditTarget: Identifiable {
    let date: Date
    var id: Date { date }
}

// MARK: - 某一天

struct CycleDayEditor: View {
    let date: Date
    @EnvironmentObject private var theme: AppTheme
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = CycleStore.shared
    @State private var draft = CycleDay()
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    section(String(localized: "这天来了吗")) {
                        Picker("", selection: Binding(get: { (draft.flow ?? 0) > 0 },
                                                      set: { draft.flow = $0 ? (draft.flow ?? 2) : nil })) {
                            Text("没来").tag(false)
                            Text("来了").tag(true)
                        }
                        .pickerStyle(.segmented)
                    }
                    if (draft.flow ?? 0) > 0 {
                        section(String(localized: "流量")) {
                            HStack(spacing: 8) {
                                ForEach(CycleCatalog.flows, id: \.0) { f, name in
                                    chip(selected: draft.flow == f) {
                                        VStack(spacing: 4) {
                                            HStack(spacing: 1) {
                                                ForEach(0..<f, id: \.self) { _ in Image(systemName: "drop.fill").font(Typo.icon(9)) }
                                            }
                                            Text(name).font(Typo.sans(Typo.Size.callout))
                                        }
                                        .frame(maxWidth: .infinity)
                                    } action: { draft.flow = f }
                                }
                            }
                        }
                    }
                    section(String(localized: "症状")) {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                            ForEach(CycleCatalog.symptoms, id: \.id) { s in
                                chip(selected: draft.symptoms.contains(s.id)) {
                                    Label(String(localized: String.LocalizationValue(s.zh)), systemImage: s.symbol)
                                        .font(Typo.sans(Typo.Size.callout))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                } action: {
                                    if let i = draft.symptoms.firstIndex(of: s.id) { draft.symptoms.remove(at: i) }
                                    else { draft.symptoms.append(s.id) }
                                }
                            }
                        }
                    }
                    section(String(localized: "心情")) {
                        HStack(spacing: 6) {
                            ForEach(CycleCatalog.moods, id: \.id) { m in
                                chip(selected: draft.mood == m.id) {
                                    VStack(spacing: 2) {
                                        Text(m.emoji).font(.system(size: 20))
                                        Text(String(localized: String.LocalizationValue(m.zh))).font(Typo.sans(Typo.Size.caption))
                                    }
                                    .frame(maxWidth: .infinity)
                                } action: { draft.mood = draft.mood == m.id ? nil : m.id }
                            }
                        }
                    }
                    section(String(localized: "备注")) {
                        TextField(String(localized: "想记点什么"), text: $draft.note, axis: .vertical)
                            .lineLimit(1...4)
                            .font(Typo.sans(Typo.Size.body))
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: Radii.control, style: .continuous).fill(.ultraThinMaterial))
                    }
                    if draft.fromHealth {
                        Label(String(localized: "这天是从苹果健康读进来的"), systemImage: "heart.text.square")
                            .font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkFaint)
                    }
                }
                .padding(20)
            }
            .background(AppBackground())
            .navigationTitle(date.formatted(.dateTime.month().day().weekday(.wide)))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        store.set(date, draft)
                        dismiss()
                    }
                    .bold()
                }
            }
        }
        .environment(\.colorScheme, .light)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            draft = store.day(date)
        }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(Typo.sans(Typo.Size.callout, .semibold)).foregroundStyle(theme.inkDim)
            content()
        }
    }

    private func chip<L: View>(selected: Bool, @ViewBuilder label: () -> L, action: @escaping () -> Void) -> some View {
        Button {
            UISelectionFeedbackGenerator().selectionChanged()
            withAnimation(.snappy(duration: 0.18)) { action() }
        } label: {
            label()
                .padding(.vertical, 10).padding(.horizontal, 10)
                .foregroundStyle(selected ? theme.accentDeep : theme.inkDim)
                .background(RoundedRectangle(cornerRadius: Radii.bubble, style: .continuous)
                    .fill(selected ? theme.accentSoft : Color.white.opacity(0.55)))
                .overlay(RoundedRectangle(cornerRadius: Radii.bubble, style: .continuous)
                    .stroke(selected ? theme.accent.opacity(0.6) : Color.white.opacity(0.8), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 设置

struct CycleSettingsView: View {
    @EnvironmentObject private var theme: AppTheme
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = CycleStore.shared
    @State private var healthFailed = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    lengthRow(String(localized: "周期"), value: store.settings.cycleLength, auto: store.averageCycle, range: 18...50) {
                        store.settings.cycleLength = $0
                    }
                    lengthRow(String(localized: "经期"), value: store.settings.periodLength, auto: store.averagePeriod, range: 2...12) {
                        store.settings.periodLength = $0
                    }
                } header: { Text("预测") } footer: {
                    Text("自动：按最近 6 次记录取平均，记录不够两次时按 28 天 / 5 天算。手动定了就按你定的。")
                }
                Section {
                    Picker("提前提醒", selection: Binding(get: { store.settings.remindDays }, set: { store.settings.remindDays = $0 })) {
                        Text("不提醒").tag(0)
                        ForEach([1, 2, 3, 5], id: \.self) { Text(String(localized: "\($0) 天")).tag($0) }
                    }
                } header: { Text("提醒") } footer: {
                    Text("预计来的前几天上午 9 点，手机上推一条提醒。")
                }
                Section {
                    Toggle("同步苹果健康", isOn: Binding(get: { store.settings.healthSync }, set: { on in
                        if on {
                            Task { healthFailed = !(await store.enableHealth()) }
                        } else {
                            store.settings.healthSync = false
                        }
                    }))
                    .tint(theme.accent)
                    if healthFailed {
                        Text("没拿到「健康」的权限，可以去 设置 → 健康 → 数据访问 里给 Mele 打开「月经」。")
                            .font(Typo.sans(Typo.Size.caption)).foregroundStyle(.orange)
                    }
                } header: { Text("苹果健康") } footer: {
                    Text("打开后：「健康」里记过的经期会读进来；在这里记的流量也写一份进「健康」。症状和心情只留在 Mele。")
                }
                Section {
                    Picker("TA 知道你的经期", selection: Binding(get: { store.settings.share }, set: { store.settings.share = $0 })) {
                        Text("所有联系人").tag("all")
                        Text("只给主联系人").tag("main")
                        Text("不告诉").tag("off")
                    }
                } header: { Text("TA 知道") } footer: {
                    Text("经期里、快来的一周、推迟了的时候，TA 聊天时会看到一行「经期第 2 天，流量多，痛经」这样的情况，有变化才给。不告诉 = TA 一点都不知道。")
                }
            }
            .navigationTitle("经期设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("好") { dismiss() } } }
        }
    }

    private func lengthRow(_ title: String, value: Int?, auto: Int, range: ClosedRange<Int>,
                           set: @escaping (Int?) -> Void) -> some View {
        HStack {
            Text(title)
            Spacer()
            if let value {
                Stepper(String(localized: "\(value) 天"), value: Binding(get: { value }, set: { set($0) }), in: range)
                    .fixedSize()
                Button("自动") { set(nil) }.buttonStyle(.borderless).font(Typo.sans(Typo.Size.callout))
            } else {
                Text(String(localized: "自动 · \(auto) 天")).foregroundStyle(.secondary)
                Button("手动") { set(auto) }.buttonStyle(.borderless).font(Typo.sans(Typo.Size.callout))
            }
        }
    }
}
