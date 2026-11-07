import SwiftUI

/// 内测反馈小卡片（11-03 Aporia：群里 50 个人只有 7 个给反馈）：在 3 个不同的日子打开过 App 就弹一次，
/// 四个问题都能点着答，想多说的再写一行。交到推送中转 /feedback（relay/worker.js），Aporia用 tools/read_feedback.sh 读。
/// 关法：交了 / 「我已经反馈过了」= 这一轮不再弹；× = 过 3 天再说，叉两次就不来了。换一轮内测改 round 就会重新问。
enum FeedbackGate {
    static let round = "一测"
    private static let d = UserDefaults.standard
    private static let daysKey = "feedback.days", snoozeKey = "feedback.snoozeUntil", snoozesKey = "feedback.snoozes"
    private static var doneKey: String { "feedback.done.\(round)" }

    /// 每次回前台记一笔今天（按本地日期，同一天只算一次）
    static func noteOpen(_ now: Date = Date()) {
        var days = d.stringArray(forKey: daysKey) ?? []
        let today = dayString(now)
        guard !days.contains(today) else { return }
        days.append(today)
        d.set(Array(days.suffix(30)), forKey: daysKey)
    }

    static var daysUsed: Int { (d.stringArray(forKey: daysKey) ?? []).count }

    static func due(_ now: Date = Date()) -> Bool {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-feedbackCard") { return true }   // 截图自测
        #endif
        guard !d.bool(forKey: doneKey), daysUsed >= 3, d.integer(forKey: snoozesKey) < 2 else { return false }
        return (d.object(forKey: snoozeKey) as? Date).map { now >= $0 } ?? true
    }

    static func snooze(_ now: Date = Date()) {
        d.set(d.integer(forKey: snoozesKey) + 1, forKey: snoozesKey)
        d.set(now.addingTimeInterval(3 * 86400), forKey: snoozeKey)
    }

    static func markDone() { d.set(true, forKey: doneKey) }

    /// 只用来防连点交两份（中转那边一小时只收同一台的一份），不跟别的东西挂钩
    static var install: String {
        if let id = d.string(forKey: "feedback.install") { return id }
        let id = UUID().uuidString.lowercased()
        d.set(id, forKey: "feedback.install")
        return id
    }

    private static func dayString(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}

struct FeedbackCard: View {
    @EnvironmentObject private var theme: AppTheme
    let api: APIClient
    let onClose: () -> Void

    @State private var problems = ""
    @State private var problemsNote = ""
    @State private var memory = ""
    @State private var memoryNote = ""
    @State private var oneThing = ""
    @State private var oneThingNote = ""
    @State private var recommend = ""
    @State private var name = ""
    @State private var sending = false
    @State private var failed = false
    @State private var copied = false
    @State private var thanked = false
    @State private var shown = false

    private static let problemChoices = [("none", "没有，挺顺的"), ("some", "有一点"), ("many", "挺多的")]
    private static let memoryChoices = [("good", "记得很好"), ("mixed", "偶尔记错、记混"), ("forgot", "忘过重要的事")]
    private static let oneThingChoices = [("memory", "记性更准"), ("reach", "更会主动找我"), ("voice", "说话更像 TA"),
                                          ("stable", "更稳定、少点 bug"), ("speed", "回得更快"), ("cost", "更省钱"), ("other", "其他")]
    private static let recommendChoices = [("yes", "愿意"), ("maybe", "看情况"), ("no", "暂时不会")]

    static let milk = Color(red: 0.996, green: 0.984, blue: 0.965)

