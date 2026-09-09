//
//  ChatUserPickerSheet.swift
//  nodeloc
//
//  Picks people: for starting a group chat, and for adding to an existing one.
//

import SwiftUI

/// Search-and-select over site users.
///
/// One sheet for two jobs — `POST /chat/api/direct-message-channels` takes
/// `target_usernames[]` and `POST /chat/api/channels/:id/memberships` takes
/// `usernames[]`, so both callers need exactly this: a set of usernames.
struct ChatUserPickerSheet: View {
    let title: String
    let confirmLabel: String
    /// Returns whether it succeeded; a failure keeps the sheet open with the
    /// selection intact.
    let onConfirm: ([String]) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var results: [DiscourseUser] = []
    @State private var selected: [DiscourseUser] = []
    @State private var isSearching = false
    @State private var isSubmitting = false
    @State private var searchTask: Task<Void, Never>?

    /// The server caps a direct message's participants
    /// (`chat_max_direct_message_users`); this is the site default, and the
    /// server is still the authority.
    private static let maxSelection = 10

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchField

                if !selected.isEmpty {
                    selectedStrip
                }

                resultList
            }
            .background(Theme.bg)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(confirmLabel) { submit() }
                        .disabled(selected.isEmpty || isSubmitting)
                }
            }
            .disabled(isSubmitting)
        }
        .standardSheet([.medium, .large])
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.muted(0.45))
            TextField("搜索用户名", text: $searchText)
                .font(Theme.body(15))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onChange(of: searchText) { _, term in search(term) }
            if isSearching {
                ProgressView().controlSize(.mini)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(Theme.surface, in: Capsule())
        .padding(16)
    }

    private var selectedStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(selected) { user in
                    Button {
                        selected.removeAll { $0.id == user.id }
                    } label: {
                        HStack(spacing: 5) {
                            Text(user.username)
                                .font(Theme.body(13, weight: .semibold))
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .bold))
                        }
                        .foregroundStyle(Theme.bg)
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .background(Theme.accent, in: Capsule())
                    }
                    .buttonStyle(.pressable)
                }
            }
            .padding(.horizontal, 16)
        }
        .scrollIndicators(.hidden)
        .padding(.bottom, 12)
    }

    private var resultList: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(results) { user in
                    let isPicked = selected.contains { $0.id == user.id }
                    Button {
                        toggle(user)
                    } label: {
                        HStack(spacing: 12) {
                            RemoteAvatar(
                                url: user.avatarTemplate.flatMap {
                                    DiscourseClient().avatarURL(template: $0, size: 96)
                                },
                                letter: String(user.username.prefix(1)).uppercased(),
                                variant: user.id,
                                size: 38
                            )

                            VStack(alignment: .leading, spacing: 2) {
                                Text(user.name?.isEmpty == false ? user.name! : user.username)
                                    .font(Theme.body(15, weight: .semibold))
                                    .foregroundStyle(Theme.text)
                                    .lineLimit(1)
                                Text("@\(user.username)")
                                    .font(Theme.body(12))
                                    .foregroundStyle(Theme.muted(0.55))
                                    .lineLimit(1)
                            }

                            Spacer(minLength: 0)

                            Image(systemName: isPicked ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 18))
                                .foregroundStyle(isPicked ? Theme.accent : Theme.muted(0.3))
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 11)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.pressable)
                }

                if results.isEmpty, !searchText.isEmpty, !isSearching {
                    Text("没有找到用户")
                        .font(Theme.body(13))
                        .foregroundStyle(Theme.muted(0.5))
                        .padding(.top, 30)
                }
            }
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
    }

    private func toggle(_ user: DiscourseUser) {
        if let index = selected.firstIndex(where: { $0.id == user.id }) {
            selected.remove(at: index)
        } else if selected.count < Self.maxSelection {
            selected.append(user)
        } else {
            ToastCenter.shared.show(AppString("最多选择 \(Self.maxSelection) 人"))
        }
    }

    /// Debounced: the user endpoint is a real request and this fires per
    /// keystroke otherwise.
    private func search(_ term: String) {
        searchTask?.cancel()
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = []
            return
        }
        isSearching = true
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled else { return }
            let found = (try? await DiscourseClient().searchUsers(term: trimmed))?.users ?? []
            guard !Task.isCancelled else { return }
            results = found
            isSearching = false
        }
    }

    private func submit() {
        isSubmitting = true
        Task {
            if await onConfirm(selected.map(\.username)) { dismiss() }
            isSubmitting = false
        }
    }
}
