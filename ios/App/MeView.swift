import PhotosUI
import SwiftUI

/// 「我」（第二块）：我的设定、钥匙串、外观、账号。我的设定和钥匙串在第 11 步；
/// 外观先做出来（09-28 Aporia要先看效果：背景 + 卡片毛玻璃 / 实色 的临时开关 + 主题色）。
struct MeView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var theme: AppTheme
    @EnvironmentObject private var session: SessionStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Me")
                    .font(Typo.accent(Typo.Size.largeTitle))
                    .foregroundStyle(theme.ink)
                    .titleBar()
                    .padding(.top, 8)
                ProfileCard()
                KeychainCard()
                if Lite.on { MediaKeysCard() }      // 看图和画图（10-15；10-16 从钥匙勾选单里拿回来单独一张）
                if Lite.on { HostCard() }
                if Lite.on { MCPServersCard() }       // 连着 Host 也能接（10-05，服务器 brain/mcp.py）
                if Lite.on { UsageCard() }          // 连着 Host 读 Host 的 GET usage（10-15），形状跟本机一样
                ContextCard()
                LookPresetsCard()      // 壁纸 + 图标 + 主题色存成方案格（10-15）
                AppearanceCard()
                if !Lite.on { AccountCard() }
                AppIconsCard()
                #if LITE
                BackupCard()          // 一键备份 / 从备份恢复（10-10 内测前）
                #endif
                if Lite.on { AboutCard() }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 120)
        }
        .scrollDismissesKeyboard(.interactively)
        .tapToDismissKeyboard()          // 点空白收键盘（10-11 内测反馈）
    }
}

/// 外观：卡片样式、背景、主题色。存本机，整个 app（聊天页以外）跟着变。
struct AppearanceCard: View {
    @EnvironmentObject private var theme: AppTheme
    @State private var picked: PhotosPickerItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("外观").font(Typo.sans(Typo.Size.headline, .semibold)).foregroundStyle(theme.ink)

            VStack(alignment: .leading, spacing: 8) {
                label("卡片")
                Picker("卡片", selection: $theme.cardStyle) {
                    Text("毛玻璃").tag("glass")
                    Text("实色").tag("solid")
                }
                .pickerStyle(.segmented)
            }

            VStack(alignment: .leading, spacing: 8) {
                label("主屏软件名字")
                Picker("主屏软件名字", selection: $theme.homeLabelColor) {
                    Text("跟着壁纸").tag("auto")
                    Text("黑字").tag("dark")
                    Text("白字").tag("light")
                }
                .pickerStyle(.segmented)
            }

            VStack(alignment: .leading, spacing: 8) {
                label("背景")
                // 照之前自用的 App：一排横着滑，不全摊开（10-03 Aporia）
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(AppTheme.backgrounds, id: \.id) { bg in thumb(bg.id, name: bg.name) }
                        ForEach(theme.customBackgrounds, id: \.self) { name in
                            thumb(name, name: "")
                                .contextMenu {
                                    Button(role: .destructive) { theme.removeCustomBackground(name) } label: {
                                        Label("删掉", systemImage: "trash")
                                    }
                                }
                        }
                        PhotosPicker(selection: $picked, matching: .images) {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(theme.inkFaint.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                                .frame(width: 62, height: 92)
                                .overlay(Image(systemName: "plus").font(Typo.icon(16, .semibold)).foregroundStyle(theme.inkDim))
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            .onChange(of: picked) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data),
                       let jpg = img.scaledDown(maxSide: 2400).jpegData(compressionQuality: 0.85) {
                        await MainActor.run { withAnimation(.snappy) { theme.addCustomBackground(jpg) } }
                    }
                    picked = nil
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    label("主题色")
                    Spacer()
                    Circle().fill(theme.accentDeep).frame(width: 18, height: 18)
                    Circle().fill(theme.accent).frame(width: 18, height: 18)
                    Circle().fill(theme.accentSoft).frame(width: 18, height: 18)
                }
                HueSlider(hue: $theme.hue)
                // 饱和度 / 明度（照之前自用的 App）：条上的颜色就是拖到那儿的样子
                toneSlider("饱和度", value: $theme.satScale, range: 0.3...1.8) { v in
                    Color(hue: theme.hue / 360, saturation: min(1, 0.34 * v), brightness: min(1, 0.88 + theme.briShift))
                }
                toneSlider("明度", value: $theme.briShift, range: -0.3...0.12) { v in
                    Color(hue: theme.hue / 360, saturation: min(1, 0.34 * theme.satScale), brightness: min(1, max(0.2, 0.88 + v)))
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    private func toneSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>,
                            color: @escaping (Double) -> Color) -> some View {
        HStack(spacing: 10) {
            Text(title).font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkDim)
                .frame(width: 44, alignment: .leading)
            Slider(value: value, in: range)
                .tint(.clear)
                .background {
                    Capsule()
                        .fill(LinearGradient(colors: (0...8).map { i in
                            color(range.lowerBound + (range.upperBound - range.lowerBound) * Double(i) / 8)
                        }, startPoint: .leading, endPoint: .trailing))
                        .frame(height: 10)
                }
        }
    }

