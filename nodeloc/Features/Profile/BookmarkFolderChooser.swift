//
//  BookmarkFolderChooser.swift
//  nodeloc
//
//  Which 收藏夹 a bookmark is in: 未分类 and the reader's folders with their
//  counts, a check on the current one, 新建收藏夹 inline, and (from a post)
//  取消收藏. Shared by 保存书签 in the reader and the cards of 我的收藏.
//
//  The server saves a bookmark without a folder (`PUT /api/v1/posts/{id}/
//  bookmark`, no body, no id back) and moves bookmarks by id (`POST
//  /api/v1/bookmarks/move {"ids","folder_id"}`, 0 = 未分类). So a bookmark
//  made in the reader is found in `GET /api/v1/saved` by its post first.
//

import SwiftUI

@MainActor
enum BookmarkAPI {
    private static var client: DiscourseClient { DiscourseClient() }

    static func folders() async throws -> NLBookmarkFolders {
        try await client.bookmarkFolders()
    }

    /// `POST /api/v1/bookmark-folders {"name"}` → the new folder's id.
    static func createFolder(_ name: String) async throws -> Int {
        struct Created: Decodable { let id: Int }
        let data = try await client.http.send("POST", "api/v1/bookmark-folders", body: .json(["name": name]))
        return try NodelocJSON.decode(Created.self, from: data).id
    }

    /// `POST /api/v1/bookmarks/move`; nil is 未分类.
    static func move(_ bookmarkIDs: [Int], to folderID: Int?) async throws {
        try await client.http.send("POST", "api/v1/bookmarks/move", body: .json(["ids": bookmarkIDs, "folder_id": folderID ?? 0]))
    }

    /// `PUT /api/v1/bookmarks/{id}/note {"note"}` (at most 100 characters).
    static func setNote(_ bookmarkID: Int, _ note: String) async throws {
        try await client.http.send("PUT", "api/v1/bookmarks/\(bookmarkID)/note", body: .json(["note": note]))
    }

    /// `POST /api/v1/bookmarks/remove {"ids"}`.
    static func remove(_ bookmarkIDs: [Int]) async throws {
        try await client.http.send("POST", "api/v1/bookmarks/remove", body: .json(["ids": bookmarkIDs]))
    }

    /// The reader's bookmark of a post. The server has no lookup by post, so
    /// the newest bookmarks are searched by the topic's title and matched on
    /// the post id.
    static func find(postID: Int, topicTitle: String?) async throws -> NLSaved.Bookmark? {
        var query = [URLQueryItem(name: "limit", value: "50")]
        if let title = topicTitle?.trimmingCharacters(in: .whitespaces), !title.isEmpty {
            query.append(URLQueryItem(name: "q", value: String(title.prefix(40))))
        }
        let page: NLSaved = try await client.get("api/v1/saved", query: query)
        if let hit = page.bookmarks.first(where: { $0.postId == postID }) { return hit }
        // The title search can miss (edited titles); the newest page then.
        let latest: NLSaved = try await client.get("api/v1/saved", query: [URLQueryItem(name: "limit", value: "50")])
        return latest.bookmarks.first { $0.postId == postID }
    }

    /// The server's own words for a refusal.
    static func message(_ error: Error) -> String {
        ServerFieldErrors.last().values.first
            ?? (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

/// The chooser sheet. `onChoose` returns nil on success or the server's
/// message, which the sheet shows while staying open.
struct BookmarkFolderChooser: View {
    let current: Int?
    var onRemove: (() -> Void)? = nil
    let onChoose: (Int?) async -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var folders: [NLBookmarkFolders.Folder] = []
    @State private var unfiled: Int?
    @State private var loaded = false
    @State private var working: Int?? = nil
    @State private var errorText: String?
    @State private var creating = false
    @State private var newName = ""
    @State private var createMessage: String?
    @State private var confirmRemove = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    row(title: AppString("未分类"), count: unfiled, id: nil)
                    ForEach(folders, id: \.id) { folder in
                        row(title: folder.name, count: folder.count, id: folder.id)
                    }
                    Button {
                        newName = ""
                        createMessage = nil
                        creating = true
                    } label: {
                        Label(AppString("新建收藏夹"), systemImage: "folder.badge.plus")
                    }
                } footer: {
                    if let errorText { Text(errorText).foregroundStyle(Theme.danger) }
                }
                if let onRemove {
                    Section {
                        Button(role: .destructive) { confirmRemove = true } label: {
                            Label(AppString("取消收藏"), systemImage: "bookmark.slash")
                        }
                        .alert(AppString("取消收藏这条内容？"), isPresented: $confirmRemove) {
                            Button(AppString("取消收藏"), role: .destructive) { dismiss(); onRemove() }
                            Button(AppString("保留"), role: .cancel) {}
                        }
                    }
                }
            }
            .overlay { if !loaded { ProgressView() } }
            .navigationTitle(AppString("选择收藏夹"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppString("完成")) { dismiss() }
                }
            }
            .alert(AppString("新建收藏夹"), isPresented: $creating) {
                TextField(AppString("收藏夹名字"), text: $newName)
                Button(AppString("取消"), role: .cancel) {}
                Button(AppString("创建")) { Task { await create() } }
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            } message: {
                Text(createMessage ?? AppString("最多 16 个字。"))
            }
        }
        .presentationDetents([.medium, .large])
        .task { await load() }
    }

    private func row(title: String, count: Int?, id: Int?) -> some View {
        Button {
            Task { await choose(id) }
        } label: {
            HStack {
                Label(title, systemImage: id == nil ? "tray" : "folder")
                    .foregroundStyle(Theme.text)
                Spacer()
                if let count { Text(verbatim: "\(count)").foregroundStyle(.secondary) }
                if working == .some(id) {
                    ProgressView().controlSize(.small)
                } else if id == current {
                    Image(systemName: "checkmark").foregroundStyle(Theme.accent).fontWeight(.semibold)
                }
            }
        }
        .disabled(working != nil)
    }

    private func load() async {
        if let answer = try? await BookmarkAPI.folders() {
            folders = answer.folders
            unfiled = answer.unfiled
        }
        loaded = true
    }

    private func choose(_ id: Int?) async {
        guard id != current else { dismiss(); return }
        working = .some(id)
        errorText = nil
        let error = await onChoose(id)
        working = nil
        if let error { errorText = error } else { dismiss() }
    }

    /// Creates the folder, then puts the bookmark in it.
    private func create() async {
        let name = newName.trimmingCharacters(in: .whitespaces)
        do {
            let id = try await BookmarkAPI.createFolder(name)
            await load()
            await choose(id)
        } catch {
            createMessage = BookmarkAPI.message(error)
            creating = true
        }
    }
}
