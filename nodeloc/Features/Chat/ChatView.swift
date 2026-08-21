//
//  ChatView.swift
//  nodeloc
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

private enum MessagePane: CaseIterable {
    case notifications
    case chat

    var title: String {
        switch self {
        case .notifications: return "通知"
        case .chat: return "聊天"
        }
    }
}

private enum ChatInboxFilter: CaseIterable {
    case messages
    case threads
    case search

    var title: String {
        switch self {
        case .messages: return "消息"
        case .threads: return "讨论串"
        case .search: return "搜索"
        }
    }
}

private enum ChatRoute: Hashable {
    case channel(Chat)
    case thread(ChatThreadListItem)
    case searchResult(ChatSearchResult)
    case profile(UserProfileTarget)

    var chat: Chat {
        switch self {
        case .channel(let chat):
            return chat
        case .thread(let thread):
            return Chat(
                id: thread.channelID,
                name: thread.channelName,
                letter: thread.avatarLetter,
                variant: thread.variant,
                lastMsg: thread.excerpt,
                time: thread.time,
                unread: thread.unread,
                avatarURL: thread.avatarURL
            )
        case .searchResult(let result):
            return result.chat
        case .profile:
            return Chat(id: 0, name: "", letter: "", variant: 0, lastMsg: "", time: "", unread: false)
        }
    }

    var initialThread: ChatThreadListItem? {
        switch self {
        case .channel:
            return nil
        case .thread(let thread):
            return thread
        case .searchResult(let result):
            return result.thread
        case .profile:
            return nil
        }
    }

    var targetMessageID: Int? {
        switch self {
        case .channel, .thread:
            return nil
        case .searchResult(let result):
            return result.message.id
        case .profile:
            return nil
        }
    }
}

