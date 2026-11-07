import SwiftUI

// 主题、字体、圆角、背景、头像：从之前自用的 App PhoneTheme.swift / AvatarStore.swift 搬来，只留聊天页用得到的。
// 之前自用的 App自带的三张壁纸图来历说不清，不搬进要上架的 app（Aporia 09-28：默认纯色，展示图以后找可商用的）；
// 这里只有纯色、代码画的「灰蓝云」和用户自己导入的。

/// 手机端主题：色轮主题色 + 聊天壁纸，全部持久化
final class AppTheme: ObservableObject {
    @Published var hue: Double {
        didSet { UserDefaults.standard.set(hue, forKey: "themeHue") }
    }
    /// 饱和度倍数：乘在三档主题色各自的饱和度上
    @Published var satScale: Double {
        didSet { UserDefaults.standard.set(satScale, forKey: "themeSatScale") }
    }
    /// 明度偏移：加在三档各自的明度上
    @Published var briShift: Double {
        didSet { UserDefaults.standard.set(briShift, forKey: "themeBriShift") }
    }
    /// 全局背景（以后首页用）；聊天页的 "same" = 跟它走
    @Published var bgChoice: String {
        didSet { UserDefaults.standard.set(bgChoice, forKey: "bgChoice") }
    }
    @Published var chatBgChoice: String {
        didSet { UserDefaults.standard.set(chatBgChoice, forKey: "chatBgChoice") }
    }
    /// 卡片样式（09-28 Aporia要的临时开关）：glass = 之前自用的 App同款毛玻璃 / solid = 半透明实色
    @Published var cardStyle: String {
        didSet { UserDefaults.standard.set(cardStyle, forKey: "cardStyle") }
    }
    /// 主屏软件名字的颜色（11-07 一测：换深色壁纸就看不见）：auto = 看壁纸深浅挑黑字或白字；dark / light = 自己定
    @Published var homeLabelColor: String {
        didSet { UserDefaults.standard.set(homeLabelColor, forKey: "homeLabelColor") }
    }
    var homeLabelIsLight: Bool {
        switch homeLabelColor {
        case "dark": false
        case "light": true
        default: wallpaperLuma(bgChoice) < 0.45
        }
    }
    private var lumaCache: [String: CGFloat] = [:]
    /// 壁纸平均亮度（0 黑 ～ 1 白）；纯色和渐变都是浅的。一张图只算一次
    private func wallpaperLuma(_ choice: String) -> CGFloat {
        if let hit = lumaCache[choice] { return hit }
        guard choice != "plain", choice != "cloud",
              let image = choice.hasPrefix("bg-") ? UIImage(named: choice)
                                                  : UIImage(contentsOfFile: Self.bgDir.appendingPathComponent(choice).path),
              let cg = image.cgImage else { return 1 }
        var px = [UInt8](repeating: 0, count: 4)
        let drawn: Bool = px.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        guard drawn else { return 1 }
        let luma = (0.299 * CGFloat(px[0]) + 0.587 * CGFloat(px[1]) + 0.114 * CGFloat(px[2])) / 255
        lumaCache[choice] = luma
        return luma
    }
    @Published var customBackgrounds: [String] {
        didSet { UserDefaults.standard.set(customBackgrounds, forKey: "customBackgrounds") }
    }
    /// 聊天背景自己导入的图：文件放 Documents/backgrounds，名字带 chat- 前缀
    @Published var chatCustomBackgrounds: [String] {
        didSet { UserDefaults.standard.set(chatCustomBackgrounds, forKey: "chatCustomBackgrounds") }
    }

