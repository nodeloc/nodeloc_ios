//
//  TagPages.swift
//  nodeloc
//
//  所有标签 (App-iOS-Tags) and one tag's page (App-iOS-Tag), on the app-wide
//  page stack.
//
//  Data: `GET /api/v1/tags` (each tag's look, description, topic count,
//  group, staff-only) and `GET /api/v1/tag-groups` (names, descriptions,
//  每帖限选一个). A tag's topics are `GET /api/v1/topics?tag=`.
//
//  What the design shows and the server doesn't send is left out: whether
//  the reader follows a tag (so no 已关注 / 我关注的), 今日 +N and 今日最活跃,
//  a tag's follower count, and solved / unsolved counts.
//

import SwiftUI

nonisolated struct NLTagCatalog: Decodable, Sendable {
    nonisolated struct Tag: Decodable, Sendable, Identifiable {
        let id: Int
        let name: String
        let topicCount: Int?
        let description: String?
        let group: String?
        let staffOnly: Bool?
    }
    let tags: [Tag]
}

nonisolated struct NLTagGroups: Decodable, Sendable {
    nonisolated struct Group: Decodable, Sendable, Identifiable {
        let id: Int
        let name: String
        let description: String?
        let exclusive: Bool?
        let position: Int?
        let tagCount: Int?
    }
    let groups: [Group]
}

@MainActor
@Observable
final class TagCatalogStore {
    static let shared = TagCatalogStore()

    private(set) var tags: [NLTagCatalog.Tag] = []
    private(set) var groups: [NLTagGroups.Group] = []
    private(set) var loaded = false
    private let client = DiscourseClient()

    func load() async {
        async let tagsCall: NLTagCatalog? = try? client.get("api/v1/tags", query: [URLQueryItem(name: "limit", value: "500")])
        async let groupsCall: NLTagGroups? = try? client.get("api/v1/tag-groups")
        let (tagList, groupList) = await (tagsCall, groupsCall)
        if let tagList { tags = tagList.tags }
        if let groupList { groups = groupList.groups.sorted { ($0.position ?? 0) < ($1.position ?? 0) } }
        loaded = true
        await TagLookStore.shared.loadIfNeeded()
    }

    func tag(named name: String) -> NLTagCatalog.Tag? {
        tags.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    func group(named name: String?) -> NLTagGroups.Group? {
        guard let name else { return nil }
        return groups.first { $0.name == name }
    }
}

// MARK: - 所有标签

struct AllTagsPage: View {
    let onClose: () -> Void

    @Environment(AppState.self) private var app
    @State private var catalog = TagCatalogStore.shared
    @State private var filter = ""
    @State private var grouped = true
    @State private var sort: Sort = .topics

    private enum Sort { case topics, name }

    private var visibleTags: [NLTagCatalog.Tag] {
        let term = filter.trimmingCharacters(in: .whitespaces).lowercased()
        let matching = term.isEmpty ? catalog.tags : catalog.tags.filter {
            $0.name.lowercased().contains(term) || ($0.description ?? "").lowercased().contains(term)
        }
        switch sort {
        case .topics: return matching.sorted { ($0.topicCount ?? 0) > ($1.topicCount ?? 0) }
        case .name: return matching.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                controls
                    .padding(.top, 8)
                if !catalog.loaded && catalog.tags.isEmpty {
                    // String ids: integer ones would collide with tag ids in
                    // the lazy stack and leave skeletons standing in for tags.
                    ForEach(["s0", "s1", "s2", "s3"], id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 16).fill(Theme.chip).frame(height: 96).skeletonPulsing()
                    }
                } else if visibleTags.isEmpty {
                    Text(AppString("没有找到这个标签"))
                        .font(Theme.body(14))
                        .foregroundStyle(Theme.textMuted)
                        .padding(.vertical, 20)
                } else if grouped && filter.isEmpty {
                    groupedList
                } else {
                    flatGrid(visibleTags)
                }
                // What the removed subtitle said, kept quietly at the end.
                if catalog.loaded {
                    Text(AppString("共 \(catalog.tags.count) 个标签，分 \(catalog.groups.count) 个标签组 · 标签帮你在节点之外按话题找帖子"))
                        .font(Theme.body(12))
                        .foregroundStyle(Theme.textMuted)
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                        .padding(.top, 12)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.bg)
        .searchable(text: $filter, placement: .navigationBarDrawer(displayMode: .automatic), prompt: AppString("筛选标签"))
        .navigationTitle(AppString("所有标签"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .task { if !catalog.loaded { await catalog.load() } }
        .refreshable { await catalog.load() }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Picker(AppString("排列"), selection: $grouped) {
                    Text(AppString("按标签组")).tag(true)
                    Text(AppString("平铺")).tag(false)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 200)
                Spacer(minLength: 0)
                Menu {
                    Picker(AppString("排序"), selection: $sort) {
                        Text(AppString("主题最多")).tag(Sort.topics)
                        Text(AppString("按名称")).tag(Sort.name)
                    }
                } label: {
                    Label(sort == .topics ? AppString("主题最多") : AppString("按名称"), systemImage: "arrow.up.arrow.down")
                        .font(Theme.body(14, weight: .semibold))
                        .foregroundStyle(Theme.text)
                }
            }
        }
    }

