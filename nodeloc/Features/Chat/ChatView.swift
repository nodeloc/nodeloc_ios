//
//  ChatView.swift
//  nodeloc
//

import AVKit
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

private enum MessagePane: CaseIterable {
    // Order is the tab order, and chat leads: it's the pane people open the
    // inbox for.
    case chat
    case privateMessages
    case notifications

    var title: String {
        switch self {
        case .notifications: return AppString("通知")
        case .privateMessages: return AppString("私信")
        case .chat: return AppString("聊天")
        }
    }
}

private enum ChatInboxFilter: CaseIterable {
    case messages
    case threads
    case search

    var title: String {
        switch self {
        case .messages: return AppString("消息")
        case .threads: return AppString("讨论串")
        case .search: return AppString("搜索")
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
    @Environment(\.sidebarIsPinned) private var sidebarIsPinned
    @State private var store = MessageCenterStore.shared
    @State private var selection: MessagePane = .chat
    @State private var chatFilter: ChatInboxFilter = .messages
    @State private var isShowingNewChat = false
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
                .toolbar(sidebarIsPinned ? .visible : .hidden, for: .navigationBar)
                .tabBarHeader(isPinned: sidebarIsPinned, needsNavigationStack: false) {
                    inboxTitle
                } trailing: {
                    inboxHeaderTools
                }
        }
    }

    private var inboxBody: some View {
        VStack(spacing: 0) {
            if !sidebarIsPinned {
                messageHeader
            }
            messageTabs

            if store.needsLogin {
                guestPrompt
            } else {
                messageContent
            }
        }
        .background(Theme.bg.ignoresSafeArea())
        .task {
            await store.load()
            // Both requests are checked here as well as in `onChange`: when the
            // tab is switched *to*, this view is created after the request was
            // made, so `onChange` never fires for it.
            var handled = await applyInboxRequestIfNeeded()
            if await openRequestedChatIfNeeded() { handled = true }
            // Only when something routed the reader straight to 通知 — the inbox
            // now opens on 聊天, and marking notifications read without them
            // having been looked at would clear the bell for nothing. Switching
            // to the pane is what clears it (see `onChange`).
            if !handled, selection == .notifications { await store.markNotificationsRead() }
        }
        .onChange(of: selection) { _, pane in
            if pane == .notifications { Task { await store.markNotificationsRead() } }
        }
        .onChange(of: app.inboxRequestedGroup) { _, _ in
            Task { await applyInboxRequestIfNeeded() }
        }
        .onChange(of: app.chatRequestedUsername) { _, _ in
            Task { await openRequestedChatIfNeeded() }
        }
        .sheet(isPresented: $isShowingNewChat) {
            ChatUserPickerSheet(
                title: AppString("发起聊天"),
                confirmLabel: AppString("开始")
            ) { usernames in
                guard let chat = await store.createDirectMessage(with: usernames) else {
                    return false
                }
                selection = .chat
                path = [.channel(chat)]
                return true
            }
        }
    }

    /// Honors a group-message notification: switch to 私信 and select the group.
    /// Returns whether a request was pending.
    @discardableResult
    private func applyInboxRequestIfNeeded() async -> Bool {
        guard let group = app.inboxRequestedGroup else { return false }
        selection = .privateMessages
        app.inboxRequestedGroup = nil
        await store.selectPMGroup(group)
        return true
    }

    /// Honors 聊天 from a profile: resolve the direct-message channel, then push
    /// the conversation. Consumes the request first so a failure doesn't leave
    /// it pending and retry on every redraw.
    @discardableResult
    private func openRequestedChatIfNeeded() async -> Bool {
        guard let username = app.chatRequestedUsername else { return false }
        app.chatRequestedUsername = nil
        selection = .chat
        guard let chat = await store.directMessageChannel(with: username) else { return true }
        path = [.channel(chat)]
        return true
    }

    private var inboxTitle: some View {
        Text("收件箱")
            .font(Theme.heading(24, weight: .semibold))
            .foregroundStyle(Theme.text)
    }

    /// Guests get 登录 where the tools would be — every inbox action needs an
    /// account anyway.
    @ViewBuilder
    private var inboxHeaderTools: some View {
        if app.isGuest {
            GuestLoginButton()
        } else {
            HStack(spacing: 8) {
                newChatButton
                markAllReadButton
            }
        }
    }

    private var messageHeader: some View {
        ZStack {
            inboxTitle

            HStack {
                SidebarMenuButton()

                Spacer()

                inboxHeaderTools
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 18)
    }

    /// Starts a chat. One person or several — `target_usernames[]` takes a list,
    /// and Discourse makes it a group direct message when there is more than one.
    /// Until now the app could only open a one-to-one chat from a profile.
    private var newChatButton: some View {
        Button {
            isShowingNewChat = true
        } label: {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Theme.text)
                .frame(width: FloatingHeader.controlHeight, height: FloatingHeader.controlHeight)
        }
        .glassButton(tint: FloatingHeader.glassTint, shape: .circle)
        .shadow(color: FloatingHeader.shadow, radius: 9, y: 6)
        .accessibilityLabel("发起聊天")
    }

