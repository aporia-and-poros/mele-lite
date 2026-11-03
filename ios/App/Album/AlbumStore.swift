import PhotosUI
import SwiftUI

// MARK: - 相册的数据（10-02，服务器 server/api/routes_album.py；规矩照之前自用的 App，见 docs/plans/2026-10-02-album.md）
//
// 三本分开要：all（不含隐私）/ starred / secret。隐私那本服务器默认不给，App 先过 Face ID 再要。

struct AlbumPhotoDTO: Decodable, Identifiable, Hashable {
    let id: Int
    let companionID: UUID
    let source: String          // chat：它从聊天里收的；mine：TA 自己加的
    let takenAt: Date
    let caption: String
    let felt: String
    let why: String
    let thoughts: String
    let note: String
    let batch: String
    let starred: Bool
    let secret: Bool
    let looking: Bool           // TA 加的、它还在看
    let url: String
    let thumb: String

    enum CodingKeys: String, CodingKey {
        case id, source, caption, felt, why, thoughts, note, batch, starred, secret, looking, url, thumb
        case companionID = "companion_id", takenAt = "taken_at"
    }

    /// 字段缺了 / 是 null 就给空：一张解不出来会让整本相册都拉不下来（10-31 内测：Lite 单张的 batch 是 null）
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        func s(_ k: CodingKeys) -> String { (try? c.decodeIfPresent(String.self, forKey: k)) ?? nil ?? "" }
        func b(_ k: CodingKeys) -> Bool { (try? c.decodeIfPresent(Bool.self, forKey: k)) ?? nil ?? false }
        id = try c.decode(Int.self, forKey: .id)
        companionID = try c.decode(UUID.self, forKey: .companionID)
        takenAt = try c.decode(Date.self, forKey: .takenAt)
        source = s(.source); caption = s(.caption); felt = s(.felt); why = s(.why); thoughts = s(.thoughts)
        note = s(.note); batch = s(.batch); url = s(.url); thumb = s(.thumb)
        starred = b(.starred); secret = b(.secret); looking = b(.looking)
    }
}

@MainActor
final class AlbumStore: ObservableObject {
    @Published private(set) var books: [AlbumBook: [AlbumPhotoDTO]] = [:]
    @Published private(set) var loaded: Set<AlbumBook> = []
    @Published var error: String?

    func photos(_ book: AlbumBook) -> [AlbumPhotoDTO] { books[book] ?? [] }

    func load(_ book: AlbumBook, api: APIClient) async {
        do {
            books[book] = try await api.call("GET", "album", query: [URLQueryItem(name: "book", value: book.key)])
            loaded.insert(book)
            error = nil
        } catch {
            self.error = "相册没拉下来：\(error.localizedDescription)"
        }
    }

    /// 收藏 / 隐私：改完三本都重拉（一张会从一本挪到另一本）
    func set(_ p: AlbumPhotoDTO, starred: Bool? = nil, secret: Bool? = nil, api: APIClient) async {
        var body: [String: Any] = [:]
        if let starred { body["starred"] = starred }
        if let secret { body["secret"] = secret }
        _ = try? await api.raw("PATCH", "album/\(p.id)", json: body)
        await reloadAll(api)
    }

    func delete(_ p: AlbumPhotoDTO, api: APIClient) async {
        _ = try? await api.raw("DELETE", "album/\(p.id)")
        await reloadAll(api)
    }

    func reloadAll(_ api: APIClient) async {
        for b in loaded { await load(b, api: api) }
    }

    /// TA 自己加照片：一次最多 9 张 + 一段话，给哪个联系人看
    func add(_ images: [Data], note: String, companion: UUID?, api: APIClient) async throws {
        var fields = ["note": note]
        if let companion { fields["companion_id"] = companion.uuidString.lowercased() }
        let files = images.enumerated().map { ("files", "photo-\($0.offset).jpg", "image/jpeg", $0.element) }
        _ = try await api.multipartFields("POST", "album", fields: fields, files: files)
        await reloadAll(api)
    }
}

extension AlbumBook {
    var key: String {
        switch self {
        case .all: "all"
        case .starred: "starred"
        case .secret: "secret"
        }
    }
}

// MARK: - 点开看（移植自之前自用的 App AlbumViewer：中间一张在前，后面的从两边露出来，左右滑；下面磨砂框里是 TA 的话和它写的字）

struct AlbumViewerJob: Identifiable {
    let id = UUID()
    let frames: [FilmFrame]
    let start: Int
}

struct AlbumViewer: View {
    @EnvironmentObject private var theme: AppTheme
    @Environment(\.dismiss) private var dismiss
    let frames: [FilmFrame]
    let start: Int
    var name: (UUID) -> String = { _ in "Ta" }
    @State private var index = 0
    @State private var drag: CGFloat = 0
    @State private var aspects: [Int: CGFloat] = [:]
    @State private var fullscreen: ImageViewerState?


