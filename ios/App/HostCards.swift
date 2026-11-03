import SwiftUI

/// Mele Host（10-04 第二步）：Lite 连上用户自己部署的 Mele 服务器。
/// 连上 = App 跟正式版 Mele 一样直接跟 Host 说话（不经过手机里的小管家），灰着的功能全亮；
/// 只在手机里做的几样（地图和它的一天、小号加好友、翻手机、接记忆库、手机版音乐）连着 Host 时先收起来，断开回本机还在。
/// 地址存 UserDefaults，登录凭证存钥匙串。
enum HostLink {
    static let apiVersion = 1                       // 跟服务器 api/app.py 的 API_VERSION 对
    static let urlKey = "host.url"
    private static let tokenKey = "hostToken"
    /// 断开时记下的上一个 Host（10-12 内测：本地部署出门连不上就得断，回家再连要重填地址、再去服务器拿配对码）。
    /// 凭证留着，回来一键连回去；Host 不认了才只留地址、要配对码
    private static let lastURLKey = "host.lastURL"
    private static let lastTokenKey = "hostTokenLast"
    static let tipKey = "host.tipShown"
    /// Host 的版本戳（10-13 内测：推送重复修了三版都在 Host 上，测的人只更新过一次 Host，App 更新了也没用，还看不出来）。
    /// 镜像打的时候写进去，样子是 YYYYMMDD-提交号；老镜像没有 → 当旧的。App 要的最低日期在这里，Host 修了要紧的事就往上调
    static let minHostBuild = "20261031"
    private static let buildKey = "host.build"           // "" = 问过了、Host 没报（老镜像）；nil = 还没问过
    static var hostBuild: String? { UserDefaults.standard.string(forKey: buildKey) }
    static var hostOutdated: Bool {
        guard let b = hostBuild else { return false }
        return String(b.prefix(8)) < minHostBuild
    }

    /// 连着 Host 时每次打开 App 问一次 /version，记下版本戳
    static func refreshBuild() async {
        guard let link = current else { return }
        guard let (d, _) = try? await URLSession.shared.data(from: link.url.appendingPathComponent("version")),
              let v = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
        UserDefaults.standard.set(v["build"] as? String ?? "", forKey: buildKey)
    }

    struct Link { let url: URL; let token: String }

    static var current: Link? {
        #if LITE
        guard let s = UserDefaults.standard.string(forKey: urlKey), let url = URL(string: s),
              let token = Keychain.read(tokenKey) else { return nil }
        return Link(url: url, token: token)
        #else
        return nil
        #endif
    }

