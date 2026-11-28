//
//  RemovalPanel.swift
//  nodeloc
//
//  帖子被移除并扣除声望 — the panel the design puts at the top of a topic whose
//  first post a manager hid or deleted, and the appeal sheet behind it.
//
//  The server sends a different slice of `removal` to each audience, so this
//  draws whatever arrived rather than deciding for itself who may see what:
//  the reason, who acted and the penalty are public (the design shows a
//  passer-by "作者 −20 声望"); the before/after balance goes to the author and
//  the node's managers; `canAppeal` only ever reaches the author.
//
//  The web has no appeal entry for authors yet, so this is the only place a
//  member can contest a removal.
//

import SwiftUI

struct RemovalPanel: View {
    let removal: TopicRemoval
    /// The reader wrote the topic: the full card (App-iOS-PostRemoved).
    /// Everyone else gets the short one (App-iOS-PostRemovedOther).
    var isAuthor = false
    var nodeSlug: String?
    var authorName: String?
    let onAppeal: () -> Void
    var onRules: (() -> Void)?
    var onReputation: (() -> Void)?

    var body: some View {
        if isAuthor {
            authorCard
        } else {
            publicCard
        }
    }

    // MARK: Author

    private var authorCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "nosign")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(AdminTone.orange.text, in: Circle())
                Text(headline)
                    .font(Theme.body(16, weight: .bold))
                    .foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 6)
                if let penalty = penaltyText {
                    Text(penalty)
                        .font(Theme.body(14, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .frame(height: 30)
                        .background(removal.refunded == true ? Theme.success : AdminTone.orange.text, in: Capsule())
                }
            }

            if let reason = removal.reason, !reason.isEmpty {
                (Text(AppString("原因：")).bold() + Text(reason))
                    .font(Theme.body(15))
                    .foregroundStyle(Theme.text)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            }

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                if let before = removal.reputationBefore, let after = removal.reputationAfter {
                    tile(
                        AppString("声望"),
                        value: "\(before.formatted()) → \(after.formatted())",
                        note: removal.refunded == true
                            ? AppString("已返还 \(removal.reputationPenalty ?? 0)")
                            : AppString("本次扣除 \(removal.reputationPenalty ?? 0)")
                    )
                }
                if let by = removal.by, !by.isEmpty {
                    tile(AppString("处理人"), value: by, note: handlerNote)
                }
                if let strikes = removal.strikes90D, strikes > 0 {
                    tile(AppString("违规记录"), value: AppString("近 90 天第 \(strikes) 次"), note: nil)
                }
                if removal.appealable == true || removal.appealDeadline != nil {
                    tile(AppString("申诉期限"), value: deadlineValue, note: deadlineNote)
                }
            }

            Label {
                Text(AppString("这篇帖子现在只有你和版主能看到，不会出现在节点和首页里。已有的回复会保留，但帖子不再产生声望。"))
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "eye.slash")
            }
            .font(Theme.body(14))
            .foregroundStyle(Theme.textMuted)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    if removal.canAppeal == true, removal.appealed != true {
                        pill(AppString("我要申诉"), filled: true, action: onAppeal)
                    } else if removal.appealed == true {
                        Text(AppString("已申诉，等待处理"))
                            .font(Theme.body(14, weight: .semibold))
                            .foregroundStyle(Theme.textMuted)
                            .padding(.horizontal, 4)
                    }
                    if let onRules {
                        pill(AppString("查看社区规则"), filled: false, action: onRules)
                    }
                    if let onReputation {
                        pill(AppString("声望记录"), filled: false, action: onReputation)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AdminTone.orange.fill.opacity(0.7), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(AdminTone.orange.text.opacity(0.22), lineWidth: 1)
        )
    }

    private func tile(_ title: String, value: String, note: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(Theme.body(13))
                .foregroundStyle(Theme.textMuted)
            Text(value)
                .font(Theme.body(16, weight: .bold))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if let note {
                Text(note)
                    .font(Theme.body(12))
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(1)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 86, alignment: .topLeading)
        .background(Theme.bg, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(AdminTone.orange.text.opacity(0.18), lineWidth: 1)
        )
    }

    private func pill(_ title: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Theme.body(14, weight: .bold))
                .foregroundStyle(filled ? Theme.bg : Theme.text)
                .padding(.horizontal, 16)
                .frame(height: 40)
                .background(filled ? Theme.text : Theme.surface, in: Capsule())
                .overlay(Capsule().strokeBorder(filled ? Color.clear : Theme.divider, lineWidth: 1))
        }
        .buttonStyle(.pressable)
    }

    // MARK: Everyone else

    private var publicCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "nosign")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.textMuted)
                .frame(width: 36, height: 36)
                .background(Theme.divider.opacity(0.6), in: Circle())
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(headline)
                        .font(Theme.body(15, weight: .bold))
                        .foregroundStyle(Theme.text)
                    if let penalty = removal.reputationPenalty, penalty > 0, removal.refunded != true {
                        Text(AppString("作者 −\(penalty) 声望"))
                            .font(Theme.body(12, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 9)
                            .frame(height: 24)
                            .background(AdminTone.orange.text, in: Capsule())
                    }
                }
                Text(publicSentence)
                    .font(Theme.body(13))
                    .foregroundStyle(Theme.textMuted)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Theme.divider, lineWidth: 1)
        )
    }

    /// 原因：重复发帖 · 版主 夏至未至 · 今天 10:24。作者 u/林见川 因此被扣除 20 声望。正文不再显示，已有的回复仍然可以看。
    private var publicSentence: String {
        var head: [String] = []
        if let reason = removal.reason?.trimmingCharacters(in: CharacterSet(charactersIn: "。. ")), !reason.isEmpty {
            head.append(AppString("原因：\(reason)"))
        }
        if let by = removal.by, !by.isEmpty {
            head.append(removal.byStaff == true ? AppString("站务 \(by)") : AppString("版主 \(by)"))
        }
        if let at = removal.at { head.append(DiscourseFormat.relative(at)) }
        var text = head.joined(separator: " · ")
        if !text.isEmpty { text += AppString("。") }
        if let penalty = removal.reputationPenalty, penalty > 0, removal.refunded != true, let authorName, !authorName.isEmpty {
            text += AppString("作者 u/\(authorName) 因此被扣除 \(penalty) 声望。")
        }
        text += AppString("正文不再显示，已有的回复仍然可以看。")
        return text
    }

    // MARK: Wording

    private var headline: String {
        removal.byStaff == true ? AppString("这篇帖子已被站务移除") : AppString("这篇帖子已被版主移除")
    }

    private var penaltyText: String? {
        guard let penalty = removal.reputationPenalty, penalty > 0 else { return nil }
        return removal.refunded == true ? AppString("已返还 \(penalty) 声望") : AppString("−\(penalty) 声望")
    }

    /// n/indie 版主 · 今天 10:24
    private var handlerNote: String? {
        var parts: [String] = []
        if removal.byStaff == true {
            parts.append(AppString("站务"))
        } else if let nodeSlug {
            parts.append(AppString("n/\(nodeSlug) 版主"))
        }
        if let at = removal.at { parts.append(DiscourseFormat.relative(at)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var deadlineValue: String {
        if removal.appealed == true { return AppString("已申诉") }
        guard let deadline = DiscourseFormat.date(removal.appealDeadline) else { return AppString("可以申诉") }
        let left = deadline.timeIntervalSinceNow
        guard left > 0 else { return AppString("已过期") }
        let days = Int(left / 86_400)
        let hours = Int(left.truncatingRemainder(dividingBy: 86_400) / 3_600)
        return days > 0 ? AppString("还剩 \(days) 天 \(hours) 小时") : AppString("还剩 \(max(hours, 1)) 小时")
    }

    private var deadlineNote: String? {
        removal.appealed == true ? AppString("等待管理人员处理") : AppString("逾期不再受理")
    }
}

/// Where an appeal gets written. One attempt per removal or penalty, so the
/// sheet says so before it is spent.
///
/// Serves both appeal endpoints, which differ: a content appeal takes 1–1000
/// characters and no reason, a penalty appeal 10–2000 and one of two reasons.
/// The caller supplies the bounds rather than this guessing them.
struct AppealSheet: View {
    let title: String
    let note: String
    var minimum = 1
    var limit = 1000
    /// Non-empty turns on the reason picker, for penalty appeals.
    var reasons: [DiscourseClient.AppealReason] = []
    /// Returns true when the server accepted it, which dismisses the sheet.
    let onSubmit: (String) async -> Bool
    /// Only called when `reasons` is non-empty.
    var onPickReason: (DiscourseClient.AppealReason) -> Void = { _ in }

    @State private var text = ""
    @State private var reason: DiscourseClient.AppealReason = .wrong
    @State private var isSubmitting = false
    @Environment(\.dismiss) private var dismiss

    private var isValid: Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count >= minimum && trimmed.count <= limit
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text(note)
                    .font(Theme.body(12))
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)

                if !reasons.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(reasons, id: \.self) { option in
                            Button {
                                reason = option
                                onPickReason(option)
                            } label: {
                                Text(option.title)
                                    .font(Theme.body(12, weight: reason == option ? .semibold : .regular))
                                    .foregroundStyle(reason == option ? Theme.accent700 : Theme.textMuted)
                                    .padding(.vertical, 6)
                                    .padding(.horizontal, 12)
                                    .background(
                                        reason == option ? Theme.accent.opacity(0.12) : Theme.surface,
                                        in: Capsule()
                                    )
                            }
                            .buttonStyle(.pressable)
                        }
                        Spacer(minLength: 0)
                    }
                }

                TextEditor(text: $text)
                    .font(Theme.body(14))
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .frame(minHeight: 160)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous))

                Text("\(text.count) / \(limit)")
                    .font(Theme.body(11))
                    .foregroundStyle(isValid || text.isEmpty ? Theme.textFaint : Theme.danger)
                    .frame(maxWidth: .infinity, alignment: .trailing)

                Spacer(minLength: 0)
            }
            .padding(16)
            .background(Theme.bg)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppString("取消")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSubmitting {
                        ProgressView().controlSize(.small)
                    } else {
                        Button(AppString("提交")) {
                            Task {
                                isSubmitting = true
                                let ok = await onSubmit(text.trimmingCharacters(in: .whitespacesAndNewlines))
                                isSubmitting = false
                                if ok { dismiss() }
                            }
                        }
                        .disabled(!isValid)
                    }
                }
            }
        }
    }
}
