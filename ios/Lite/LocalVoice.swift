#if LITE
import CryptoKit
import Foundation
import MeleLiteCore

/// 声音（10-04 Aporia：声音不用服务器，填自己的 ElevenLabs key 就行）：照 server/api/routes_voice.py + brain/voice.py + brain/voice_in.py 搬进手机。
/// - 钥匙只认用户自己的 ElevenLabs key（钥匙串里 "elevenlabs"）；没有我们出钱的额度。没 key = 不发语音条、不念、不收语音。
/// - 它在回复里用 🎤 开头标一段 → 那段自己成一条 → 先落一个占位的语音条（lazy_voice：编号 + 估的秒数，不花钱）；
///   TA 点了才念（10-31 按需念），念好存成 voice-<id>.mp3，挂在那条消息的 voice_clips 上（按文字指纹）。
/// - 念过的按「文字 + 嗓子 + 模型」指纹存在 voice-cache.json，同一句再念不花钱。
/// - TA 发语音：Scribe 转文字 + 量语速、停顿、笑和叹气（跟 TA 自己最近 20 条比）→ 附件 kind=voice，caption 是〔语音 12 秒：…〕那行。
/// 11-08 加 MiniMax（照 server/llm/tts.py 的 MiniMax）：钥匙串里 "minimax"（+ "minimax-base" 记它是国内版还是国际版的地址），
/// TA 设定里 voice_provider 选哪家；两家的嗓子、模型各存各的格子（voice_id / mm_voice_id …），换回来还是原来那把。
enum LocalVoice {
    static let mark = "🎤"
    static let keyID = "elevenlabs"
    static let mmKeyID = "minimax"
    static let mmBaseID = "minimax-base"
    static let providers = ["elevenlabs", "minimax"]
    static let noteModel = "eleven_v4"
    static let defaultTag = "[warm, relaxed, natural] "     // 稿子里一个标签都没有时先垫这一个（10-03 Aporia A/B）
    /// 语音条能选的模型（11-07，内测）：照 server/llm/tts.py。key 没开「看模型」权限时就给这张表
    static let modelChoices: [(id: String, name: String)] = [
        ("eleven_v4", "Eleven v4"), ("eleven_v4_turbo", "Eleven v4 Turbo"), ("eleven_v3", "Eleven v3"),
        ("eleven_v3_conversational", "Eleven v3 Conversational"), ("eleven_multilingual_v2", "Multilingual v2"),
        ("eleven_flash_v2_5", "Flash v2.5"), ("eleven_turbo_v2_5", "Turbo v2.5"),
    ]
    static let presets: [(key: String, id: String, name: String, gender: String, zh: String, en: String)] = [
        ("lauren", "DODLEQrClDo8wCz460ld", "Lauren", "female", "温柔、让人安心", "friendly, comforting, soft"),
        ("hope", "uYXf8XasLslADfZ2MB4u", "Hope", "female", "明亮、活泼、爱聊天", "bubbly, chatty, bright"),
        ("andrew", "SF9uvIlY93SJRMdV5jeP", "Andrew", "male", "清亮、有劲儿（原本是足球解说）", "clear and lively (a football commentator by trade)"),
        ("jon", "Cz0K1kOv9tD8l0b5Qu53", "Jon", "male", "低沉、松弛、好亲近", "relaxed, deep, approachable"),
    ]
    /// MiniMax 出厂的几把（照 server brain/voice.MM_PRESETS）：只挑国内版、国际版两边都有的官方嗓子。按 TA 的语言给，第一把 = 默认。
    /// 没有现成试听：设置页点试听时拿用户自己的 key 念一句（voice/sample，念过存着）。
    static let mmPresets: [String: [(key: String, id: String, name: String, gender: String, zh: String, en: String)]] = [
        "zh": [("mm-warm-girl", "Chinese (Mandarin)_Warm_Girl", "温暖少女", "female", "温暖、亲近", "warm and close"),
               ("mm-sweet-lady", "Chinese (Mandarin)_Sweet_Lady", "甜美女声", "female", "甜、柔", "sweet and soft"),
               ("mm-gentle-youth", "Chinese (Mandarin)_Gentle_Youth", "温润青年", "male", "年轻、温和", "young and gentle"),
               ("mm-gentleman", "Chinese (Mandarin)_Gentleman", "温润男声", "male", "成熟、稳", "mature and steady")],
        "en": [("mm-graceful-lady", "English_Graceful_Lady", "Graceful Lady", "female", "优雅、从容", "graceful, unhurried"),
               ("mm-whispering-girl", "English_Whispering_girl", "Whispering Girl", "female", "轻、带气声", "soft and breathy"),
               ("mm-gentle-man", "English_Gentle-voiced_man", "Gentle-voiced Man", "male", "温和的男声", "gentle male voice"),
               ("mm-diligent-man", "English_Diligent_Man", "Diligent Man", "male", "踏实、清楚", "steady and clear")],
    ]
    static let sampleLine = ["zh": "嗨，是我。今天过得怎么样？", "en": "Hey, it's me. How was your day?"]
    static let errors = ["no_key": String(localized: "先在 TA 的设定 → 声音里填你自己的 ElevenLabs key"),
                         "auth": String(localized: "ElevenLabs 的 key 不对或者没开权限"),
                         "quota": String(localized: "ElevenLabs 那边额度用完了"),
                         "server": String(localized: "ElevenLabs 那边出错了，等会儿再试"),
                         "network": String(localized: "连不上 ElevenLabs"),
                         "bad_request": String(localized: "这句念不了"),
                         "too_long": String(localized: "语音最长 2 分钟"),
                         "voice_not_found": String(localized: "ElevenLabs 找不到这把嗓子，检查一下音色 ID"),
                         "model_not_found": String(localized: "这把 key 用不了这个模型，换一个试试"),
                         "missing_permissions": String(localized: "这把 ElevenLabs key 少了权限：在 ElevenLabs 后台给它打开 Text to Speech、Speech to Text 和 Voices"),
                         "sensitive": String(localized: "ElevenLabs 说这句内容过不了审，念不了"),
                         "slots": String(localized: "ElevenLabs 的声音位满了，先在那边删掉一把再存")]

    /// 提示里的「ElevenLabs」按这家换掉
    static func errorText(_ kind: String, provider: String = "elevenlabs") -> String {
        let t = errors[kind] ?? kind
        return provider == "minimax" ? t.replacingOccurrences(of: "ElevenLabs", with: "MiniMax") : t
    }

    struct Fail: Error { let kind: String }

    /// ElevenLabs 回的错归一类。这几种它说得清楚，单独拎出来提示才说得准（missing_permissions：10-04 实测，只开了部分权限的 key）
    static func failKind(status: Int, body: Data) -> String {
        let text = String(decoding: body, as: UTF8.self)
        if let named = ["missing_permissions", "voice_not_found", "model_not_found"].first(where: { text.contains($0) }) { return named }
        return [401, 403].contains(status) ? "auth" : [402, 429].contains(status) ? "quota" : status < 500 ? "bad_request" : "server"
    }

