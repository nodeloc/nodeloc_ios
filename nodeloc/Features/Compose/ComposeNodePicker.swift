//
//  ComposeNodePicker.swift
//  nodeloc
//
//  Node chooser presented from the composer.
//

import SwiftUI

// MARK: - Compose node picker

/// Full-page node chooser for the composer, mirroring the web plugin's picker:
/// recently posted-to nodes first, then joined nodes, then the rest.
/// Internal rather than private: the composer presents it from its own file.
struct ComposeNodePicker: View {
    @Environment(\.dismiss) private var dismiss
    let store: ComposeStore
    @Binding var selection: SidebarNodeSummary?
    /// 发布至 for the composer; the move form says 移到.
    var title: String = AppString("发布至")
    @State private var query = ""
    /// 常去节点 (the nodes of your latest posts, busiest first — the same
    /// source as the profile's), lower-cased slugs.
    @State private var frequentSlugs: [String] = []

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                LazyVStack(spacing: 0) {
                    if store.isLoadingCommunities && store.nodeOptions.isEmpty {
                        loadingRow
                    }

                    if showsDefaultHeader {
                        Text(AppString("常用节点 · 搜索可找到全部节点"))
                            .font(Theme.body(12, weight: .semibold))
                            .foregroundStyle(Theme.textMuted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.top, 12)
                            .padding(.bottom, 2)
                    }
                    ForEach(filteredOptions) { option in
                        nodeRow(option)
                    }

                    if !store.isLoadingCommunities && filteredOptions.isEmpty {
                        emptyRow
                    }
                }
                .padding(.bottom, 96)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
        }
        .background(Theme.bg.ignoresSafeArea())
        .safeAreaInset(edge: .bottom, spacing: 0) {
            searchField
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
        }
        .task { await store.loadCommunities() }
        .task { await loadFrequent() }
    }

    private func loadFrequent() async {
        guard let me = DiscourseAuth.shared.username,
              let nodes = try? await DiscourseClient().userFrequentNodes(username: me) else { return }
        frequentSlugs = nodes.map { $0.slug.lowercased() }
    }

    /// Shown before anything is typed: your frequent nodes, then the ones
    /// you've posted to recently or joined (all of them when that's short),
    /// with the current choice kept at the top. Typing searches every node.
    private var defaultOptions: [ComposeNodeOption] {
        let all = store.nodeOptions
        let bySlug = Dictionary(all.map { ($0.node.slug.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
        var picked: [ComposeNodeOption] = []
        var seen = Set<Int>()
        func add(_ option: ComposeNodeOption?) {
            guard let option, seen.insert(option.id).inserted else { return }
            picked.append(option)
        }
        if let selection { add(all.first { $0.id == selection.id }) }
        for slug in frequentSlugs { add(bySlug[slug]) }
        for option in all where option.reason != .none { add(option) }
        // Nothing to go on yet (a new account): the full list as before.
        return picked.count > (selection == nil ? 0 : 1) ? picked : all
    }

    private var showsDefaultHeader: Bool {
        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && defaultOptions.count < store.nodeOptions.count
    }

    private var header: some View {
        ZStack {
            Text(title)
                .font(Theme.heading(17, weight: .semibold))
                .foregroundStyle(Theme.text)

            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 20, weight: .regular))
                        .foregroundStyle(Theme.text)
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.pressable)

                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Theme.divider)
                .frame(height: 1)
        }
    }

    private func nodeRow(_ option: ComposeNodeOption) -> some View {
        let node = option.node

        return Button {
            selection = node
            dismiss()
        } label: {
            HStack(spacing: 12) {
                NodeSummaryIcon(node: node, size: 44, cornerRadius: 22)

                VStack(alignment: .leading, spacing: 3) {
                    Text("n/\(node.slug)")
                        .font(Theme.body(15, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)

                    Text(subtitle(for: option))
                        .font(Theme.body(12, weight: .medium))
                        .foregroundStyle(Theme.textMuted)
                        .lineLimit(1)

                    if !node.description.isEmpty {
                        Text(node.description)
                            .font(Theme.body(12))
                            .foregroundStyle(Theme.textMuted)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }

                Spacer(minLength: 8)

                if selection?.id == node.id {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Theme.accent)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
    }

    private func subtitle(for option: ComposeNodeOption) -> String {
        let members = option.node.memberCount.isEmpty ? "" : AppString("\(option.node.memberCount) 成员")
        return [members, option.reasonText]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    private var filteredOptions: [ComposeNodeOption] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return defaultOptions }
        return store.nodeOptions.filter { option in
            option.node.name.localizedCaseInsensitiveContains(term)
                || option.node.slug.localizedCaseInsensitiveContains(term)
                || option.node.description.localizedCaseInsensitiveContains(term)
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.textMuted)
            TextField(AppString("搜索全部节点"), text: $query)
                .font(Theme.body(15))
                .foregroundStyle(Theme.text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.textFaint)
                }
                .buttonStyle(.pressable)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .glassBackground(in: Capsule(), tint: Theme.bg.opacity(0.36))
    }

    private var loadingRow: some View {
        HStack(spacing: 10) {
            ProgressView().tint(Theme.accent)
            Text("正在加载节点")
                .font(Theme.body(14, weight: .medium))
                .foregroundStyle(Theme.textMuted)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var emptyRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .semibold))
            Text("没有匹配的节点")
                .font(Theme.body(13))
            Spacer()
        }
        .foregroundStyle(Theme.textMuted)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}