struct ChatView: View {
    @Environment(AppState.self) private var app
    @State private var store = MessageCenterStore()
    @State private var selection: MessagePane = .notifications
    @State private var chatFilter: ChatInboxFilter = .messages
    @State private var chatSearchText = ""
    @State private var chatSearchTask: Task<Void, Never>?
    @State private var path: [ChatRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            inboxBody
                .navigationDestination(for: ChatRoute.self) { route in
                    switch route {
                    case .channel(let chat):
                        ChatConversationView(chat: chat)
                            .toolbar(.hidden, for: .navigationBar)
                            .toolbar(.hidden, for: .tabBar)
                    case .thread(let thread):
                        ChatConversationView(chat: route.chat, initialThread: thread)
                            .toolbar(.hidden, for: .navigationBar)
                            .toolbar(.hidden, for: .tabBar)
                    case .searchResult(let result):
                        ChatConversationView(
                            chat: result.chat,
                            initialThread: result.thread,
                            targetMessageID: result.message.id
                        )
                        .toolbar(.hidden, for: .navigationBar)
                        .toolbar(.hidden, for: .tabBar)
                    case .profile(let target):
                        ChatPublicProfileView(target: target)
                            .toolbar(.hidden, for: .navigationBar)
                            .toolbar(.hidden, for: .tabBar)
                    }
                }
                .toolbar(.hidden, for: .navigationBar)
        }
    }

    private var inboxBody: some View {
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
            Text("收件箱")
                .font(Theme.heading(24, weight: .semibold))
                .foregroundStyle(Theme.text)

            HStack {
                Button {
                    withAnimation(.quick) {
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
                        withAnimation(.quick) {
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
                    withAnimation(.quicker) {
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

    private var messageContent: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if selection == .chat {
                    chatFilterBar
                        .padding(.bottom, 8)
                }

                if store.isLoading {
                    ProgressView()
                        .tint(Theme.accent)
                        .padding(.top, 44)
                }

                switch selection {
                case .notifications:
                    notificationList(store.notifications, emptyTitle: "暂无通知", emptyIcon: "bell")
                case .chat:
                    chatFilteredContent
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
            .padding(.top, selection == .chat ? 12 : 14)
            .padding(.bottom, 100)
        }
        .scrollIndicators(.hidden)
    }

    private var chatFilterBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Theme.text)
                .frame(width: 34, height: 34)

            HStack(spacing: 8) {
                ForEach(ChatInboxFilter.allCases, id: \.self) { filter in
                    Button {
                        withAnimation(.quicker) {
                            chatFilter = filter
                        }
                    } label: {
                        Text(filter.title)
                            .font(Theme.body(15, weight: chatFilter == filter ? .semibold : .medium))
                            .foregroundStyle(chatFilter == filter ? Theme.text : Theme.muted(0.58))
                            .lineLimit(1)
                            .minimumScaleFactor(0.86)
                            .padding(.horizontal, 16)
                            .frame(height: 42)
                            .background(
                                chatFilter == filter ? Theme.neutral300 : Color.clear,
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
    }

    @ViewBuilder
    private var chatFilteredContent: some View {
        switch chatFilter {
        case .messages:
            chatList
        case .threads:
            threadList
        case .search:
            chatSearchContent
        }
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
                NavigationLink(value: ChatRoute.channel(chat)) {
                    MessageChatRow(chat: chat)
                }
                .buttonStyle(.plain)
            }

            if !store.isLoading && store.chats.isEmpty {
                emptyState(title: "暂无聊天", icon: "bubble.left.and.bubble.right")
            }
        }
    }

    private var threadList: some View {
        Group {
            ForEach(store.threads) { thread in
                NavigationLink(value: ChatRoute.thread(thread)) {
                    MessageThreadRow(thread: thread)
                }
                .buttonStyle(.plain)
            }

            if !store.isLoading && store.threads.isEmpty {
                emptyState(title: "暂无讨论串", icon: "text.bubble")
            }
        }
    }

    private var chatSearchContent: some View {
        VStack(spacing: 0) {
            chatSearchField
                .padding(.bottom, 8)

            if store.isSearchingChat {
                ProgressView()
                    .tint(Theme.accent)
                    .padding(.top, 32)
            }

            if chatSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                emptyState(title: "输入关键词搜索聊天", icon: "magnifyingglass")
            } else if !store.isSearchingChat && store.chatSearchResults.isEmpty {
                emptyState(title: "没有找到相关聊天", icon: "magnifyingglass")
            }

            ForEach(store.chatSearchResults) { result in
                NavigationLink(value: ChatRoute.searchResult(result)) {
                    MessageSearchResultRow(result: result)
                }
                .buttonStyle(.plain)
            }

            if let errorText = store.chatSearchErrorText {
                Text(errorText)
                    .font(Theme.body(12, weight: .medium))
                    .foregroundStyle(Theme.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 14)
            }
        }
    }

    private var chatSearchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.muted(0.48))

            TextField("搜索聊天消息", text: $chatSearchText)
                .font(Theme.body(15))
                .foregroundStyle(Theme.text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit {
                    performChatSearch()
                }

            if !chatSearchText.isEmpty {
                Button {
                    chatSearchText = ""
                    chatSearchTask?.cancel()
                    store.clearChatSearch()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.muted(0.42))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 42)
        .background(Theme.surface, in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(Theme.divider, lineWidth: 1)
        )
        .padding(.horizontal, 20)
        .onChange(of: chatSearchText) { _, newValue in
            scheduleChatSearch(newValue)
        }
        .onDisappear {
            chatSearchTask?.cancel()
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

    private func scheduleChatSearch(_ query: String) {
        chatSearchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            store.clearChatSearch()
            return
        }

        chatSearchTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            await store.searchChatMessages(query: trimmed)
        }
    }

    private func performChatSearch() {
        chatSearchTask?.cancel()
        let trimmed = chatSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            store.clearChatSearch()
            return
        }

        chatSearchTask = Task {
            await store.searchChatMessages(query: trimmed)
        }
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

private struct MessageSearchResultRow: View {
    let result: ChatSearchResult

    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            RemoteAvatar(url: result.chat.avatarURL, letter: result.chat.letter, variant: result.chat.variant, size: 42)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(result.chat.name)
                        .font(Theme.body(15, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)

                    if result.thread != nil {
                        Text("讨论串")
                            .font(Theme.body(11, weight: .semibold))
                            .foregroundStyle(Theme.accent700)
                            .padding(.horizontal, 7)
                            .frame(height: 20)
                            .background(Theme.accent.opacity(0.1), in: Capsule())
                    }

                    Spacer(minLength: 8)

                    Text(result.message.time)
                        .font(Theme.body(12))
                        .foregroundStyle(Theme.muted(0.5))
                        .lineLimit(1)
                }

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(result.message.authorName)
                        .font(Theme.body(13, weight: .semibold))
                        .foregroundStyle(Theme.muted(0.62))
                        .lineLimit(1)

                    Text(searchExcerpt)
                        .font(Theme.body(14))
                        .foregroundStyle(Theme.text.opacity(0.72))
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 13)
        .padding(.horizontal, 20)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.divider).frame(height: 1)
        }
    }

    private var searchExcerpt: String {
        result.message.text.isEmpty ? "媒体消息" : result.message.text
    }
}

