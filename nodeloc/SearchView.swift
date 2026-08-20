//
//  SearchView.swift
//  nodeloc
//

import SwiftUI

private enum SearchScope: String, CaseIterable {
    case all = "全部"
    case nodes = "节点"
    case posts = "帖子"
    case users = "用户"
    case apps = "应用"
    case media = "媒体"
}

struct SearchView: View {
    let postTransitionNamespace: Namespace.ID

    var body: some View {
        SearchExperience(
            postTransitionNamespace: postTransitionNamespace,
            mode: .screen
        )
    }
}

struct SearchOverlay: View {
    let postTransitionNamespace: Namespace.ID

    var body: some View {
        SearchExperience(
            postTransitionNamespace: postTransitionNamespace,
            mode: .overlay
        )
    }
}

private enum SearchExperienceMode {
    case screen
    case overlay
}

private struct SearchExperience: View {
    @Environment(AppState.self) private var app
    let postTransitionNamespace: Namespace.ID
    let mode: SearchExperienceMode

    @State private var store = SearchStore()
    @State private var query = ""
    @State private var selectedScope: SearchScope = .all
    @FocusState private var searchFocused: Bool
    @Namespace private var scopeSelectionNamespace

    private var isOverlay: Bool { mode == .overlay }
    private var isSearching: Bool {
        query.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            backdrop

            searchContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.bottom, isOverlay ? 0 : 12)

            if isOverlay {
                telegramSearchControls
            }

            if !isOverlay {
                screenSearchHeader
                    .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .task { await store.loadCategories() }
        .onAppear {
            guard isOverlay else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                searchFocused = true
            }
        }
        .onChange(of: query) { _, newValue in
            Task { await store.search(newValue) }
        }
    }

    @ViewBuilder
    private var backdrop: some View {
        if isOverlay {
            Theme.bg
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { dismissOverlay() }
        } else {
            Theme.bg
                .ignoresSafeArea()
        }
    }

    private var searchContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Color.clear
                    .frame(height: isOverlay ? 26 : 118)

                if isSearching {
                    resultsSection
                } else {
                    redditSuggestions
                }
            }
            .padding(.bottom, isOverlay ? 130 : 14)
        }
        .scrollIndicators(.hidden)
    }

    private var redditSuggestions: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(title: "最近", trailing: "历史记录")
                .padding(.bottom, 12)

            VStack(spacing: 0) {
                RedditSearchRow(
                    icon: "clock",
                    title: "nodeloc",
                    subtitle: nil,
                    badge: nil,
                    trailingIcon: "xmark"
                )

                RedditSearchRow(
                    icon: nil,
                    title: "r/PhotoshopRequest",
                    subtitle: nil,
                    badge: "Paid  $",
                    trailingIcon: "xmark",
                    avatarText: "PsR",
                    avatarTint: Color(hex: 0x0B5AA8)
                )
            }
            .padding(.bottom, 24)

            sectionHeader(title: "热门", trailing: nil)
                .padding(.bottom, 12)

            VStack(spacing: 0) {
                ForEach(Self.hotSearches, id: \.self) { title in
                    RedditSearchRow(
                        icon: "arrow.up.right",
                        title: title,
                        subtitle: "根据你的兴趣",
                        badge: nil,
                        trailingIcon: nil
                    )
                }
            }
        }
        .padding(.horizontal, 20)
    }

    private var resultsSection: some View {
        VStack(spacing: 8) {
            if store.isSearching {
                ProgressView()
                    .tint(Theme.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 24)
            }

            ForEach(store.results) { post in
                PostCard(post: post, postTransitionNamespace: postTransitionNamespace)
            }

            if !store.isSearching && store.results.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 30, weight: .medium))
                        .foregroundStyle(Theme.muted(0.34))
                    Text("没有找到相关内容")
                        .font(Theme.body(14, weight: .medium))
                        .foregroundStyle(Theme.muted(0.58))
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 54)
            }
        }
        .padding(.horizontal, 16)
    }

    private var telegramSearchControls: some View {
        VStack(spacing: 10) {
            scopeBar

            HStack(spacing: 9) {
                searchField

                Button {
                    dismissOverlay()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .frame(width: 50, height: 50)
                        .glassEffect(.regular.interactive(), in: Circle())
                }
                .buttonStyle(.plain)
                .shadow(color: .black.opacity(0.08), radius: 12, y: 7)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    private var scopeBar: some View {
        GlassEffectContainer(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 4) {
                        ForEach(SearchScope.allCases, id: \.self) { scope in
                            Button {
                                withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                                    selectedScope = scope
                                    proxy.scrollTo(scope, anchor: .center)
                                }
                            } label: {
                                Text(scope.rawValue)
                                    .font(Theme.body(14, weight: .semibold))
                                    .foregroundStyle(selectedScope == scope ? Theme.text : Theme.text.opacity(0.84))
                                    .padding(.horizontal, 15)
                                    .frame(height: 38)
                                    .background {
                                        if selectedScope == scope {
                                            Capsule()
                                                .fill(Theme.neutral400.opacity(0.62))
                                                .matchedGeometryEffect(id: "scope-selection", in: scopeSelectionNamespace)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                            .id(scope)
                        }
                    }
                    .padding(3)
                }
                .scrollIndicators(.hidden)
                .onAppear {
                    proxy.scrollTo(selectedScope, anchor: .center)
                }
                .onChange(of: selectedScope) { _, newValue in
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                        proxy.scrollTo(newValue, anchor: .center)
                    }
                }
            }
            .glassEffect(.regular, in: Capsule())
        }
        .shadow(color: .black.opacity(0.08), radius: 12, y: 7)
    }

    private var searchField: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Theme.muted(0.45))

            TextField("搜索", text: $query)
                .font(Theme.heading(19, weight: .regular))
                .foregroundStyle(Theme.text)
                .textFieldStyle(.plain)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($searchFocused)

            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.muted(0.35))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 15)
        .frame(height: 50)
        .glassEffect(.regular.interactive(), in: Capsule())
        .shadow(color: .black.opacity(0.08), radius: 12, y: 7)
    }

    private var screenSearchHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("搜索")
                .font(Theme.heading(25, weight: .semibold))
                .foregroundStyle(Theme.text)

            searchField
                .focused($searchFocused)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 14)
        .background(Theme.bg)
    }

    private func sectionHeader(title: String, trailing: String?) -> some View {
        HStack {
            Text(title)
                .font(Theme.body(14, weight: .semibold))
                .foregroundStyle(Theme.muted(0.58))

            Spacer()

            if let trailing {
                Button {} label: {
                    HStack(spacing: 5) {
                        Text(trailing)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .bold))
                    }
                    .font(Theme.body(14, weight: .semibold))
                    .foregroundStyle(Theme.muted(0.58))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func dismissOverlay() {
        guard isOverlay else { return }
        searchFocused = false
        withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
            app.overlay = nil
        }
    }

    private static let hotSearches = [
        "GitHub Outage",
        "WNBA Highlights",
        "Fairphone Gen 6+ US Launch",
        "August 2026 Visa Bulletin"
    ]
}

