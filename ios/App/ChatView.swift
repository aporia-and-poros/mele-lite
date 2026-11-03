import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

// 聊天房间：从之前自用的 App ChatView.swift 搬来（2026-09-27 晚，iOS 第一块第 7 步）。
//
// 搬了：UIKit 消息列表（ChatListView.swift，原样）、气泡和「我的气泡」、思考链、动作卡片、
// 微信式时间戳和换天分隔、头像摆法、顶部渐进雾、悬空胶囊头、⋯ 系统菜单、打字三个点、输入框（草稿落盘）、自测。
// 没搬：跟中继和Poros绑死的（爪印按钮、表情包、召唤铃、情绪房间、回执、塔罗、语音条、听他说、收藏、会客厅、思考提示）。
// 第 8 步加了长按浮层（表情条 + 那条消息 + 菜单卡）、引用、多选、编辑（倒回）、重新回。
// 搜索 / 回到那天 / 长文模式 / 改备注是第 9 步，照片文件是第 10 步。

extension ChatItem {
    /// 「回复：xxx」\n正文 → 拆成引用条 + 正文
    var quoteParsed: (quote: String, body: String)? {
        guard text.hasPrefix("「回复："), let end = text.range(of: "」\n") else { return nil }
        let quote = String(text[text.index(text.startIndex, offsetBy: 4)..<end.lowerBound])
        let body = String(text[end.upperBound...])
        guard !quote.isEmpty, !body.isEmpty else { return nil }
        return (quote, body)
    }
}

struct ChatView: View {
    @EnvironmentObject var theme: AppTheme
    @EnvironmentObject var chat: ChatStore
    @EnvironmentObject var avatars: AvatarStore
    @EnvironmentObject var session: SessionStore
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var wentBackground = false
    @ObservedObject private var favorites = FavoritesStore.shared

    let companionID: UUID
    /// 「回到那天」：给了锚点就是只读回顾——同一个房间、同一套气泡，没有输入行，上下都能翻（照之前自用的 App 09-27）
    var momentAnchor: Int? = nil
    /// 左上角 ‹：从消息列表推进来的，按它回去（09-28 第二块）
    var onBack: (() -> Void)? = nil
    /// 无痕窗口：顶上一条提示，离开就整段删（删的确认在外面做）
    var incognito = false
    /// ⋯ 菜单里的新窗口、无痕、TA 的设定（第二块）；nil = 不显示
    var onNewWindow: (() -> Void)? = nil
    var onIncognito: (() -> Void)? = nil
    var onSettings: (() -> Void)? = nil
    /// 小号窗口（Lite）：TA 在这里把你当成谁（空 = 平常的你）
    var altName = ""
    /// 群（10-11）：标题换群名、⋯ 里是群设定；每个 TA 按 speaker 画自己的头像和名字
    var group: GroupDTO? = nil
    var memberLook: [UUID: MemberLook] = [:]
    private var isMoment: Bool { momentAnchor != nil }
    @Environment(\.dismiss) private var dismissMoment
    /// 它的名字：ChatRoom 进来时写一次，改备注时跟着变
    @AppStorage("companionName") private var companionName = "Lumi"
    @AppStorage("companionRelationship") private var companionRelationship = ""

    @AppStorage("showThinking") private var showThinking = true
    @AppStorage("showActionCards") private var showActionCards = true
    @AppStorage("innerVoiceOpen") private var innerVoiceOpen = true      // 心声卡片默认展开（10-11）
    @AppStorage("showTimestamps") private var showTimestamps = true
    @AppStorage("chatAppearance") private var appearanceRaw = ChatAppearance.light.rawValue   // 新用户默认浅色（Aporia 10-04）
    @AppStorage("chatDarkWallpaper") private var chatDarkWallpaper = false
    @AppStorage("bubbleStyleLight") private var bubbleStyleLight = ""
    @AppStorage("bubbleStyleDark") private var bubbleStyleDark = ""
    @AppStorage("fadeStyleLight") private var fadeStyleLight = ""
    @AppStorage("fadeStyleDark") private var fadeStyleDark = ""
    @AppStorage("thoughtStyleLight") private var thoughtStyleLight = ""
    @AppStorage("thoughtStyleDark") private var thoughtStyleDark = ""
    @AppStorage("chatFontScale") private var fontScaleRaw: Double = ChatFontStep.normal.rawValue
    @AppStorage("chatFontDefault") private var fontDefault: Double = 1.0

    @State private var showBubbleSettings = false
    @State private var coachFrames: [String: CGRect] = [:]
    @State private var showTour = false
    @State private var showWallpaper = false
    @State private var expandedThoughts: Set<Int> = []
    /// 心声卡片里跟默认（innerVoiceOpen）相反的那几张：点过一下的
    @State private var flippedVoices: Set<Int> = []
    @State private var highlightID: Int?
    @State private var selecting = false
    @State private var selectedIDs: Set<Int> = []
    @State private var quoting: ChatItem?
    /// 「更多表情…」正在给哪条选
    @State private var emojiPickFor: ChatItem?
    @State private var openedCard: OpenedCard?
    /// 查手机申请卡：本机先改掉状态（服务器那份下次拉回来也一样）；正在挑给看哪几间的那张
    /// 它正在申请翻手机的那一行（最近一张还没答的）
    private var pendingPeek: ChatItem? {
        chat.items.last { if case .card(let k) = $0.kind { k == "peek:ask" } else { false } }
    }
    /// 它提议陪你专注（10-05 Aporia：跟查手机一样弹在屏幕中间，不往聊天里挂卡片）：最近一张、十分钟内、还没答过的
    @AppStorage("focusOffersAnswered") private var focusAnsweredRaw = ""
    private var pendingFocus: ChatItem? {
        let answered = Set(focusAnsweredRaw.split(separator: ",").map(String.init))
        guard let f = chat.items.last(where: { if case .card(let k) = $0.kind { k == "focus" } else { false } }),
              Date().timeIntervalSince(f.at) < 600, !answered.contains(String(f.id)) else { return nil }
        return f
    }
    private func answerFocus(_ item: ChatItem, start: Bool) {
        let kept = focusAnsweredRaw.split(separator: ",").suffix(50).map(String.init)
        focusAnsweredRaw = (kept + [String(item.id)]).joined(separator: ",")
        if start { NotificationCenter.default.post(name: .lumiOpenFocus, object: nil, userInfo: FocusPrefill.parse(item.text)) }
    }
    /// 长按浮层正对着哪条（Instagram 那种：表情条在上、气泡在中、菜单在下）
    @State private var actionItem: ChatItem?
    @State private var actionPopped = false
    /// 键盘此刻在不在（长按时在就先收起来，浮层关了再叫回来）
    @State private var keyboardUp = false
    @State private var refocusAfterActions = false
    /// 倒回之前要问一声的那条（后面还有别的话，会一起撤）
    @State private var confirmRewind: ChatItem?
    /// 指挥 UIKit 那半边列表的把手；引用类型，跨重画活着
    @State private var listHandle = ChatListHandle()
    /// 胶囊头的下缘（全局坐标）：列表内容从它底下开始
    @State private var headerBottom: CGFloat = 0
    @State private var showSearch = false
    /// 搜索 / 日历点了一条不在眼前的：开一个回顾
    @State private var moment: MomentTarget?
    /// 长文模式：真值在服务器（联系人设置 long_mode），这里是镜像
    @State private var longModeOn = false
    @State private var renaming = false
    @State private var nameDraft = ""
    // 照片、文件（第 10 步）
    @State private var cameraPresented = false
    @State private var photoPickerPresented = false
    @State private var stickerPanel = false
    @State private var thoughtZh: [Int: String] = [:]     // 思考链的中文翻译（10-01）
    @State private var showZh: Set<Int> = []
    @State private var translating: Int?
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var filePickerPresented = false
    @State private var imageViewer: ImageViewerState?
    @State private var callLog: CallLogTarget?
    @State private var visitingMoments: MomentsVisit?    // 点 TA 的头像进 TA 的朋友圈（11-03 Aporia，照微信）
    #if LITE
    @State private var consentAsk: LiteConsent.Ask?
    @State private var calling = false          // 语音通话（10-31）
    @State private var showCallHistory = false  // 通话记录（10-31，第 5 步）
    #endif

    private var skin: ChatSkin {
        let mode = ChatAppearance(rawValue: appearanceRaw) ?? .dark
        return ChatSkin(mode: mode,
                        accent: theme.accent,
                        scale: CGFloat(fontScaleRaw),
                        wallpaperInDark: chatDarkWallpaper,
                        bubble: BubbleStyle.effective(raw: mode == .light ? bubbleStyleLight : bubbleStyleDark,
                                                      mode: mode))
    }
    private var bubbleLayout: BubbleStyle.Layout { skin.bubble?.layout ?? .header }
    private var thoughtStyle: ThoughtStyle {
        ThoughtStyle.decode(skin.isDark ? thoughtStyleDark : thoughtStyleLight)
    }

    /// 显示开关过滤后的行
    private var visibleItems: [ChatItem] {
        chat.items.filter { item in
            switch item.kind {
            case .thinking: return showThinking && !item.text.isEmpty   // 开头占位的那行不画（10-01 Aporia：还是只有三个点好看）
            case .card("divider"), .card("callEnd"), .card("callRing"): return true        // 搬来的那几段的分隔行、通话时长那行，跟动作卡片开关无关
            case .card, .deeds: return showActionCards
            case .text, .song, .sticker, .innerVoice: return true
            }
        }
    }