private struct ChatPublicProfileView: View {
    let target: UserProfileTarget
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        PublicProfileOverlay(target: target) {
            dismiss()
        }
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
            RemoteAvatar(url: chat.avatarURL, letter: chat.letter, variant: chat.variant, size: 42)

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

            if chat.threadUnreadCount > 0 {
                Text("\(chat.threadUnreadCount)")
                    .font(Theme.body(11, weight: .bold))
                    .foregroundStyle(Theme.accent900)
                    .frame(minWidth: 18, minHeight: 18)
                    .padding(.horizontal, 3)
                    .background(Theme.accent100, in: Capsule())
            } else if chat.unread {
                Circle()
                    .fill(Theme.accent)
                    .frame(width: 8, height: 8)
            }
        }
        .padding(.vertical, 13)
        .padding(.horizontal, 20)
        .contentShape(Rectangle())
        .background(chat.unread ? Theme.accent.opacity(0.05) : Color.clear)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.divider).frame(height: 1)
        }
    }
}

private struct MessageThreadRow: View {
    let thread: ChatThreadListItem

    var body: some View {
        HStack(spacing: 13) {
            RemoteAvatar(url: thread.avatarURL, letter: thread.avatarLetter, variant: thread.variant, size: 42)

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(thread.title)
                        .font(Theme.body(15, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(thread.time)
                        .font(Theme.body(12))
                        .foregroundStyle(Theme.muted(0.5))
                        .lineLimit(1)
                }

                HStack(spacing: 6) {
                    Text(thread.channelName)
                        .font(Theme.body(13, weight: .medium))
                        .foregroundStyle(Theme.muted(0.55))
                        .lineLimit(1)
                    Text("•")
                        .font(Theme.body(12))
                        .foregroundStyle(Theme.muted(0.35))
                    Text(thread.excerpt)
                        .font(Theme.body(14))
                        .foregroundStyle(Theme.text.opacity(0.68))
                        .lineLimit(1)
                }
            }

            if thread.unread {
                Circle()
                    .fill(Theme.accent)
                    .frame(width: 8, height: 8)
            }
        }
        .padding(.vertical, 13)
        .padding(.horizontal, 20)
        .contentShape(Rectangle())
        .background(thread.unread ? Theme.accent.opacity(0.05) : Color.clear)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.divider).frame(height: 1)
        }
    }
}

private struct ChatConversationView: View {
    let chat: Chat
    var initialThread: ChatThreadListItem?
    var targetMessageID: Int?
    @Environment(\.dismiss) private var dismiss
    @State private var store = ChatConversationStore()
    @State private var draft = ""
    @State private var appliedScrollSignature: String?
    @State private var selectedMedia: PostMedia?

    var body: some View {
        VStack(spacing: 0) {
            conversationHeader
            Divider()
                .overlay(Theme.divider)
            conversationContent
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            messageInputBar
        }
        .background(Theme.bg.ignoresSafeArea())
        .fullScreenCover(item: $selectedMedia) { media in
            ChatImagePreview(media: media)
        }
        .task(id: taskID) {
            await store.load(chat: chat, initialThread: initialThread, targetMessageID: targetMessageID)
        }
    }

    private var taskID: String {
        "\(chat.id)-\(initialThread?.id ?? 0)-\(targetMessageID ?? 0)"
    }

    private var activeMessages: [ChatConversationMessage] {
        store.selectedThread == nil ? store.messages : store.threadMessages
    }

    private var activeInitialScrollMessageID: Int? {
        store.selectedThread == nil ? store.channelInitialScrollMessageID : store.threadInitialScrollMessageID
    }

    private var activeInitialScrollIsUnread: Bool {
        store.selectedThread == nil ? store.channelInitialScrollIsUnread : store.threadInitialScrollIsUnread
    }

    private var initialScrollSignature: String {
        let contextID = store.selectedThread?.id ?? 0
        guard let messageID = activeInitialScrollMessageID else {
            return "none-\(contextID)"
        }
        return "\(contextID)-\(messageID)-\(activeInitialScrollIsUnread)"
    }