    init() {
        let saved = UserDefaults.standard.double(forKey: "themeHue")
        hue = saved > 0 ? saved : 333   // 默认紫调雾玫瑰（跟之前自用的 App一样）
        satScale = UserDefaults.standard.object(forKey: "themeSatScale") as? Double ?? 1
        briShift = UserDefaults.standard.object(forKey: "themeBriShift") as? Double ?? 0
        bgChoice = UserDefaults.standard.string(forKey: "bgChoice") ?? "plain"
        chatBgChoice = UserDefaults.standard.string(forKey: "chatBgChoice") ?? "plain"
        cardStyle = UserDefaults.standard.string(forKey: "cardStyle") ?? "solid"
        homeLabelColor = UserDefaults.standard.string(forKey: "homeLabelColor") ?? "auto"
        customBackgrounds = UserDefaults.standard.stringArray(forKey: "customBackgrounds") ?? []
        chatCustomBackgrounds = UserDefaults.standard.stringArray(forKey: "chatCustomBackgrounds") ?? []
    }

    static var bgDir: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("backgrounds", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func addChatCustomBackground(_ data: Data) {
        let name = "chat-\(UUID().uuidString).jpg"
        try? data.write(to: Self.bgDir.appendingPathComponent(name))
        chatCustomBackgrounds.append(name)
        chatBgChoice = name   // 导入即启用
    }

    func removeChatCustomBackground(_ name: String) {
        try? FileManager.default.removeItem(at: Self.bgDir.appendingPathComponent(name))
        chatCustomBackgrounds.removeAll { $0 == name }
        if chatBgChoice == name { chatBgChoice = "plain" }
    }

    /// 背景库："plain" 纯色（默认），"cloud" 代码画的灰蓝渐变
    static let backgrounds: [(id: String, name: String)] = [
        ("plain", "纯色"),
        ("cloud", "灰蓝云"),
        // 内置的 Unsplash 图（09-28 Aporia挑的；来源和许可记在 THIRD_PARTY.md）
        ("bg-angel", "天使"),
        ("bg-bloom", "花影"),
        ("bg-water", "水面"),
        ("bg-moon", "月亮"),
        ("bg-petal", "花瓣"),
        ("bg-cyanotype", "蓝晒"),
    ]

    func addCustomBackground(_ data: Data) {
        let name = "home-\(UUID().uuidString).jpg"
        try? data.write(to: Self.bgDir.appendingPathComponent(name))
        customBackgrounds.append(name)
        bgChoice = name
    }

    func removeCustomBackground(_ name: String) {
        try? FileManager.default.removeItem(at: Self.bgDir.appendingPathComponent(name))
        customBackgrounds.removeAll { $0 == name }
        if bgChoice == name { bgChoice = "plain" }
    }
    static let plainColor = Color(red: 0.87, green: 0.89, blue: 0.92)
    static let cloudGradient = LinearGradient(colors: [Color(red: 0.49, green: 0.57, blue: 0.66),
                                                       Color(red: 0.66, green: 0.73, blue: 0.79)],
                                              startPoint: .top, endPoint: .bottom)

    // Aporia设计稿的色值换算成 HSB（deep: hsl(h,56%,75%) / soft: hsl(h,65%,86%)）
    var accent: Color { tone(0.34, 0.88) }
    var accentSoft: Color { tone(0.19, 0.95) }
    var accentDeep: Color { tone(0.50, 0.66) }

    private func tone(_ s: Double, _ b: Double) -> Color {
        Color(hue: hue / 360,
              saturation: min(1, max(0, s * satScale)),
              brightness: min(1, max(0.2, b + briShift)))
    }

    /// 字的颜色跟主题色走（09-28 Aporia：主题色也管字）：同一个色相、压得很暗很淡，看着是深灰，带一点主题的调子
    var ink: Color { Color(hue: hue / 360, saturation: min(1, 0.32 * satScale), brightness: 0.24) }
    var inkDim: Color { ink.opacity(0.64) }
    var inkFaint: Color { ink.opacity(0.44) }

    static let ink = Color(red: 0.17, green: 0.22, blue: 0.28)
    static let inkDim = Color(red: 0.17, green: 0.22, blue: 0.28).opacity(0.62)
    static let inkFaint = Color(red: 0.17, green: 0.22, blue: 0.28).opacity(0.42)
}

/// 圆角级差：四档够用，新代码从这里取
enum Radii {
    static let card: CGFloat = 24      // 毛玻璃大卡片、整块面板
    static let control: CGFloat = 18   // 输入框、按钮、胶囊
    static let bubble: CGFloat = 14    // 聊天气泡、小卡片、缩略图
    static let chip: CGFloat = 8       // 标签、色块、进度条端头
}

/// 字体规矩（2026-09-28 Aporia定：目标 clean、不花哨）
/// - 功能字 = 系统字（SF + 苹方）：一切要读懂的。
/// - 点缀字 = New York 衬线：只给页面大标题、栏目名、大数字；中文界面也用英文。**不跟中文放进同一个 Text**
///   （New York 没有中文，系统会拿宋体补，一行里三种气质）。
/// - 字号只有下面六档。聊天页的字跟用户调的字号走：`skin.size(Typo.Size.xxx)`，括号里也只能是六档之一。
/// - 图标（SF Symbols）、表情、头像里的字按图形尺寸算，用 `icon`，不受六档管。
enum Typo {
    enum Size {
        static let largeTitle: CGFloat = 34
        static let title: CGFloat = 22
        static let headline: CGFloat = 17
        static let body: CGFloat = 15
        static let callout: CGFloat = 13
        static let caption: CGFloat = 11
    }

