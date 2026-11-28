//
//  InvitePage.swift
//  nodeloc
//
//  邀请好友 — after the design's iOS artboard and the web's /invites: the
//  rewards card, the reader's link and code (with a poster and a QR code drawn
//  on the device), the four numbers, the milestones, the friends they brought
//  in with how far each has got, one-use invite links, and the rules.
//
//  Everything but the one-use links comes from `GET /api/v1/invites/me`; the
//  links are `GET /api/v1/invites`. Writes, each only on the reader's tap:
//  `POST /api/v1/invites/friends/{id}/remind` (提醒验证) and
//  `POST /api/v1/invites` (生成邀请链接).
//

import SwiftUI
import CoreImage.CIFilterBuiltins

// MARK: - Store

@MainActor
@Observable
final class InviteStore {
    private let client = DiscourseClient()

    private(set) var data: NLInviteOverview?
    private(set) var codes: [NLInviteCode] = []
    private(set) var isLoading = false
    private(set) var errorText: String?
    private(set) var reminding: Set<Int> = []
    private(set) var reminded: Set<Int> = []
    private(set) var isCreatingCode = false

    func load() async {
        isLoading = true
        errorText = nil
        defer { isLoading = false }
        do {
            data = try await client.inviteOverview()
        } catch {
            guard !(error is CancellationError) else { return }
            errorText = (error as? DiscourseError)?.errorDescription ?? error.localizedDescription
        }
        if data?.code != nil { await loadCodes() }
    }

    /// One-use links only: the personal code is shown above, and node invite
    /// links belong to the node's own page.
    func loadCodes() async {
        guard let all = try? await client.inviteCodes() else { return }
        codes = all.filter { $0.personal != true && $0.nodeId == nil && $0.revoked != true }
    }

    func remind(_ friend: NLInviteOverview.Friend) async {
        guard !reminding.contains(friend.id) else { return }
        reminding.insert(friend.id)
        defer { reminding.remove(friend.id) }
        do {
            try await client.remindInvitedFriend(id: friend.id)
            reminded.insert(friend.id)
            ToastCenter.shared.show(AppString("已提醒 \(friend.displayName) 验证邮箱，24 小时内不能重复提醒"))
        } catch {
            if (error as? DiscourseError)?.serverCode == "remind_too_soon" { reminded.insert(friend.id) }
            ToastCenter.shared.showError(error)
        }
    }

    func createCode() async {
        guard !isCreatingCode else { return }
        isCreatingCode = true
        defer { isCreatingCode = false }
        do {
            let invite = try await client.createInviteCode()
            codes.insert(invite, at: 0)
            ToastCenter.shared.show(AppString("已生成"))
        } catch {
            ToastCenter.shared.showError(error)
        }
    }
}

// MARK: - Page

struct InvitePage: View {
    @Environment(AppState.self) private var app
    let navigation: PageNavigation
    let onClose: () -> Void

    @State private var store = InviteStore()
    @State private var scrolled = false
    @State private var friendFilter = FriendFilter.all
    @State private var openRule: Int? = 0
    @State private var sharing: ShareKind?

    enum FriendFilter { case all, effective, pending }
    enum ShareKind: String, Identifiable { case poster, qr; var id: String { rawValue } }