    private var conversationHeader: some View {
        HStack(spacing: 12) {
            Button {
                if store.selectedThread == nil {
                    dismiss()
                } else {
                    withAnimation(.quicker) {
                        store.closeThread()
                    }
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.glass(.regular.tint(Theme.bg.opacity(0.34))))
            .buttonBorderShape(.circle)
            .shadow(color: .black.opacity(0.08), radius: 9, y: 6)

            RemoteAvatar(url: chat.avatarURL, letter: chat.letter, variant: chat.variant, size: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(store.selectedThread?.title ?? chat.name)
                    .font(Theme.body(17, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)

                if let selectedThread = store.selectedThread {
                    Text(selectedThread.channelName)
                        .font(Theme.body(12, weight: .medium))
                        .foregroundStyle(Theme.muted(0.54))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            HStack(spacing: 0) {
                Button {} label: {
                    Image(systemName: "bell")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 34, height: 34)
                }

                Button {} label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 15, weight: .semibold))
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
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    private var conversationContent: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 14) {
                    if store.selectedThread == nil {
                        conversationIntro
                        threadRail
                    } else if let selectedThread = store.selectedThread {
                        selectedThreadSummary(selectedThread)
                    }

                    if store.isLoading || store.isLoadingThread {
                        ProgressView()
                            .tint(Theme.accent)
                            .padding(.top, 24)
                    }

                    ForEach(activeMessages) { message in
                        ChatMessageBubble(
                            message: message,
                            onOpenThread: { thread in
                                openThread(thread)
                            },
                            onOpenImage: { media in
                                selectedMedia = media
                            }
                        )
                        .id(message.id)
                    }

                    if !store.isLoading && !store.isLoadingThread && activeMessages.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "bubble.left.and.bubble.right")
                                .font(.system(size: 30, weight: .medium))
                                .foregroundStyle(Theme.muted(0.34))
                            Text(store.selectedThread == nil ? "暂无消息" : "暂无线程回复")
                                .font(Theme.body(14, weight: .medium))
                                .foregroundStyle(Theme.muted(0.56))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 54)
                    }

                    if let errorText = store.errorText {
                        Text(errorText)
                            .font(Theme.body(12, weight: .medium))
                            .foregroundStyle(Theme.danger)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 6)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 22)
                .padding(.bottom, 18)
            }
            .scrollIndicators(.hidden)
            .onAppear {
                scrollToInitialTarget(with: proxy)
            }
            .onChange(of: initialScrollSignature) { _, _ in
                scrollToInitialTarget(with: proxy)
            }
        }
    }

    private var conversationIntro: some View {
        VStack(spacing: 10) {
            RemoteAvatar(url: chat.avatarURL, letter: chat.letter, variant: chat.variant, size: 104)
            Text(chat.name)
                .font(Theme.heading(24, weight: .semibold))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if !chat.lastMsg.isEmpty {
                Text(chat.lastMsg)
                    .font(Theme.body(14, weight: .medium))
                    .foregroundStyle(Theme.muted(0.58))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 22)
        .padding(.bottom, 16)
    }

    @ViewBuilder
    private var threadRail: some View {
        if !store.channelThreads.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("讨论串")
                        .font(Theme.body(14, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Spacer()
                }

                ScrollView(.horizontal) {
                    HStack(spacing: 10) {
                        ForEach(store.channelThreads) { thread in
                            Button {
                                openThread(thread)
                            } label: {
                                ChatThreadPill(thread: thread)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .scrollIndicators(.hidden)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 4)
        }
    }

    private func selectedThreadSummary(_ thread: ChatThreadListItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "text.bubble")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.accent700)
                Text("\(thread.replyCount) 条回复")
                    .font(Theme.body(13, weight: .semibold))
                    .foregroundStyle(Theme.accent700)
                Spacer()
            }

            Text(thread.excerpt)
                .font(Theme.body(14))
                .lineSpacing(3)
                .foregroundStyle(Theme.text.opacity(0.7))
                .lineLimit(3)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Theme.divider, lineWidth: 1)
        )
    }

    private var messageInputBar: some View {
        HStack(spacing: 10) {
            Button {} label: {
                Image(systemName: "plus")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .frame(width: 42, height: 42)
                    .background(Theme.neutral300, in: Circle())
            }
            .buttonStyle(.plain)

            TextField("消息", text: $draft, axis: .vertical)
                .font(Theme.body(16))
                .foregroundStyle(Theme.text)
                .lineLimit(1...4)
                .textInputAutocapitalization(.sentences)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(Theme.surface, in: Capsule())

            Button {
                sendCurrentDraft()
            } label: {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(canSend ? Theme.accent700 : Theme.muted(0.35))
                    .frame(width: 42, height: 42)
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(Theme.bg.opacity(0.92))
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.divider).frame(height: 1)
        }
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !store.isSending
    }

    private func openThread(_ thread: ChatThreadListItem) {
        Task {
            withAnimation(.quicker) {
                store.selectedThread = thread
            }
            await store.openThread(thread)
        }
    }

    private func sendCurrentDraft() {
        let text = draft
        draft = ""
        Task {
            if store.selectedThread == nil {
                await store.send(text, chat: chat)
            } else {
                await store.sendToSelectedThread(text)
            }
        }
    }

    private func scrollToInitialTarget(with proxy: ScrollViewProxy) {
        guard let targetID = activeInitialScrollMessageID else { return }
        let signature = initialScrollSignature
        guard appliedScrollSignature != signature else { return }
        let anchor: UnitPoint = activeInitialScrollIsUnread ? .center : .bottom
        appliedScrollSignature = signature

        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.18)) {
                proxy.scrollTo(targetID, anchor: anchor)
            }
        }
    }
}

