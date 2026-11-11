import PhotosUI
import SwiftUI

/// Memory（10-04 Aporia：洞洞板替换原来那几个格子）：板上四件——信（抽屉）、相册、档案袋（Record：收藏夹 / 里程碑 / 通话历史 / 人物卡，
/// 半升起，照之前自用的 App）、地图（去线下）；板子能翻面、能摆、挂着贴纸架。板下面是日记和自己加的照片小组件。
struct MemoryView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var theme: AppTheme
    @State private var editing = false
    @State private var showRecord = false
    @State private var showMap = false
    @State private var pickingCover = false
    @State private var coverItem: PhotosPickerItem?
    @State private var cover: UIImage? = UIImage(contentsOfFile: MemoryView.coverURL.path)

    static var coverURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("album-cover.jpg")
    }

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Memory")
                        .font(Typo.accent(Typo.Size.largeTitle))
                        .foregroundStyle(theme.ink)
                        .titleBar()
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                    // 尺寸照之前自用的 App Memory：板宽 = 屏宽 - 16，高约宽的 0.92
                    let boardW = geo.size.width - 16
                    MemoryBoard(editing: $editing, albumPhoto: cover, onOpen: open, onChangePhoto: { pickingCover = true })
                        .frame(width: boardW, height: boardW * 0.92)
                        .background(BoardSurface().padding(.horizontal, 6).padding(.vertical, -10))
                        .padding(.horizontal, 8)
                        .padding(.top, 14)
                    diaryRow.padding(.horizontal, 16)
                    MemoryWidgets().padding(.horizontal, 16)
                    Color.clear.frame(height: 90)
                }
            }
            .scrollDisabled(editing)
        }
        .photosPicker(isPresented: $pickingCover, selection: $coverItem, matching: .images)
        .onChange(of: coverItem) { _, item in
            Task {
                guard let data = try? await item?.loadTransferable(type: Data.self), let img = UIImage(data: data) else { return }
                let small = DeskStickerStore.normalized(img, maxSide: 900)
                try? small.jpegData(compressionQuality: 0.88)?.write(to: Self.coverURL, options: .atomic)
                cover = small
                coverItem = nil
            }
        }
        .sheet(isPresented: $showRecord) {
            RecordHall()
                .environmentObject(model).environmentObject(theme)
                .presentationDetents([.medium, .large])
                .presentationBackground {
                    ZStack {
                        Rectangle().fill(.ultraThinMaterial)
                        Color.white.opacity(0.22)
                        theme.accent.opacity(0.05)
                    }
                }
        }
        .sheet(isPresented: $showMap) {
            MapSheet().environmentObject(model).environmentObject(theme)
                .presentationDetents(Lite.on ? [.large] : [.medium])
        }
    }

    private func open(_ leaf: PegLeaf) {
        switch leaf {
        case .letter: NotificationCenter.default.post(name: .lumiOpenDrawer, object: nil)
        case .album: NotificationCenter.default.post(name: .lumiOpenAlbum, object: nil)
        case .record: showRecord = true
        case .map: showMap = true
        }
    }

    /// 日记：原来 Memory 的一个格子，放到板子下面一行
    private var diaryRow: some View {
        Button { NotificationCenter.default.post(name: .lumiOpenDiary, object: nil) } label: {
            HStack(spacing: 12) {
                Image(systemName: "book.pages").font(Typo.icon(18)).foregroundStyle(theme.accentDeep)
                Text("日记").font(Typo.sans(Typo.Size.headline, .semibold)).foregroundStyle(theme.ink)
                Spacer()
                Image(systemName: "chevron.right").font(Typo.icon(12)).foregroundStyle(theme.inkFaint)
            }
            .padding(16)
            .cardSurface()
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 板下面自己加的照片小组件（无边框）

struct MemoryWidgets: View {
    @EnvironmentObject private var theme: AppTheme
    @AppStorage("memoryWidgetPhotos") private var raw: String = ""
    @State private var picking: PhotosPickerItem?

    static var dir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("memory-widgets", isDirectory: true)
    }

    private var files: [String] { raw.split(separator: "|").map(String.init) }

    var body: some View {
        VStack(spacing: 12) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(files, id: \.self) { f in
                    if let img = UIImage(contentsOfFile: Self.dir.appendingPathComponent(f).path) {
                        Color.clear
                            .aspectRatio(1, contentMode: .fit)
                            .overlay { Image(uiImage: img).resizable().scaledToFill() }
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .shadow(color: .black.opacity(0.08), radius: 6, y: 3)
                            .contextMenu {
                                Button(role: .destructive) { remove(f) } label: { Label("拿掉", systemImage: "trash") }
                            }
                    }
                }
            }
            PhotosPicker(selection: $picking, matching: .images) {
                HStack(spacing: 6) {
                    Image(systemName: "plus").font(Typo.icon(14, .medium))
                    Text("加小组件").font(Typo.sans(Typo.Size.callout))
                }
                .foregroundStyle(theme.wash(0.2))
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(theme.wash(0.35), style: StrokeStyle(lineWidth: 1.4, dash: [6, 5]))
                }
            }
            .buttonStyle(.plain)
        }
        .onChange(of: picking) { _, item in
            Task {
                defer { picking = nil }
                guard let data = try? await item?.loadTransferable(type: Data.self), let img = UIImage(data: data) else { return }
                try? FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
                let name = UUID().uuidString + ".jpg"
                try? DeskStickerStore.normalized(img, maxSide: 1200).jpegData(compressionQuality: 0.88)?
                    .write(to: Self.dir.appendingPathComponent(name), options: .atomic)
                raw = (files + [name]).joined(separator: "|")
            }
        }
    }

    private func remove(_ f: String) {
        raw = files.filter { $0 != f }.joined(separator: "|")
        try? FileManager.default.removeItem(at: Self.dir.appendingPathComponent(f))
    }
}

