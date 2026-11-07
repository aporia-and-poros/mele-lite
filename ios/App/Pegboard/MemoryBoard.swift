import PhotosUI
import SwiftUI

/// 洞洞板上的四件
enum PegLeaf: Int, CaseIterable, Identifiable {
    case letter, album, record, map
    var id: Int { rawValue }
}

/// Memory 页的洞洞板（照之前自用的 App MemoryDesk：长按进摆放模式，拖到哪算哪；贴纸架挂在板上）。
struct MemoryBoard: View {
    @EnvironmentObject private var theme: AppTheme
    @Binding var editing: Bool
    var albumPhoto: UIImage?
    var onOpen: (PegLeaf) -> Void
    var onChangePhoto: () -> Void

    struct Placement {
        let leaf: PegLeaf
        let x: CGFloat, y: CGFloat
        let width: CGFloat
        let tilt: Double
    }

    static let placements: [Placement] = [
        .init(leaf: .letter, x: 0.30, y: 0.22, width: 0.40, tilt: -4),
        .init(leaf: .album, x: 0.75, y: 0.28, width: 0.32, tilt: 4),
        .init(leaf: .record, x: 0.25, y: 0.60, width: 0.25, tilt: -3),
        .init(leaf: .map, x: 0.70, y: 0.63, width: 0.34, tilt: 3),
    ]

    @AppStorage("pegLayout") private var saved: String = ""
    @State private var dragging: String?
    @State private var tearing: String?
    @State private var dragOffset: CGSize = .zero
    @State private var lastMoved: String?

    @ObservedObject private var stickers = DeskStickerStore.shared
    @AppStorage("pegShelfSpot") private var shelfSaved: String = ""
    static let shelfDefault = CGPoint(x: 0.5, y: 0.91)
    static let stickerSize: CGFloat = 64

    var body: some View {
        GeometryReader { geo in
            let W = geo.size.width, H = geo.size.height
            let spots = Self.parse(saved)
            ZStack(alignment: .topLeading) {
                ForEach(Array(Self.placements.enumerated()), id: \.offset) { index, p in
                    let spot = spots[p.leaf] ?? CGPoint(x: p.x, y: p.y)
                    let key = "leaf.\(p.leaf.rawValue)"
                    let live = dragging == key ? dragOffset : .zero
                    PegItem(leaf: p.leaf, width: W * p.width, tilt: p.tilt, editing: editing,
                            albumPhoto: albumPhoto, onChangePhoto: onChangePhoto)
                        .position(x: W * spot.x + live.width, y: H * spot.y + live.height)
                        .zIndex(dragging == key ? 30 : (lastMoved == key ? 20 : Double(index)))
                        .gesture(
                            enterArrange
                                .exclusively(before: TapGesture().onEnded {
                                    guard !editing else { return }
                                    onOpen(p.leaf)
                                })
                        )
                        .simultaneousGesture(editing ? move(key, from: spot, in: geo.size) { pt in
                            var spots = Self.parse(saved)
                            spots[p.leaf] = pt
                            saved = Self.serialize(spots)
                        } : nil)
                }

                ForEach(Array(stickers.placed.enumerated()), id: \.element.id) { index, ps in
                    if let item = stickers.item(ps.stickerID) {
                        let key = "sticker.\(ps.id)"
                        let live = dragging == key ? dragOffset : .zero
                        StickerFace(item: item, image: stickers.image(for: item), size: Self.stickerSize)
                            .rotationEffect(.degrees(ps.tilt + (editing ? 1 : 0)))
                            .overlay(alignment: .topTrailing) {
                                if editing {
                                    Button { withAnimation { stickers.unplace(ps.id) } } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.system(size: 17))
                                            .foregroundStyle(Color(white: 0.4), Color.white)
                                    }
                                    .buttonStyle(.plain)
                                    .offset(x: 6, y: -6)
                                }
                            }
                            .position(x: W * ps.x + live.width, y: H * ps.y + live.height)
                            .zIndex(dragging == key ? 30 : (lastMoved == key ? 20 : 10 + Double(index) * 0.01))
                            .transition(.scale(scale: 0.4).combined(with: .opacity))
                            .onTapGesture { if !editing { tearing = ps.id } }      // 点一下问要不要撕（11-07 一测：找不到怎么删）
                            .gesture(enterArrange)
                            .simultaneousGesture(editing ? move(key, from: CGPoint(x: ps.x, y: ps.y), in: geo.size) { pt in
                                stickers.move(ps.id, to: pt)
                            } : nil)
                    }
                }

                let shelf = Self.parsePoint(shelfSaved) ?? Self.shelfDefault
                let shelfLive = dragging == "shelf" ? dragOffset : .zero
                StickerShelf(store: stickers, editing: editing) { item in
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                        stickers.place(item, near: CGPoint(x: shelf.x, y: shelf.y - 0.22))
                    }
                }
                .position(x: W * shelf.x + shelfLive.width, y: H * shelf.y + shelfLive.height)
                .zIndex(dragging == "shelf" ? 30 : 9)
                .simultaneousGesture(enterArrange)
                .simultaneousGesture(editing ? move("shelf", from: shelf, in: geo.size) { pt in
                    shelfSaved = String(format: "%.4f,%.4f", pt.x, pt.y)
                } : nil)
            }
            .frame(width: W, height: H)
            .confirmationDialog("把这枚贴纸撕下来？", isPresented: Binding(get: { tearing != nil }, set: { if !$0 { tearing = nil } }),
                                titleVisibility: .visible) {
                Button("撕下来", role: .destructive) {
                    if let id = tearing { withAnimation { stickers.unplace(id) } }
                    tearing = nil
                }
                Button("算了", role: .cancel) { tearing = nil }
            }
            .overlay(alignment: .topTrailing) {
                if editing { editBar.padding(.trailing, 14).padding(.top, 10).transition(.opacity) }
            }
        }
    }

    private var enterArrange: some Gesture {
        LongPressGesture(minimumDuration: 0.45)
            .onEnded { _ in
                guard !editing else { return }
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                withAnimation(.spring(response: 0.3)) { editing = true }
            }
    }

    private func move(_ key: String, from spot: CGPoint, in size: CGSize,
                      commit: @escaping (CGPoint) -> Void) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { v in
                dragging = key
                dragOffset = v.translation
            }
            .onEnded { v in
                let x = min(0.96, max(0.04, spot.x + v.translation.width / max(1, size.width)))
                let y = min(0.96, max(0.04, spot.y + v.translation.height / max(1, size.height)))
                commit(CGPoint(x: x, y: y))
                lastMoved = key
                dragging = nil
                dragOffset = .zero
            }
    }

    private var editBar: some View {
        HStack(spacing: 8) {
            Button("复位") {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
                    saved = ""
                    shelfSaved = ""
                }
            }
            .foregroundStyle(theme.inkDim)
            Button("完成") {
                withAnimation(.spring(response: 0.3)) { editing = false }
            }
            .fontWeight(.semibold)
            .foregroundStyle(theme.accentDeep)
        }
        .font(Typo.sans(14))
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Capsule().fill(Color.white.opacity(0.9))
                        .shadow(color: .black.opacity(0.10), radius: 6, y: 3))
    }

    // MARK: 存取

    static func parsePoint(_ s: String) -> CGPoint? {
        let xy = s.split(separator: ",").compactMap { Double($0) }
        return xy.count == 2 ? CGPoint(x: xy[0], y: xy[1]) : nil
    }

    static func parse(_ s: String) -> [PegLeaf: CGPoint] {
        var out: [PegLeaf: CGPoint] = [:]
        for part in s.split(separator: ";") {
            let kv = part.split(separator: ":")
            guard kv.count == 2, let raw = Int(kv[0]), let leaf = PegLeaf(rawValue: raw),
                  let pt = parsePoint(String(kv[1])) else { continue }
            out[leaf] = pt
        }
        return out
    }

    static func serialize(_ spots: [PegLeaf: CGPoint]) -> String {
        spots.sorted { $0.key.rawValue < $1.key.rawValue }
            .map { "\($0.key.rawValue):\(String(format: "%.4f", $0.value.x)),\(String(format: "%.4f", $0.value.y))" }
            .joined(separator: ";")
    }
}