    static var connected: Bool { current != nil }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// 地址整理成 https://xxx（不带结尾 /）；用户可能只填了域名
    static func normalize(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.lowercased().hasPrefix("http://") && !s.lowercased().hasPrefix("https://") { s = "https://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        guard let url = URL(string: s), url.host != nil else { return nil }
        return url
    }

    /// 先问 /version（是不是 Host、版本对不对），再拿配对码换登录凭证
    static func connect(address: String, code: String) async throws {
        guard let base = normalize(address) else { throw Failure(message: String(localized: "地址看不懂，填安装完打出来的那个 https:// 地址")) }
        guard base.scheme == "https" else { throw Failure(message: String(localized: "地址要是 https:// 开头的")) }
        let version: [String: Any]
        do {
            let (d, _) = try await URLSession.shared.data(from: base.appendingPathComponent("version"))
            version = (try JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
        } catch {
            throw Failure(message: String(localized: "连不上这个地址：服务器开着吗？地址对吗？"))
        }
        guard version["host"] as? Bool == true else { throw Failure(message: String(localized: "这个地址不是 Mele Host")) }
        let api = version["api"] as? Int ?? 0
        if api > apiVersion { throw Failure(message: String(localized: "Host 比 App 新：去 TestFlight / App Store 更新一下 Mele Lite")) }
        if api < apiVersion { throw Failure(message: String(localized: "Host 比 App 旧：在服务器上运行 mele-host update")) }

        var req = URLRequest(url: base.appendingPathComponent("host/pair"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["code": code, "tz": TimeZone.current.identifier])
        let data: Data, resp: URLResponse
        do { (data, resp) = try await URLSession.shared.data(for: req) } catch {
            throw Failure(message: String(localized: "连不上这个地址：服务器开着吗？地址对吗？"))
        }
        let body = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        guard (resp as? HTTPURLResponse)?.statusCode == 200, let token = body["token"] as? String else {
            throw Failure(message: body["detail"] as? String ?? String(localized: "配对没成功"))
        }
        save(url: base, token: token)
    }

    #if LITE
    /// 搬家（第三步）：手机里的核心东西整包交给 Host（/me/import）；手机里的原件不删。返回搬了多少
    /// 带文件的房间（10-05 第二批）：先 /me/import/files 问 Host 缺哪些指纹，一个个 PUT 上去，最后整包交 /me/import。
    /// progress(传了几个, 一共几个)；中途断了再点一次，传过的、搬过的都不再传。
    static func moveFromPhone(progress: (@MainActor (Int, Int) -> Void)? = nil) async throws -> [String: Int] {
        guard let link = current else { throw Failure(message: String(localized: "还没连上 Mele Host")) }
        let (bundle, files) = await Task.detached(priority: .userInitiated) { LocalExport.hostBundle(withFiles: true) }.value
        func request(_ path: String, _ method: String, timeout: TimeInterval) -> URLRequest {
            var r = URLRequest(url: link.url.appendingPathComponent(path), timeoutInterval: timeout)
            r.httpMethod = method
            r.setValue("Bearer \(link.token)", forHTTPHeaderField: "Authorization")
            return r
        }
        var ask = request("me/import/files", "POST", timeout: 60)
        ask.setValue("application/json", forHTTPHeaderField: "Content-Type")
        ask.httpBody = try JSONSerialization.data(withJSONObject: ["rooms": bundle["rooms"] ?? [String: Any]()])
        var missing: [String] = []
        do {
            let (d, r) = try await URLSession.shared.data(for: ask)
            if (r as? HTTPURLResponse)?.statusCode == 200 {          // 老 Host 没这个接口（404）：只搬文字的
                missing = ((try? JSONSerialization.jsonObject(with: d)) as? [String: Any])?["missing"] as? [String] ?? []
            }
        } catch {
            throw Failure(message: String(localized: "搬到一半断了：网络不稳，再试一次（已经搬过去的不会重复）"))
        }
        let todo = missing.filter { files[$0] != nil }
        for (i, h) in todo.enumerated() {
            await progress?(i, todo.count)
            guard let url = files[h], let data = try? Data(contentsOf: url) else { continue }
            var put = request("me/import/files/\(h)", "PUT", timeout: 180)
            put.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            do {
                let (_, r) = try await URLSession.shared.upload(for: put, from: data)
                if (r as? HTTPURLResponse)?.statusCode != 204 { continue }   // 这一个不收（太大 / 坏了）：那一条留在手机里
            } catch {
                throw Failure(message: String(localized: "传照片传到一半断了：网络不稳，再点一次接着传（传过的不重传）"))
            }
        }
        if !todo.isEmpty { await progress?(todo.count, todo.count) }
        var req = request("me/import", "POST", timeout: 300)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: bundle)
        let data: Data, resp: URLResponse
        do { (data, resp) = try await URLSession.shared.data(for: req) } catch {
            throw Failure(message: String(localized: "搬到一半断了：网络不稳，再试一次（已经搬过去的不会重复）"))
        }
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw Failure(message: body["detail"] as? String ?? String(localized: "没搬成"))
        }
        var out = body.compactMapValues { $0 as? Int }
        // 房间（10-05）：服务器回 {kind: 几条}，这里只要一个总数
        if let r = body["rooms"] as? [String: Any] {
            out["memories"] = r["memories"] as? Int ?? 0                 // 记忆单独报（10-13）
            out["rooms"] = r.filter { $0.key != "memories" }.values.compactMap { $0 as? Int }.reduce(0, +)
        }
        return out
    }

    static func movingLabel(_ sent: (Int, Int)?) -> String {
        guard let (n, all) = sent, all > 0 else { return String(localized: "搬家中…") }
        return n < all ? String(localized: "传文件 \(n + 1)/\(all)…") : String(localized: "搬家中…")
    }
    #endif

    static func save(url: URL, token: String) {
        UserDefaults.standard.set(url.absoluteString, forKey: urlKey)
        Keychain.write(tokenKey, token)
    }

    /// keepToken：自己点断开 = 留着凭证下次一键连回；Host 不认凭证了 = 只留地址
    static func disconnect(keepToken: Bool = true) {
        if let link = current {
            UserDefaults.standard.set(link.url.absoluteString, forKey: lastURLKey)
            if keepToken { Keychain.write(lastTokenKey, link.token) } else { Keychain.delete(lastTokenKey) }
        }
        UserDefaults.standard.removeObject(forKey: urlKey)
        Keychain.delete(tokenKey)
    }

    /// 上一个 Host 的地址（没连着的时候才有意义）；token 为空 = 要重新配对
    static var last: (url: URL, token: String?)? {
        guard let s = UserDefaults.standard.string(forKey: lastURLKey), let url = URL(string: s) else { return nil }
        return (url, Keychain.read(lastTokenKey))
    }

    static func forgetLast() {
        UserDefaults.standard.removeObject(forKey: lastURLKey)
        Keychain.delete(lastTokenKey)
    }

    /// 用记下的凭证连回去：先看连不连得上，再看 Host 还认不认这个凭证
    static func reconnect() async throws {
        guard let last, let token = last.token else { throw Failure(message: String(localized: "要重新配对")) }
        var req = URLRequest(url: last.url.appendingPathComponent("me"), timeoutInterval: 15)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let resp: URLResponse
        do { (_, resp) = try await URLSession.shared.data(for: req) } catch {
            throw Failure(message: String(localized: "连不上这个地址：服务器开着吗？手机跟它在同一个网络里吗？"))
        }
        switch (resp as? HTTPURLResponse)?.statusCode {
        case 200: save(url: last.url, token: token)
        case 401, 403:
            Keychain.delete(lastTokenKey)
            throw Failure(message: String(localized: "Host 不认这台手机了：在服务器上运行 mele-host pair 拿新的配对码"))
        default: throw Failure(message: String(localized: "Host 没回应，等一下再试"))
        }
    }

    /// 扫安装时那个二维码：mele://host?u=<地址>&c=<配对码>
    static func parse(_ url: URL) -> (address: String, code: String)? {
        guard url.scheme == "mele", url.host == "host",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        let u = items.first { $0.name == "u" }?.value ?? ""
        let c = items.first { $0.name == "c" }?.value ?? ""
        return u.isEmpty ? nil : (u, c)
    }
}

extension Notification.Name {
    /// 扫了 Host 的二维码（mele://host?…）：打开连接页并填好
    static let meleHostLink = Notification.Name("meleHostLink")
}

/// Me 里的「Mele Host」卡：没连 = 一句话 + 连接；连着 = 地址 + 断开。右上角 ? 是教程。
struct HostCard: View {
    @EnvironmentObject private var theme: AppTheme
    @EnvironmentObject private var session: SessionStore
    @State private var connecting = false
    @State private var guide = false
    @State private var confirmLeave = false
    @State private var moving = false
    @State private var movedNote: String?
    @State private var sent: (Int, Int)?
    @State private var rejoining = false
    @State private var rejoinError: String?
    @State private var forgot = false          // 点了「忘掉」：重画一下
    @State private var asked = false           // 问过 Host 版本：重画一下

