import SwiftUI

/// 登录以后的骨架（第二块，照之前自用的 App MainTabView）：四个标签 Home / Library / Memory / Me（09-29 Aporia定），
/// 消息列表从首页推开，聊天再从列表推开——两层都是一整页盖上来，左边缘拖着能退。
enum AppTab: String, CaseIterable {
    case home = "Home"
    case library = "Library"
    case memory = "Memory"
    case me = "Me"
}

struct MainTabView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var session: SessionStore
    @State private var tab: AppTab = .home
    @State private var listX: CGFloat = 0
    @State private var chatX: CGFloat = 0
    @State private var screenW: CGFloat = 430
    @State private var confirmLeaveIncognito = false
    @State private var showDrawer = false
    @State private var focusPrefill: FocusPrefill?
    @State private var feedbackShown = false   // 内测反馈小卡片（11-03）
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(CoachTour.homeKey) private var homeTourPending = false   // 主屏导览没看完前先不冒 Host 提示（两个挤一个位置）

    static let slide = Animation.snappy(duration: 0.32)

    private var coveredByList: Bool { model.listOpen || model.chat != nil }

    /// 内测反馈（11-03）：记一笔今天；在 3 个不同的日子打开过、又在主屏（不在聊天里、导览看完了）才弹，晚一秒半等主屏站稳
    private func askFeedbackIfDue() {
        guard Lite.on else { return }
        FeedbackGate.noteOpen()
        guard FeedbackGate.due(), !feedbackShown else { return }
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            if FeedbackGate.due(), !coveredByList, !homeTourPending { withAnimation { feedbackShown = true } }
        }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            ZStack {
                AppBackground()
                // 整个 App 是一部手机（10-04 Aporia）：软件图标 + 小组件，几页横着滑，底下 Dock + 页码点
                Springboard()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .overlay(alignment: .bottom) {             // Lite 引导走完：冒一次「看看 Mele Host」（10-04 Aporia：轻提示）
                if Lite.on && !coveredByList && !homeTourPending { HostTip().padding(.bottom, 118) }
            }
            // 标签页永远是亮色：聊天页深色时整窗会翻黑，推开那一下底下不能跟着暗（之前自用的 App 08-06）
            .environment(\.colorScheme, .light)
            .ignoresSafeArea(.keyboard, edges: .bottom)


            if model.listOpen {
                MessageListView(onBack: closeList)
                    .environment(\.colorScheme, .light)
                    .offset(x: listX)
                    .overlay(alignment: .leading) { edgeHandle($listX, close: closeList) }
                    .transition(.move(edge: .trailing))
                    .zIndex(1)
            }

            if feedbackShown {
                FeedbackCard(api: model.api) { feedbackShown = false }
                    .transition(.opacity)
                    .zIndex(5)
            }

            if let target = model.chat {
                ChatRoom(companion: target.companion, conversation: target.conversation, api: session.api,
                         incognito: target.incognito,
                         onBack: { if target.incognito { confirmLeaveIncognito = true } else { closeChat() } },
                         onNewWindow: { Task { await model.openNewWindow(target.companion) } },
                         onIncognito: { Task { await model.openNewWindow(target.companion, incognito: true) } },
                         onSettings: { model.settingsFor = target.companion },
                         altName: target.altName, group: target.group)
                    .id(target.conversation)
                    .offset(x: chatX)
                    .overlay(alignment: .leading) { edgeHandle($chatX, close: closeChat) }
                    .transition(.move(edge: .trailing))
                    .zIndex(2)
            }
        }
        .animation(Self.slide, value: model.listOpen)
        .animation(Self.slide, value: model.chat)
        .background {
            GeometryReader { geo in Color.clear.onAppear { screenW = geo.size.width } }
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .onChange(of: scenePhase) { _, phase in
            // 回前台：报「在」、天气 / 在哪 / 日程 / 步数（开了的那几样）；进后台停掉「在」的钟
            if phase == .active {
                ContextReporter.shared.foreground(); PushDelegate.clearDelivered()
                askFeedbackIfDue()
                Task { await model.refreshWindows() }                       // 不在的时候它可能说过话：列表预览刷新
                #if LITE
                if Lite.local { Task { await LocalRooms3.runDueVisits(LocalHost.shared) } }   // 朋友圈：关着的时候欠下的来回（10-18）
                #endif
                Task {
                    await FocusStore.shared.refresh(api: model.api)             // 专注：读回插件记的、到点自动结束
                }
            }
            else if phase == .background { ContextReporter.shared.background() }
        }
        .task {
            ContextReporter.shared.api = model.api
            MusicStore.shared.api = model.api
            await MusicStore.shared.load()               // 歌卡要知道 TA 用什么听歌
            ContextReporter.shared.foreground()
            askFeedbackIfDue()
            if !model.loaded { await model.refresh() }
            #if LITE
            if Lite.local { Task { await LocalRooms3.runDueVisits(LocalHost.shared) } }   // 朋友圈：上次关掉前欠下的来回（10-18）
            IncomingCalls.shared.model = model              // TA 打来（10-31）：来电页要名字和头像
            IncomingCalls.shared.api = model.api
            if Lite.hosted { Task { await HostVoIP.shared.report(api: model.api) } }   // 连着 Host：登记来电用的设备号
            #endif
            await model.greetIfPending()
            #if DEBUG && LITE
            // 自测（10-31）：-callSelfTest 直接进第一个 TA 的聊天，聊天页接着打电话
            if CommandLine.arguments.contains("-callSelfTest"), let c = model.companions.first { await model.openChat(c) }
            // 自测（10-31 第 4 步）：-ringSelfTest 进第一个 TA 的聊天，递一句旁白让它用 phone_call 打过来
            if CommandLine.arguments.contains("-ringSelfTest"), let c = model.companions.first {
                await model.openChat(c)
                try? await Task.sleep(for: .seconds(1.5))
                if let conv = model.chat?.conversation.uuidString.lowercased() {
                    LocalHost.shared.brain.poke(conv, nudge: "〔测试：现在用 phone_call 工具给对方打个语音电话，reason 写一句为什么想打。〕")
                }
            }
            #endif
            if !Lite.local { await PushDelegate.requestAndRegister() }   // 手机里的小管家推不了；连着 Mele Host 就要（10-04）
            await model.reportDevice()
            await HostLink.refreshBuild()                   // Host 是不是旧的（10-13）：Me 的 Host 卡上提醒 mele-host update
        }
        .onReceive(NotificationCenter.default.publisher(for: .lumiDeviceToken)) { _ in
            Task { await model.reportDevice() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .lumiOpenDrawer)) { _ in showDrawer = true }
        .modifier(RoomCovers(model: model, theme: theme))
        .task {                                     // 待办的地理围栏：每次进来按服务器上的地方对一遍（10-01）
            if let places: [PlaceDTO] = try? await model.api.call("GET", "places") { PlaceMonitor.shared.sync(places) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .lumiRelationshipChanged)) { _ in Task { await model.refresh() } }
        .onReceive(NotificationCenter.default.publisher(for: .lumiWindowsChanged)) { _ in Task { await model.refreshWindows() } }
        .onOpenURL { url in                         // 小组件点开（09-29）：mele://focus · drawer · wakes · music
            if HostLink.parse(url) != nil { return }      // 扫了 Host 的二维码：SignedIn 那层接（引导里也能扫）
            switch url.host {
            case "focus": NotificationCenter.default.post(name: .lumiOpenFocus, object: nil)
            case "drawer": NotificationCenter.default.post(name: .lumiOpenDrawer, object: nil)
            case "todo": NotificationCenter.default.post(name: .lumiOpenTodo, object: nil)
            case "diary": NotificationCenter.default.post(name: .lumiOpenDiary, object: nil)
            case "calendar": NotificationCenter.default.post(name: .lumiOpenCalendar, object: nil)
            case "moments": NotificationCenter.default.post(name: .lumiOpenMoments, object: nil)
            case "wakes": NotificationCenter.default.post(name: .lumiOpenWakes, object: nil)
            case "music": NotificationCenter.default.post(name: .lumiOpenMusic, object: nil)
            case "books": NotificationCenter.default.post(name: .lumiOpenBooks, object: nil)
            case "wallet": NotificationCenter.default.post(name: .lumiOpenWallet, object: nil)
            case "album": NotificationCenter.default.post(name: .lumiOpenAlbum, object: nil)
            case "favorites": NotificationCenter.default.post(name: .lumiOpenFavorites, object: nil)
            case "tarot": NotificationCenter.default.post(name: .lumiOpenTarot, object: nil)
            case "food": NotificationCenter.default.post(name: .lumiOpenFood, object: nil)
            default: break
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .lumiOpenFocus)) { note in
            focusPrefill = FocusPrefill(minutes: note.userInfo?["minutes"] as? Int ?? 45, label: note.userInfo?["label"] as? String ?? "")
        }
        .sheet(item: $focusPrefill) { p in
            // 在哪个窗口开：聊天开着就是这个窗口，不然是最近那个联系人的最近一个窗口
            let comp = model.chat.flatMap { model.companion($0.companion.id) } ?? model.recentCompanion
            FocusSheet(prefill: p, conversation: model.chat?.conversation ?? comp.flatMap { model.latestConversation($0.id)?.id },
                       companion: comp)
                .environmentObject(model).environmentObject(theme)
                .presentationDetents([.large])
        }
        .fullScreenCover(isPresented: $showDrawer) { DrawerView().environmentObject(model).environmentObject(theme) }
        .onReceive(NotificationCenter.default.publisher(for: PushDelegate.openFromPush)) { note in
            // 点了通知：进那个人的那个窗口；群的进群
            if note.userInfo?["group"] as? Bool == true, let conv = note.userInfo?["conversation"] as? UUID {
                Task { if model.group(conv) == nil { await model.loadGroups() }; if let g = model.group(conv) { model.openGroup(g) } }
                return
            }
            guard let conv = note.userInfo?["conversation"] as? UUID, let comp = note.userInfo?["companion"] as? UUID,
                  let c = model.companion(comp) else { return }
            if let g = model.group(conv) { model.openGroup(g); return }        // Host 推来的群消息（带的是说话那个 TA）
            model.openChat(c, conversation: conv)
        }
        .sheet(item: $model.settingsFor) { c in
            CompanionSettingsView(companion: c, api: session.api)
                .environmentObject(model).environmentObject(theme)
                .presentationDetents([.large])
        }
        .confirmationDialog("离开无痕？", isPresented: $confirmLeaveIncognito, titleVisibility: .visible) {
            Button("离开并删掉这段", role: .destructive) { closeChat() }
            Button("再待会儿", role: .cancel) {}
        } message: {
            Text("这段对话会整个删掉，TA 也不会记得。")
        }
    }

    private func closeList() {
        withAnimation(Self.slide) { listX = screenW } completion: {
            model.listOpen = false
            listX = 0
        }
    }

    private func closeChat() {
        guard let target = model.chat else { return }
        withAnimation(Self.slide) { chatX = screenW } completion: {
            model.chat = nil
            chatX = 0
            Task { await model.chatClosed(target) }
        }
        if target.incognito {
            Task { try? await session.api.send("DELETE", "conversations/\(target.conversation.lowercased)") }
        }
    }

    /// 左边缘 24pt 的把手：往右拖过三分之一或者甩得够快就退
    private func edgeHandle(_ x: Binding<CGFloat>, close: @escaping () -> Void) -> some View {
        Color.clear
            .frame(width: 24)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { v in x.wrappedValue = max(0, v.translation.width) }
                    .onEnded { v in
                        if v.translation.width > screenW / 3 || v.predictedEndTranslation.width > screenW / 2 {
                            close()
                        } else {
                            withAnimation(.snappy(duration: 0.25)) { x.wrappedValue = 0 }
                        }
                    }
            )
            .ignoresSafeArea()
    }

    @EnvironmentObject private var theme: AppTheme

    /// 底下的菜单：一枚毛玻璃小胶囊 + 四个点（照手机主屏的页码点）；点一下跳过去，横着滑也行
    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(AppTab.allCases, id: \.self) { item in
                Button {
                    withAnimation(.snappy(duration: 0.25)) { tab = item }
                } label: {
                    Circle()
                        .fill(tab == item ? theme.accentDeep : theme.ink.opacity(0.22))
                        .frame(width: 7, height: 7)
                        .scaleEffect(tab == item ? 1.15 : 1)
                        .frame(width: 22, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.rawValue)
            }
        }
        .padding(.horizontal, 8)
        .background {
            Capsule().fill(.ultraThinMaterial)
            Capsule().fill(theme.accentSoft.opacity(0.12))
            Capsule().stroke(Color.white.opacity(0.45), lineWidth: 1)
        }
        .animation(.snappy(duration: 0.2), value: tab)
        .padding(.bottom, 10)
    }
}


