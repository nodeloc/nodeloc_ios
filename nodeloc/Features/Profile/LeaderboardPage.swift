//
//  LeaderboardPage.swift
//  nodeloc
//
//  财富榜 — the same table as the web's /rank, read from
//  `GET /api/v1/points/leaderboard`. The server recomputes it hourly and the
//  endpoint only reads, so this page never recalculates anything itself and
//  the numbers always agree with the web's.
//
//  Income over a week or a month deliberately excludes transfers between
//  members — otherwise two accounts passing energy back and forth would climb
//  the board. Tips, red envelopes and lottery winnings all count.
//

import SwiftUI

@MainActor
@Observable
final class LeaderboardStore {
    private let client = DiscourseClient()

    var period: DiscourseClient.LeaderboardPeriod = .all
    private(set) var entries: [NLLeaderboard.Entry] = []
    private(set) var me: NLLeaderboard.Me?
    private(set) var updatedAt: String?
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private(set) var errorText: String?
    private var nextPage: Int?

    func load(period: DiscourseClient.LeaderboardPeriod? = nil) async {
        if let period, period != self.period {
            self.period = period
            entries = []
        }
        isLoading = entries.isEmpty
        errorText = nil
        defer { isLoading = false }
        do {
            let board = try await client.leaderboard(period: self.period, page: 1)
            entries = board.users
            me = board.me
            updatedAt = board.updatedAt
            nextPage = board.nextPage
        } catch {
            errorText = (error as? DiscourseError)?.errorDescription ?? error.localizedDescription
        }
    }

    func loadMore() async {
        guard let page = nextPage, !isLoading, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        guard let board = try? await client.leaderboard(period: period, page: page) else { return }
        entries += board.users
        nextPage = board.nextPage
    }
}

struct LeaderboardPage: View {
    let onClose: () -> Void
    let onOpenProfile: (UserProfileTarget) -> Void

    @State private var store = LeaderboardStore()

    var body: some View {
        VStack(spacing: 0) {
            SettingsPageHeader(title: AppString("财富榜"), onClose: onClose)

            periodPicker

            ScrollView {
                LazyVStack(spacing: 0) {
                    if store.isLoading, store.entries.isEmpty {
                        ProgressView()
                            .tint(Theme.accent)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                    } else if let errorText = store.errorText, store.entries.isEmpty {
                        Text(errorText)
                            .font(Theme.body(13))
                            .foregroundStyle(Theme.muted(0.55))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                    } else {
                        ForEach(store.entries) { entry in
                            row(entry)
                            Divider().background(Theme.divider)
                        }

                        if store.isLoadingMore {
                            ProgressView()
                                .controlSize(.small)
                                .tint(Theme.accent)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                        }

                        // The last row coming into view is the cue for more.
                        Color.clear
                            .frame(height: 1)
                            .onAppear { Task { await store.loadMore() } }
                    }

                    if let updatedAt = store.updatedAt {
                        Text(AppString("更新于 \(DiscourseFormat.relative(updatedAt))"))
                            .font(Theme.body(11))
                            .foregroundStyle(Theme.muted(0.4))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 18)
                    }
                }
            }

            // Where this reader stands, pinned so they needn't scroll for it.
            if let me = store.me, let rank = me.rank, rank > 0 {
                myStanding(me, rank: rank)
            }
        }
        .background(Theme.bg)
        .task { await store.load() }
    }

    private var periodPicker: some View {
        HStack(spacing: 8) {
            ForEach(DiscourseClient.LeaderboardPeriod.allCases, id: \.self) { period in
                Button {
                    Task { await store.load(period: period) }
                } label: {
                    Text(period.title)
                        .font(Theme.body(13, weight: store.period == period ? .semibold : .regular))
                        .foregroundStyle(store.period == period ? Theme.accent700 : Theme.muted(0.5))
                        .padding(.vertical, 6)
                        .padding(.horizontal, 14)
                        .background(
                            store.period == period ? Theme.accent.opacity(0.12) : Color.clear,
                            in: Capsule()
                        )
                }
                .buttonStyle(.pressable)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func row(_ entry: NLLeaderboard.Entry) -> some View {
        Button {
            onOpenProfile(
                UserProfileTarget(
                    username: entry.username,
                    displayName: entry.name,
                    avatarURL: entry.avatarUrl.flatMap(URL.init(string:))
                )
            )
        } label: {
            HStack(spacing: 12) {
                Text("\(entry.rank)")
                    .font(Theme.body(14, weight: .semibold))
                    .foregroundStyle(entry.rank <= 3 ? Theme.accent700 : Theme.muted(0.45))
                    .frame(width: 30, alignment: .leading)

                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name ?? entry.username)
                        .font(Theme.body(14))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    // Null when that reader hides their tier.
                    if let tierName = entry.tierName {
                        Text(tierName)
                            .font(Theme.body(11))
                            .foregroundStyle(Theme.muted(0.45))
                    }
                }

                Spacer(minLength: 0)

                rankChange(entry.rankChange)

                Text("\(entry.value)")
                    .font(Theme.body(14, weight: .semibold))
                    .foregroundStyle(Theme.text)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .background(entry.me == true ? Theme.accent.opacity(0.06) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
    }

    /// Movement against this reader's first standing today. Null means they
    /// only joined the board today, which the web calls "new".
    @ViewBuilder
    private func rankChange(_ change: Int?) -> some View {
        if let change {
            if change != 0 {
                Label("\(abs(change))", systemImage: change > 0 ? "arrow.up" : "arrow.down")
                    .labelStyle(CompactLabelStyle())
                    .font(Theme.body(10, weight: .semibold))
                    .foregroundStyle(change > 0 ? Theme.success : Theme.danger)
            }
        } else {
            Text(AppString("新上榜"))
                .font(Theme.body(10, weight: .semibold))
                .foregroundStyle(Theme.accent700)
        }
    }

    private func myStanding(_ me: NLLeaderboard.Me, rank: Int) -> some View {
        HStack(spacing: 12) {
            Text(AppString("我"))
                .font(Theme.body(12, weight: .semibold))
                .foregroundStyle(Theme.muted(0.5))
            Text(AppString("第 \(rank) 名"))
                .font(Theme.body(14, weight: .semibold))
                .foregroundStyle(Theme.text)
            Spacer(minLength: 0)
            // 0 at the top, where there is nobody to catch.
            if let gap = me.gap, gap > 0 {
                Text(AppString("距上一名 \(gap)"))
                    .font(Theme.body(11))
                    .foregroundStyle(Theme.muted(0.45))
            }
            Text("\(me.value ?? 0)")
                .font(Theme.body(14, weight: .semibold))
                .foregroundStyle(Theme.accent700)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Theme.surface)
    }
}
