import SwiftUI
import PhotosUI
import Vision
import CoreImage

/// 贴纸 / 冰箱贴：照之前自用的 App Stickers.swift 搬来（Aporia 10-03 点名要的贴纸托盘）。抠出来的能一键加进表情包。
///
/// - 库（library）：架子上立着的那些。内置三枚（心、星、四叶草，矢量画的）+ 她上传的。
/// - 贴在板上的（placed）：从架子上点一枚就贴一张到板上，同一枚可以贴好几张。
/// - 上传的图先用 Vision 的「抠主体」（跟相册长按抠图同一个东西）抠出来，抠不出主体就整张当照片磁贴。
/// 全存在 Documents/desk-stickers/ 下：每张图一个 png + 一个 state.json。
struct DeskSticker: Codable, Identifiable, Equatable {
    let id: String
    var builtin: String?     // "heart" / "star" / "clover"
    var file: String?        // Documents/stickers/ 下的文件名
}

struct PlacedSticker: Codable, Identifiable, Equatable {
    let id: String
    let stickerID: String
    var x: Double            // 占桌面区域的比例，跟四件物件同一套坐标
    var y: Double
    var tilt: Double
}

@MainActor
final class DeskStickerStore: ObservableObject {
    static let shared = DeskStickerStore()

    @Published private(set) var library: [DeskSticker] = []
    @Published private(set) var placed: [PlacedSticker] = []
    @Published var working = false

    private var cache: [String: UIImage] = [:]

    static let builtins: [DeskSticker] = [
        .init(id: "b.heart", builtin: "heart"),
        .init(id: "b.star", builtin: "star"),
        .init(id: "b.clover", builtin: "clover"),
    ]

    private struct State: Codable {
        var library: [DeskSticker]
        var placed: [PlacedSticker]
    }

    private var dir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("desk-stickers", isDirectory: true)
    }
    private var stateURL: URL { dir.appendingPathComponent("state.json") }

    init() { load() }

    private func load() {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: stateURL),
           let s = try? JSONDecoder().decode(State.self, from: data) {
            library = s.library
            placed = s.placed
        } else {
            library = Self.builtins
        }
    }

    private func save() {
        let s = State(library: library, placed: placed)
        if let data = try? JSONEncoder().encode(s) { try? data.write(to: stateURL, options: .atomic) }
    }

    func item(_ id: String) -> DeskSticker? { library.first { $0.id == id } }

    func image(for item: DeskSticker) -> UIImage? {
        guard let file = item.file else { return nil }
        if let hit = cache[file] { return hit }
        let img = UIImage(contentsOfFile: dir.appendingPathComponent(file).path)
        cache[file] = img
        return img
    }

    // MARK: 上传

    func add(imageData data: Data) async {
        working = true
        defer { working = false }
        guard let raw = UIImage(data: data) else { return }
        let upright = Self.normalized(raw, maxSide: 900)
        let lifted = await Task.detached(priority: .userInitiated) { Self.liftSubject(upright) }.value
        let final = lifted ?? upright
        guard let png = final.pngData() else { return }
        let name = UUID().uuidString + ".png"
        do { try png.write(to: dir.appendingPathComponent(name), options: .atomic) } catch { return }
        cache[name] = final
        library.append(.init(id: "u." + name, builtin: nil, file: name))
        save()
    }

    /// 转正 + 缩到最长边 maxSide（相机原图四千多像素，贴纸用不着）
    nonisolated static func normalized(_ image: UIImage, maxSide: CGFloat) -> UIImage {
        let s = image.size
        let k = min(1, maxSide / max(s.width, s.height))
        let size = CGSize(width: s.width * k, height: s.height * k)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    /// Vision 抠主体（iOS 17+）。抠不出来返回 nil，外面就整张当照片磁贴。
    nonisolated static func liftSubject(_ image: UIImage) -> UIImage? {
        guard let cg = image.cgImage else { return nil }
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: cg, orientation: .up, options: [:])
        do {
            try handler.perform([request])
            guard let result = request.results?.first, !result.allInstances.isEmpty else { return nil }
            let buffer = try result.generateMaskedImage(ofInstances: result.allInstances, from: handler,
                                                        croppedToInstancesExtent: true)
            let ci = CIImage(cvPixelBuffer: buffer)
            guard let out = CIContext().createCGImage(ci, from: ci.extent) else { return nil }
            return UIImage(cgImage: out)
        } catch {
            return nil
        }
    }

    // MARK: 贴 / 挪 / 撕

    func place(_ item: DeskSticker, near: CGPoint = CGPoint(x: 0.5, y: 0.45)) {
        let jx = Double.random(in: -0.08...0.08), jy = Double.random(in: -0.06...0.06)
        placed.append(.init(id: UUID().uuidString, stickerID: item.id,
                            x: min(0.92, max(0.08, near.x + jx)), y: min(0.92, max(0.08, near.y + jy)),
                            tilt: Double.random(in: -12...12)))
        save()
    }

    func move(_ id: String, to p: CGPoint) {
        guard let i = placed.firstIndex(where: { $0.id == id }) else { return }
        placed[i].x = p.x
        placed[i].y = p.y
        save()
    }

    func unplace(_ id: String) {
        placed.removeAll { $0.id == id }
        save()
    }

    /// 从架子上拿掉（板上贴着的那几张也一起撕）。内置的也能拿掉，想要回来就「复位」。
    func delete(_ item: DeskSticker) {
        library.removeAll { $0.id == item.id }
        placed.removeAll { $0.stickerID == item.id }
        if let file = item.file {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(file))
            cache[file] = nil
        }
        save()
    }

    /// 复位：内置三枚放回架子（没了的补上），板上的贴纸全撕下来
    func resetBoard() {
        placed.removeAll()
        for b in Self.builtins where !library.contains(where: { $0.id == b.id }) {
            library.insert(b, at: 0)
        }
        save()
    }
}