    // MARK: 路由

    static func handle(_ r: LocalRequest, host: LocalHost) async -> LocalResponse? {
        let p = r.parts
        switch (r.method, p.count) {
        case ("GET", 2) where p == ["voice", "presets"]:
            let en = r.query["lang"] == "en"
            if r.query["provider"] == "minimax" {
                return .json((mmPresets[en ? "en" : "zh"] ?? []).map { ["key": $0.key, "voice_id": $0.id, "name": $0.name, "gender": $0.gender,
                                                                        "about": en ? $0.en : $0.zh, "preview": samplePath($0.id, lang: en ? "en" : "zh")] })
            }
            return .json(presets.map { ["key": $0.key, "voice_id": $0.id, "name": $0.name, "gender": $0.gender,
                                        "about": en ? $0.en : $0.zh, "preview": "voice/presets/\($0.key)/preview?lang=\(en ? "en" : "zh")"] })
        case ("GET", 2) where p == ["voice", "sample"]:
            return await sample(host, voiceID: r.query["voice_id"] ?? "", provider: provider(r.query["provider"] ?? "minimax"),
                                lang: r.query["lang"] == "en" ? "en" : "zh")
        case ("GET", 4) where p[0] == "voice" && p[1] == "presets" && p[3] == "preview":
            let lang = r.query["lang"] == "en" ? "en" : "zh"
            guard presets.contains(where: { $0.key == p[2] }),
                  let url = Bundle.main.url(forResource: "\(p[2])-\(lang)", withExtension: "mp3"),
                  let d = try? Data(contentsOf: url) else { return .error(404, String(localized: "没有这把")) }
            return .data(d, mime: "audio/mpeg")
        case ("GET", 2) where p == ["voice", "library"]:
            return await library(host, provider: provider(r.query["provider"]), lang: r.query["lang"] == "en" ? "en" : "zh")
        case ("GET", 2) where p == ["voice", "models"]:
            return await models(host, provider: provider(r.query["provider"]))
        case ("GET", 2) where p == ["voice", "quota"]:
            return .json(["chars_left": 0, "own_key": key(host, provider: provider(r.query["provider"])) != nil])
        case ("POST", 2) where p == ["keys", "elevenlabs"]:
            return await saveKey(host, r.json["api_key"] as? String ?? "")
        case ("POST", 2) where p == ["keys", "minimax"]:
            return await saveMiniMaxKey(host, r.json["api_key"] as? String ?? "")
        case ("POST", 2) where p == ["voice", "design"]:
            return await design(host, r.json["description"] as? String ?? "", provider: provider(r.json["provider"] as? String))
        case ("POST", 3) where p[0] == "companions" && p[2] == "voice":
            return await choose(host, companion: p[1], r.json)
        case ("GET", 3) where p[0] == "voice" && p[1] == "clips":
            guard let d = try? Data(contentsOf: host.store.fileURL("voice-\(p[2]).mp3")) else { return .error(404, String(localized: "没有这段")) }
            return .data(d, mime: "audio/mpeg")
        case ("POST", 3) where p[0] == "messages" && p[2] == "speak":
            return await speakMessage(host, Int(p[1]) ?? -1, index: r.json["index"] as? Int ?? -1)
        case ("POST", 3) where p[0] == "conversations" && p[2] == "voice":
            return await receive(host, conversation: p[1], r)
        default: return nil
        }
    }

    static func key(_ host: LocalHost, provider: String = "elevenlabs") -> String? {
        let k = host.vault.get(provider == "minimax" ? mmKeyID : keyID)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (k?.isEmpty ?? true) ? nil : k
    }

    /// 认得的那家，别的一律当 ElevenLabs（老 App 不带 provider）
    static func provider(_ raw: String?) -> String { raw == "minimax" ? "minimax" : "elevenlabs" }
    static func provider(_ settings: [String: Any]) -> String { provider(settings["voice_provider"] as? String) }

    /// 这个 TA 现在能不能出声：它用的那家有 key
    static func hasKey(_ host: LocalHost, _ settings: [String: Any]) -> Bool { key(host, provider: provider(settings)) != nil }

    static func minimax(_ host: LocalHost) -> MiniMax? {
        guard let k = key(host, provider: "minimax") else { return nil }
        return MiniMax(key: k, base: host.vault.get(mmBaseID) ?? MiniMax.hosts["intl"]!)
    }

    /// 那家的接头（没 key 就抛 no_key）
    static func engine(_ host: LocalHost, provider: String) throws -> any VoiceEngine {
        if provider == "minimax" {
            guard let m = minimax(host) else { throw Fail(kind: "no_key") }
            return m
        }
        guard let k = key(host) else { throw Fail(kind: "no_key") }
        return ElevenLabs(key: k)
    }

    static func samplePath(_ voiceID: String, lang: String, provider: String = "minimax") -> String {
        var c = URLComponents()
        c.path = "voice/sample"
        c.queryItems = [URLQueryItem(name: "provider", value: provider), URLQueryItem(name: "voice_id", value: voiceID),
                        URLQueryItem(name: "lang", value: lang)]
        return c.string ?? "voice/sample"
    }

    private static func err(_ kind: String, provider: String = "elevenlabs") -> LocalResponse { .error(400, errorText(kind, provider: provider)) }

    private static func saveKey(_ host: LocalHost, _ raw: String) async -> LocalResponse {
        let k = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard k.count >= 20 else { return .error(400, String(localized: "这不像一把 ElevenLabs key")) }
        do { _ = try await ElevenLabs(key: k).request("GET", "/v1/models") }
        catch let f as Fail where f.kind == "missing_permissions" {}      // 认得这把 key，只是没开「看模型」：照收
        catch let f as Fail { return err(f.kind) } catch { return err("network") }
        host.vault.set(k, for: keyID)
        return .json(["last4": String(k.suffix(4))], status: 201)
    }

    /// MiniMax 的 key（11-08）：国内版、国际版两边都试，认得的那边记下来
    private static func saveMiniMaxKey(_ host: LocalHost, _ raw: String) async -> LocalResponse {
        let k = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard k.count >= 20 else { return .error(400, String(localized: "这不像一把 MiniMax key")) }
        let region: String
        do { region = try await MiniMax.region(for: k) } catch let f as Fail { return err(f.kind, provider: "minimax") } catch { return err("network", provider: "minimax") }
        host.vault.set(k, for: mmKeyID)
        host.vault.set(MiniMax.hosts[region], for: mmBaseID)
        return .json(["last4": String(k.suffix(4)), "region": region], status: 201)
    }

