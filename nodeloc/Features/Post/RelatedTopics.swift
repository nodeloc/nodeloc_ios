//
//  RelatedTopics.swift
//  nodeloc
//
//  相关主题 at the foot of the reader (App-iOS-Post3, V317): the title with
//  换一批, four filters, five rows drawn like the home list, and a way into the
//  node. 16pt margins; one fixed layout whatever the home list style is.
//
//  Filters and their data:
//  - 相关推荐, n/{slug}, 本周热门: `GET /api/v1/topics/{id}/related?kind=
//    similar|node|week&offset=` — five a batch, ten at most per filter;
//    换一批 asks for `next_offset` and starts again at 0 once it is null.
//  - 同一作者: `GET /api/v1/users/{author}/topics`, the author's newest
//    twenty without this one, shown five at a time and cycled here.
//
//  Each filter's batch is kept for the life of the reader page, so switching
//  back and forth doesn't refetch; 换一批 swaps the rows in place.
//

import SwiftUI

enum RelatedFilter: Hashable, CaseIterable {
    case similar, node, week, author

    var serverKind: DiscourseClient.RelatedTopicsKind? {
        switch self {
        case .similar: .similar
        case .node: .node
        case .week: .week
        case .author: nil
        }
    }
}

@MainActor
@Observable
final class RelatedTopicsStore {
    private let client = DiscourseClient()

    private struct Column {
        var posts: [Post] = []
        /// Server filters: where the next batch starts (nil wraps to 0).
        var nextOffset: Int?
        /// 同一作者: everything fetched, and which five are showing.
        var pool: [Post] = []
        var page = 0
        var loaded = false
    }

    private(set) var filter: RelatedFilter = .similar
    private var columns: [RelatedFilter: Column] = [:]
    private(set) var isLoading = false
    private var topicID: Int?
    private var author: String?
    private var generation = 0

    static let batchSize = 5

    /// What the current filter shows, without anything blocked since.
    var visiblePosts: [Post] {
        BlockedUsersStore.shared.visible(columns[filter]?.posts ?? [])
    }

    var hasLoadedCurrent: Bool { columns[filter]?.loaded == true }

    func configure(topicID: Int, author: String?) {
        // The author arrives with the topic, after the section is first
        // drawn; take it whenever it shows up.
        if let author, !author.isEmpty { self.author = author }
        guard self.topicID != topicID else { return }
        self.topicID = topicID
        if let author, !author.isEmpty { self.author = author }
        filter = .similar
        columns = [:]
    }

    func select(_ next: RelatedFilter) async {
        filter = next
        if columns[next]?.loaded != true { await fetch(next, offset: 0) }
    }

    func loadIfNeeded() async {
        if columns[filter]?.loaded != true { await fetch(filter, offset: 0) }
    }

    /// 换一批: the server's next five, or the next five of what's held.
    func nextBatch() async {
        let current = filter
        if current == .author {
            guard var column = columns[current], !column.pool.isEmpty else { return }
            let pages = max(1, Int(ceil(Double(column.pool.count) / Double(Self.batchSize))))
            column.page = (column.page + 1) % pages
            column.posts = Self.slice(column.pool, page: column.page)
            columns[current] = column
        } else {
            await fetch(current, offset: columns[current]?.nextOffset ?? 0)
        }
    }

    private static func slice(_ pool: [Post], page: Int) -> [Post] {
        Array(pool.dropFirst(page * batchSize).prefix(batchSize))
    }

    private func fetch(_ which: RelatedFilter, offset: Int) async {
        guard let topicID else { return }
        generation += 1
        let request = generation
        isLoading = true
        defer { if request == generation { isLoading = false } }

        var column = columns[which] ?? Column()
        if let kind = which.serverKind {
            guard let result = try? await client.relatedTopics(topicID: topicID, kind: kind, offset: offset) else {
                if request == generation { column.loaded = true; columns[which] = column }
                return
            }
            column.posts = await map(result.topics).filter { $0.id != topicID }
            column.nextOffset = result.nextOffset
        } else {
            // Not known yet (the topic is still loading): nothing to cache.
            guard let author else { return }
            guard let result = try? await client.authorTopics(username: author) else {
                column.loaded = true
                columns[which] = column
                return
            }
            column.pool = await map(result).filter { $0.id != topicID }
            column.page = 0
            column.posts = Self.slice(column.pool, page: 0)
        }
        column.loaded = true
        columns[which] = column
    }

    /// The site's categories, for each row's node (as the tag page does).
    private var categoriesByID: [Int: DiscourseCategory] = [:]