    static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
    static func accent(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }
    /// 会跳动的计数：等宽数字位，不会左右晃
    static func number(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight).monospacedDigit()
    }
    /// 图标、表情、头像首字母
    static func icon(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
}

/// 磨砂的配比（paintedChrome 用 material 这一档）
enum Frost {
    static let material: Double = 0.80
    static let veil: Double = 0.05
    static let tint: Double = 0.045
}

/// 磨砂卡片（之前自用的 App PhoneGlassCard 的 .frosted 那一档，静的）：材料糊开背景 → 几乎无色的白纱 →
/// 渐变亮边当玻璃的厚度 → 外面一圈很淡的白光把它从底图上托起来
struct PhoneGlassCard<Content: View>: View {
    enum Style { case frosted }
    @EnvironmentObject var theme: AppTheme
    var padding: CGFloat = 18
    var style: Style = .frosted
    @ViewBuilder var content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radii.card, style: .continuous)
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                ZStack {
                    shape.fill(.ultraThinMaterial)
                        .opacity(Frost.material)
                        .shadow(color: .white.opacity(0.20), radius: 10)
                    shape.fill(Color.white.opacity(Frost.veil))
                    shape.fill(theme.accent.opacity(Frost.tint))
                    shape.strokeBorder(
                        LinearGradient(colors: [Color.white.opacity(0.95), Color.white.opacity(0.18),
                                                Color.white.opacity(0.45), Color.white.opacity(0.90)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: 1)
                }
            }
    }
}

/// 全屏背景：所选壁纸（灰蓝渐变 / 自己导入的）+ 顶部白纱
struct AppBackground: View {
    var choiceOverride: String? = nil
    /// 深色聊天页开了壁纸：顶部白纱换成整页黑纱，白字压得住
    var darkVeil: Bool = false
    @EnvironmentObject var theme: AppTheme

