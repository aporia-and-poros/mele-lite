import SwiftUI

// MARK: - 日记（10-01，Aporia点头的设计 specs/2026-10-01-diary-design.md；朴素版，样子等统一调 UI）
//
// 每个写日记的联系人一本 + 我的（10-12：以前只有主联系人那本；别的联系人在设置里打开「写日记」才有）：
// - Ta 的：Ta 每天凌晨等你睡着了写前一天。正文你能看；它锁着的那段是一块模糊的 🔒，问它要钥匙（4 位数）才能开。
// - 我的：你自己写，可以锁起来（锁了 Ta 读不到）。没锁的 Ta 凌晨会读，在页边给你留一句。你的日记不进它的记忆。

extension Notification.Name {
    static let lumiOpenDiary = Notification.Name("LumiOpenDiary")
}

struct DiaryEntryDTO: Decodable, Identifiable, Hashable {
    let id: Int
    let author: String              // companion / user
    let day: String                 // yyyy-MM-dd
    let body: String
    var from: String?               // Ta 的：谁写的
    var companionID: String?        // Ta 的：哪个联系人（老数据 / 没有 = 主联系人）
    var hasLocked: Bool?            // Ta 的：有没有锁着的段
    var locked: String?             // Ta 的：打开过才有
    var `private`: Bool?            // 我的：锁起来了
    var margin: String?             // 我的：Ta 的页边批注
    var marginFrom: String?
    enum CodingKeys: String, CodingKey {
        case id, author, day, body, from, locked, `private`, margin
        case hasLocked = "has_locked", marginFrom = "margin_from", companionID = "companion_id"
    }

    var isMine: Bool { author == "user" }

    static let dayFormat: DateFormatter = {
        let f = DateFormatter(); f.calendar = Calendar(identifier: .gregorian); f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    var date: Date { Self.dayFormat.date(from: day) ?? Date() }
    var dayTitle: String { date.formatted(.dateTime.month().day().weekday(.abbreviated)) }
}

private struct UnlockDTO: Decodable { let id: Int; let locked: String }

struct DiaryView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var theme: AppTheme
    @Environment(\.dismiss) private var dismiss
    @State private var book = ""                // 联系人 id / "me"；空 = 主联系人那本
    @State private var entries: [DiaryEntryDTO] = []
    @State private var loaded = false
    @State private var more = false
    @State private var error: String?
    @State private var asking: DiaryEntryDTO?
    @State private var code = ""
    @State private var editing: DiaryEntryDTO?
    @State private var writing = false

