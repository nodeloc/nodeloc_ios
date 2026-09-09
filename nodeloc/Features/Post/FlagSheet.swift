//
//  FlagSheet.swift
//  nodeloc
//
//  举报 — Discourse's flag flow, natively.
//

import SwiftUI

/// What is being flagged.
///
/// A topic and a post are different calls, not different ids: with
/// `flag_topic=true` the server takes a *topic* id and resolves the first post
/// itself, and the two offer different flag sets (`topic_flag_types` vs
/// `post_action_types`).
struct FlagTarget: Identifiable {
    enum Kind {
        case topic
        case post
        /// A chat message. Its own endpoint, and it needs the channel as well as
        /// the message: `POST /chat/api/channels/:cid/messages/:mid/flags`.
        case chatMessage(channelID: Int)
    }

    let kind: Kind
    /// Topic id for `.topic`, post id for `.post`, message id for a chat message.
    let id: Int
    /// The author, only used to address the "message the author" option. That
    /// option is dropped when this is unknown, since its label is literally
    /// "send @{username} a message".
    var authorUsername: String?

    var isTopic: Bool {
        if case .topic = kind { return true }
        return false
    }

    var chatChannelID: Int? {
        if case .chatMessage(let channelID) = kind { return channelID }
        return nil
    }
}

/// Lists the site's own flag types, takes a message where one is required, and
/// posts to `/post_actions`.
///
/// Everything shown comes from `site.json` rather than a hardcoded list: flags
/// are admin-editable and this site adds two custom ones (推广信息, 谣言信息).
struct FlagSheet: View {
    let target: FlagTarget
    /// Stands in for `site.json` in previews and tests; nil loads from the site.
    var providedFlags: [FlagType]?
    /// Restricts the list to what the server said it will accept. Chat messages
    /// carry `available_flags` per message; topics and posts don't, and pass nil.
    var allowedNameKeys: [String]?

    @Environment(\.dismiss) private var dismiss
    @State private var flags: [FlagType] = []
    @State private var selected: FlagType?
    @State private var message = ""
    @State private var confirmedIllegal = false
    @State private var isSubmitting = false
    @State private var errorText: String?

