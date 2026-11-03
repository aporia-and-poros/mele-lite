#if LITE
import AVFoundation
import CryptoKit
import LiveCommunicationKit
import PushKit
import UIKit

/// 连着 Mele Host 时 TA 打给你（10-31 第 4 步）：VoIP 推送 + 系统来电横幅（LiveCommunicationKit），锁屏也响。
/// - 开机就挂上 PushKit（App 被推送叫醒时也要先有它）。拿到 VoIP 设备号 → 去推送中转站登记（voip: true）→ 编号、口令交给 Host
/// - 推送来了：苹果规定必须马上报一个来电，不然 App 会被系统罚、以后收不到。所以推送里只有谁打来、通话编号（加密的），
///   解开就报；解不开、或者现在没连着 Host，也先报再立刻挂掉
/// - 系统横幅上接 / 拒 → IncomingCalls.accept / decline；Host 那边结束了（未接、撤回）→ 横幅跟着收
@MainActor
final class HostVoIP: NSObject {
    static let shared = HostVoIP()

    private var registry: PKPushRegistry?
    private let manager = ConversationManager(configuration: .init(
        ringtoneName: nil, iconTemplateImageData: nil, maximumConversationGroups: 1, maximumConversationsPerConversationGroup: 1,
        includesConversationInRecents: false, supportsVideo: false, supportedHandleTypes: [.generic]))
    /// 系统那边的通话号 ↔ Host 的通话编号
    private var calls: [UUID: String] = [:]
    static let tokenKey = "voipToken"

    func start() {
        guard registry == nil else { return }
        manager.delegate = self
        let r = PKPushRegistry(queue: .main)
        r.delegate = self
        r.desiredPushTypes = [.voIP]
        registry = r
        let center = IncomingCalls.shared
        center.onSystemRingEnded = { [weak self] id in self?.end(id, .unanswered) }
        center.onSystemCallEnded = { [weak self] id in self?.end(id, .remoteEnded) }
    }

    /// 连着 Host 时把 VoIP 设备号登记上（App 打开时、拿到新设备号时各一次）
    func report(api: APIClient) async {
        guard Lite.hosted, let token = UserDefaults.standard.string(forKey: Self.tokenKey) else { return }
        let mark = "\(token)|\(UserDefaults.standard.string(forKey: HostLink.urlKey) ?? "")"
        guard UserDefaults.standard.string(forKey: "voip.reported") != mark else { return }
        var ok = false
        if let relay = await PushRelay.register(token: token, voip: true) {
            ok = (try? await api.send("POST", "me/voip", json: ["relay_id": relay.id, "relay_secret": relay.secret,
                                                               "push_key": PushRelay.pushKey])) != nil
        } else {
            // 手机连不上中转站（国内打不开 workers.dev）：交给自己的 Host 去登记
            ok = (try? await api.send("POST", "me/voip/relay", json: ["token": token, "sandbox": PushRelay.sandbox,
                                                                     "push_key": PushRelay.pushKey])) != nil
        }
        if ok { UserDefaults.standard.set(mark, forKey: "voip.reported") }
    }

    private func end(_ callID: String, _ reason: Conversation.EndedReason) {
        guard let uuid = calls.first(where: { $0.value == callID })?.key,
              let c = manager.conversations.first(where: { $0.uuid == uuid }) else { return }
        manager.reportConversationEvent(.conversationEnded(Date(), reason), for: c)
        calls[uuid] = nil
    }

    /// 推送里的东西（Host 用这台手机的钥匙加密，跟普通推送同一把）
    nonisolated static func open(_ payload: [AnyHashable: Any]) -> [String: Any]? {
        guard let sealed = payload["sealed"] as? String,
              let keyB64 = UserDefaults(suiteName: PushRelay.group)?.string(forKey: "push.key"),
              let key = Data(base64Encoded: keyB64), let raw = Data(base64Encoded: sealed),
              let box = try? AES.GCM.SealedBox(combined: raw),
              let plain = try? AES.GCM.open(box, using: SymmetricKey(data: key)) else { return nil }
        return try? JSONSerialization.jsonObject(with: plain) as? [String: Any]
    }