    private func map(_ response: LatestResponse) async -> [Post] {
        if categoriesByID.isEmpty, let site = await SiteResources.shared.siteResponse() {
            categoriesByID = Dictionary(
                (site.categories ?? []).map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
        }
        let usersByID = Dictionary(
            (response.users ?? []).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return response.topicList.topics.map {
            FeedMapper.post(
                topic: $0,
                usersByID: usersByID,
                client: client,
                category: $0.categoryId.flatMap { categoriesByID[$0] }
            )
        }
    }
}

/// The section itself.
struct RelatedTopicsSection: View {
    let topicID: Int
    let nodeSlug: String?
    let author: String?
    let onOpen: (Post) -> Void
    let onOpenNode: (String) -> Void

    @State private var store = RelatedTopicsStore()

    private var filters: [RelatedFilter] {
        RelatedFilter.allCases.filter { filter in
            switch filter {
            case .node: nodeSlug != nil
            case .author: author != nil
            default: true
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            titleRow
            chips
            rows
            if let nodeSlug {
                Button {
                    onOpenNode(nodeSlug)
                } label: {
                    Text(AppString("去 n/\(nodeSlug) 看更多"))
                        .font(Theme.body(15, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                        .background(Theme.chip, in: Capsule())
                }
                .buttonStyle(.pressable)
                .padding(.top, 4)
            }
        }
        .padding(.horizontal, 16)
        .onAppear {
            store.configure(topicID: topicID, author: author)
        }
        // Fetched when the section scrolls into view — the foot of the
        // replies — so opening a post is never slowed down by it.
        .onScrollVisibilityChange(threshold: 0.01) { visible in
            guard visible else { return }
            store.configure(topicID: topicID, author: author)
            Task {
                await store.loadIfNeeded()
            }
        }
    }

    private var titleRow: some View {
        HStack {
            Text(AppString("相关主题"))
                .font(Theme.body(22, weight: .bold))
                .foregroundStyle(Theme.text)
            Spacer()
            Button {
                Task { await store.nextBatch() }
            } label: {
                Label(AppString("换一批"), systemImage: "arrow.triangle.2.circlepath")
                    .font(Theme.body(14, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 14)
                    .frame(height: 36)
                    .background(Theme.chip, in: Capsule())
            }
            .buttonStyle(.pressable)
            .disabled(store.isLoading || store.visiblePosts.isEmpty)
        }
    }

    private var chips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(filters, id: \.self) { filter in
                    Button {
                        Task { await store.select(filter) }
                    } label: {
                        CapsuleChipLabel(title: title(filter), isSelected: store.filter == filter, unselectedWeight: .medium)
                    }
                    .buttonStyle(.pressable)
                }
            }
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
    }

    private func title(_ filter: RelatedFilter) -> String {
        switch filter {
        case .similar: AppString("相关推荐")
        case .node: "n/\(nodeSlug ?? "")"
        case .week: AppString("本周热门")
        case .author: AppString("同一作者")
        }
    }

    @ViewBuilder
    private var rows: some View {
        let posts = store.visiblePosts
        if !store.hasLoadedCurrent && posts.isEmpty {
            VStack(spacing: 0) {
                ForEach(0..<3, id: \.self) { index in
                    if index > 0 { Divider().overlay(Theme.divider) }
                    RelatedRowSkeleton()
                }
            }
        } else if posts.isEmpty {
            Text(AppString("这里暂时没有主题"))
                .font(Theme.body(14))
                .foregroundStyle(Theme.textMuted)
                .padding(.vertical, 12)
        } else {
            VStack(spacing: 0) {
                ForEach(Array(posts.enumerated()), id: \.element.id) { index, post in
                    if index > 0 { Divider().overlay(Theme.divider) }
                    Button { onOpen(post) } label: {
                        RelatedTopicRow(post: post)
                    }
                    .buttonStyle(.pressable)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: posts.map(\.id))
        }
    }
}

/// One row: node mark, n/slug · time · 已读, the title (已解决 first), the
/// votes and replies, and a thumbnail with its picture count.
struct RelatedTopicRow: View {
    let post: Post

    private var slug: String {
        post.node.hasPrefix("n/") ? String(post.node.dropFirst(2)) : post.node
    }

    private var imageCount: Int {
        post.media.count
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    if let node = NodeCatalog.shared.cachedNode(slug: slug) {
                        NodeAvatar(node: node, size: 20, cornerRadius: 10)
                    } else {
                        Circle().fill(Theme.chip).frame(width: 20, height: 20)
                    }
                    Text(post.node)
                        .font(Theme.body(13, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Text("· \(post.time)")
                        .font(Theme.body(13))
                        .foregroundStyle(Theme.textMuted)
                        .lineLimit(1)
                    if post.isRead {
                        Text(AppString("· 已读"))
                            .font(Theme.body(13))
                            .foregroundStyle(Theme.textFaint)
                    }
                }

                titleText
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 16) {
                    Label("\(post.voteScore ?? post.baseVotes)", systemImage: "arrow.up")
                    Label("\(post.comments)", systemImage: "bubble.left")
                }
                .labelStyle(CompactLabelStyle())
                .font(Theme.body(13, weight: .semibold))
                .foregroundStyle(Theme.textMuted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let url = post.imageURL {
                ZStack(alignment: .bottomTrailing) {
                    CachedRemoteImage(url: url) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Theme.chip
                    }
                    .frame(width: 84, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    if imageCount > 1 {
                        Label("\(imageCount)", systemImage: "photo")
                            .labelStyle(CompactLabelStyle())
                            .font(Theme.body(11, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .frame(height: 20)
                            .background(.black.opacity(0.65), in: Capsule())
                            .padding(4)
                    }
                }
                .padding(.top, 26)
            }
        }
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }

    private var titleText: Text {
        let title = Text(post.title)
            .font(Theme.body(17, weight: .bold))
            .foregroundColor(post.isRead ? Theme.textMuted : Theme.text)
        guard post.isSolved else { return title }
        return Text(Image(systemName: "checkmark")).font(.system(size: 12, weight: .bold)).foregroundColor(Theme.accent)
            + Text(AppString(" 已解决  ")).font(Theme.body(13, weight: .bold)).foregroundColor(Theme.accent)
            + title
    }
}

private struct RelatedRowSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            RoundedRectangle(cornerRadius: 4).fill(Theme.chip).frame(width: 140, height: 12)
            RoundedRectangle(cornerRadius: 4).fill(Theme.chip).frame(height: 16)
            RoundedRectangle(cornerRadius: 4).fill(Theme.chip).frame(width: 200, height: 16)
            RoundedRectangle(cornerRadius: 4).fill(Theme.chip).frame(width: 90, height: 12)
        }
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .skeletonPulsing()
    }
}
