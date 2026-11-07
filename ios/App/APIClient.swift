import Foundation

/// 跟服务器说话的唯一出口（正式接口 server/api/）。
/// - 每个请求带 `Authorization: Bearer <登录凭证>`；401 = 凭证失效，交给 SessionStore 退回登录页。
/// - 服务器出错时回 `{"detail": "人话"}`，这里原样变成 APIError 给界面显示。
/// - 时间是 Python 的 isoformat（微秒 + 时区），JSONDecoder 默认认不全，自己解。
struct APIError: LocalizedError {
    let status: Int
    let message: String
    var errorDescription: String? { message }
    var isUnauthorized: Bool { status == 401 }
}

final class APIClient: @unchecked Sendable {
    var baseURL: URL
    var token: String?
    var onUnauthorized: (@Sendable () -> Void)?
    private let session: URLSession

    init(baseURL: URL, token: String? = nil) {
        self.baseURL = baseURL
        self.token = token
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        #if LITE
        // Lite：请求交给手机里的小管家（Lite/LocalHost），不出手机
        cfg.protocolClasses = [LocalHostProtocol.self] + (cfg.protocolClasses ?? [])
        // 小管家想一轮可能很久，给足 600 秒；连着 Mele Host 时还是 30 秒——Host 挂了不能一个请求等十分钟（10-05）
        if baseURL.host == LocalHostProtocol.host { cfg.timeoutIntervalForRequest = 600 }
        #endif
        session = URLSession(configuration: cfg)
    }