/// Library / Memory 的各个房间：收到「打开」就全屏盖上（10-01 从 MainTabView 拆出来——修饰链太长编译器算不过来）
private struct RoomCovers: ViewModifier {
    @ObservedObject var model: AppModel
    @ObservedObject var theme: AppTheme
    @State private var showFood = false
    @State private var showMusic = false
    @State private var showLore = false
    @State private var showPeople = false
    @State private var showDiary = false
    @State private var showTodo = false
    @State private var showStickers = false
    @State private var showCalendar = false
    @State private var showMoments = false
    @State private var showFavorites = false
    @State private var showAlbum = false
    @State private var showBooks = false
    @State private var showWallet = false
    @State private var showTarot = false

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .lumiOpenMoments)) { _ in showMoments = true }
            .fullScreenCover(isPresented: $showMoments) { MomentsView(api: model.api).environmentObject(model).environmentObject(theme) }
            .onReceive(NotificationCenter.default.publisher(for: .lumiOpenCalendar)) { _ in showCalendar = true }
            .fullScreenCover(isPresented: $showCalendar) { CalendarRoomView().environmentObject(model).environmentObject(theme) }
            .onReceive(NotificationCenter.default.publisher(for: .lumiOpenFood)) { _ in showFood = true }
            .fullScreenCover(isPresented: $showFood) { FoodRoom().environmentObject(model).environmentObject(theme) }
            .onReceive(NotificationCenter.default.publisher(for: .lumiOpenMusic)) { _ in showMusic = true }
            .fullScreenCover(isPresented: $showMusic) { MusicRoomView().environmentObject(model).environmentObject(theme) }
            .onReceive(NotificationCenter.default.publisher(for: .lumiOpenLore)) { _ in showLore = true }
            .fullScreenCover(isPresented: $showLore) { LoreRoomView().environmentObject(model).environmentObject(theme) }
            .onReceive(NotificationCenter.default.publisher(for: .lumiOpenPeople)) { _ in showPeople = true }
            .fullScreenCover(isPresented: $showPeople) { PeopleRoomView().environmentObject(model).environmentObject(theme) }
            .onReceive(NotificationCenter.default.publisher(for: .lumiOpenDiary)) { _ in showDiary = true }
            .fullScreenCover(isPresented: $showDiary) { DiaryView().environmentObject(model).environmentObject(theme) }
            .onReceive(NotificationCenter.default.publisher(for: .lumiOpenTodo)) { _ in showTodo = true }
            .fullScreenCover(isPresented: $showTodo) { TodoRoomView().environmentObject(model).environmentObject(theme) }
            .onReceive(NotificationCenter.default.publisher(for: .lumiOpenStickers)) { _ in showStickers = true }
            .fullScreenCover(isPresented: $showStickers) { StickerRoomView().environmentObject(model).environmentObject(theme) }
            .onReceive(NotificationCenter.default.publisher(for: .lumiOpenFavorites)) { _ in showFavorites = true }
            .fullScreenCover(isPresented: $showFavorites) { FavoritesView().environmentObject(model).environmentObject(theme) }
            .onReceive(NotificationCenter.default.publisher(for: .lumiOpenWallet)) { _ in showWallet = true }
            .fullScreenCover(isPresented: $showWallet) { WalletView().environmentObject(model).environmentObject(theme) }
            .onReceive(NotificationCenter.default.publisher(for: .lumiOpenTarot)) { _ in showTarot = true }
            .fullScreenCover(isPresented: $showTarot) { TarotRoomView().environmentObject(model).environmentObject(theme) }
            .onReceive(NotificationCenter.default.publisher(for: .lumiOpenBooks)) { _ in showBooks = true }
            .fullScreenCover(isPresented: $showBooks) { BookshelfView().environmentObject(model).environmentObject(theme) }
            .onReceive(NotificationCenter.default.publisher(for: .lumiOpenAlbum)) { _ in showAlbum = true }
            .fullScreenCover(isPresented: $showAlbum) { FilmRollView(names: Dictionary(uniqueKeysWithValues: model.companions.map { ($0.id, $0.name) }))
                    .environmentObject(model).environmentObject(theme) }
    }
}