// MARK: - 一枚贴纸的样子

/// 贴纸本体：抠出来的图外面一圈白边（像剪下来的贴纸 / 冰箱贴），底下一点影子。
/// 白边是把图的轮廓染白、往八个方向各挪一点叠出来的，所以顺着形状走，不是方框。
struct StickerFace: View {
    @EnvironmentObject var theme: AppTheme
    let item: DeskSticker
    let image: UIImage?
    var size: CGFloat
    var border: CGFloat = 2.5

    var body: some View {
        Group {
            if let builtin = item.builtin {
                BuiltinSticker(name: builtin)
                    .frame(width: size, height: size)
            } else if let image {
                ZStack {
                    ForEach(0..<8, id: \.self) { (i: Int) in
                        let a = Double(i) * .pi / 4
                        Image(uiImage: image).renderingMode(.template).resizable().scaledToFit()
                            .foregroundStyle(Color.white)
                            .offset(x: cos(a) * border, y: sin(a) * border)
                    }
                    Image(uiImage: image).resizable().scaledToFit()
                }
                .frame(width: size, height: size)
            } else {
                RoundedRectangle(cornerRadius: 6).fill(theme.accentSoft).frame(width: size, height: size)
            }
        }
        .shadow(color: .black.opacity(0.16), radius: 1, y: 1)
        .shadow(color: .black.opacity(0.10), radius: 4, y: 3)
    }
}

/// 内置三枚：都是矢量画的，放多大都清
struct BuiltinSticker: View {
    @EnvironmentObject var theme: AppTheme
    let name: String

    var body: some View {
        GeometryReader { g in
            let d = min(g.size.width, g.size.height)
            ZStack {
                switch name {
                case "heart":
                    // 亮面心形磁贴：主题色、左上一点高光
                    Image(systemName: "heart.fill")
                        .resizable().scaledToFit()
                        .foregroundStyle(LinearGradient(colors: [theme.accent, theme.accentDeep],
                                                        startPoint: .topLeading, endPoint: .bottomTrailing))
                        .overlay(alignment: .topLeading) {
                            Capsule().fill(Color.white.opacity(0.55))
                                .frame(width: d * 0.18, height: d * 0.08)
                                .rotationEffect(.degrees(-35))
                                .offset(x: d * 0.2, y: d * 0.22)
                        }
                        .padding(d * 0.08)
                        .background(Image(systemName: "heart.fill").resizable().scaledToFit()
                                        .foregroundStyle(.white).padding(d * 0.02))
                case "star":
                    Image(systemName: "star.fill")
                        .resizable().scaledToFit()
                        .foregroundStyle(LinearGradient(colors: [Color(red: 1, green: 0.88, blue: 0.55),
                                                                 Color(red: 0.95, green: 0.72, blue: 0.35)],
                                                        startPoint: .top, endPoint: .bottom))
                        .padding(d * 0.08)
                        .background(Image(systemName: "star.fill").resizable().scaledToFit()
                                        .foregroundStyle(.white).padding(d * 0.01))
                default:
                    // 四叶草：四片小心形，淡绿
                    ZStack {
                        ForEach(0..<4, id: \.self) { i in
                            HeartLeafShape()
                                .fill(LinearGradient(colors: [Color(red: 0.62, green: 0.80, blue: 0.60),
                                                              Color(red: 0.45, green: 0.66, blue: 0.47)],
                                                     startPoint: .top, endPoint: .bottom))
                                .frame(width: d * 0.40, height: d * 0.42)
                                .offset(y: -d * 0.19)
                                .rotationEffect(.degrees(Double(i) * 90 + 45))
                        }
                    }
                    .padding(d * 0.06)
                    .background(Circle().fill(Color.white).padding(d * 0.02))
                }
            }
            .frame(width: g.size.width, height: g.size.height)
        }
    }
}

// MARK: - 架子

/// 挂在板上的贴纸架（宜家洞洞板配件那种白色小托架）：一块托板 + 前沿挡边，
/// 两个小挂钩勾在板上。贴纸立在托板上排一排，最后一格「＋」从相册挑图。
/// 点一枚 → 贴一张到板上。摆放模式下每枚右上角出现 ×（从架子上拿掉）。
struct StickerShelf: View {
    @EnvironmentObject var theme: AppTheme
    @ObservedObject var store: DeskStickerStore
    let editing: Bool
    var onPlace: (DeskSticker) -> Void