    var body: some View {
        Group {
            if app.authed {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        EnergyPageTitle(text: AppString("邀请好友"))
                        content
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 32)
                }
                .tracksTitleScroll($scrolled)
                .refreshable { await store.load() }
                .task { await store.load() }
            } else {
                EnergySignedOutView(message: AppString("登录后邀请好友"), onClose: onClose)
            }
        }
        .energyPageChrome(
            title: AppString("邀请好友"),
            navigation: navigation,
            titleVisible: scrolled,
            onClose: onClose
        )
        .sheet(item: $sharing) { kind in
            if let code = store.data?.code {
                InviteShareSheet(kind: kind, code: code, link: Self.link(for: code), welcome: store.data?.overview.rewards.welcome ?? 0)
            }
        }
    }

    static func link(for code: String) -> URL {
        DiscourseConfig.baseURL.appendingPathComponent("i").appendingPathComponent(code)
    }

    @ViewBuilder
    private var content: some View {
        if let data = store.data {
            let overview = data.overview
            hero(overview.rewards)
            if let code = data.code {
                linkCard(code: code)
            } else {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(Theme.textMuted)
                    Text(AppString("你的段位现在还不能邀请好友。升段位之后，这里会出现你专属的邀请链接和邀请码。"))
                        .font(Theme.body(14))
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            stats(overview)
            if !overview.milestones.isEmpty {
                InviteMilestones(milestones: overview.milestones, count: overview.milestoneCount)
            }
            friends(overview)
            if data.code != nil {
                oneUseLinks
            }
            rules(overview.rewards)
        } else if store.isLoading {
            InviteSkeleton()
        } else if let errorText = store.errorText {
            EnergyRetryView(message: errorText) { Task { await store.load() } }
        }
    }

    // MARK: Hero

    /// The web's headline for whichever rewards are switched on.
    private func headline(_ rewards: NLInviteOverview.Rewards) -> String {
        switch (rewards.inviter > 0, rewards.welcome > 0) {
        case (true, true): AppString("每邀请一位好友，你得 \(rewards.inviter) 能量，好友得 \(rewards.welcome)")
        case (true, false): AppString("每邀请一位好友，你得 \(rewards.inviter) 能量")
        case (false, true): AppString("好友用你的邀请注册，能得 \(rewards.welcome) 能量")
        case (false, false): AppString("把这里分享给会喜欢它的人")
        }
    }

    private func steps(_ rewards: NLInviteOverview.Rewards) -> [(when: String, reward: String)] {
        let first: String = switch (rewards.inviter > 0, rewards.welcome > 0) {
        case (true, true): AppString("你 +\(rewards.inviter) · 好友 +\(rewards.welcome)")
        case (true, false): AppString("你 +\(rewards.inviter)")
        case (false, true): AppString("好友 +\(rewards.welcome)")
        case (false, false): AppString("奖励直接进能量余额")
        }
        var steps = [(AppString("好友用你的链接注册并验证邮箱"), first)]
        if rewards.levelBonus > 0 {
            steps.append((AppString("好友升到\(rewards.levelName)"), AppString("你再得 +\(rewards.levelBonus)")))
        }
        if rewards.second > 0 {
            steps.append((AppString("好友邀请的人也生效"), AppString("每人你得 +\(rewards.second)")))
        }
        return steps
    }

    private func hero(_ rewards: NLInviteOverview.Rewards) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "gift")
                    .font(.system(size: 11, weight: .bold))
                Text(AppString("邀请奖励"))
            }
            .font(Theme.body(12, weight: .bold))
            .foregroundStyle(EnergyPalette.mint)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(EnergyPalette.mint.opacity(0.16), in: Capsule())

            Text(headline(rewards))
                .font(Theme.heading(22, weight: .heavy))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
            Text(AppString("好友越活跃，你拿到的越多。奖励直接进你的能量余额。"))
                .font(Theme.body(14))
                .foregroundStyle(EnergyPalette.nightMuted)
                .padding(.top, 6)

            VStack(spacing: 10) {
                let list = steps(rewards)
                ForEach(list.indices, id: \.self) { index in
                    HStack(alignment: .top, spacing: 12) {
                        Text("\(index + 1)")
                            .font(Theme.body(14, weight: .heavy))
                            .foregroundStyle(EnergyPalette.goldInk)
                            .frame(width: 28, height: 28)
                            .background(EnergyPalette.mint, in: Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            Text(list[index].when)
                                .font(Theme.body(13))
                                .foregroundStyle(EnergyPalette.nightMuted)
                            Text(list[index].reward)
                                .font(Theme.body(14, weight: .bold))
                                .foregroundStyle(.white)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
            .padding(.top, 18)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.profileBanner, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: Link

    private func linkCard(code: String) -> some View {
        let link = Self.link(for: code)
        return VStack(alignment: .leading, spacing: 12) {
            Text(AppString("你的邀请链接"))
                .font(Theme.body(16, weight: .bold))
                .foregroundStyle(Theme.text)
            VStack(alignment: .leading, spacing: 8) {
                Text(link.absoluteString)
                    .font(Theme.body(15))
                    .foregroundStyle(Theme.text)
                    .monospacedDigit()
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Theme.textFaint, lineWidth: 1)
                    }
                    .accessibilityLabel(AppString("邀请链接"))
                Button {
                    copyLink(link, message: AppString("邀请链接已复制"))
                } label: {
                    Label(AppString("复制链接"), systemImage: "doc.on.doc")
                        .labelStyle(CompactLabelStyle())
                        .frame(minWidth: 84)
                }
                .buttonStyle(FilledButtonStyle())
            }
            HStack(spacing: 8) {
                Text(AppString("邀请码"))
                    .font(Theme.body(13))
                    .foregroundStyle(Theme.textMuted)
                Button {
                    UIPasteboard.general.string = code
                    ToastCenter.shared.show(AppString("邀请码 \(code) 已复制"))
                } label: {
                    HStack(spacing: 6) {
                        Text(code)
                            .font(.system(size: Theme.scaledSize(15), weight: .bold, design: .monospaced))
                            .tracking(1.8)
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.textMuted)
                    }
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 12)
                    .frame(height: 36)
                    .background(Theme.bg, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Theme.textFaint, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                    }
                }
                .buttonStyle(.pressable)
                .accessibilityLabel(AppString("复制邀请码 \(code)"))
            }
            HStack(spacing: 8) {
                Button { sharing = .poster } label: {
                    CapsuleActionLabel(title: AppString("生成海报"), systemImage: "photo.on.rectangle", height: 44)
                }
                .buttonStyle(.pressable)
                Button { sharing = .qr } label: {
                    CapsuleActionLabel(title: AppString("二维码"), systemImage: "qrcode", height: 44)
                }
                .buttonStyle(.pressable)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.bg, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        }
    }

    // MARK: Stats

    private func stats(_ overview: NLInviteOverview.Overview) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
            statCell(AppString("已邀请"), value: "\(overview.invited)", tint: Theme.text, note: AppString("人注册"))
            statCell(AppString("有效好友"), value: "\(overview.effective)", tint: EnergyPalette.plus, note: AppString("已验证邮箱"))
            statCell(
                AppString("累计获得"),
                value: "+" + EnergyFormat.grouped(overview.earned),
                tint: EnergyPalette.plus,
                note: overview.earnedSecond > 0
                    ? AppString("能量，含二级 +\(EnergyFormat.grouped(overview.earnedSecond))")
                    : AppString("能量")
            )
            statCell(AppString("待解锁"), value: EnergyFormat.grouped(overview.pending), tint: Theme.text, note: AppString("能量，好友完成后到账"))
        }
    }

    private func statCell(_ label: String, value: String, tint: Color, note: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label)
                .font(Theme.body(12))
                .foregroundStyle(Theme.textMuted)
            Text(value)
                .font(Theme.heading(24, weight: .heavy))
                .foregroundStyle(tint)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.top, 2)
            Text(note)
                .font(Theme.body(12))
                .foregroundStyle(Theme.textMuted)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.bg, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        }
    }

    // MARK: Friends

    private func friends(_ overview: NLInviteOverview.Overview) -> some View {
        let shown = overview.friends.filter { friend in
            switch friendFilter {
            case .all: true
            case .effective: friend.isEffective
            case .pending: friend.stage == "pending"
            }
        }
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text(AppString("我邀请的好友"))
                    .font(Theme.body(16, weight: .bold))
                    .foregroundStyle(Theme.text)
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        filterChip(.all, AppString("全部"), overview.invited)
                        filterChip(.effective, AppString("已生效"), overview.effective)
                        filterChip(.pending, AppString("待验证"), overview.pendingCount)
                    }
                }
                .scrollIndicators(.hidden)
            }
            .padding(.top, 12)
            .padding(.bottom, 8)

            if overview.friends.isEmpty {
                VStack(spacing: 4) {
                    Text(AppString("还没有邀请到好友"))
                        .font(Theme.body(14, weight: .bold))
                        .foregroundStyle(Theme.text)
                    Text(AppString("把上面的链接或邀请码发给朋友，他注册后就会出现在这里。"))
                        .font(Theme.body(13))
                        .foregroundStyle(Theme.textMuted)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
                .overlay(alignment: .top) { Rectangle().fill(Theme.chip).frame(height: 1) }
            } else if shown.isEmpty {
                Text(AppString("这一类里还没有人。"))
                    .font(Theme.body(13))
                    .foregroundStyle(Theme.textMuted)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                    .overlay(alignment: .top) { Rectangle().fill(Theme.chip).frame(height: 1) }
            } else {
                ForEach(shown) { friend in
                    InviteFriendRow(
                        friend: friend,
                        rewards: overview.rewards,
                        isReminding: store.reminding.contains(friend.id),
                        wasReminded: store.reminded.contains(friend.id),
                        onOpen: {
                            app.pushPage(.profile(UserProfileTarget(
                                username: friend.username,
                                displayName: friend.name,
                                avatarURL: friend.avatarUrl.flatMap(URL.init(string:))
                            )))
                        },
                        onRemind: { Task { await store.remind(friend) } }
                    )
                }
            }
            Text(AppString("只显示通过你的链接或邀请码注册的账号。好友注册 \(overview.rewards.verifyDays) 天内没有验证邮箱，邀请会失效。"))
                .font(Theme.body(12))
                .foregroundStyle(Theme.textMuted)
                .padding(.top, 8)
        }
    }

    private func filterChip(_ filter: FriendFilter, _ title: String, _ count: Int) -> some View {
        Button {
            friendFilter = filter
        } label: {
            EnergyFilterChip(title: title, count: count, isSelected: friendFilter == filter)
        }
        .buttonStyle(.pressable)
    }

    // MARK: One-use links

    /// The web's /invites view from its settings menu: links that each work
    /// once and for a limited time, for handing to one person.
    private var oneUseLinks: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(AppString("一次性邀请链接"))
                .font(Theme.body(16, weight: .bold))
                .foregroundStyle(Theme.text)
            Text(AppString("把链接发给朋友，他用这个链接注册就算你邀请的。每个链接只能用一次。"))
                .font(Theme.body(13))
                .foregroundStyle(Theme.textMuted)
            ForEach(store.codes) { invite in
                oneUseRow(invite)
            }
            Button {
                Task { await store.createCode() }
            } label: {
                HStack(spacing: 6) {
                    if store.isCreatingCode {
                        ProgressView().controlSize(.mini).tint(Theme.onAccent)
                    } else {
                        Image(systemName: "plus")
                            .font(.system(size: 13, weight: .bold))
                    }
                    Text(AppString("生成邀请链接"))
                }
            }
            .buttonStyle(FilledButtonStyle())
            .disabled(store.isCreatingCode)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.bg, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        }
    }

    private func oneUseRow(_ invite: NLInviteCode) -> some View {
        let url = Self.oneUseLink(invite.code)
        let used = invite.useCount ?? 0
        let expired = DiscourseFormat.date(invite.expiresAt).map { $0 < Date() } ?? false
        let usable = !expired && (invite.maxUses.map { used < $0 } ?? true)
        var meta = AppString("已用 \(used) / \(invite.maxUses ?? 1)")
        if let expires = DiscourseFormat.date(invite.expiresAt) {
            meta += " · " + (expired ? AppString("已过期") : AppString("\(EnergyFormat.full.string(from: expires)) 过期"))
        }
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(url.absoluteString)
                    .font(Theme.body(13, weight: .medium))
                    .foregroundStyle(usable ? Theme.text : Theme.textFaint)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(meta)
                    .font(Theme.body(12))
                    .foregroundStyle(Theme.textMuted)
                    .monospacedDigit()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if usable {
                Button {
                    copyLink(url, message: AppString("邀请链接已复制"))
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .frame(width: 36, height: 36)
                        .background(Theme.chip, in: Circle())
                }
                .buttonStyle(.pressable)
                .accessibilityLabel(AppString("复制链接"))
            }
        }
        .padding(.vertical, 6)
        .overlay(alignment: .top) { Rectangle().fill(Theme.chip).frame(height: 1) }
    }

    /// What the web's list hands out for a one-use code.
    static func oneUseLink(_ code: String) -> URL {
        var components = URLComponents(url: DiscourseConfig.baseURL.appendingPathComponent("register"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "invite", value: code)]
        return components?.url ?? DiscourseConfig.baseURL
    }

    // MARK: Rules

    private func rules(_ rewards: NLInviteOverview.Rewards) -> some View {
        let faq: [(String, String)] = [
            (AppString("什么算有效邀请？"), AppString("好友通过你的链接或邀请码注册，并在 \(rewards.verifyDays) 天内验证邮箱。")),
            (AppString("奖励什么时候到账？"), AppString("好友验证邮箱后立刻到账；升到\(rewards.levelName)的奖励在好友升级后一刻钟内发放。每笔都会出现在能量明细里。")),
            (AppString("二级奖励怎么算？"), AppString("你邀请的好友再邀请别人，每有一位生效，你得 \(rewards.second) 能量。只算两级，不会无限往下。")),
            (AppString("有没有上限？"), rewards.monthlyCap > 0
                ? AppString("每月最多从 \(rewards.monthlyCap) 位新的有效好友身上拿邀请奖励，超出的好友照样算有效、好友自己的奖励照发。里程碑不受这个限制。")
                : AppString("现在没有上限。")),
            (AppString("刷邀请会怎样？"), AppString("用小号、脚本批量注册违反社区守则，管理员可以扣回奖励并处理账号。")),
        ]
        return VStack(alignment: .leading, spacing: 0) {
            Text(AppString("规则说明"))
                .font(Theme.body(14, weight: .bold))
                .foregroundStyle(Theme.text)
                .padding(.bottom, 4)
            ForEach(faq.indices, id: \.self) { index in
                VStack(alignment: .leading, spacing: 0) {
                    Button {
                        withAnimation(.quick) { openRule = openRule == index ? nil : index }
                    } label: {
                        HStack(spacing: 8) {
                            Text(faq[index].0)
                                .font(Theme.body(14, weight: .medium))
                                .foregroundStyle(Theme.text)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Theme.textMuted)
                                .rotationEffect(.degrees(openRule == index ? 180 : 0))
                        }
                        .padding(.vertical, 8)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.pressable)
                    if openRule == index {
                        Text(faq[index].1)
                            .font(Theme.body(13))
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.bottom, 12)
                            .transition(.opacity)
                    }
                }
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
            }
        }
        .padding(.top, 8)
    }
}