private struct ChatThreadPill: View {
    let thread: ChatThreadListItem

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                RemoteAvatar(url: thread.avatarURL, letter: thread.avatarLetter, variant: thread.variant, size: 24)
                Text(thread.title)
                    .font(Theme.body(13, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
            }

            Text(thread.excerpt)
                .font(Theme.body(12))
                .foregroundStyle(Theme.text.opacity(0.62))
                .lineLimit(2)

            Text("\(thread.replyCount) 条回复")
                .font(Theme.body(11, weight: .semibold))
                .foregroundStyle(Theme.accent700)
        }
        .frame(width: 190, alignment: .leading)
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(thread.unread ? Theme.accent.opacity(0.45) : Theme.divider, lineWidth: 1)
        )
    }
}

private struct ChatMessageBubble: View {
    let message: ChatConversationMessage
    let onOpenThread: (ChatThreadListItem) -> Void
    let onOpenImage: (PostMedia) -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if message.isMine {
                Spacer(minLength: 56)
            } else {
                authorAvatar
            }

            VStack(alignment: message.isMine ? .trailing : .leading, spacing: 5) {
                HStack(spacing: 5) {
                    Text(message.authorName)
                        .font(Theme.body(12, weight: .semibold))
                        .foregroundStyle(Theme.muted(0.58))
                        .lineLimit(1)
                    if !message.time.isEmpty {
                        Text(message.time)
                            .font(Theme.body(11))
                            .foregroundStyle(Theme.muted(0.42))
                            .lineLimit(1)
                    }
                }

                if !message.text.isEmpty || !message.content.isEmpty {
                    ChatMessageContentView(message: message)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 10)
                        .background(
                            message.isMine ? Theme.accent.opacity(0.16) : Theme.surface,
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .strokeBorder(message.isMine ? Color.clear : Theme.divider, lineWidth: 1)
                        )
                }

                if !message.media.isEmpty {
                    VStack(alignment: message.isMine ? .trailing : .leading, spacing: 8) {
                        ForEach(message.media) { media in
                            ChatMessageImage(media: media) {
                                onOpenImage(media)
                            }
                        }
                    }
                }

                if let thread = message.thread {
                    Button {
                        onOpenThread(thread)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrowshape.turn.up.left.2")
                                .font(.system(size: 11, weight: .semibold))
                            Text(thread.replyCount > 0 ? "\(thread.replyCount) 条线程回复" : "查看讨论串")
                                .font(Theme.body(12, weight: .semibold))
                                .lineLimit(1)
                            if !thread.time.isEmpty {
                                Text(thread.time)
                                    .font(Theme.body(11))
                                    .foregroundStyle(Theme.muted(0.48))
                            }
                        }
                        .foregroundStyle(Theme.accent700)
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(Theme.accent.opacity(0.09), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }

            if message.isMine {
                authorAvatar
            } else {
                Spacer(minLength: 56)
            }
        }
    }

    @ViewBuilder
    private var authorAvatar: some View {
        if let target = message.authorProfileTarget {
            NavigationLink(value: ChatRoute.profile(target)) {
                avatarImage
            }
            .buttonStyle(.plain)
        } else {
            avatarImage
        }
    }

    private var avatarImage: some View {
        RemoteAvatar(url: message.avatarURL, letter: message.avatarLetter, variant: message.variant, size: 32)
            .contentShape(Circle())
    }
}

