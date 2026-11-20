#if LITE
import MeleLiteCore
import SwiftUI

/// 世界书导入（10-11 内测反馈）：选一个文件 → 手机上先读（MeleLiteCore/LoreImport）→ 看一眼读到几条、给谁 → 一条条存。
/// 在手机上读，存走跟手写一样的 POST lore，所以手机里的小管家和 Host 都能用。
struct LoreImportFile: Identifiable {
    let id = UUID()
    let name: String
    let entries: [MeleLiteCore.LoreEntry]
    let skipped: Int
    var whole: [MeleLiteCore.LoreEntry] = []      // 整份导入（11-19）：txt 才有，切成 ≤2000 字的常驻块
    var wholeChars = 0
}

struct LoreImportSheet: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var theme: AppTheme
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: LoreStore
    let file: LoreImportFile

    @State private var forWho = ""
    @State private var saved = 0
    @State private var saving = false
    @State private var occasional = false                 // 整份导成「偶尔想起」（10-14）
    @State private var dropped: Set<String> = []          // 预览里点掉的（10-14：一长串梗清单，不要的点一下）
    @State private var asWhole = false                    // 整份导入，不拆（11-19）
    private var shown: [MeleLiteCore.LoreEntry] { asWhole ? file.whole : file.entries }
    private var picked: [MeleLiteCore.LoreEntry] { shown.filter { !dropped.contains($0.id) } }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if asWhole {
                        Text(file.whole.count > 1
                             ? String(localized: "整份 \(file.wholeChars) 字，分成 \(file.whole.count) 条存")
                             : String(localized: "整份 \(file.wholeChars) 字，存成 1 条"))
                    } else {
                        Text(file.skipped > 0
                             ? String(localized: "读到 \(file.entries.count) 条（另有 \(file.skipped) 条没有关键词或是空的，跳过）")
                             : String(localized: "读到 \(file.entries.count) 条"))
                    }
                    Picker(String(localized: "给谁"), selection: $forWho) {
                        ForEach(model.companions) { c in Text(c.name).tag(c.id.uuidString.lowercased()) }
                        Text(String(localized: "所有人都知道")).tag("")
                    }
                    if !file.whole.isEmpty {
                        Toggle(String(localized: "整份导入，不拆"), isOn: $asWhole)
                            .onChange(of: asWhole) { _, _ in dropped = [] }
                    }
                    if !asWhole { Toggle(String(localized: "偶尔想起"), isOn: $occasional) }
                } footer: {
                    Text((asWhole
                          ? String(localized: "整份一直记着，每轮都带上，不用等说到关键词。一条最多 2000 字，长的按段落分成几条。文件越长，每轮越费额度。")
                          : String(localized: "开着：不用等说到关键词，隔几轮它会随手想起一条自己用（适合梗清单）。导进来以后点这一组还能一条条挑。")) + "\n" + file.name)
                }
                Section {
                    ForEach(shown) { e in
                        HStack(alignment: .top, spacing: 10) {
                        Image(systemName: dropped.contains(e.id) ? "circle" : "checkmark.circle.fill")
                            .foregroundStyle(dropped.contains(e.id) ? theme.inkFaint : theme.accentDeep)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(e.title).font(Typo.sans(Typo.Size.body, .medium)).foregroundStyle(theme.ink)
                                if e.constant { Text(String(localized: "常驻")).font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.accentDeep) }
                                if !e.enabled { Text(String(localized: "关着")).font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkFaint) }
                            }
                            Text(e.keys.joined(separator: "、")).font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkDim).lineLimit(1)
                            Text(e.content).font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkFaint).lineLimit(2)
                        }
                        }
                        .opacity(dropped.contains(e.id) ? 0.5 : 1)
                        .contentShape(Rectangle())
                        .onTapGesture { if dropped.contains(e.id) { dropped.remove(e.id) } else { dropped.insert(e.id) } }
                    }
                } header: { Text(String(localized: "点一下不要这条")) }
                if let err = store.error { Text(err).foregroundStyle(.red) }
            }
            .navigationTitle(String(localized: "导入世界书"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(String(localized: "取消")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if saving { Text("\(saved)/\(picked.count)").foregroundStyle(theme.inkDim) }
                    else { Button(String(localized: "导入 \(picked.count) 条")) { Task { await save() } }.disabled(picked.isEmpty) }
                }
            }
            .onAppear {
                forWho = model.primaryCompanion?.id.uuidString.lowercased() ?? ""
                if file.entries.isEmpty { asWhole = true }        // 拆不出来就直接整份
            }
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        for e in picked {
            let body: [String: Any] = ["name": e.title, "keywords": e.keys.joined(separator: ", "), "content": e.content,
                                       "enabled": e.enabled, "constant": e.constant, "occasional": occasional && !e.constant && !asWhole,
                                       "source": (file.name as NSString).deletingPathExtension,
                                       "companion_id": forWho.isEmpty ? NSNull() : forWho]
            guard await store.save(nil, body: body) else { return }    // 出错就停，前面的已经存好
            saved += 1
        }
        dismiss()
    }

    /// 读文件：失败给一句人话
    static func read(_ url: URL, charName: String, userName: String) -> Result<LoreImportFile, CardError> {
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        let zh = !(Bundle.main.preferredLocalizations.first ?? "zh").hasPrefix("en")
        guard let data = try? Data(contentsOf: url) else {
            return .failure(CardError(message: zh ? "这个文件打不开" : "Couldn't open this file"))
        }
        // 整份导入只给 txt（JSON 世界书本来就是一条条的）
        let isJSON = (try? JSONSerialization.jsonObject(with: data)) != nil
        let text = isJSON || data.count > 5 * 1024 * 1024 ? nil : LoreImport.decodeText(data)
        let whole = text.map { LoreImport.whole($0, fileName: url.lastPathComponent, charName: charName,
                                                userName: userName, lang: zh ? .zh : .en) } ?? []
        let chars = whole.reduce(0) { $0 + $1.content.count }
        do {
            let (es, skipped) = try LoreImport.parse(data, fileName: url.lastPathComponent, charName: charName,
                                                     userName: userName, lang: zh ? .zh : .en)
            return .success(LoreImportFile(name: url.lastPathComponent, entries: es, skipped: skipped, whole: whole, wholeChars: chars))
        } catch let e as CardError {
            if !whole.isEmpty {                                    // 拆不出词条，但整份还能导
                return .success(LoreImportFile(name: url.lastPathComponent, entries: [], skipped: 0, whole: whole, wholeChars: chars))
            }
            return .failure(e)
        } catch {
            return .failure(CardError(message: zh ? "读不出来" : "Couldn't read it"))
        }
    }
}
#endif
