//
//  LoginPromptSheet.swift
//  nodeloc
//
//  未登录时的登录提示弹层 (App-iOS-AuthSheet, App-iOS-AuthSheet2): the one
//  sheet a guest gets for anything that needs an account. It says what they
//  were about to do (登录后参与讨论, 登录后加入 n/indie…), what an account
//  gives them, then 登录 / 注册新账号, the terms line and 先不登录，继续看.
//

import SwiftUI

/// What the guest tried to do, which decides the sheet's headline.
enum LoginPromptContext: Identifiable, Equatable {
    case reply
    case vote
    case bookmark
    case follow
    case joinNode(name: String, slug: String)
    case content
    case chat
    case generic

    var id: String {
        switch self {
        case .joinNode(_, let slug): "join-\(slug)"
        default: String(describing: self)
        }
    }

    var title: String {
        switch self {
        case .reply: AppString("登录后参与讨论")
        case .vote: AppString("登录后点赞")
        case .bookmark: AppString("登录后收藏")
        case .follow: AppString("登录后关注")
        case .joinNode(let name, _): AppString("登录后加入 \(name)")
        case .content: AppString("登录后查看")
        case .chat: AppString("登录后发消息")
        case .generic: AppString("登录 nodeloc")
        }
    }

    var message: String {
        switch self {
        case .reply: AppString("你要回复的这个帖子会一直留在这里，登录完直接接着写。")
        case .vote: AppString("登录后就能给喜欢的内容点赞，作者会收到你的支持。")
        case .bookmark: AppString("收藏会存在你的账号里，手机和电脑都能看到。")
        case .follow: AppString("关注以后，对方的新帖会出现在你的首页。")
        case .joinNode: AppString("加入以后，新帖会出现在你的首页，成员可见的内容也能看。")
        case .content: AppString("这段内容登录后可见，登录完会回到这里。")
        case .chat: AppString("登录后就能和大家聊天、发私信。")
        case .generic: AppString("登录后可以发帖、回复、点赞，加入感兴趣的节点。")
        }
    }

    var symbol: String {
        switch self {
        case .reply: "bubble.left"
        case .vote: "arrow.up"
        case .bookmark: "star"
        case .follow: "person.badge.plus"
        case .joinNode: "person.2"
        case .content: "lock"
        case .chat: "bubble.left.and.bubble.right"
        case .generic: "person.crop.circle"
        }
    }
}

struct LoginPromptSheet: View {
    let context: LoginPromptContext
    let onLogin: () -> Void
    let onSignup: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                mark
                VStack(alignment: .leading, spacing: 4) {
                    Text(context.title)
                        .font(Theme.heading(21, weight: .bold))
                        .foregroundStyle(Theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(context.message)
                        .font(Theme.body(14))
                        .foregroundStyle(Theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Theme.textMuted)
                        .frame(width: 30, height: 30)
                        .background(Theme.chip, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(AppString("关闭"))
            }

            // What an account gives; scrolls rather than truncating in
            // longer languages.
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    chip(AppString("回复和发帖"), "bubble.left")
                    chip(AppString("点赞"), "arrow.up")
                    chip(AppString("收藏"), "star")
                    chip(AppString("加入节点"), "person.2")
                }
            }
            .scrollIndicators(.hidden)

            VStack(spacing: 10) {
                Button {
                    dismiss()
                    onLogin()
                } label: {
                    Text(AppString("登录"))
                        .font(Theme.body(16, weight: .bold))
                        .foregroundStyle(Theme.bg)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(Theme.text, in: Capsule())
                }
                .buttonStyle(.pressable)
                Button {
                    dismiss()
                    onSignup()
                } label: {
                    Text(AppString("注册新账号"))
                        .font(Theme.body(16, weight: .bold))
                        .foregroundStyle(Theme.text)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .overlay(Capsule().strokeBorder(Theme.text.opacity(0.85), lineWidth: 1.2))
                }
                .buttonStyle(.pressable)
            }

            Text(Self.terms)
                .font(Theme.body(12))
                .foregroundStyle(Theme.textMuted)
                .tint(Theme.textMuted)
                .frame(maxWidth: .infinity)

            Button { dismiss() } label: {
                Text(AppString("先不登录，继续看"))
                    .font(Theme.body(15, weight: .semibold))
                    .foregroundStyle(Theme.textMuted)
                    .frame(maxWidth: .infinity)
                    .frame(height: 36)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.top, 22)
        .padding(.bottom, 8)
        .presentationDetents([.height(440)])
        .presentationDragIndicator(.visible)
    }

    /// The links render as links: `AppString` hands back plain text.
    private static var terms: AttributedString {
        let raw = AppString("继续即表示同意[用户协议](https://www.nodeloc.com/tos)和[隐私政策](https://www.nodeloc.com/privacy)")
        return (try? AttributedString(markdown: raw)) ?? AttributedString(raw)
    }

    @ViewBuilder
    private var mark: some View {
        if case .joinNode(_, let slug) = context, let node = NodeCatalog.shared.cachedNode(slug: slug) {
            NodeAvatar(node: node, size: 52, cornerRadius: 14)
        } else {
            Image(systemName: context.symbol)
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 52, height: 52)
                .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private func chip(_ title: String, _ symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(Theme.body(12, weight: .semibold))
            .foregroundStyle(Theme.text)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 9)
            .frame(height: 30)
            .background(Theme.chip, in: Capsule())
    }
}

/// A guest-gated action anywhere: shows the prompt (from whichever screen is
/// on top) instead of going straight to the full login page.
@MainActor
func requestLogin(_ app: AppState, _ context: LoginPromptContext = .generic) {
    app.loginPrompt = context
}