private struct ChatMessageContentView: View {
    let message: ChatConversationMessage

    var body: some View {
        if containsCustomEmoji {
            ChatInlineContentView(fragments: message.content)
        } else {
            Text(message.text)
                .font(Theme.body(15))
                .lineSpacing(3)
                .foregroundStyle(Theme.text)
        }
    }

    private var containsCustomEmoji: Bool {
        message.content.contains { fragment in
            if case .customEmoji = fragment.kind {
                return true
            }
            return false
        }
    }
}

private struct ChatInlineContentView: View {
    let fragments: [ChatContentFragment]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                FlowLayout(spacing: 0) {
                    ForEach(displayItems(for: line)) { item in
                        content(for: item)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func content(for item: ChatInlineDisplayItem) -> some View {
        switch item.kind {
        case .text(let text):
            Text(text)
                .font(Theme.body(15))
                .foregroundStyle(Theme.text)
        case .customEmoji(let emoji):
            ChatInlineEmojiImage(emoji: emoji)
        }
    }

    private var lines: [[ChatContentFragment]] {
        var rows: [[ChatContentFragment]] = [[]]
        for fragment in fragments {
            if case .lineBreak = fragment.kind {
                rows.append([])
            } else {
                rows[rows.count - 1].append(fragment)
            }
        }
        return rows.filter { !$0.isEmpty }
    }

    private func displayItems(for line: [ChatContentFragment]) -> [ChatInlineDisplayItem] {
        var items: [ChatInlineDisplayItem] = []
        for fragment in line {
            switch fragment.kind {
            case .text(let text):
                for (index, token) in textTokens(text).enumerated() {
                    items.append(ChatInlineDisplayItem(id: "\(fragment.id)-\(index)", kind: .text(token)))
                }
            case .customEmoji(let emoji):
                items.append(ChatInlineDisplayItem(id: fragment.id, kind: .customEmoji(emoji)))
            case .lineBreak:
                break
            }
        }
        return items
    }

    private func textTokens(_ text: String) -> [String] {
        var tokens: [String] = []
        var buffer = ""

        func flushBuffer() {
            guard !buffer.isEmpty else { return }
            tokens.append(buffer)
            buffer = ""
        }

        for character in text {
            if character.isWhitespace {
                flushBuffer()
                tokens.append(String(character))
            } else if isASCIIWordCharacter(character) {
                buffer.append(character)
            } else {
                flushBuffer()
                tokens.append(String(character))
            }
        }
        flushBuffer()
        return tokens
    }

    private func isASCIIWordCharacter(_ character: Character) -> Bool {
        String(character).range(of: #"^[A-Za-z0-9_@#:/.\-]+$"#, options: .regularExpression) != nil
    }
}

private struct ChatInlineDisplayItem: Identifiable {
    enum Kind {
        case text(String)
        case customEmoji(ChatCustomEmoji)
    }

    let id: String
    let kind: Kind
}

private struct ChatInlineEmojiImage: View {
    let emoji: ChatCustomEmoji

    var body: some View {
        CachedRemoteImage(url: emoji.url) { image in
            image
                .resizable()
                .scaledToFit()
        } placeholder: {
            Text(emoji.shortcode)
                .font(Theme.body(13, weight: .medium))
                .foregroundStyle(Theme.text.opacity(0.72))
        }
        .frame(width: imageWidth, height: imageHeight)
        .accessibilityLabel(emoji.shortcode)
    }

    private var imageHeight: CGFloat { 21 }

    private var imageWidth: CGFloat {
        guard let width = emoji.width, let height = emoji.height, width > 0, height > 0 else {
            return imageHeight
        }
        return min(56, max(18, imageHeight * CGFloat(width) / CGFloat(height)))
    }
}

private struct ChatMessageImage: View {
    let media: PostMedia
    let onOpen: () -> Void

    var body: some View {
        Button {
            onOpen()
        } label: {
            CachedRemoteImage(url: media.url) { image in
                image
                    .resizable()
                    .scaledToFill()
            } placeholder: {
                ZStack {
                    Theme.neutral300
                    Image(systemName: "photo")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(Theme.muted(0.38))
                }
            }
            .frame(width: imageWidth, height: imageHeight)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Theme.divider, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var imageWidth: CGFloat {
        224
    }

    private var imageHeight: CGFloat {
        let ratio = aspectRatio
        return min(280, max(118, imageWidth / ratio))
    }

    private var aspectRatio: CGFloat {
        guard let width = media.width, let height = media.height, width > 0, height > 0 else {
            return 4 / 3
        }
        return CGFloat(width) / CGFloat(height)
    }
}

private struct ChatImagePreview: View {
    let media: PostMedia
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var imageData: Data?
    @State private var shareURL: URL?
    @State private var isLoading = false
    @State private var isShowingFileExporter = false
    @State private var statusText: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            Group {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if isLoading {
                    ProgressView()
                        .tint(.white)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "photo")
                            .font(.system(size: 42, weight: .medium))
                        Text("图片加载失败")
                            .font(Theme.body(15, weight: .medium))
                    }
                    .foregroundStyle(.white.opacity(0.72))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 72)

            VStack {
                HStack(spacing: 12) {
                    Button {
                        dismiss()
                    } label: {
                        previewButtonIcon("xmark")
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    Button {
                        isShowingFileExporter = true
                    } label: {
                        previewButtonIcon("square.and.arrow.down")
                    }
                    .buttonStyle(.plain)
                    .disabled(imageData == nil)
                    .opacity(imageData == nil ? 0.45 : 1)

                    if let shareURL {
                        ShareLink(item: shareURL) {
                            previewButtonIcon("square.and.arrow.up")
                        }
                    } else {
                        previewButtonIcon("square.and.arrow.up")
                            .opacity(0.45)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 14)

                Spacer()

                if let statusText {
                    Text(statusText)
                        .font(Theme.body(13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .frame(height: 34)
                        .background(.black.opacity(0.52), in: Capsule())
                        .padding(.bottom, 24)
                }
            }
        }
        .task(id: media.url) {
            await loadImage()
        }
        .fileExporter(
            isPresented: $isShowingFileExporter,
            document: ChatImageDownloadDocument(data: imageData ?? Data()),
            contentType: downloadContentType,
            defaultFilename: downloadFilename
        ) { result in
            switch result {
            case .success:
                statusText = "已保存文件"
            case .failure:
                statusText = "保存失败"
            }
        }
    }

    private func previewButtonIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 42, height: 42)
            .background(.black.opacity(0.46), in: Circle())
            .overlay(
                Circle()
                    .strokeBorder(.white.opacity(0.16), lineWidth: 1)
            )
    }

    private func loadImage() async {
        isLoading = true
        statusText = nil

        do {
            let (data, response) = try await URLSession.shared.data(from: media.url)
            if let httpResponse = response as? HTTPURLResponse,
               !(200..<300).contains(httpResponse.statusCode) {
                throw ChatImagePreviewError.loadFailed
            }
            guard let loadedImage = UIImage(data: data) else {
                throw ChatImagePreviewError.loadFailed
            }

            image = loadedImage
            imageData = data
            shareURL = try writeTemporaryImageFile(data: data)
        } catch {
            statusText = "图片加载失败"
        }

        isLoading = false
    }

    private func writeTemporaryImageFile(data: Data) throws -> URL {
        let fileExtension = downloadFileExtension
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("nodeloc-chat-\(UUID().uuidString).\(fileExtension)")
        try data.write(to: fileURL, options: .atomic)
        return fileURL
    }

    private var downloadContentType: UTType {
        UTType(filenameExtension: downloadFileExtension) ?? .image
    }

    private var downloadFilename: String {
        let lastPathComponent = media.url.lastPathComponent
        guard !lastPathComponent.isEmpty else {
            return "nodeloc-chat-image.\(downloadFileExtension)"
        }
        return lastPathComponent
    }

    private var downloadFileExtension: String {
        media.url.pathExtension.isEmpty ? "jpg" : media.url.pathExtension
    }
}

private enum ChatImagePreviewError: Error {
    case loadFailed
}

private struct ChatImageDownloadDocument: FileDocument {
    nonisolated static var readableContentTypes: [UTType] {
        [.image]
    }

    let data: Data

    init(data: Data = Data()) {
        self.data = data
    }

    nonisolated init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    nonisolated func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