private struct RedditSearchRow: View {
    let icon: String?
    let title: String
    let subtitle: String?
    let badge: String?
    let trailingIcon: String?
    var avatarText: String?
    var avatarTint: Color = Theme.accent

    var body: some View {
        HStack(spacing: 15) {
            leadingIcon

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text(title)
                        .font(Theme.heading(18, weight: .regular))
                        .foregroundStyle(Theme.text.opacity(0.92))
                        .lineLimit(1)

                    if let badge {
                        Text(badge)
                            .font(Theme.body(12, weight: .bold))
                            .foregroundStyle(Color(hex: 0x9A4E05))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color(hex: 0xFFF2D8), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(Color(hex: 0xA85C0D), lineWidth: 1)
                            }
                    }
                }

                if let subtitle {
                    Text(subtitle)
                        .font(Theme.body(13, weight: .regular))
                        .foregroundStyle(Theme.muted(0.58))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            if let trailingIcon {
                Image(systemName: trailingIcon)
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(Theme.muted(0.58))
                    .frame(width: 28, height: 28)
            }
        }
        .frame(minHeight: 50)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var leadingIcon: some View {
        if let avatarText {
            Text(avatarText)
                .font(Theme.body(11, weight: .black))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(avatarTint, in: Circle())
        } else if let icon {
            Image(systemName: icon)
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(Theme.text.opacity(0.82))
                .frame(width: 32, height: 32)
        } else {
            Color.clear
                .frame(width: 32, height: 32)
        }
    }
}
