import PhotosUI
import SwiftUI

// MARK: - 表情包（10-01 Aporia：一个库所有联系人共用，某几张可以「只给谁」；它按意思找着发；描述能改）
// 朴素版，样子等统一调 UI。

extension Notification.Name {
    static let lumiOpenStickers = Notification.Name("LumiOpenStickers")
}

struct StickerDTO: Decodable, Identifiable, Hashable {
    let id: Int
    let name: String
    let caption: String
    let mime: String
    let onlyFor: [String]
    let useCount: Int
    enum CodingKeys: String, CodingKey {
        case id, name, caption, mime
        case onlyFor = "only_for", useCount = "use_count"
    }
    var path: String { "stickers/\(id)/image" }
}

private struct UploadResult: Decodable {
    struct Skip: Decodable { let name: String; let reason: String }
    let added: [StickerDTO]
    let skipped: [Skip]
}

/// 认图片字节是什么格式（相册给的是原样字节，gif 要保住能动）
private func sniffMime(_ d: Data) -> (String, String) {
    let b = [UInt8](d.prefix(12))
    if b.starts(with: [0x47, 0x49, 0x46]) { return ("image/gif", "gif") }
    if b.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return ("image/png", "png") }
    if b.count >= 12, b[0...3] == [0x52, 0x49, 0x46, 0x46], b[8...11] == [0x57, 0x45, 0x42, 0x50] { return ("image/webp", "webp") }
    return ("image/jpeg", "jpg")
}

/// 真是一张图（链接下回来的可能是网页）：认得的文件头，或者系统能解开
private func looksLikeImage(_ d: Data) -> Bool {
    let b = [UInt8](d.prefix(12))
    if b.starts(with: [0x47, 0x49, 0x46]) || b.starts(with: [0x89, 0x50, 0x4E, 0x47]) || b.starts(with: [0xFF, 0xD8, 0xFF]) { return true }
    if b.count >= 12, b[0...3] == [0x52, 0x49, 0x46, 0x46], b[8...11] == [0x57, 0x45, 0x42, 0x50] { return true }
    return UIImage(data: d) != nil
}