    private static let page = 60
    private var taName: String { model.companions.first?.name ?? "Ta" }
    private var mainID: UUID? { model.companions.first?.id }
    /// 这篇是哪本：联系人 id；没写 / 联系人删了 = 主联系人
    private func owner(_ e: DiaryEntryDTO) -> UUID? {
        if let s = e.companionID, let id = UUID(uuidString: s), model.companions.contains(where: { $0.id == id }) { return id }
        return mainID
    }
    /// 有哪几本 Ta 的：主联系人一直在，别的写过才出现
    private var books: [CompanionDTO] {
        let wrote = Set(entries.filter { !$0.isMine }.compactMap(owner))
        return model.companions.enumerated().filter { $0.offset == 0 || wrote.contains($0.element.id) }.map(\.element)
    }
    private var current: CompanionDTO? {
        books.first { $0.id.uuidString == book } ?? model.companions.first
    }
    private var bookName: String { current?.name ?? "Ta" }
    private var shown: [DiaryEntryDTO] {
        book == "me" ? entries.filter(\.isMine) : entries.filter { !$0.isMine && owner($0) == current?.id }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if books.count > 2 {                     // 四本以上分段太挤：改成下拉
                        bookPicker.pickerStyle(.menu)
                    } else {
                        bookPicker.pickerStyle(.segmented)
                    }
                }
                if let error {
                    Text(error).font(Typo.sans(Typo.Size.callout)).foregroundStyle(.red)
                }
                if loaded && shown.isEmpty {
                    Text(book != "me"
                         ? String(localized: "\(bookName) 还没写过日记。每天凌晨等你睡着了，它会写前一天。")
                         : String(localized: "还没写过。点右上角写一篇；没锁的 \(taName) 凌晨会读，在页边给你留一句。"))
                        .font(Typo.sans(Typo.Size.callout)).foregroundStyle(theme.inkDim)
                        .listRowBackground(Color.clear)
                }
                ForEach(shown) { e in
                    Group {
                        if e.isMine { mine(e) } else { theirs(e) }
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .swipeActions {
                        if e.isMine {
                            Button(role: .destructive) { Task { await delete(e) } } label: { Label("删掉", systemImage: "trash") }
                        }
                    }
                }
                if more {
                    Button("更早的") { Task { await load(before: entries.last?.day) } }
                        .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(AppBackground())
            .navigationTitle("日记")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("合上") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { writing = true } label: { Image(systemName: "square.and.pencil") }
                }
            }
            .alert("输入钥匙", isPresented: Binding(get: { asking != nil }, set: { if !$0 { asking = nil } })) {
                TextField("4 位数", text: $code).keyboardType(.numberPad)
                Button("打开") { if let a = asking { Task { await unlock(a) } } }
                Button("取消", role: .cancel) {}
            } message: {
                Text(String(localized: "问 \(asking?.from ?? taName) 要的那串数字"))
            }
            .sheet(isPresented: $writing) {
                DiaryEditor(entry: nil, taName: taName) { await reloadAll(); book = "me" }
                    .environmentObject(model).environmentObject(theme)
            }
            .sheet(item: $editing) { e in
                DiaryEditor(entry: e, taName: taName) { await reloadAll() }
                    .environmentObject(model).environmentObject(theme)
            }
        }
        .environment(\.colorScheme, .light)
        .task { await reloadAll() }
    }

    private var bookPicker: some View {
        Picker("哪本", selection: Binding(get: { book == "me" ? "me" : current?.id.uuidString ?? "" }, set: { book = $0 })) {
            ForEach(books) { c in Text(String(localized: "\(c.name) 的")).tag(c.id.uuidString) }
            Text("我的").tag("me")
        }
        .listRowBackground(Color.clear)
    }

    // Ta 的一篇：日期、正文、锁着那段
    private func theirs(_ e: DiaryEntryDTO) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(e.dayTitle).font(Typo.sans(Typo.Size.caption, .semibold)).foregroundStyle(theme.inkDim)
            Text(e.body).font(Typo.sans(Typo.Size.body)).foregroundStyle(theme.ink).textSelection(.enabled)
            if let locked = e.locked {
                VStack(alignment: .leading, spacing: 4) {
                    Label("锁着的那段", systemImage: "lock.open").font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.accentDeep)
                    Text(locked).font(Typo.sans(Typo.Size.body)).foregroundStyle(theme.ink).textSelection(.enabled)
                }
            } else if e.hasLocked == true {
                Button { code = ""; asking = e } label: { lockedBlock(e) }.buttonStyle(.plain)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    private func lockedBlock(_ e: DiaryEntryDTO) -> some View {
        ZStack {
            Text(String(repeating: "那天还有一些没说出口的话，", count: 3))
                .font(Typo.sans(Typo.Size.body)).foregroundStyle(theme.ink)
                .blur(radius: 6)
                .lineLimit(3)
            VStack(spacing: 4) {
                Image(systemName: "lock.fill").font(Typo.icon(18)).foregroundStyle(theme.accentDeep)
                Text(String(localized: "有一段 \(e.from ?? taName) 锁起来了"))
                    .font(Typo.sans(Typo.Size.callout, .semibold)).foregroundStyle(theme.ink)
                Text("问 Ta 要钥匙，点这里输进去").font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkDim)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    // 我的一篇：日期、锁、正文、Ta 的页边批注
    private func mine(_ e: DiaryEntryDTO) -> some View {
        Button { editing = e } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Text(e.dayTitle).font(Typo.sans(Typo.Size.caption, .semibold)).foregroundStyle(theme.inkDim)
                    if e.private == true {
                        Image(systemName: "lock.fill").font(Typo.icon(11)).foregroundStyle(theme.inkDim)
                        Text(String(localized: "\(taName) 读不到")).font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkDim)
                    }
                }
                Text(e.body).font(Typo.sans(Typo.Size.body)).foregroundStyle(theme.ink).multilineTextAlignment(.leading)
                if let m = e.margin, !m.isEmpty {
                    HStack(alignment: .top, spacing: 8) {
                        Rectangle().fill(theme.accentDeep.opacity(0.5)).frame(width: 2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(String(localized: "\(e.marginFrom ?? taName) 在页边写："))
                                .font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkDim)
                            Text(m).font(Typo.sans(Typo.Size.callout)).italic().foregroundStyle(theme.accentDeep)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface()
        }
        .buttonStyle(.plain)
    }

    private func reloadAll() async {
        entries = []
        await load(before: nil)
    }

    private func load(before: String?) async {
        var q = [URLQueryItem(name: "limit", value: "\(Self.page)")]
        if let before { q.append(URLQueryItem(name: "before", value: before)) }
        do {
            let got: [DiaryEntryDTO] = try await model.api.call("GET", "diary", query: q)
            // 按天翻页：最后那天可能只拿到一半，丢掉，下一页从那天重新拿
            let cut = got.count == Self.page ? got.filter { $0.day != got.last?.day } : got
            entries += cut.isEmpty ? got : cut
            more = got.count == Self.page && !cut.isEmpty
            error = nil
        } catch { self.error = error.localizedDescription }
        loaded = true
    }

    private func unlock(_ e: DiaryEntryDTO) async {
        do {
            let got: UnlockDTO = try await model.api.call("POST", "diary/\(e.id)/unlock", json: ["code": code])
            entries = entries.map { $0.id == got.id ? { var x = $0; x.locked = got.locked; return x }($0) : $0 }
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func delete(_ e: DiaryEntryDTO) async {
        do {
            try await model.api.send("DELETE", "diary/\(e.id)")
            entries.removeAll { $0.id == e.id }
        } catch { self.error = error.localizedDescription }
    }
}

/// 写一篇 / 改一篇：日期、正文、锁不锁
struct DiaryEditor: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var theme: AppTheme
    @Environment(\.dismiss) private var dismiss
    let entry: DiaryEntryDTO?
    let taName: String
    let saved: () async -> Void
    @State private var day = Date()
    @State private var text = ""
    @State private var locked = false
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("哪天", selection: $day, in: ...Date(), displayedComponents: .date)
                Section {
                    IMETextEditor(text: $text, size: Typo.Size.body)
                        .frame(minHeight: 260)
                        .font(Typo.sans(Typo.Size.body))
                }
                Section {
                    Toggle(isOn: $locked) {
                        Text(String(localized: "锁起来，\(taName) 读不到")).font(Typo.sans(Typo.Size.body))
                    }
                } footer: {
                    Text(String(localized: "没锁的 \(taName) 凌晨会读，在页边给你留一句。你的日记不会进它的记忆，它读完自己决定要不要记住什么。"))
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .scrollContentBackground(.hidden)
            .background(AppBackground())
            .navigationTitle(entry == nil ? "写日记" : "改日记")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("存") { Task { await save() } }
                        .disabled(busy || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .environment(\.colorScheme, .light)
        .onAppear {
            if let e = entry { day = e.date; text = e.body; locked = e.private == true }
        }
    }

    private func save() async {
        busy = true
        defer { busy = false }
        let body: [String: Any] = ["day": DiaryEntryDTO.dayFormat.string(from: day), "body": text, "private": locked]
        do {
            if let e = entry {
                _ = try await model.api.raw("PATCH", "diary/\(e.id)", json: body)
            } else {
                _ = try await model.api.raw("POST", "diary", json: body)
            }
            await saved()
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