// MARK: - Milestones

/// 里程碑: 3 / 10 / 30 / 100 effective friends, each a quarter of the bar and
/// filled in proportion within its quarter, as the web draws it.
private struct InviteMilestones: View {
    let milestones: [NLInviteOverview.Milestone]
    let count: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(AppString("里程碑"))
                    .font(Theme.body(16, weight: .bold))
                    .foregroundStyle(Theme.text)
                Spacer(minLength: 0)
                Text(next)
                    .font(Theme.body(13, weight: .bold))
                    .foregroundStyle(EnergyPalette.plus)
                    .multilineTextAlignment(.trailing)
            }
            GeometryReader { proxy in
                let width = proxy.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.chip).frame(height: 8)
                    Capsule().fill(Theme.accentFill).frame(width: width * fraction, height: 8)
                    ForEach(milestones.indices, id: \.self) { index in
                        dot(milestones[index])
                            .position(x: width * position(index), y: 14)
                    }
                    ForEach(milestones.indices, id: \.self) { index in
                        caption(milestones[index], last: true)
                            // Each caption ends under its dot, in the quarter before it, so
                            // the long ones (徽章「织网人」+1,000) never run into the next.
                            .frame(width: segment(width) - 4, alignment: .trailing)
                            .position(
                                x: width * position(index) - segment(width) / 2 + 2,
                                y: 28 + 20 + 22
                            )
                    }
                }
                .frame(height: 28, alignment: .center)
            }
            .frame(height: 28 + 64)
            .padding(.horizontal, 12)
            .padding(.top, 14)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.bg, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        }
    }

    private func segment(_ width: CGFloat) -> CGFloat {
        width / CGFloat(max(milestones.count, 1))
    }

    private func position(_ index: Int) -> CGFloat {
        CGFloat(index + 1) / CGFloat(max(milestones.count, 1))
    }

    /// Fill: whole quarters for milestones passed, then the share of the way
    /// from the last one to the next.
    private var fraction: CGFloat {
        let quarter = 1 / CGFloat(max(milestones.count, 1))
        var previous = 0
        var filled: CGFloat = 0
        for (index, milestone) in milestones.enumerated() where count > previous {
            let span = CGFloat(max(milestone.target - previous, 1))
            filled = CGFloat(index) * quarter + quarter * min(1, CGFloat(count - previous) / span)
            previous = milestone.target
        }
        return min(max(filled, 0), 1)
    }

    private func label(_ milestone: NLInviteOverview.Milestone) -> String {
        switch (milestone.badge?.isEmpty == false ? milestone.badge : nil, milestone.reward > 0) {
        case (let badge?, true): AppString("徽章「\(badge)」+\(EnergyFormat.grouped(milestone.reward))")
        case (let badge?, false): AppString("徽章「\(badge)」")
        case (nil, true): AppString("+\(EnergyFormat.grouped(milestone.reward)) 能量")
        case (nil, false): ""
        }
    }

    private var next: String {
        guard let milestone = milestones.first(where: { count < $0.target }) else {
            return AppString("全部里程碑都完成了")
        }
        let gain = label(milestone).isEmpty ? AppString("\(milestone.target) 人里程碑") : label(milestone)
        return AppString("再邀请 \(milestone.target - count) 位有效好友，解锁 \(gain)")
    }

    private func dot(_ milestone: NLInviteOverview.Milestone) -> some View {
        ZStack {
            Circle().fill(milestone.reached ? Theme.accentFill : Theme.bg)
            Circle().strokeBorder(milestone.reached ? Theme.accentFill : Theme.textFaint, lineWidth: 2)
            if milestone.reached {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(Theme.onAccent)
            } else {
                Text("\(milestone.target)")
                    .font(Theme.body(11, weight: .heavy))
                    .foregroundStyle(Theme.textMuted)
                    .minimumScaleFactor(0.7)
            }
        }
        .frame(width: 28, height: 28)
    }

    private func caption(_ milestone: NLInviteOverview.Milestone, last: Bool) -> some View {
        VStack(alignment: last ? .trailing : .center, spacing: 0) {
            Text(AppString("\(milestone.target) 人"))
                .font(Theme.body(12, weight: .bold))
                .foregroundStyle(milestone.reached ? EnergyPalette.plus : Theme.text)
            Text(label(milestone))
                .font(Theme.body(12))
                .foregroundStyle(Theme.textMuted)
                .lineLimit(2)
                .multilineTextAlignment(last ? .trailing : .center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(height: 44, alignment: .top)
    }
}

// MARK: - Friend row

private struct InviteFriendRow: View {
    let friend: NLInviteOverview.Friend
    let rewards: NLInviteOverview.Rewards
    let isReminding: Bool
    let wasReminded: Bool
    let onOpen: () -> Void
    let onRemind: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onOpen) {
                RemoteAvatar(
                    url: friend.avatarUrl.flatMap(URL.init(string:)),
                    letter: friend.displayName.first.map { String($0).uppercased() } ?? "?",
                    variant: friend.id % 2,
                    size: 40
                )
            }
            .buttonStyle(.pressable)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Button(action: onOpen) {
                        Text(friend.displayName)
                            .font(Theme.body(15, weight: .medium))
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    if let sub = friend.subInvites, sub > 0 {
                        Text(AppString("又邀请了 \(sub) 人"))
                            .font(Theme.body(11, weight: .bold))
                            .foregroundStyle(EnergyPalette.reward.1)
                            .padding(.horizontal, 6)
                            .frame(height: 18)
                            .background(EnergyPalette.reward.0, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .fixedSize()
                    }
                }
                HStack(spacing: 4) {
                    Text(joinedLabel)
                        .monospacedDigit()
                    Text(verbatim: "·")
                    HStack(spacing: 3) {
                        ForEach(1...3, id: \.self) { index in
                            Capsule()
                                .fill(index <= step ? Theme.accentFill : Theme.hairline)
                                .frame(width: 18, height: 4)
                        }
                    }
                    .accessibilityElement()
                    .accessibilityLabel(AppString("进度 \(step) / 3：\(stageText)"))
                    Text(stageText)
                        .font(Theme.body(12, weight: .medium))
                        .foregroundStyle(isWarn ? EnergyPalette.warn : EnergyPalette.plus)
                        .lineLimit(1)
                }
                .font(Theme.body(12))
                .foregroundStyle(Theme.textMuted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let earned = friend.earned, earned > 0 {
                VStack(alignment: .trailing, spacing: 0) {
                    Text("+" + EnergyFormat.grouped(earned))
                        .font(Theme.body(15, weight: .bold))
                        .foregroundStyle(EnergyPalette.plus)
                    if let note = earnNote {
                        Text(note)
                            .font(Theme.body(12))
                            .foregroundStyle(Theme.textMuted)
                    }
                }
                .monospacedDigit()
                .fixedSize()
            } else if let note = earnNote, friend.stage != "pending" {
                Text(note)
                    .font(Theme.body(12))
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize()
            }

            if friend.stage == "pending" {
                let canRemind = (friend.canRemind ?? false) && !wasReminded
                Button(action: onRemind) {
                    Text(canRemind ? AppString("提醒验证") : AppString("已提醒"))
                        .font(Theme.body(13, weight: .bold))
                        .foregroundStyle(canRemind ? Theme.text : Theme.textMuted)
                        .padding(.horizontal, 14)
                        .frame(height: 36)
                        .background(Theme.bg, in: Capsule())
                        .overlay(Capsule().strokeBorder(Theme.textFaint, lineWidth: 1))
                        .contentShape(Capsule())
                        .fixedSize()
                }
                .buttonStyle(.pressable)
                .disabled(!canRemind || isReminding)
            }
        }
        .padding(.vertical, 10)
        .frame(minHeight: 68)
        .overlay(alignment: .top) { Rectangle().fill(Theme.chip).frame(height: 1) }
    }

    private var joinedLabel: String {
        guard let date = DiscourseFormat.date(friend.joinedAt) else { return "" }
        let parts = EnergyFormat.calendar.dateComponents([.month, .day], from: date)
        return AppString("\(parts.month ?? 0)月\(parts.day ?? 0)日加入")
    }

    private var step: Int {
        switch friend.stage {
        case "verified": 2
        case "leveled": 3
        default: 1
        }
    }

    private var isWarn: Bool { friend.stage == "pending" || friend.stage == "expired" }

    private var stageText: String {
        switch friend.stage {
        case "pending": AppString("已注册，待验证邮箱")
        case "expired": AppString("\(rewards.verifyDays) 天内没有验证邮箱，邀请已失效")
        case "verified": AppString("已验证邮箱")
        default: AppString("已升到\(rewards.levelName)")
        }
    }

    private var earnNote: String? {
        if friend.capped == true, friend.isEffective { return AppString("当月名额已满") }
        if friend.stage == "verified", rewards.levelBonus > 0 { return AppString("升到\(rewards.levelName)再 +\(rewards.levelBonus)") }
        if let second = friend.second, second > 0 { return AppString("含二级 +\(second)") }
        if (friend.earned ?? 0) > 0 { return AppString("全部到账") }
        return nil
    }
}