    private func rejoin() async {
        rejoining = true; rejoinError = nil
        defer { rejoining = false }
        do {
            try await HostLink.reconnect()
            session.switchHost()
        } catch {
            rejoinError = error.localizedDescription
        }
    }

    #if LITE
    /// 连的时候没搬、或者后来手机里又多了：再搬一次（已经搬过的不重复）
    private func move() async {
        moving = true
        defer { moving = false; sent = nil }
        do {
            let got = try await HostLink.moveFromPhone { sent = ($0, $1) }
            movedNote = String(localized: "搬好了：\(got["companions"] ?? 0) 个联系人、\(got["messages"] ?? 0) 条聊天、\(got["memories"] ?? 0) 条记忆、房间里 \(got["rooms"] ?? 0) 样东西（已经在 Host 上的没重复搬）")
            if (got["companions"] ?? 0) > 0 { session.switchHost() }
        } catch {
            movedNote = error.localizedDescription
        }
    }
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                CardTitle(text: "Mele Host")
                Spacer()
                Button { guide = true } label: {
                    Image(systemName: "questionmark.circle").font(Typo.icon(18)).foregroundStyle(theme.inkDim)
                }
                .accessibilityLabel(String(localized: "Mele Host 是什么"))
            }
            if let link = HostLink.current {
                HStack(spacing: 8) {
                    Circle().fill(Color.green).frame(width: 8, height: 8)
                    Text(link.url.host ?? link.url.absoluteString).font(Typo.sans(Typo.Size.body)).foregroundStyle(theme.ink)
                        .lineLimit(1).truncationMode(.middle)
                }
                Hint(text: String(localized: "TA 在 Host 上：你关掉 App 它也会想起你、自己醒来。手机里的地图、小号、记忆库连着 Host 时先收起来，断开就回来。"))
                if HostLink.hostOutdated {
                    Label(String(localized: "Host 旧了：在服务器上用 root 运行 mele-host update。最近的修补（推送重复、搬记忆库）都在 Host 上，App 更新了也要 Host 跟上才生效。"),
                          systemImage: "exclamationmark.triangle")
                        .font(Typo.sans(Typo.Size.caption)).foregroundStyle(.orange)
                } else if let b = HostLink.hostBuild, !b.isEmpty {
                    Text(String(localized: "Host 版本 \(b)")).font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkDim)
                }
                #if LITE
                Button(moving ? HostLink.movingLabel(sent) : String(localized: "把手机里的搬过来")) { Task { await move() } }
                    .font(Typo.sans(Typo.Size.callout, .medium)).foregroundStyle(theme.accentDeep).disabled(moving)
                if let movedNote { Hint(text: movedNote) }
                #endif
                Button(String(localized: "断开，回到手机里")) { confirmLeave = true }
                    .font(Typo.sans(Typo.Size.callout, .medium)).foregroundStyle(theme.accentDeep)
            } else if let last = HostLink.last {
                // 断开过：地址记着，凭证还在就一键连回去（10-12 内测）
                HStack(spacing: 8) {
                    Circle().fill(theme.inkDim.opacity(0.5)).frame(width: 8, height: 8)
                    Text(last.url.host ?? last.url.absoluteString).font(Typo.sans(Typo.Size.body)).foregroundStyle(theme.ink)
                        .lineLimit(1).truncationMode(.middle)
                }
                Hint(text: last.token == nil
                     ? String(localized: "已断开。地址记着，在服务器上运行 mele-host pair 拿个新配对码就能连回去。")
                     : String(localized: "已断开，现在用的是手机里那份。地址和配对都记着，回到能连上它的网络点一下就回去。"))
                if last.token != nil {
                    Button(rejoining ? String(localized: "连接中…") : String(localized: "连回去")) { Task { await rejoin() } }
                        .font(Typo.sans(Typo.Size.callout, .medium)).foregroundStyle(theme.accentDeep).disabled(rejoining)
                } else {
                    Button(String(localized: "填配对码连回去")) { connecting = true }
                        .font(Typo.sans(Typo.Size.callout, .medium)).foregroundStyle(theme.accentDeep)
                }
                if let rejoinError { Hint(text: rejoinError) }
                HStack(spacing: 16) {
                    if last.token != nil {
                        Button(String(localized: "用新配对码连")) { connecting = true }
                    }
                    Button(String(localized: "忘掉这个 Host")) { HostLink.forgetLast(); rejoinError = nil; forgot.toggle() }
                }
                .font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkDim)
            } else {
                Hint(text: String(localized: "没连接。连上自己部署的 Mele Host 以后，TA 能在你关掉 App 时主动来找你、自己醒来、记得更久。"))
                Button { connecting = true } label: {
                    Label(String(localized: "连接 Mele Host"), systemImage: "link")
                }
                .font(Typo.sans(Typo.Size.callout, .medium)).foregroundStyle(theme.accentDeep)
            }
        }
        .id("\(forgot)-\(asked)")
        .task { await HostLink.refreshBuild(); asked.toggle() }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
        .sheet(isPresented: $connecting) {
            HostConnectSheet(address: HostLink.last?.url.absoluteString ?? "").environmentObject(session).environmentObject(theme)
        }
        .sheet(isPresented: $guide) {
            HostGuideSheet(onConnect: { guide = false; connecting = true }).environmentObject(theme)
        }
        .confirmationDialog(String(localized: "断开 Mele Host？"), isPresented: $confirmLeave, titleVisibility: .visible) {
            Button(String(localized: "断开"), role: .destructive) {
                HostLink.disconnect()
                session.switchHost()
            }
        } message: {
            Text("回到手机里那份。Host 上的聊天留在 Host 上，地址和配对都记着，下次点「连回去」就行。")
        }
    }
}

