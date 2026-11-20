import SwiftUI

/// 回声（Lite 本机，10-04 Aporia）：TA 的设定 → 记性 → 回声。一个窗口一本，按天一段；
/// 默认收着（回声会很长），点一天展开，能直接改；改成空 = 删掉这一天。
struct EchoView: View {
    @EnvironmentObject private var theme: AppTheme
    let companion: CompanionDTO

    private struct Book: Identifiable {
        let id: String            // 窗口
        let title: String
        var days: [(day: String, text: String)]
        let samples: [String]
        let at: String
        let fails: Int
    }
    @State private var books: [Book] = []
    @State private var loaded = false
    @State private var open: Set<String> = []          // "窗口|日子"
    @State private var drafts: [String: String] = [:]
    @State private var saved: String?
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("聊得久了，最早的那些会按天卷进这本账，原话就不再整段带着了。今天写得细、昨天少一点、更早的只剩一两句。写错了可以直接改；整段删空就是不要这一天。")
                    .font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkFaint)
                if loaded && books.isEmpty {
                    Text("还没卷过。聊到「记性长度」那么多的时候，第一段回声会出现在这里。")
                        .font(Typo.sans(Typo.Size.body)).foregroundStyle(theme.inkDim).padding(.top, 20)
                }
                ForEach(books) { b in bookView(b) }
            }
            .padding(20)
        }
        .background(AppBackground().ignoresSafeArea())
        .navigationTitle("回声")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func bookView(_ b: Book) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if books.count > 1 {
                Text(b.title).font(Typo.sans(Typo.Size.callout, .semibold)).foregroundStyle(theme.inkDim)
            }
            if let when = APIClient.parseDate(b.at) {     // 上次什么时候卷的（10-27 内测：Host 上看不到）
                Text("上次卷进账本：\(when.formatted(date: .abbreviated, time: .shortened))")
                    .font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkFaint)
            }
            if b.fails > 0 {
                Text("最近 \(b.fails) 次没卷成（写出来的对不上原文，先留着原话，下一轮再试）。")
                    .font(Typo.sans(Typo.Size.caption)).foregroundStyle(.orange)
            }
            ForEach(b.days, id: \.day) { d in dayRow(b.id, d.day, d.text) }
            if !b.samples.isEmpty {
                Text("腔调样本：卷走的话里留了 \(b.samples.count) 句 TA 自己的原话，接着说的时候照这个调子。")
                    .font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkFaint)
            }
        }
    }

    private func dayRow(_ conv: String, _ day: String, _ text: String) -> some View {
        let key = conv + "|" + day
        let isOpen = open.contains(key)
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.snappy) { if isOpen { open.remove(key) } else { open.insert(key); drafts[key] = drafts[key] ?? text } }
            } label: {
                HStack(spacing: 10) {
                    Text(Self.label(day)).font(Typo.sans(Typo.Size.callout, .semibold)).foregroundStyle(theme.ink)
                    Text(isOpen ? "" : text).font(Typo.sans(Typo.Size.callout)).foregroundStyle(theme.inkFaint).lineLimit(1)
                    Spacer(minLength: 4)
                    Text("\(text.count) 字").font(Typo.number(Typo.Size.caption)).foregroundStyle(theme.inkFaint)
                    Image(systemName: "chevron.down").font(Typo.icon(11, .semibold)).foregroundStyle(theme.inkFaint)
                        .rotationEffect(.degrees(isOpen ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isOpen {
                IMETextEditor(text: Binding(get: { drafts[key] ?? text }, set: { drafts[key] = $0 }), size: Typo.Size.body)
                    .font(Typo.sans(Typo.Size.body))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 140)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: Radii.control).fill(Color.white.opacity(0.7)))
                HStack {
                    if saved == key { Text("存好了").font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.accentDeep) }
                    Spacer()
                    Button("保存") { Task { await save(conv, day, key) } }
                        .font(Typo.sans(Typo.Size.callout, .semibold)).foregroundStyle(theme.accentDeep)
                        .disabled((drafts[key] ?? text) == text)
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.white.opacity(0.55)))
    }

    static func label(_ day: String) -> String {
        let p = day.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return day }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        if day == f.string(from: Date()) { return String(localized: "今天") }
        if let y = Calendar.current.date(byAdding: .day, value: -1, to: Date()), day == f.string(from: y) { return String(localized: "昨天") }
        return String(localized: "\(p[1])月\(p[2])日")
    }

    private func load() async {
        defer { loaded = true }
        guard let raw = try? await model.api.raw("GET", "companions/\(companion.id.uuidString.lowercased())/echo") as? [[String: Any]] else { return }
        books = raw.map { b in
            let alt = b["alt_name"] as? String ?? "", title = b["title"] as? String ?? ""
            return Book(id: b["conversation"] as? String ?? "",
                        title: !title.isEmpty ? title : !alt.isEmpty ? String(localized: "小号 · \(alt)") : String(localized: "窗口"),
                        days: (b["days"] as? [[String: Any]] ?? []).map { ($0["day"] as? String ?? "", $0["text"] as? String ?? "") },
                        samples: b["samples"] as? [String] ?? [], at: b["at"] as? String ?? "", fails: b["fails"] as? Int ?? 0)
        }
    }

    private func save(_ conv: String, _ day: String, _ key: String) async {
        let text = drafts[key] ?? ""
        _ = try? await model.api.raw("PUT", "conversations/\(conv)/echo", json: ["day": day, "text": text])
        saved = key
        await load()
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { open.remove(key) }
    }
}
