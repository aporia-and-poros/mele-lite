import SwiftUI

/// 小号 + 加好友（Lite，10-04 Aporia）：消息列表右上角 ＋ →「创建小号」「加好友」。
/// 小号是你换的另一个身份（名字、这个你是谁）；拿它输联系人的微信号去申请，TA 过一会儿通过，先开口。
struct AltDTO: Decodable, Identifiable, Hashable {
    let id: String
    let userName: String
    var aboutMe: String = ""
    enum CodingKeys: String, CodingKey { case id; case userName = "user_name"; case aboutMe = "about_me" }
}

struct FriendRequestDTO: Decodable, Identifiable, Hashable {
    let id: Int
    let altName: String
    let name: String
    let state: String
    var altID: String = ""
    enum CodingKeys: String, CodingKey { case id, name, state; case altName = "alt_name"; case altID = "alt_id" }
}

/// 小号管理（消息列表右上角人头，10-04 Aporia）：大号 + 每个小号一行，点谁切成谁；能新建、能删
struct AltManagerSheet: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var theme: AppTheme
    @Environment(\.dismiss) private var dismiss
    var onNew: () -> Void = {}
    @State private var deleting: AltDTO?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("我的号").font(Typo.accent(Typo.Size.title)).foregroundStyle(theme.ink)
            ScrollView {
                VStack(spacing: 10) {
                    row(title: model.profile?.name.isEmpty == false ? model.profile!.name : String(localized: "大号"),
                        sub: String(localized: "平常的你"), icon: "person.crop.circle.fill", on: model.activeAlt == nil,
                        unread: model.companions.contains { model.hasUnread($0.id) }) { switchTo(nil) }
                    ForEach(model.alts) { a in
                        let friends = model.windows(ofAlt: a.id).count
                        row(title: a.userName, sub: a.aboutMe.isEmpty ? String(localized: "\(friends) 个好友") : a.aboutMe,
                            icon: "person.crop.circle.dashed", on: model.activeAlt == a.id, unread: model.altHasUnread(a.id)) { switchTo(a.id) }
                            .contextMenu {
                                Button(role: .destructive) { deleting = a } label: { Label("删掉这个小号", systemImage: "trash") }
                            }
                    }
                    Button { dismiss(); onNew() } label: {
                        Label("新建小号", systemImage: "plus")
                            .font(Typo.sans(Typo.Size.callout, .semibold)).foregroundStyle(theme.accentDeep)
                            .frame(maxWidth: .infinity).padding(.vertical, 14)
                            .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .strokeBorder(theme.accent.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
                    }
                    .buttonStyle(.plain)
                    if !model.alts.isEmpty {
                        Text("长按一个小号可以删掉。").font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkFaint)
                    }
                }
            }
        }
        .padding(22)
        .background(AppBackground().ignoresSafeArea())
        .confirmationDialog("删掉小号「\(deleting?.userName ?? "")」？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("删掉", role: .destructive) {
                if let a = deleting { Task { await model.deleteAlt(a.id) } }
                deleting = nil
            }
        } message: {
            Text("用它加的好友和聊天会一起删掉，找不回来。")
        }
    }

    private func switchTo(_ id: String?) {
        withAnimation(.snappy) { model.activeAlt = id }
        dismiss()
    }

    private func row(title: String, sub: String, icon: String, on: Bool, unread: Bool, tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(Typo.icon(26)).foregroundStyle(on ? theme.accentDeep : theme.inkFaint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(Typo.sans(Typo.Size.headline, .semibold)).foregroundStyle(theme.ink)
                    Text(sub).font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkFaint).lineLimit(1)
                }
                Spacer()
                if unread { UnreadDot() }
                if on { Image(systemName: "checkmark").font(Typo.icon(14, .semibold)).foregroundStyle(theme.accentDeep) }
            }
            .padding(.horizontal, 16).padding(.vertical, 13)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.white.opacity(on ? 0.85 : 0.55)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 建一个小号