/// 填地址和配对码（扫二维码进来时已经填好）
struct HostConnectSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var theme: AppTheme
    @State private var address: String
    @State private var code: String
    @State private var busy = false
    @State private var error: String?
    @State private var phoneHas: (companions: Int, messages: Int)?     // 连上了、手机里有东西：问搬不搬
    @State private var moved: String?
    @State private var sent: (Int, Int)?

    init(address: String = "", code: String = "") {
        _address = State(initialValue: address)
        _code = State(initialValue: code)
    }

    var body: some View {
        NavigationStack {
            if let has = phoneHas { moveForm(has) } else { connectForm }
        }
        .interactiveDismissDisabled(phoneHas != nil)       // 连上了就别下拉关掉，走完「搬 / 不搬」
    }

    private func moveForm(_ has: (companions: Int, messages: Int)) -> some View {
        Form {
            Section {
                Label(String(localized: "连上了"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Text("手机里有 \(has.companions) 个联系人、\(has.messages) 条聊天。要搬到 Host 上吗？")
            } footer: {
                Text("搬的是：我的设定、模型钥匙、联系人（人设、设置、头像）、平常窗口的聊天、本地记忆库，还有日记、信、远事、待办、钱包、人物卡、世界书、收藏夹、里程碑、相册、表情包、书架、饮食、朋友圈、塔罗。照片多的话要传一会儿，中途断了再点一次接着传。手机里的原件一个都不删，断开就回来。")
            }
            if let moved {
                Section {
                    Text(moved)
                    Button(String(localized: "好")) { finish() }
                }
            } else {
                Section {
                    #if LITE
                    Button(busy ? HostLink.movingLabel(sent) : String(localized: "搬过去")) { Task { await move() } }.disabled(busy)
                    #endif
                    Button(String(localized: "先不搬，Host 上从头开始")) { finish() }.disabled(busy)
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .navigationTitle(String(localized: "搬家"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private var connectForm: some View {
            Form {
                Section {
                    TextField("https://203-0-113-7.sslip.io", text: $address)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField(String(localized: "配对码，比如 AB3D-EF7H"), text: $code)
                        .textInputAutocapitalization(.characters).autocorrectionDisabled()
                } footer: {
                    Text("安装完服务器上会打出地址、配对码和一个二维码。用手机相机扫那个二维码会直接填好。配对码用一次就作废；要新的，在服务器上运行 mele-host pair。")
                }
                Section {
                    Button(busy ? String(localized: "连接中…") : String(localized: "连接")) { Task { await connect() } }
                        .disabled(busy || address.trimmingCharacters(in: .whitespaces).isEmpty || code.trimmingCharacters(in: .whitespaces).isEmpty)
                } footer: {
                    Text("连上以后会问你要不要把手机里的聊天搬过去。手机里的原件不删。")
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle(String(localized: "连接 Mele Host"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(String(localized: "取消")) { dismiss() } } }
    }

    private func connect() async {
        busy = true; error = nil
        defer { busy = false }
        do {
            try await HostLink.connect(address: address, code: code)
            #if LITE
            let sum = LocalExport.summary(LocalExport.hostBundle())
            if sum.messages > 0 || sum.companions > 1 { phoneHas = sum; return }     // 手机里有东西：先问搬不搬
            #endif
            dismiss()
            session.switchHost()
        } catch {
            self.error = error.localizedDescription
        }
    }

    #if LITE
    private func move() async {
        busy = true; error = nil
        defer { busy = false; sent = nil }
        do {
            let got = try await HostLink.moveFromPhone { sent = ($0, $1) }
            moved = String(localized: "搬好了：\(got["companions"] ?? 0) 个联系人、\(got["messages"] ?? 0) 条聊天、\(got["memories"] ?? 0) 条记忆、房间里 \(got["rooms"] ?? 0) 样东西")
        } catch {
            self.error = error.localizedDescription
        }
    }
    #endif

    private func finish() {
        dismiss()
        session.switchHost()
    }
}

/// 点 ? 的教程：Host 是什么、连上多了什么、要多少钱、三步装好
struct HostGuideSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var theme: AppTheme
    var onConnect: () -> Void = {}

    private let command = "curl -fsSL https://raw.githubusercontent.com/aporia-and-poros/mele-lite/main/host/install.sh | bash"
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    section(String(localized: "Mele Host 是什么"),
                            String(localized: "一台你自己租的小服务器，上面跑一份完整的 Mele。Lite 只在你打开 App 的时候醒着；连上 Host 以后，TA 一直醒着。服务器和数据都是你的，不经过我们。"))
                    VStack(alignment: .leading, spacing: 8) {
                        heading(String(localized: "连上以后多了什么"))
                        bullet(String(localized: "TA 主动来找你：你关掉 App 它也会想起你，自己醒来"))
                        bullet(String(localized: "记得更久：旧聊天会卷进账本，还有联想记忆"))
                        bullet(String(localized: "每日私选到点推给你、查营养、哨兵、缓存保活"))
                        bullet(String(localized: "推送：TA 来找你时手机会响"))
                    }
                    section(String(localized: "要多少钱"),
                            String(localized: "一台 4GB 内存、20GB 硬盘以上的 Linux 服务器（比如 Hetzner），一个月大约 5 欧元。模型和声音照旧用你自己的 key。"))
                    VStack(alignment: .leading, spacing: 10) {
                        heading(String(localized: "三步装好"))
                        bullet(String(localized: "1. 租一台服务器，系统选 Ubuntu 24.04，记得打开公网 IPv4"))
                        bullet(String(localized: "2. 用 root 登进去，粘下面这一条命令，等几分钟"))
                        Text(command).font(.system(size: 13, design: .monospaced)).foregroundStyle(theme.ink)
                            .textSelection(.enabled).padding(10).frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.05)))
                        Button(copied ? String(localized: "复制好了") : String(localized: "复制命令")) {
                            UIPasteboard.general.string = command; copied = true
                        }
                        .font(Typo.sans(Typo.Size.callout, .medium)).foregroundStyle(theme.accentDeep)
                        bullet(String(localized: "3. 装完屏幕上有一个二维码：用手机相机扫一下，或者在下面手动填地址和配对码"))
                        Hint(text: String(localized: "装完还会打出一串「主密钥」，抄下来放好：丢了它，存在服务器上的 key 就都解不开了。"))
                    }
                    Link(String(localized: "完整说明（GitHub）"), destination: URL(string: "https://github.com/aporia-and-poros/mele-lite")!)
                        .font(Typo.sans(Typo.Size.callout, .medium)).foregroundStyle(theme.accentDeep)
                    if !HostLink.connected { Button { onConnect() } label: {
                        Text("我装好了，去连接").font(Typo.sans(Typo.Size.body, .semibold))
                            .frame(maxWidth: .infinity).padding(.vertical, 12)
                            .background(Capsule().fill(theme.accentDeep)).foregroundStyle(.white)
                    }
                    .buttonStyle(.plain) }
                }
                .padding(20)
            }
            .navigationTitle("Mele Host")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(String(localized: "好")) { dismiss() } } }
        }
    }

    private func heading(_ t: String) -> some View {
        Text(t).font(Typo.sans(Typo.Size.headline, .semibold)).foregroundStyle(theme.ink)
    }

    private func section(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            heading(title)
            Text(body).font(Typo.sans(Typo.Size.body)).foregroundStyle(theme.inkDim).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func bullet(_ t: String) -> some View {
        Text(t).font(Typo.sans(Typo.Size.body)).foregroundStyle(theme.inkDim).fixedSize(horizontal: false, vertical: true)
    }
}