/// 板上的一件：图标 + 两层淡影子（一层贴着板、一层散开），摆放模式下轻轻晃
private struct PegItem: View {
    @EnvironmentObject private var theme: AppTheme
    let leaf: PegLeaf
    let width: CGFloat
    let tilt: Double
    let editing: Bool
    let albumPhoto: UIImage?
    var onChangePhoto: () -> Void
    @State private var wobble = false

    var body: some View {
        icon
            .frame(width: width)
            .shadow(color: .black.opacity(0.10), radius: 1.2, x: 0, y: 1)
            .shadow(color: .black.opacity(0.08), radius: 8, x: 2, y: 6)
            .overlay(alignment: .bottom) {
                if editing && leaf == .album {
                    Button(action: onChangePhoto) {
                        Label("换照片", systemImage: "photo")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(theme.ink)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Capsule().fill(Color.white.opacity(0.92)))
                            .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
                    }
                    .buttonStyle(.plain)
                    .offset(y: 10)
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .contentShape(Rectangle())
            .rotationEffect(.degrees(tilt + (editing ? (wobble ? 1.3 : -1.3) : 0)))
            .scaleEffect(editing ? 1.02 : 1)
            .onChange(of: editing) { _, on in
                if on {
                    withAnimation(.easeInOut(duration: 0.14).repeatForever(autoreverses: true)) { wobble = true }
                } else {
                    withAnimation(.easeOut(duration: 0.15)) { wobble = false }
                }
            }
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder private var icon: some View {
        switch leaf {
        case .letter: LetterIcon()
        case .album: AlbumIcon(photo: albumPhoto)
        case .record: RecordIcon()
        case .map: MapIcon()
        }
    }

    private var label: String {
        switch leaf {
        case .letter: String(localized: "信")
        case .album: String(localized: "相册")
        case .record: String(localized: "记录")
        case .map: String(localized: "线下")
        }
    }
}
