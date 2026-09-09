//
//  PostPermissionView.swift
//  nodeloc
//
//  discourse-permission: the frame around a gated section of a post.
//
//  Both states are framed, on purpose. A *locked* section needs a frame so the
//  reader can see the post continues behind a requirement rather than simply
//  ending — otherwise the notice reads as an odd sentence the author wrote. An
//  *unlocked* one needs it too: knowing the author gated this part is part of
//  what it says, and without a frame the reveal is invisible to the person it
//  was revealed to.
//
//  The tint carries the requirement: replying is a community act (accent),
//  signing in is neutral, paying is money (accent2 — the same orange the
//  energy/points UI uses elsewhere).
//
//  What this view will not do is unlock a *paid* block. Points can be bought
//  with real money through discourse-points-service (Stripe/epay), so a button
//  here that spends them to reveal content would be selling digital content
//  outside in-app purchase — App Store guideline 3.1.1. The locked state is
//  shown honestly and the transaction is left to the website.
//

import SwiftUI

struct PostPermissionView: View {
    let block: PostPermissionBlock
    let metrics: PostTextMetrics
    var onImageTap: ((PostImage) -> Void)?

    @Environment(AppState.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if block.isUnlocked {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(block.blocks) { inner in
                        PostBlockView(block: inner, metrics: metrics, onImageTap: onImageTap)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            } else {
                locked
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.05), in: shape)
        .overlay {
            shape.strokeBorder(tint.opacity(0.35), lineWidth: 1)
        }
        // A ScrollView adopts its widest child, so a long notice must not be
        // allowed to report an oversized minimum width.
        .clampedToWidth()
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .bold))
            Text(title)
                .font(Theme.body(metrics.bodySize - 3, weight: .semibold))
            Spacer(minLength: 6)
            // Only ever set on a pay block, and only once unlocked — it is the
            // plugin's own social proof, so it is shown where it exists.
            if let buyers = block.buyersCount, buyers > 0 {
                Text(AppString("\(buyers) 人已购买"))
                    .font(Theme.body(metrics.bodySize - 4))
                    .opacity(0.75)
            }
            if block.isUnlocked {
                Image(systemName: "lock.open.fill")
                    .font(.system(size: 9, weight: .bold))
                    .opacity(0.6)
            }
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.1))
        .clipShape(
            UnevenRoundedRectangle(
                topLeadingRadius: 12,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: 12,
                style: .continuous
            )
        )
    }

    private var locked: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tint.opacity(0.7))
                Text(noticeText)
                    .font(Theme.body(metrics.bodySize - 1))
                    .foregroundStyle(Theme.text.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Only where the app can actually satisfy the requirement. Replying
            // happens in the composer below this post, and paying is
            // deliberately not offered here — see the note at the top.
            if case .login = block.requirement, !app.authed {
                Button {
                    presentAuth(app)
                } label: {
                    Text("登录后查看")
                        .font(Theme.body(metrics.bodySize - 2, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(tint)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The server's wording when it sent any, ours when it didn't — a locked
    /// frame with no explanation is worse than a generic one.
    private var noticeText: String {
        guard block.notice.isEmpty else { return block.notice }
        switch block.requirement {
        case .login: return AppString("此内容仅对已登录用户可见。")
        case .reply: return AppString("回复本主题后可查看此内容。")
        case .pay: return AppString("此内容需要付费查看，请在网页版购买。")
        }
    }

    private var title: String {
        switch block.requirement {
        case .login: return AppString("登录可见")
        case .reply: return AppString("回复可见")
        case .pay(let amount):
            return amount > 0
                ? AppString("付费可见 · \(amount) 能量")
                : AppString("付费可见")
        }
    }

    private var icon: String {
        switch block.requirement {
        case .login: return "person.fill"
        case .reply: return "arrowshape.turn.up.left.fill"
        case .pay: return "bolt.fill"
        }
    }

    private var tint: Color {
        switch block.requirement {
        case .reply: return Theme.accent
        case .login: return Theme.neutral700
        // The same orange the energy UI uses, so a cost reads as a cost.
        case .pay: return Theme.accent2
        }
    }
}
