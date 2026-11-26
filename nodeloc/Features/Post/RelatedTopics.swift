//
//  RelatedTopics.swift
//  nodeloc
//
//  The strip at the foot of a topic page (`GET /api/v1/topics/{id}/related`),
//  the JSON twin of the web's three columns: similar topics, recent ones in
//  this node, and the week's site-wide hits. Five at a time; each column holds
//  ten in all, so "换一批" fetches the second five and then starts over.
//
//  Unlike the web's — which caches whole pages and so can't — this one is cut
//  to the reader: nodes and people they block are already gone from it.
//

import SwiftUI

@MainActor
@Observable
final class RelatedTopicsStore {
    private let client = DiscourseClient()

    private(set) var kind: DiscourseClient.RelatedTopicsKind = .similar
    private(set) var posts: [Post] = []
    private(set) var isLoading = false
    /// Where the next batch starts. Null from the server means that column is
    /// exhausted, and the next "换一批" wraps back to the top.
    private var nextOffset: Int?
    private var topicID: Int?

    /// Blocking has to empty a row on the spot, not at the next fetch.
    var visiblePosts: [Post] { BlockedUsersStore.shared.visible(posts) }

    func load(topicID: Int, kind: DiscourseClient.RelatedTopicsKind? = nil) async {
        let kind = kind ?? self.kind
        // A column switch starts over; a reload of the same one doesn't.
        if self.topicID != topicID || self.kind != kind {
            posts = []
            nextOffset = nil
        }
        self.topicID = topicID
        self.kind = kind
        await fetch(offset: 0, replacing: true)
    }

    /// The next five, wrapping to the start once the column runs out.
    func loadNextBatch() async {
        await fetch(offset: nextOffset ?? 0, replacing: true)
    }

    private func fetch(offset: Int, replacing: Bool) async {
        guard let topicID, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        guard let result = try? await client.relatedTopics(topicID: topicID, kind: kind, offset: offset) else {
            return
        }
        let usersByID = Dictionary(
            (result.topics.users ?? []).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let mapped = result.topics.topicList.topics.map {
            FeedMapper.post(topic: $0, usersByID: usersByID, client: client)
        }
        if replacing { posts = mapped } else { posts += mapped }
        nextOffset = result.nextOffset
    }
}

/// The strip: a column picker, five rows, and "换一批".
struct RelatedTopicsSection: View {
    let topicID: Int
    let onOpen: (Post) -> Void

    @State private var store = RelatedTopicsStore()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ForEach(DiscourseClient.RelatedTopicsKind.allCases, id: \.self) { kind in
                    Button {
                        Task { await store.load(topicID: topicID, kind: kind) }
                    } label: {
                        Text(kind.title)
                            .font(Theme.body(12, weight: store.kind == kind ? .semibold : .regular))
                            .foregroundStyle(store.kind == kind ? Theme.accent700 : Theme.muted(0.5))
                            .padding(.vertical, 5)
                            .padding(.horizontal, 10)
                            .background(
                                store.kind == kind ? Theme.accent.opacity(0.12) : Color.clear,
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.pressable)
                }

                Spacer(minLength: 0)

                Button {
                    Task { await store.loadNextBatch() }
                } label: {
                    Label(AppString("换一批"), systemImage: "arrow.triangle.2.circlepath")
                        .labelStyle(CompactLabelStyle())
                        .font(Theme.body(11))
                        .foregroundStyle(Theme.muted(0.5))
                }
                .buttonStyle(.pressable)
                .disabled(store.isLoading)
            }

            ForEach(store.visiblePosts) { post in
                Button { onOpen(post) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(post.title)
                            .font(Theme.body(13))
                            .foregroundStyle(Theme.text)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        HStack(spacing: 8) {
                            if let author = post.authorUsername {
                                Text(author)
                            }
                            Text("· \(post.comments)")
                            Image(systemName: "bubble.right")
                                .font(.system(size: 9))
                        }
                        .font(Theme.body(11))
                        .foregroundStyle(Theme.muted(0.45))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)

                Divider().background(Theme.divider)
            }
        }
        .task(id: topicID) { await store.load(topicID: topicID) }
    }
}
