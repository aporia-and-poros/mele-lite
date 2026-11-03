import Foundation
import Testing
@testable import MeleLiteCore

private func run(_ cfg: ProviderConfig, _ reply: StubProtocol.Reply, image: Data? = nil) async throws -> (String, String, String) {
    let token = UUID().uuidString
    let client = makeClient(cfg, key: "k-test", session: StubProtocol.session(token: token, reply: reply))
    let req = ChatRequest(system: "你是 Lumi", turns: [ChatTurn(role: .user, text: "在吗", imageJPEG: image)])
    let (t, th) = try await collect(client.stream(req))
    return (t, th, token)
}

@Suite struct LLMClientTests {
    let anthropic = ProviderConfig(kind: .anthropic, model: "claude-opus-5-5", thinking: true)
    let openai = ProviderConfig(kind: .openai, baseURL: "https://api.deepseek.com/v1/", model: "deepseek-reasoner")
    let gemini = ProviderConfig(kind: .gemini, model: "gemini-3.5-flash", thinking: true)

    @Test func anthropicStream() async throws {
        let sse = """
        event: message_start
        data: {"type":"message_start","message":{"usage":{"input_tokens":10}}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"她在问"}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"在"}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"呀"}}

        event: message_stop
        data: {"type":"message_stop"}

        """
        let (t, th, token) = try await run(anthropic, .init(status: 200, body: sse))
        #expect(t == "在呀")
        #expect(th == "她在问")
        let r = StubProtocol.request(token)!
        #expect(r.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(r.value(forHTTPHeaderField: "x-api-key") == "k-test")
        #expect(r.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        let body = StubProtocol.bodyJSON(token)
        #expect((body["thinking"] as? [String: Any])?["type"] as? String == "adaptive")
        let sys = body["system"] as? [[String: Any]]
        #expect(sys?.first?["text"] as? String == "你是 Lumi")
        #expect((sys?.first?["cache_control"] as? [String: Any])?["ttl"] as? String == "1h")
    }

    @Test func usageReported() async throws {
        let sse = """
        data: {"type":"message_start","message":{"usage":{"input_tokens":12,"cache_read_input_tokens":3000,"cache_creation_input_tokens":40,"output_tokens":1}}}

        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"嗯"}}

        data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":25}}

        data: {"type":"message_stop"}

        """
        let token = UUID().uuidString
        let client = makeClient(anthropic, key: "k", session: StubProtocol.session(token: token, reply: .init(status: 200, body: sse)))
        var got: Usage?
        for try await e in client.stream(ChatRequest(system: "", turns: [ChatTurn(role: .user, text: "在吗")])) {
            if case .done(let u) = e { got = u }
        }
        #expect(got == Usage(input: 12, output: 25, cacheRead: 3000, cacheWrite: 40))
        #expect(got?.prompt == 3052)
    }

    @Test func anthropicCacheMarksAndContext() {
        let c = AnthropicClient(config: anthropic, key: "k", session: .shared)
        let req = ChatRequest(system: "底子", turns: [ChatTurn(role: .user, text: "早"), ChatTurn(role: .assistant, text: "早呀"),
                                                     ChatTurn(role: .user, text: "在干嘛")], context: "现在是 08:00")
        let msgs = c.body(req)["messages"] as! [[String: Any]]
        let last = msgs.last!["content"] as! [[String: Any]]
        #expect(last.count == 2)
        #expect(last[0]["text"] as? String == "在干嘛" && last[0]["cache_control"] != nil)      // 书签在 TA 那句末尾
        #expect(last[1]["text"] as? String == "现在是 08:00" && last[1]["cache_control"] == nil) // 每轮变的贴在后面、不进缓存
        #expect((msgs[0]["content"] as! [[String: Any]])[0]["cache_control"] == nil)
    }