    /// 全部已读. One round glass button, built like every other header control
    /// (the hamburger beside it included) instead of a capsule of three — the
    /// other two had no actions behind them.
    private var markAllReadButton: some View {
        Button {
            Task {
                await store.markAllRead()
                ToastCenter.shared.show(AppString("已全部标为已读"))
            }
        } label: {
            // Lucide's double tick, the mark messaging apps use for "read".
            // Template-rendered so it takes `Theme.text` like the SF Symbols
            // in the other headers.
            Image("LucideCheckCheck")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 18, height: 18)
                .foregroundStyle(Theme.text)
                .frame(width: FloatingHeader.controlHeight, height: FloatingHeader.controlHeight)
        }
        .glassButton(tint: FloatingHeader.glassTint, shape: .circle)
        .shadow(color: FloatingHeader.shadow, radius: 9, y: 6)
        // Deliberately never disabled: a disabled `.glass` button gets no
        // press response, which is what made this one feel dead next to the
        // hamburger. With nothing unread the tap is simply a no-op.
        .accessibilityLabel("全部已读")
    }

    private func count(for pane: MessagePane) -> Int {
        switch pane {
        case .notifications: return store.unreadNotifications
        case .privateMessages: return store.unreadPrivateMessages
        case .chat: return store.unreadChat
        }
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
                        HStack(spacing: 6) {
                            Text(pane.title)
                                .font(Theme.body(18, weight: selection == pane ? .semibold : .medium))
                                .foregroundStyle(selection == pane ? Theme.text : Theme.muted(0.5))
                            if count(for: pane) > 0 {
                                Text("\(count(for: pane))")
                                    .font(Theme.body(11, weight: .bold))
                                    .foregroundStyle(.white)
                                    .frame(minWidth: 18, minHeight: 18)
                                    .padding(.horizontal, 3)
                                    .background(Theme.accent, in: Capsule())
                            }
                        }
                        Rectangle()
                            .fill(selection == pane ? Theme.accent : Color.clear)
                            .frame(width: 56, height: 3)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
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
                    notificationList(store.notifications, emptyTitle: AppString("暂无通知"), emptyIcon: "bell")
                case .privateMessages:
                    privateMessageList
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
                    .buttonStyle(.pressable)
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

    @ViewBuilder
    private var privateMessageList: some View {
        if !store.messageGroups.isEmpty {
            pmFilterBar
                .padding(.bottom, 8)
        }

        if store.isLoadingGroupPMs {
            ProgressView()
                .tint(Theme.accent)
                .padding(.top, 32)
        }

        ForEach(store.visibleConversations) { conversation in
            Button {
                store.markConversationRead(id: conversation.id)
                app.openTopic(id: conversation.id)
            } label: {
                PMConversationRow(conversation: conversation)
            }
            .buttonStyle(.pressable)
        }

        if !store.isLoading && !store.isLoadingGroupPMs && store.visibleConversations.isEmpty {
            emptyState(title: AppString("暂无私信"), icon: "envelope")
        }
    }

    /// 个人 + one chip per group with a message inbox.
    private var pmFilterBar: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    pmFilterChip(title: AppString("个人"), isSelected: store.selectedPMGroup == nil) {
                        Task { await store.selectPMGroup(nil) }
                    }
                    .id(personalChipID)
                    ForEach(store.messageGroups, id: \.self) { group in
                        pmFilterChip(title: group, isSelected: store.selectedPMGroup == group) {
                            Task { await store.selectPMGroup(group) }
                        }
                        .id(group)
                    }
                }
                .padding(.horizontal, 20)
            }
            .scrollIndicators(.hidden)
            // Center the active chip — chiefly when a notification jumps to a
            // group that would otherwise sit off-screen. Driven by `.task` (not
            // `.onChange`) so it also fires the first time the bar appears, and
            // after a short delay so a chip just added for the target group has
            // been laid out before we scroll to it.
            .task(id: store.selectedPMGroup) {
                try? await Task.sleep(for: .milliseconds(150))
                withAnimation(.easeInOut(duration: 0.3)) {
                    proxy.scrollTo(store.selectedPMGroup ?? personalChipID, anchor: .center)
                }
            }
        }
    }

    private var personalChipID: String { "__personal__" }

    private func pmFilterChip(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.quicker) { action() }
        } label: {
            Text(title)
                .font(Theme.body(15, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? Theme.text : Theme.muted(0.58))
                .lineLimit(1)
                .padding(.horizontal, 16)
                .frame(height: 38)
                .background(isSelected ? Theme.neutral300 : Color.clear, in: Capsule())
        }
        .buttonStyle(.pressable)
    }

    private var chatList: some View {
        Group {
            ForEach(store.chats) { chat in
                NavigationLink(value: ChatRoute.channel(chat)) {
                    MessageChatRow(chat: chat)
                }
                .buttonStyle(.pressable)
            }

            if !store.isLoading && store.chats.isEmpty {
                emptyState(title: AppString("暂无聊天"), icon: "bubble.left.and.bubble.right")
            }
        }
    }

    private var threadList: some View {
        Group {
            ForEach(store.threads) { thread in
                NavigationLink(value: ChatRoute.thread(thread)) {
                    MessageThreadRow(thread: thread)
                }
                .buttonStyle(.pressable)
            }

            if !store.isLoading && store.threads.isEmpty {
                emptyState(title: AppString("暂无讨论串"), icon: "text.bubble")
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
                emptyState(title: AppString("输入关键词搜索聊天"), icon: "magnifyingglass")
            } else if !store.isSearchingChat && store.chatSearchResults.isEmpty {
                emptyState(title: AppString("没有找到相关聊天"), icon: "magnifyingglass")
            }

            ForEach(store.chatSearchResults) { result in
                NavigationLink(value: ChatRoute.searchResult(result)) {
                    MessageSearchResultRow(result: result)
                }
                .buttonStyle(.pressable)
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
                .buttonStyle(.pressable)
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
        result.message.text.isEmpty ? AppString("媒体消息") : result.message.text
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
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button {
            if let url = notification.url { openURL(url) }
        } label: {
            rowContent
        }
        .buttonStyle(.pressable)
        .disabled(notification.url == nil)
    }

    private var rowContent: some View {
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
        case .comment: return "arrowshape.turn.up.left.fill"
        case .message: return "envelope.fill"
        case .success: return "checkmark"
        case .star: return "star.fill"
        case .system: return "bell.fill"
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
        case .system: return Theme.accent700
        }
    }

    private var iconBackground: Color {
        switch notification.kind {
        case .like: return Theme.surface.blended(with: Theme.love, fraction: 0.15)
        case .comment: return Theme.surface.blended(with: Theme.accent, fraction: 0.15)
        case .message: return Theme.surface.blended(with: Theme.text, fraction: 0.08)
        case .success: return Theme.surface.blended(with: Theme.success, fraction: 0.15)
        case .star: return Theme.surface.blended(with: Theme.accent2_500, fraction: 0.18)
        case .system: return Theme.surface.blended(with: Theme.accent, fraction: 0.15)
        }
    }
}

private struct PMConversationRow: View {
    let conversation: PMConversation

    var body: some View {
        HStack(spacing: 13) {
            RemoteAvatar(
                url: conversation.avatarURL,
                letter: conversation.letter,
                variant: conversation.variant,
                size: 42
            )

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(conversation.counterpart)
                        .font(Theme.body(15, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(conversation.time)
                        .font(Theme.body(12))
                        .foregroundStyle(Theme.muted(0.5))
                        .lineLimit(1)
                }

                Text(conversation.title)
                    .font(Theme.body(14))
                    .foregroundStyle(Theme.text.opacity(0.68))
                    .lineLimit(2)
            }

            if conversation.unread {
                Circle()
                    .fill(Theme.accent)
                    .frame(width: 8, height: 8)
            }
        }
        .padding(.vertical, 13)
        .padding(.horizontal, 20)
        .contentShape(Rectangle())
        .background(conversation.unread ? Theme.accent.opacity(0.05) : Color.clear)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.divider).frame(height: 1)
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

/// One picked image or video waiting to be sent. `uploadID` nil means it is
/// still uploading — that is what holds the send button.
/// A video in a bubble: a poster-less dark tile that plays full screen on tap.
///
/// `VideoPlayer` in a sheet rather than the post reader's full-screen pager —
/// that machinery is built around a `Post` and its siblings, and a chat clip has
/// neither.
private struct ChatMessageVideo: View {
    let url: URL
    @State private var isPlaying = false
    @State private var posterURL: URL?

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
    }

    var body: some View {
        Button {
            isPlaying = true
        } label: {
            ZStack {
                Theme.neutral300

                // No placeholder: the fill behind it already is one, and a
                // second would flash over it.
                CachedRemoteImage(url: posterURL) { image in
                    image
                        .resizable()
                        .scaledToFill()
                } placeholder: {
                    Color.clear
                }

                // A constant scrim rather than colours that follow the poster:
                // the URL arrives before the image is decoded, so keying off it
                // would put a white glyph on bare grey for a frame. One scrim
                // reads correctly in every state.
                Color.black.opacity(0.18)

                Image(systemName: "play.circle.fill")
                    .font(.system(size: 38))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.35), radius: 6)
            }
            // The frame has to bound the stack *before* the clip. `scaledToFill`
            // answers a layout size larger than the space it was offered — a
            // portrait poster in a 200×132 tile reports 200×400 — so a
            // `clipShape` hung on the image clips to that overflowing frame and
            // clips nothing, which is how the poster spilled out of the bubble.
            .frame(width: 200, height: 132)
            .clipShape(shape)
            .overlay(alignment: .bottomLeading) {
                Label("视频", systemImage: "film")
                    .font(Theme.body(11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.95))
                    .shadow(color: .black.opacity(0.4), radius: 4)
                    .padding(8)
            }
            .overlay {
                shape.strokeBorder(Theme.divider, lineWidth: 1)
            }
            .contentShape(shape)
        }
        .buttonStyle(.pressable)
        // Same `by_sha1` answer the player will use, so opening the video
        // costs no second request.
        .task {
            guard posterURL == nil else { return }
            posterURL = await AnyVideoResolver.shared.posterURL(forUpload: url)
        }
        .fullScreenCover(isPresented: $isPlaying) {
            ChatVideoPlayerView(url: url) { isPlaying = false }
        }
    }
}

