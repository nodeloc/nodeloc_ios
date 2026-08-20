//
//  ProfileView.swift
//  nodeloc
//

import SwiftUI

struct ProfileView: View {
    @Environment(AppState.self) private var app
    @State private var store = ProfileStore()

    private let activityColumns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                profileHero
                statsSection
                badgesSection
                nodesSection
                activitySection
                accountSection
            }
            .padding(.bottom, 112)
        }
        .scrollIndicators(.hidden)
        .background(Theme.bg)
        .task(id: app.authed) { await store.load(isAppAuthed: app.authed) }
        .refreshable { await store.load(isAppAuthed: app.authed) }
    }

    private var profileHero: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                profileBanner
                    .frame(height: 176)

                profileTopBar
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
            }

            profileCard
                .padding(.horizontal, 16)
                .offset(y: -54)
                .padding(.bottom, -54)
        }
    }

    private var profileTopBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("我的")
                    .font(Theme.heading(28, weight: .bold))
                    .foregroundStyle(Theme.text)
                Text("NodeLoc")
                    .font(Theme.body(13, weight: .semibold))
                    .foregroundStyle(Theme.muted(0.58))
            }

            Spacer()

            Button {
                app.overlay = .settings
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .frame(width: 38, height: 38)
            }
            .buttonStyle(.glass(.regular.tint(Theme.bg.opacity(0.34))))
            .buttonBorderShape(.circle)
        }
    }

    @ViewBuilder
    private var profileBanner: some View {
        if let backgroundURL = store.backgroundURL {
            AsyncImage(url: backgroundURL) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                default:
                    profileBannerFallback
                }
            }
            .frame(maxWidth: .infinity)
            .clipped()
        } else {
            profileBannerFallback
        }
    }

    private var profileBannerFallback: some View {
        ZStack {
            Theme.surface
            HStack {
                Spacer()
                Image(systemName: "at")
                    .font(.system(size: 118, weight: .semibold))
                    .foregroundStyle(Theme.muted(0.08))
                    .rotationEffect(.degrees(-8))
                    .padding(.trailing, 20)
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Theme.divider)
                .frame(height: 1)
        }
    }

    private var profileCard: some View {
        VStack(spacing: 14) {
            RemoteAvatar(
                url: store.avatarURL,
                letter: store.initial,
                variant: abs(store.username.hashValue),
                size: 96
            )
            .overlay(Circle().strokeBorder(Theme.bg, lineWidth: 5))
            .shadow(color: .black.opacity(0.14), radius: 14, y: 8)
            .offset(y: -42)
            .padding(.bottom, -34)

            VStack(spacing: 4) {
                Text(store.displayName)
                    .font(Theme.heading(24, weight: .bold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)

                HStack(spacing: 6) {
                    Text("@\(store.username)")
                        .font(Theme.body(15, weight: .semibold))
                        .foregroundStyle(Theme.muted(0.62))

                    if !store.isGuest {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                    }
                }
            }

            HStack(spacing: 8) {
                profilePill(store.lastSeen, icon: "circle.fill", iconColor: store.isGuest ? Theme.muted(0.38) : Theme.accent)
                profilePill(store.joined, icon: "calendar")
            }

            if !store.roles.isEmpty {
                wrappingChips(store.roles) { role in
                    profileChip(role, color: roleColor(role))
                }
            }

            if let title = store.title, !title.isEmpty {
                Text(title)
                    .font(Theme.body(15, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !store.bio.isEmpty {
                Text(store.bio)
                    .font(Theme.body(14))
                    .foregroundStyle(Theme.text.opacity(0.78))
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }

            profileMeta

            HStack(spacing: 10) {
                primaryProfileAction
                secondaryProfileAction
            }
            .padding(.top, 2)

            if store.isLoading {
                ProgressView()
                    .tint(Theme.accent)
            } else if let errorText = store.errorText {
                Text(errorText)
                    .font(Theme.body(12))
                    .foregroundStyle(Theme.danger)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 18)
        .background(Theme.surface.opacity(0.94), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Theme.divider, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.08), radius: 18, y: 10)
    }

    private var primaryProfileAction: some View {
        Button {
            if store.isGuest {
                withAnimation(.easeInOut(duration: 0.2)) {
                    app.isGuest = false
                    app.authed = false
                }
            } else {
                app.overlay = .compose
            }
        } label: {
            Label(store.isGuest ? "登录" : "发帖", systemImage: store.isGuest ? "person.crop.circle.badge.checkmark" : "square.and.pencil")
                .font(Theme.body(16, weight: .semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 44)
        }
        .buttonStyle(.borderedProminent)
        .tint(Theme.accent)
    }

    private var secondaryProfileAction: some View {
        Button {
            app.tab = .chat
        } label: {
            Label("消息", systemImage: "bubble.left.fill")
                .font(Theme.body(16, weight: .semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 44)
        }
        .buttonStyle(.bordered)
        .tint(Theme.text)
    }

    @ViewBuilder
    private var profileMeta: some View {
        let items = profileMetaItems
        if !items.isEmpty {
            VStack(spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(spacing: 8) {
                        Image(systemName: item.icon)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 16)
                        Text(item.text)
                            .font(Theme.body(12, weight: .medium))
                            .foregroundStyle(Theme.muted(0.62))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Theme.bg, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private var profileMetaItems: [(icon: String, text: String)] {
        var items: [(icon: String, text: String)] = []
        if let location = store.location, !location.isEmpty {
            items.append(("mappin.and.ellipse", location))
        }
        if let website = store.website, !website.isEmpty {
            items.append(("link", website))
        }
        return items
    }

    private var statsSection: some View {
        profileSection(title: "统计", icon: "chart.bar.fill") {
            LazyVGrid(columns: activityColumns, spacing: 10) {
                ForEach(Array(displayStats.enumerated()), id: \.offset) { _, stat in
                    statTile(value: stat.value, label: stat.label)
                }
            }
        }
    }

    private var badgesSection: some View {
        profileSection(title: "徽章", icon: "shield.lefthalf.filled") {
            if store.badges.isEmpty {
                emptyRow(icon: "shield", text: store.isGuest ? "登录后查看你的徽章" : "还没有公开徽章")
            } else {
                wrappingChips(store.badges) { badge in
                    profileChip(badge, color: Color(light: 0xD99A00, dark: 0xF8D34B), icon: "shield.fill")
                }
            }
        }
    }

    private var nodesSection: some View {
        profileSection(title: "常去节点", icon: "square.grid.2x2.fill") {
            VStack(spacing: 4) {
                ForEach(Array(store.topCategories.prefix(5))) { community in
                    nodeRow(community)
                }
            }
        }
    }

    private var activitySection: some View {
        profileSection(title: "最近活跃", icon: "waveform.path.ecg") {
            HStack(alignment: .bottom, spacing: 7) {
                ForEach(Array(SampleData.activity.enumerated()), id: \.offset) { _, value in
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Theme.accent.opacity(0.78))
                        .frame(height: 72 * (value / 100))
                        .frame(maxWidth: .infinity, alignment: .bottom)
                }
            }
            .frame(height: 78, alignment: .bottom)

            HStack {
                ForEach(SampleData.weekdays, id: \.self) { day in
                    Text(day)
                        .font(Theme.body(10, weight: .medium))
                        .foregroundStyle(Theme.muted(0.45))
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private var accountSection: some View {
        profileSection(title: "账户", icon: "person.crop.circle.fill") {
            VStack(spacing: 4) {
                actionRow(title: "通知", subtitle: "查看回复、点赞和系统提醒", icon: "bell.fill", tint: Theme.accent) {
                    app.overlay = .notifications
                }
                actionRow(title: "设置", subtitle: "账户、隐私和外观", icon: "gearshape.fill", tint: Theme.text) {
                    app.overlay = .settings
                }
                actionRow(title: "Nodeloc Pro", subtitle: "自定义徽章和更多体验", icon: "sparkle", tint: Theme.accent) {
                    app.overlay = .pro
                }

                if !store.isGuest {
                    actionRow(title: "退出登录", subtitle: "回到登录页", icon: "rectangle.portrait.and.arrow.right", tint: Theme.danger) {
                        DiscourseLogin.shared.signOut()
                        withAnimation(.easeInOut(duration: 0.2)) {
                            app.authed = false
                            app.isGuest = false
                            app.onboardingDone = false
                        }
                    }
                }
            }
        }
    }

    private func profileSection<Content: View>(
        title: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Text(title)
                    .font(Theme.heading(16, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Spacer()
            }

            content()
        }
        .padding(16)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Theme.divider, lineWidth: 1)
        }
        .padding(.horizontal, 16)
    }

    private func statTile(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(Theme.heading(24, weight: .bold))
                .foregroundStyle(label == "获赞" || label == "声望" ? Theme.accent : Theme.text)
                .lineLimit(1)
                .minimumScaleFactor(0.76)
            Text(label)
                .font(Theme.body(12, weight: .semibold))
                .foregroundStyle(Theme.muted(0.55))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.bg, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Theme.divider, lineWidth: 1)
        }
    }

    private func nodeRow(_ community: Community) -> some View {
        Button {
            app.tab = .search
        } label: {
            HStack(spacing: 12) {
                Avatar(letter: community.letter, variant: community.variant, size: 38, cornerRadius: 12)

                VStack(alignment: .leading, spacing: 2) {
                    Text(community.name)
                        .font(Theme.body(15, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Text(community.desc)
                        .font(Theme.body(11))
                        .foregroundStyle(Theme.muted(0.5))
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Text(community.members)
                    .font(Theme.body(11, weight: .semibold))
                    .foregroundStyle(Theme.muted(0.48))
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func actionRow(
        title: String,
        subtitle: String,
        icon: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 36, height: 36)
                    .background(Theme.bg, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Theme.divider, lineWidth: 1)
                    }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(Theme.body(15, weight: .semibold))
                        .foregroundStyle(tint == Theme.danger ? Theme.danger : Theme.text)
                    Text(subtitle)
                        .font(Theme.body(11))
                        .foregroundStyle(Theme.muted(0.5))
                        .lineLimit(1)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.muted(0.36))
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func emptyRow(icon: String, text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.muted(0.42))
            Text(text)
                .font(Theme.body(13))
                .foregroundStyle(Theme.muted(0.56))
            Spacer()
        }
        .padding(14)
        .background(Theme.bg, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func profilePill(_ text: String, icon: String, iconColor: Color = Theme.muted(0.46)) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: icon == "circle.fill" ? 8 : 11, weight: .semibold))
                .foregroundStyle(iconColor)
            Text(text)
                .font(Theme.body(12, weight: .semibold))
                .foregroundStyle(Theme.muted(0.62))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Theme.bg, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.divider, lineWidth: 1))
    }

    private func profileChip(_ text: String, color: Color, icon: String? = nil) -> some View {
        HStack(spacing: 5) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(color)
            }
            Text(text)
                .font(Theme.body(11, weight: .semibold))
                .foregroundStyle(color)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(color.opacity(0.1), in: Capsule())
        .overlay(Capsule().strokeBorder(color.opacity(0.22), lineWidth: 1))
    }

    private func wrappingChips<Data: RandomAccessCollection, Content: View>(
        _ data: Data,
        @ViewBuilder content: @escaping (Data.Element) -> Content
    ) -> some View where Data.Element: Hashable {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 112), spacing: 8)], spacing: 8) {
            ForEach(Array(data), id: \.self) { item in
                content(item)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var displayStats: [(value: String, label: String)] {
        store.stats.isEmpty ? [
            (SampleData.userKarma, "声望"),
            (SampleData.userPosts, "主题"),
            (SampleData.userComments, "回复"),
            ("3", "徽章")
        ] : store.stats
    }

    private func roleColor(_ role: String) -> Color {
        switch role {
        case "ADMIN", "MOD":
            return Theme.danger
        case "REGULAR", "LEADER":
            return Color(light: 0x8A36D6, dark: 0xC99BFF)
        case "GUEST":
            return Theme.muted(0.58)
        default:
            return Color(light: 0x2F6DF6, dark: 0x7EA7FF)
        }
    }
}

#Preview {
    let app = AppState()
    app.authed = true
    app.onboardingDone = true
    return ProfileView()
        .environment(app)
        .foregroundStyle(Theme.text)
        .tint(Theme.accent)
}