    @ViewBuilder
    private var groupedList: some View {
        let tags = visibleTags
        ForEach(catalog.groups) { group in
            let members = tags.filter { $0.group == group.name }
            if !members.isEmpty {
                groupHeader(group, count: members.count)
                ForEach(members) { tag in tagCard(tag) }
            }
        }
        let loose = tags.filter { tag in tag.group == nil || catalog.group(named: tag.group) == nil }
        if !loose.isEmpty {
            HStack(spacing: 8) {
                Text(AppString("其他标签"))
                    .font(Theme.body(18, weight: .bold))
                Text(AppString("\(loose.count) 个标签"))
                    .font(Theme.body(13))
                    .foregroundStyle(Theme.textMuted)
            }
            .padding(.top, 8)
            flatGrid(loose)
        }
    }

    private func groupHeader(_ group: NLTagGroups.Group, count: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(group.name)
                    .font(Theme.body(18, weight: .bold))
                    .foregroundStyle(Theme.text)
                Text(AppString("\(count) 个标签"))
                    .font(Theme.body(13))
                    .foregroundStyle(Theme.textMuted)
                if group.exclusive == true {
                    Text(AppString("每帖限选一个"))
                        .font(Theme.body(12, weight: .bold))
                        .foregroundStyle(AdminTone.amber.text)
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                        .background(AdminTone.amber.fill, in: Capsule())
                }
            }
            if let description = group.description, !description.isEmpty {
                Text(description)
                    .font(Theme.body(13))
                    .foregroundStyle(Theme.textMuted)
            }
        }
        .padding(.top, 8)
    }

    private func tagCard(_ tag: NLTagCatalog.Tag) -> some View {
        Button {
            app.pushPage(.tag(tag.name))
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    TagLookChip(name: tag.name, size: .filter)
                    Spacer(minLength: 6)
                    Text(AppString("\(tag.topicCount ?? 0) 个主题"))
                        .font(Theme.body(13))
                        .foregroundStyle(Theme.textMuted)
                }
                if let description = tag.description, !description.isEmpty {
                    Text(description)
                        .font(Theme.body(14))
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if tag.staffOnly == true {
                    Text(AppString("仅管理员可用"))
                        .font(Theme.body(12, weight: .bold))
                        .foregroundStyle(AdminTone.amber.text)
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                        .background(AdminTone.amber.fill, in: Capsule())
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.bg, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.divider, lineWidth: 1))
        }
        .buttonStyle(.pressable)
    }

    private func flatGrid(_ tags: [NLTagCatalog.Tag]) -> some View {
        FlowLayout(spacing: 8) {
            ForEach(tags) { tag in
                Button { app.pushPage(.tag(tag.name)) } label: {
                    HStack(spacing: 6) {
                        TagLookChip(name: tag.name, size: .filter)
                        Text("\(tag.topicCount ?? 0)")
                            .font(Theme.body(12))
                            .foregroundStyle(Theme.textMuted)
                            .monospacedDigit()
                    }
                }
                .buttonStyle(.pressable)
            }
        }
    }
}

// MARK: - One tag

struct TagPage: View {
    let name: String
    let onClose: () -> Void

    @Environment(AppState.self) private var app
    @State private var catalog = TagCatalogStore.shared
    @State private var store = TagTopicsStore()

