//
//  BlockedUsersPage.swift
//  nodeloc
//
//  屏蔽的用户 — the account's block list, and the way back out of it.
//
//  Discourse keeps this list itself (`ignored_usernames` and `muted_usernames`
//  on the owner's serialized profile), so the page reads the server's answer
//  rather than only what this device happens to remember. Removing someone puts
//  their notification level back to 常规, the same call the website's own
//  preferences page makes.
//
//  Guideline 1.2 asks for a way to block abusive users. A block nobody can undo
//  is a trap rather than a tool — and a reader who blocks the wrong person by
//  mistake needs this page more than they needed the block.
//

import SwiftUI

struct BlockedUsersPage: View {
    let onClose: () -> Void

    private var store = BlockedUsersStore.shared
    @State private var isLoading = true
    @State private var busyUsername: String?
    /// Set when the server refused, which is worth saying: un-hiding someone
    /// the account still ignores server-side would show content it is set to
    /// hide.
    @State private var errorText: String?

    /// Explicit because reading the shared store makes the memberwise
    /// initialiser private.
    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    var body: some View {
        VStack(spacing: 0) {
            SettingsPageHeader(title: AppString("屏蔽的用户"), onClose: onClose)

            ScrollView {
                LazyVStack(spacing: 0) {
                    if isLoading, store.usernames.isEmpty {
                        ProgressView()
                            .tint(Theme.accent)
                            .padding(.vertical, 40)
                    } else if store.usernames.isEmpty {
                        EmptyStateView(
                            icon: "hand.raised",
                            message: AppString("你还没有屏蔽任何人")
                        )
                        .padding(.vertical, 40)
                    } else {
                        SettingsSection(
                            title: AppString("已屏蔽 (\(store.usernames.count))"),
                            footer: footer
                        ) {
                            ForEach(sortedUsernames, id: \.self) { username in
                                row(username)
                            }
                        }
                    }

                    if let errorText {
                        Text(errorText)
                            .font(Theme.body(13))
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 20)
                            .padding(.top, 12)
                    }
                }
                .padding(.bottom, 30)
            }
            .scrollIndicators(.hidden)
            .refreshable { await reload() }
        }
        .background(Theme.bg.ignoresSafeArea())
        .task {
            await reload()
            isLoading = false
        }
    }

    /// Alphabetical. The server returns them in whatever order the join
    /// produced, which changes between fetches for no reason the reader can see.
    private var sortedUsernames: [String] {
        store.usernames.sorted()
    }

    private var footer: String {
        if !store.canIgnoreOnServer {
            // The account is below the trust level `ignore_allowed_groups`
            // requires, so blocks stop notifications and hide content in the
            // app without becoming a server-side ignore. Better said than left
            // as a mystery.
            return AppString("你的账号等级还不能在服务器上屏蔽他人，所以这些人的内容只在 App 中隐藏，同时不再收到他们的通知。")
        }
        return AppString("被屏蔽的人的主题和回复不会出现在你的列表里，你也不会收到他们的通知。")
    }

    private func row(_ username: String) -> some View {
        HStack(spacing: 12) {
            RemoteAvatar(
                url: nil,
                letter: String(username.prefix(1)).uppercased(),
                size: 34
            )

            VStack(alignment: .leading, spacing: 2) {
                Text("@\(username)")
                    .font(Theme.body(15, weight: .semibold))
                    .foregroundStyle(Theme.text)
                if store.localOnly.contains(username) {
                    Text("仅在此设备隐藏")
                        .font(Theme.body(12))
                        .foregroundStyle(Theme.muted(0.55))
                }
            }

            Spacer(minLength: 8)

            if busyUsername == username {
                ProgressView().tint(Theme.accent)
            } else {
                Button(AppString("解除")) {
                    Task { await unblock(username) }
                }
                .font(Theme.body(14, weight: .semibold))
                .foregroundStyle(Theme.accent)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func reload() async {
        errorText = nil
        // A failure here is not worth reporting: the locally stored list is
        // still shown, which is better than an empty page.
        await store.loadFromServer()
    }

    private func unblock(_ username: String) async {
        busyUsername = username
        errorText = nil
        defer { busyUsername = nil }

        if await store.unblock(username: username) {
            ToastCenter.shared.show(AppString("已解除屏蔽 @\(username)"))
        } else {
            errorText = AppString("解除屏蔽失败，请稍后重试。")
        }
    }
}