private struct ChatVideoPlayerView: View {
    let url: URL
    let onClose: () -> Void

    @State private var player: AVPlayer?
    @State private var dragOffset: CGFloat = 0
    /// Which gesture this is, decided once from its first movement. Nil means
    /// undecided; false hands the drag to AVKit and keeps it there.
    @State private var isDismissDrag: Bool?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let player {
                ChatVideoSurface(player: player)
                    .ignoresSafeArea()
                    // Follows the finger and shrinks a little, the same pull
                    // the image viewer uses.
                    .offset(y: dragOffset)
                    .scaleEffect(max(1 - dragOffset / 1400, 0.85))
            } else {
                // Covers the HLS lookup only. Once there is a player,
                // AVPlayerViewController draws its own spinner over the video
                // while it buffers — which is the wait that made this look
                // broken, because nothing was on screen for it.
                VideoLoadingIndicator(size: 26)
            }
        }
        // Simultaneous, not high-priority: AVKit still needs the tap that
        // raises its controls and the horizontal drag that scrubs.
        .simultaneousGesture(dismissDragGesture)
        // The upload URL off `uploads` is the original file, and the site stops
        // serving that once discourse-anyvideo has transcoded it — every
        // original now answers 404 while its HLS rendition plays. Handing the
        // raw URL to AVPlayer is why chat clips never started. Every post
        // surface already resolves first; chat was the one that didn't.
        .task {
            guard player == nil,
                  let playable = await AnyVideoResolver.shared.playableURL(forUpload: url)
            else { return }
            let player = AVPlayer(url: playable)
            self.player = player
            // Opening the sheet *is* the play gesture — the bubble's tile is a
            // play button.
            player.play()
        }
        .onDisappear { player?.pause() }
    }

    /// Pull down to close. A downward drag is unambiguous here — unlike the
    /// post reader's pager, this sheet has no vertical paging to compete with —
    /// so the only thing to keep clear of is scrubbing, which is horizontal.
    private var dismissDragGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                if isDismissDrag == nil {
                    let translation = value.translation
                    isDismissDrag = translation.height > 0
                        && abs(translation.height) > abs(translation.width) * 1.2
                }
                guard isDismissDrag == true else { return }
                dragOffset = max(0, value.translation.height)
            }
            .onEnded { value in
                let wasDismissDrag = isDismissDrag == true
                isDismissDrag = nil
                guard wasDismissDrag else { return }
                if dragOffset > 130 || value.velocity.height > 900 {
                    onClose()
                } else {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                        dragOffset = 0
                    }
                }
            }
    }
}

/// The system playback UI, rather than SwiftUI's `VideoPlayer`.
///
/// `VideoPlayer` does supply controls, but they auto-hide as soon as playback
/// starts — and this sheet starts playing immediately — so a clip that was
/// working looked like a bare video with no way to pause or scrub it.
/// `AVPlayerViewController` is the documented standard interface: the transport
/// bar comes up on tap and it renders its own buffering indicator.
private struct ChatVideoSurface: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = true
        controller.videoGravity = .resizeAspect
        // Chat has nowhere to restore playback to, so Picture in Picture would
        // strand the clip outside the sheet that owns it.
        controller.allowsPictureInPicturePlayback = false
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player { controller.player = player }
    }
}

private struct ChatComposerAttachment: Identifiable {
    let id = UUID()
    let isVideo: Bool
    let thumbnail: UIImage?
    var uploadID: Int?
}

private struct ChatConversationView: View {
    let chat: Chat
    var initialThread: ChatThreadListItem?
    var targetMessageID: Int?
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var store = ChatConversationStore()
    @State private var draft = ""
    @State private var appliedScrollSignature: String?
    @State private var selectedMedia: PostMedia?
    /// Picked-but-not-yet-sent media, mirroring how the post composer holds
    /// attachments in the view: this screen is short-lived, and a draft that
    /// outlived it would be a surprise rather than a feature.
    @State private var attachments: [ChatComposerAttachment] = []
    @State private var mediaSelections: [PhotosPickerItem] = []
    @State private var showThreadList = false
    @State private var isConfirmingLeave = false
    @State private var isShowingEmojiPicker = false
    @State private var isShowingMembers = false
    /// The message the draft will quote, if any.
    @State private var replyTarget: ChatConversationMessage?
    /// The message being edited, and its working text.
    @State private var editTarget: ChatConversationMessage?
    /// The message a reaction is being picked for; nil means the composer's own
    /// emoji button opened the picker.
    @State private var reactionTarget: ChatConversationMessage?
    @State private var flagTargetMessage: ChatConversationMessage?
    @State private var deleteTargetMessage: ChatConversationMessage?
    /// A message the server refused, awaiting the reader's decision.
    @State private var failedMessage: ChatConversationMessage?
    /// Watched so the outbox sends itself the moment a network path returns.
    @State private var reachability = NetworkReachability.shared
    @Environment(\.scenePhase) private var scenePhase
    /// Set by the pinned bar; consumed by the transcript's scroll.
    @State private var pinJumpTarget: Int?
    @State private var isShowingAddMembers = false
    /// Raising the keyboard has to bring the transcript with it. Anchoring the
    /// scroll view's bottom for `.sizeChanges` was not enough on device — the
    /// newest messages stayed behind the keyboard — so the scroll is explicit.
    @FocusState private var isInputFocused: Bool
    /// Held so the send path and the keyboard can scroll without being inside
    /// the `ScrollViewReader`'s closure.
    @State private var scrollProxy: ScrollViewProxy?

    /// A clear strip after the last bubble. Scrolling *its* bottom to the
    /// viewport's bottom is what leaves a gap above the input bar: scrolling to
    /// the message itself puts the bubble flush against the keyboard, and the
    /// container's own bottom padding ends up below the visible area where it
    /// does nothing.
    private static let bottomAnchor = "chat-bottom-anchor"
    private static let bottomGap: CGFloat = 22

