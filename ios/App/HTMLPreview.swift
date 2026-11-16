import SwiftUI
import WebKit

// MARK: - TA 写的网页（11-16 内测许愿：「小机写的交互只有代码」）
//
// 回复里有 ```html 代码块，或者整条就是一页 <!DOCTYPE html> / <html>：气泡里不再铺一大段代码，
// 换成一张小卡片，点开全屏跑起来。手机上渲染，Lite 本机和连 Host 一样。
// 沙盒：不存任何东西（非持久的数据区，没有 cookie、没有本地存储留下来），碰不到 App 的聊天和钥匙；
// 页面里点链接不跳走（只认第一次加载），弹窗不弹。页面自己引 CDN 的脚本 / 样式照常能加载。

/// 气泡里那张卡
struct HTMLCard: View {
    let html: String
    let ink: Color
    @State private var open = false

    var body: some View {
        Button { open = true } label: {
            HStack(spacing: 10) {
                Image(systemName: "safari")
                    .font(Typo.icon(20))
                    .frame(width: 36, height: 36)
                    .background(RoundedRectangle(cornerRadius: Radii.chip, style: .continuous).fill(ink.opacity(0.08)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(HTMLBlock.title(html)).font(Typo.sans(Typo.Size.body, .semibold)).lineLimit(1)
                    Text("点开看看").font(Typo.sans(Typo.Size.caption)).opacity(0.65)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.left.and.arrow.down.right").font(Typo.icon(12, .semibold)).opacity(0.5)
            }
            .foregroundStyle(ink)
            .padding(10)
            .frame(minWidth: 200, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Radii.bubble, style: .continuous).fill(ink.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: Radii.bubble, style: .continuous).stroke(ink.opacity(0.12), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .fullScreenCover(isPresented: $open) { HTMLPageView(html: html) }
    }
}

/// 全屏看
struct HTMLPageView: View {
    let html: String
    @Environment(\.dismiss) private var dismiss
    @State private var showCode = false

    var body: some View {
        NavigationStack {
            Group {
                if showCode {
                    ScrollView {
                        Text(html).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding()
                    }
                } else {
                    SandboxWebView(html: HTMLBlock.document(html)).ignoresSafeArea(edges: .bottom)
                }
            }
            .navigationTitle(HTMLBlock.title(html))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关上") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button { showCode.toggle() } label: {
                            Label(showCode ? "看网页" : "看代码", systemImage: showCode ? "safari" : "chevron.left.forwardslash.chevron.right")
                        }
                        Button { UIPasteboard.general.string = html } label: { Label("复制代码", systemImage: "doc.on.doc") }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
        }
    }
}

/// 关在沙盒里的网页：不留数据、不跳走、不弹窗
struct SandboxWebView: UIViewRepresentable {
    let html: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.isOpaque = false
        view.backgroundColor = .systemBackground
        view.loadHTMLString(html, baseURL: nil)
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        private var loaded = false

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            // 第一次加载放行；页面里的 iframe 照常；点链接、跳转一律不走
            if !loaded { loaded = true; return .allow }
            if action.targetFrame?.isMainFrame == false { return .allow }
            return .cancel
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
    }
}