    /// 试听（11-08）：MiniMax 没有现成的试听，拿用户自己的 key 念一句（念过存着）
    private static func sample(_ host: LocalHost, voiceID: String, provider p: String, lang: String) async -> LocalResponse {
        guard validVoiceID(voiceID, provider: p) else { return .error(400, String(localized: "这不像音色 ID")) }
        do {
            let clip = try await speak(host, text: sampleLine[lang] ?? sampleLine["zh"]!, voiceID: voiceID, model: noteModel(p), provider: p)
            guard let id = clip["id"] as? String, let d = try? Data(contentsOf: host.store.fileURL("voice-\(id).mp3")) else { return err("server", provider: p) }
            return .data(d, mime: "audio/mpeg")
        } catch let f as Fail { return err(f.kind, provider: p) } catch { return err("network", provider: p) }
    }

    /// ElevenLabs 的会拼进地址里，只放字母数字；MiniMax 的官方嗓子带空格和括号（只放进请求体）
    static func validVoiceID(_ id: String, provider: String) -> Bool {
        let re = provider == "minimax" ? #"^[\p{L}\p{N}_ ().,'-]{1,120}$"# : #"^[A-Za-z0-9_-]{8,64}$"#
        return id.range(of: re, options: .regularExpression) != nil
    }

    /// 音色库（11-07）：这把 key 账号里所有的嗓子。MiniMax 没有试听链接，给 voice/sample 的路径
    private static func library(_ host: LocalHost, provider p: String, lang: String) async -> LocalResponse {
        guard key(host, provider: p) != nil else { return .error(403, errorText("no_key", provider: p)) }
        do {
            let list = try await engine(host, provider: p).voices()
            guard p == "minimax" else { return .json(list) }
            return .json(list.map { v in
                var v = v
                if (v["preview"] as? String ?? "").isEmpty { v["preview"] = samplePath(v["voice_id"] as? String ?? "", lang: lang) }
                return v
            })
        } catch let f as Fail { return err(f.kind, provider: p) } catch { return err("network", provider: p) }
    }

    /// 能选的模型：出厂那几个排前面，ElevenLabs 那边多出来的跟在后面。key 没开「看模型」权限、连不上，就只有出厂的。MiniMax 是固定那张表
    private static func models(_ host: LocalHost, provider p: String) async -> LocalResponse {
        if p == "minimax" {
            return .json(MiniMax.models.map { ["id": $0.id, "name": $0.name, "tags": takesInterjections($0.id)] as [String: Any] })
        }
        var got: [(id: String, name: String)] = []
        if let k = key(host) { got = (try? await ElevenLabs(key: k).models()) ?? [] }
        let factory = modelChoices.map { m in (id: m.id, name: got.first { $0.id == m.id }?.name ?? m.name) }
        let extra = got.filter { g in !modelChoices.contains { $0.id == g.id } }
        return .json((factory + extra).map { ["id": $0.id, "name": $0.name, "tags": takesTags($0.id)] as [String: Any] })
    }

    private static func design(_ host: LocalHost, _ desc: String, provider p: String) async -> LocalResponse {
        let d = desc.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (8...400).contains(d.count) else { return .error(400, String(localized: "描述写 8～400 个字")) }
        guard key(host, provider: p) != nil else { return .error(403, errorText("no_key", provider: p)) }
        do { return .json(try await engine(host, provider: p).design(d)) } catch let f as Fail { return err(f.kind, provider: p) } catch { return err("network", provider: p) }
    }

