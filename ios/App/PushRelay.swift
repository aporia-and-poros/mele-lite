import Foundation

/// Mele Host 推送中转（10-04 第四步）：苹果推送钥匙只在Aporia的中转站（relay/worker.js）。
/// 连着 Host 的 Lite：拿到苹果设备号 → 去中转站登记 → 拿到编号和口令 → 连同一把这台手机自己生成的加密钥匙交给自己的 Host。
/// Host 推送时用这把钥匙加密，中转只转发密文；手机的通知扩展（LiteNotify）用同一把钥匙解开。钥匙放在 App Group 里给扩展读。
enum PushRelay {
    static let base = URL(string: "https://mele-push.meleapp.workers.dev")!
    static let group = "group.chat.mele.app"
    private static var shared: UserDefaults { UserDefaults(suiteName: group) ?? .standard }

    #if DEBUG
    static let sandbox = true                  // Xcode 直接装的走苹果的沙盒；TestFlight / App Store 走正式
    #else
    static let sandbox = false
    #endif

    /// 这台手机的推送加密钥匙（32 字节，base64）；第一次用时生成
    static var pushKey: String {
        if let k = shared.string(forKey: "push.key") { return k }
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let k = Data(bytes).base64EncodedString()
        shared.set(k, forKey: "push.key")
        return k
    }

    /// 去中转站登记这个设备号（同一个设备号登记过就用存着的）。返回 (编号, 口令)
    /// voip = 来电用的那个设备号（10-31，PushKit）：中转站只往它身上推来电
    static func register(token: String, voip: Bool = false) async -> (id: String, secret: String)? {
        let d = UserDefaults.standard
        let p = voip ? "relay.voip." : "relay."
        if d.string(forKey: p + "token") == token, let id = d.string(forKey: p + "id"), let s = d.string(forKey: p + "secret") {
            return (id, s)
        }
        var req = URLRequest(url: base.appendingPathComponent("register"), timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["token": token, "sandbox": sandbox, "voip": voip])
        guard let (data, resp) = try? await URLSession.shared.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200,
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = j["relay_id"] as? String, let secret = j["relay_secret"] as? String else { return nil }
        d.set(token, forKey: p + "token"); d.set(id, forKey: p + "id"); d.set(secret, forKey: p + "secret")
        return (id, secret)
    }
}
