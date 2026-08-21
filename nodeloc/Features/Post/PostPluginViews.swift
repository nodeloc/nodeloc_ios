//
//  PostPluginViews.swift
//  nodeloc
//
//  Reading-side views for the three content plugins.
//
//  All three arrive as structured JSON alongside the post rather than as markup
//  inside `cooked`, so none of this is scraped from HTML:
//
//    * poll         — `post.polls` + `post.polls_votes`, rendered at the
//                     `<div class="poll">` position via a placeholder block.
//    * lottery      — `post.lottery`, appended after the body.
//    * red envelope — `topic.red_envelope`, a banner above the body.
//
//  The red envelope deliberately has no claim button: the plugin claims it
//  automatically in an `on(:post_created)` hook, so *replying* is the action.
//

import SwiftUI

// MARK: - Poll

struct PollView: View {
    let poll: PostPoll
    let myVotes: [String]
    let isBusy: Bool
    let onVote: ([String]) -> Void
    let onRemoveVote: () -> Void

    /// Staged selections for multi-choice polls, which submit as a batch.
    @State private var pending: Set<String> = []
    @State private var hasStagedEdits = false

    private var hasVoted: Bool { !myVotes.isEmpty }
    /// Discourse hides counts until the viewer is entitled to see them, which it
    /// signals by omitting `votes` from the options entirely.
    private var showsResults: Bool {
        poll.options?.contains { $0.votes != nil } ?? false
    }
    private var selection: Set<String> {
        hasStagedEdits ? pending : Set(myVotes)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            VStack(spacing: 8) {
                ForEach(poll.options ?? []) { option in
                    optionRow(option)
                }
            }

            footer
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Theme.divider, lineWidth: 1)
        }
        .onAppear { resetStaging() }
        // `.onAppear` doesn't re-fire when the parent hands down new votes, and
        // SwiftUI may reuse this view's state for a different poll, so staged
        // selections are re-seeded whenever the server truth changes.
        .onChange(of: myVotes) { _, _ in resetStaging() }
        .onChange(of: poll.pollName) { _, _ in resetStaging() }
    }

    private func resetStaging() {
        pending = Set(myVotes)
        hasStagedEdits = false
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image("LucideVote")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 14, height: 14)
                    .foregroundStyle(Theme.accent)
                Text(poll.title ?? "投票")
                    .font(Theme.body(15, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Spacer(minLength: 0)
                if poll.isClosed {
                    Text("已结束")
                        .font(Theme.body(11, weight: .semibold))
                        .foregroundStyle(Theme.muted(0.55))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Theme.hover, in: Capsule())
                }
            }

            if poll.isMultiple, let min = poll.min, let max = poll.max {
                Text("可选 \(min)–\(max) 项")
                    .font(Theme.body(11))
                    .foregroundStyle(Theme.muted(0.5))
            }
        }
    }

    private func optionRow(_ option: PollOptionResult) -> some View {
        let isSelected = selection.contains(option.id)
        let votes = option.votes ?? 0
        let total = max(1, poll.totalVotes)
        let fraction = showsResults ? Double(votes) / Double(total) : 0

        return Button {
            toggle(option.id)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Image(systemName: selectionSymbol(isSelected: isSelected))
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(isSelected ? Theme.accent : Theme.muted(0.35))

                    Text(option.html ?? "")
                        .font(Theme.body(14))
                        .foregroundStyle(Theme.text.opacity(0.9))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 6)

                    if showsResults {
                        Text("\(votes)")
                            .font(Theme.body(12, weight: .semibold))
                            .foregroundStyle(Theme.muted(0.6))
                            .monospacedDigit()
                    }
                }

                if showsResults {
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.hover)
                            Capsule()
                                .fill(Theme.accent.opacity(isSelected ? 0.75 : 0.4))
                                .frame(width: max(2, proxy.size.width * fraction))
                        }
                    }
                    .frame(height: 5)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isSelected ? Theme.accent.opacity(0.08) : Theme.bg.opacity(0.5),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .disabled(!canInteract)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text("\(poll.voters ?? poll.totalVotes) 人参与")
                .font(Theme.body(11))
                .foregroundStyle(Theme.muted(0.5))

            Spacer(minLength: 0)

            if isBusy {
                ProgressView().controlSize(.small)
            }

            // Multi-choice stages selections, so it needs an explicit submit.
            if poll.isMultiple, canInteract, hasStagedEdits {
                Button("提交") { submitPending() }
                    .font(Theme.body(12, weight: .semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accent)
            }

            if hasVoted, canInteract {
                Button("取消投票") { onRemoveVote() }
                    .font(Theme.body(12))
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.muted(0.55))
            }
        }
    }

    /// Ranked-choice and number polls have no UI here, so they render read-only
    /// rather than pretending a tap will register.
    private var canInteract: Bool {
        poll.isVotable && !poll.isClosed && !isBusy
    }

    private func selectionSymbol(isSelected: Bool) -> String {
        if poll.isMultiple {
            return isSelected ? "checkmark.square.fill" : "square"
        }
        return isSelected ? "largecircle.fill.circle" : "circle"
    }

    private func toggle(_ optionID: String) {
        guard canInteract else { return }
        if poll.isMultiple {
            var next = selection
            if next.contains(optionID) { next.remove(optionID) } else { next.insert(optionID) }
            pending = next
            hasStagedEdits = true
        } else {
            // Single choice submits immediately.
            hasStagedEdits = false
            onVote([optionID])
        }
    }

    private func submitPending() {
        hasStagedEdits = false
        onVote(Array(pending))
    }
}

