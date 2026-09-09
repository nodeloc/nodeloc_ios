//
//  TagTopicsView.swift
//  nodeloc
//
//  Topics for one `#tag`, shown when a tag badge in a post is tapped.
//
//  Rows are `NodeTopicRow` at the reader's chosen density, so a tag list and a
//  node list are the same thing to look at — a tag is just a different way of
//  gathering topics.
//

import SwiftUI

struct TagTopicsView: View {
    let slug: String
    /// What the badge read, which keeps the author's casing (`AFF` vs `aff`).
    let label: String
    let onOpenPost: (Post) -> Void

    @State private var store = TagTopicsStore()
    private var readingMode = NodeReadingModeStore.shared

    /// Explicit because the shared reading-mode store makes the memberwise
    /// initialiser private.
    init(slug: String, label: String, onOpenPost: @escaping (Post) -> Void) {
        self.slug = slug
        self.label = label
        self.onOpenPost = onOpenPost
    }

    var body: some View {
        NavigationStack {
            content
                .background(Theme.bg)
                .navigationTitle("#\(label)")
                .navigationBarTitleDisplayMode(.inline)
        }
        .task { await store.loadIfNeeded(slug: slug) }
    }

    @ViewBuilder
    private var content: some View {
        if store.isLoading, store.visiblePosts.isEmpty {
            ProgressView()
                .tint(Theme.accent)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.visiblePosts.isEmpty {
            EmptyStateView(
                icon: "number",
                message: store.errorText ?? AppString("这个标签下还没有主题")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(store.visiblePosts) { post in
                        NodeTopicRow(
                            post: post,
                            mode: readingMode.mode,
                            onTap: { onOpenPost(post) }
                        )
                    }

                    if store.hasMore {
                        HStack {
                            ProgressView().tint(Theme.accent)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                        .onScrollVisibilityChange(threshold: 0.1) { visible in
                            guard visible else { return }
                            Task { await store.loadMore() }
                        }
                    }
                }
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
        }
    }
}
