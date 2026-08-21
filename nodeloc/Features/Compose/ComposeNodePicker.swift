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
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                LazyVStack(spacing: 0) {
                    if store.isLoadingCommunities && store.nodeOptions.isEmpty {
                        loadingRow
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
    }

    private var header: some View {
        ZStack {
            Text("发布至")
                .font(Theme.heading(17, weight: .semibold))
                .foregroundStyle(Theme.text)

            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 20, weight: .regular))
                        .foregroundStyle(Theme.text)
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)

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
                        .foregroundStyle(Theme.muted(0.6))
                        .lineLimit(1)

                    if !node.description.isEmpty {
                        Text(node.description)
                            .font(Theme.body(12))
                            .foregroundStyle(Theme.muted(0.62))
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
        .buttonStyle(.plain)
    }

    private func subtitle(for option: ComposeNodeOption) -> String {
        let members = option.node.memberCount.isEmpty ? "" : "\(option.node.memberCount) 成员"
        return [members, option.reasonText]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    private var filteredOptions: [ComposeNodeOption] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return store.nodeOptions }
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
                .foregroundStyle(Theme.muted(0.56))
            TextField("搜索节点", text: $query)
                .font(Theme.body(15))
                .foregroundStyle(Theme.text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.muted(0.4))
                }
                .buttonStyle(.plain)
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
                .foregroundStyle(Theme.muted(0.58))
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
        .foregroundStyle(Theme.muted(0.54))
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}
