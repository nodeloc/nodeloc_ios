//
//  ChatView.swift
//  nodeloc
//

import SwiftUI

private enum MessagePane: CaseIterable {
    case notifications
    case privateMessages
    case chat

    var title: String {
        switch self {
        case .notifications: return "通知"
        case .privateMessages: return "私信"
        case .chat: return "聊天"
        }
    }
}

struct ChatView: View {
    @Environment(AppState.self) private var app
    @State private var store = MessageCenterStore()
    @State private var selection: MessagePane = .notifications

    var body: some View {
        VStack(spacing: 0) {
            messageHeader
            messageTabs

            if store.needsLogin {
                guestPrompt
            } else {
                messageContent
            }
        }
        .background(Theme.bg.ignoresSafeArea())
        .task { await store.load() }
    }

    private var messageHeader: some View {
        ZStack {
            Text("Message")
                .font(Theme.heading(24, weight: .semibold))
                .foregroundStyle(Theme.text)

            HStack {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        app.overlay = .sidebar
                    }
                } label: {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.headerText)
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.glass(.regular.tint(Theme.bg.opacity(0.34))))
                .buttonBorderShape(.circle)
                .shadow(color: .black.opacity(0.08), radius: 9, y: 6)

                Spacer()

                HStack(spacing: 0) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            app.overlay = .compose
                        }
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 14, weight: .semibold))
                            .frame(width: 34, height: 34)
                    }

                    Button {} label: {
                        Image(systemName: "checkmark.message")
                            .font(.system(size: 14, weight: .semibold))
                            .frame(width: 34, height: 34)
                    }

                    Button {} label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 14, weight: .semibold))
                            .frame(width: 34, height: 34)
                    }
                }
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 5)
                .frame(height: 50)
                .glassBackground(in: Capsule(), tint: Theme.bg.opacity(0.34))
                .shadow(color: .black.opacity(0.08), radius: 9, y: 6)
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 18)
    }

    private var messageTabs: some View {
        HStack(spacing: 0) {
            ForEach(MessagePane.allCases, id: \.self) { pane in
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        selection = pane
                    }
                } label: {
                    VStack(spacing: 10) {
                        Text(pane.title)
                            .font(Theme.body(18, weight: selection == pane ? .semibold : .medium))
                            .foregroundStyle(selection == pane ? Theme.text : Theme.muted(0.5))
                        Rectangle()
                            .fill(selection == pane ? Theme.accent : Color.clear)
                            .frame(width: 56, height: 3)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Theme.divider)
                .frame(height: 1)
        }
    }

    @ViewBuilder
    private var messageContent: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if store.isLoading {
                    ProgressView()
                        .tint(Theme.accent)
                        .padding(.top, 44)
                }

                switch selection {
                case .notifications:
                    notificationList(store.notifications, emptyTitle: "暂无通知", emptyIcon: "bell")
                case .privateMessages:
                    notificationList(store.privateMessages, emptyTitle: "暂无私信通知", emptyIcon: "envelope")
                case .chat:
                    chatList
                }

                if let errorText = store.errorText, !store.isLoading {
                    Text(errorText)
                        .font(Theme.body(12, weight: .medium))
                        .foregroundStyle(Theme.danger)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.top, 14)
                }
            }
            .padding(.top, 14)
            .padding(.bottom, 100)
        }
        .scrollIndicators(.hidden)
    }

    private func notificationList(_ items: [AppNotification], emptyTitle: String, emptyIcon: String) -> some View {
        Group {
            ForEach(items) { notification in
                MessageNotificationRow(notification: notification)
            }

            if !store.isLoading && items.isEmpty {
                emptyState(title: emptyTitle, icon: emptyIcon)
            }
        }
    }

    private var chatList: some View {
        Group {
            ForEach(store.chats) { chat in
                MessageChatRow(chat: chat)
            }

            if !store.isLoading && store.chats.isEmpty {
                emptyState(title: "暂无聊天", icon: "bubble.left.and.bubble.right")
            }
        }
    }

    private func emptyState(title: String, icon: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 32, weight: .medium))
                .foregroundStyle(Theme.muted(0.38))
            Text(title)
                .font(Theme.body(14, weight: .medium))
                .foregroundStyle(Theme.muted(0.58))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    private var guestPrompt: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "tray")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(Theme.neutral500)
            Text("登录后查看消息")
                .font(Theme.body(14, weight: .medium))
                .foregroundStyle(Theme.muted(0.6))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 80)
    }
}

private struct MessageNotificationRow: View {
    let notification: AppNotification

    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            ZStack {
                Circle()
                    .fill(iconBackground)
                Image(systemName: icon)
                    .font(.system(size: 16, weight: iconWeight))
                    .foregroundStyle(iconColor)
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(notification.name)
                        .font(Theme.body(15, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(notification.time)
                        .font(Theme.body(12))
                        .foregroundStyle(Theme.muted(0.5))
                        .lineLimit(1)
                }

                Text(notification.text)
                    .font(Theme.body(14))
                    .lineSpacing(3)
                    .foregroundStyle(Theme.text.opacity(0.68))
                    .lineLimit(2)
            }

            if notification.unread {
                Circle()
                    .fill(Theme.accent)
                    .frame(width: 8, height: 8)
                    .padding(.top, 7)
            }
        }
        .padding(.vertical, 13)
        .padding(.horizontal, 20)
        .background(notification.unread ? Theme.accent.opacity(0.05) : Color.clear)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.divider).frame(height: 1)
        }
    }

    private var icon: String {
        switch notification.kind {
        case .like: return "heart.fill"
        case .comment: return "bubble.left"
        case .message: return "envelope.fill"
        case .success: return "checkmark"
        case .star: return "star.fill"
        }
    }

    private var iconWeight: Font.Weight {
        (notification.kind == .success || notification.kind == .comment) ? .bold : .regular
    }

    private var iconColor: Color {
        switch notification.kind {
        case .like: return Theme.love
        case .comment: return Theme.accent700
        case .message: return Theme.text
        case .success: return Theme.success
        case .star: return Theme.accent2_600
        }
    }

    private var iconBackground: Color {
        switch notification.kind {
        case .like: return Theme.surface.blended(with: Theme.love, fraction: 0.15)
        case .comment: return Theme.surface.blended(with: Theme.accent, fraction: 0.15)
        case .message: return Theme.surface.blended(with: Theme.text, fraction: 0.08)
        case .success: return Theme.surface.blended(with: Theme.success, fraction: 0.15)
        case .star: return Theme.surface.blended(with: Theme.accent2_500, fraction: 0.18)
        }
    }
}

private struct MessageChatRow: View {
    let chat: Chat

    var body: some View {
        HStack(spacing: 13) {
            Avatar(letter: chat.letter, variant: chat.variant, size: 42)

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(chat.name)
                        .font(Theme.body(15, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(chat.time)
                        .font(Theme.body(12))
                        .foregroundStyle(Theme.muted(0.5))
                        .lineLimit(1)
                }

                Text(chat.lastMsg)
                    .font(Theme.body(14))
                    .foregroundStyle(Theme.text.opacity(0.68))
                    .lineLimit(2)
            }

            if chat.unread {
                Circle()
                    .fill(Theme.accent)
                    .frame(width: 8, height: 8)
            }
        }
        .padding(.vertical, 13)
        .padding(.horizontal, 20)
        .background(chat.unread ? Theme.accent.opacity(0.05) : Color.clear)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.divider).frame(height: 1)
        }
    }
}
