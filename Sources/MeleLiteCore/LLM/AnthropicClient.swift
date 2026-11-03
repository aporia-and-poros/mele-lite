import Foundation

/// POST /v1/messages，stream: true。思考：新模型用 adaptive + summarized（能看到思考摘要）；Haiku 4.5 还是 budget_tokens。
/// 工具：tools 照 input_schema 给；它用工具时这一轮的内容块（含思考签名）原样留着，下一轮带着 tool_result 递回去。
struct AnthropicClient: LLMClient {
    let config: ProviderConfig
    let key: String
    let session: URLSession

    func message(_ t: ChatTurn) -> [String: Any] {
        if t.role == .assistant, let raw = t.raw,
           let blocks = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [[String: Any]], !blocks.isEmpty {
            return ["role": "assistant", "content": blocks]
        }
        var content: [[String: Any]] = []
        for r in t.toolResults {
            content.append(["type": "tool_result", "tool_use_id": r.id, "content": r.content])
        }
        if let img = t.imageJPEG {
            content.append(["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": img.base64EncodedString()]])
        }
        if !t.text.isEmpty || content.isEmpty { content.append(["type": "text", "text": t.text]) }
        for c in t.toolCalls { content.append(["type": "tool_use", "id": c.id, "name": c.name, "input": c.arguments]) }
        return ["role": t.role.rawValue, "content": content]
    }

    /// 缓存书签（10-04）：system 末尾、TA 最新那句末尾（context 之前）、这一轮最后一块（用工具来回时）。1 小时档。
    /// 走中转站（11-03）不带 ttl：1 小时档是新参数，中转最可能不认、一不认整句就发不出去；普通 5 分钟档各家都认
    var cacheMark: [String: Any] { config.baseURL?.isEmpty == false ? ["type": "ephemeral"] : ["type": "ephemeral", "ttl": "1h"] }

    func messages(_ r: ChatRequest) -> [[String: Any]] {
        var msgs = r.turns.map(message)
        if let ci = r.contextIndex, var content = msgs[ci]["content"] as? [[String: Any]], !content.isEmpty {
            content[content.count - 1]["cache_control"] = cacheMark
            if !r.context.isEmpty { content.append(["type": "text", "text": r.context]) }
            msgs[ci]["content"] = content
        }
        if let last = msgs.indices.last, last != r.contextIndex, var content = msgs[last]["content"] as? [[String: Any]], !content.isEmpty,
           content[content.count - 1]["type"] as? String != "thinking" {
            content[content.count - 1]["cache_control"] = cacheMark
            msgs[last]["content"] = content
        }
        return msgs
    }

    func body(_ r: ChatRequest) -> [String: Any] {
        var system: [[String: Any]] = []
        if !r.system.isEmpty { system.append(["type": "text", "text": r.system, "cache_control": cacheMark]) }
        if r.contextIndex == nil, !r.context.isEmpty { system.append(["type": "text", "text": r.context]) }
        var b: [String: Any] = [
            "model": config.model,
            "max_tokens": r.maxTokens,
            "stream": true,
            "messages": messages(r),
        ]
        if !system.isEmpty { b["system"] = system }
        if !r.tools.isEmpty {
            b["tools"] = r.tools.map { ["name": $0.name, "description": $0.description, "input_schema": $0.parameters] }
        }
        if config.thinking {
            if config.model.hasPrefix("claude-haiku") {
                b["thinking"] = ["type": "enabled", "budget_tokens": 2048]
            } else {
                b["thinking"] = ["type": "adaptive", "display": "summarized"]
            }
        }
        return b
    }

    /// 中转站的 Claude 原生接口（11-03 一测：中转只能走 OpenAI 那条，没有缓存，每句全价）：
    /// 地址填到域名或 /v1 都行，统一接成 …/v1/messages；没填就是官方
    public static func endpoint(_ base: String?) -> URL {
        var b = (base ?? "").trimmingCharacters(in: .whitespaces)
        while b.hasSuffix("/") { b.removeLast() }
        if b.hasSuffix("/messages") { b.removeLast("/messages".count) }
        if b.hasSuffix("/v1") { b.removeLast(3) }
        return URL(string: (b.isEmpty ? "https://api.anthropic.com" : b) + "/v1/messages") ?? URL(string: "https://api.anthropic.com/v1/messages")!
    }

    func stream(_ r: ChatRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        var req = URLRequest(url: Self.endpoint(config.baseURL))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        if config.baseURL?.isEmpty == false { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }   // 中转站有的认这个
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body(r), options: [.sortedKeys])   // 键顺序固定：Swift 字典每次排法不一样，工具说明一变前缀就对不上、缓存全丢（10-08 Aporia：命中只有两三成）
        let st = StreamState()
        return HTTPStream.run(req, session: session, model: config.model, state: st, parse: { payload in
            let o = try HTTPStream.json(payload)
            let index = o["index"] as? Int ?? 0
            switch o["type"] as? String {
            case "message_start":
                if let u = (o["message"] as? [String: Any])?["usage"] as? [String: Any] {
                    st.lock.withLock {
                        st.usage = Usage(input: u["input_tokens"] as? Int ?? 0, output: u["output_tokens"] as? Int ?? 0,
                                         cacheRead: u["cache_read_input_tokens"] as? Int ?? 0, cacheWrite: u["cache_creation_input_tokens"] as? Int ?? 0)
                    }
                }
                return []
            case "content_block_start":
                var block = o["content_block"] as? [String: Any] ?? [:]
                if block["type"] as? String == "tool_use" { block["_json"] = "" }
                st.lock.withLock { st.open[index] = block }
                return []
            case "content_block_delta":
                let d = o["delta"] as? [String: Any] ?? [:]
                return st.lock.withLock { () -> [StreamEvent] in
                    var b = st.open[index] ?? ["type": "text", "text": ""]
                    defer { st.open[index] = b }
                    switch d["type"] as? String {
                    case "text_delta":
                        let t = d["text"] as? String ?? ""
                        b["type"] = b["type"] ?? "text"
                        b["text"] = (b["text"] as? String ?? "") + t
                        return [.text(t)]
                    case "thinking_delta":
                        let t = d["thinking"] as? String ?? ""
                        b["thinking"] = (b["thinking"] as? String ?? "") + t
                        return [.thinking(t)]
                    case "signature_delta":
                        b["signature"] = (b["signature"] as? String ?? "") + (d["signature"] as? String ?? "")
                        return []
                    case "input_json_delta":
                        b["_json"] = (b["_json"] as? String ?? "") + (d["partial_json"] as? String ?? "")
                        return []
                    default:
                        return []
                    }
                }
            case "content_block_stop":
                return st.lock.withLock { () -> [StreamEvent] in
                    guard var b = st.open.removeValue(forKey: index) else { return [] }
                    var out: [StreamEvent] = []
                    if b["type"] as? String == "tool_use" {
                        let json = (b.removeValue(forKey: "_json") as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "{}"
                        b["input"] = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) ?? [String: Any]()
                        out.append(.toolCall(ToolCall(id: b["id"] as? String ?? UUID().uuidString, name: b["name"] as? String ?? "", argumentsJSON: json)))
                    }
                    st.blocks.append(b)
                    return out
                }
            case "message_delta":
                if ((o["delta"] as? [String: Any])?["stop_reason"] as? String) == "refusal" { throw LLMError.refused }
                if let out = (o["usage"] as? [String: Any])?["output_tokens"] as? Int {
                    st.lock.withLock { st.usage = st.usage.map { var u = $0; u.output = out; return u } ?? Usage(input: 0, output: out) }
                }
                return []
            case "message_stop":
                return [.done(nil)]
            case "error":
                let e = o["error"] as? [String: Any]
                if (e?["type"] as? String) == "overloaded_error" { throw LLMError.server("overloaded") }
                throw LLMError.server(e?["message"] as? String ?? "error")
            default:
                return []
            }
        }, finish: {
            st.lock.withLock {
                let blocks = st.blocks + st.open.keys.sorted().compactMap { st.open[$0] }
                return blocks.isEmpty ? [] : [.assistantRaw(HTTPStream.string(blocks))]
            }
        })
    }
}