// MARK: - Lottery

struct LotteryView: View {
    let lottery: PostLottery
    let isBusy: Bool
    let onParticipate: (Int, Bool) -> Void

    @State private var quantity = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            prizes

            if !(lottery.winners?.isEmpty ?? true) {
                winners
            }

            stats

            if lottery.isOpen {
                participation
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Theme.accent2.opacity(0.35), lineWidth: 1)
        }
    }

    private var header: some View {
        HStack(spacing: 7) {
            Image("LucideGift")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 15, height: 15)
                .foregroundStyle(Theme.accent2)

            Text(lottery.title ?? "抽奖")
                .font(Theme.body(15, weight: .semibold))
                .foregroundStyle(Theme.text)
                .lineLimit(2)

            Spacer(minLength: 0)

            Text(statusLabel)
                .font(Theme.body(11, weight: .semibold))
                .foregroundStyle(statusColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(statusColor.opacity(0.12), in: Capsule())
        }
    }

    private var prizes: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(lottery.levels ?? []) { level in
                HStack(spacing: 8) {
                    Text(level.name ?? "")
                        .font(Theme.body(11, weight: .bold))
                        .foregroundStyle(Theme.accent2)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Theme.accent2.opacity(0.12), in: Capsule())

                    Text(level.prize ?? "")
                        .font(Theme.body(13))
                        .foregroundStyle(Theme.text.opacity(0.85))
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    Text("×\(level.quantity ?? 1)")
                        .font(Theme.body(12, weight: .medium))
                        .foregroundStyle(Theme.muted(0.5))
                        .monospacedDigit()
                }
            }
        }
    }

    private var winners: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("中奖名单")
                .font(Theme.body(12, weight: .semibold))
                .foregroundStyle(Theme.muted(0.6))
            ForEach(Array((lottery.winners ?? []).enumerated()), id: \.offset) { _, winner in
                HStack(spacing: 6) {
                    Image(systemName: "rosette")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.accent2)
                    Text(winner.username ?? "")
                        .font(Theme.body(12, weight: .medium))
                        .foregroundStyle(Theme.text.opacity(0.85))
                    if let prize = winner.prize {
                        Text("· \(prize)")
                            .font(Theme.body(12))
                            .foregroundStyle(Theme.muted(0.5))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var stats: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 14) {
                statistic("\(lottery.participantsCount ?? 0)", label: "参与")
                statistic("\(lottery.ticketsCount ?? 0)", label: "总票数")
                if (lottery.userTickets ?? 0) > 0 {
                    statistic("\(lottery.userTickets ?? 0)", label: "我的票", highlighted: true)
                }
                Spacer(minLength: 0)
            }

            if let drawAt = lottery.drawAt {
                Text("开奖时间 \(DiscourseFormat.relative(drawAt))")
                    .font(Theme.body(11))
                    .foregroundStyle(Theme.muted(0.5))
            }
            if let minimum = lottery.minParticipants, (lottery.participantsCount ?? 0) < minimum {
                Text("满 \(minimum) 人开奖，不足则流抽并退还能量")
                    .font(Theme.body(11))
                    .foregroundStyle(Theme.muted(0.5))
            }
        }
    }

    private func statistic(_ value: String, label: String, highlighted: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(Theme.body(15, weight: .semibold))
                .foregroundStyle(highlighted ? Theme.accent2 : Theme.text)
                .monospacedDigit()
            Text(label)
                .font(Theme.body(10))
                .foregroundStyle(Theme.muted(0.45))
        }
    }

    private var participation: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider().overlay(Theme.divider)

            if remainingTickets <= 0 {
                // At the per-user cap: offering a stepper here would let the
                // user buy one more than allowed and get rejected server-side.
                Text("你已达到每人票数上限")
                    .font(Theme.body(12))
                    .foregroundStyle(Theme.muted(0.55))
            } else {
                HStack(spacing: 10) {
                    Stepper("\(quantity) 张", value: $quantity, in: 1...remainingTickets)
                        .font(Theme.body(13))
                        // Vertical only: `.fixedSize()` on both axes would let
                        // the label push the row past the screen.
                        .fixedSize(horizontal: false, vertical: true)
                        .layoutPriority(1)

                    Spacer(minLength: 0)

                    if isBusy {
                        ProgressView().controlSize(.small)
                    } else {
                        Button {
                            onParticipate(quantity, false)
                        } label: {
                            Text("参与")
                                .font(Theme.body(13, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 18)
                                .frame(height: 32)
                                .background(Theme.accent2, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }

                Text("每张票消耗 1 能量")
                    .font(Theme.body(10))
                    .foregroundStyle(Theme.muted(0.45))
            }
        }
        // Clamp if the cap shrinks under us after a purchase.
        .onChange(of: remainingTickets) { _, remaining in
            quantity = min(quantity, max(1, remaining))
        }
    }

    /// Tickets this user may still buy. Capped at 100 per action so the stepper
    /// stays usable when the server allows a very large per-user limit.
    private var remainingTickets: Int {
        let cap = lottery.maxTicketsPerUser ?? 10
        return min(cap - (lottery.userTickets ?? 0), 100)
    }

    private var statusLabel: String {
        switch lottery.status {
        case "open": "进行中"
        case "drawn": "已开奖"
        case "closed": "已关闭"
        case "failed": "已流抽"
        default: lottery.status ?? ""
        }
    }

    private var statusColor: Color {
        switch lottery.status {
        case "open": Theme.accent
        case "drawn": Theme.accent2
        case "failed": Theme.danger
        default: Theme.muted(0.55)
        }
    }
}

// MARK: - Red envelope

/// Status banner. Intentionally has no claim button — `discourse-red-envelope`
/// claims automatically from an `on(:post_created)` hook, so the way to open one
/// is to reply to the topic.
struct RedEnvelopeBanner: View {
    let envelope: TopicRedEnvelope

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image("LucideHandCoins")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 16, height: 16)
                    .foregroundStyle(.white)

                Text("红包")
                    .font(Theme.body(15, weight: .semibold))
                    .foregroundStyle(.white)

                Spacer(minLength: 0)

                Text(isExhausted ? "已抢完" : "进行中")
                    .font(Theme.body(11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.white.opacity(0.22), in: Capsule())
            }

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(envelope.totalPoints ?? 0)")
                    .font(Theme.heading(26, weight: .bold))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                Text("能量 · \(envelope.totalCount ?? 0) 个")
                    .font(Theme.body(12))
                    .foregroundStyle(.white.opacity(0.85))
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.25))
                    Capsule()
                        .fill(.white)
                        .frame(width: max(2, proxy.size.width * claimedFraction))
                }
            }
            .frame(height: 5)

            HStack {
                Text("已领 \(envelope.claimedCount ?? 0)/\(envelope.totalCount ?? 0)")
                    .font(Theme.body(11))
                    .foregroundStyle(.white.opacity(0.85))
                Spacer()
                Text("剩余 \(envelope.remainingPoints ?? 0) 能量")
                    .font(Theme.body(11))
                    .foregroundStyle(.white.opacity(0.85))
            }

            // The mechanic is non-obvious, so it's spelled out rather than
            // implied by a button that doesn't exist.
            if !isExhausted {
                Label("回复本帖即可领取", systemImage: "arrowshape.turn.up.left.fill")
                    .font(Theme.body(11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .background(.white.opacity(0.18), in: Capsule())
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [Color(hex: 0xE8452F), Color(hex: 0xC1121F)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
    }

    private var isExhausted: Bool {
        envelope.exhausted ?? ((envelope.availableCount ?? 0) <= 0)
    }

    private var claimedFraction: Double {
        guard let total = envelope.totalCount, total > 0 else { return 0 }
        return min(1, Double(envelope.claimedCount ?? 0) / Double(total))
    }
}