/// Library → 表情包：格子、相册多选加、点开改
struct StickerRoomView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var theme: AppTheme
    @Environment(\.dismiss) private var dismiss
    @State private var stickers: [StickerDTO] = []
    @State private var loaded = false
    @State private var picks: [PhotosPickerItem] = []
    @State private var picking = false
    @State private var busy = false
    @State private var note: String?
    @State private var editing: StickerDTO?
    @State private var pastingLinks = false     // 粘贴图片链接批量加（10-11 内测反馈）
    @State private var linkText = ""
    @State private var selecting = false        // 选几张一起删（10-12 内测反馈：不能批量删除）
    @State private var selected: Set<Int> = []
    @State private var confirmDelete = false

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 4)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let note {
                        Text(note).font(Typo.sans(Typo.Size.callout)).foregroundStyle(theme.inkDim)
                    }
                    if loaded && stickers.isEmpty {
                        Text("还没有表情包。点右上角从相册加（一次能选好几张）或者粘贴一堆图片链接，聊天里长按图片也能「加到表情包」。所有联系人都能用，它会挑着发。")
                            .font(Typo.sans(Typo.Size.callout)).foregroundStyle(theme.inkDim)
                    }
                    if selecting {
                        Text(selected.isEmpty ? "点几张要删的" : "选了 \(selected.count) 张").font(Typo.sans(Typo.Size.callout)).foregroundStyle(theme.inkDim)
                    }
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(stickers) { s in
                            Button {
                                if selecting {
                                    if selected.contains(s.id) { selected.remove(s.id) } else { selected.insert(s.id) }
                                } else { editing = s }
                            } label: {
                                AuthImageView(urlPath: s.path, contentMode: .fit)
                                    .frame(height: 78)
                                    .frame(maxWidth: .infinity)
                                    .opacity(selecting && !selected.contains(s.id) ? 0.55 : 1)
                                    .overlay(alignment: .bottomTrailing) {
                                        if !s.onlyFor.isEmpty && !selecting {
                                            Image(systemName: "person.fill").font(Typo.icon(10)).foregroundStyle(theme.accentDeep)
                                        }
                                    }
                                    .overlay(alignment: .topTrailing) {
                                        if selecting {
                                            Image(systemName: selected.contains(s.id) ? "checkmark.circle.fill" : "circle")
                                                .font(Typo.icon(18)).foregroundStyle(selected.contains(s.id) ? theme.accentDeep : theme.inkFaint)
                                                .background(Circle().fill(.white).padding(2))
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    if !stickers.isEmpty {
                        Text(String(localized: "\(stickers.count) / 300")).font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkDim)
                    }
                }
                .padding(20)
            }
            .background(AppBackground())
            .navigationTitle("表情包")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(selecting ? "取消" : "关上") {
                        if selecting { selecting = false; selected = [] } else { dismiss() }
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    if selecting {
                        Button(String(localized: "删掉 \(selected.count) 张"), role: .destructive) { confirmDelete = true }
                            .disabled(selected.isEmpty || busy)
                    } else {
                        Menu {
                            Button { picking = true } label: { Label("从相册选", systemImage: "photo.on.rectangle") }
                            Button { pastingLinks = true } label: { Label("粘贴图片链接", systemImage: "link") }
                            if !stickers.isEmpty {
                                Button { selecting = true; selected = [] } label: { Label("选几张删掉", systemImage: "checkmark.circle") }
                            }
                        } label: { busy ? AnyView(ProgressView()) : AnyView(Image(systemName: "plus")) }
                            .disabled(busy)
                    }
                }
            }
            .confirmationDialog(String(localized: "删掉这 \(selected.count) 张？"), isPresented: $confirmDelete, titleVisibility: .visible) {
                Button(String(localized: "删掉 \(selected.count) 张"), role: .destructive) { Task { await deleteSelected() } }
            }
            .photosPicker(isPresented: $picking, selection: $picks, maxSelectionCount: 20, matching: .images)
            .onChange(of: picks) { _, items in
                guard !items.isEmpty else { return }
                Task { await upload(items) }
            }
            .sheet(item: $editing) { s in
                StickerEditor(sticker: s) { await load() }
                    .environmentObject(model).environmentObject(theme)
            }
            .sheet(isPresented: $pastingLinks) { linkSheet }
        }
        .environment(\.colorScheme, .light)
        .task { await load() }
    }

    private func load() async {
        stickers = (try? await model.api.call("GET", "stickers")) ?? stickers
        loaded = true
        if await readTexts() { stickers = (try? await model.api.call("GET", "stickers")) ?? stickers }
    }

    /// 还没描述的：图上有字就把字认出来当描述（手机自带文字识别，离线；10-13 内测：描述一直「还在写」，
    /// 因为 TA 的模型不会看图）。连着 Host 时 Host 自己不会认字，所以在这里认完 PATCH 上去；手机本机的在 LocalRooms2 里也认，
    /// 这里认到的就是漏网的。每张只认一次。返回有没有改到
    private func readTexts() async -> Bool {
        let key = "sticker.ocrTried"
        var tried = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        var changed = false
        for s in stickers where s.caption.isEmpty && !tried.contains(AuthImageView.key(s.path) as String) {
            tried.insert(AuthImageView.key(s.path) as String)        // 跟图片缓存一样分本机 / Host（编号各管各的，10-27）
            guard let d = try? await model.api.data(s.path),
                  let text = await Task.detached(priority: .utility, operation: { StickerOCR.text(in: d) }).value else { continue }
            if (try? await model.api.raw("PATCH", "stickers/\(s.id)", json: ["caption": text])) != nil { changed = true }
        }
        UserDefaults.standard.set(Array(tried.suffix(2000)), forKey: key)
        return changed
    }

    private func deleteSelected() async {
        busy = true
        defer { busy = false }
        var n = 0
        for id in selected where (try? await model.api.send("DELETE", "stickers/\(id)")) != nil { n += 1 }
        note = String(localized: "删掉了 \(n) 张")
        selecting = false; selected = []
        await load()
    }

    private func upload(_ items: [PhotosPickerItem]) async {
        busy = true
        defer { busy = false; picks = [] }
        var files: [(Data, String, String)] = []
        for (i, item) in items.enumerated() {
            guard let d = try? await item.loadTransferable(type: Data.self) else { continue }
            let (mime, ext) = sniffMime(d)
            files.append((d, "sticker-\(i + 1).\(ext)", mime))
        }
        await send(files, failed: 0)
    }

    // MARK: 粘贴图片链接

    /// 贴进来的一段字里所有 http(s) 链接，去重、保持顺序，最多 30 个
    static func links(in text: String) -> [URL] {
        let det = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        var seen = Set<String>(), out: [URL] = []
        for m in det?.matches(in: text, range: NSRange(text.startIndex..., in: text)) ?? [] {
            guard let u = m.url, ["http", "https"].contains(u.scheme?.lowercased() ?? ""), seen.insert(u.absoluteString).inserted else { continue }
            out.append(u)
        }
        return Array(out.prefix(30))
    }

    private var linkSheet: some View {
        let urls = Self.links(in: linkText)
        return NavigationStack {
            Form {
                Section {
                    TextEditor(text: $linkText)
                        .frame(minHeight: 180)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                } footer: {
                    Text(urls.isEmpty ? String(localized: "一行一个图片链接（打开就是一张图的那种直链），一次最多 30 个。")
                                      : String(localized: "认出 \(urls.count) 个链接"))
                }
            }
            .navigationTitle("粘贴图片链接")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { pastingLinks = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("加") {
                        pastingLinks = false
                        Task { await download(urls) }
                    }
                    .disabled(urls.isEmpty)
                }
            }
        }
        .environmentObject(theme)
    }

    /// 手机直接下（并发），是图才收；下不来、不是图的记个数
    private func download(_ urls: [URL]) async {
        busy = true
        defer { busy = false }
        note = String(localized: "在下 \(urls.count) 张…")
        let got: [(Int, Data)] = await withTaskGroup(of: (Int, Data?).self) { g in
            for (i, u) in urls.enumerated() {
                g.addTask {
                    var req = URLRequest(url: u, timeoutInterval: 20)
                    req.setValue("image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
                    guard let (d, resp) = try? await URLSession.shared.data(for: req),
                          (resp as? HTTPURLResponse)?.statusCode ?? 0 < 400, d.count <= 10 * 1024 * 1024,
                          looksLikeImage(d) else { return (i, nil) }
                    return (i, d)
                }
            }
            var out: [(Int, Data)] = []
            for await (i, d) in g { if let d { out.append((i, d)) } }
            return out.sorted { $0.0 < $1.0 }
        }
        let files = got.map { (i, d) in
            let (mime, ext) = sniffMime(d)
            return (d, "link-\(i + 1).\(ext)", mime)
        }
        if files.isEmpty {
            note = String(localized: "\(urls.count) 个链接都没下下来，或者不是图片（要图片直链）")
            return
        }
        linkText = ""
        await send(files, failed: urls.count - files.count)
    }

    private func send(_ files: [(Data, String, String)], failed: Int) async {
        guard !files.isEmpty else { return }
        do {
            let out = try APIClient.decoder.decode(UploadResult.self, from: try await model.api.uploadStickers(files))
            var bits = [String(localized: "加了 \(out.added.count) 张")]
            if failed > 0 { bits.append(String(localized: "\(failed) 个链接没下下来或者不是图片")) }
            if !out.skipped.isEmpty {
                bits.append(String(localized: "\(out.skipped.count) 张没加：") + Set(out.skipped.map(\.reason)).joined(separator: "、"))
            }
            if !out.added.isEmpty { bits.append(String(localized: "描述过一会儿写好")) }
            note = bits.joined(separator: " · ")
            await load()
        } catch { note = error.localizedDescription }
    }
}