    static let width: CGFloat = 176
    static let height: CGFloat = 62

    @State private var pick: PhotosPickerItem?
    @State private var confirmDelete: DeskSticker?

    var body: some View {
        ZStack(alignment: .bottom) {
            // 两个挂钩
            HStack {
                hook
                Spacer()
                hook
            }
            .padding(.horizontal, 22)
            .frame(maxHeight: .infinity, alignment: .top)

            // 立在托板上的贴纸
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .bottom, spacing: 8) {
                    ForEach(store.library) { item in
                        StickerFace(item: item, image: store.image(for: item), size: 34, border: 1.5)
                            .overlay(alignment: .topTrailing) {
                                if editing {
                                    Button { confirmDelete = item } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.system(size: 13))
                                            .foregroundStyle(Color(white: 0.45), Color.white)
                                    }
                                    .buttonStyle(.plain)
                                    .offset(x: 5, y: -5)
                                }
                            }
                            .onTapGesture { if !editing { onPlace(item) } }
                            .contextMenu {
                                if item.file != nil, !editing {
                                    Button { addToChatStickers(item) } label: { Label("加进表情包", systemImage: "face.smiling") }
                                }
                                if !editing {     // 11-07 一测：只知道能加、找不到怎么删
                                    Button(role: .destructive) { confirmDelete = item } label: { Label("从架子上拿掉", systemImage: "trash") }
                                }
                            }
                    }
                    PhotosPicker(selection: $pick, matching: .images) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(Color(white: 0.6), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                            if store.working {
                                ProgressView().controlSize(.mini)
                            } else {
                                Image(systemName: "plus").font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(Color(white: 0.5))
                            }
                        }
                        .frame(width: 30, height: 30)
                    }
                    .disabled(store.working)
                }
                .padding(.horizontal, 12)
                .padding(.top, 6)
            }
            .padding(.bottom, 12)

            // 托板 + 前沿挡边
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(LinearGradient(colors: [Color(white: 0.99), Color(white: 0.90)],
                                         startPoint: .top, endPoint: .bottom))
                Rectangle().fill(Color.white).frame(height: 1)
            }
            .frame(height: 14)
            .shadow(color: .black.opacity(0.14), radius: 1, y: 1)
            .shadow(color: .black.opacity(0.12), radius: 6, y: 5)
        }
        .frame(width: Self.width, height: Self.height)
        .onChange(of: pick) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    await store.add(imageData: data)
                }
                pick = nil
            }
        }
        .confirmationDialog("从架子上拿掉这枚贴纸？板上贴着的也会一起撕掉。",
                            isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
                            titleVisibility: .visible) {
            Button("拿掉", role: .destructive) {
                if let item = confirmDelete { withAnimation { store.delete(item) } }
                confirmDelete = nil
            }
            Button("算了", role: .cancel) { confirmDelete = nil }
        }
    }

    /// 抠出来的贴纸一键进聊天用的表情包库（同一张图只存一次，零件包按指纹去重）
    private func addToChatStickers(_ item: DeskSticker) {
        guard let png = store.image(for: item)?.pngData(), let api = AuthImageView.api else { return }
        Task {
            _ = try? await api.uploadStickers([(png, "sticker.png", "image/png")])
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }

    private var hook: some View {
        RoundedRectangle(cornerRadius: 1.5)
            .fill(Color(white: 0.93))
            .frame(width: 4, height: Self.height - 8)
            .shadow(color: .black.opacity(0.15), radius: 1, y: 1)
    }
}

/// 一片叶子 = 一颗心，尖端朝下（放到四叶草顶部时尖端指向圆心）。
/// 四片靠 rotationEffect 得到，不画四次。
struct HeartLeafShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let x0 = rect.minX, y0 = rect.minY
        var p = Path()
        p.move(to: CGPoint(x: x0 + w / 2, y: y0 + h))                          // 尖端
        p.addCurve(to: CGPoint(x: x0, y: y0 + h * 0.36),
                   control1: CGPoint(x: x0 + w * 0.16, y: y0 + h * 0.84),
                   control2: CGPoint(x: x0, y: y0 + h * 0.62))
        p.addCurve(to: CGPoint(x: x0 + w / 2, y: y0 + h * 0.26),               // 左瓣到中间凹口
                   control1: CGPoint(x: x0, y: y0 + h * 0.03),
                   control2: CGPoint(x: x0 + w * 0.40, y: y0 - h * 0.02))
        p.addCurve(to: CGPoint(x: x0 + w, y: y0 + h * 0.36),                   // 右瓣
                   control1: CGPoint(x: x0 + w * 0.60, y: y0 - h * 0.02),
                   control2: CGPoint(x: x0 + w, y: y0 + h * 0.03))
        p.addCurve(to: CGPoint(x: x0 + w / 2, y: y0 + h),
                   control1: CGPoint(x: x0 + w, y: y0 + h * 0.62),
                   control2: CGPoint(x: x0 + w * 0.84, y: y0 + h * 0.84))
        p.closeSubpath()
        return p
    }
}
