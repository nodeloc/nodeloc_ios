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
    let onAppeal: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: removal.kind == "hide" ? "eye.slash.fill" : "trash.fill")
                    .font(.system(size: 12, weight: .semibold))
                Text(headline)
                    .font(Theme.body(13, weight: .semibold))
                Spacer(minLength: 0)
            }
            .foregroundStyle(Theme.danger)

            if let reason = removal.reason, !reason.isEmpty {
                Text(AppString("原因：\(reason)"))
                    .font(Theme.body(13))
                    .foregroundStyle(Theme.text.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Public, by design: a passer-by sees what it cost.
            if let penalty = removal.reputationPenalty, penalty > 0 {
                HStack(spacing: 6) {
                    Text(removal.refunded == true
                         ? AppString("已返还 \(penalty) 声望")
                         : AppString("扣除 \(penalty) 声望"))
                        .font(Theme.body(12, weight: .semibold))
                        .foregroundStyle(removal.refunded == true ? Theme.success : Theme.danger)
                    // Author and managers only.
                    if let before = removal.reputationBefore, let after = removal.reputationAfter {
                        Text("\(before) → \(after)")
                            .font(Theme.body(11))
                            .foregroundStyle(Theme.muted(0.45))
                    }
                }
            }

            HStack(spacing: 8) {
                if let by = removal.by, !by.isEmpty {
                    Text(removal.byStaff == true ? AppString("站务 \(by)") : AppString("版主 \(by)"))
                }
                if let at = removal.at {
                    Text("· \(DiscourseFormat.relative(at))")
                }
                // Repeat offences, as the design shows them.
                if let strikes = removal.strikes90d, strikes > 1 {
                    Text(AppString("· 90 天内第 \(strikes) 次"))
                }
            }
            .font(Theme.body(11))
            .foregroundStyle(Theme.muted(0.45))

            appealLine
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.danger.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Theme.danger.opacity(0.18), lineWidth: 1)
        )
    }

    private var headline: String {
        switch removal.kind {
        case "hide": AppString("这个主题已被管理人员隐藏")
        case "topic": AppString("这个主题已被管理人员删除")
        default: AppString("这个帖子已被管理人员删除")
        }
    }

    /// Only the author ever gets `canAppeal`, so this whole line is invisible
    /// to everyone else.
    @ViewBuilder
    private var appealLine: some View {
        if removal.appealed == true {
            Text(AppString("你已经申诉过，等待管理人员处理"))
                .font(Theme.body(12))
                .foregroundStyle(Theme.muted(0.5))
        } else if removal.canAppeal == true {
            VStack(alignment: .leading, spacing: 6) {
                Button(action: onAppeal) {
                    Text(AppString("我要申诉"))
                        .font(Theme.body(13, weight: .semibold))
                        .foregroundStyle(Theme.accent700)
                        .padding(.vertical, 7)
                        .padding(.horizontal, 14)
                        .background(Theme.accent.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.pressable)

                if let deadline = removal.appealDeadline {
                    Text(AppString("申诉截止 \(DiscourseFormat.relative(deadline))"))
                        .font(Theme.body(11))
                        .foregroundStyle(Theme.muted(0.4))
                }
            }
        }
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
                    .foregroundStyle(Theme.muted(0.55))
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
                                    .foregroundStyle(reason == option ? Theme.accent700 : Theme.muted(0.5))
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
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                Text("\(text.count) / \(limit)")
                    .font(Theme.body(11))
                    .foregroundStyle(isValid || text.isEmpty ? Theme.muted(0.4) : Theme.danger)
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