    private static func choose(_ host: LocalHost, companion cid: String, _ b: [String: Any]) async -> LocalResponse {
        guard var c = host.store.companion(cid) else { return .error(404, String(localized: "没有这个联系人")) }
        // 音色库里的名字常常是「Adam - Distinct, Deep and Engaging」：只留破折号前面
        let tidy = { (s: String) in
            let one = s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return String((one.range(of: #"\s[-–—]\s"#, options: .regularExpression).map { String(one[..<$0.lowerBound]) } ?? one).prefix(30))
        }
        let p = provider(b["provider"] as? String)
        var name = tidy(b["name"] as? String ?? "")
        var voiceID = (b["voice_id"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if let gid = b["generated_voice_id"] as? String, !gid.isEmpty {
            guard key(host, provider: p) != nil else { return .error(403, errorText("no_key", provider: p)) }
            do {
                let el = try engine(host, provider: p)
                let (used, limit) = try await el.slots()
                if limit > 0 && used >= limit { return .error(409, String(localized: "声音位满了，先在 ElevenLabs 删掉一把再存")) }
                voiceID = try await el.saveDesign(name: name.isEmpty ? "Mele voice" : name,
                                                  description: String((b["description"] as? String ?? "").prefix(400)), generated: gid)
            } catch let f as Fail { return err(f.kind, provider: p) } catch { return err("network", provider: p) }
        } else if !voiceID.isEmpty {
            // ElevenLabs 的会拼进地址里，只放这些字符（别的字符还会让拼地址那一步直接崩）
            guard validVoiceID(voiceID, provider: p) else {
                return .error(400, p == "minimax" ? String(localized: "这不像音色 ID") : String(localized: "这不像音色 ID：只有英文字母和数字，一般 20 位"))
            }
            if name.isEmpty {       // 手填的：查个名字，查不到不拦（没加进账号的公共音色查不到，但念得出来）
                if let el = try? engine(host, provider: p), let n = try? await el.voiceName(voiceID) { name = tidy(n) }
                if name.isEmpty { name = voiceID.prefix(8) + "…" }
            }
        }
        guard !voiceID.isEmpty else { return .error(400, String(localized: "要给 voice_id 或 generated_voice_id")) }
        var s = c["settings"] as? [String: Any] ?? [:]
        if p == "minimax" { s["mm_voice_id"] = voiceID; s["mm_voice_name"] = name } else { s["voice_id"] = voiceID; s["voice_name"] = name }
        s["voice_provider"] = p
        c["settings"] = s
        host.store.saveCompanion(c)
        return .json(["voice_id": voiceID, "voice_name": name, "provider": p])
    }

    // MARK: 稿子

    private static let tagRE = try! NSRegularExpression(pattern: #"\[[^\[\]\n]{1,60}\]"#)
    /// MiniMax 2.8 认的语气词（官方文档 speech-t2a-http），和所有模型都认的 <#0.5#> 停顿
    static let interjections = ["laughs", "chuckle", "coughs", "clear-throat", "groans", "breath", "pant", "inhale", "exhale", "gasps",
                                "sniffs", "sighs", "snorts", "burps", "lip-smacking", "humming", "hissing", "emm", "sneezes"]
    private static let interjRE = try! NSRegularExpression(
        pattern: "[(（](?:" + interjections.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|") + ")[)）]",
        options: .caseInsensitive)
    private static let pauseRE = try! NSRegularExpression(pattern: #"<#\d{1,2}(?:\.\d{1,2})?#>"#)

    private static func sub(_ re: NSRegularExpression, _ s: String) -> String {
        re.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: "")
    }
    static func stripInterjections(_ s: String) -> String { sub(interjRE, s) }
    static func isMiniMax(_ model: String) -> Bool { model.hasPrefix("speech-") }
    static func takesInterjections(_ model: String) -> Bool { model.hasPrefix("speech-2.8") }

    static func isVoice(_ bubble: String) -> Bool { bubble.trimmingCharacters(in: .whitespaces).hasPrefix(mark) }

    /// 去掉开头的 🎤，留要念的稿子（带音频标签）
    static func body(_ bubble: String) -> String {
        let t = bubble.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix(mark) ? String(t.dropFirst(mark.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                                 : bubble.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 给人看的逐字稿：去掉 [softly] 这类音频标签
    static func stripTags(_ text: String) -> String {
        var out = sub(pauseRE, sub(interjRE, sub(tagRE, text)))      // MiniMax 的 (laughs)、<#0.5#> 也去掉
        out = out.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
        return out.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 念不成的时候：这一条照常当文字发（去 🎤、去标签）
    static func asText(_ bubble: String) -> String { stripTags(body(bubble)) }

    /// 还没念的语音条：编号按稿子的指纹（事件流里和翻历史时是同一个），秒数按字数估
    static func lazyRef(_ bubble: String) -> [String: Any] {
        ["id": "n" + sha(body(bubble)).prefix(20), "duration_ms": VoiceNoteLength.estimateMs(body(bubble)), "lazy": true]
    }

    static func sha(_ s: String) -> String { SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined() }

    /// 语音条用哪个模型（11-07）：没选过 = 默认。MiniMax 读它那一格
    static func model(_ settings: [String: Any]) -> String {
        if provider(settings) == "minimax" {
            let m = (settings["mm_voice_model"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            return isMiniMax(m) ? m : MiniMax.noteModel
        }
        let m = (settings["voice_model"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        return m.isEmpty || isMiniMax(m) ? noteModel : m
    }

    static func noteModel(_ provider: String) -> String { provider == "minimax" ? MiniMax.noteModel : noteModel }

    /// 这个模型认不认 [soft, tired] 这种音频标签（v3 起才认；别的模型会把标签照字念出来）
    static func takesTags(_ model: String) -> Bool { model.range(of: #"^eleven_v\d"#, options: .regularExpression) != nil }

    /// v3 不收前后句（11-07 实测 400 unsupported_model），带了整句念不了
    static func takesContext(_ model: String) -> Bool { !model.hasPrefix("eleven_v3") }

    /// 真正送去念的稿子。认标签的模型：一个标签都没有就垫一个；不认的：把标签去掉
    static func script(_ text: String, model: String) -> String {
        if isMiniMax(model) {        // [标签] 一律去掉；语气词只有 2.8 留着；<#0.5#> 停顿都留着
            let out = sub(tagRE, text).replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
            return (takesInterjections(model) ? out : stripInterjections(out)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard takesTags(model) else { return stripTags(text) }
        return tagRE.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) == nil ? defaultTag + text : text
    }

    static func voiceID(_ settings: [String: Any]) -> String {
        if provider(settings) == "minimax" {
            let v = (settings["mm_voice_id"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let lang = (settings["lang"] as? String) == "en" ? "en" : "zh"
            return v.isEmpty ? (mmPresets[lang] ?? mmPresets["zh"]!)[0].id : v
        }
        let v = (settings["voice_id"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        return v.isEmpty ? presets[0].id : v
    }

    // MARK: 念

    /// 念一句（有缓存就不花钱）。返回 {id, duration_ms}
    static func speak(_ host: LocalHost, text raw: String, voiceID: String, model: String = noteModel, prev: String? = nil, next: String? = nil,
                      provider p: String = "elevenlabs") async throws -> [String: Any] {
        let plain = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !plain.isEmpty else { throw Fail(kind: "bad_request") }
        let text = script(plain, model: model)
        guard !text.isEmpty else { throw Fail(kind: "bad_request") }
        let eng = try engine(host, provider: p)
        let fp = sha("\(model)\n\(voiceID)\n\(text)")
        var cache = host.store.read("voice-cache.json") as? [String: [String: Any]] ?? [:]
        if let hit = cache[fp], let id = hit["id"] as? String, FileManager.default.fileExists(atPath: host.store.fileURL("voice-\(id).mp3").path) {
            return hit
        }
        let mp3 = try await eng.synth(text, voiceID: voiceID, model: model, prev: prev, next: next)
        let id = UUID().uuidString.lowercased()
        host.store.saveFile(mp3, name: "voice-\(id).mp3")
        let clip: [String: Any] = ["id": id, "duration_ms": mp3.count * 8 / 128]       // 128kbps 估时长，够气泡上显示用
        cache[fp] = clip
        host.store.write("voice-cache.json", cache)
        return clip
    }

    /// 念给我听：它那条消息的第几个气泡。是语音条（🎤）就是「点了才念」那一下：带上前后句念得顺，念好挂回那条消息
    private static func speakMessage(_ host: LocalHost, _ mid: Int, index: Int) async -> LocalResponse {
        guard let (conv, i) = host.store.locate(message: mid) else { return .error(400, String(localized: "只能念它说的话")) }
        let m = host.store.messages(conv)[i]
        guard (m["role"] as? String) == "assistant", host.companion(ofConversation: conv) != nil else {
            return .error(400, String(localized: "只能念它说的话"))
        }
        let settings = host.settings(forMessage: m, in: conv)
        let bubbles = Bubbles.split(m["text"] as? String ?? "", cap: settings["max_bubbles"] as? Int ?? 6,
                                    offline: settings["long_mode"] as? Bool ?? false)
        guard bubbles.indices.contains(index) else { return .error(400, String(localized: "没有这一条")) }
        let b = bubbles[index]
        let note = isVoice(b)
        let near = { (j: Int) -> String? in note && bubbles.indices.contains(j) ? asText(bubbles[j]) : nil }
        let p = provider(settings)
        do {
            let clip = try await speak(host, text: note ? body(b) : b, voiceID: voiceID(settings), model: model(settings), prev: near(index - 1), next: near(index + 1),
                                       provider: p)
            if note, let (c, at) = host.store.locate(message: mid) {      // 下次翻历史直接是念好的那段
                var list = host.store.messages(c)
                var clips = list[at]["voice_clips"] as? [String: Any] ?? [:]
                clips[sha(body(b))] = clip
                list[at]["voice_clips"] = clips
                host.store.saveMessages(c, list)
            }
            return .json(clip)
        } catch let f as Fail { return err(f.kind, provider: p) } catch { return err("network", provider: p) }
    }

    /// 写进系统提示的那几句：有 key、没关、不是无痕才给
    static func modeLines(_ settings: [String: Any], hasKey: Bool, zh: Bool) -> String {
        let mode = settings["voice_mode"] as? String ?? "sometimes"
        guard hasKey, mode != "off" else { return "" }
        if provider(settings) == "minimax" { return miniMaxLines(mode: mode, interj: takesInterjections(model(settings)), zh: zh) }
        let example = zh ? "🎤 [soft, a little tired] 晚安…早点睡，明天见。" : "🎤 [soft, a little tired] Goodnight… sleep well, see you tomorrow."
        let lead: String
        if zh {
            lead = mode == "often" ? "你喜欢让 TA 听见你的声音，想说出声的时候就发语音条。" : "有些话用说的更好——晚安、安慰、笑出声、想 TA 的时候，就发语音条。"
        } else {
            lead = mode == "often" ? "You like letting them hear your voice: whenever you want to say something out loud, send a voice note."
                                   : "Some things land better said out loud — goodnights, comfort, a laugh, missing them — so send a voice note."
        }
        let how = zh ? """
            格式就是单独一段、以 🎤 开头，后面直接写要说出口的话，比如：
            \(example)
            这一段会念成你的语音条，TA 看到的逐字稿里没有标签。
            怎么写：
            - 🎤 那段是要念出来的稿子：写说出口的话，语言跟着你们聊天的语言走。
            - 音频标签写成一小段描述，几个词说清嗓子怎么动：[low and close, unhurried]、[quiet laugh under the breath]、[soft, a little tired]。单写一个 [whispers] 会整段变成气声，想贴近说话用 [low, close]。
            - 声口变了才写一个标签，往轻里写。
            - 停顿靠 …、换行和 —；逗号句号停不住。
            - 喘放进标点里：句首句尾留 …、话说一半断一下，一段两三处就够，每处换一种。
            - 要喘、要叹气的时候，写成英文的字：Hah… Hh— Haah…，夹在话里，每处换一种；低低的 Mm… Hm… 换着用。别写中文拟声（哈……呼——），也别写 panting、moaning 这类标签。倒吸一口气写 [hisses softly]，再接 [exhales slowly]。
            - 压低、凑近、放慢，比用力好听：[groans] 和带火气的词（angry、growl、intense、rough）会念成发火，用温和的词代替。
            - 写配音演员一读就知道嗓子怎么动的词，比喻和画面留给文字。
            - 拟声字（Mwah、啵）会被当成字念出来，用说的话代替。
            """ : """
            The format is its own paragraph starting with 🎤, followed by the words you'll say, e.g.:
            \(example)
            That paragraph becomes your voice note; the transcript they see has no tags.
            How to write it:
            - The 🎤 paragraph is a script to be spoken: write words meant to be said, in the language you two are talking in.
            - Write audio tags as a short description — a few words on what the voice does: [low and close, unhurried], [quiet laugh under the breath], [soft, a little tired]. A bare [whispers] turns the whole thing breathy; for speaking close, use [low, close].
            - Add a tag only when the delivery changes, and keep it light.
            - Pauses come from …, line breaks and —; commas and full stops don't hold.
            - Put breath in the punctuation: a … at the start or end, a sentence breaking off halfway — two or three per paragraph, each one different.
            - When you breathe or sigh, write it as letters inside the words: Hah… Hh— Haah…, each one different; trade off with a low Mm… or Hm…. No breathing tags like panting or moaning. A sharp intake of breath is [hisses softly], then [exhales slowly].
            - Lower, closer and slower sound better than forceful: [groans] and heated words (angry, growl, intense, rough) come out as anger, so use gentle words instead.
            - Use words a voice actor would know how to perform; save metaphors and imagery for text.
            - Sound words (Mwah and the like) get read out as words — say it in words instead.
            """
        return lead + "\n" + how
    }

    /// MiniMax 的写法（照 server brain/voice.MM_MODE_LINES）：不认 [标签]；2.8 认 (laughs) 这类语气词；都认 <#0.5#>
    static func miniMaxLines(mode: String, interj: Bool, zh: Bool) -> String {
        if zh {
            let lead = mode == "often" ? "你喜欢让 TA 听见你的声音，想说出声的时候就发语音条。" : "有些话用说的更好——晚安、安慰、笑出声、想 TA 的时候，就发语音条。"
            return lead + "\n格式就是单独一段、以 🎤 开头，后面直接写要说出口的话，比如：\n🎤 " + (interj ? "晚安…(sighs) 早点睡，明天见。" : "晚安…<#0.5#> 早点睡，明天见。")
                + "\n这一段会念成你的语音条。\n怎么写：\n- 只写说出口的话，语言跟着你们聊天的语言走；不写方括号标签，也不写动作。\n"
                + "- 停顿靠 …、换行和 —；想停久一点写 <#0.5#>（数字是秒，0.3～2），两个别挨着写。"
                + (interj ? "\n- 笑、叹气、喘的时候，把这几个词原样夹在话里：(laughs) (chuckle) (sighs) (breath) (inhale) (exhale) (gasps) (sniffs) (humming) (emm)，一段一两处就够，每处换一个。" : "")
        }
        let lead = mode == "often" ? "You like letting them hear your voice: whenever you want to say something out loud, send a voice note."
                                   : "Some things land better said out loud — goodnights, comfort, a laugh, missing them — so send a voice note."
        return lead + "\nThe format is its own paragraph starting with 🎤, followed by the words you'll say, e.g.:\n🎤 "
            + (interj ? "Goodnight… (sighs) sleep well, see you tomorrow." : "Goodnight… <#0.5#> sleep well, see you tomorrow.")
            + "\nThat paragraph becomes your voice note.\nHow to write it:\n- Only words meant to be said, in the language you two are talking in; no square-bracket tags, no actions.\n"
            + "- Pauses come from …, line breaks and —; for a longer one write <#0.5#> (seconds, 0.3–2), never two in a row."
            + (interj ? "\n- When you laugh, sigh or breathe, drop one of these into the words exactly as written: (laughs) (chuckle) (sighs) (breath) (inhale) (exhale) (gasps) (sniffs) (humming) (emm) — one or two per paragraph, a different one each time." : "")
    }

    // MARK: TA 发语音

    private static func receive(_ host: LocalHost, conversation conv: String, _ r: LocalRequest) async -> LocalResponse {
        guard let file = r.form.files["audio"]?.first, !file.data.isEmpty else { return err("bad_request") }
        let secondsHint = Double(r.form.fields["seconds"] ?? "") ?? 0
        guard file.data.count <= 8 * 1024 * 1024, secondsHint <= 125 else { return err("too_long") }
        let cs = host.companion(ofConversation: conv)?["settings"] as? [String: Any] ?? [:]
        // 转文字先用这个 TA 那家的 key，没有就用另一家的（11-08 MiniMax 也能转）
        let prefer = provider(cs)
        guard let ears = ([prefer] + providers.filter { $0 != prefer }).lazy.compactMap({ try? engine(host, provider: $0) }).first else {
            return err("no_key", provider: prefer)
        }
        let zh = (cs["lang"] as? String ?? "zh") != "en"
        var text = "", note = ""
        var m = Measure(seconds: secondsHint, units: 0, rate: 0, pauses: 0, longest: 0, events: [])
        if let got = try? await ears.transcribe(file.data) {
            text = got.text.replacingOccurrences(of: #"\s*[(\[][^)\]]{1,30}[)\]]\s*"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            m = measure(got.words, secondsHint: secondsHint)
            let samples = host.store.read("voice-baseline.json") as? [[String: Double]] ?? []
            note = describe(m, samples: samples, zh: zh)
            if m.units >= 4 {
                host.store.write("voice-baseline.json", Array((samples + [["rate": m.rate, "pause_per_min": m.pausePerMin]]).suffix(20)))
            }
        } else {
            note = describe(m, samples: [], zh: zh)
        }
        if text.isEmpty { text = zh ? "（语音没转出文字）" : "(couldn't transcribe the voice message)" }
        let secs = max(1, Int((m.seconds > 0 ? m.seconds : secondsHint).rounded()))
        let id = UUID().uuidString.lowercased()
        host.store.saveFile(file.data, name: "att-\(id)")
        var all = host.store.collection("attachments")
        all.append(["id": id, "conversation": conv, "kind": "voice", "name": "voice-\(secs)s.m4a", "mime": "audio/mp4",
                    "size": file.data.count, "seconds": secs, "caption": note])
        host.store.saveCollection("attachments", all)
        return .json(["attachment": host.attachmentPublic(id) ?? [:], "text": text], status: 201)
    }

    struct Measure {
        var seconds: Double, units: Double, rate: Double, pauses: Int, longest: Double, events: [String]
        var pausePerMin: Double { Double(pauses) / max(seconds / 60, 0.25) }
    }

    private static func units(_ s: String) -> Double {
        let cjk = s.unicodeScalars.filter { (0x4E00...0x9FFF).contains($0.value) }.count
        let words = s.split(whereSeparator: { !($0.isLetter && $0.isASCII) && $0 != "'" }).count
        return Double(cjk + words * 2)
    }

    static func measure(_ words: [[String: Any]], secondsHint: Double) -> Measure {
        func num(_ v: Any?) -> Double { (v as? Double) ?? Double(v as? Int ?? 0) }
        let spoken = words.filter { ($0["type"] as? String) == "word" }
        let events = words.filter { ($0["type"] as? String) == "audio_event" }.map { $0["text"] as? String ?? "" }
        let talk = spoken.isEmpty ? max(secondsHint, 0.3) : max(num(spoken.last?["end"]) - num(spoken.first?["start"]), 0.3)
        let gaps = zip(spoken, spoken.dropFirst()).map { num($1["start"]) - num($0["end"]) }
        let pauses = gaps.filter { $0 >= 0.7 }
        let u = units(spoken.map { ($0["text"] as? String ?? "") + " " }.joined())
        let total = max(secondsHint, num(words.last?["end"]), talk)
        return Measure(seconds: (total * 10).rounded() / 10, units: u, rate: u > 0 ? u / talk : 0, pauses: pauses.count,
                       longest: ((pauses.max() ?? 0) * 10).rounded() / 10, events: events)
    }

    private static let eventWords: [(String, String, String)] = [
        ("laugh", "笑了一下", "laughed"), ("chuckle", "轻笑了一下", "chuckled"), ("giggle", "咯咯笑了", "giggled"),
        ("sigh", "叹了口气", "sighed"), ("cry", "带着哭腔", "sounded tearful"), ("sob", "抽泣", "sobbed"),
        ("sniff", "吸了吸鼻子", "sniffed"), ("cough", "咳了一声", "coughed"), ("yawn", "打了个哈欠", "yawned"),
        ("breath", "深吸了一口气", "took a deep breath")]

    private static func median(_ xs: [Double]) -> Double {
        let s = xs.sorted()
        guard !s.isEmpty else { return 0 }
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    /// 只写听到的事实，不替 TA 下结论；攒够 5 条才跟 TA 自己比
    static func describe(_ m: Measure, samples: [[String: Double]], zh: Bool) -> String {
        var bits: [String] = []
        let mine = samples.count >= 5
        if m.units >= 4 && m.rate > 0 {
            if mine {
                let base = median(samples.compactMap { $0["rate"] })
                let r = base > 0 ? m.rate / base : 1
                if r <= 0.8 { bits.append(zh ? "说得比你平时慢不少" : "much slower than you usually talk") }
                else if r <= 0.9 { bits.append(zh ? "比平时慢一点" : "a bit slower than usual") }
                else if r >= 1.25 { bits.append(zh ? "说得比你平时快不少" : "much faster than you usually talk") }
                else if r >= 1.1 { bits.append(zh ? "比平时快一点" : "a bit faster than usual") }
            } else if m.rate < 3 { bits.append(zh ? "说得偏慢" : "on the slow side") }
            else if m.rate > 6 { bits.append(zh ? "说得偏快" : "on the fast side") }
        }
        if m.pauses > 0 {
            let many = mine ? m.pausePerMin >= 1.5 * max(median(samples.compactMap { $0["pause_per_min"] }), 1) : m.pauses >= 3
            if many {
                let lg = m.longest == m.longest.rounded() ? "\(Int(m.longest))" : "\(m.longest)"
                bits.append(zh ? "中间停了 \(m.pauses) 次（最长 \(lg) 秒）" + (mine ? "，比平时多" : "")
                               : "paused \(m.pauses) times (longest \(lg)s)" + (mine ? ", more than usual" : ""))
            }
        }
        var heard: [String] = [], background: [String] = []
        for e in m.events {
            let key = e.lowercased().filter { $0.isLetter }
            if let hit = eventWords.first(where: { key.hasPrefix($0.0) }) { heard.append(zh ? hit.1 : hit.2) }
            else {
                let t = e.trimmingCharacters(in: CharacterSet(charactersIn: "()[] "))
                if !t.isEmpty { background.append(t) }
            }
        }
        if !background.isEmpty {
            var seen = Set<String>()
            heard.append((zh ? "背景里有" : "background: ") + background.filter { seen.insert($0).inserted }.joined(separator: zh ? "、" : ", "))
        }
        var seen = Set<String>()
        bits += heard.filter { seen.insert($0).inserted }
        let secs = max(1, Int(m.seconds.rounded()))
        let head = zh ? "语音 \(secs) 秒" : "voice message, \(secs)s"
        if bits.isEmpty { return "〔\(head)〕" }
        return zh ? "〔\(head)：\(bits.joined(separator: "，"))〕" : "〔\(head): \(bits.joined(separator: ", "))〕"
    }
}

/// 两家接头共有的那几样（11-08）：调用方不用分是哪家
protocol VoiceEngine {
    func synth(_ text: String, voiceID: String, model: String, prev: String?, next: String?) async throws -> Data
    func voices() async throws -> [[String: Any]]
    func voiceName(_ id: String) async throws -> String
    func design(_ description: String) async throws -> [[String: Any]]
    func saveDesign(name: String, description: String, generated: String) async throws -> String
    func slots() async throws -> (Int, Int)
    func transcribe(_ audio: Data) async throws -> (text: String, words: [[String: Any]])
}

/// ElevenLabs 接头（照 server/llm/tts.py）
struct ElevenLabs: VoiceEngine {
    let key: String
    private static let base = "https://api.elevenlabs.io"

    func request(_ method: String, _ path: String, query: [String: String] = [:], json: [String: Any]? = nil,
                 multipart: (fields: [String: String], file: Data)? = nil) async throws -> Data {
        var c = URLComponents(string: Self.base + path)!
        if !query.isEmpty { c.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var req = URLRequest(url: c.url!, timeoutInterval: 60)
        req.httpMethod = method
        req.setValue(key, forHTTPHeaderField: "xi-api-key")
        if let json {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: json)
        } else if let multipart {
            let boundary = "mele-\(UUID().uuidString)"
            req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            var body = Data()
            for (k, v) in multipart.fields {
                body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(v)\r\n".utf8))
            }
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"voice.m4a\"\r\nContent-Type: audio/mp4\r\n\r\n".utf8))
            body.append(multipart.file)
            body.append(Data("\r\n--\(boundary)--\r\n".utf8))
            req.httpBody = body
        }
        let data: Data, resp: URLResponse
        do { (data, resp) = try await URLSession.shared.data(for: req) } catch { throw LocalVoice.Fail(kind: "network") }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status >= 400 {
            throw LocalVoice.Fail(kind: LocalVoice.failKind(status: status, body: data))
        }
        return data
    }

    private func object(_ d: Data) -> [String: Any] { (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:] }

    func synth(_ text: String, voiceID: String, model: String, prev: String?, next: String?) async throws -> Data {
        var body: [String: Any] = ["text": text, "model_id": model, "voice_settings": ["stability": 0.5]]
        if LocalVoice.takesContext(model) {
            if let prev, !prev.isEmpty { body["previous_text"] = prev }
            if let next, !next.isEmpty { body["next_text"] = next }
        }
        return try await request("POST", "/v1/text-to-speech/\(voiceID)", query: ["output_format": "mp3_44100_128"], json: body)
    }

    /// 账号里所有的嗓子（自己克隆的、设计的、收藏的、官方的）
    func voices() async throws -> [[String: Any]] {
        let list = object(try await request("GET", "/v1/voices"))["voices"] as? [[String: Any]] ?? []
        return list.compactMap { v in
            guard let id = v["voice_id"] as? String else { return nil }
            return ["voice_id": id, "name": v["name"] as? String ?? "", "category": v["category"] as? String ?? "",
                    "about": v["description"] as? String ?? "", "preview": v["preview_url"] as? String ?? ""]
        }
    }

    func voiceName(_ id: String) async throws -> String {
        object(try await request("GET", "/v1/voices/\(id)"))["name"] as? String ?? ""
    }

    /// 能合成的模型（key 要开「看模型」权限）
    func models() async throws -> [(id: String, name: String)] {
        let list = (try? JSONSerialization.jsonObject(with: try await request("GET", "/v1/models"))) as? [[String: Any]] ?? []
        return list.compactMap { m in
            guard m["can_do_text_to_speech"] as? Bool == true, let id = m["model_id"] as? String else { return nil }
            return (id, m["name"] as? String ?? id)
        }
    }

    func design(_ description: String) async throws -> [[String: Any]] {
        let d = object(try await request("POST", "/v1/text-to-voice/design",
                                         json: ["voice_description": description, "model_id": "eleven_ttv_v3", "auto_generate_text": true]))
        return (d["previews"] as? [[String: Any]] ?? []).map {
            ["generated_voice_id": $0["generated_voice_id"] ?? "", "audio_base_64": $0["audio_base_64"] ?? "",
             "duration_secs": $0["duration_secs"] ?? 0]
        }
    }

    func saveDesign(name: String, description: String, generated: String) async throws -> String {
        let d = object(try await request("POST", "/v1/text-to-voice",
                                         json: ["voice_name": name, "voice_description": description, "generated_voice_id": generated]))
        guard let id = d["voice_id"] as? String else { throw LocalVoice.Fail(kind: "server") }
        return id
    }

    func slots() async throws -> (Int, Int) {
        let d = object(try await request("GET", "/v1/user/subscription"))
        return (d["voice_slots_used"] as? Int ?? 0, d["voice_limit"] as? Int ?? 0)
    }

    func transcribe(_ audio: Data) async throws -> (text: String, words: [[String: Any]]) {
        let d = object(try await request("POST", "/v1/speech-to-text",
                                         multipart: (["model_id": "scribe_v2", "tag_audio_events": "true",
                                                      "timestamps_granularity": "word"], audio)))
        return (d["text"] as? String ?? "", d["words"] as? [[String: Any]] ?? [])
    }
}

/// MiniMax 接头（11-08，照 server/llm/tts.py 的 MiniMax）
/// - 出错时 HTTP 还是 200，错在 base_resp.status_code；音频是 hex 字符串
/// - 没有前后句、没有试听链接；描述一把一次只出一把，存的时候念一个字激活（没用过的 7 天后会被清掉）
struct MiniMax: VoiceEngine {
    let key: String
    var base: String = MiniMax.hosts["intl"]!
    static let hosts = ["cn": "https://api.minimax.cn", "intl": "https://api.minimax.io"]
    static let noteModel = "speech-2.8-hd"
    static let fastModel = "speech-2.8-turbo"
    static let models: [(id: String, name: String)] = [
        ("speech-2.8-hd", "Speech 2.8 HD"), ("speech-2.8-turbo", "Speech 2.8 Turbo"), ("speech-2.6-hd", "Speech 2.6 HD"),
        ("speech-2.6-turbo", "Speech 2.6 Turbo"), ("speech-02-hd", "Speech 02 HD"), ("speech-02-turbo", "Speech 02 Turbo"),
    ]
    /// 错误码（官方 errorcode 页）归到跟 ElevenLabs 一样的几类
    static let kinds: [Int: String] = [
        1004: "auth", 2049: "auth",
        1002: "quota", 1008: "quota", 1039: "quota", 1041: "quota", 2045: "quota", 2046: "quota", 2047: "quota",
        2053: "quota", 2056: "quota", 2062: "quota", 2067: "quota",
        2054: "voice_not_found", 20132: "voice_not_found", 2042: "voice_not_found", 2043: "voice_not_found",
        2022: "model_not_found", 2061: "model_not_found", 2068: "model_not_found", 2069: "model_not_found",
        1026: "sensitive", 1027: "sensitive", 1040: "sensitive", 2052: "slots",
        2013: "bad_request", 2014: "bad_request", 1042: "bad_request",
    ]

    @discardableResult
    static func check(_ d: [String: Any]) throws -> [String: Any] {
        let br = d["base_resp"] as? [String: Any] ?? [:]
        let code = (br["status_code"] as? Int) ?? Int(br["status_code"] as? String ?? "") ?? 0
        if code != 0 {
            NSLog("[voice] MiniMax \(code): \(br["status_msg"] as? String ?? "")")
            throw LocalVoice.Fail(kind: kinds[code] ?? "server")
        }
        return d
    }

    static func hex(_ s: String) -> Data {
        var out = Data(capacity: s.utf8.count / 2)
        var hi: UInt8?
        for c in s.utf8 {
            let v: UInt8
            switch c {
            case 48...57: v = c - 48
            case 97...102: v = c - 87
            case 65...70: v = c - 55
            default: continue
            }
            if let h = hi { out.append(h << 4 | v); hi = nil } else { hi = v }
        }
        return out
    }

    func request(_ path: String, json: [String: Any]) throws -> URLRequest {
        var req = URLRequest(url: URL(string: base + path)!, timeoutInterval: 60)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: json)
        return req
    }

    private func send(_ req: URLRequest) async throws -> [String: Any] {
        let data: Data, resp: URLResponse
        do { (data, resp) = try await URLSession.shared.data(for: req) } catch { throw LocalVoice.Fail(kind: "network") }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if status >= 400, ((d["base_resp"] as? [String: Any])?["status_code"] as? Int ?? 0) == 0 {
            throw LocalVoice.Fail(kind: [401, 403].contains(status) ? "auth" : status == 429 ? "quota" : status < 500 ? "bad_request" : "server")
        }
        return try Self.check(d)
    }

    func post(_ path: String, json: [String: Any]) async throws -> [String: Any] { try await send(try request(path, json: json)) }

    func ttsBody(_ text: String, voiceID: String, model: String, stream: Bool) -> [String: Any] {
        var b: [String: Any] = ["model": model, "text": text, "stream": stream, "language_boost": "auto",
                                "voice_setting": ["voice_id": voiceID, "speed": 1, "vol": 1, "pitch": 0],
                                "audio_setting": stream ? ["sample_rate": 24000, "format": "pcm", "channel": 1]
                                                        : ["sample_rate": 32000, "bitrate": 128000, "format": "mp3", "channel": 1]]
        if stream { b["stream_options"] = ["exclude_aggregated_audio": true] }
        return b
    }

    func synth(_ text: String, voiceID: String, model: String, prev: String?, next: String?) async throws -> Data {
        let d = try await post("/v1/t2a_v2", json: ttsBody(text, voiceID: voiceID, model: model, stream: false))
        let audio = Self.hex((d["data"] as? [String: Any])?["audio"] as? String ?? "")
        guard !audio.isEmpty else { throw LocalVoice.Fail(kind: "server") }
        return audio
    }

    func voices() async throws -> [[String: Any]] {
        let d = try await post("/v1/get_voice", json: ["voice_type": "all"])
        var out: [[String: Any]] = []
        for (group, cat) in [("voice_cloning", "cloned"), ("voice_generation", "generated"), ("system_voice", "premade")] {
            for v in d[group] as? [[String: Any]] ?? [] {
                guard let id = v["voice_id"] as? String, !id.isEmpty else { continue }
                let about = (v["description"] as? [String])?.joined(separator: " ") ?? (v["description"] as? String ?? "")
                out.append(["voice_id": id, "name": (v["voice_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id,
                            "category": cat, "about": about, "preview": ""])
            }
        }
        return out
    }

    func voiceName(_ id: String) async throws -> String {
        try await voices().first { ($0["voice_id"] as? String) == id }?["name"] as? String ?? ""
    }

    func design(_ description: String) async throws -> [[String: Any]] {
        let zh = description.range(of: #"\p{Han}"#, options: .regularExpression) != nil
        let d = try await post("/v1/voice_design", json: ["prompt": description,
                                                          "preview_text": zh ? "嗨，是我。今天过得怎么样？我刚才一直在想你。" : "Hey, it's me. How was your day? I was just thinking about you."])
        guard let id = d["voice_id"] as? String, !id.isEmpty else { throw LocalVoice.Fail(kind: "server") }
        let audio = Self.hex(d["trial_audio"] as? String ?? "")
        return [["generated_voice_id": id, "audio_base_64": audio.base64EncodedString(), "duration_secs": 0]]
    }

    func saveDesign(name: String, description: String, generated: String) async throws -> String {
        _ = try await synth("嗯。", voiceID: generated, model: Self.fastModel, prev: nil, next: nil)     // 用一次才会留下来
        return generated
    }

    func slots() async throws -> (Int, Int) { (0, 0) }      // 不给查；满了存的时候会报 slots

    /// asr-1.0：只有一段一段的起止时间，一段当一个「词」交给量语气那边
    func transcribe(_ audio: Data) async throws -> (text: String, words: [[String: Any]]) {
        var req = URLRequest(url: URL(string: base + "/v1/speech_to_text")!, timeoutInterval: 60)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let boundary = "mele-\(UUID().uuidString)"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        for (k, v) in ["model": "asr-1.0", "response_format": "verbose_json"] {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(v)\r\n".utf8))
        }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"voice.m4a\"\r\nContent-Type: audio/mp4\r\n\r\n".utf8))
        body.append(audio)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        req.httpBody = body
        let d = try await send(req)
        let words: [[String: Any]] = (d["segments"] as? [[String: Any]] ?? []).compactMap { s in
            let t = (s["text"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { return nil }
            return ["text": t, "type": "word", "start": s["start"] as? Double ?? 0, "end": s["end"] as? Double ?? 0]
        }
        return (d["text"] as? String ?? "", words)
    }

    /// 填 key 时轻探一下：列官方嗓子，不花钱
    func checkKey() async throws { _ = try await post("/v1/get_voice", json: ["voice_type": "system"]) }

    /// 国内版先试（用户多半在国内），key 不认再试另一边
    static func region(for key: String) async throws -> String {
        for region in ["cn", "intl"] {
            do {
                try await MiniMax(key: key, base: hosts[region]!).checkKey()
                return region
            } catch let f as LocalVoice.Fail where f.kind == "auth" {
                continue
            }
        }
        throw LocalVoice.Fail(kind: "auth")
    }
}
#endif