    /// 离中间 t 格时横向挪多远：离开中间那一段走得快，两张交换前后时已经分开（之前自用的 App 09-25 调过）
    private static func spread(_ d: CGFloat) -> CGFloat {
        let t = abs(d)
        let f = t < 1 ? 0.55 * t * (2 - t) + 0.45 * t : t
        return d < 0 ? -f : f
    }

    var body: some View {
        GeometryReader { geo in
            let cardW = min(geo.size.width * 0.74, 330)
            let cardH = min(geo.size.height * 0.5, cardW * 1.3)
            let step = geo.size.width * 0.46
            let pos = CGFloat(index) - drag / step
            VStack(spacing: 18) {
                Spacer(minLength: 64)
                ZStack {
                    ForEach(Array(frames.enumerated()), id: \.element.id) { i, f in
                        let d = CGFloat(i) - pos
                        if abs(d) < 2.6 {
                            let box = fitted(aspects[f.id] ?? f.aspect ?? 0.75, maxW: cardW, maxH: cardH)
                            card(f, width: box.width, height: box.height)
                                // 一条直的横线（10-04 Aporia：Mele 里不要弧）：不歪、不抬，中间那张盖在左右两张上面
                                .scaleEffect(1 - 0.16 * min(abs(d), 2))
                                .offset(x: Self.spread(d) * step)
                                .opacity(abs(d) > 2 ? 0 : 1 - 0.25 * min(abs(d), 1.6))
                                .zIndex(-Double(abs(d)))
                                .onTapGesture {
                                    if i == index {
                                        let live = frames.filter { $0.photo != nil }
                                        if f.photo != nil {
                                            fullscreen = ImageViewerState(urls: live.compactMap { $0.photo?.url },
                                                                          index: live.firstIndex { $0.id == f.id } ?? 0)
                                        }
                                    } else {
                                        withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { index = i }
                                    }
                                }
                                .task(id: f.id) {
                                    guard aspects[f.id] == nil, let url = f.photo?.url,
                                          let img = await AuthImageView.image(urlPath: url), img.size.height > 0 else { return }
                                    withAnimation(.easeOut(duration: 0.25)) { aspects[f.id] = img.size.width / img.size.height }
                                }
                        }
                    }
                }
                .frame(width: geo.size.width, height: cardH + 40)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture()
                        .onChanged { v in drag = v.translation.width }
                        .onEnded { v in
                            // 一次只翻一张（之前自用的 App 09-25：太敏感一下滑走两张）
                            let moved = -v.translation.width / step
                            let flung = -v.predictedEndTranslation.width / step
                            var target = index
                            if moved > 0.25 || flung > 0.6 { target = index + 1 }
                            else if moved < -0.25 || flung < -0.6 { target = index - 1 }
                            withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
                                index = max(0, min(frames.count - 1, target))
                                drag = 0
                            }
                        }
                )
                ScrollView(showsIndicators: false) {
                    if frames.indices.contains(index) {
                        words(frames[index])
                            .frame(width: min(geo.size.width - 40, 380))
                            .id(frames[index].id)
                            .transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity)
                .animation(.easeOut(duration: 0.2), value: index)
            }
            .overlay(alignment: .topTrailing) {
                VStack(alignment: .trailing, spacing: 8) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(Typo.icon(14, .semibold)).foregroundStyle(theme.inkDim)
                            .frame(width: 38, height: 38).background(Circle().fill(Color.white.opacity(0.5)))
                    }
                    .buttonStyle(.plain)
                    if frames.count > 1 {
                        Text("\(index + 1) / \(frames.count)")
                            .font(Typo.sans(Typo.Size.caption, .medium)).foregroundStyle(theme.inkDim)
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(Capsule().fill(Color.white.opacity(0.5)))
                    }
                }
                .padding(.trailing, 16).padding(.top, 6)
            }
        }
        .onAppear { index = start }
        .environment(\.colorScheme, .light)
        .fullScreenCover(item: $fullscreen) { ImageViewerView(state: $0) }
    }

    /// 横图竖图都整张放进格子里，按原比例，不裁（之前自用的 App：横版的被裁掉了）
    private func fitted(_ aspect: CGFloat, maxW: CGFloat, maxH: CGFloat) -> CGSize {
        let a = max(aspect, 0.2)
        var w = maxW, h = w / a
        if h > maxH { h = maxH; w = h * a }
        return CGSize(width: w, height: h)
    }

    private func card(_ f: FilmFrame, width: CGFloat, height: CGFloat) -> some View {
        f.picture(full: true)
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: .black.opacity(0.16), radius: 16, y: 8)
            .overlay(alignment: .bottomLeading) {
                if f.photo?.looking == true {
                    Text("\(name(f.photo!.companionID)) 在看…").font(Typo.sans(Typo.Size.caption, .medium)).foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Capsule().fill(.black.opacity(0.35))).padding(12)
                }
            }
    }

    @ViewBuilder
    private func words(_ f: FilmFrame) -> some View {
        if let p = f.photo {
            let who = name(p.companionID)
            FoodCard(padding: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    if !p.note.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("你写的").font(Typo.sans(Typo.Size.caption, .medium)).foregroundStyle(theme.inkFaint)
                            Text(p.note).font(Typo.sans(Typo.Size.body)).foregroundStyle(theme.ink)
                        }
                    }
                    if p.looking {
                        Text("\(who) 在看…").font(Typo.sans(Typo.Size.callout)).foregroundStyle(theme.inkFaint)
                    }
                    if !p.caption.isEmpty {
                        Text(p.caption).font(Typo.sans(Typo.Size.headline)).foregroundStyle(theme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !p.felt.isEmpty {
                        Text(p.felt).font(Typo.sans(Typo.Size.body)).foregroundStyle(theme.inkDim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !p.why.isEmpty {
                        HStack(alignment: .top, spacing: 6) {
                            Text("留着是因为").font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkFaint)
                            Text(p.why).font(Typo.sans(Typo.Size.callout)).foregroundStyle(theme.inkDim)
                        }
                    }
                    if !p.thoughts.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(who) 的观后感").font(Typo.sans(Typo.Size.caption, .medium)).foregroundStyle(theme.inkFaint)
                            Text(p.thoughts).font(Typo.sans(Typo.Size.body)).foregroundStyle(theme.ink)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Text("\(p.takenAt.formatted(.dateTime.year().month().day())) · \(p.source == "mine" ? "你放进来的" : "\(who) 收的")")
                        .font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkFaint)
                }
            }
        }
    }
}