    var body: some View {
        ZStack {
            // 房间自带不透明的底：深色＝纯黑，浅色（或深色开了壁纸）＝她选的聊天壁纸
            if let background = skin.pageBackground {
                background.ignoresSafeArea()
            } else {
                AppBackground(choiceOverride: theme.chatBgChoice != "same" ? theme.chatBgChoice : nil,
                              darkVeil: skin.darkVeil)
            }
            messagesList
                .ignoresSafeArea()
                .overlay {
                    // 导览「长按气泡」那一步亮的地方：消息区中间一块（气泡在 UIKit 列表里，报不了各自的位置）
                    Color.clear.frame(height: 220).coachMark("bubbles").allowsHitTesting(false)
                }
                // 顶部渐进模糊：消息滑到状态栏底下时被雾化
                .overlay(alignment: .top) {
                    TopFadeOverlay(isDark: skin.isDark,
                                   style: FadeStyle.decode(skin.isDark ? fadeStyleDark : fadeStyleLight))
                        .ignoresSafeArea(edges: .top)
                        .allowsHitTesting(false)
                }
        }
        .overlay(alignment: .top) {
            VStack(spacing: 6) {
                if isMoment { momentHeader } else { header }
                if incognito && !isMoment { incognitoBanner }
                if !altName.isEmpty && !isMoment { altBanner }
            }
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { bottom in
                    if bottom != headerBottom { headerBottom = bottom }
                }
        }
        // 它申请翻手机：屏幕中间弹出来，背后整屏模糊（Aporia 10-04：不做成卡片）
        .overlay {
            if let p = pendingPeek, !isMoment {
                PeekPrompt(companionName: companionName, want: p.text, avatar: avatars.ai) { allow, rooms in
                    Task { await chat.answerPeek(row: p.id, messageID: p.messageID, allow: allow, rooms: rooms) }
                }
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.25), value: pendingPeek?.id)
        .overlay {
            if let f = pendingFocus, pendingPeek == nil, !isMoment {
                FocusPrompt(companionName: companionName, offer: f.text, avatar: avatars.ai) { start in answerFocus(f, start: start) }
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.25), value: pendingFocus?.id)
        // 系统的东西（⋯ 菜单、弹出页、状态栏）跟着聊天页的深浅走，不跟手机的（Aporia 09-28：深色下菜单还是浅色）
        .preferredColorScheme(skin.isDark ? .dark : .light)
        .onPreferenceChange(CoachFrameKey.self) { coachFrames = $0 }
        .overlay {
            if let card = openedCard {
                ActionCardOverlay(card: card, skin: skin) {
                    withAnimation(.easeOut(duration: 0.2)) { openedCard = nil }
                }
                .transition(.opacity)
            }
        }
        .overlay {
            if showTour {
                CoachOverlay(steps: [
                    CoachStep(id: "plus", text: String(localized: "发照片、文件给 TA")),
                    CoachStep(id: "bubbles", text: String(localized: "长按一条消息：复制、引用、点个表情，或者让 TA 重新说"), padding: -20),
                    CoachStep(id: "more", text: String(localized: "新窗口、无痕、TA 的设定都在这里，还能换壁纸和字号")),
                    CoachStep(id: "search", text: String(localized: "搜聊过的话，或者按日历回到那天")),
                ], frames: coachFrames) {
                    withAnimation { showTour = false }
                    CoachTour.done(CoachTour.chatKey)
                }
                .environment(\.colorScheme, .light)
                .transition(.opacity)
            }
        }
        .task {
            guard !isMoment, CoachTour.pending(CoachTour.chatKey) else { return }
            try? await Task.sleep(for: .seconds(3))       // 先让 TA 把招呼打完
            withAnimation { showTour = true }
        }
        .onAppear { chat.start() }
        .task { await favorites.loadIfNeeded(session.api) }
        .onDisappear { chat.stop() }
        .onChange(of: scenePhase) { _, phase in
            // 切到后台就断开事件流（10-12 内测：挂起时连接还在，Host 以为你还看着，它的回话就不推送了）。
            // 回来是 后台 → inactive → active，最后一跳的 old 是 inactive，所以用自己记的标记判断，不看 old
            if phase == .background { wentBackground = true; chat.stop() }
            if phase == .active, wentBackground { wentBackground = false; chat.resume() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .lumiFocusSaid)) { _ in Task { await chat.catchUp() } }
        .task {
            #if DEBUG && LITE
            if CommandLine.arguments.contains("-callSelfTest") && !isMoment && group == nil {     // 自测（10-31）
                try? await Task.sleep(for: .seconds(1.5))
                calling = true
            }
            #endif
            if Self.selfTest && !isMoment { await runSelfTest() }
            // 自测：-openMoment <消息号> 直接开「回到那天」
            let args = ProcessInfo.processInfo.arguments
            if !isMoment, let i = args.firstIndex(of: "-openMoment"), i + 1 < args.count, let id = Int(args[i + 1]) {
                try? await Task.sleep(for: .seconds(1))
                moment = MomentTarget(id: id)
            }
        }
        .onChange(of: chat.loaded) { _, loaded in
            if loaded, let anchor = momentAnchor { Task { await landOnMoment(anchor) } }
        }
        .sheet(isPresented: $showSearch) {
            ChatSearchView(companionName: companionName) { messageID in
                showSearch = false
                open(messageID)
            }
            .environmentObject(theme)
            .environmentObject(chat)
            .environmentObject(avatars)
        }
        #if LITE
        .fullScreenCover(isPresented: $calling) {
            CallView(conversation: chat.conversation.uuidString.lowercased(), api: chat.api, name: companionName, avatar: avatars.ai) {
                calling = false
            }
        }
        #endif
        .sheet(item: $callLog) { t in
            Group {
                #if LITE
                // 按通话编号取、TA 每句能重听（本机读手机里的，连着 Host 问 Host）
                CallDetailSheet(conversation: chat.conversation.uuidString.lowercased(), endMessage: t.id, name: companionName,
                                api: chat.api)
                #else
                CallLogSheet(title: t.title, lines: chat.callLines(endingAt: t.id), name: companionName)
                #endif
            }
            .environmentObject(theme)
            .presentationDetents([.medium, .large])
        }
        #if LITE
        .sheet(isPresented: $showCallHistory) {
            CallHistoryView(conversation: chat.conversation.uuidString.lowercased(), name: companionName, api: chat.api)
                .environmentObject(theme)
                .presentationDetents([.large])
        }
        #endif
        .fullScreenCover(item: $visitingMoments) { v in
            MomentsView(api: chat.api, who: v.who).environmentObject(model).environmentObject(theme)
        }
        .fullScreenCover(item: $moment) { target in
            MomentRoom(companionID: companionID, conversation: chat.conversation, anchor: target.id, api: chat.api)
                .environmentObject(theme)
                .environmentObject(avatars)
                .environmentObject(session)
        }
        .modifier(AttachLayer(view: self))
        .alert("给它改个名字", isPresented: $renaming) {
            TextField("名字", text: $nameDraft)
            Button("保存") { Task { await rename(nameDraft) } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("它会知道自己改名了。")
        }
        .sheet(isPresented: $showWallpaper) {
            ChatWallpaperSheet()
                .environmentObject(theme)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showBubbleSettings) {
            BubbleSettingsView()
                .environmentObject(theme)
                .environmentObject(avatars)
                .presentationDetents([.large])
        }
        .modifier(ActionLayer(view: self))
    }

    /// 照片 / 文件那一层的挂件：相机、相册、文件选择、全屏看图
    fileprivate func attachLayer<V: View>(_ content: V) -> some View {
        content
            .fullScreenCover(isPresented: $cameraPresented) {
                CameraPicker { jpeg in
                    Task { await chat.sendAttachments([(jpeg, "photo-\(Int(Date().timeIntervalSince1970)).jpg", "image/jpeg")]) }
                }
                .ignoresSafeArea()
            }
            .sheet(isPresented: $stickerPanel) {
                StickerPanel(api: session.api) { id in stickerPanel = false; Task { await chat.sendSticker(id) } }
                    .environmentObject(theme)
                    .presentationDetents([.medium, .large])
            }
            .photosPicker(isPresented: $photoPickerPresented, selection: $photoItems, maxSelectionCount: 9, matching: .images)
            .onChange(of: photoItems) { _, items in
                guard !items.isEmpty else { return }
                Task {
                    var files: [(Data, String, String)] = []
                    let stamp = Int(Date().timeIntervalSince1970)
                    for (i, item) in items.enumerated() {
                        // 手机上先压到长边 1600（设计定的），服务器那边超 2048 还会再缩
                        if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data),
                           let jpeg = image.resizedIfNeeded(maxSide: 1600).jpegData(compressionQuality: 0.8) {
                            files.append((jpeg, "photo-\(stamp)-\(i + 1).jpg", "image/jpeg"))
                        }
                    }
                    photoItems = []
                    await chat.sendAttachments(files)
                }
            }
            .fileImporter(isPresented: $filePickerPresented, allowedContentTypes: Self.fileTypes,
                          allowsMultipleSelection: false) { result in
                guard case .success(let urls) = result, let url = urls.first else { return }
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url) else { return }
                guard data.count <= 20_000_000 else { chat.errorText = "文件太大了（20MB 以内）"; return }
                let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "text/plain"
                Task { await chat.sendAttachments([(data, url.lastPathComponent, mime)]) }
            }
            .fullScreenCover(item: $imageViewer) { state in
                ImageViewerView(state: state)
            }
    }

    /// 先只认 PDF、纯文本、Markdown（服务器能抽出字的那几种）
    static let fileTypes: [UTType] = [.pdf, .plainText, UTType("net.daringfireball.markdown") ?? .text]

    /// 长按浮层那一层的挂件（拆出来：全堆在 body 上编译器算不动类型）
    fileprivate func actionLayer<V: View>(_ content: V) -> some View {
        content
            .overlay {
                if let item = actionItem {
                    actionOverlay(item)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.18), value: actionItem?.id)
            .sheet(item: $emojiPickFor) { item in
                EmojiPickerSheet { emoji in
                    EmojiCatalog.noteRecent(emoji)
                    if let mid = item.messageID, let b = item.bubble { Task { await chat.react(messageID: mid, bubble: b, emoji: emoji) } }
                }
            .presentationDetents([.fraction(0.62), .large])
            .presentationDragIndicator(.visible)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                keyboardUp = true
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                keyboardUp = false
            }
            .onChange(of: selecting) { _, isSelecting in
                listHandle.selectionModeChanged(selecting: isSelecting, firstSelected: selectedIDs.first)
            }
            #if LITE
            .sheet(item: $consentAsk) { ask in
                LiteConsentSheet(ask: ask, onAgree: {
                    LiteConsent.book.grant(ask.provider)
                    consentAsk = nil
                    chat.send(ask.text)
                }, onCancel: {
                    UserDefaults.standard.set(ask.text, forKey: draftKey)       // 没发的话放回输入框
                    consentAsk = nil
                })
                .environmentObject(theme)
                .presentationDetents([.medium])
                .interactiveDismissDisabled()
            }
            #endif
            .confirmationDialog(confirmRewind?.mine == true ? "从这句往后的聊天都会撤回" : "这一轮和之后的聊天都会撤回",
                                isPresented: Binding(get: { confirmRewind != nil }, set: { if !$0 { confirmRewind = nil } }),
                                titleVisibility: .visible) {
                if let item = confirmRewind {
                    Button(item.mine ? "撤回并编辑这句" : "撤回并重新回", role: .destructive) { doRewind(item) }
                }
            } message: {
                Text(confirmRewind?.mine == true ? "这句的原文会放回输入栏。它这些话里记下的东西也一起撤掉。"
                                                 : "它会重新回这一轮。它这些话里记下的东西也一起撤掉。")
            }
    }

    /// 悬空的底部：错误条 + 输入行。整体没有底色，透出聊天内容。
    @ViewBuilder
    private var bottomBar: some View {
        if isMoment {
            // 回顾不能说话：留一点底，最后一条别贴着 home 条
            Color.clear.frame(height: 12)
        } else {
            liveBottomBar
        }
    }

    private var liveBottomBar: some View {
        VStack(spacing: 0) {
            if let error = chat.errorText {
                Text(error)
                    .font(Typo.sans(Typo.Size.callout))
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 4)
            }
            if let quoted = quoting {
                quotingBar(quoted)
            }
            // 水位（Lite，10-04 Aporia）：左下角一小行，当前多少 token · 还剩多少满
            if Lite.local && !isMoment && group == nil {
                GaugeLine(api: chat.api, conversation: chat.conversation, tick: chat.typing, skin: skin)
            }
            inputBar
        }
    }

    static func relationshipIcon(_ rel: String) -> String? {
        switch rel {
        case "": return nil
        case "friend": return "person.2.fill"
        case "partner": return "heart.fill"
        case "family": return "house.fill"
        case "buddy": return "figure.2"
        case "card": return "theatermasks.fill"   // 导入的角色卡（10-01）
        default: return "tag.fill"          // 自己写的关系
        }
    }

    /// 悬浮胶囊头：名字 + 一个绿灯居中，右边 ⋯。没有导航栏、没有分隔线。
    /// （10-04 Aporia：去掉头像和 connected 那行字，只留备注和绿灯）
    private var header: some View {
        ZStack {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(chat.connected ? Color.green : Color.orange)
                        .frame(width: 6, height: 6)
                        .accessibilityLabel(chat.connected ? "connected" : "reconnecting")
                    if let group {
                        // 群：群名（人数）；有人在打字就换成「阿橘 正在输入…」
                        Text(chat.typing && !(chat.typingName ?? "").isEmpty ? "\(chat.typingName!) 正在输入…"
                                                                           : "\(group.displayName)（\(group.members.count)）")
                            .font(Typo.sans(skin.size(Typo.Size.headline), .semibold))
                            .foregroundStyle(skin.ink)
                            .lineLimit(1)
                    } else {
                    Text(companionName)
                        .font(Typo.sans(skin.size(Typo.Size.headline), .semibold))
                        .foregroundStyle(skin.ink)
                    }
                }
                // 长按名字改备注（10-04 Aporia：之前自用的 App里一直这么用）
                .contentShape(Rectangle())
                .onLongPressGesture(minimumDuration: 0.4) {
                    guard !isMoment, group == nil else { return }
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    nameDraft = companionName
                    renaming = true
                }
                // 你们的关系（09-29 Aporia，照之前自用的 App胶囊里的爱心）：朋友两个人、恋人爱心、家人小房子、搭子并肩；点开 TA 的设定
                if let icon = Self.relationshipIcon(companionRelationship), !isMoment, group == nil {
                    Button { onSettings?() } label: {
                        Image(systemName: icon)
                            .font(Typo.icon(11))
                            .foregroundStyle(skin.inkDim)
                            .frame(width: 30, height: 30)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, -8)
                    .contentTransition(.symbolEffect(.replace))
                }
                // 线下（长文）开着：一个小标，点一下回到日常（10-01 Aporia：「转线下」要一眼看得到、一点就切）
                if longModeOn, !isMoment, group == nil {
                    Button { longModeOn = false; Task { await pushLongMode(false) } } label: {
                        Text("线下")
                            .font(Typo.sans(skin.size(Typo.Size.caption), .semibold))
                            .foregroundStyle(skin.inkDim)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .overlay(Capsule().stroke(skin.inkDim.opacity(0.5), lineWidth: 0.8))
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 6)
                }
            }
            .padding(.leading, 16)
            .padding(.trailing, 14)
            .padding(.vertical, 9)
            .background(paintedChrome(Capsule(), skin: skin))

            HStack(spacing: 8) {
                if let onBack {
                    Button { onBack() } label: { circleIcon("chevron.left") }
                        .buttonStyle(.plain)
                }
                Spacer()
                // 搜索和 ⋯ 合成一条长胶囊（10-10 Aporia）：画 36 高，热区照旧 44
                HStack(spacing: 0) {
                    Button { showSearch = true } label: { pillIcon("magnifyingglass").coachMark("search") }
                        .buttonStyle(.plain)
                    moreMenu
                }
                .padding(.horizontal, 4)
                .background(paintedChrome(Capsule(), skin: skin).padding(.vertical, 4))
                .padding(.trailing, 4)                  // 跟左边返回键的圆一样离边 20（圆是 44 热区里画 36）
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    /// 无痕窗口顶上那条
    private var incognitoBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "eye.slash").font(Typo.icon(11, .semibold))
            Text("无痕中 · 离开就全部删掉").font(Typo.sans(Typo.Size.caption, .medium))
        }
        .foregroundStyle(skin.inkDim)
        .padding(.horizontal, 12).padding(.vertical, 5)
        .background(paintedChrome(Capsule(), skin: skin))
    }

    /// 小号窗口顶上那条
    private var altBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "person.crop.circle.dashed").font(Typo.icon(11, .semibold))
            Text("小号 · 在这里你是「\(altName)」").font(Typo.sans(Typo.Size.caption, .medium))
        }
        .foregroundStyle(skin.inkDim)
        .padding(.horizontal, 12).padding(.vertical, 5)
        .background(paintedChrome(Capsule(), skin: skin))
    }

    private var draftKey: String { "chatDraft-\(chat.conversation.uuidString.lowercased())" }

    private func circleIcon(_ icon: String) -> some View {
        Image(systemName: icon)
            .font(Typo.icon(15, .semibold))
            .foregroundStyle(skin.chromeIcon)
            // 44×44 是 HIG 的触控下限，圆圈画 36 但热区给足
            .frame(width: 36, height: 36)
            .background(paintedChrome(Circle(), skin: skin))
            .contentShape(Rectangle())
            .frame(width: 44, height: 44)
    }

    /// 长胶囊里的一格：不自己画底，底是外面那条胶囊
    private func pillIcon(_ icon: String) -> some View {
        Image(systemName: icon)
            .font(Typo.icon(15, .semibold))
            .foregroundStyle(skin.chromeIcon)
            .frame(width: 40, height: 44)
            .contentShape(Rectangle())
    }

    /// ⋯：系统原生菜单（之前自用的 App 2026-09-25 定的：动画和质感只有真的系统菜单才有）。
    /// 字号照 Safari「Aa」那样一排：A⁻ | 百分比 | A⁺，点了不关菜单。
    private var moreMenu: some View {
        Menu {
            ControlGroup {
                ForEach(ChatAppearance.allCases, id: \.rawValue) { mode in
                    Button {
                        appearanceRaw = mode.rawValue
                    } label: {
                        Label(mode.label, systemImage: appearanceRaw == mode.rawValue
                              ? mode.icon : mode.icon.replacingOccurrences(of: ".fill", with: ""))
                    }
                }
                Button {
                    showWallpaper = true
                } label: {
                    Label("壁纸", systemImage: "photo")
                }
            }
            ControlGroup {
                Button {
                    fontScaleRaw = max(0.85, ((fontScaleRaw - 0.05) * 100).rounded() / 100)
                } label: {
                    Label("小一点", systemImage: "textformat.size.smaller")
                }
                Menu {
                    Button {
                        fontScaleRaw = fontDefault
                    } label: {
                        Label("回到默认（\(Int((fontDefault * 100).rounded()))%）", systemImage: "arrow.uturn.backward")
                    }
                    Button {
                        fontDefault = fontScaleRaw
                    } label: {
                        Label("把 \(Int((fontScaleRaw * 100).rounded()))% 设为默认", systemImage: "pin")
                    }
                } label: {
                    Text("\(Int((fontScaleRaw * 100).rounded()))%")
                }
                Button {
                    fontScaleRaw = min(1.3, ((fontScaleRaw + 0.05) * 100).rounded() / 100)
                } label: {
                    Label("大一点", systemImage: "textformat.size.larger")
                }
            }
            .menuActionDismissBehavior(.disabled)
            Divider()
            Menu {
                Toggle(isOn: $showTimestamps) {
                    Label("时间戳", systemImage: "clock")
                }
                Toggle(isOn: $showActionCards) {
                    Label("做了几件事", systemImage: "checklist")
                }
                Toggle(isOn: $showThinking) {
                    Label("思考过程", systemImage: "sparkles")
                }
                Toggle(isOn: $innerVoiceOpen) {
                    Label("心声默认展开", systemImage: "heart.text.square")
                }
            } label: {
                Label("拓展显示", systemImage: "square.stack.3d.up")
            }
            Button {
                showBubbleSettings = true
            } label: {
                Label("我的气泡", systemImage: "bubble.left.and.bubble.right")
            }
            // 线下 = 长文模式：场景、动作、心理整段写，不切成一泡一泡（真值在服务器；10-01 改名）
            if group == nil {
            Toggle(isOn: Binding(get: { longModeOn },
                                 set: { on in longModeOn = on; Task { await pushLongMode(on) } })) {
                Label("线下（长文）", systemImage: "theatermasks")
            }
            }
            Divider()
            // 改备注挪进了「TA 的设定」（09-28：菜单太长，TA 的设定被挤到要滚才看得到）
            // 打电话（10-31）：Lite 本机先能打；连着 Host 的、正式版还占着位
            #if LITE
            if Lite.on && group == nil {         // 连着 Host 也能打（10-31 第 3 步；Host 要 update 到带电话的那版）
                Button { calling = true } label: { Label("语音通话", systemImage: "phone.fill") }
                Button { showCallHistory = true } label: { Label("通话记录", systemImage: "clock.arrow.circlepath") }
            } else {
                Button {} label: { Label("打电话（以后做）", systemImage: "phone.fill") }.disabled(true)
            }
            #else
            Button {} label: {
                Label("打电话（以后做）", systemImage: "phone.fill")
            }
            .disabled(true)
            #endif
            if onNewWindow != nil || onIncognito != nil || onSettings != nil {
                Divider()
                if !incognito, let onNewWindow, let onIncognito {
                    ControlGroup {
                        Button { onNewWindow() } label: { Label("新窗口", systemImage: "plus.bubble") }
                        Button { onIncognito() } label: { Label("无痕", systemImage: "eye.slash") }
                    }
                }
                if let onSettings {
                    Button { onSettings() } label: { Label(group == nil ? "TA 的设定" : "群设定", systemImage: "slider.horizontal.3") }
                }
            }
        } label: {
            pillIcon("ellipsis").coachMark("more")
        }
        .task { if group == nil { await fetchLongMode() } }
    }

    // MARK: - 长文模式、改备注（都存服务器的联系人设置 / 人设）

    private var companionPath: String { "companions/\(companionID.uuidString.lowercased())" }

    private func fetchLongMode() async {
        if let c: CompanionDetail = try? await chat.api.call("GET", companionPath) {
            longModeOn = c.settings?.longMode ?? false
        }
    }

    private func pushLongMode(_ on: Bool) async {
        do {
            // 进线下顺手把「线下生活」打开（10-05 Aporia）；出来不关，那是 TA 设定里的事
            try await chat.api.send("PATCH", companionPath, json: ["settings": on && Lite.on ? ["long_mode": true, "offline_life": true] : ["long_mode": on]])
        } catch {
            longModeOn = !on
            chat.errorText = "长文模式没切过去：\(error.localizedDescription)"
        }
    }

    private func rename(_ raw: String) async {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != companionName else { return }
        do {
            try await chat.api.send("PATCH", companionPath, json: ["persona": ["name": String(name.prefix(20))]])
            companionName = String(name.prefix(20))
        } catch {
            chat.errorText = "名字没改成：\(error.localizedDescription)"
        }
    }

    // MARK: - 搜索跳转、回到那天

    /// 搜到的那条在眼前就滚过去亮一下，不在就开一个回顾
    private func open(_ messageID: Int) {
        if let row = visibleItems.first(where: { $0.messageID == messageID && $0.kind == .text }) {
            listHandle.jump(to: row.id)
            flash(row.id)
        } else {
            moment = MomentTarget(id: messageID)
        }
    }

    private func flash(_ id: Int) {
        highlightID = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            withAnimation { if highlightID == id { highlightID = nil } }
        }
    }

    /// 回顾落地：等列表把行装上，跳到锚点那句、亮一下
    private func landOnMoment(_ anchor: Int) async {
        try? await Task.sleep(for: .milliseconds(80))
        let list = visibleItems
        guard let target = list.first(where: { $0.messageID == anchor && $0.kind == .text })
                ?? list.first(where: { ($0.messageID ?? 0) >= anchor }) ?? list.last else { return }
        listHandle.jump(to: target.id)
        flash(target.id)
    }

    /// 回顾的门牌：左边 ‹ 回去，中间一枚胶囊写着那天的日子
    private var momentHeader: some View {
        ZStack {
            Text(momentTitle)
                .font(Typo.sans(skin.size(Typo.Size.body), .semibold))
                .foregroundStyle(skin.ink)
                .padding(.horizontal, 18)
                .padding(.vertical, 11)
                .background(paintedChrome(Capsule(), skin: skin))
            HStack {
                Button { dismissMoment() } label: { circleIcon("chevron.left") }
                    .buttonStyle(.plain)
                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    private var momentTitle: String {
        guard let anchor = momentAnchor,
              let date = chat.items.first(where: { $0.messageID == anchor })?.at ?? chat.items.first?.at else { return "回到那天" }
        let sameYear = Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year)
        return sameYear ? date.formatted(.dateTime.month().day().weekday()) : date.formatted(.dateTime.year().month().day())
    }

    // MARK: - 列表

    /// 一次算好、递给每一行用的东西（按行现取就是 O(n²)，之前自用的 App 08-15 踩过）
    private struct RowContext {
        var byID: [Int: ChatItem]
        var stamps: Set<Int>
        var avatars: Set<Int>
        var dayLabels: [Int: String]
    }

    /// 消息列表：UIKit 的 UICollectionView，行是 SwiftUI 气泡。
    /// 这里只负责算"有哪些行、每行的指纹"，滚动和键盘全在 ChatListView.swift。
    private var messagesList: some View {
        let list = visibleItems
        var dayLabels: [Int: String] = [:]
        for index in list.indices {
            if let label = dayDividerLabel(list, at: index) { dayLabels[list[index].id] = label }
        }
        let ctx = RowContext(byID: Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) }),
                             stamps: timestampIDs(list),
                             avatars: bubbleLayout == .side ? sideAvatarIDs(list) : avatarIDs(list),
                             dayLabels: dayLabels)

        var rows: [ChatRow] = []
        var keys: [ChatRow: Int] = [:]
        if !list.isEmpty {
            rows.append(.older)
            var h = Hasher()
            h.combine(chat.reachedHistoryStart); h.combine(chat.loadingOlder)
            keys[.older] = h.finalize()
        }
        for item in list {
            if let label = ctx.dayLabels[item.id] {
                rows.append(.day(item.id))
                keys[.day(item.id)] = label.hashValue
            }
            // 头像是一整串的抬头，单独占一行
            if bubbleLayout == .header, ctx.avatars.contains(item.id) {
                rows.append(.avatar(item.id))
                keys[.avatar(item.id)] = item.mine ? 1 : (item.speaker?.hashValue ?? 0)
            }
            rows.append(.message(item.id))
            keys[.message(item.id)] = rowKey(item, ctx: ctx)
        }
        if isMoment {
            if chat.loaded && !chat.reachedEnd {
                rows.append(.newer)
                keys[.newer] = chat.loadingNewer ? 1 : 0
            }
        } else if chat.typing || Self.fakeTyping {
            rows.append(.typing)
            keys[.typing] = 0
        }

        // 影响所有行的东西：变了全部重配、重量
        var global = Hasher()
        global.combine(selecting)
        global.combine(showTimestamps)
        global.combine(appearanceRaw)
        global.combine(fontScaleRaw)
        global.combine(companionName)
        global.combine(theme.accent)
        global.combine(skin.bubble)
        global.combine(thoughtStyle)

        let lastIsMine = (rows.last?.messageID).flatMap { ctx.byID[$0] }?.mine == true
        let model = ChatListModel(rows: rows, rowKeys: keys, globalKey: global.finalize(),
                                  animateGlobalChange: false, headerBottom: headerBottom,
                                  lastIsMine: lastIsMine,
                                  rowSpacing: CGFloat(skin.bubble?.rowSpacing ?? 10))
        return ChatListView(model: model, handle: listHandle,
                            rowContent: { row in rowView(row, ctx: ctx) },
                            bar: bottomBar)
    }

    private func rowKey(_ item: ChatItem, ctx: RowContext) -> Int {
        var h = Hasher()
        h.combine(item)
        h.combine(ctx.stamps.contains(item.id))
        h.combine(ctx.avatars.contains(item.id))
        h.combine(expandedThoughts.contains(item.id))
        h.combine(flippedVoices.contains(item.id) != innerVoiceOpen)
        h.combine(highlightID == item.id)
        h.combine(selectedIDs.contains(item.id))
        return h.finalize()
    }

    /// 一行长什么样。⚠️ cell 里的 SwiftUI 是另起的一棵树，环境对象要在这里重新挂一遍。
    private func rowView(_ row: ChatRow, ctx: RowContext) -> AnyView {
        AnyView(
            rowBody(row, ctx: ctx)
                .environmentObject(theme)
                .environmentObject(chat)
                .environmentObject(avatars)
        )
    }

    @ViewBuilder
    private func rowBody(_ row: ChatRow, ctx: RowContext) -> some View {
        switch row {
        case .older:
            olderRow
        case .day(let id):
            Text(ctx.dayLabels[id] ?? "")
                .font(Typo.sans(skin.size(Typo.Size.caption)))
                .foregroundStyle(skin.inkFaint)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
        case .avatar(let id):
            avatarHeader(mine: ctx.byID[id]?.mine == true, speaker: ctx.byID[id]?.speaker)
        case .typing:
            typingBubble
        case .newer:
            Button { Task { await chat.loadNewer() } } label: {
                if chat.loadingNewer {
                    ProgressView().controlSize(.small)
                } else {
                    Text("↓ 再往后看看")
                        .font(Typo.sans(skin.size(Typo.Size.callout)))
                        .foregroundStyle(skin.inkFaint)
                }
            }
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .disabled(chat.loadingNewer)
        case .message(let id):
            if let item = ctx.byID[id] {
                messageRow(item, ctx: ctx)
            }
        }
    }

    @ViewBuilder
    private var olderRow: some View {
        if chat.reachedHistoryStart {
            Text("这里就是我们最开始的地方了 🌱")
                .font(Typo.sans(skin.size(Typo.Size.caption)))
                .foregroundStyle(skin.inkFaint)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
        } else {
            Button {
                // 前插之后把原来的第一条钉回视野顶上（ChatListController 接手）
                listHandle.pendingTopAnchor = visibleItems.first?.id
                Task { await chat.loadOlder() }
            } label: {
                if chat.loadingOlder {
                    ProgressView().controlSize(.small)
                } else {
                    Text("↑ 加载更早的聊天")
                        .font(Typo.sans(skin.size(Typo.Size.callout)))
                        .foregroundStyle(skin.inkFaint)
                }
            }
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .disabled(chat.loadingOlder)
        }
    }

    /// 统一行结构：多选时左侧出现圈圈，气泡本体停止响应点击
    private func messageRow(_ item: ChatItem, ctx: RowContext) -> some View {
        let selectable = selecting && item.kind == .text
        return HStack(spacing: 8) {
            if selectable {
                Image(systemName: selectedIDs.contains(item.id) ? "checkmark.circle.fill" : "circle")
                    .font(Typo.icon(20))
                    .foregroundStyle(selectedIDs.contains(item.id) ? theme.accent : skin.inkFaint)
            }
            if case .song(let song) = item.kind {
                // 移植自之前自用的 App musicBubble：玻璃卡在上；它那句话是紧跟着的独立气泡（ChatStore 拆的，能引用）
                SongCardView(song: song)
                Spacer(minLength: 0)
            } else if case .sticker(let sid) = item.kind {
                // 它发的表情包（10-01）：不要气泡底，就一张图
                AuthImageView(urlPath: "stickers/\(sid)/image", contentMode: .fit)
                    .frame(width: 128, height: 128)
                    .padding(.leading, 6)
                Spacer(minLength: 0)
            } else if case .deeds(let deeds) = item.kind {
                DeedsRow(deeds: deeds, at: item.at, skin: skin)
                Spacer(minLength: 0)
            } else if case .card("callEnd") = item.kind {
                // 电话（10-31）：照微信只留一行；点开看这通说了什么
                Button { callLog = CallLogTarget(id: item.messageID ?? 0, title: item.text) } label: {
                    HStack(spacing: 4) {
                        Text(item.text)
                        Image(systemName: "chevron.right").font(Typo.icon(9, .semibold))
                    }
                    .font(Typo.sans(skin.size(Typo.Size.caption))).foregroundStyle(skin.inkFaint)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Capsule().fill(skin.inkFaint.opacity(0.1)))
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity).padding(.vertical, 8)
            } else if case .card("callRing") = item.kind {
                // TA 打来没接通（10-31 第 4 步）：照微信一行灰字，点了回拨
                Button {
                    #if LITE
                    calling = true
                    #endif
                } label: {
                    HStack(spacing: 4) {
                        Text(item.text)
                        Image(systemName: "phone.arrow.up.right").font(Typo.icon(10, .semibold))
                    }
                    .font(Typo.sans(skin.size(Typo.Size.caption))).foregroundStyle(skin.inkFaint)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Capsule().fill(skin.inkFaint.opacity(0.1)))
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity).padding(.vertical, 8)
            } else if case .card("divider") = item.kind {
                Text(item.text).font(Typo.sans(skin.size(Typo.Size.caption))).foregroundStyle(skin.inkFaint)
                    .multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(.vertical, 10)
            } else if case .card(let raw) = item.kind, raw.hasPrefix("peek") {
                PeekNoticeRow(kind: raw, companionName: companionName, skin: skin)
            } else if case .card(let kind) = item.kind {
                // 动作卡片：左右离屏幕一样远（不走气泡那套远侧 26pt）；有正文的点开是整张
                let chip = ActionCardChip(kind: kind, text: item.text, at: item.at, skin: skin)
                if kind == "focus" {
                    // 专注提议：弹窗问过了，聊天里只留一行灰字；点一下还能打开专注页
                    Button { NotificationCenter.default.post(name: .lumiOpenFocus, object: nil, userInfo: FocusPrefill.parse(item.text)) } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "timer").font(Typo.icon(10))
                            Text("\(companionName)想陪你专注 · \(item.text)").font(Typo.sans(skin.size(Typo.Size.caption)))
                        }
                        .foregroundStyle(skin.inkFaint).frame(maxWidth: .infinity).padding(.vertical, 4)
                    }
                    .buttonStyle(.plain).disabled(selectable)
                } else if !chip.parts.body.isEmpty && !selectable {
                    Button {
                        withAnimation(.easeOut(duration: 0.22)) {
                            openedCard = OpenedCard(title: chip.parts.title, body: chip.parts.body, at: item.at)
                        }
                    } label: { chip }
                    .buttonStyle(.plain)
                } else {
                    chip
                }
            } else {
                bubble(item, showTime: ctx.stamps.contains(item.id), showAvatar: ctx.avatars.contains(item.id))
                    .allowsHitTesting(!selecting)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard selectable else { return }
            if selectedIDs.contains(item.id) { selectedIDs.remove(item.id) } else { selectedIDs.insert(item.id) }
        }
    }

    // MARK: - 时间戳、换天、头像

    /// 换天才插的分隔条。同一天里不插——每条消息自己带时间戳。
    private func dayDividerLabel(_ list: [ChatItem], at index: Int) -> String? {
        guard index < list.count else { return nil }
        let current = list[index].at
        let calendar = Calendar.current
        if index > 0, calendar.isDate(current, inSameDayAs: list[index - 1].at) { return nil }
        if calendar.isDateInToday(current) { return "今天" }
        if calendar.isDateInYesterday(current) { return "昨天" }
        return current.formatted(.dateTime.month().day())
    }

    /// 哪些行该带时间戳：每分钟只留一个，留那一分钟里的最后一条（思考链和卡片自己不带）
    private func timestampIDs(_ list: [ChatItem]) -> Set<Int> {
        guard showTimestamps else { return [] }
        let stampable = list.filter { $0.kind == .text }
        var out: Set<Int> = []
        for (index, item) in stampable.enumerated() {
            guard index + 1 < stampable.count else {
                out.insert(item.id)   // 最后一条永远带
                continue
            }
            let next = stampable[index + 1]
            if next.mine != item.mine || !Calendar.current.isDate(item.at, equalTo: next.at, toGranularity: .minute) {
                out.insert(item.id)
            }
        }
        return out
    }

    /// 「头像在上面」：一串里只有第一行（思考链算在这一串里，而且经常就是第一行——它先想，再说）
    private func avatarIDs(_ list: [ChatItem]) -> Set<Int> {
        var out: Set<Int> = []
        var speaker: String?
        for item in list {
            if Self.isLine(item) { speaker = nil; continue }      // 灰色分隔行（搬来的段落头、通话时长）不算谁说的，也不挂头像
            guard Self.runKey(item) != speaker else { continue }
            out.insert(item.id)
            speaker = Self.runKey(item)
        }
        return out
    }

    private static func isLine(_ item: ChatItem) -> Bool {
        if case .card(let k) = item.kind { return k == "divider" || k == "callEnd" || k == "callRing" }
        return false
    }

    /// 一串 = 同一个人连着说的（群里不同 TA 断开，10-11）
    private static func runKey(_ item: ChatItem) -> String { item.mine ? "me" : (item.speaker?.uuidString ?? "ai") }

    /// 「头像在旁边」：每一串里第一条走气泡的（卡片不走气泡、也不缩进，头像落在它身上没地方挂）
    private func sideAvatarIDs(_ list: [ChatItem]) -> Set<Int> {
        var out: Set<Int> = []
        var speaker: String?
        var pending = false
        for item in list {
            if Self.isLine(item) { speaker = nil; continue }
            if Self.runKey(item) != speaker {
                speaker = Self.runKey(item)
                pending = true
            }
            if pending, !Self.isCard(item) {
                out.insert(item.id)
                pending = false
            }
        }
        return out
    }

    private static func isCard(_ item: ChatItem) -> Bool {
        switch item.kind {
        case .card, .song, .sticker: return true
        default: return false
        }
    }

    private static func messageTime(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    // MARK: - 气泡

    /// 远侧补多少：列表页边 20，想伸到 reach 就补 reach - 20
    private var farPad: CGFloat {
        CGFloat((skin.bubble?.farReach(side: bubbleLayout == .side) ?? 26) - 20)
    }

    @ViewBuilder
    private func bubble(_ item: ChatItem, showTime: Bool, showAvatar: Bool) -> some View {
        let mine = item.mine
        HStack(alignment: .top, spacing: 8) {
            if mine { Spacer(minLength: 0) }
            if !mine, bubbleLayout == .side {
                sideAvatar(show: showAvatar, mine: false, overhang: item.kind == .thinking, speaker: item.speaker)
            }
            VStack(alignment: mine ? .trailing : .leading, spacing: 2) {
                if group != nil, !mine, showAvatar, bubbleLayout == .side {
                    speakerName(item.speaker).padding(.leading, 4)
                }
                if item.kind == .thinking {
                    thoughtBlock(item)
                } else if item.kind == .innerVoice {
                    innerVoiceBlock(item)
                } else {
                    if !item.attachments.isEmpty { attachmentsView(item) }
                    if !item.text.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        if let v = item.voice ?? item.attachments.first(where: { $0.kind == "voice" }).map({
                            VoiceRef(id: $0.id.uuidString.lowercased(), durationMs: ($0.seconds ?? 0) * 1000,
                                     path: "attachments/\($0.id.uuidString.lowercased())") }) {
                            VoiceNoteContent(voice: v, transcript: item.text, ink: skin.bubbleInk(mine: mine),
                                             accent: theme.accent, fontSize: skin.size(Typo.Size.headline),
                                             messageID: item.messageID, bubble: item.bubble)
                            if !mine, let t = item.translation, !t.isEmpty {
                                Text(t).font(Typo.sans(skin.size(Typo.Size.callout))).foregroundStyle(skin.bubbleInk(mine: mine).opacity(0.72))
                            }
                        } else {
                        if let parsed = item.quoteParsed {
                            HStack(spacing: 6) {
                                RoundedRectangle(cornerRadius: 1.5)
                                    .fill(theme.accent)
                                    .frame(width: 3)
                                Text(parsed.quote)
                                    .font(Typo.sans(skin.size(Typo.Size.callout)))
                                    .foregroundStyle(skin.bubbleInk(mine: mine).opacity(0.62))
                                    .lineLimit(2)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background {
                                RoundedRectangle(cornerRadius: Radii.chip, style: .continuous)
                                    .fill(skin.isDark ? Color.white.opacity(0.07) : Color.white.opacity(0.3))
                            }
                            .fixedSize(horizontal: false, vertical: true)
                        }
                        // 双语气泡（10-15）：你的泡上面是翻成 TA 那种语言的、下面是你的原话；TA 的泡原文在上、译文在下
                        if mine, let t = item.translation, !t.isEmpty {
                            Text(t).font(Typo.sans(skin.size(Typo.Size.headline))).foregroundStyle(skin.bubbleInk(mine: mine))
                        }
                        Text(mentionLit(RichText.render(item.quoteParsed?.body ?? item.text, size: skin.size(Typo.Size.headline),
                                                        ink: skin.bubbleInk(mine: mine))))
                            .font(Typo.sans(skin.size(Typo.Size.headline)))
                            .foregroundStyle(skin.bubbleInk(mine: mine).opacity(mine && !(item.translation ?? "").isEmpty ? 0.72 : 1))
                        if !mine, let t = item.translation, !t.isEmpty {
                            Text(t).font(Typo.sans(skin.size(Typo.Size.headline))).foregroundStyle(skin.bubbleInk(mine: mine).opacity(0.72))
                        }
                        }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(ChatBubbleBackground(skin: skin, mine: mine, tinted: mine))
                    .onLongPressGesture(minimumDuration: 0.35) { openActions(item) }
                    }
                }
                // 标记表情：贴在气泡底边往上叠一点，像 Instagram。只用 offset 叠——负边距会把量出来的行高算小
                if let emoji = item.reaction {
                    Button {
                        // 再点自己点的那个 = 取消
                        if let mid = item.messageID, let b = item.bubble { Task { await chat.react(messageID: mid, bubble: b, emoji: emoji) } }
                    } label: {
                    Text(emoji)
                        .font(Typo.icon(13))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Capsule().fill(skin.bubbleTheirs))
                        .overlay(Capsule().stroke(skin.inkDim.opacity(0.25), lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                        .padding(.horizontal, 10)
                        .offset(y: -9)
                        .padding(.bottom, 2)
                }
                if item.kind != .thinking, item.kind != .innerVoice, showTime {
                    Text(Self.messageTime(item.at))
                        .font(Typo.sans(skin.size(Typo.Size.caption)).monospacedDigit())
                        .foregroundStyle(skin.timestamp)
                        .padding(.horizontal, 4)
                }
            }
            if mine, bubbleLayout == .side {
                sideAvatar(show: showAvatar, mine: true, overhang: false)
            }
            if !mine { Spacer(minLength: 0) }
        }
        .padding(.leading, mine ? farPad : (bubbleLayout == .side ? -6 : 0))
        .padding(.trailing, mine ? (bubbleLayout == .side ? -6 : 0) : farPad)
        .background {
            if highlightID == item.id {
                RoundedRectangle(cornerRadius: Radii.card, style: .continuous)
                    .fill(theme.accent.opacity(0.22))
                    .padding(-5)
            }
        }
    }

    // MARK: - 照片、文件的气泡

    @ViewBuilder
    private func attachmentsView(_ item: ChatItem) -> some View {
        let images = item.attachments.filter { $0.kind == "image" }
        let files = item.attachments.filter { $0.kind != "image" && $0.kind != "voice" }   // 语音画在气泡里
        let paths = images.map { "attachments/\($0.id.uuidString.lowercased())" }
        VStack(alignment: item.mine ? .trailing : .leading, spacing: 4) {
            if images.count == 1 {
                // 一张：固定方块（服务器不给宽高，量高那份和屏上那份一样高，不会压到下一行）；点开看完整的
                AuthImageView(urlPath: paths[0])
                    .frame(width: 200, height: 200)
                    .clipShape(RoundedRectangle(cornerRadius: Radii.control, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Radii.control, style: .continuous)
                        .stroke(Color.white.opacity(skin.isDark ? 0.08 : 0.4), lineWidth: 1))
                    .onTapGesture { imageViewer = ImageViewerState(urls: paths, index: 0) }
            } else if images.count > 1 {
                imageGrid(paths)
            }
            ForEach(files) { file in fileChip(file, mine: item.mine) }
        }
    }

    /// 多图网格：2 张或 4 张两列，其余三列；网格只占几张图那么宽（之前自用的 App 09-06：两张照片占了三个空）
    private func imageGrid(_ paths: [String]) -> some View {
        let columnCount = (paths.count == 2 || paths.count == 4) ? 2 : 3
        let side: CGFloat = columnCount == 2 ? 108 : 76
        let columns = Array(repeating: GridItem(.fixed(side), spacing: 4), count: columnCount)
        let shown = min(paths.count, columnCount)
        let gridWidth = CGFloat(shown) * side + CGFloat(max(0, shown - 1)) * 4
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 4) {
            ForEach(Array(paths.enumerated()), id: \.offset) { index, path in
                AuthImageView(urlPath: path)
                    .frame(width: side, height: side)
                    .clipShape(RoundedRectangle(cornerRadius: Radii.bubble, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: Radii.bubble, style: .continuous))
                    .onTapGesture { imageViewer = ImageViewerState(urls: paths, index: index) }
            }
        }
        .frame(width: gridWidth)
        .padding(4)
        .background(paintedChrome(RoundedRectangle(cornerRadius: Radii.control, style: .continuous), skin: skin))
    }

    private func fileChip(_ file: AttachmentDTO, mine: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: file.mime == "application/pdf" ? "doc.richtext.fill" : "doc.text.fill")
                .font(Typo.icon(22))
                .foregroundStyle(theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name.isEmpty ? "文件" : file.name)
                    .font(Typo.sans(skin.size(Typo.Size.body)))
                    .foregroundStyle(skin.bubbleInk(mine: mine))
                    .lineLimit(1)
                Text(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file))
                    .font(Typo.sans(skin.size(Typo.Size.caption)))
                    .foregroundStyle(skin.bubbleInk(mine: mine).opacity(0.6))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .frame(maxWidth: 240, alignment: .leading)
        .background(ChatBubbleBackground(skin: skin, mine: mine, tinted: mine))
    }

    /// 思考链：贴着头像那一行是「⌄ ✦ 思考过程」，点开在下面铺一整块半透明面板，正文一段都不切。
    private func thoughtBlock(_ item: ChatItem) -> some View {
        let pending = item.text.isEmpty          // 这一轮开头占好的那一行，思考还没到
        let open = expandedThoughts.contains(item.id) && !pending
        return VStack(alignment: .leading, spacing: 7) {
            Button {
                // 不包 withAnimation（10-01 Aporia：开关思考链卡）：高度变了列表自己重量、自己动，
                // SwiftUI 再在 cell 里播一遍展开动画，两边一起动就会顿一下
                if open { expandedThoughts.remove(item.id) } else { expandedThoughts.insert(item.id) }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.down")
                        .font(Typo.icon(skin.size(9), .semibold))
                        .rotationEffect(.degrees(open ? 0 : -90))
                    Image(systemName: "sparkle")
                        .font(Typo.icon(skin.size(10.5)))
                    Text(pending ? "正在想…" : Self.thoughtTitle(item.thinkingMs))
                        .font(Typo.sans(skin.size(Typo.Size.callout)))
                        .lineLimit(1)
                }
                .foregroundStyle(thoughtStyle.inkColor(fallback: skin.inkDim))
                .padding(.vertical, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(pending)

            if open {
                let zh = item.messageID.flatMap { showZh.contains($0) ? thoughtZh[$0] : nil }
                VStack(alignment: .leading, spacing: 8) {
                    Text((zh ?? item.text).trimmingCharacters(in: .whitespacesAndNewlines))
                        .font(Typo.sans(skin.size(Typo.Size.body)))
                        .foregroundStyle(thoughtStyle.inkColor(fallback: skin.inkDim))
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if !Lite.local, let mid = item.messageID, Self.mostlyForeign(item.text) {
                        // 10-01 Aporia：Claude 用英文想（中文想得太短太干），这里给个翻译
                        Button {
                            if showZh.contains(mid) { showZh.remove(mid) } else { Task { await translateThought(mid) } }
                        } label: {
                            Label(translating == mid ? "翻译中…" : (showZh.contains(mid) ? "看原文" : "翻译"),
                                  systemImage: "character.bubble")
                                .font(Typo.sans(skin.size(Typo.Size.caption)))
                                .foregroundStyle(theme.accentDeep)
                        }
                        .buttonStyle(.plain)
                        .disabled(translating == mid)
                    }
                }
                .padding(.horizontal, 15).padding(.vertical, 13)
                .background(ThoughtPanelBackground(skin: skin, style: thoughtStyle))
            }
        }
    }

    /// 回复后的心声（10-11）：这一轮最后一张小卡片。标题行「♡ 心声」点一下开 / 收；默认看「拓展显示」里的开关。
    /// 跟思考同一套字号和玻璃，整体淡一点，不抢气泡。
    private func innerVoiceBlock(_ item: ChatItem) -> some View {
        let open = flippedVoices.contains(item.id) != innerVoiceOpen
        return VStack(alignment: .leading, spacing: 7) {
            Button {
                if flippedVoices.contains(item.id) { flippedVoices.remove(item.id) } else { flippedVoices.insert(item.id) }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.down")
                        .font(Typo.icon(skin.size(9), .semibold))
                        .rotationEffect(.degrees(open ? 0 : -90))
                    Image(systemName: "heart")
                        .font(Typo.icon(skin.size(10.5)))
                    Text("心声")
                        .font(Typo.sans(skin.size(Typo.Size.callout)))
                        .lineLimit(1)
                }
                .foregroundStyle(thoughtStyle.inkColor(fallback: skin.inkDim))
                .padding(.vertical, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if open {
                Text(item.text)
                    .font(Typo.sans(skin.size(Typo.Size.body)))
                    .foregroundStyle(thoughtStyle.inkColor(fallback: skin.inkDim))
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 15).padding(.vertical, 13)
                    .background(ThoughtPanelBackground(skin: skin, style: thoughtStyle).opacity(0.85))
            }
        }
    }

    /// 「思考了 x 秒」（10-05 Aporia）：从开口到说完；早先没记时长的消息还叫「思考过程」
    private static func thoughtTitle(_ ms: Int?) -> String {
        guard let ms else { return String(localized: "思考过程") }
        let s = max(1, Int((Double(ms) / 1000).rounded()))
        return s < 60 ? String(localized: "思考了 \(s) 秒") : String(localized: "思考了 \(s / 60) 分 \(s % 60) 秒")
    }

    /// 思考链大半不是中文（Claude 用英文想的那种）才给翻译按钮
    private static func mostlyForeign(_ s: String) -> Bool {
        let letters = s.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard letters.count > 20 else { return false }
        let cjk = letters.filter { (0x4E00...0x9FFF).contains($0.value) }.count
        return Double(cjk) / Double(letters.count) < 0.3
    }

    private func translateThought(_ mid: Int) async {
        if thoughtZh[mid] == nil {
            struct Out: Decodable { let text: String }
            translating = mid
            defer { translating = nil }
            guard let out: Out = try? await session.api.call("POST", "messages/\(mid)/thinking/translate") else { return }
            thoughtZh[mid] = out.text
        }
        showZh.insert(mid)
    }

    /// 「头像在旁边」那一列：整串都留 30pt，只有第一条真的放头像。
    /// overhang：挂在思考链那一行时头像不撑高这一行，往下探出去落在第一条气泡旁边
    /// 群里 TA 的头像（按 speaker）；其余照旧
    /// 点 TA 的头像进 TA 的朋友圈（11-03 Aporia，照微信）；群里点谁进谁的。自己的头像不管
    @ViewBuilder
    private func avatar(mine: Bool, speaker: UUID?, size: CGFloat) -> some View {
        Group {
            if group != nil, !mine {
                MemberAvatar(look: speaker.flatMap { memberLook[$0] }, size: size)
            } else {
                AvatarView(who: mine ? .me : .ai, size: size)
            }
        }
        .contentShape(Circle())
        .onTapGesture {
            guard !mine else { return }
            visitingMoments = MomentsVisit(who: (group != nil ? speaker ?? companionID : companionID).uuidString.lowercased())
        }
    }

    struct MomentsVisit: Identifiable { let who: String; var id: String { who } }

    /// 群里一串开头的名字小字
    private func speakerName(_ speaker: UUID?) -> some View {
        Text(speaker.flatMap { memberLook[$0]?.name } ?? "TA")
            .font(Typo.sans(skin.size(Typo.Size.caption)))
            .foregroundStyle(skin.inkDim)
    }

    /// 群里气泡中的 @名字 用主题色加粗
    private func mentionLit(_ s: AttributedString) -> AttributedString {
        guard group != nil else { return s }
        var out = s
        for name in memberLook.values.map(\.name) where !name.isEmpty {
            var from = out.startIndex
            while from < out.endIndex, let r = out[from...].range(of: "@" + name) {
                out[r].foregroundColor = theme.accent
                out[r].font = Typo.sans(skin.size(Typo.Size.headline), .semibold)
                from = r.upperBound
            }
        }
        return out
    }

    private func sideAvatar(show: Bool, mine: Bool, overhang: Bool, speaker: UUID? = nil) -> some View {
        Group {
            if show, overhang {
                Color.clear.frame(width: 30, height: 20)
                    .overlay(alignment: .top) {
                        avatar(mine: mine, speaker: speaker, size: 30).offset(y: -5)
                    }
            } else if show {
                avatar(mine: mine, speaker: speaker, size: 30)
                    .frame(width: 30, height: 30)
            } else {
                // 空位只占宽不占高：不然这一行被撑成头像那么高
                Color.clear.frame(width: 30, height: 0)
            }
        }
    }

    private func avatarHeader(mine: Bool, speaker: UUID? = nil) -> some View {
        HStack(spacing: 6) {
            if mine { Spacer(minLength: 0) }
            avatar(mine: mine, speaker: speaker, size: 32)
            if group != nil, !mine { speakerName(speaker) }
            if !mine { Spacer(minLength: 0) }
        }
        .padding(.top, 4)
        .padding(.bottom, -2)
    }

    // MARK: - 打字中、输入行

    /// 启动参数 -fakeTyping：不等它真的在打字也把三个点摆出来，好截图检查
    static let fakeTyping = ProcessInfo.processInfo.arguments.contains("-fakeTyping")

    private var typingBubble: some View {
        HStack(alignment: .bottom, spacing: 8) {
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { i in
                    BobbingDot(color: skin.inkDim, size: 6, delay: Double(i) * 0.2)
                        .frame(width: 6, height: 6)
                        .opacity(0.5)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(ChatBubbleBackground(skin: skin, mine: false, tinted: false))
            Spacer(minLength: 16)
        }
    }

    private var inputBar: some View {
        HStack(spacing: 10) {
            if selecting {
                Button("取消") {
                    selecting = false
                    selectedIDs = []
                }
                .font(Typo.sans(Typo.Size.body))
                .foregroundStyle(skin.inkDim)
                Spacer()
                Button {
                    let picked = visibleItems.filter { selectedIDs.contains($0.id) }
                    UIPasteboard.general.string = picked.map { item in
                        "\(item.mine ? "我" : companionName)：\(item.quoteParsed?.body ?? item.text)"
                    }.joined(separator: "\n")
                    selecting = false
                    selectedIDs = []
                } label: {
                    Text("复制 \(selectedIDs.count) 条")
                        .font(Typo.sans(Typo.Size.body, .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18).padding(.vertical, 10)
                        .background(Capsule().fill(theme.accent))
                }
                .disabled(selectedIDs.isEmpty)
                .opacity(selectedIDs.isEmpty ? 0.5 : 1)
                if !incognito {
                    Button {
                        let picked = visibleItems.filter { selectedIDs.contains($0.id) && $0.kind == .text && $0.messageID != nil }
                        Task { await favorites.addGroup(picked, api: session.api) }
                        selecting = false
                        selectedIDs = []
                    } label: {
                        Text("收藏 \(selectedIDs.count) 条为一组 ♡")
                            .font(Typo.sans(Typo.Size.body, .semibold))
                            .foregroundStyle(theme.accentDeep)
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .background(Capsule().fill(Color.white.opacity(0.7)))
                    }
                    .disabled(selectedIDs.isEmpty)
                    .opacity(selectedIDs.isEmpty ? 0.5 : 1)
                }
            } else if chat.uploading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("附件发送中…")
                        .font(Typo.sans(Typo.Size.body)).foregroundStyle(skin.inkDim)
                    Spacer()
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                .background(paintedChrome(Capsule(), skin: skin, light: .fromBottom))
            } else {
                Menu {
                    if CameraPicker.isAvailable {
                        Button { cameraPresented = true } label: { Label("拍照片", systemImage: "camera") }
                    }
                    Button { photoPickerPresented = true } label: { Label("照片", systemImage: "photo") }
                    Button { filePickerPresented = true } label: { Label("文件", systemImage: "doc") }
                    Button { stickerPanel = true } label: { Label("表情包", systemImage: "face.smiling") }
                    #if LITE
                    if Lite.on && group == nil && !isMoment {
                        Button { calling = true } label: { Label("语音通话", systemImage: "phone") }   // 微信放在 + 里（10-31）
                    }
                    #endif
                } label: {
                    Image(systemName: "plus")
                        .font(Typo.icon(18, .semibold))
                        .foregroundStyle(theme.accent)
                        .frame(width: 36, height: 36)
                        .background(paintedChrome(Circle(), skin: skin))
                        .coachMark("plus")
                }
                // 草稿住在 DraftField 自己家里：她打的每一个字都会重画拥有它的那个视图。
                // 输入框换行了要吱一声：底栏的高度是 UIKit 那边按实际宽度量的，自己感知不到 SwiftUI 里的换行
                DraftField(draftKey: draftKey, placeholder: "对\(companionName)说点什么…", skin: skin,
                           mentionNames: group == nil ? [] : (group?.members ?? []).compactMap { memberLook[$0]?.name },
                           onHeightChange: { _ in listHandle.barContentChanged() },
                           onVoice: isMoment ? nil : { data, secs in Task { await chat.sendVoice(data, seconds: secs) } }) { typed in
                    var text = typed
                    if let quoted = quoting {
                        text = "「回复：\(quoteSnippet(quoted))」\n" + text
                        quoting = nil
                    }
                    #if LITE
                    // 第一次发给这家模型：先说清楚发到哪、请 TA 点同意（苹果 5.1.2）
                    if let ask = LiteConsent.ask(companion: companionID, text: text) { consentAsk = ask; return }
                    #endif
                    chat.send(text)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        // 整条底栏的底边由 ChatListController 钉在安全区上沿 / 键盘顶上，键盘弹起时它跟列表同一个动画块抬
        .padding(.bottom, 8)
    }

    // MARK: - 长按浮层

    private func openActions(_ item: ChatItem) {
        guard !item.isPending, item.kind == .text else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        // 键盘挡着菜单：先收，记着关了浮层再升回来
        refocusAfterActions = keyboardUp
        if keyboardUp {
            NotificationCenter.default.post(name: ChatView.selfTestFocus, object: false)
        }
        actionPopped = false
        actionItem = item
        // 底子先淡入，内容跟着系统菜单那种 spring 弹出来
        DispatchQueue.main.async {
            withAnimation(.spring(response: 0.36, dampingFraction: 0.72)) { actionPopped = true }
        }
    }

    private func closeActions(refocus: Bool = true) {
        actionPopped = false
        actionItem = nil
        if refocusAfterActions {
            refocusAfterActions = false
            guard refocus else { return }
            // 等浮层淡出一拍再升键盘，不然两段动画打架
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                NotificationCenter.default.post(name: ChatView.selfTestFocus, object: true)
            }
        }
    }

    /// 整页压一层雾，表情条浮在最上面（只有它的话能点），中间是那条消息，下面一张菜单卡。
    /// 卡和条都用 paintedChrome——跟输入框、头顶胶囊同一块玻璃。浅色下是发白的雾，深色下是压暗。
    private func actionOverlay(_ item: ChatItem) -> some View {
        let mine = item.mine
        let cardShape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        return ZStack {
            Group {
                LegacyBlur(style: skin.isDark ? .dark : .light)
                (skin.isDark ? Color.black.opacity(0.42) : Color.white.opacity(0.55))
            }
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture { closeActions() }

            VStack(alignment: mine ? .trailing : .leading, spacing: 10) {
                if !mine, !isMoment, let mid = item.messageID, item.bubble != nil {
                    HStack(spacing: 4) {
                        ForEach(ReactionChoices.current, id: \.self) { emoji in
                            Button {
                                EmojiCatalog.noteRecent(emoji)
                                if let b = item.bubble { Task { await chat.react(messageID: mid, bubble: b, emoji: emoji) } }
                                closeActions()
                            } label: {
                                Text(emoji).font(Typo.icon(28)).frame(width: 40, height: 44)
                            }
                            .buttonStyle(.plain)
                        }
                        Button {
                            closeActions()
                            emojiPickFor = item
                        } label: {
                            Image(systemName: "plus")
                                .font(Typo.icon(20, .medium))
                                .foregroundStyle(skin.inkDim)
                                .frame(width: 40, height: 44)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 8)
                    .background(paintedChrome(Capsule(), skin: skin, light: .fromBottom))
                    .shadow(color: .black.opacity(skin.isDark ? 0.3 : 0.12), radius: 16, y: 8)
                }

                Text(RichText.render(item.quoteParsed?.body ?? item.text, size: skin.size(Typo.Size.headline),
                                     ink: skin.bubbleInk(mine: mine)))
                    .font(Typo.sans(skin.size(Typo.Size.headline)))
                    .foregroundStyle(skin.bubbleInk(mine: mine))
                    .lineLimit(8)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(ChatBubbleBackground(skin: skin, mine: mine, tinted: mine))
                    .frame(maxWidth: 300, alignment: mine ? .trailing : .leading)

                VStack(spacing: 0) {
                    messageMenu(item)
                }
                .buttonStyle(ActionRowStyle(ink: skin.ink, isDark: skin.isDark))
                .frame(width: 250)
                .background(paintedChrome(cardShape, skin: skin))
                .clipShape(cardShape)
                .shadow(color: .black.opacity(skin.isDark ? 0.3 : 0.12), radius: 16, y: 8)
            }
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
            // 弹出：从那条消息所在的一侧缩着长出来，跟系统菜单一个劲儿
            .scaleEffect(actionPopped ? 1 : 0.55, anchor: mine ? .topTrailing : .topLeading)
            .opacity(actionPopped ? 1 : 0)
        }
    }

    /// 菜单卡：复制、引用、多选；TA 的话能「编辑」（倒回到没发的时候），它的话能「重新回」
    @ViewBuilder
    private func messageMenu(_ item: ChatItem) -> some View {
        Button {
            closeActions()
            UIPasteboard.general.string = item.quoteParsed?.body ?? item.text
        } label: {
            Label("复制", systemImage: "doc.on.doc")
        }
        if item.messageID != nil && !incognito {
            let kept = favorites.contains(item.id)
            Button {
                closeActions()
                Task { await favorites.toggle(item, api: session.api) }
            } label: {
                Label(kept ? "取消收藏" : "收藏", systemImage: kept ? "heart.slash" : "heart")
            }
        }
        if let vid = item.voice?.id ?? item.attachments.first(where: { $0.kind == "voice" })?.id.uuidString.lowercased() {
            let open = VoiceTranscripts.shared.open.contains(vid)
            Button {
                closeActions()
                withAnimation(.easeOut(duration: 0.2)) { VoiceTranscripts.shared.toggle(vid) }
            } label: {
                Label(open ? "收起文字" : "转文字", systemImage: open ? "text.badge.minus" : "text.bubble")
            }
        }
        if !item.mine, item.kind == .text, item.voice == nil,
           !item.attachments.contains(where: { $0.kind == "voice" }), let mid = item.messageID {
            // 念给我听（10-03）：用它的嗓子念这一泡；念过的服务器存着，再点不花钱
            Button {
                closeActions()
                let index = item.id - ChatItem.rowID(message: mid, slot: ChatItem.bubbleSlot)
                Task { await speakAloud(message: mid, index: index) }
            } label: {
                Label("念给我听", systemImage: "speaker.wave.2")
            }
        }
        if let img = item.attachments.first(where: { $0.kind == "image" }) {
            Button {
                closeActions()
                Task { _ = try? await session.api.raw("POST", "stickers/from-attachment/\(img.id.uuidString.lowercased())") }
            } label: {
                Label("加到表情包", systemImage: "face.smiling")
            }
        }
        if !isMoment {
        Button {
            closeActions()
            quoting = item
        } label: {
            Label("引用", systemImage: "arrowshape.turn.up.left")
        }
        Button {
            closeActions(refocus: false)
            selectedIDs = [item.id]
            selecting = true
        } label: {
            Label("多选", systemImage: "checkmark.circle")
        }
        if let mid = item.messageID {
            Button(role: item.mine ? nil : .destructive) {
                closeActions(refocus: false)
                // 后面还有话的，倒回会连它们一起撤，先问一声
                if chat.hasMessages(after: mid) || chat.typing { confirmRewind = item } else { doRewind(item) }
            } label: {
                if item.mine {
                    Label("编辑", systemImage: "pencil")
                } else {
                    Label("重新回", systemImage: "arrow.clockwise")
                }
            }
            // 撤回（10-20，照之前自用的 App）：只撤这一句，TA 的回复留着；TA 看过了会知道你撤回了
            if item.mine {
                Button(role: .destructive) {
                    closeActions(refocus: false)
                    Task { await chat.recall(messageID: mid) }
                } label: {
                    Label("撤回", systemImage: "arrow.uturn.backward")
                }
            }
        }
        // 刚发出去、还在「等你说完」里的那句：TA 还没看到，撤回就是悄悄拿掉
        if item.mine, item.messageID == nil, chat.isRecallableEcho(item.id) {
            Button(role: .destructive) {
                closeActions(refocus: false)
                Task { await chat.recallEcho(item.id) }
            } label: {
                Label("撤回", systemImage: "arrow.uturn.backward")
            }
        }
        }   // !isMoment
    }

    /// 念给我听（10-03）：服务器念好（或拿念过的）→ 当场放
    private func speakAloud(message mid: Int, index: Int) async {
        do {
            let clip: VoiceRef = try await session.api.call("POST", "messages/\(mid)/speak", json: ["index": index])
            await VoicePlayer.shared.play(clip.id, api: session.api)
        } catch {
            chat.errorText = (error as? APIError)?.message ?? "没念出来"
        }
    }

    private func doRewind(_ item: ChatItem) {
        guard let mid = item.messageID else { return }
        Task {
            if let text = await chat.rewind(messageID: mid), item.mine {
                // 原文回到输入栏（草稿住在 DraftField 的 AppStorage 里，改 UserDefaults 它就跟着变）
                UserDefaults.standard.set(text, forKey: draftKey)
                NotificationCenter.default.post(name: ChatView.selfTestFocus, object: true)
            }
        }
    }

    // MARK: - 引用

    private func quoteSnippet(_ item: ChatItem) -> String {
        var snippet = (item.quoteParsed?.body ?? item.text).replacingOccurrences(of: "\n", with: " ")
        if snippet.count > 40 { snippet = String(snippet.prefix(40)) + "…" }
        return snippet
    }

    private func quotingBar(_ item: ChatItem) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(theme.accent)
                .frame(width: 3, height: 26)
            VStack(alignment: .leading, spacing: 0) {
                Text("引用 \(item.mine ? "自己" : companionName)")
                    .font(Typo.sans(skin.size(Typo.Size.caption), .semibold))
                    .foregroundStyle(theme.accent)
                Text(quoteSnippet(item))
                    .font(Typo.sans(skin.size(Typo.Size.callout)))
                    .foregroundStyle(skin.inkDim)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                quoting = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(Typo.icon(17))
                    .foregroundStyle(skin.inkFaint)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(paintedChrome(RoundedRectangle(cornerRadius: Radii.bubble, style: .continuous), skin: skin))
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }

    // MARK: - 自测（-chatSelfTest）
    //
    // 真机上我没有手指：这个脚本按顺序做一遍"键盘起落 → 来消息 → 翻历史 → 跳转 → 翻着历史时再起键盘"，
    // 每步把几何打到 NSLog（devicectl --console 能看）。假消息只活在本机，跑完自己撤掉，不发到服务器。

    static let selfTest = ProcessInfo.processInfo.arguments.contains("-chatSelfTest")
    static let selfTestFocus = Notification.Name("ChatSelfTest.focus")

    private func runSelfTest() async {
        func pause(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
        func focus(_ on: Bool) { NotificationCenter.default.post(name: Self.selfTestFocus, object: on) }
        await pause(3)
        NSLog("[selftest] ===== begin =====")
        listHandle.selfTestLogState(label: "idle")

        // 1. 键盘起落（贴着底）
        listHandle.selfTestSample(label: "kb-show", seconds: 1.2)
        focus(true)
        await pause(1.6)
        listHandle.selfTestLogState(label: "after-show")
        listHandle.selfTestSample(label: "kb-hide", seconds: 1.2)
        focus(false)
        await pause(1.6)
        listHandle.selfTestLogState(label: "after-hide")

        // 2. 来消息：先 typing，再正文原地换掉
        chat.typing = true
        listHandle.selfTestSample(label: "typing", seconds: 1.0)
        await pause(1.2)
        listHandle.selfTestLogState(label: "after-typing")
        listHandle.selfTestSample(label: "arrive", seconds: 1.0)
        chat.typing = false
        let fake = chat.selfTestAppend("（自测消息，一会儿自己消失）\n这一行是用来看来消息时列表是不是一个方向到底的。")
        await pause(1.4)
        listHandle.selfTestLogState(label: "after-arrive")

        // 3. 跳到中间一条居中
        let list = visibleItems
        if list.count > 10 {
            let target = list[list.count / 2].id
            listHandle.jump(to: target)
            await pause(1.2)
            listHandle.selfTestLogState(label: "after-jump", anchor: target)

            // 4. 翻着历史时起键盘：要滚到底（之前自用的 App 09-03 她要的）
            listHandle.selfTestSample(label: "kb-show-up", seconds: 1.0)
            focus(true)
            await pause(1.4)
            listHandle.selfTestLogState(label: "after-show-up")
            focus(false)
            await pause(1.2)
            listHandle.selfTestLogState(label: "after-hide-up")
        }

        // 5. 收拾
        chat.selfTestRemove(fake)
        await pause(0.8)
        listHandle.selfTestLogState(label: "cleanup")
        NSLog("[selftest] ===== done =====")
    }
}

struct MomentTarget: Identifiable { let id: Int }

/// 回顾的壳：自己一个只读的 ChatStore（从锚点前后开始，不连事件流）
struct MomentRoom: View {
    @StateObject private var chat: ChatStore
    let companionID: UUID
    let anchor: Int

    init(companionID: UUID, conversation: UUID, anchor: Int, api: APIClient) {
        self.companionID = companionID
        self.anchor = anchor
        _chat = StateObject(wrappedValue: ChatStore(api: api, conversation: conversation, anchor: anchor))
    }

    var body: some View {
        ChatView(companionID: companionID, momentAnchor: anchor)
            .environmentObject(chat)
    }
}

private struct AttachLayer: ViewModifier {
    let view: ChatView
    func body(content: Content) -> some View { view.attachLayer(content) }
}

private struct ActionLayer: ViewModifier {
    let view: ChatView
    func body(content: Content) -> some View { view.actionLayer(content) }
}

// MARK: - 做了几件事（10-03 Aporia：不挂动作卡片，照之前自用的 App「用了几个工具」那样折起来）
//
// 一件：直接写做了什么（「记了一条」）；两件以上：「做了 N 件事」。点开逐件列出，每件是标题 + 详细。

struct DeedsRow: View {
    let deeds: [ChatItem.Deed]
    let at: Date
    let skin: ChatSkin
    @State private var open = false

    private var title: String {
        deeds.count == 1 ? ActionCardChip.split(deeds[0].text).title : String(localized: "做了 \(deeds.count) 件事")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.smooth(duration: 0.25)) { open.toggle() }
            } label: {
                // 跟思考链那行一个排法（10-05 Aporia）：小箭头在最左、收着朝右点开朝下，再图标、再字
                HStack(spacing: 5) {
                    Image(systemName: "chevron.down")
                        .font(Typo.icon(skin.size(9), .semibold))
                        .rotationEffect(.degrees(open ? 0 : -90))
                    Image(systemName: deeds.count == 1 ? ActionCardChip.icon(deeds[0].kind) : "checklist")
                        .font(Typo.icon(skin.size(10.5)))
                    Text(title).font(Typo.sans(skin.size(Typo.Size.callout))).lineLimit(1)
                }
                .foregroundStyle(skin.inkDim)
                .padding(.vertical, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(deeds.enumerated()), id: \.offset) { _, d in
                        let parts = ActionCardChip.split(d.text)
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: ActionCardChip.icon(d.kind))
                                .font(Typo.icon(12)).foregroundStyle(skin.inkFaint)
                                .frame(width: 16).padding(.top, 2)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(parts.title).font(Typo.sans(skin.size(Typo.Size.caption), .semibold)).foregroundStyle(skin.ink)
                                if !parts.body.isEmpty {
                                    Text(parts.body)
                                        .font(Typo.sans(skin.size(Typo.Size.caption)))
                                        .foregroundStyle(skin.inkDim)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }
                }
                .padding(.leading, 4)
                .transition(.opacity)
            }
        }
        .padding(.leading, 14)
        .padding(.vertical, 2)
    }
}

// MARK: - 动作卡片（只剩「它提议专注」那张还用）

/// 它这一轮真干过的事（记了一条、翻了手册、定了提醒…），挂在正文气泡上面的一枚玻璃小卡。
/// 卡是服务器凭工具调用挂的，不是它嘴上说了算。便利贴、人物卡这种「不挂的」服务器那边就不推。
/// 动作卡片（移植自之前自用的 App ActionCardViews，09-28 Aporia：原来一行字没有重点）：
/// 左边小图标，**标题**加粗 + 右边时间一行，下面两行正文预览；有正文的点开是整张（ActionCardOverlay）。
/// 服务器给的是「动作：内容」一句（brain/tools.py 的 Card），在第一个冒号处切成标题和正文。
struct ActionCardChip: View {
    let kind: String
    let text: String
    let at: Date
    let skin: ChatSkin

    var parts: (title: String, body: String) { Self.split(text) }

    static func split(_ text: String) -> (title: String, body: String) {
        if let r = text.range(of: "：") ?? text.range(of: ": ") {
            return (String(text[..<r.lowerBound]), String(text[r.upperBound...]).trimmingCharacters(in: .whitespaces))
        }
        return (text, "")
    }

    static func icon(_ kind: String) -> String {
        switch kind {
        case "remember": return "brain"
        case "search": return "magnifyingglass"
        case "manual": return "book"
        case "clock": return "alarm"
        case "self_clock": return "clock.arrow.circlepath"
        case "person": return "person.crop.circle"
        case "sticky": return "note.text"
        case "date": return "calendar"
        case "drawer": return "envelope"
        case "diary": return "book.pages"
        case "todo": return "checklist"
        case "moment": return "camera.aperture"
        case "place": return "figure.walk"
        case "photo": return "photo.on.rectangle"
        case "book": return "books.vertical"
        case "wallet": return "wallet.pass"
        case "tarot": return "moon.stars"
        case "focus": return "timer"
        case "food": return "fork.knife"
        case "lore": return "book.closed"
        case "error": return "exclamationmark.triangle"
        default: return "sparkle"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: Self.icon(kind))
                .font(Typo.icon(13))
                .foregroundStyle(skin.inkDim)
                .frame(width: 18, height: 18)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(parts.title)
                        .font(Typo.sans(skin.size(Typo.Size.callout), .semibold))
                        .foregroundStyle(skin.ink)
                    Spacer(minLength: 12)
                    Text(at, format: .dateTime.month(.twoDigits).day(.twoDigits).hour().minute())
                        .font(Typo.number(skin.size(Typo.Size.caption), .regular))
                        .foregroundStyle(skin.inkFaint)
                }
                if !parts.body.isEmpty {
                    Text(parts.body)
                        .font(Typo.sans(skin.size(Typo.Size.callout)))
                        .foregroundStyle(skin.inkDim)
                        .lineSpacing(2)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { ActionCardGlass(skin: skin) }
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// 卡的玻璃底：跟顶栏圆钮同一套（paintedChrome），深色再压暗一层
struct ActionCardGlass: View {
    let skin: ChatSkin
    var radius: CGFloat = 14

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack {
            paintedChrome(shape, skin: skin)
            if skin.isDark { shape.fill(Color.black.opacity(0.30)) }
        }
    }
}

struct OpenedCard: Identifiable {
    let id = UUID()
    let title: String
    let body: String
    let at: Date
}

/// 点开的整张卡（移植自之前自用的 App）：不换页——当前聊天页打一层雾，卡叠在上面，头像悬在卡片正上方中央。点卡外任何地方关掉。
struct ActionCardOverlay: View {
    let card: OpenedCard
    let skin: ChatSkin
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Group {
                LegacyBlur(style: skin.isDark ? .dark : .light)
                (skin.isDark ? Color.black.opacity(0.42) : Color.white.opacity(0.55))
            }
            .ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    VStack(alignment: .center, spacing: 12) {
                        Text(card.title)
                            .font(Typo.sans(Typo.Size.headline, .semibold))
                            .foregroundStyle(skin.ink)
                            .padding(.top, 34)
                        Text(card.body)
                            .font(Typo.sans(Typo.Size.headline))
                            .foregroundStyle(skin.ink.opacity(0.92))
                            .lineSpacing(7)
                            .multilineTextAlignment(.leading)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(card.at, format: .dateTime.year().month(.twoDigits).day(.twoDigits).hour().minute())
                            .font(Typo.number(Typo.Size.caption, .medium))
                            .tracking(0.6)
                            .foregroundStyle(skin.inkFaint)
                            .padding(.top, 2)
                    }
                    .padding(.horizontal, 22).padding(.vertical, 22)
                    .background { ActionCardGlass(skin: skin, radius: 22) }
                    .overlay(alignment: .top) {
                        AvatarView(who: .ai, size: 58)
                            .overlay(Circle().stroke(Color.white.opacity(0.75), lineWidth: 2))
                            .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
                            .offset(y: -29)
                    }
                    .padding(.horizontal, 26)
                    .padding(.top, 40)
                    .onTapGesture { }
                }
                .frame(maxWidth: .infinity)
                .frame(minHeight: UIScreen.main.bounds.height * 0.9)
                .contentShape(Rectangle())
                .onTapGesture { onClose() }
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}

// MARK: - 打字中三个点

/// 呼吸动画交给 Core Animation：动的是图层不是视图，SwiftUI 的布局动画碰不到它，主线程一帧都不用管
/// （之前自用的 App第一版 repeatForever 会"跟跳蚤一样"满屏飞，第二版 TimelineView 每秒重画 30 次吃主线程）。
private struct BobbingDot: UIViewRepresentable {
    let color: Color
    let size: CGFloat
    /// 相位差（秒）：三个点错开起伏
    let delay: Double

    func makeUIView(context: Context) -> BobbingDotView {
        let view = BobbingDotView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: BobbingDotView, context: Context) {
        view.apply(color: UIColor(color), size: size, delay: delay)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: BobbingDotView, context: Context) -> CGSize? {
        CGSize(width: size, height: size)
    }
}

private final class BobbingDotView: UIView {
    private let dot = CALayer()
    private var configured = (size: CGFloat(0), delay: Double(-1))

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        layer.addSublayer(dot)
        // 回前台时 CA 动画会被系统清掉，补上
        NotificationCenter.default.addObserver(self, selector: #selector(restartAnimation),
                                               name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { NotificationCenter.default.removeObserver(self) }

    func apply(color: UIColor, size: CGFloat, delay: Double) {
        dot.backgroundColor = color.cgColor
        dot.cornerRadius = size / 2
        if configured.size != size || configured.delay != delay {
            configured = (size, delay)
            dot.bounds = CGRect(x: 0, y: 0, width: size, height: size)
            restartAnimation()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dot.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { restartAnimation() }
    }

    @objc private func restartAnimation() {
        dot.removeAnimation(forKey: "bob")
        let bob = CABasicAnimation(keyPath: "transform.translation.y")
        bob.fromValue = -3
        bob.toValue = 1
        bob.duration = 0.5
        bob.autoreverses = true
        bob.repeatCount = .infinity
        bob.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        bob.beginTime = CACurrentMediaTime() + configured.delay
        bob.isRemovedOnCompletion = false
        dot.add(bob, forKey: "bob")
    }
}

// MARK: - 输入框

/// 输入框 + 发送键。**草稿状态住在这里，不住在 ChatView**：状态一变拥有它的视图整体重画，
/// 住在 ChatView 上的话每敲一个字母整个列表都跟着重算（之前自用的 App 08-02「世界级延迟」）。
/// 草稿落盘：App 被杀、重装、切后台太久，打了一半的话不丢。
private struct DraftField: View {
    @EnvironmentObject var theme: AppTheme

    let placeholder: String
    let skin: ChatSkin
    /// 自己长高/变矮时通知一声
    let onHeightChange: (CGFloat) -> Void
    let onSend: (String) -> Void
    /// 空着时发送键变麦克风（10-03 TA 发语音条）；nil = 不给麦克风（无痕、朋友圈）
    var onVoice: ((Data, Double) -> Void)?

    @AppStorage private var draft: String
    @FocusState private var focused: Bool
    @State private var voiceActive = false

    /// 草稿一个窗口一份（09-28：以前全局一份，换个联系人草稿跟着串过去）
    /// 群里能 @ 的名字（10-11）：打了 @ 就在输入框上面浮一排
    var mentionNames: [String] = []

    init(draftKey: String, placeholder: String, skin: ChatSkin, mentionNames: [String] = [], onHeightChange: @escaping (CGFloat) -> Void,
         onVoice: ((Data, Double) -> Void)? = nil, onSend: @escaping (String) -> Void) {
        self.mentionNames = mentionNames
        self.onVoice = onVoice
        _draft = AppStorage(wrappedValue: "", draftKey)
        self.placeholder = placeholder
        self.skin = skin
        self.onHeightChange = onHeightChange
        self.onSend = onSend
    }

    private var sendable: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var showMentions: Bool { !mentionNames.isEmpty && draft.hasSuffix("@") }

    var body: some View {
        // 录语音时输入框让开，录音条放进来（10-03）
        if !voiceActive {
        VStack(alignment: .leading, spacing: 6) {
        // 群里打了 @：输入框上面一排成员（10-11）。放在排版里而不是浮层——浮出底栏的部分点不到
        if showMentions {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(mentionNames, id: \.self) { name in
                        Button { draft += name + " " } label: {
                            Text("@" + name)
                                .font(Typo.sans(Typo.Size.callout, .medium))
                                .foregroundStyle(skin.ink)
                                .padding(.horizontal, 12).padding(.vertical, 7)
                                .background(paintedChrome(Capsule(), skin: skin))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        // 提示字自己上色：系统默认的灰压在深色玻璃上几乎看不见
        TextField("", text: $draft, prompt: Text(placeholder).foregroundStyle(skin.inkDim.opacity(0.8)), axis: .vertical)
            .lineLimit(1...4)
            // 不许被压回一行（被压扁之后它改成内部滚动，只剩最后一行看得见）
            .fixedSize(horizontal: false, vertical: true)
            .focused($focused)
            // 回车直接发送（10-11 内测反馈）；要换行就长按 shift+return（外接键盘）或先打完再编辑
            .submitLabel(.send)
            .onSubmit {
                guard sendable else { return }
                let text = draft
                draft = ""
                onSend(text)
                focused = true          // 发完键盘不缩回去，接着聊
            }
            .onReceive(NotificationCenter.default.publisher(for: ChatView.selfTestFocus)) { note in
                focused = (note.object as? Bool) ?? false
            }
            .font(Typo.sans(skin.size(Typo.Size.headline)))
            .foregroundStyle(skin.ink)
            .tint(theme.accent)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background {
                // 输入框是扁长件：光从下沿打上来
                paintedChrome(Capsule(), skin: skin, light: .fromBottom)
            }
            .background {
                // 只在高度真的变了时上报（一行变两行那种），不是每敲一个字都报
                GeometryReader { geo in
                    Color.clear.onChange(of: geo.size.height, initial: true) { _, h in
                        onHeightChange(h)
                    }
                }
            }
        }
        .onChange(of: showMentions) { _, _ in onHeightChange(0) }

        }
        if let onVoice, !sendable {
            VoiceRecordButton(skin: skin, active: $voiceActive, onSend: onVoice)
        } else {
        Button {
            let text = draft
            draft = ""
            onSend(text)
        } label: {
            Image(systemName: "arrow.up")
                .font(Typo.icon(16, .bold))
                .foregroundStyle(theme.accent)
                .frame(width: 36, height: 36)
                .background(paintedChrome(Circle(), skin: skin))
        }
        .disabled(!sendable)
        }
    }
}

// MARK: - 手画的仿玻璃

/// 手画的仿玻璃（之前自用的 App 08-06 ～ 08-28 三稿）：材质糊掉底下滑过去的内容 → 深色压一层墨吸掉奶白 →
/// 一层极淡的染色 → 一圈渐变描边（光在边上不在面上，像玻璃杯沿的光）。
/// 扁长的件光从下沿打上来；方的件左上一段亮高光。
enum ChromeLight {
    case diagonal
    case fromBottom
}

@ViewBuilder
func paintedChrome<S: InsettableShape>(_ shape: S, skin: ChatSkin,
                                       light: ChromeLight = .diagonal) -> some View {
    ZStack {
        shape.fill(.ultraThinMaterial).opacity(Frost.material)
        shape.fill(skin.chromeDim)
        shape.fill(skin.chromeTint)
        shape.strokeBorder(
            LinearGradient(stops: skin.chromeEdgeLight,
                           startPoint: light == .diagonal ? .topLeading : .bottom,
                           endPoint: light == .diagonal ? .bottomTrailing : .top),
            lineWidth: 0.75)
    }
}

/// 点开的那通电话（10-31）
struct CallLogTarget: Identifiable {
    let id: Int
    let title: String
}

/// 一通电话说了什么：你在右、TA 在左，跟通话页的字幕一个样子
struct CallLogSheet: View {
    @EnvironmentObject private var theme: AppTheme
    let title: String
    let lines: [(mine: Bool, text: String)]
    let name: String

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 10) {
                    if lines.isEmpty {
                        Text("这通电话的记录不在眼前，往上翻一翻再点").font(Typo.sans(Typo.Size.callout))
                            .foregroundStyle(theme.inkFaint).padding(.top, 40)
                    }
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, l in
                        HStack {
                            if l.mine { Spacer(minLength: 48) }
                            Text(l.text)
                                .font(Typo.sans(Typo.Size.body))
                                .foregroundStyle(theme.ink)
                                .padding(.horizontal, 13).padding(.vertical, 9)
                                .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(l.mine ? theme.accent.opacity(0.22) : theme.ink.opacity(0.06)))
                                .textSelection(.enabled)
                            if !l.mine { Spacer(minLength: 48) }
                        }
                    }
                }
                .padding(16)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
