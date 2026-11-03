import Foundation

public enum EngineEvent: Sendable {
    case thinking(String)          // 到目前为止的完整思考
    case typing                    // 开始出字了
    case bubble(Message)           // 存好的一条气泡
    case sticker(Sticker, Message) // 它发的表情包
    case milestone(Milestone)
    case peekRequest(String)       // 它想翻你的手机：想看什么
    case failed(LLMError)
}

/// key 在钥匙串里怎么起名：Anthropic / Gemini 各一把；OpenAI 兼容按地址分（DeepSeek、OpenRouter 各一把）。
public enum KeyName {
    public static func of(_ c: ProviderConfig) -> String {
        guard c.kind == .openai else { return c.kind.rawValue }
        let host = c.baseURL.flatMap { URL(string: $0)?.host } ?? "api.openai.com"
        return "openai:" + host
    }
}

/// 发一句 → 拼 → 流式 → 解标记 → 切气泡 → 存。界面只管听事件。
@MainActor
public final class ChatEngine {
    let store: LiteStore
    let vault: KeyVault
    let stickers: StickerLibrary
    let lang: Lang
    let clientFactory: (ProviderConfig, String) -> LLMClient
    var now: () -> Date = Date.init

    public init(store: LiteStore, vault: KeyVault, stickers: StickerLibrary, lang: Lang,
                clientFactory: @escaping (ProviderConfig, String) -> LLMClient = { makeClient($0, key: $1) }) {
        self.store = store; self.vault = vault; self.stickers = stickers; self.lang = lang; self.clientFactory = clientFactory
    }

    public func send(_ text: String, image: Data? = nil, quoteOf: String? = nil,
                     contactID: String, identityID: String) -> AsyncStream<EngineEvent> {
        AsyncStream { cont in
            Task { @MainActor in
                do {
                    let file = try image.map { try store.saveImage($0) }
                    try store.append(Message(role: .user, text: text, quoteOf: quoteOf, imageFile: file, at: now()),
                                     contact: contactID, identity: identityID)
                } catch {
                    cont.yield(.failed(.server("存不下：\(error)"))); cont.finish(); return
                }
                await runTurn(contactID: contactID, identityID: identityID, image: image, nudge: nil, peek: nil, cont: cont)
                cont.finish()
            }
        }
    }

    /// 它想查手机，TA 选了给看哪几间（空 = 不给看）。记一笔，再让它说一句。
    public func answerPeek(rooms: Set<PeekRoom>, asked: String, contactID: String, identityID: String) -> AsyncStream<EngineEvent> {
        AsyncStream { cont in
            Task { @MainActor in
                let zh = lang == .zh
                guard let contact = store.contacts().first(where: { $0.id == contactID }),
                      let identity = contact.identities.first(where: { $0.id == identityID }) else { cont.finish(); return }
                if rooms.isEmpty {
                    await runTurn(contactID: contactID, identityID: identityID, image: nil,
                                  nudge: zh ? "（TA 没把手机给你）" : "(They didn't hand you their phone.)", peek: nil, cont: cont)
                } else {
                    try? store.appendPeek(PeekLog(contactID: contactID, identityID: identityID, rooms: PeekRoom.allCases.filter(rooms.contains), asked: asked, at: now()))
                    let snap = PhoneCheck.snapshot(store: store, stickers: stickers, viewer: contact, viewerIdentity: identity, rooms: rooms, lang: lang)
                    await runTurn(contactID: contactID, identityID: identityID, image: nil,
                                  nudge: zh ? "（TA 把手机递给你了）" : "(They handed you their phone.)", peek: snap, cont: cont)
                }
                cont.finish()
            }
        }
    }

    func runTurn(contactID: String, identityID: String, image: Data?, nudge: String?, peek: String?,
                 cont: AsyncStream<EngineEvent>.Continuation) async {
        guard let contact = store.contacts().first(where: { $0.id == contactID }),
              let identity = contact.identities.first(where: { $0.id == identityID }) else { return }
        guard let key = vault.get(KeyName.of(contact.provider)), !key.isEmpty else { cont.yield(.failed(.auth)); return }

        var history = store.messages(contact: contactID, identity: identityID)
        if let nudge { history.append(Message(role: .user, text: nudge, at: now())) }
        let hits = LoreMatcher.hits(entries: store.lore(), recent: history, contactID: contactID)
        let jpeg = image.flatMap { StickerLibrary.jpeg($0, maxSide: 1280) }
        let req = Prompt.build(PromptInput(contact: contact, identity: identity, history: history, loreHits: hits,
                                           stickers: stickers.all(), peekResult: peek, lang: lang, now: now(), currentImage: jpeg))

        var text = "", thinking = "", typing = false
        do {
            for try await e in clientFactory(contact.provider, key).stream(req) {
                switch e {
                case .thinking(let t): thinking += t; cont.yield(.thinking(thinking))
                case .text(let t):
                    if !typing { typing = true; cont.yield(.typing) }
                    text += t
                case .done, .toolCall, .assistantRaw: break      // 这个引擎不给工具
                }
            }
        } catch let e as LLMError {
            cont.yield(.failed(e)); return
        } catch {
            cont.yield(.failed(.network)); return
        }

        let parsed = Markers.parse(text)
        var first = true
        for b in Bubbles.split(parsed.text, offline: contact.mode == .offline) {
            let m = Message(role: .assistant, text: b, thinking: first && !thinking.isEmpty ? thinking : nil, at: now())
            first = false
            try? store.append(m, contact: contactID, identity: identityID)
            cont.yield(.bubble(m))
        }
        let menu = StickerMenu(stickers.all())
        for want in parsed.stickers {
            guard let s = menu.resolve(want) else { continue }
            let tag = lang == .zh ? "[表情包：\(s.caption)]" : "[sticker: \(s.caption)]"
            let m = Message(role: .assistant, text: tag, thinking: first && !thinking.isEmpty ? thinking : nil, stickerID: s.id, at: now())
            first = false
            try? store.append(m, contact: contactID, identity: identityID)
            cont.yield(.sticker(s, m))
        }
        for title in parsed.milestones {
            let ms = Milestone(contactID: contactID, title: title, at: now())
            try? store.appendMilestone(ms)
            cont.yield(.milestone(ms))
        }
        if let ask = parsed.wantsPeek, peek == nil { cont.yield(.peekRequest(ask)) }
    }
}