    var body: some View {
        let choice = choiceOverride ?? theme.bgChoice
        GeometryReader { geo in
            Group {
                if choice == "cloud" {
                    AppTheme.cloudGradient
                } else if choice.hasPrefix("bg-"), let image = UIImage(named: choice) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else if choice != "plain", let image = UIImage(contentsOfFile: AppTheme.bgDir.appendingPathComponent(choice).path) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    AppTheme.plainColor
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .overlay {
                if darkVeil {
                    ZStack(alignment: .top) {
                        Color.black.opacity(0.42)
                        LinearGradient(colors: [Color.black.opacity(0.35), .clear],
                                       startPoint: .top, endPoint: .bottom)
                            .frame(height: 280)
                    }
                }
            }
            .overlay(alignment: .top) {
                if !darkVeil {
                    LinearGradient(colors: [Color.white.opacity(0.55), Color.white.opacity(0.22), .clear],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: 280)
                }
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: - 头像

/// 两边的头像：从相册选图，裁成方形存本地；没设置时显示渐变字圈。选图的入口在第二块（设置）。
final class AvatarStore: ObservableObject {
    enum Who: String { case ai, me }

    @Published var ai: UIImage?
    @Published var me: UIImage?

    private static func fileURL(_ who: Who) -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("avatar-\(who.rawValue).jpg")
    }

    init() {
        ai = UIImage(contentsOfFile: Self.fileURL(.ai).path)
        me = UIImage(contentsOfFile: Self.fileURL(.me).path)
    }

    func set(_ who: Who, data: Data) {
        guard let image = UIImage(data: data) else { return }
        let squared = image.squareCropped(to: 512)
        try? squared.jpegData(compressionQuality: 0.85)?.write(to: Self.fileURL(who))
        DispatchQueue.main.async {
            switch who {
            case .ai: self.ai = squared
            case .me: self.me = squared
            }
        }
    }

    func clear(_ who: Who) {
        try? FileManager.default.removeItem(at: Self.fileURL(who))
        switch who {
        case .ai: ai = nil
        case .me: me = nil
        }
    }

    func image(for who: Who) -> UIImage? { who == .ai ? ai : me }
}

extension UIImage {
    /// 居中裁成正方形并缩放，避免存原图占空间
    func squareCropped(to side: CGFloat) -> UIImage {
        let minSide = min(size.width, size.height)
        let originX = (size.width - minSide) / 2
        let originY = (size.height - minSide) / 2
        let scale = side / minSide
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side))
        return renderer.image { _ in
            draw(in: CGRect(x: -originX * scale, y: -originY * scale,
                            width: size.width * scale, height: size.height * scale))
        }
    }
}

/// 统一的头像组件：有照片显示照片，没有就显示渐变字圈（它的名字第一个字 / 「我」）
struct AvatarView: View {
    @EnvironmentObject var avatars: AvatarStore
    @EnvironmentObject var theme: AppTheme
    @AppStorage("companionName") private var companionName = "Lumi"
    let who: AvatarStore.Who
    var size: CGFloat = 32

    var body: some View {
        Group {
            if let image = avatars.image(for: who) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                LinearGradient(colors: [theme.accentSoft, theme.accent],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .overlay(
                        Text(who == .ai ? String(companionName.prefix(1)) : "我")
                            .font(Typo.icon(size * 0.42, .semibold))
                            .foregroundStyle(.white)
                    )
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(.white.opacity(0.6), lineWidth: size > 40 ? 1.5 : 1.2))
    }
}


// MARK: - 卡片的皮（09-28：毛玻璃 / 实色 临时开关，Aporia要对比效果）

/// 页面上所有卡片、胶囊都从这里取底，开关一换全换
struct CardSurface<S: InsettableShape>: ViewModifier {
    @EnvironmentObject private var theme: AppTheme
    let shape: S
    var strength: Double = 1           // 实色时的浓淡（1 = 卡片；小一点给窄条、胶囊）

    func body(content: Content) -> some View {
        content.background {
            if theme.cardStyle == "glass" {
                ZStack {
                    shape.fill(.ultraThinMaterial)
                        .opacity(Frost.material)
                        .shadow(color: .white.opacity(0.20), radius: 10)
                    shape.fill(Color.white.opacity(Frost.veil))
                    shape.fill(theme.accent.opacity(Frost.tint))
                    shape.strokeBorder(
                        LinearGradient(colors: [Color.white.opacity(0.95), Color.white.opacity(0.18),
                                                Color.white.opacity(0.45), Color.white.opacity(0.90)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: 1)
                }
            } else {
                shape.fill(Color.white.opacity(0.55 * strength))
            }
        }
    }
}

extension View {
    func cardSurface(radius: CGFloat = Radii.card, strength: Double = 1) -> some View {
        modifier(CardSurface(shape: RoundedRectangle(cornerRadius: radius, style: .continuous), strength: strength))
    }
    func capsuleSurface(strength: Double = 0.75) -> some View {
        modifier(CardSurface(shape: Capsule(), strength: strength))
    }
}
