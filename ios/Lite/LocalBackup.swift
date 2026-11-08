#if LITE
import Foundation
import MeleLiteCore

/// 备份到文件（2026-10-10，内测前Aporia要的：Lite 的东西全在手机里，删了 App 就没了）。
/// 一个 .melebackup = 整个 Documents（lite-host 里的聊天和房间 + 主屏图标、壁纸、小组件照片、贴纸……）
/// + 设置（UserDefaults）+ 可选的钥匙（模型 API key、记忆库令牌的原文）。
/// 格式自己定的，顺序读写、不整个读进内存（相册可能几百 MB）：
///   "MELEBAK1" | u32 清单长度 | 清单 JSON | 若干段 [u32 路径长度 | 路径 UTF-8 | u64 大小 | 内容]
/// 恢复：先整包解到旁边的临时文件夹，全部解对了才换进来；换下来的旧东西放 .restore-old-*，下次打开清掉。
enum LocalBackup {
    static let magic = Data("MELEBAK1".utf8)
    static let ext = "melebackup"
    static let formatVersion = 1
    private static let tmpPrefix = ".restore"     // 自己的临时文件夹，备份时跳过
    private static let chunk = 1 << 20

    static var docs: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].resolvingSymlinksInPath()
    }

    struct Summary {
        let files: Int
        let bytes: Int64
        let keys: Int
        let created: String
    }

    enum Failure: LocalizedError {
        case notBackup, broken, unsafePath, newer
        var errorDescription: String? {
            switch self {
            case .notBackup: return String(localized: "这不是 Mele 的备份文件")
            case .broken: return String(localized: "备份文件不完整，可能没传完")
            case .unsafePath: return String(localized: "备份文件里有不认识的路径，没敢恢复")
            case .newer: return String(localized: "这个备份是新版 Mele 做的，先把 Mele 更新到最新再恢复")
            }
        }
    }

    // MARK: - 导出

    /// 导出到临时文件夹，返回文件地址（交给分享面板存到「文件」/ iCloud 云盘）
    static func export(includeKeys: Bool) throws -> URL {
        let fm = FileManager.default
        let day = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
        let out = fm.temporaryDirectory.appendingPathComponent("Mele 备份 \(day).\(ext)")
        try? fm.removeItem(at: out)
        fm.createFile(atPath: out.path, contents: nil)
        let h = try FileHandle(forWritingTo: out)
        defer { try? h.close() }

        let files = allFiles()
        var keys: [[String: String]] = []
        if includeKeys {
            let host = LocalHost.shared
            for k in host.keys {
                if let id = k["id"] as? String, let secret = host.vault.get(id) {
                    keys.append(["vault": "model", "id": id, "secret": secret])
                }
            }
            for id in [LocalVoice.keyID, LocalVoice.mmKeyID, LocalVoice.mmBaseID] {     // 声音的 key（11-08 补上）
                if let secret = host.vault.get(id) { keys.append(["vault": "model", "id": id, "secret": secret]) }
            }
            for sv in host.mcp.servers(host.store) {
                if let secret = host.mcp.vault.get(sv.id) {
                    keys.append(["vault": "mcp", "id": sv.id, "secret": secret])
                }
            }
        }
        var manifest: [String: Any] = [
            "format": formatVersion,
            "created": ISO8601DateFormatter().string(from: Date()),
            "app": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
            "files": files.count,
            "bytes": files.reduce(Int64(0)) { $0 + $1.size },
            "keys": keys,
        ]
        if let bid = Bundle.main.bundleIdentifier, let domain = UserDefaults.standard.persistentDomain(forName: bid),
           let plist = try? PropertyListSerialization.data(fromPropertyList: domain, format: .binary, options: 0) {
            manifest["defaults"] = plist.base64EncodedString()
        }
        let mdata = try JSONSerialization.data(withJSONObject: manifest)
        try h.write(contentsOf: magic)
        try h.write(contentsOf: u32(mdata.count))
        try h.write(contentsOf: mdata)

        for f in files {
            let p = Data(f.path.utf8)
            try h.write(contentsOf: u32(p.count))
            try h.write(contentsOf: p)
            try h.write(contentsOf: u64(UInt64(f.size)))
            let r = try FileHandle(forReadingFrom: f.url)
            var left = f.size
            while left > 0 {
                let d = try r.read(upToCount: min(chunk, Int(left))) ?? Data()
                if d.isEmpty { break }
                try h.write(contentsOf: d)
                left -= Int64(d.count)
            }
            try? r.close()
            // 读的时候文件变短了（正在写）：补零保证格式对得上，宁可这一个文件坏也别整包坏
            if left > 0 { try h.write(contentsOf: Data(count: Int(left))) }
        }
        return out
    }

    // MARK: - 删 TA 前自动留一份（10-11 Aporia在 TA 设定里误删了一个 Lumi，没备份找不回来）

    /// 放在 Application Support 不放 Documents：一键备份只打包 Documents，免得备份里套备份越滚越大
    static var autoDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("auto-backups", isDirectory: true)
    }
    static let autoKeep = 3

    struct AutoBackup: Identifiable {
        let url: URL
        let who: String
        let date: Date
        let bytes: Int64
        var id: String { url.lastPathComponent }
    }

    /// 删 TA 之前整个打一份（不带钥匙：钥匙在钥匙串里，同一台手机恢复不受影响），只留最近 3 份
    static func autoBackup(before who: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: autoDir, withIntermediateDirectories: true)
        let tmp = try export(includeKeys: false)
        let stamp = Int(Date().timeIntervalSince1970)
        let dest = autoDir.appendingPathComponent("before-delete-\(stamp).\(ext)")
        try? fm.removeItem(at: dest)
        try fm.moveItem(at: tmp, to: dest)
        let meta = try JSONSerialization.data(withJSONObject: ["who": who, "at": stamp])
        try meta.write(to: dest.deletingPathExtension().appendingPathExtension("json"))
        for old in autoBackups().dropFirst(autoKeep) {
            try? fm.removeItem(at: old.url)
            try? fm.removeItem(at: old.url.deletingPathExtension().appendingPathExtension("json"))
        }
    }

    /// 新的在前
    static func autoBackups() -> [AutoBackup] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(at: autoDir, includingPropertiesForKeys: [.fileSizeKey]) else { return [] }
        return names.filter { $0.pathExtension == ext }.compactMap { u in
            let meta = (try? Data(contentsOf: u.deletingPathExtension().appendingPathExtension("json")))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            let at = (meta["at"] as? Double) ?? (try? u.resourceValues(forKeys: [.creationDateKey]).creationDate?.timeIntervalSince1970) ?? 0
            let size = Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            return AutoBackup(url: u, who: meta["who"] as? String ?? "TA", date: Date(timeIntervalSince1970: at), bytes: size)
        }.sorted { $0.date > $1.date }
    }

    private struct Entry { let url: URL; let path: String; let size: Int64 }

    private static func allFiles() -> [Entry] {
        let base = docs
        let fm = FileManager.default
        guard let it = fm.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else { return [] }
        var out: [Entry] = []
        let prefix = base.path.hasSuffix("/") ? base.path : base.path + "/"
        for case let u as URL in it {
            let url = u.resolvingSymlinksInPath()
            let vals = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard vals?.isRegularFile == true, url.path.hasPrefix(prefix) else { continue }
            let rel = String(url.path.dropFirst(prefix.count))
            if rel.hasPrefix(tmpPrefix) || rel.hasPrefix("Inbox/") { continue }
            out.append(Entry(url: url, path: rel, size: Int64(vals?.fileSize ?? 0)))
        }
        return out.sorted { $0.path < $1.path }
    }

    // MARK: - 恢复

    /// 只读清单，给「确定要恢复吗」那一步看
    static func peek(_ url: URL) throws -> Summary {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        return summary(try readManifest(h))
    }

    /// 恢复：返回恢复了什么。成功后要她把 App 划掉重开（各处缓存还是旧的）
    @discardableResult
    static func restore(_ url: URL) throws -> Summary {
        let fm = FileManager.default
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        let manifest = try readManifest(h)

        let stamp = Int(Date().timeIntervalSince1970)
        let staging = docs.appendingPathComponent("\(tmpPrefix)-new-\(stamp)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            while let lenData = try h.read(upToCount: 4), !lenData.isEmpty {
                guard lenData.count == 4 else { throw Failure.broken }
                let plen = Int(readU32(lenData))
                guard plen > 0, plen < 4096, let pdata = try h.read(upToCount: plen), pdata.count == plen,
                      let path = String(data: pdata, encoding: .utf8) else { throw Failure.broken }
                guard let sdata = try h.read(upToCount: 8), sdata.count == 8 else { throw Failure.broken }
                let size = readU64(sdata)
                let comps = path.split(separator: "/")
                guard !path.hasPrefix("/"), !comps.contains(".."), !comps.isEmpty else { throw Failure.unsafePath }
                let dest = staging.appendingPathComponent(path)
                try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                fm.createFile(atPath: dest.path, contents: nil)
                let w = try FileHandle(forWritingTo: dest)
                var left = size
                while left > 0 {
                    let d = try h.read(upToCount: min(chunk, Int(left))) ?? Data()
                    if d.isEmpty { try? w.close(); throw Failure.broken }
                    try w.write(contentsOf: d)
                    left -= UInt64(d.count)
                }
                try w.close()
            }
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }

        // 全部解对了才动现在的东西：旧的挪开 → 新的挪进来
        let old = docs.appendingPathComponent("\(tmpPrefix)-old-\(stamp)", isDirectory: true)
        try fm.createDirectory(at: old, withIntermediateDirectories: true)
        let current = (try? fm.contentsOfDirectory(atPath: docs.path)) ?? []
        for name in current where !name.hasPrefix(tmpPrefix) && name != "Inbox" {
            try fm.moveItem(at: docs.appendingPathComponent(name), to: old.appendingPathComponent(name))
        }
        for name in (try? fm.contentsOfDirectory(atPath: staging.path)) ?? [] {
            try fm.moveItem(at: staging.appendingPathComponent(name), to: docs.appendingPathComponent(name))
        }
        try? fm.removeItem(at: staging)

        if let b64 = manifest["defaults"] as? String, let plist = Data(base64Encoded: b64),
           let domain = try? PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any],
           let bid = Bundle.main.bundleIdentifier {
            UserDefaults.standard.setPersistentDomain(domain, forName: bid)
        }
        let host = LocalHost.shared
        for k in manifest["keys"] as? [[String: String]] ?? [] {
            guard let id = k["id"], let secret = k["secret"] else { continue }
            (k["vault"] == "mcp" ? host.mcp.vault : host.vault).set(secret, for: id)
        }
        return summary(manifest)
    }

    /// 上次恢复换下来的旧东西：打开 App 时清掉
    static func cleanupOld() {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: docs.path)) ?? [] where name.hasPrefix("\(tmpPrefix)-") {
            try? fm.removeItem(at: docs.appendingPathComponent(name))
        }
    }

    private static func readManifest(_ h: FileHandle) throws -> [String: Any] {
        guard let m = try h.read(upToCount: magic.count), m == magic else { throw Failure.notBackup }
        guard let l = try h.read(upToCount: 4), l.count == 4 else { throw Failure.broken }
        let n = Int(readU32(l))
        guard n > 0, n < 64 << 20, let d = try h.read(upToCount: n), d.count == n,
              let obj = try JSONSerialization.jsonObject(with: d) as? [String: Any] else { throw Failure.broken }
        if (obj["format"] as? Int ?? 0) > formatVersion { throw Failure.newer }
        return obj
    }

    private static func summary(_ m: [String: Any]) -> Summary {
        Summary(files: m["files"] as? Int ?? 0, bytes: (m["bytes"] as? NSNumber)?.int64Value ?? 0,
                keys: (m["keys"] as? [Any])?.count ?? 0, created: m["created"] as? String ?? "")
    }

    #if DEBUG
    /// 自测（模拟器 -backupSelfTest）：导出 → 读清单 → 恢复 → 比对恢复前后每个文件的内容，结果打到日志
    static func selfTest() {
        let before = Dictionary(uniqueKeysWithValues: allFiles().map { ($0.path, (try? Data(contentsOf: $0.url)) ?? Data()) })
        do {
            let url = try export(includeKeys: false)
            let s = try peek(url)
            try restore(url)
            let after = Dictionary(uniqueKeysWithValues: allFiles().map { ($0.path, (try? Data(contentsOf: $0.url)) ?? Data()) })
            let same = before == after
            NSLog("[backup-selftest] files=\(s.files) bytes=\(s.bytes) before=\(before.count) after=\(after.count) identical=\(same)")
            try? FileManager.default.removeItem(at: url)
        } catch {
            NSLog("[backup-selftest] FAILED \(error)")
        }
    }
    #endif

    // MARK: - 小端整数

    private static func u32(_ v: Int) -> Data { withUnsafeBytes(of: UInt32(v).littleEndian) { Data($0) } }
    private static func u64(_ v: UInt64) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
    private static func readU32(_ d: Data) -> UInt32 { d.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) } }
    private static func readU64(_ d: Data) -> UInt64 { d.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self)) } }
}
#endif