    private var ready: Bool {
        !problems.isEmpty && !memory.isEmpty && !oneThing.isEmpty
            && (oneThing != "other" || !oneThingNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    var body: some View {
        ZStack {
            // 11-03 Aporia：毛玻璃 + 奶白色的模糊底（原来是压暗）
            Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
                .overlay(Self.milk.opacity(0.55).ignoresSafeArea())
            card
                .frame(maxWidth: 380)
                .padding(.horizontal, 18)
                .padding(.vertical, 40)
                .scaleEffect(shown ? 1 : 0.94)
                .opacity(shown ? 1 : 0)
        }
        .environment(\.colorScheme, .light)
        .onAppear { withAnimation(.spring(response: 0.38, dampingFraction: 0.84)) { shown = true } }
    }

    private var card: some View {
        VStack(spacing: 0) {
            header
            if thanked {
                thanks
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        question(1, "有没有出过什么问题，哪里不太方便？", choices: Self.problemChoices, pick: $problems,
                                 note: $problemsNote, noteWhen: problems == "some" || problems == "many",
                                 hint: "哪里？什么时候？（选填）")
                        question(2, "记性如何，有没有记错、记混、忘掉重要的事情？", choices: Self.memoryChoices, pick: $memory,
                                 note: $memoryNote, noteWhen: memory == "mixed" || memory == "forgot",
                                 hint: "记错了什么？（选填）")
                        question(3, "如果二测只能修一个问题、或只加一个功能，你选什么？", choices: Self.oneThingChoices, pick: $oneThing,
                                 note: $oneThingNote, noteWhen: !oneThing.isEmpty,
                                 hint: oneThing == "other" ? "写一下是什么" : "想多说一句（选填）")
                        question(4, "你愿意把 Mele 推荐给别人或 repo 吗？", optional: true, choices: Self.recommendChoices,
                                 pick: $recommend, note: .constant(""), noteWhen: false, hint: "")
                        VStack(alignment: .leading, spacing: 6) {
                            Text("怎么称呼你（选填，不填就是匿名）")
                                .font(Typo.sans(Typo.Size.caption, .medium)).foregroundStyle(theme.inkFaint)
                            field("比如群里的昵称", text: $name)
                        }
                    }
                    .padding(.horizontal, 22).padding(.top, 6).padding(.bottom, 18)
                }
                .scrollDismissesKeyboard(.interactively)
                footer
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 30, style: .continuous).fill(.regularMaterial)
                .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous).fill(Self.milk.opacity(0.45)))
        }
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous).strokeBorder(Color.white.opacity(0.8), lineWidth: 1))
        .shadow(color: Color(red: 0.55, green: 0.48, blue: 0.4).opacity(0.14), radius: 28, y: 10)
        .fixedSize(horizontal: false, vertical: thanked)
    }

    private var header: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 8) {
                Image(systemName: "envelope.open.fill")
                    .font(Typo.icon(22))
                    .foregroundStyle(theme.accentDeep)
                    .frame(width: 52, height: 52)
                    .background(Circle().fill(theme.accentSoft.opacity(0.45)))
                Text("用了三天啦").font(Typo.sans(Typo.Size.headline, .semibold)).foregroundStyle(theme.ink)
                Text("四个小问题，点几下就好。\n你说的每一句，二测都会看着改。")
                    .font(Typo.sans(Typo.Size.callout)).foregroundStyle(theme.inkDim)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 26).padding(.bottom, 16).padding(.horizontal, 22)
            .background(LinearGradient(colors: [theme.accentSoft.opacity(0.22), .clear], startPoint: .top, endPoint: .bottom))
            if !thanked {
                Button {
                    FeedbackGate.snooze()
                    close()
                } label: {
                    Image(systemName: "xmark").font(Typo.icon(13, .semibold)).foregroundStyle(theme.inkFaint)
                        .frame(width: 34, height: 34).background(Circle().fill(Color.white.opacity(0.6)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "过几天再说"))
                .padding(14)
            }
        }
    }

    private func question(_ no: Int, _ title: String, optional: Bool = false, choices: [(String, String)],
                          pick: Binding<String>, note: Binding<String>, noteWhen: Bool, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(no)").font(Typo.sans(Typo.Size.caption, .bold)).foregroundStyle(.white)
                    .frame(width: 20, height: 20).background(Circle().fill(pick.wrappedValue.isEmpty ? theme.inkFaint.opacity(0.5) : theme.accentDeep))
                (Text(title).foregroundStyle(theme.ink)
                 + Text(optional ? String(localized: "（选填）") : "").foregroundStyle(theme.inkFaint))
                    .font(Typo.sans(Typo.Size.callout, .semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            FlowChips(items: choices, selected: pick.wrappedValue.isEmpty ? [] : [pick.wrappedValue]) { id in
                withAnimation(.snappy) { pick.wrappedValue = pick.wrappedValue == id ? "" : id }
            }
            .padding(.leading, 28)
            if noteWhen {
                field(hint, text: note).padding(.leading, 28)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func field(_ hint: String, text: Binding<String>) -> some View {
        TextField(hint, text: text, axis: .vertical)
            .lineLimit(1...4)
            .font(Typo.sans(Typo.Size.callout))
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.6)))
    }

    private var footer: some View {
        VStack(spacing: 10) {
            if failed {
                // 11-05 内测：国内打不开 workers.dev，Lite 本机怎么点都交不上。退一步：复制下来发到群里也算交了
                VStack(spacing: 6) {
                    Text("没交上去（国内有时连不上）。可以复制下来，发到内测群里")
                        .font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkDim).multilineTextAlignment(.center)
                    Button {
                        UIPasteboard.general.string = summary
                        withAnimation(.snappy) { copied = true }
                    } label: {
                        Label(copied ? "复制好了" : "复制我的回答", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .font(Typo.sans(Typo.Size.caption, .semibold)).foregroundStyle(theme.accentDeep)
                    }
                    .buttonStyle(.plain)
                }
            }
            Button { Task { await send() } } label: {
                Group {
                    if sending { ProgressView().tint(.white) } else { Text("交了") }
                }
                .font(Typo.sans(Typo.Size.callout, .semibold)).foregroundStyle(ready ? .white : theme.inkFaint)
                .frame(maxWidth: .infinity).padding(.vertical, 13)
                .background(Capsule().fill(ready ? theme.accentDeep : Color.white.opacity(0.6)))
            }
            .buttonStyle(.plain)
            .disabled(!ready || sending)
            Button {
                FeedbackGate.markDone()
                close()
            } label: {
                Text("我已经反馈过了").font(Typo.sans(Typo.Size.caption, .medium)).foregroundStyle(theme.inkDim)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 22).padding(.top, 12).padding(.bottom, 18)
        .overlay(alignment: .top) { Divider().opacity(0.4) }
    }

    private var thanks: some View {
        VStack(spacing: 8) {
            Image(systemName: "heart.fill").font(Typo.icon(20)).foregroundStyle(theme.accentDeep)
            Text("收到啦，谢谢你").font(Typo.sans(Typo.Size.headline, .semibold)).foregroundStyle(theme.ink)
        }
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity)
        .transition(.opacity)
    }

    private func close() {
        withAnimation(.easeOut(duration: 0.2)) { shown = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { onClose() }
    }

    private func send() async {
        sending = true
        failed = false
        defer { sending = false }
        let info = Bundle.main.infoDictionary
        let body: [String: Any] = [
            "round": FeedbackGate.round, "install": FeedbackGate.install, "days": FeedbackGate.daysUsed,
            "version": "\(info?["CFBundleShortVersionString"] as? String ?? "") (\(info?["CFBundleVersion"] as? String ?? ""))",
            "mode": Lite.local ? "lite" : Lite.hosted ? "host" : "app",
            "name": name.trimmingCharacters(in: .whitespacesAndNewlines),
            "answers": ["problems": label(Self.problemChoices, problems), "problems_note": problemsNote,
                        "memory": label(Self.memoryChoices, memory), "memory_note": memoryNote,
                        "one_thing": label(Self.oneThingChoices, oneThing), "one_thing_note": oneThingNote,
                        "recommend": label(Self.recommendChoices, recommend)],
        ]
        var req = URLRequest(url: PushRelay.base.appendingPathComponent("feedback"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 15
        var sent = (try? await URLSession.shared.data(for: req)).map { ($0.1 as? HTTPURLResponse)?.statusCode == 200 } ?? false
        // 国内打不开 workers.dev（11-05）：连着 Host 的交给 Host 代交（Host 的 /me/feedback 原样转给中转）
        if !sent, Lite.hosted { sent = (try? await api.raw("POST", "me/feedback", json: body)) != nil }
        guard sent else {
            failed = true
            return
        }
        FeedbackGate.markDone()
        withAnimation(.snappy) { thanked = true }
        try? await Task.sleep(for: .seconds(1.4))
        close()
    }

    /// 交不上时复制的那段：跟 read_feedback 打出来的一个样
    private var summary: String {
        func line(_ no: Int, _ q: String, _ a: String, _ note: String) -> String {
            "\(no). \(q)\n" + (a.isEmpty ? "—" : a) + (note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : "：\(note.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return ["【Mele 反馈】" + (name.trimmingCharacters(in: .whitespaces).isEmpty ? "" : "（\(name.trimmingCharacters(in: .whitespaces))）"),
                line(1, "有没有出过什么问题", label(Self.problemChoices, problems), problemsNote),
                line(2, "记性如何", label(Self.memoryChoices, memory), memoryNote),
                line(3, "二测只修一个 / 只加一个", label(Self.oneThingChoices, oneThing), oneThingNote),
                line(4, "愿意推荐吗", label(Self.recommendChoices, recommend), "")].joined(separator: "\n\n")
    }

    /// 存中文字面（Aporia读的时候一眼看懂），不存内部编号
    private func label(_ choices: [(String, String)], _ id: String) -> String {
        choices.first { $0.0 == id }?.1 ?? ""
    }
}