    /// Host 的通话编号是 32 位十六进制：直接当系统的通话号用
    nonisolated static func uuid(_ callID: String) -> UUID {
        let h = callID.replacingOccurrences(of: "-", with: "")
        guard h.count == 32 else { return UUID() }
        let a = Array(h)
        let s = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { String(a[$0]) }.joined(separator: "-")
        return UUID(uuidString: s) ?? UUID()
    }

    private func incoming(_ payload: [AnyHashable: Any]) async {
        let inner = Self.open(payload)
        let callID = inner?["call"] as? String ?? ""
        let uuid = Self.uuid(callID)
        let name = inner?["name"] as? String ?? "Mele"
        let update = Conversation.Update(members: [Handle(type: .generic, value: inner?["companion"] as? String ?? "mele",
                                                          displayName: name)])
        do { try await manager.reportNewIncomingConversation(uuid: uuid, update: update) } catch {
            NSLog("[voip] 报来电失败：\(error)")
            return
        }
        guard Lite.hosted, let inner, !callID.isEmpty, let conv = inner["conversation"] as? String,
              !IncomingCalls.shared.busy else {
            // 解不开 / 没连着 Host / 正在打着另一通：报了就挂（苹果要先报）
            if let c = manager.conversations.first(where: { $0.uuid == uuid }) {
                manager.reportConversationEvent(.conversationEnded(Date(), .failed), for: c)
            }
            return
        }
        calls[uuid] = callID
        IncomingCalls.shared.incomingFromHost(callID: callID, conversation: conv,
                                              companion: inner["companion"] as? String ?? "", reason: inner["reason"] as? String ?? "")
    }
}

extension HostVoIP: PKPushRegistryDelegate {
    nonisolated func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
        let token = pushCredentials.token.map { String(format: "%02x", $0) }.joined()
        MainActor.assumeIsolated {
            UserDefaults.standard.set(token, forKey: Self.tokenKey)
            if let api = IncomingCalls.shared.api { Task { await self.report(api: api) } }
        }
    }

    nonisolated func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload,
                                  for type: PKPushType, completion: @escaping () -> Void) {
        let dict = payload.dictionaryPayload
        MainActor.assumeIsolated {
            Task {
                await self.incoming(dict)
                completion()
            }
        }
    }
}

extension HostVoIP: ConversationManagerDelegate {
    nonisolated func conversationManager(_ manager: ConversationManager, conversationChanged conversation: Conversation) {}
    nonisolated func conversationManagerDidBegin(_ manager: ConversationManager) {}
    nonisolated func conversationManagerDidReset(_ manager: ConversationManager) {}
    nonisolated func conversationManager(_ manager: ConversationManager, timedOutPerforming action: ConversationAction) {}
    nonisolated func conversationManager(_ manager: ConversationManager, didActivate audioSession: AVAudioSession) {}
    nonisolated func conversationManager(_ manager: ConversationManager, didDeactivate audioSession: AVAudioSession) {}

    nonisolated func conversationManager(_ manager: ConversationManager, perform action: ConversationAction) {
        let uuid = action.conversationUUID
        Task { @MainActor in
            let center = IncomingCalls.shared
            let id = self.calls[uuid]
            if let join = action as? JoinConversationAction {
                guard let id, center.ringing?.id == id else { join.fail(); return }
                join.fulfill(dateConnected: Date())
                center.accept()
            } else if let end = action as? EndConversationAction {
                end.fulfill(dateEnded: Date())
                self.calls[uuid] = nil
                if let id, center.ringing?.id == id { center.decline() }
                else if let id, center.answered?.id == id { center.hangUpFromSystem() }
            } else {
                action.fulfill()
            }
        }
    }
}
#endif