    private var tag: NLTagCatalog.Tag? { catalog.tag(named: name) }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                Divider().overlay(Theme.divider)

                if store.isLoading && store.visiblePosts.isEmpty {
                    ForEach(["s0", "s1", "s2", "s3"], id: \.self) { _ in FeedTopicRowSkeleton() }
                } else if store.visiblePosts.isEmpty {
                    EmptyStateView(
                        icon: store.errorText == nil ? "number" : "wifi.exclamationmark",
                        message: store.errorText ?? AppString("这个标签下还没有主题")
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
                } else {
                    ForEach(store.visiblePosts) { post in
                        TagTopicRow(post: post)
                            .contentShape(Rectangle())
                            .onTapGesture { app.openPostPage(post) }
                        Divider().overlay(Theme.divider).padding(.leading, 16)
                    }
                    if store.hasMore {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 20)
                            .onScrollVisibilityChange(threshold: 0.1) { visible in
                                guard visible else { return }
                                Task { await store.loadMore() }
                            }
                    }
                }
            }
            .padding(.bottom, 24)
        }
        .background(Theme.bg)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .task {
            async let topics: Void = store.loadIfNeeded(slug: name)
            if !catalog.loaded { await catalog.load() }
            await topics
        }
        .refreshable { await store.load(slug: name) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                app.pushPage(.tags)
            } label: {
                Label(AppString("所有标签"), systemImage: "chevron.left")
                    .font(Theme.body(14, weight: .semibold))
                    .foregroundStyle(Theme.textMuted)
            }
            .buttonStyle(.plain)

            HStack(alignment: .top, spacing: 12) {
                TagLookChip(name: name, size: .filter)
                    .scaleEffect(1.25, anchor: .leading)
                    .frame(height: 40, alignment: .leading)
                Spacer(minLength: 0)
            }
            if let group = tag?.group {
                Text(AppString("标签组 · \(group)"))
                    .font(Theme.body(12, weight: .semibold))
                    .foregroundStyle(Theme.textMuted)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .overlay(Capsule().strokeBorder(Theme.divider, lineWidth: 1))
            }
            Text("#\(name)")
                .font(Theme.body(26, weight: .bold))
                .foregroundStyle(Theme.text)
            if let description = tag?.description, !description.isEmpty {
                Text(description)
                    .font(Theme.body(15))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let count = tag?.topicCount {
                Text(AppString("\(count) 个主题"))
                    .font(Theme.body(14, weight: .bold))
                    .foregroundStyle(Theme.text)
            }
        }
        .padding(.top, 8)
    }
}

/// One topic under a tag: a status mark (✓ when solved), the title, then
/// 已解决, n/node, u/author and time, and the reply count at the right.
private struct TagTopicRow: View {
    let post: Post

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: post.isSolved ? "checkmark" : "text.bubble")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(post.isSolved ? Theme.accent : Theme.textMuted)
                .frame(width: 30, height: 30)
                .background(post.isSolved ? Theme.accent.opacity(0.12) : Theme.chip, in: Circle())
            VStack(alignment: .leading, spacing: 6) {
                Text(post.title)
                    .font(Theme.body(16, weight: .bold))
                    .foregroundStyle(post.isRead ? Theme.textMuted : Theme.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 6) {
                    if post.isSolved {
                        Text(AppString("已解决"))
                            .font(Theme.body(12, weight: .bold))
                            .foregroundStyle(Theme.accent)
                            .padding(.horizontal, 7)
                            .frame(height: 20)
                            .background(Theme.accent.opacity(0.12), in: Capsule())
                    }
                    Text(post.node)
                        .font(Theme.body(12, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    if let author = post.authorUsername {
                        Text("u/\(author)")
                            .font(Theme.body(12))
                            .foregroundStyle(Theme.textMuted)
                    }
                    Text(post.time)
                        .font(Theme.body(12))
                        .foregroundStyle(Theme.textMuted)
                }
                .lineLimit(1)
            }
            Spacer(minLength: 6)
            Label("\(post.comments)", systemImage: "bubble.left")
                .labelStyle(CompactLabelStyle())
                .font(Theme.body(13, weight: .bold))
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(Theme.chip, in: Capsule())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}