    private func label(_ s: String) -> some View {
        Text(s).font(Typo.sans(Typo.Size.callout)).foregroundStyle(theme.inkDim)
    }

    private func thumb(_ id: String, name: String) -> some View {
        let on = theme.bgChoice == id
        return Button { withAnimation(.snappy) { theme.bgChoice = id } } label: {
            VStack(spacing: 4) {
                preview(id)
                    .frame(width: 62, height: 92)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(on ? theme.accent : Color.white.opacity(0.6), lineWidth: on ? 2.5 : 1))

            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private func preview(_ id: String) -> some View {
        if id == "plain" {
            AppTheme.plainColor
        } else if id == "cloud" {
            AppTheme.cloudGradient
        } else if let img = id.hasPrefix("bg-") ? UIImage(named: id)
                    : UIImage(contentsOfFile: AppTheme.bgDir.appendingPathComponent(id).path) {
            Image(uiImage: img).resizable().scaledToFill()
        } else {
            Color.gray.opacity(0.2)
        }
    }
}

/// 软件图标（10-04 Aporia）：列出每一个软件，点一个导入自己的照片当图标；换过的长按能改回原样
struct AppIconsCard: View {
    @EnvironmentObject private var theme: AppTheme
    @ObservedObject private var icons = AppIconStore.shared
    @State private var target: HomeApp?
    @State private var picking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("软件图标").font(Typo.sans(Typo.Size.headline, .semibold)).foregroundStyle(theme.ink)
                Text("点一个，换成你自己的照片。换过的长按可以改回原样。")
                    .font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkDim)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 14) {
                ForEach(HomeApp.allCases.filter(\.available), id: \.self) { app in
                    AppIcon(app: app, size: 56, showLabel: true) {
                        target = app
                        picking = true
                    }
                    .contextMenu {
                        if icons.images[app] != nil {
                            Button(role: .destructive) { withAnimation(.snappy) { icons.reset(app) } } label: {
                                Label("改回原样", systemImage: "arrow.uturn.backward")
                            }
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
        .photoImport(isPresented: $picking, aspect: 1) { img in
            if let app = target { withAnimation(.snappy) { icons.set(app, img) } }
        }
    }
}

/// 主题色：一条色相条，拖到哪就是哪个颜色（饱和度、明度跟着出厂三档走）
struct HueSlider: View {
    @Binding var hue: Double

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(LinearGradient(colors: stride(from: 0.0, through: 360, by: 30).map {
                        Color(hue: $0 / 360, saturation: 0.34, brightness: 0.88)
                    }, startPoint: .leading, endPoint: .trailing))
                    .frame(height: 22)
                Circle()
                    .fill(Color(hue: hue / 360, saturation: 0.34, brightness: 0.88))
                    .overlay(Circle().stroke(.white, lineWidth: 3))
                    .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
                    .frame(width: 28, height: 28)
                    .offset(x: CGFloat(hue / 360) * (w - 28))
            }
            .frame(height: 28)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                hue = max(1, min(359, Double((v.location.x - 14) / max(1, w - 28)) * 360))
            })
        }
        .frame(height: 28)
    }
}

extension UIImage {
    /// 长边超过 maxSide 就等比缩小（导入背景用，别存原图）
    func scaledDown(maxSide: CGFloat) -> UIImage {
        let longest = max(size.width, size.height)
        guard longest > maxSide else { return self }
        let s = maxSide / longest
        let target = CGSize(width: size.width * s, height: size.height * s)
        return UIGraphicsImageRenderer(size: target).image { _ in draw(in: CGRect(origin: .zero, size: target)) }
    }
}