/// 引导走完第一次进主屏：底下冒一次小提示（10-04 Aporia：轻提示，不强制）；点了看教程，点 × 就再也不出
struct HostTip: View {
    @EnvironmentObject private var theme: AppTheme
    @AppStorage(HostLink.tipKey) private var shown = false
    @State private var guide = false
    @State private var connecting = false
    @EnvironmentObject private var session: SessionStore

    var body: some View {
        if Lite.local && (!shown || guide || connecting) {     // 看教程 / 填地址的时候先别消失（不然页面跟着没了）
            HStack(spacing: 10) {
                Image(systemName: "sparkles").foregroundStyle(theme.accentDeep)
                Text("想让 TA 在你关掉 App 时也来找你？看看 Mele Host")
                    .font(Typo.sans(Typo.Size.callout)).foregroundStyle(theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button { shown = true } label: {
                    Image(systemName: "xmark").font(Typo.icon(12, .semibold)).foregroundStyle(theme.inkFaint)
                }
                .accessibilityLabel(String(localized: "不再提示"))
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(Capsule().fill(.regularMaterial))
            .padding(.horizontal, 16)
            .contentShape(Capsule())
            .onTapGesture { guide = true }
            .sheet(isPresented: $guide, onDismiss: { shown = true }) {
                HostGuideSheet(onConnect: { guide = false; connecting = true }).environmentObject(theme)
            }
            .sheet(isPresented: $connecting) {
            HostConnectSheet(address: HostLink.last?.url.absoluteString ?? "").environmentObject(session).environmentObject(theme)
        }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
