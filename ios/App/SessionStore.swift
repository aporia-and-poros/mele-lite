import Foundation
import Security
import SwiftUI

/// 登录状态：登录凭证存钥匙串（Keychain），下次打开免登；服务器地址存 UserDefaults（开发时在登录页长按标题改）。
@MainActor
final class SessionStore: ObservableObject {
    static let defaultServer = "http://192.168.0.28:8080"      // 开发阶段：她 Mac 在家里 Wi-Fi 上的地址（python -m api）

    @Published private(set) var isLoggedIn: Bool
    /// 连上 / 断开 Mele Host 时 +1：整个登录后的界面按它重建（10-04）
    @Published private(set) var hostEpoch = 0
    @Published var serverURL: String {
        didSet { UserDefaults.standard.set(serverURL, forKey: "serverURL"); api.baseURL = URL(string: serverURL) ?? api.baseURL }
    }
    let api: APIClient

    init() {
        #if LITE
        #if DEBUG
        // 自测（10-04）：-hostSelfTest <地址> <登录凭证> 直接当成连着 Mele Host 启动（模拟器点配对太慢）
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "-hostSelfTest"), args.count > i + 2, let u = URL(string: args[i + 1]) {
            HostLink.save(url: u, token: args[i + 2])
        }
        if args.contains("-hostOff") { HostLink.disconnect() }      // 自测（10-31）：模拟器连着关掉的测试 Host 时先断开，用本机
        LocalHost.shared.debugSeedKey()
        LocalHost.shared.debugSeedGemini()
        // 自测（10-05）：SIMCTL_CHILD_LITE_TEST_SAY="<窗口编号>|<一句话>" 直接放进那个窗口的输入框（模拟器敲不了中文）
        if let say = ProcessInfo.processInfo.environment["LITE_TEST_SAY"], let bar = say.firstIndex(of: "|") {
            UserDefaults.standard.set(String(say[say.index(after: bar)...]), forKey: "chatDraft-\(say[..<bar])")
        }
        #endif
        // Lite：没有账号、没有服务器，一直是「登录着」，连的是手机里的小管家；连了 Mele Host 就连 Host（10-04）
        let server = HostLink.current?.url.absoluteString ?? LocalHostProtocol.baseURL.absoluteString
        let token: String? = HostLink.current?.token ?? "local"
        #else
        let server = UserDefaults.standard.string(forKey: "serverURL") ?? Self.defaultServer
        let token = Keychain.read("session")
        #endif
        serverURL = server
        api = APIClient(baseURL: URL(string: server) ?? URL(string: Self.defaultServer)!, token: token)
        isLoggedIn = token != nil
        AuthImageView.api = api
        FoodLogConfig.api = api                 // 饮食页也走这个（09-29）
        PlaceMonitor.shared.api = api           // 待办的地理围栏：App 被系统在后台叫醒时也要能报进出（10-01）
        api.onUnauthorized = { [weak self] in Task { @MainActor in self?.unauthorized() } }
    }

    private func unauthorized() {
        #if LITE
        // Host 不认这个凭证了（服务器重置过、换了 SECRET）：断开回本机，去 Me 重新配对；Lite 没有登录页
        if HostLink.connected { HostLink.disconnect(keepToken: false); switchHost() }
        #else
        logout(local: true)
        #endif
    }

    /// 连上 / 断开 Mele Host 以后：换地址和凭证，整个界面重建
    func switchHost() {
        #if LITE
        if let link = HostLink.current {
            api.baseURL = link.url; api.token = link.token
        } else {
            api.baseURL = LocalHostProtocol.baseURL; api.token = "local"
        }
        hostEpoch += 1
        #endif
    }

    func loggedIn(token: String) {
        Keychain.write("session", token)
        api.token = token
        isLoggedIn = true
    }

    /// local = 服务器已经不认这个凭证了，只清本机。
    func logout(local: Bool = false) {
        // 先记下凭证再清：以前是清完才发，服务器收到的请求没带凭证（401），那个凭证在服务器上一直没作废
        if !local, let token = api.token {
            let api = self.api
            Task { try? await api.logoutRemote(token: token) }
        }
        Keychain.delete("session")
        api.token = nil
        isLoggedIn = false
    }
}

enum Keychain {
    private static let service = "chat.mele.app"

    static func read(_ key: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: key, kSecReturnData as String: true]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ key: String, _ value: String) {
        delete(key)
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: key, kSecValueData as String: Data(value.utf8),
                                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]
        SecItemAdd(q as CFDictionary, nil)
    }

    static func delete(_ key: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: key]
        SecItemDelete(q as CFDictionary)
    }
}