struct AltIdentitySheet: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var theme: AppTheme
    @Environment(\.dismiss) private var dismiss
    var onCreated: (AltDTO) -> Void = { _ in }

    @State private var name = ""
    @State private var about = ""
    @State private var saving = false
    @State private var error: String?

    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Alt").font(Typo.accent(Typo.Size.title)).foregroundStyle(theme.ink)
            Text("换个身份。用小号加的人不知道是你，两边聊的互相看不到。")
                .font(Typo.sans(Typo.Size.callout)).foregroundStyle(theme.inkDim)
            SheetField(title: "小号叫什么", text: $name, placeholder: String(localized: "比如：小满"))
            VStack(alignment: .leading, spacing: 6) {
                Text("这个你是什么样的人（可以不写）").font(Typo.sans(Typo.Size.callout)).foregroundStyle(theme.inkDim)
                IMETextEditor(text: $about, size: Typo.Size.body)
                    .font(Typo.sans(Typo.Size.body))
                    .scrollContentBackground(.hidden)
                    .frame(height: 110)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: Radii.control).fill(Color.white.opacity(0.7)))
            }
            if let error { Text(error).font(Typo.sans(Typo.Size.callout)).foregroundStyle(.red) }
            Spacer(minLength: 0)
            SheetButton(title: saving ? "…" : String(localized: "建好，去加好友"), enabled: !trimmed.isEmpty && !saving) {
                Task { await create() }
            }
        }
        .padding(24)
        .background(AppBackground().ignoresSafeArea())
    }

    private func create() async {
        saving = true
        defer { saving = false }
        do {
            let made: AltDTO = try await model.api.call("POST", "alts", json: [
                "user_name": String(trimmed.prefix(20)),
                "about_me": String(about.trimmingCharacters(in: .whitespacesAndNewlines).prefix(400)),
            ])
            await model.refreshFriends()
            dismiss()
            onCreated(made)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// 用小号加好友：选小号 → 输微信号找人 → 写一句验证消息 → 发
struct AddFriendSheet: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var theme: AppTheme
    @Environment(\.dismiss) private var dismiss
    var preselected: AltDTO?
    var onNewAlt: () -> Void = {}

    private struct Found: Decodable {
        let companionId: String
        let name: String
        let wechatId: String
        enum CodingKeys: String, CodingKey { case name; case companionId = "companion_id"; case wechatId = "wechat_id" }
    }

    @State private var alt: AltDTO?
    @State private var wechat = ""
    @State private var found: Found?
    @State private var greeting = ""
    @State private var error: String?
    @State private var busy = false
    @State private var sent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add").font(Typo.accent(Typo.Size.title)).foregroundStyle(theme.ink)
            if sent {
                sentView
            } else if model.alts.isEmpty {
                Text("先建一个小号，再用它去加人。").font(Typo.sans(Typo.Size.callout)).foregroundStyle(theme.inkDim)
                SheetButton(title: String(localized: "创建小号"), enabled: true) { dismiss(); onNewAlt() }
                Spacer(minLength: 0)
            } else {
                altPicker
                HStack(spacing: 10) {
                    TextField("对方的微信号", text: $wechat)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .font(Typo.sans(Typo.Size.headline))
                        .padding(.leading, 12).padding(.trailing, 34).padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: Radii.control).fill(Color.white.opacity(0.7)))
                        .overlay(alignment: .trailing) {
                            if !wechat.isEmpty {
                                Button { wechat = ""; found = nil; error = nil } label: {
                                    Image(systemName: "xmark.circle.fill").font(Typo.icon(15)).foregroundStyle(theme.inkFaint)
                                        .padding(.trailing, 10)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .onSubmit { Task { await search() } }
                    Button { Task { await search() } } label: {
                        Image(systemName: "magnifyingglass").font(Typo.icon(16, .semibold)).foregroundStyle(.white)
                            .frame(width: 44, height: 44).background(Circle().fill(theme.accentDeep))
                    }
                    .buttonStyle(.plain)
                    .disabled(wechat.trimmingCharacters(in: .whitespaces).isEmpty || busy)
                }
                if let found { foundCard(found) }
                if let error { Text(error).font(Typo.sans(Typo.Size.callout)).foregroundStyle(.red) }
                Spacer(minLength: 0)
                if found != nil {
                    SheetButton(title: busy ? "…" : String(localized: "发送申请"), enabled: alt != nil && !busy) { Task { await send() } }
                }
            }
        }
        .padding(24)
        .background(AppBackground().ignoresSafeArea())
        .onAppear { alt = preselected ?? model.alts.last }
        .onChange(of: alt) { _, a in greeting = a.map { String(localized: "我是\($0.userName)") } ?? "" }
    }

    private var altPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("用哪个小号").font(Typo.sans(Typo.Size.callout)).foregroundStyle(theme.inkDim)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(model.alts) { a in
                        let on = alt?.id == a.id
                        Button { alt = a } label: {
                            Label(a.userName, systemImage: "person.crop.circle.dashed")
                                .font(Typo.sans(Typo.Size.callout, .medium))
                                .foregroundStyle(on ? .white : theme.ink)
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .background(Capsule().fill(on ? theme.accentDeep : Color.white.opacity(0.7)))
                        }
                        .buttonStyle(.plain)
                    }
                    Button { dismiss(); onNewAlt() } label: {
                        Image(systemName: "plus").font(Typo.icon(13, .semibold)).foregroundStyle(theme.accentDeep)
                            .frame(width: 34, height: 34).background(Circle().fill(Color.white.opacity(0.7)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func foundCard(_ f: Found) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                if let c = model.companions.first(where: { $0.id.uuidString.lowercased() == f.companionId }) {
                    CompanionAvatar(companion: c, size: 48)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(f.name).font(Typo.sans(Typo.Size.headline, .semibold)).foregroundStyle(theme.ink)
                    Text("微信号：\(f.wechatId)").font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkFaint)
                }
            }
            SheetField(title: "验证消息", text: $greeting, placeholder: String(localized: "我是…"))
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.45)))
    }

    private var sentView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("申请发出去了", systemImage: "paperplane").font(Typo.sans(Typo.Size.headline, .semibold)).foregroundStyle(theme.ink)
            Text("等\(found?.name ?? "TA")通过。通过了会在消息列表里多一个「小号 · \(alt?.userName ?? "")」的窗口，TA 会先跟你打招呼。")
                .font(Typo.sans(Typo.Size.callout)).foregroundStyle(theme.inkDim)
            Spacer(minLength: 0)
            SheetButton(title: String(localized: "好"), enabled: true) { dismiss() }
        }
    }

    private func search() async {
        error = nil; found = nil
        busy = true
        defer { busy = false }
        let w = wechat.trimmingCharacters(in: .whitespaces)
        do { found = try await model.api.call("GET", "friends/lookup", query: [URLQueryItem(name: "wechat_id", value: w)]) }
        catch { self.error = String(localized: "没有找到这个微信号") }
    }

    private func send() async {
        guard let alt, let found else { return }
        busy = true
        defer { busy = false }
        do {
            try await model.api.send("POST", "friends/requests", json: ["alt_id": alt.id, "wechat_id": found.wechatId,
                                                                        "greeting": greeting.trimmingCharacters(in: .whitespaces)])
            await model.refreshFriends()
            withAnimation { sent = true }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct SheetField: View {
    @EnvironmentObject private var theme: AppTheme
    let title: LocalizedStringKey
    @Binding var text: String
    let placeholder: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(Typo.sans(Typo.Size.callout)).foregroundStyle(theme.inkDim)
            TextField(placeholder, text: $text)
                .font(Typo.sans(Typo.Size.headline))
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: Radii.control).fill(Color.white.opacity(0.7)))
        }
    }
}

private struct SheetButton: View {
    @EnvironmentObject private var theme: AppTheme
    let title: String
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(Typo.sans(Typo.Size.headline, .semibold)).foregroundStyle(.white)
                .frame(maxWidth: .infinity).padding(.vertical, 14)
                .background(Capsule().fill(theme.accentDeep))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }
}
