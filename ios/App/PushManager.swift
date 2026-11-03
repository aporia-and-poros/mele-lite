import SwiftUI
import UserNotifications

/// 推送（第三块第 3 步，照之前自用的 App PushManager）：要权限 → 拿 APNs 设备号 → 报给服务器 /me/devices；
/// 前台正开着那个窗口就不弹；点通知直接进那个人的那个窗口。
final class PushDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    /// 现在开着哪个窗口（ChatRoom 进出时写）——同一个窗口来的推送不弹
    @MainActor static var openConversation: UUID?
    /// 登录前拿到的设备号先攒着，登录后再报
    static var pendingToken: String? {
        get { UserDefaults.standard.string(forKey: "apnsToken") }
        set { UserDefaults.standard.set(newValue, forKey: "apnsToken") }
    }
    static let openFromPush = Notification.Name("LumiOpenFromPush")

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        #if LITE
        MainActor.assumeIsolated { HostVoIP.shared.start() }   // TA 打来（10-31）：被 VoIP 推送叫醒时也要先挂上
        #endif
        return true
    }

    /// 登录以后才要权限（第一次打开就弹「允许通知」太唐突）
    @MainActor static func requestAndRegister() async {
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        if granted { UIApplication.shared.registerForRemoteNotifications() }
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Self.pendingToken = deviceToken.map { String(format: "%02x", $0) }.joined()
        NotificationCenter.default.post(name: .lumiDeviceToken, object: nil)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        NSLog("[push] register failed: \(error.localizedDescription)")
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        let conv = (notification.request.content.userInfo["conversation"] as? String).flatMap(UUID.init)
        let open = await MainActor.run { Self.openConversation }
        // App 开着时来了它的话：列表 / 主屏卡片的预览跟着刷新（10-13 内测：要点进去再出来才看到最新那句）
        await MainActor.run { NotificationCenter.default.post(name: .lumiWindowsChanged, object: nil) }
        if let conv, conv == open { return [] }          // 人就在这个窗口里，消息自己会出现
        return [.banner, .list, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        if info["room"] as? String == "drawer" {                 // 抽屉解锁（09-28）：点开进抽屉
            await MainActor.run { NotificationCenter.default.post(name: .lumiOpenDrawer, object: nil) }
            return
        }
        if info["room"] as? String == "focus" {                  // 专注提醒（09-29）：点开看还剩多久
            await MainActor.run { NotificationCenter.default.post(name: .lumiOpenFocus, object: nil) }
            return
        }
        if info["group"] as? Bool == true, let conv = (info["conversation"] as? String).flatMap(UUID.init) {   // 群（10-11）
            await MainActor.run {
                NotificationCenter.default.post(name: Self.openFromPush, object: nil, userInfo: ["conversation": conv, "group": true])
            }
            return
        }
        guard let conv = (info["conversation"] as? String).flatMap(UUID.init),
              let comp = (info["companion"] as? String).flatMap(UUID.init) else { return }
        await MainActor.run {
            NotificationCenter.default.post(name: Self.openFromPush, object: nil,
                                            userInfo: ["conversation": conv, "companion": comp])
        }
    }

    /// 回到 app：通知中心里攒的清掉
    @MainActor static func clearDelivered() {
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        Task { try? await UNUserNotificationCenter.current().setBadgeCount(0) }
    }
}

extension Notification.Name {
    static let lumiDeviceToken = Notification.Name("LumiDeviceToken")
}