// MARK: - Poster and QR

/// The invite link as a QR code, or as a poster to save or send. Both are
/// drawn here — nothing leaves the device to make them.
///
/// The poster is for the person who receives it, so it speaks to them, in
/// the words of the invited person's landing page (Mobile-InviteLanding):
/// who invites them, what nodeloc is, what joining with this code gives them
/// (`rewards.welcome`, only when the site grants one), the code and the QR,
/// and how to use them. Light, whatever the app's appearance, and rendered
/// 360 pt wide at 3× (1080 px).
private struct InviteShareSheet: View {
    let kind: InvitePage.ShareKind
    let code: String
    let link: URL
    /// Energy a newcomer gets for joining with a code; 0 when the site gives none.
    let welcome: Int
    @Environment(\.dismiss) private var dismiss
    @State private var avatar: UIImage?

    private var me: NLUser? { NodelocAdapterState.shared.me }
    private var inviterName: String {
        if let name = me?.name, !name.isEmpty { return name }
        return me?.username ?? DiscourseAuth.shared.username ?? "nodeloc"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    if kind == .qr {
                        qrCard
                    } else {
                        poster
                            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                            .shadow(color: .black.opacity(0.12), radius: 16, y: 6)
                    }
                    if let image = rendered {
                        ShareLink(
                            item: image,
                            preview: SharePreview(
                                kind == .qr ? AppString("加入 nodeloc 的二维码") : AppString("\(inviterName) 邀请你加入 nodeloc"),
                                image: image
                            )
                        ) {
                            Label(AppString("保存或分享"), systemImage: "square.and.arrow.up")
                                .labelStyle(CompactLabelStyle())
                        }
                        .buttonStyle(FilledButtonStyle(block: true))
                    }
                }
                .padding(20)
            }
            .background(Theme.bg)
            .navigationTitle(kind == .qr ? AppString("二维码") : AppString("生成海报"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppString("完成")) { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
        .task { avatar = await Self.loadAvatar() }
    }

    private var qrCard: some View {
        VStack(spacing: 12) {
            qrImage
                .frame(width: 220, height: 220)
            Text(link.absoluteString)
                .font(Theme.body(13))
                .foregroundStyle(Theme.textMuted)
            Text(AppString("邀请码 \(code)"))
                .font(Theme.body(14, weight: .bold))
                .foregroundStyle(Theme.text)
        }
        .padding(20)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .environment(\.colorScheme, .light)
    }

    private static let ink = Color(hex: 0x0F1A1C)
    private static let muted = Color(hex: 0x576F76)
    private static let green = Color(hex: 0x029A68)

    private var poster: some View {
        VStack(alignment: .leading, spacing: 0) {
            NodelocLogo(markSize: 30, wordSize: 20)

            // Who is inviting them.
            HStack(spacing: 12) {
                inviterAvatar
                Text(AppString("\(inviterName) 邀请你加入 nodeloc"))
                    .font(Theme.body(16, weight: .bold))
                    .foregroundStyle(Self.ink)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 26)

            // What nodeloc is.
            Text(AppString("找到一群聊同一件事的人"))
                .font(Theme.heading(26, weight: .heavy))
                .foregroundStyle(Self.ink)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 18)
            Text(AppString("独立开发、摄影、咖啡、骑行……总有一个节点是你的。"))
                .font(Theme.body(14))
                .foregroundStyle(Self.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)

            // What joining with this code gives them, when the site gives anything.
            if welcome > 0 {
                HStack(spacing: 12) {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(Color(hex: 0x0B1F18))
                        .frame(width: 38, height: 38)
                        .background(Color(hex: 0xFF9C38), in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(AppString("注册即得 \(welcome) 能量"))
                            .font(Theme.body(15, weight: .bold))
                            .foregroundStyle(Self.ink)
                        Text(AppString("用这个邀请码注册，验证邮箱后到账。"))
                            .font(Theme.body(12))
                            .foregroundStyle(Self.muted)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(hex: 0xFFF6EC), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color(hex: 0xF7D3A8), lineWidth: 1))
                .padding(.top, 18)
            }

            // The code and the QR, and how to use them.
            HStack(alignment: .center, spacing: 16) {
                qrImage
                    .frame(width: 116, height: 116)
                    // The quiet zone the scanners need, in white.
                    .padding(10)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(hex: 0xDCE3E6), lineWidth: 1))
                VStack(alignment: .leading, spacing: 4) {
                    Text(AppString("邀请码"))
                        .font(Theme.body(12))
                        .foregroundStyle(Self.muted)
                    Text(code)
                        .font(.system(size: 24, weight: .bold, design: .monospaced))
                        .foregroundStyle(Self.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                    Text(AppString("扫码注册，或在注册时填写邀请码"))
                        .font(Theme.body(12))
                        .foregroundStyle(Self.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 22)
        }
        .padding(24)
        .frame(width: 360, alignment: .leading)
        .background(Color.white)
        .overlay(alignment: .top) { Self.green.frame(height: 6) }
        .environment(\.colorScheme, .light)
    }

    @ViewBuilder
    private var inviterAvatar: some View {
        if let avatar {
            Image(uiImage: avatar)
                .resizable()
                .scaledToFill()
                .frame(width: 44, height: 44)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(Color(hex: 0x5CC79A), lineWidth: 2))
        } else {
            Text(String(inviterName.prefix(1)).uppercased())
                .font(Theme.body(18, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Self.green, in: Circle())
        }
    }

    /// The reader's avatar, fetched before rendering: the renderer draws one
    /// frame and can't wait for an image still loading.
    private static func loadAvatar() async -> UIImage? {
        guard let raw = NodelocAdapterState.shared.myAvatar,
              let url = NodeSummaryFactory.resolvedURL(raw),
              let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        return UIImage(data: data)
    }

    private var qrImage: some View {
        Group {
            if let image = Self.qr(link.absoluteString) {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
            } else {
                Color.clear
            }
        }
    }

    @MainActor
    private var rendered: Image? {
        let renderer = kind == .qr ? ImageRenderer(content: AnyView(qrCard)) : ImageRenderer(content: AnyView(poster))
        renderer.scale = 3
        return renderer.uiImage.map { Image(uiImage: $0) }
    }

    static func qr(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cgImage = CIContext().createCGImage(output, from: output.extent)
        else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

// MARK: - Skeleton

private struct InviteSkeleton: View {
    var body: some View {
        VStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.neutral300).frame(height: 260)
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.neutral300).frame(height: 170)
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.neutral300).frame(height: 92)
                RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.neutral300).frame(height: 92)
            }
        }
        .skeletonPulsing()
        .accessibilityLabel(AppString("加载中"))
    }
}