    @Test func anthropicImageAndRefusal() async throws {
        let sse = "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"refusal\"}}\n"
        let token = UUID().uuidString
        let client = makeClient(anthropic, key: "k", session: StubProtocol.session(token: token, reply: .init(status: 200, body: sse)))
        await #expect(throws: LLMError.refused) {
            _ = try await collect(client.stream(ChatRequest(system: "", turns: [ChatTurn(role: .user, text: "看", imageJPEG: Data([1, 2, 3]))])))
        }
        let msgs = StubProtocol.bodyJSON(token)["messages"] as? [[String: Any]]
        let first = (msgs?.first?["content"] as? [[String: Any]])?.first
        #expect(first?["type"] as? String == "image")
    }

    @Test func openAICompatibleStream() async throws {
        let sse = """
        data: {"choices":[{"delta":{"reasoning_content":"想想"}}]}

        data: {"choices":[{"delta":{"content":"好"}}]}

        data: {"choices":[{"delta":{"content":"的"}}]}

        data: [DONE]

        """
        let (t, th, token) = try await run(openai, .init(status: 200, body: sse), image: Data([9]))
        #expect(t == "好的")
        #expect(th == "想想")
        let r = StubProtocol.request(token)!
        #expect(r.url?.absoluteString == "https://api.deepseek.com/v1/chat/completions")
        #expect(r.value(forHTTPHeaderField: "authorization") == "Bearer k-test")
        let msgs = StubProtocol.bodyJSON(token)["messages"] as? [[String: Any]]
        #expect(msgs?.first?["role"] as? String == "system")
        let parts = msgs?.last?["content"] as? [[String: Any]]
        #expect((parts?.last?["image_url"] as? [String: Any])?["url"] as? String == "data:image/jpeg;base64,CQ==")
    }

    @Test func geminiStream() async throws {
        let sse = """
        data: {"candidates":[{"content":{"parts":[{"text":"先想一下","thought":true}]}}]}

        data: {"candidates":[{"content":{"parts":[{"text":"你好"}]}}]}

        """
        let (t, th, token) = try await run(gemini, .init(status: 200, body: sse))
        #expect(t == "你好")
        #expect(th == "先想一下")
        let r = StubProtocol.request(token)!
        #expect(r.url?.absoluteString.contains("models/gemini-3.5-flash:streamGenerateContent?alt=sse") == true)
        #expect(r.value(forHTTPHeaderField: "x-goog-api-key") == "k-test")
        let body = StubProtocol.bodyJSON(token)
        #expect((body["contents"] as? [[String: Any]])?.first?["role"] as? String == "user")
    }

    @Test func creditVsRateLimit() {
        #expect(HTTPStream.errorFor(status: 429, body: #"{"error":{"message":"Rate limit reached"}}"#) == .quota)
        #expect(HTTPStream.errorFor(status: 429, body: #"{"error":{"code":"insufficient_quota","message":"You exceeded your current quota"}}"#)
                == .server(#"HTTP 429: {"error":{"code":"insufficient_quota","message":"You exceeded your current quota"}}"#))
        if case .server = HTTPStream.errorFor(status: 402, body: "Insufficient Balance") {} else { Issue.record("402 应该带原话") }
    }

    @Test(arguments: [(401, LLMError.auth), (429, LLMError.quota)])
    func statusErrors(status: Int, expected: LLMError) async throws {
        await #expect(throws: expected) { _ = try await run(openai, .init(status: status, body: "{\"error\":\"x\"}")) }
    }

    @Test func serverError() async throws {
        do { _ = try await run(gemini, .init(status: 500, body: "boom")); Issue.record("没报错") }
        catch let e as LLMError { if case .server = e {} else { Issue.record("不是 server：\(e)") } }
    }

    @Test func dropMidway() async throws {
        let sse = "data: {\"choices\":[{\"delta\":{\"content\":\"一半\"}}]}\n\n"
        await #expect(throws: LLMError.network) { _ = try await run(openai, .init(status: 200, body: sse, failMidway: true)) }
    }

    @Test func deepSeekThinkingSwitch() {
        let off = OpenAIClient(config: ProviderConfig(kind: .openai, baseURL: "https://api.deepseek.com", model: "deepseek-flash", thinking: false),
                               key: "k", session: .shared)
        #expect((off.body(ChatRequest(system: "s", turns: []))["thinking"] as? [String: String])?["type"] == "disabled")
        let on = OpenAIClient(config: ProviderConfig(kind: .openai, baseURL: "https://api.deepseek.com", model: "deepseek-flash", thinking: true),
                              key: "k", session: .shared)
        #expect((on.body(ChatRequest(system: "s", turns: []))["thinking"] as? [String: String])?["type"] == "enabled")
        let gpt = OpenAIClient(config: ProviderConfig(kind: .openai, model: "gpt-5"), key: "k", session: .shared)
        #expect(gpt.body(ChatRequest(system: "s", turns: []))["thinking"] == nil)       // 别家不认这个字段
    }

    @Test func deepSeekPrefixGoesToBetaWithoutTools() {      // 10-12：漏写独白时补叫，开头填 [独白]
        let ds = OpenAIClient(config: ProviderConfig(kind: .openai, baseURL: "https://api.deepseek.com/v1", model: "deepseek-flash", thinking: false),
                              key: "k", session: .shared)
        let tool = ToolSpec(name: "remember", description: "d", parametersJSON: "{}")
        var r = ChatRequest(system: "s", turns: [ChatTurn(role: .user, text: "hi")], tools: [tool])
        #expect(ds.endpoint(for: r).absoluteString == "https://api.deepseek.com/v1/chat/completions")
        #expect(ds.body(r)["tools"] != nil)
        r.assistantPrefix = "[独白]\n"
        #expect(ds.endpoint(for: r).absoluteString == "https://api.deepseek.com/beta/chat/completions")
        let b = ds.body(r)
        #expect(b["tools"] == nil)                                  // DeepSeek：前缀续写不能带工具
        let last = (b["messages"] as? [[String: Any]])?.last
        #expect(last?["role"] as? String == "assistant" && last?["content"] as? String == "[独白]\n" && last?["prefix"] as? Bool == true)
        let gpt = OpenAIClient(config: ProviderConfig(kind: .openai, model: "gpt-5"), key: "k", session: .shared)
        #expect(gpt.endpoint(for: r) == gpt.endpoint && gpt.body(r)["tools"] != nil)   // 别家不认：原样发
        #expect(((gpt.body(r)["messages"] as? [[String: Any]])?.last?["role"] as? String) == "user")
    }

    @Test func defaultOpenAIBase() {
        let c = OpenAIClient(config: ProviderConfig(kind: .openai, model: "gpt-5"), key: "k", session: .shared)
        #expect(c.endpoint.absoluteString == "https://api.openai.com/v1/chat/completions")
    }
}

/// 中转站的 Claude 原生接口（11-03）：地址怎么填都接成 …/v1/messages
@Test func anthropicRelayEndpoint() {
    #expect(AnthropicClient.endpoint(nil).absoluteString == "https://api.anthropic.com/v1/messages")
    #expect(AnthropicClient.endpoint("").absoluteString == "https://api.anthropic.com/v1/messages")
    for b in ["https://aihubmix.com", "https://aihubmix.com/", "https://aihubmix.com/v1", "https://aihubmix.com/v1/", "https://aihubmix.com/v1/messages"] {
        #expect(AnthropicClient.endpoint(b).absoluteString == "https://aihubmix.com/v1/messages", "\(b)")
    }
}