// MARK: - 地图 = 去线下：挑一个人，切成线下（长文），进聊天（「地图 + 它的一天」做好之前先这样）

struct OfflineSheet: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var theme: AppTheme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(model.companions) { c in
                        Button { go(c) } label: {
                            HStack(spacing: 12) {
                                CompanionAvatar(companion: c, size: 36)
                                Text(c.name).font(Typo.sans(Typo.Size.body, .medium)).foregroundStyle(theme.ink)
                                Spacer()
                                Image(systemName: "chevron.right").font(Typo.icon(12)).foregroundStyle(theme.inkFaint)
                            }
                        }
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("线下：场景、动作、心里想的，长段地写。聊天页右上角 ⋯ 里能切回线上。")
                        if Lite.hosted {          // 地图 + 它的一天 11-11 搬上 Host，老 Host 还没有
                            Text("想要 TA 自己的地图和一天：在服务器上跑 mele-host update，更新以后这里就是地图。")
                        }
                    }
                }
            }
            .navigationTitle("去线下")
            .navigationBarTitleDisplayMode(.inline)
        }
        .environment(\.colorScheme, .light)
    }

    private func go(_ c: CompanionDTO) {
        Task {
            _ = try? await model.api.raw("PATCH", "companions/\(c.id.uuidString.lowercased())", json: ["settings": ["long_mode": true]])
            dismiss()
            try? await Task.sleep(for: .milliseconds(350))
            await model.openChat(c)
        }
    }
}

// MARK: - 洞洞板小组件（10-04 主屏改版：Memory 不再是一页，洞洞板变成主屏上的一个大号小组件）

struct PegboardWidget: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var theme: AppTheme
    @Environment(\.homeEditing) private var homeEditing
    @State private var editing = false
    @State private var showRecord = false
    @State private var showMap = false
    @State private var pickingCover = false
    @State private var cover: UIImage? = UIImage(contentsOfFile: MemoryView.coverURL.path)

    var body: some View {
        MemoryBoard(editing: $editing, albumPhoto: cover, onOpen: open, onChangePhoto: { pickingCover = true })
            .padding(10)
            .background(BoardSurface())
            // 相册拍立得的窗口是正方形：导进来先自己框
            .photoImport(isPresented: $pickingCover, aspect: 1) { img in
                let small = DeskStickerStore.normalized(img, maxSide: 900)
                try? small.jpegData(compressionQuality: 0.88)?.write(to: MemoryView.coverURL, options: .atomic)
                cover = small
            }
            .preference(key: InnerArrangeKey.self, value: editing)
            .onChange(of: homeEditing) { _, on in if on { withAnimation(.spring(response: 0.3)) { editing = false } } }
            .sheet(isPresented: $showRecord) {
                RecordHall()
                    .environmentObject(model).environmentObject(theme)
                    .presentationDetents([.medium, .large])
                    .presentationBackground {
                        ZStack {
                            Rectangle().fill(.ultraThinMaterial)
                            Color.white.opacity(0.22)
                            theme.accent.opacity(0.05)
                        }
                    }
            }
            .sheet(isPresented: $showMap) {
                MapSheet().environmentObject(model).environmentObject(theme)
                    .presentationDetents(Lite.on ? [.large] : [.medium])
            }
    }

    private func open(_ leaf: PegLeaf) {
        switch leaf {
        case .letter: NotificationCenter.default.post(name: .lumiOpenDrawer, object: nil)
        case .album: NotificationCenter.default.post(name: .lumiOpenAlbum, object: nil)
        case .record: showRecord = true
        case .map: showMap = true
        }
    }
}

/// 最近聊天小组件：原来首页顶上那张聊天卡 + 「全部消息」那一条
struct ChatWidget: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        VStack(spacing: 8) {
            if model.recentCompanion != nil {
                PrimaryCard()
                AllMessagesStrip()
            }
        }
    }
}
