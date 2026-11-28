//
//  HiddenPostViews.swift
//  nodeloc
//
//  A hidden post as each reader sees it (App-iOS-PostHidden, -PostHold):
//
//  - everyone else: only 「这个帖子已被暂时隐藏。」;
//  - the author: why, and what to do — edit it (a rule-hidden post is judged
//    again automatically), appeal a staff hiding, or wait for review;
//  - the node's managers: the content, with why it is hidden.
//
//  The wording is the scheme's, as written.
//

import SwiftUI

/// The placeholder everyone but the author and managers sees.
struct HiddenPostPlaceholder: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "eye.slash")
                .font(.system(size: 14, weight: .semibold))
            Text(AppString("这个帖子已被暂时隐藏。"))
                .font(Theme.body(14, weight: .semibold))
        }
        .foregroundStyle(Theme.textMuted)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.divider, lineWidth: 1)
        }
    }
}

/// 等待审核 — the author's own held post, shown to them with the badge.
struct HeldPostBadge: View {
    var body: some View {
        HStack(spacing: 8) {
            AdminBadge(text: AppString("等待审核"), tone: .amber, icon: "hourglass")
            Text(AppString("审核通过后显示，别人现在看不到"))
                .font(Theme.body(12))
                .foregroundStyle(Theme.textMuted)
                .lineLimit(1)
        }
    }
}

/// What the author (or a manager) sees above a hidden post's content.
struct HiddenPostNotice: View {
    let state: PostHiddenState
    /// The first post (whole topic hidden) rather than a reply.
    let isFirstPost: Bool
    /// The reader wrote it.
    let isAuthor: Bool
    var onEdit: (() -> Void)?
    var onAppeal: (() -> Void)?

    var body: some View {
        if state.isHeld {
            HeldPostBadge()
        } else if !isAuthor {
            managerLine
        } else {
            authorBox
        }
    }

    /// A manager reads the content; this says why others don't.
    private var managerLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "eye.slash")
                .font(.system(size: 12, weight: .semibold))
            Text([AppString("已隐藏"), Self.reasonTitle(state.reason), state.note]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                .font(Theme.body(12))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(AdminTone.amber.text)
    }

    private var authorBox: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "eye.slash")
                    .font(.system(size: 17, weight: .semibold))
                VStack(alignment: .leading, spacing: 6) {
                    Text(headline)
                        .font(Theme.body(15, weight: .bold))
                        .foregroundStyle(Theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                    if let follow = followUp {
                        Text(follow)
                            .font(Theme.body(13))
                            .foregroundStyle(Theme.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .foregroundStyle(AdminTone.amber.text)

            if let note = state.note, !note.isEmpty {
                (Text(AppString("原因：")).bold().foregroundColor(AdminTone.amber.text) + Text(note).foregroundColor(Theme.text))
                    .font(Theme.body(13))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.bg, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            HStack(spacing: 8) {
                if let onEdit {
                    Button(action: onEdit) {
                        Label(isFirstPost ? AppString("编辑首帖") : AppString("编辑帖子"), systemImage: "pencil")
                            .font(Theme.body(14, weight: .bold))
                            .foregroundStyle(Theme.bg)
                            .padding(.horizontal, 16)
                            .frame(height: 38)
                            .background(Theme.text, in: Capsule())
                    }
                    .buttonStyle(.pressable)
                }
                if !state.isRule, let onAppeal {
                    Button(action: onAppeal) {
                        Text(AppString("申诉"))
                            .font(Theme.body(14, weight: .bold))
                            .foregroundStyle(Theme.text)
                            .padding(.horizontal, 16)
                            .frame(height: 38)
                            .background(Theme.bg, in: Capsule())
                            .overlay(Capsule().strokeBorder(Theme.divider, lineWidth: 1))
                    }
                    .buttonStyle(.pressable)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AdminTone.amber.fill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(AdminTone.amber.text.opacity(0.25), lineWidth: 1)
        }
    }

    private var headline: String {
        if state.isRule {
            return isFirstPost
                ? AppString("首帖可能不符合发帖规则，已被暂时隐藏，等待管理人员复核。")
                : AppString("这个帖子可能不符合发帖规则，已被暂时隐藏，等待管理人员复核。")
        }
        return AppString("别人看不到这个帖子，改了会重新交给管理人员审核")
    }

    private var followUp: String? {
        guard state.isRule else { return nil }
        return isFirstPost
            ? AppString("编辑首帖使它符合规定后会自动重新判定，通过就恢复显示；你也可以等管理人员复核。")
            : AppString("编辑帖子使它符合规定后会自动重新判定，通过就恢复显示。")
    }

    static func reasonTitle(_ reason: String?) -> String? {
        switch reason {
        case "rule": AppString("可能违反发帖规则")
        case "spam": AppString("疑似垃圾内容")
        case "staff": AppString("管理人员隐藏")
        case nil: nil
        default: AppString("举报后隐藏")
        }
    }
}