// MARK: - TA 自己放照片进来（照之前自用的 App AlbumUploadSheet：选几张、写一段话；一分钟后它看）

struct AlbumAddSheet: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var theme: AppTheme
    @Environment(\.dismiss) private var dismiss
    let store: AlbumStore
    @State private var picks: [PhotosPickerItem] = []
    @State private var images: [UIImage] = []
    @State private var note = ""
    @State private var to: UUID?
    @State private var sending = false
    @State private var error: String?

    private var whoName: String { model.companion(to ?? model.companions.first?.id ?? UUID())?.name ?? "Ta" }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(96), spacing: 6), count: 3), alignment: .leading, spacing: 6) {
                        ForEach(Array(images.enumerated()), id: \.offset) { i, img in
                            Image(uiImage: img).resizable().scaledToFill()
                                .frame(width: 96, height: 96).clipped()
                                .clipShape(RoundedRectangle(cornerRadius: Radii.chip, style: .continuous))
                                .overlay(alignment: .topTrailing) {
                                    Button { images.remove(at: i) } label: {
                                        Image(systemName: "xmark.circle.fill").foregroundStyle(.white, .black.opacity(0.5))
                                    }
                                    .padding(4)
                                }
                        }
                        if images.count < 9 {
                            PhotosPicker(selection: $picks, maxSelectionCount: 9 - images.count, matching: .images) {
                                Image(systemName: "plus").font(Typo.icon(26, .light)).foregroundStyle(theme.inkDim)
                                    .frame(width: 96, height: 96)
                                    .background(RoundedRectangle(cornerRadius: Radii.chip, style: .continuous).fill(Color.white.opacity(0.5)))
                            }
                        }
                    }
                    TextField("写点什么——这是哪天、在哪、你想让 \(whoName) 知道的…", text: $note, axis: .vertical)
                        .lineLimit(3...10)
                        .font(Typo.sans(Typo.Size.body))
                        .padding(12)
                        .frame(maxWidth: .infinity, minHeight: 90, alignment: .topLeading)
                        .background(RoundedRectangle(cornerRadius: Radii.control, style: .continuous).fill(Color.white.opacity(0.55)))
                    if model.companions.count > 1 {
                        Picker("给谁看", selection: Binding(get: { to ?? model.companions.first?.id }, set: { to = $0 })) {
                            ForEach(model.companions) { c in Text(c.name).tag(Optional(c.id)) }
                        }
                        .pickerStyle(.menu)
                    }
                    Text("一次放的算一组，写一段话就行。放进去一分钟后 \(whoName) 会看，一张张写它的感受。")
                        .font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkDim)
                    if let error { Text(error).font(Typo.sans(Typo.Size.callout)).foregroundStyle(.red) }
                }
                .padding(18)
            }
            .background(AppBackground())
            .navigationTitle("放进相册")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(sending ? "放着…" : "放进去") { Task { await send() } }
                        .disabled(images.isEmpty || sending)
                }
            }
            .onChange(of: picks) { _, items in
                Task {
                    for item in items {
                        if let raw = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: raw) {
                            images.append(img.resizedIfNeeded(maxSide: 2400))
                        }
                    }
                    picks = []
                }
            }
        }
        .environment(\.colorScheme, .light)
    }

    private func send() async {
        sending = true
        defer { sending = false }
        let data = images.compactMap { $0.jpegData(compressionQuality: 0.85) }
        do {
            try await store.add(data, note: note, companion: to, api: session.api)
            dismiss()
        } catch {
            self.error = "没放进去：\(error.localizedDescription)"
        }
    }
}