    var body: some View {
        VStack(spacing: 0) {
            conversationHeader
            Divider()
                .overlay(Theme.divider)
            if let pin = store.pins.first {
                pinnedBar(pin)
            }
            conversationContent
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            messageInputBar
        }
        .background(Theme.bg.ignoresSafeArea())
        .fullScreenCover(item: $selectedMedia) { media in
            ChatImagePreview(media: media)
        }
        .sheet(isPresented: $showThreadList) {
            channelThreadSheet
        }
        .sheet(isPresented: $isShowingMembers) {
            memberListSheet
        }
        .sheet(isPresented: $isShowingAddMembers) {
            ChatUserPickerSheet(
                title: AppString("添加成员"),
                confirmLabel: AppString("添加")
            ) { usernames in
                await store.addMembers(usernames, channelID: chat.id)
            }
        }
        .sheet(isPresented: $isShowingEmojiPicker) {
            EmojiPickerSheet { emoji in
                if let target = reactionTarget {
                    // Reacting is one emoji, so the sheet closes behind it.
                    isShowingEmojiPicker = false
                    reactionTarget = nil
                    Task {
                        await store.toggleReaction(
                            emoji: emoji.name,
                            messageID: target.id,
                            channelID: chat.id
                        )
                    }
                } else {
                    // Composing: stays open, because sending several in a row is
                    // the common case.
                    insert(emoji)
                }
            }
        }
        .onChange(of: isShowingEmojiPicker) { _, showing in
            if !showing { reactionTarget = nil }
        }
        .sheet(item: $editTarget) { target in
            ChatMessageEditSheet(original: target.text) { text in
                await store.editMessage(text, messageID: target.id, channelID: chat.id)
            }
        }
        .sheet(item: $flagTargetMessage) { target in
            FlagSheet(
                target: FlagTarget(
                    kind: .chatMessage(channelID: chat.id),
                    id: target.id,
                    authorUsername: target.username
                ),
                allowedNameKeys: target.availableFlags
            )
        }
        // Retry or throw away. Deliberately not automatic: a message that has
        // failed three times is failing for a reason, and silently retrying
        // forever is how a chat app ends up sending something an hour late.
        .confirmationDialog(
            AppString("这条消息没有发送成功"),
            isPresented: Binding(get: { failedMessage != nil }, set: { if !$0 { failedMessage = nil } }),
            titleVisibility: .visible
        ) {
            Button(AppString("重新发送")) {
                guard let outboxID = failedMessage?.outboxID,
                      let item = store.pending.first(where: { $0.localID == outboxID })
                else { return }
                failedMessage = nil
                Task { await store.retry(item) }
            }
            Button(AppString("删除"), role: .destructive) {
                guard let outboxID = failedMessage?.outboxID,
                      let item = store.pending.first(where: { $0.localID == outboxID })
                else { return }
                failedMessage = nil
                Task { await store.discard(item) }
            }
            Button(AppString("取消"), role: .cancel) { failedMessage = nil }
        } message: {
            if let text = failedMessage?.text, !text.isEmpty {
                Text(text)
            }
        }
        .confirmationDialog(
            AppString("删除这条消息？"),
            isPresented: Binding(
                get: { deleteTargetMessage != nil },
                set: { if !$0 { deleteTargetMessage = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                guard let target = deleteTargetMessage else { return }
                deleteTargetMessage = nil
                Task { await store.deleteMessage(messageID: target.id, channelID: chat.id) }
            }
            Button("取消", role: .cancel) { deleteTargetMessage = nil }
        }
        .confirmationDialog(
            store.isDirectMessage ? AppString("退出这个会话？") : AppString("退出这个频道？"),
            isPresented: $isConfirmingLeave,
            titleVisibility: .visible
        ) {
            Button("退出", role: .destructive) {
                Task {
                    if await store.leaveChannel(chat.id) { dismiss() }
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("退出后不再收到这里的消息，对方仍能看到之前的对话。")
        }
        .task(id: taskID) {
            await store.load(chat: chat, initialThread: initialThread, targetMessageID: targetMessageID)
            // Pins are their own endpoint and their own site setting.
            await store.loadPins(channelID: chat.id)
            // Reading the channel clears its unread on the server and drops it
            // from the inbox/tab badge.
            if let latest = store.messages.map(\.id).max() {
                await MessageCenterStore.shared.markChatChannelRead(channelID: chat.id, messageID: latest)
            }
        }
        // Coming back online is the event a queued message is waiting for.
        // Only the transition, and only towards online: `NetworkReachability`
        // filters repeats, so this fires once per reconnection.
        .onChange(of: reachability.isOnline) { _, isOnline in
            guard isOnline else { return }
            Task { await store.drainOutbox(channelID: chat.id, includingFailed: true) }
        }
        // A long poll cannot be serviced by a suspended app, and iOS tears the
        // connection down regardless — so it is stopped on the way out and
        // reconnected on the way back, which is also the moment to ask what
        // was missed. Without this the transcript came back silently stale.
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                Task { await store.resumeLiveUpdates(chat: chat) }
            case .background, .inactive:
                store.stopLiveUpdates()
            @unknown default:
                break
            }
        }
        .onDisappear {
            store.stopLiveUpdates()
            // Server-side draft, so an unsent line is still there on the web or
            // on another device. Fire-and-forget by design.
            let pending = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            if !pending.isEmpty {
                let channelID = chat.id
                let threadID = store.selectedThread?.id
                Task { await store.saveDraft(pending, channelID: channelID, threadID: threadID) }
            }
        }
    }

    /// The channel's newest pin, under the header. One line, tappable to jump to
    /// the message — the same place the web puts its pinned bar.
    private func pinnedBar(_ pin: ChatPinnedMessage) -> some View {
        Button {
            pinJumpTarget = pin.messageID
            Task { await store.markPinsRead(channelID: chat.id) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "pin.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.accent700)

                VStack(alignment: .leading, spacing: 1) {
                    Text(pin.authorName.isEmpty ? AppString("置顶消息") : pin.authorName)
                        .font(Theme.body(11, weight: .semibold))
                        .foregroundStyle(Theme.accent700)
                        .lineLimit(1)
                    Text(pin.excerpt)
                        .font(Theme.body(12))
                        .foregroundStyle(Theme.muted(0.6))
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if store.pins.count > 1 {
                    Text("\(store.pins.count)")
                        .font(Theme.body(11, weight: .semibold))
                        .foregroundStyle(Theme.muted(0.5))
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.accent.opacity(0.06))
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
    }

    /// Hands the chat transcript to the composer, so a conversation can become a
    /// post. The markdown comes from the server (`Chat::TranscriptService`), not
    /// from anything reassembled here.
    private func quoteToPost(_ message: ChatConversationMessage) {
        Task {
            guard let markdown = await store.transcript(
                messageIDs: [message.id],
                channelID: chat.id
            ) else { return }
            app.composePrefillBody = markdown
            dismiss()
            withAnimation(.overlayPush) { app.overlay = .compose }
        }
    }

    private var memberListLabel: String {
        let title = store.channelKind.memberListTitle
        return store.memberTotal > 0 ? "\(title) (\(store.memberTotal))" : title
    }

    /// Everyone in a group chat or channel, each row opening their profile.
    private var memberListSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    if store.isLoadingMembers && store.members.isEmpty {
                        ProgressView()
                            .tint(Theme.accent)
                            .padding(.top, 40)
                    }

                    ForEach(store.members) { member in
                        Button {
                            isShowingMembers = false
                            app.openProfile(member)
                        } label: {
                            memberRow(member)
                        }
                        .buttonStyle(.pressable)
                    }

                    // The list is capped; say so rather than implying the group
                    // is smaller than it is.
                    if store.memberTotal > store.members.count {
                        Text("另有 \(store.memberTotal - store.members.count) 位成员")
                            .font(Theme.body(12))
                            .foregroundStyle(Theme.muted(0.5))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 20)
                            .padding(.top, 12)
                    }
                }
                .padding(.vertical, 8)
            }
            .scrollIndicators(.hidden)
            .background(Theme.bg)
            .navigationTitle(store.channelKind.memberListTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { isShowingMembers = false } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .bold))
                    }
                    .tint(Theme.text)
                }
            }
        }
        .standardSheet()
        .task { await store.loadMembers(channelID: chat.id) }
    }

    private func memberRow(_ member: UserProfileTarget) -> some View {
        HStack(spacing: 12) {
            RemoteAvatar(
                url: member.avatarURL,
                letter: member.initial,
                variant: abs(member.username.hashValue),
                size: 40
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(member.displayName ?? member.username)
                    .font(Theme.body(15, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Text("@\(member.username)")
                    .font(Theme.body(12))
                    .foregroundStyle(Theme.muted(0.55))
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.muted(0.4))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// The channel's discussion threads. They were already loaded on open and
    /// had no way in from here.
    private var channelThreadSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(store.channelThreads) { thread in
                        Button {
                            showThreadList = false
                            openThread(thread)
                        } label: {
                            threadRow(thread)
                        }
                        .buttonStyle(.pressable)
                    }
                }
                .padding(16)
            }
            .scrollIndicators(.hidden)
            .background(Theme.bg)
            .navigationTitle("讨论串")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { showThreadList = false }
                }
            }
        }
        .standardSheet()
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
            .glassButton(tint: Theme.bg.opacity(0.34), shape: .circle)
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

            conversationTools
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

                    // Paging trigger, above the oldest row. Its own view
                    // rather than an `onAppear` on the first bubble: the first
                    // bubble changes identity every time a page lands, which
                    // re-fires `onAppear` and would page again immediately.
                    if store.selectedThread == nil, store.hasMoreHistory, !activeMessages.isEmpty {
                        Color.clear
                            .frame(height: 1)
                            .onAppear {
                                Task { await store.loadOlderMessages(channelID: chat.id) }
                            }
                        if store.isLoadingHistory {
                            ProgressView()
                                .tint(Theme.accent)
                                .padding(.vertical, 8)
                        }
                    }

                    ForEach(activeMessages) { message in
                        ChatMessageBubble(
                            message: message,
                            onOpenThread: { thread in
                                openThread(thread)
                            },
                            onOpenImage: { media in
                                selectedMedia = media
                            },
                            onReply: {
                                replyTarget = message
                                isInputFocused = true
                            },
                            onOpenQuoted: { quoted in
                                // Only if it's still loaded; the original can be
                                // far enough back to be off the page.
                                guard activeMessages.contains(where: { $0.id == quoted.id }) else {
                                    ToastCenter.shared.show(AppString("原消息不在当前页"))
                                    return
                                }
                                withAnimation(.easeOut(duration: 0.22)) {
                                    proxy.scrollTo(quoted.id, anchor: .center)
                                }
                            },
                            onToggleReaction: { emoji in
                                Task {
                                    await store.toggleReaction(
                                        emoji: emoji,
                                        messageID: message.id,
                                        channelID: chat.id
                                    )
                                }
                            },
                            onAddReaction: {
                                reactionTarget = message
                                isShowingEmojiPicker = true
                            },
                            onEdit: { editTarget = message },
                            onDelete: { deleteTargetMessage = message },
                            onFlag: { flagTargetMessage = message },
                            onTogglePin: store.isPinningAvailable
                                ? {
                                    Task {
                                        await store.togglePin(
                                            messageID: message.id,
                                            channelID: chat.id
                                        )
                                    }
                                }
                                : nil,
                            isPinned: store.pins.contains { $0.messageID == message.id },
                            onQuoteToPost: { quoteToPost(message) },
                            onRetryFailed: { failedMessage = message }
                        )
                        .id(message.id)
                    }

                    if !store.isLoading && !store.isLoadingThread && activeMessages.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "bubble.left.and.bubble.right")
                                .font(.system(size: 30, weight: .medium))
                                .foregroundStyle(Theme.muted(0.34))
                            Text(store.selectedThread == nil ? AppString("暂无消息") : AppString("暂无线程回复"))
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

                    Color.clear
                        .frame(height: Self.bottomGap)
                        .id(Self.bottomAnchor)
                }
                .padding(.horizontal, 20)
                .padding(.top, 22)
            }
            .scrollIndicators(.hidden)
            // The keyboard shrinks the scroll view's container, and by default
            // the content keeps its offset — so the newest messages ended up
            // behind the keyboard. This anchors the *bottom* through container
            // and content size changes, which is what a conversation wants:
            // raising the keyboard pushes the transcript up with it, and an
            // arriving message stays in view.
            //
            // Only the `.sizeChanges` role. `.initialOffset` and `.alignment`
            // stay as they were, so opening still lands on the first unread via
            // `scrollToInitialTarget`, and a short conversation keeps its intro
            // at the top instead of being pinned to the bottom.
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
            // Chat convention: drag the transcript to put the keyboard away.
            //
            // `.immediately` rather than `.interactively`, plus an explicit
            // gesture: the transcript sits *at* its bottom while typing, so a
            // downward drag scrolls nothing and the scroll-driven dismissal
            // never engaged — only the strip where content could still move
            // responded. The gesture doesn't care about scroll position.
            .scrollDismissesKeyboard(.immediately)
            .simultaneousGesture(dismissKeyboardDragGesture, isEnabled: isInputFocused)
            .onAppear {
                scrollProxy = proxy
                scrollToInitialTarget(with: proxy)
            }
            .onChange(of: initialScrollSignature) { _, _ in
                scrollToInitialTarget(with: proxy)
            }
            // Tapping the field is a deliberate act, so following it to the
            // newest message is what the reader wants. Not on every incoming
            // message, which would yank someone reading history.
            .onChange(of: isInputFocused) { _, focused in
                guard focused else { return }
                scrollToBottom(with: proxy)
            }
            // The pinned bar names a message that may be far back; jump only if
            // it's on the loaded page, and say so when it isn't.
            .onChange(of: pinJumpTarget) { _, target in
                guard let target else { return }
                pinJumpTarget = nil
                guard activeMessages.contains(where: { $0.id == target }) else {
                    ToastCenter.shared.show(AppString("置顶消息不在当前页"))
                    return
                }
                withAnimation(.easeOut(duration: 0.22)) {
                    proxy.scrollTo(target, anchor: .center)
                }
            }
            // The keyboard resizing (the predictive bar appearing, switching to
            // emoji, a different keyboard) moves the floor again. Async stream
            // rather than a Combine publisher.
            .task {
                let changes = NotificationCenter.default.notifications(
                    named: UIResponder.keyboardWillChangeFrameNotification
                )
                for await _ in changes {
                    guard isInputFocused else { continue }
                    scrollToBottom(with: proxy)
                }
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
                            .buttonStyle(.pressable)
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

    /// A thread in the list sheet: its title, then the same summary card the
    /// open thread shows, so the two read as the same object.
    private func threadRow(_ thread: ChatThreadListItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(thread.title)
                    .font(Theme.body(15, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if thread.unread {
                    Circle().fill(Theme.accent).frame(width: 8, height: 8)
                }
                Text(thread.time)
                    .font(Theme.body(11))
                    .foregroundStyle(Theme.muted(0.45))
            }
            selectedThreadSummary(thread)
        }
    }

    /// 免打扰 + 更多, both wired. The two buttons here used to be a bell and an
    /// ellipsis with empty actions inside a capsule marked `.plain` over
    /// `glassBackground`, so neither the capsule nor the icons could respond.
    /// This is the node page's construction: the glass carries `.interactive()`
    /// and the controls sit on it.
    private var conversationTools: some View {
        HStack(spacing: 6) {
            // The bell *is* the state: slashed while muted, so the current
            // setting is readable without opening anything.
            Button {
                Task { await store.toggleMute(channelID: chat.id) }
            } label: {
                toolIcon(store.isMuted ? "bell.slash.fill" : "bell")
                    .foregroundStyle(store.isMuted ? Theme.accent : Theme.text)
            }
            .buttonStyle(.pressable)
            .accessibilityLabel(store.isMuted ? AppString("恢复通知") : AppString("设为免打扰"))

            Menu {
                conversationMenuContent
            } label: {
                toolIcon("ellipsis")
            }
            .accessibilityLabel("更多")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .glassSurface(tint: FloatingHeader.glassTint, interactive: true)
        .shadow(color: FloatingHeader.shadow, radius: 9, y: 6)
    }

    private func toolIcon(_ systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(Theme.text)
            .frame(width: 28, height: FloatingHeader.controlHeight)
            .contentShape(Rectangle())
    }

    @ViewBuilder
    private var conversationMenuContent: some View {
        // Three kinds, three answers. A one-to-one chat has a person behind it;
        // a group chat and a category channel have a roster, and offering one
        // participant's profile for a group — which is what this did — is just
        // wrong for the other members.
        if store.channelKind.hasMemberList {
            Button {
                isShowingMembers = true
            } label: {
                Label(memberListLabel, systemImage: "person.2")
            }
            Button {
                isShowingAddMembers = true
            } label: {
                Label("添加成员", systemImage: "person.badge.plus")
            }
        } else if let counterpart = store.counterpart {
            // `app.routedProfile` rather than a `NavigationLink` in the menu:
            // this is the route every other screen opens a profile through, so
            // it is the one that is known to fire from inside a `Menu`.
            Button {
                app.openProfile(counterpart)
            } label: {
                Label("查看资料", systemImage: "person.crop.circle")
            }
        }

        Menu {
            Picker("通知级别", selection: Binding(
                get: { store.notificationLevel },
                set: { level in Task { await store.setNotificationLevel(level, channelID: chat.id) } }
            )) {
                ForEach(ChatNotificationLevel.allCases) { level in
                    Label(level.label, systemImage: level.icon).tag(level)
                }
            }
        } label: {
            Label("通知级别", systemImage: store.notificationLevel.icon)
        }

        if !store.channelThreads.isEmpty {
            Button {
                showThreadList = true
            } label: {
                Label("讨论串 (\(store.channelThreads.count))", systemImage: "bubble.left.and.bubble.right")
            }
        }

        Divider()

        Button(role: .destructive) {
            isConfirmingLeave = true
        } label: {
            Label(store.isDirectMessage ? AppString("退出会话") : AppString("退出频道"), systemImage: "rectangle.portrait.and.arrow.right")
        }
    }

    private var messageInputBar: some View {
        VStack(spacing: 0) {
            if let replyTarget {
                replyBanner(replyTarget)
            }

            if !attachments.isEmpty {
                attachmentStrip
            }

            inputRow
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(Theme.bg.opacity(0.92))
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.divider).frame(height: 1)
        }
        .onChange(of: mediaSelections) { _, items in
            ingest(items)
        }
    }

    /// Thumbnails of what's about to go, each removable — the messenger
    /// convention, and the reason picking doesn't send immediately.
    private var attachmentStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    attachmentTile(attachment)
                }
            }
            .padding(.bottom, 10)
        }
        .scrollIndicators(.hidden)
    }

    private func attachmentTile(_ attachment: ChatComposerAttachment) -> some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let thumbnail = attachment.thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                } else {
                    Theme.surface
                        .overlay {
                            Image(systemName: attachment.isVideo ? "film" : "photo")
                                .font(.system(size: 18))
                                .foregroundStyle(Theme.muted(0.45))
                        }
                }
            }
            .frame(width: 62, height: 62)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Theme.divider, lineWidth: 1)
            }
            // Still uploading: dim it and say so, rather than letting the send
            // button look ready when the id isn't back yet.
            .overlay {
                if attachment.uploadID == nil {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.black.opacity(0.35))
                        .overlay { ProgressView().tint(.white) }
                }
            }

            Button {
                attachments.removeAll { $0.id == attachment.id }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(4)
                    .background(Color.black.opacity(0.55), in: Circle())
            }
            .buttonStyle(.pressable)
            .padding(4)
        }
    }

    private var inputRow: some View {
        HStack(spacing: 10) {
            PhotosPicker(
                selection: $mediaSelections,
                maxSelectionCount: max(1, Self.maxAttachments - attachments.count),
                selectionBehavior: .ordered,
                matching: .any(of: [.images, .videos]),
                preferredItemEncoding: .compatible
            ) {
                Image(systemName: "plus")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .frame(width: 42, height: 42)
                    .background(Theme.neutral300, in: Circle())
            }
            .buttonStyle(.pressable)
            .disabled(attachments.count >= Self.maxAttachments)

            TextField("消息", text: $draft, axis: .vertical)
                .font(Theme.body(16))
                .foregroundStyle(Theme.text)
                .focused($isInputFocused)
                .lineLimit(1...4)
                .textInputAutocapitalization(.sentences)
                .padding(.leading, 14)
                .padding(.trailing, 4)
                .padding(.vertical, 11)
                .background(Theme.surface, in: Capsule())
                // Inside the field's capsule, where the system keyboard puts its
                // own emoji key — and out of the way of 发送.
                .overlay(alignment: .trailing) { emojiButton }

            Button {
                sendCurrentDraft()
            } label: {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(canSend ? Theme.accent700 : Theme.muted(0.35))
                    .frame(width: 42, height: 42)
            }
            .buttonStyle(.pressable)
            .disabled(!canSend)
        }
    }

    /// What the draft is replying to, with a way out of it.
    private func replyBanner(_ target: ChatConversationMessage) -> some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(Theme.accent.opacity(0.65))
                .frame(width: 2, height: 32)

            VStack(alignment: .leading, spacing: 1) {
                Text("回复 \(target.authorName)")
                    .font(Theme.body(11, weight: .semibold))
                    .foregroundStyle(Theme.accent700)
                    .lineLimit(1)
                Text(target.text)
                    .font(Theme.body(12))
                    .foregroundStyle(Theme.muted(0.6))
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button {
                withAnimation(.quick) { replyTarget = nil }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.muted(0.5))
                    .frame(width: 28, height: 28)
                    .contentShape(Circle())
            }
            .buttonStyle(.pressableIcon)
            .accessibilityLabel("取消引用")
        }
        .padding(.bottom, 8)
    }

    /// Opens the site's emoji, standard and custom.
    ///
    /// Inserted as `:shortcode:` rather than a character: the custom ones have
    /// no Unicode form, and Discourse cooks the shortcode into the same image on
    /// both ends — which is also how the bubble renderer already displays them
    /// in received messages.
    private var emojiButton: some View {
        Button {
            isShowingEmojiPicker = true
        } label: {
            Image(systemName: "face.smiling")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Theme.muted(0.5))
                .frame(width: 38, height: 38)
                .contentShape(Circle())
        }
        .buttonStyle(.pressableIcon)
        .accessibilityLabel("表情")
    }

    /// Appends the shortcode to the draft, spaced so two in a row don't run
    /// together into something Discourse won't recognise (`:a::b:`).
    private func insert(_ emoji: DiscourseEmoji) {
        if !draft.isEmpty, draft.last?.isWhitespace == false {
            draft += " "
        }
        draft += emoji.shortcode + " "
    }

    private static let maxAttachments = 5

    /// Text or finished uploads will do; anything still uploading holds the
    /// button, since its id is what the send call needs.
    private var canSend: Bool {
        let hasText = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasReadyMedia = !attachments.isEmpty && attachments.allSatisfy { $0.uploadID != nil }
        return (hasText || hasReadyMedia) && !store.isSending && !isUploading
    }

    private var isUploading: Bool {
        attachments.contains { $0.uploadID == nil }
    }

    /// Reads each picked item, shows it immediately, then uploads it. Shown
    /// before the upload finishes on purpose: a thumbnail that appears on tap is
    /// the feedback, and the tile carries its own progress.
    private func ingest(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        mediaSelections = []

        let capacity = Self.maxAttachments - attachments.count
        guard capacity > 0 else { return }

        for item in items.prefix(capacity) {
            Task { await ingest(item) }
        }
    }

    private func ingest(_ item: PhotosPickerItem) async {
        let isVideo = item.supportedContentTypes.contains { $0.conforms(to: .movie) }
        let type = item.supportedContentTypes.first {
            $0.conforms(to: isVideo ? .movie : .image)
        } ?? (isVideo ? .quickTimeMovie : .jpeg)

        guard let data = try? await item.loadTransferable(type: Data.self), !data.isEmpty else {
            store.errorText = isVideo ? AppString("无法读取所选视频。") : AppString("无法读取所选图片。")
            return
        }

        let attachment = ChatComposerAttachment(
            isVideo: isVideo,
            // Downscaled here rather than handing a full-resolution image to a
            // 62pt tile.
            thumbnail: isVideo ? nil : await Self.thumbnail(from: data)
        )
        attachments.append(attachment)

        let ext = type.preferredFilenameExtension ?? (isVideo ? "mov" : "jpg")
        let uploadID = await store.upload(
            data: data,
            fileName: "nodeloc-chat-\(UUID().uuidString).\(ext)",
            mimeType: type.preferredMIMEType ?? (isVideo ? "video/quicktime" : "image/jpeg")
        )

        guard let uploadID else {
            // Failed: take the tile away again, so the strip only ever shows
            // things that will actually send.
            attachments.removeAll { $0.id == attachment.id }
            return
        }
        if let index = attachments.firstIndex(where: { $0.id == attachment.id }) {
            attachments[index].uploadID = uploadID
        }
    }

    private static func thumbnail(from data: Data) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            UIImage(data: data)?.preparingThumbnail(of: CGSize(width: 186, height: 186))
        }.value
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
        let uploadIDs = attachments.compactMap(\.uploadID)
        let inReplyToID = replyTarget?.id
        Task {
            // Cleared *after* the message is recorded on disk, not before.
            // Clearing first is what used to lose the text outright when the
            // request failed; the wait is a local write, not the network.
            if store.selectedThread == nil {
                await store.enqueue(text, chat: chat, inReplyToID: inReplyToID, uploadIDs: uploadIDs)
            } else {
                await store.enqueueToSelectedThread(text, inReplyToID: inReplyToID, uploadIDs: uploadIDs)
            }
            draft = ""
            attachments = []
            replyTarget = nil
            // Your own message should always land in view, gap included. The
            // draft clearing also shrinks the input bar, which moves the floor
            // a second time — hence scrolling after the send resolves.
            if let scrollProxy { scrollToBottom(with: scrollProxy) }
        }
    }

    /// A downward drag anywhere in the transcript puts the keyboard away.
    ///
    /// Simultaneous, so scrolling still works: this only reads the gesture, it
    /// doesn't consume it.
    private var dismissKeyboardDragGesture: some Gesture {
        DragGesture(minimumDistance: 18)
            .onChanged { value in
                guard isInputFocused else { return }
                let translation = value.translation
                guard translation.height > 24,
                      translation.height > abs(translation.width) * 1.2
                else { return }
                isInputFocused = false
            }
    }

    /// Puts the newest message just above the input bar.
    ///
    /// Two hops: the keyboard's own animation resizes the scroll view, and
    /// scrolling before that has landed aims at the old geometry. The first hop
    /// covers the common case, the second corrects it once the resize is done.
    private func scrollToBottom(with proxy: ScrollViewProxy, animated: Bool = true) {
        func perform() {
            if animated {
                withAnimation(.easeOut(duration: 0.22)) {
                    proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                }
            } else {
                proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
            }
        }
        perform()
        Task {
            try? await Task.sleep(for: .milliseconds(320))
            perform()
        }
    }

    private func scrollToInitialTarget(with proxy: ScrollViewProxy) {
        guard let targetID = activeInitialScrollMessageID else { return }
        let signature = initialScrollSignature
        guard appliedScrollSignature != signature else { return }
        appliedScrollSignature = signature

        // An unread marker is a place in the middle of the transcript, so it
        // gets centred. Otherwise the target *is* the newest message, and the
        // gap strip is what to align — aiming at the bubble put it flush
        // against the input bar on open.
        guard activeInitialScrollIsUnread else {
            scrollToBottom(with: proxy, animated: false)
            return
        }

        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.18)) {
                proxy.scrollTo(targetID, anchor: .center)
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
    /// Starts a reply to this message.
    var onReply: (() -> Void)?
    /// Jumps to the message this one quotes.
    var onOpenQuoted: ((ChatQuotedMessage) -> Void)?
    /// Toggles one emoji on this message.
    var onToggleReaction: ((String) -> Void)?
    /// Opens the emoji picker for a new reaction.
    var onAddReaction: (() -> Void)?
    var onEdit: (() -> Void)?
    var onDelete: (() -> Void)?
    var onFlag: (() -> Void)?
    /// Pins or unpins; nil when the site has pinning off.
    var onTogglePin: (() -> Void)?
    var isPinned = false
    /// Quotes this message into a forum post.
    var onQuoteToPost: (() -> Void)?
    /// Offers to resend or discard a message the server refused. Only reached
    /// from a `.failed` row.
    var onRetryFailed: (() -> Void)?

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
                    // The server tracks this (`edited`); saying so is what stops
                    // an edited message from looking like it always read that way.
                    if message.isEdited {
                        Text("已编辑")
                            .font(Theme.body(10))
                            .foregroundStyle(Theme.muted(0.38))
                    }

                    // Only ever on your own rows, and only until the server
                    // acknowledges them. A message shown with no mark at all
                    // is a claim that it was delivered — which is exactly what
                    // this used to do before there was an outbox behind it.
                    switch message.delivery {
                    case .sent:
                        EmptyView()
                    case .sending:
                        Image(systemName: "clock")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Theme.muted(0.42))
                            .accessibilityLabel(AppString("发送中"))
                    case .failed:
                        Button {
                            onRetryFailed?()
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "exclamationmark.circle.fill")
                                    .font(.system(size: 10, weight: .semibold))
                                Text("未发送")
                                    .font(Theme.body(10, weight: .semibold))
                            }
                            .foregroundStyle(Theme.danger)
                        }
                        .buttonStyle(.pressable)
                        .accessibilityLabel(AppString("未发送，点击重试"))
                    }
                }

                if let quoted = message.replyTo {
                    quoteStrip(quoted)
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

                if !message.videos.isEmpty {
                    VStack(alignment: message.isMine ? .trailing : .leading, spacing: 8) {
                        ForEach(message.videos, id: \.self) { url in
                            ChatMessageVideo(url: url)
                        }
                    }
                }

                if !message.reactions.isEmpty {
                    reactionRow
                }

                if let thread = message.thread {
                    Button {
                        onOpenThread(thread)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrowshape.turn.up.left.2")
                                .font(.system(size: 11, weight: .semibold))
                            Text(thread.replyCount > 0 ? AppString("\(thread.replyCount) 条线程回复") : AppString("查看讨论串"))
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
                    .buttonStyle(.pressable)
                }
            }

            if message.isMine {
                authorAvatar
            } else {
                Spacer(minLength: 56)
            }
        }
        // Long press for per-message actions, the way every chat app offers
        // them. `contextMenu` rather than a custom gesture: it doesn't fight the
        // scroll view, and it gives the press its own preview and haptic.
        .contextMenu {
            if let onAddReaction {
                Button(action: onAddReaction) {
                    Label("表情回应", systemImage: "face.smiling")
                }
            }
            if let onReply {
                Button(action: onReply) {
                    Label("引用回复", systemImage: "arrowshape.turn.up.left")
                }
            }
            if !message.text.isEmpty {
                Button {
                    UIPasteboard.general.string = message.text
                    ToastCenter.shared.show(AppString("已复制"))
                } label: {
                    Label("复制文本", systemImage: "doc.on.doc")
                }
            }
            if let onTogglePin {
                Button(action: onTogglePin) {
                    Label(
                        isPinned ? AppString("取消置顶") : AppString("置顶消息"),
                        systemImage: isPinned ? "pin.slash" : "pin"
                    )
                }
            }
            if let onQuoteToPost {
                Button(action: onQuoteToPost) {
                    Label("引用到帖子", systemImage: "arrow.up.doc")
                }
            }
            if message.canModify, let onEdit {
                Button(action: onEdit) {
                    Label("编辑", systemImage: "pencil")
                }
            }
            // Only when the server said this reader can flag it: a direct
            // message drops some types, your own message drops others, and an
            // already-flagged one comes back with none.
            if !message.availableFlags.isEmpty, let onFlag {
                Button(action: onFlag) {
                    Label("举报", systemImage: "flag")
                }
            }
            if message.canModify, let onDelete {
                Button(role: .destructive, action: onDelete) {
                    Label("删除", systemImage: "trash")
                }
            }
        }
    }

    /// Emoji tallies under the bubble. Tapping one adds or removes your own.
    private var reactionRow: some View {
        FlowLayout(spacing: 6) {
            ForEach(message.reactions) { reaction in
                Button {
                    onToggleReaction?(reaction.emoji)
                } label: {
                    HStack(spacing: 4) {
                        CachedRemoteImage(url: ChatEmojiURL.url(for: reaction.emoji)) { image in
                            image.resizable().scaledToFit()
                        } placeholder: {
                            Text(reaction.shortcode)
                                .font(Theme.body(9))
                                .foregroundStyle(Theme.muted(0.5))
                        }
                        .frame(width: 16, height: 16)

                        Text("\(reaction.count)")
                            .font(Theme.body(11, weight: .semibold))
                            .foregroundStyle(reaction.reacted ? Theme.accent700 : Theme.muted(0.6))
                            .monospacedDigit()
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 26)
                    .background(
                        reaction.reacted ? Theme.accent.opacity(0.14) : Theme.surface,
                        in: Capsule()
                    )
                    .overlay {
                        Capsule().strokeBorder(
                            reaction.reacted ? Theme.accent.opacity(0.45) : Theme.divider,
                            lineWidth: 1
                        )
                    }
                }
                .buttonStyle(.pressable)
            }
        }
        .frame(maxWidth: 260, alignment: message.isMine ? .trailing : .leading)
        // A reaction carries only the emoji's name; the catalog is what turns a
        // custom one into its upload URL. Without it the chip falls back to the
        // standard-set path, which is wrong for `ac01` and friends.
        .task { await EmojiCatalog.shared.loadIfNeeded() }
    }

    /// The message being replied to, above the body — an accent rule, who wrote
    /// it, and one line of it. Tapping jumps to the original.
    private func quoteStrip(_ quoted: ChatQuotedMessage) -> some View {
        Button {
            onOpenQuoted?(quoted)
        } label: {
            HStack(spacing: 8) {
                Rectangle()
                    .fill(Theme.accent.opacity(0.65))
                    .frame(width: 2)

                VStack(alignment: .leading, spacing: 1) {
                    Text(quoted.authorName)
                        .font(Theme.body(11, weight: .semibold))
                        .foregroundStyle(Theme.accent700)
                        .lineLimit(1)
                    Text(quoted.excerpt)
                        .font(Theme.body(12))
                        .foregroundStyle(Theme.muted(0.6))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
            .padding(.leading, 2)
            .frame(maxWidth: 260, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
    }

    @ViewBuilder
    private var authorAvatar: some View {
        if let target = message.authorProfileTarget {
            NavigationLink(value: ChatRoute.profile(target)) {
                avatarImage
            }
            .buttonStyle(.pressable)
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
        if containsEmojiImage {
            ChatInlineContentView(fragments: message.content)
        } else {
            Text(message.text)
                .font(Theme.body(15))
                .lineSpacing(3)
                .foregroundStyle(Theme.text)
        }
    }

    /// Any emoji at all means the rich renderer: emoji are images here, custom
    /// and standard alike, and plain `Text` can't show them.
    private var containsEmojiImage: Bool {
        message.content.contains { fragment in
            if case .emojiImage = fragment.kind {
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
        case .emojiImage(let emoji):
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
            case .emojiImage(let emoji):
                items.append(ChatInlineDisplayItem(id: fragment.id, kind: .emojiImage(emoji)))
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
        case emojiImage(ChatEmojiImage)
    }

    let id: String
    let kind: Kind
}

private struct ChatInlineEmojiImage: View {
    let emoji: ChatEmojiImage

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
        .buttonStyle(.pressable)
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
                    // Pinch, pan and double-tap, the same gestures the post
                    // reader's viewer has. Wrapping the already-loaded image
                    // rather than a URL-driven view keeps the single download
                    // this screen needs anyway for 分享 and 保存.
                    ZoomableContainer {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                    }
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
                    .buttonStyle(.pressable)

                    Spacer()

                    Button {
                        isShowingFileExporter = true
                    } label: {
                        previewButtonIcon("square.and.arrow.down")
                    }
                    .buttonStyle(.pressable)
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
                statusText = AppString("已保存文件")
            case .failure:
                statusText = AppString("保存失败")
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
            statusText = AppString("图片加载失败")
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

/// Edits one chat message. Deliberately plain: chat messages are a line or two,
/// and the post composer's machinery (nodes, titles, polls) has nothing to do
/// with them.
private struct ChatMessageEditSheet: View {
    let original: String
    /// Returns whether it saved; a failure keeps the sheet open.
    let save: (String) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var isSaving = false
    @FocusState private var isFocused: Bool

    init(original: String, save: @escaping (String) async -> Bool) {
        self.original = original
        self.save = save
        _text = State(initialValue: original)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TextField("消息", text: $text, axis: .vertical)
                    .font(Theme.body(16))
                    .foregroundStyle(Theme.text)
                    .focused($isFocused)
                    .lineLimit(3...10)
                    .padding(14)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .padding(16)

                Spacer(minLength: 0)
            }
            .background(Theme.bg)
            .navigationTitle("编辑消息")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        isSaving = true
                        Task {
                            if await save(text) { dismiss() }
                            isSaving = false
                        }
                    }
                    .disabled(!canSave || isSaving)
                }
            }
            .disabled(isSaving)
        }
        .standardSheet([.medium])
        .onAppear { isFocused = true }
    }

    private var canSave: Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != original.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