    /// Discourse validates the message against `min_personal_message_post_length`
    /// (default 10) and `MAX_MESSAGE_LENGTH` (500, a frontend constant). The
    /// setting isn't in the anonymous `site.json`, so the default stands in — the
    /// server is still the authority and its error is surfaced.
    private static let minMessage = 10
    private static let maxMessage = 500

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text("举报会交给管理人员审核。请选择最贴切的原因。")
                        .font(Theme.body(12))
                        .foregroundStyle(Theme.muted(0.55))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 4)

                    ForEach(flags) { flag in
                        flagRow(flag)
                    }

                    if let flag = selected, flag.requireMessage == true {
                        messageField(for: flag)
                    }

                    if let errorText {
                        Text(errorText)
                            .font(Theme.body(12))
                            .foregroundStyle(Theme.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    submitButton
                        .padding(.top, 6)
                }
                .padding(18)
            }
            .scrollIndicators(.hidden)
            .background(Theme.bg)
            .navigationTitle(flagTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .disabled(isSubmitting)
        }
        .standardSheet()
        .task { await loadFlags() }
    }

    private var flagTitle: String {
        switch target.kind {
        case .topic: return AppString("举报主题")
        case .post: return AppString("举报回复")
        case .chatMessage: return AppString("举报消息")
        }
    }

    // MARK: Pieces

    private func flagRow(_ flag: FlagType) -> some View {
        let isSelected = selected?.id == flag.id
        return Button {
            selected = flag
            errorText = nil
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 17))
                    .foregroundStyle(isSelected ? Theme.accent : Theme.muted(0.35))

                VStack(alignment: .leading, spacing: 4) {
                    Text(label(for: flag))
                        .font(Theme.body(15, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    if let detail = detail(for: flag) {
                        Text(detail)
                            .font(Theme.body(12))
                            .foregroundStyle(Theme.muted(0.55))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isSelected ? Theme.accent.opacity(0.08) : Theme.surface,
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(isSelected ? Theme.accent.opacity(0.45) : Theme.divider, lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
    }

    @ViewBuilder
    private func messageField(for flag: FlagType) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(flag.isNotifyUser ? AppString("给作者的消息") : AppString("补充说明"))
                .font(Theme.body(13, weight: .semibold))
                .foregroundStyle(Theme.muted(0.55))

            TextField("请至少写 \(Self.minMessage) 个字", text: $message, axis: .vertical)
                .font(Theme.body(15))
                .lineLimit(3...8)
                .padding(12)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Theme.divider, lineWidth: 1)
                }

            HStack {
                Spacer(minLength: 0)
                Text("\(message.count)/\(Self.maxMessage)")
                    .font(Theme.body(11))
                    .foregroundStyle(message.count > Self.maxMessage ? Theme.danger : Theme.muted(0.4))
                    .monospacedDigit()
            }

            // The web modal gates illegal-content flags behind an explicit
            // confirmation; skipping it here would send a heavier report than
            // the reader realises.
            if flag.isIllegal {
                Toggle(isOn: $confirmedIllegal) {
                    Text("我确认这是违法内容，并愿意为此报告负责。")
                        .font(Theme.body(12))
                        .foregroundStyle(Theme.muted(0.6))
                }
                .tint(Theme.accent)
            }
        }
    }

    private var submitButton: some View {
        Button {
            Task { await submit() }
        } label: {
            Group {
                if isSubmitting {
                    ProgressView().tint(Theme.bg)
                } else {
                    Text(selected?.isNotifyUser == true ? AppString("发送消息") : AppString("提交举报"))
                        .font(Theme.body(15, weight: .semibold))
                }
            }
            .foregroundStyle(Theme.bg)
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(canSubmit ? Theme.accent : Theme.muted(0.25), in: Capsule())
        }
        .buttonStyle(.pressable)
        .disabled(!canSubmit || isSubmitting)
    }

    // MARK: Rules

    private var canSubmit: Bool {
        guard let flag = selected else { return false }
        guard flag.requireMessage == true else { return true }
        if flag.isIllegal, !confirmedIllegal { return false }
        return message.count >= Self.minMessage && message.count <= Self.maxMessage
    }

    /// `notify_user`'s name is "向 @%{username} 发送消息" — the placeholder is the
    /// site's, not ours, so it has to be filled in.
    private func label(for flag: FlagType) -> String {
        let name = flag.name ?? flag.nameKey ?? AppString("举报")
        guard let username = target.authorUsername else { return name }
        return name.replacingOccurrences(of: "%{username}", with: username)
    }

    /// The long description, with the HTML the site puts in some of them (links
    /// to /guidelines) reduced to text.
    private func detail(for flag: FlagType) -> String? {
        let raw = flag.description ?? flag.shortDescription
        let text = DiscourseFormat.plainText(raw)
        return text.isEmpty ? nil : text
    }

    private func loadFlags() async {
        var all = providedFlags
        if all == nil {
            let site = await SiteResources.shared.siteResponse()
            // A chat message uses the post list: `available_flags` names come
            // from `PostActionType.flag_types`, the same table.
            all = target.isTopic ? site?.topicFlagTypes : site?.postActionTypes
        }
        var usable = (all ?? []).filter { flag in
            guard flag.enabled != false, flag.isFlag == true else { return false }
            if let allowedNameKeys, let key = flag.nameKey {
                guard allowedNameKeys.contains(key) else { return false }
            }
            // `topic_flag_types` is already scoped; `post_action_types` carries
            // like as well as every flag, so it needs the applies-to check.
            guard !target.isTopic else { return true }
            if target.chatChannelID != nil {
                return flag.appliesTo?.contains("Chat::Message") ?? true
            }
            return flag.appliesTo?.contains("Post") ?? true
        }
        // Can't address a message to an author we don't know.
        if target.authorUsername == nil {
            usable.removeAll { $0.isNotifyUser }
        }
        // The web puts "message the author" first; it is the least severe
        // option and often the right one.
        if let index = usable.firstIndex(where: { $0.isNotifyUser }) {
            usable.insert(usable.remove(at: index), at: 0)
        }
        flags = usable
    }

    private func submit() async {
        guard let flag = selected else { return }
        isSubmitting = true
        errorText = nil
        defer { isSubmitting = false }
        do {
            let text = flag.requireMessage == true ? message : nil
            if let channelID = target.chatChannelID {
                try await DiscourseClient().flagChatMessage(
                    channelID: channelID,
                    messageID: target.id,
                    flagTypeID: flag.id,
                    message: text
                )
            } else {
                try await DiscourseClient().flag(
                    id: target.id,
                    typeID: flag.id,
                    message: text,
                    flagTopic: target.isTopic
                )
            }
            ToastCenter.shared.show(flag.isNotifyUser ? AppString("消息已发送") : AppString("举报已提交"))
            dismiss()
        } catch {
            // The server owns the real rules — message length, one flag per
            // post, rate limits — so its wording is what gets shown.
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

#Preview("举报") {
    // The real set nodeloc serves, including its two custom flags.
    FlagSheet(
        target: FlagTarget(kind: .post, id: 951994, authorUsername: "xiaibao"),
        providedFlags: [
            FlagType(
                id: 6, nameKey: "notify_user", name: AppString("向 @%{username} 发送消息"),
                isFlag: true, requireMessage: true,
                description: AppString("我想亲自与此人私下交流关于其帖子的事情。"),
                shortDescription: nil, enabled: true, appliesTo: ["Post"]
            ),
            FlagType(
                id: 3, nameKey: "off_topic", name: AppString("偏离话题"),
                isFlag: true, requireMessage: false,
                description: AppString("此帖子与标题和第一个帖子定义的当前讨论无关，可能应该移到其他地方。"),
                shortDescription: nil, enabled: true, appliesTo: ["Post"]
            ),
            FlagType(
                id: 1001, nameKey: "custom_", name: AppString("推广信息"),
                isFlag: true, requireMessage: false,
                description: AppString("此信息看起来是推广信息，推广内容需要发布到推广专区。"),
                shortDescription: nil, enabled: true, appliesTo: ["Topic", "Post"]
            ),
            FlagType(
                id: 4, nameKey: "inappropriate", name: AppString("不当言论"),
                isFlag: true, requireMessage: false,
                description: AppString("这个帖子包含的内容具有冒犯性、侮辱性，或违反<a href=\"/guidelines\">我们的社区准则</a>。"),
                shortDescription: nil, enabled: true, appliesTo: ["Post"]
            ),
            FlagType(
                id: 8, nameKey: "spam", name: AppString("垃圾信息"),
                isFlag: true, requireMessage: false,
                description: AppString("此帖子是广告或者蓄意破坏讨论。"),
                shortDescription: nil, enabled: true, appliesTo: ["Post"]
            ),
            FlagType(
                id: 10, nameKey: "illegal", name: AppString("非法"),
                isFlag: true, requireMessage: true,
                description: AppString("此帖子需要工作人员注意，因为我认为其中包含非法内容。"),
                shortDescription: nil, enabled: true, appliesTo: ["Post"]
            ),
            FlagType(
                id: 7, nameKey: "notify_moderators", name: AppString("其他内容"),
                isFlag: true, requireMessage: true,
                description: AppString("由于上面未列出的另一个原因，此帖子需要管理人员注意。"),
                shortDescription: nil, enabled: true, appliesTo: ["Post"]
            ),
        ]
    )
}