    // MARK: - 编解码

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let s = try dec.singleValueContainer().decode(String.self)
            if let date = APIClient.parseDate(s) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: dec.codingPath, debugDescription: "bad date \(s)"))
        }
        return d
    }()

    static func parseDate(_ raw: String) -> Date? {
        // 2026-09-27T12:00:00.123456+00:00 → 小数截到毫秒，ISO8601DateFormatter 才认
        var s = raw
        if let dot = s.firstIndex(of: "."), let end = s[dot...].firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" }) {
            let frac = s[s.index(after: dot)..<end]
            s.replaceSubrange(s.index(after: dot)..<end, with: String(frac.prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0))
        }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    // MARK: - 请求

    private func makeRequest(_ method: String, _ path: String, query: [URLQueryItem] = [], json: Any? = nil) throws -> URLRequest {
        // 路径里自带的「?…」拆出来当参数（11-05 内测：朋友圈封面路径带 ?v=，appendingPathComponent 把 ? 转成 %3F，
        // 取图一直 404，只有刚上传塞进缓存的那张看得见，你和 TA 的封面轮流「掉」）
        let parts = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        var comps = URLComponents(url: baseURL.appendingPathComponent(String(parts[0])), resolvingAgainstBaseURL: false)!
        let inline = parts.count > 1 ? URLComponents(string: "?" + parts[1])?.queryItems ?? [] : []
        if !query.isEmpty || !inline.isEmpty { comps.queryItems = inline + query }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let json {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        return req
    }

    /// 自己拿着去读流的请求（电话的事件流 / 合成的声音流，10-31）
    func request(_ method: String, _ path: String, json: Any? = nil) throws -> URLRequest {
        try makeRequest(method, path, json: json)
    }

    private func check(_ data: Data, _ resp: URLResponse) throws {
        guard let http = resp as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["detail"] as? String
            let err = APIError(status: http.statusCode, message: detail ?? "服务器出错了（\(http.statusCode)）")
            if err.isUnauthorized { onUnauthorized?() }
            throw err
        }
    }

    /// 发一个请求，把回来的 JSON 解成 T。
    func call<T: Decodable>(_ method: String, _ path: String, query: [URLQueryItem] = [], json: Any? = nil,
                            as type: T.Type = T.self) async throws -> T {
        let (data, resp) = try await transport(makeRequest(method, path, query: query, json: json))
        try check(data, resp)
        return try Self.decoder.decode(T.self, from: data)
    }

    /// 回来的 JSON 不先定类型（设置页那种键很多、只改几项的）
    func raw(_ method: String, _ path: String, json: Any? = nil) async throws -> Any {
        let (data, resp) = try await transport(makeRequest(method, path, json: json))
        try check(data, resp)
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    /// 退出登录：带着要作废的那个凭证发（本机的凭证这时已经清了）
    func logoutRemote(token: String) async throws {
        var req = try makeRequest("POST", "auth/logout")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await transport(req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) || http.statusCode == 401 else {
            try check(data, resp); return
        }
    }

    /// 不关心回什么（204 之类）。
    func send(_ method: String, _ path: String, query: [URLQueryItem] = [], json: Any? = nil) async throws {
        let (data, resp) = try await transport(makeRequest(method, path, query: query, json: json))
        try check(data, resp)
    }

    /// 上传一张图或一个文件（multipart）。
    func upload(_ path: String, fileName: String, mime: String, data: Data) async throws -> AttachmentDTO {
        let out = try await multipart("POST", path, fileName: fileName, mime: mime, data: data)
        return try Self.decoder.decode(AttachmentDTO.self, from: out)
    }

    /// 饮食的照片（09-29）：不挂窗口，拿回编号 + 取图路径
    func uploadFoodPhoto(_ data: Data) async throws -> (id: String, path: String) {
        struct Out: Decodable { let id: String; let url: String }
        let out = try await multipart("POST", "food/photo", fileName: "food.jpg", mime: "image/jpeg", data: data)
        let o = try Self.decoder.decode(Out.self, from: out)
        return (o.id, String(o.url.drop(while: { $0 == "/" })))
    }

    /// 换联系人头像（服务器裁成 512 见方），返回新的版本号
    func uploadAvatar(companion: UUID, data: Data) async throws -> Int {
        struct Ver: Decodable { let avatar_ver: Int }
        let out = try await multipart("PUT", "companions/\(companion.uuidString.lowercased())/avatar",
                                      fileName: "avatar.jpg", mime: "image/jpeg", data: data)
        return try Self.decoder.decode(Ver.self, from: out).avatar_ver
    }

    /// 换群头像（10-11）
    func uploadGroupAvatar(group: UUID, data: Data) async throws -> GroupDTO {
        let out = try await multipart("PUT", "groups/\(group.uuidString.lowercased())/avatar",
                                      fileName: "avatar.jpg", mime: "image/jpeg", data: data)
        return try Self.decoder.decode(GroupDTO.self, from: out)
    }

    /// 导入酒馆角色卡（10-01）：preview = 只看不建；否则带上挑好的开场白和文风（chat / long）真导入
    func importCard(_ data: Data, fileName: String, preview: Bool, greeting: Int = 0, style: String = "chat") async throws -> Data {
        let lower = fileName.lowercased()
        let mime = lower.hasSuffix(".json") ? "application/json" : lower.hasSuffix(".txt") ? "text/plain" : "image/png"
        return try await multipart("POST", preview ? "companions/import/preview" : "companions/import", fileName: fileName,
                                   mime: mime, data: data,
                                   fields: preview ? [:] : ["greeting": String(greeting), "style": style])
    }

    private func multipart(_ method: String, _ path: String, fileName: String, mime: String, data: Data,
                           fields: [String: String] = [:]) async throws -> Data {
        var req = try makeRequest(method, path)
        let boundary = "lumi-\(UUID().uuidString)"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        for (k, v) in fields.sorted(by: { $0.key < $1.key }) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(v)\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mime)\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body
        let (out, resp) = try await transport(req)
        try check(out, resp)
        return out
    }

    /// 通用 multipart：几个文字字段 + 几个文件（字段名, 文件名, mime, 数据）（10-01 朋友圈）
    func multipartFields(_ method: String, _ path: String, fields: [String: String],
                         files: [(String, String, String, Data)]) async throws -> Data {
        var req = try makeRequest(method, path)
        let boundary = "lumi-\(UUID().uuidString)"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        for (k, v) in fields.sorted(by: { $0.key < $1.key }) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(v)\r\n".data(using: .utf8)!)
        }
        for (field, name, mime, data) in files {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(field)\"; filename=\"\(name)\"\r\n".data(using: .utf8)!)
            body.append("Content-Type: \(mime)\r\n\r\n".data(using: .utf8)!)
            body.append(data)
            body.append("\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body
        let (out, resp) = try await transport(req)
        try check(out, resp)
        return out
    }

    /// 一次传好几张表情包（10-01）：每张一个 files 字段，原样传（gif 能动）
    func uploadStickers(_ files: [(Data, String, String)]) async throws -> Data {
        var req = try makeRequest("POST", "stickers")
        let boundary = "lumi-\(UUID().uuidString)"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        for (data, name, mime) in files {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"files\"; filename=\"\(name)\"\r\n".data(using: .utf8)!)
            body.append("Content-Type: \(mime)\r\n\r\n".data(using: .utf8)!)
            body.append(data)
            body.append("\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body
        let (out, resp) = try await transport(req)
        try check(out, resp)
        return out
    }

    /// 取一张图（要带凭证，所以不能直接给 AsyncImage 一个网址）。
    func data(_ path: String) async throws -> Data {
        let (data, resp) = try await transport(makeRequest("GET", path))
        try check(data, resp)
        return data
    }

    private func transport(_ req: URLRequest) async throws -> (Data, URLResponse) {
        do { return try await session.data(for: req) }
        catch { throw APIError(status: 0, message: "连不上服务器，检查一下网络") }
    }

    // MARK: - 事件流（Server-Sent Events）

    /// 一直连着的事件流：每来一行 `data: {...}` 就给出一个 ChatEvent；`: ping` 心跳忽略。断了就结束，调用方负责重连。
    func events(conversation: UUID) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var req = try makeRequest("GET", "conversations/\(conversation.uuidString.lowercased())/events")
                    req.timeoutInterval = 3600
                    let (bytes, resp) = try await session.bytes(for: req)
                    if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                        if http.statusCode == 401 { onUnauthorized?() }
                        throw APIError(status: http.statusCode, message: "事件流连不上（\(http.statusCode)）")
                    }
                    for try await line in bytes.lines where line.hasPrefix("data: ") {
                        if let ev = try? Self.decoder.decode(ChatEvent.self, from: Data(line.dropFirst(6).utf8)) {
                            continuation.yield(ev)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