/// 点开一张：名字、TA 看到的描述（能改）、只给谁、删
struct StickerEditor: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var theme: AppTheme
    @Environment(\.dismiss) private var dismiss
    let sticker: StickerDTO
    let saved: () async -> Void
    @State private var name = ""
    @State private var caption = ""
    @State private var onlyFor: Set<String> = []
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    AuthImageView(urlPath: sticker.path, contentMode: .fit)
                        .frame(height: 140).frame(maxWidth: .infinity)
                }
                Section("名字") { TextField("可以不起", text: $name) }
                Section {
                    IMETextEditor(text: $caption).frame(minHeight: 90)
                } header: { Text("TA 看到的样子") } footer: {
                    Text(caption.isEmpty ? "还没有描述。图上有字会先把字认出来当描述；TA 的模型会看图的话，过一会儿 TA 会写一句（DeepSeek 不会看图）。你也可以自己写一句，比如「阴阳怪气」。"
                                         : "TA 按这段描述找表情包；写得不对就改成你的意思（比如「阴阳怪气」）。")
                }
                Section {
                    ForEach(model.companions) { c in
                        Toggle(c.name, isOn: Binding(
                            get: { onlyFor.contains(c.id.uuidString.lowercased()) },
                            set: { on in
                                let id = c.id.uuidString.lowercased()
                                if on { onlyFor.insert(id) } else { onlyFor.remove(id) }
                            }))
                    }
                } header: { Text("只给谁") } footer: {
                    Text("都不选 = 所有联系人都能用。")
                }
                Section {
                    Button("删掉这张", role: .destructive) { Task { await delete() } }
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .scrollContentBackground(.hidden)
            .background(AppBackground())
            .navigationTitle("表情包")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("存") { Task { await save() } } }
            }
        }
        .environment(\.colorScheme, .light)
        .onAppear {
            name = sticker.name; caption = sticker.caption; onlyFor = Set(sticker.onlyFor)
        }
    }

    private func save() async {
        var body: [String: Any] = ["name": name, "only_for": Array(onlyFor)]
        if caption != sticker.caption { body["caption"] = caption }
        do {
            _ = try await model.api.raw("PATCH", "stickers/\(sticker.id)", json: body)
            await saved()
            dismiss()
        } catch { self.error = error.localizedDescription }
    }

    private func delete() async {
        do {
            try await model.api.send("DELETE", "stickers/\(sticker.id)")
            await saved()
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

/// 聊天里的表情包面板：点一张就发
struct StickerPanel: View {
    @EnvironmentObject private var theme: AppTheme
    let api: APIClient
    let send: (Int) -> Void
    @State private var stickers: [StickerDTO] = []
    @State private var loaded = false

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 4)

    var body: some View {
        ScrollView {
            if loaded && stickers.isEmpty {
                Text("还没有表情包。在 Library → 表情包 里从相册加，或者长按聊天里的图「加到表情包」。")
                    .font(Typo.sans(Typo.Size.callout)).foregroundStyle(theme.inkDim).padding(24)
            }
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(stickers) { s in
                    Button { send(s.id) } label: {
                        AuthImageView(urlPath: s.path, contentMode: .fit).frame(height: 72).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)
        }
        .background(AppBackground())
        .task {
            // 常用的在前
            stickers = ((try? await api.call("GET", "stickers")) as [StickerDTO]? ?? []).sorted { $0.useCount > $1.useCount }
            loaded = true
        }
    }
}
