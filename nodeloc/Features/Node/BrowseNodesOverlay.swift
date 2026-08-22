//
//  BrowseNodesOverlay.swift
//  nodeloc
//
//  The node directory, searchable and grouped.
//

import SwiftUI

// MARK: - Browse nodes

struct BrowseNodesOverlay: View {
    @Environment(AppState.self) private var app
    @Environment(\.openURL) private var openURL
    @State private var store = NodeBrowseStore()
    @State private var query = ""
    @State private var showsSearch = false
    @State private var showsGroupList = false
    @State private var selectedNode: SidebarNodeSummary?
    @State private var skeletonPulse = false
    let showsCloseButton: Bool
    private let headerIconFrame: CGFloat = 34
    private let headerContentHeight: CGFloat = 56

    init(showsCloseButton: Bool = true) {
        self.showsCloseButton = showsCloseButton
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .top) {
                ScrollView {
                    VStack(spacing: 0) {
                        Color.clear
                            .frame(maxWidth: .infinity)
                            .frame(height: headerContentHeight)

                        if showsGroupList {
                            groupListContent
                        } else if !store.hasContent && store.isLoading {
                            nodeSkeleton
                                .padding(.top, 18)
                                .padding(.bottom, 110)
                        } else {
                            VStack(alignment: .leading, spacing: 28) {
                                topicChipsSection

                                categoryPreviewSections

                                if let errorText = store.errorText {
                                    Text(errorText)
                                        .font(Theme.body(13, weight: .medium))
                                        .foregroundStyle(Theme.danger)
                                        .padding(.horizontal, 16)
                                }
                            }
                            .padding(.top, 18)
                            .padding(.bottom, 110)
                        }
                    }
                }
                .scrollIndicators(.hidden)

                browseHeader()
                    .zIndex(1)

                if let selectedNode {
                    NodeDetailOverlay(node: selectedNode) {
                        withAnimation(.overlayPush) {
                            self.selectedNode = nil
                        }
                    }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                    .zIndex(20)
                }
            }
            .background(Theme.bg.ignoresSafeArea())
        }
        .task { await store.load() }
    }

    private func browseHeader() -> some View {
        ZStack {
            Text(headerTitle)
                .font(Theme.heading(20, weight: .semibold))
                .foregroundStyle(Theme.text)

            HStack {
                if showsCloseButton || showsGroupList {
                    Button { handleBack() } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Theme.text)
                            .frame(width: headerIconFrame, height: headerIconFrame)
                    }
                    .buttonStyle(.glass(.regular.tint(Theme.bg.opacity(0.34))))
                    .buttonBorderShape(.circle)
                    .shadow(color: .black.opacity(0.08), radius: 9, y: 6)
                } else {
                    // Root of the nodes tab: no back destination, so the slot
                    // holds the sidebar toggle like the home feed does.
                    SidebarMenuButton()
                }

                Spacer()

                Button {
                    withAnimation(.overlayPush) {
                        app.overlay = .createNode
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .frame(width: headerIconFrame, height: headerIconFrame)
                }
                .buttonStyle(.glass(.regular.tint(Theme.bg.opacity(0.34))))
                .buttonBorderShape(.circle)
                .shadow(color: .black.opacity(0.08), radius: 9, y: 6)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .background {
            Rectangle()
                .fill(Theme.bg.opacity(0.3))
                .ignoresSafeArea(edges: .top)
        }
    }

    private var headerTitle: String {
        showsGroupList ? (store.selectedGroup?.name ?? "节点") : "节点"
    }

    private func handleBack() {
        if showsGroupList {
            withAnimation(.quick) {
                showsGroupList = false
            }
        } else {
            closeOverlay(app)
        }
    }

    private var topicChipsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("按主题浏览节点")
                .font(Theme.heading(17, weight: .semibold))
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 16)

            ScrollView(.horizontal) {
                LazyHGrid(
                    rows: Array(repeating: GridItem(.fixed(36), spacing: 11), count: 3),
                    alignment: .top,
                    spacing: 10
                ) {
                    if store.groups.isEmpty {
                        ForEach(fallbackTopicLabels, id: \.self) { label in
                            topicChip(title: label, isSelected: false) {}
                                .disabled(true)
                        }
                    } else {
                        ForEach(store.groups) { group in
                            topicChip(title: group.name, isSelected: store.selectedGroup?.id == group.id) {
                                openGroup(group)
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
            .scrollIndicators(.hidden)
            .frame(height: 130)
        }
    }

    private var groupListContent: some View {
        VStack(spacing: 10) {
            if store.isLoadingGroup {
                loadingRow("正在加载 \(store.selectedGroup?.name ?? "节点")")
            }

            ForEach(Array(store.groupNodes.enumerated()), id: \.element.id) { index, node in
                rankedCommunityCard(node, rank: index + 1)
            }

            if !store.isLoadingGroup && store.groupNodes.isEmpty {
                emptyRow("这里还没有可浏览的节点", icon: "tray")
                    .padding(.horizontal, 16)
            }

            if let errorText = store.errorText {
                Text(errorText)
                    .font(Theme.body(13, weight: .medium))
                    .foregroundStyle(Theme.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
            }
        }
        .padding(.top, 18)
        .padding(.bottom, 110)
    }

    @ViewBuilder
    private var categoryPreviewSections: some View {
        if previewGroups.isEmpty {
            recommendedSection
        } else {
            VStack(alignment: .leading, spacing: 28) {
                ForEach(previewGroups) { group in
                    categoryPreviewSection(group)
                }
            }
        }
    }

    private var previewGroups: [NodeGroupSummary] {
        Array(store.groups.prefix(6))
    }

    private func categoryPreviewSection(_ group: NodeGroupSummary) -> some View {
        let nodes = store.previewNodes(for: group)

        return VStack(alignment: .leading, spacing: 14) {
            Button {
                openGroup(group)
            } label: {
                HStack {
                    Text(group.name)
                        .font(Theme.heading(20, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Spacer()
                    Text("更多")
                        .font(Theme.body(13, weight: .semibold))
                        .foregroundStyle(Theme.muted(0.58))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Theme.text)
                }
                .padding(.horizontal, 16)
            }
            .buttonStyle(.plain)

            if nodes.isEmpty, store.isLoading {
                loadingRow("正在加载 \(group.name)")
            } else if nodes.isEmpty {
                emptyRow("暂无节点", icon: "tray")
                    .padding(.horizontal, 16)
            } else {
                horizontalCommunityCards(nodes: nodes)
            }
        }
    }

    private var recommendedSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("为你推荐")
                .font(Theme.heading(17, weight: .semibold))
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 16)

            horizontalCommunityCards(nodes: Array(store.recommended.prefix(8)))
        }
    }

    @ViewBuilder
    private var relatedSection: some View {
        let nodes = relatedNodes
        if !nodes.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(relatedTitle)
                        .font(Theme.heading(20, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(Theme.text)
                }
                .padding(.horizontal, 16)

                horizontalCommunityCards(nodes: nodes)
            }
        }
    }

    private var searchResultsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("搜索结果")
                .font(Theme.heading(20, weight: .semibold))
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 16)

            VStack(spacing: 10) {
                ForEach(searchResults) { node in
                    wideCommunityCard(node)
                }
                if searchResults.isEmpty {
                    emptyRow("没有匹配的节点", icon: "magnifyingglass")
                        .padding(.horizontal, 16)
                }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.muted(0.56))
            TextField("搜索节点", text: $query)
                .font(Theme.body(16))
                .foregroundStyle(Theme.text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.muted(0.4))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .glassBackground(in: Capsule(), tint: Theme.bg.opacity(0.36))
        .padding(.horizontal, 16)
    }

    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var searchResults: [SidebarNodeSummary] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return [] }
        let previewNodes = store.groupPreviews.values.flatMap { $0 }
        let allNodes = store.recommended + store.groupNodes + previewNodes
        var seen = Set<Int>()
        return allNodes.filter { node in
            guard seen.insert(node.id).inserted else { return false }
            return node.name.localizedCaseInsensitiveContains(term)
                || node.slug.localizedCaseInsensitiveContains(term)
                || node.description.localizedCaseInsensitiveContains(term)
        }
    }

    private var relatedNodes: [SidebarNodeSummary] {
        if !store.groupNodes.isEmpty { return Array(store.groupNodes.prefix(8)) }
        return Array(store.recommended.dropFirst(2).prefix(6))
    }

    private var relatedTitle: String {
        if let selectedGroup = store.selectedGroup {
            return "更多 \(selectedGroup.name) 类似内容"
        }
        return "更多类似内容"
    }

    private func openGroup(_ group: NodeGroupSummary) {
        withAnimation(.quick) {
            showsGroupList = true
        }
        Task { await store.loadGroup(group) }
    }

    private var fallbackTopicLabels: [String] {
        [
            "互联网文化", "游戏", "问答与故事", "影视", "科技", "食物",
            "胜地与旅行", "流行文化", "体育", "商业与金融", "人文与艺术",
            "教育与职业", "时尚与美容", "新闻与政治", "交通工具"
        ]
    }

    private func topicChip(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Theme.body(13, weight: .medium))
                .foregroundStyle(isSelected ? Theme.bg : Theme.text)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(height: 32)
                .background(isSelected ? Theme.text : Theme.bg, in: Capsule())
                .overlay {
                    Capsule()
                        .strokeBorder(isSelected ? Theme.text.opacity(0.18) : Theme.divider, lineWidth: 1.2)
                }
        }
        .buttonStyle(.plain)
    }

    private func horizontalCommunityCards(nodes: [SidebarNodeSummary]) -> some View {
        GeometryReader { proxy in
            let cardWidth = max(286, min(360, proxy.size.width - 70))

            ScrollView(.horizontal) {
                LazyHStack(spacing: 14) {
                    ForEach(nodePairs(from: nodes)) { pair in
                        communityCard(pair, width: cardWidth)
                    }
                }
                .padding(.horizontal, 16)
            }
            .scrollIndicators(.hidden)
        }
        .frame(height: 272)
    }

    private func nodePairs(from nodes: [SidebarNodeSummary]) -> [NodeCardPair] {
        stride(from: 0, to: nodes.count, by: 2).map { index in
            NodeCardPair(
                first: nodes[index],
                second: index + 1 < nodes.count ? nodes[index + 1] : nil
            )
        }
    }

    private func communityCard(_ pair: NodeCardPair, width: CGFloat) -> some View {
        VStack(spacing: 14) {
            compactCommunityCard(pair.first, width: width)
            if let second = pair.second {
                compactCommunityCard(second, width: width)
            } else {
                Spacer(minLength: 0)
                    .frame(height: 120)
            }
        }
        .frame(width: width, height: 254, alignment: .top)
    }

    private func compactCommunityCard(_ node: SidebarNodeSummary, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                NodeSummaryIcon(node: node, size: 44, cornerRadius: 22)

                VStack(alignment: .leading, spacing: 4) {
                    Text(displayName(for: node))
                        .font(Theme.heading(15, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Text(memberText(for: node))
                        .font(Theme.body(12, weight: .medium))
                        .foregroundStyle(Theme.muted(0.62))
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                joinButton(for: node)
            }

            Text(node.description)
                .font(Theme.body(12))
                .foregroundStyle(Theme.muted(0.62))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .frame(width: width, height: 120, alignment: .top)
        .background(Theme.bg, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Theme.divider, lineWidth: 1.2)
        }
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onTapGesture { openNode(node) }
    }

    private func wideCommunityCard(_ node: SidebarNodeSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                NodeSummaryIcon(node: node, size: 44, cornerRadius: 22)

                VStack(alignment: .leading, spacing: 4) {
                    Text(displayName(for: node))
                        .font(Theme.heading(15, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Text(memberText(for: node))
                        .font(Theme.body(12, weight: .medium))
                        .foregroundStyle(Theme.muted(0.62))
                        .lineLimit(1)
                }

                Spacer(minLength: 8)
                joinButton(for: node)
            }

            Text(node.description)
                .font(Theme.body(12))
                .foregroundStyle(Theme.muted(0.62))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.bg, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Theme.divider, lineWidth: 1.2)
        }
        .padding(.horizontal, 16)
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onTapGesture { openNode(node) }
    }

    private func rankedCommunityCard(_ node: SidebarNodeSummary, rank: Int) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(rank)")
                .font(Theme.body(15, weight: .semibold))
                .foregroundStyle(Theme.muted(0.62))
                .monospacedDigit()
                .frame(width: 34, height: 44, alignment: .center)

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 12) {
                    NodeSummaryIcon(node: node, size: 44, cornerRadius: 22)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(displayName(for: node))
                            .font(Theme.heading(15, weight: .semibold))
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                        Text(memberText(for: node))
                            .font(Theme.body(12, weight: .medium))
                            .foregroundStyle(Theme.muted(0.62))
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)

                    joinButton(for: node)
                }

                Text(node.description)
                    .font(Theme.body(12))
                    .foregroundStyle(Theme.muted(0.62))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Theme.bg, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Theme.divider, lineWidth: 1.2)
        }
        .padding(.horizontal, 16)
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onTapGesture { openNode(node) }
    }

    /// 加入 is a filled call to action; 已加入 is a quiet outline. Same shape,
    /// different weight — the joined state is a status, not an invitation to
    /// tap again.
    private func joinButton(for node: SidebarNodeSummary) -> some View {
        Button {
            openNode(node)
        } label: {
            Text(node.isJoined ? "已加入" : "加入")
                .font(Theme.body(12, weight: .semibold))
                .foregroundStyle(node.isJoined ? Theme.muted(0.62) : Theme.bg)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(node.isJoined ? Theme.surface : Theme.text, in: Capsule())
                .overlay {
                    if node.isJoined {
                        Capsule().strokeBorder(Theme.divider, lineWidth: 1)
                    }
                }
        }
        .buttonStyle(.plain)
    }

    private func memberText(for node: SidebarNodeSummary) -> String {
        node.memberCount.isEmpty ? "成员" : "\(node.memberCount) 成员"
    }

    private func displayName(for node: SidebarNodeSummary) -> String {
        node.name.isEmpty ? node.slug : node.name
    }

    // MARK: Skeleton

    /// Placeholder blocks shown only on a cold first load (no cache yet).
    private var nodeSkeleton: some View {
        VStack(alignment: .leading, spacing: 28) {
            // Topic chips row.
            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    ForEach(0..<6, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Theme.neutral300)
                            .frame(width: 96, height: 32)
                    }
                }
                .padding(.horizontal, 16)
            }
            .scrollIndicators(.hidden)
            .disabled(true)

            ForEach(0..<3, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 14) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Theme.neutral300)
                        .frame(width: 150, height: 22)
                        .padding(.horizontal, 16)

                    ScrollView(.horizontal) {
                        HStack(spacing: 14) {
                            ForEach(0..<3, id: \.self) { _ in skeletonCard }
                        }
                        .padding(.horizontal, 16)
                    }
                    .scrollIndicators(.hidden)
                    .disabled(true)
                }
            }
        }
        .opacity(skeletonPulse ? 0.55 : 1)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                skeletonPulse = true
            }
        }
    }

    private var skeletonCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Circle().fill(Theme.neutral300).frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 6) {
                    RoundedRectangle(cornerRadius: 4).fill(Theme.neutral300).frame(width: 120, height: 14)
                    RoundedRectangle(cornerRadius: 4).fill(Theme.neutral300).frame(width: 74, height: 12)
                }
                Spacer(minLength: 0)
            }
            RoundedRectangle(cornerRadius: 4).fill(Theme.neutral300).frame(height: 12)
            RoundedRectangle(cornerRadius: 4).fill(Theme.neutral300).frame(width: 190, height: 12)
        }
        .padding(14)
        .frame(width: 300, height: 120, alignment: .top)
        .background(Theme.bg, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Theme.divider, lineWidth: 1.2)
        }
    }

    private func loadingRow(_ text: String) -> some View {
        HStack(spacing: 10) {
            ProgressView()
                .tint(Theme.accent)
            Text(text)
                .font(Theme.body(15, weight: .medium))
                .foregroundStyle(Theme.muted(0.58))
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func emptyRow(_ text: String, icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
            Text(text)
                .font(Theme.body(13))
            Spacer()
        }
        .foregroundStyle(Theme.muted(0.54))
        .padding(.vertical, 12)
    }

    private func openNode(_ node: SidebarNodeSummary) {
        withAnimation(.panelSlide) {
            selectedNode = node
        }
    }
}
