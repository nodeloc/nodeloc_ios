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
//    * lottery      — `post.lottery`, appended after the body (LotteryCard.swift).
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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Staged selections, sent with 投票 (single or multiple).
    @State private var pending: Set<String> = []
    @State private var hasStagedEdits = false
    /// Each bar's drawn share, animated toward the poll's.
    @State private var shown: [String: Double] = [:]

    private var hasVoted: Bool { !myVotes.isEmpty }
    /// The server leaves `votes` out until the reader may see them.
    private var showsResults: Bool {
        poll.options?.contains { $0.votes != nil } ?? false
    }
    private var selection: Set<String> {
        hasStagedEdits ? pending : Set(myVotes)
    }
    private var leaderVotes: Int {
        poll.options?.compactMap(\.votes).max() ?? 0
    }
    /// The shares, keyed by option, that the bars animate to.
    private var targets: [String: Double] {
        let total = Double(max(1, poll.totalVotes))
        var out: [String: Double] = [:]
        for option in poll.options ?? [] {
            out[option.id] = showsResults ? Double(option.votes ?? 0) / total : 0
        }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            VStack(spacing: 8) {
                ForEach(Array((poll.options ?? []).enumerated()), id: \.element.id) { index, option in
                    optionRow(option)
                }
            }

            footer
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.bg, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Theme.divider, lineWidth: 1)
        }
        .sensoryFeedback(.selection, trigger: pending)
        .sensoryFeedback(.success, trigger: myVotes) { old, new in !new.isEmpty && old != new }
        .onAppear {
            resetStaging()
            animateBars(from: [:])
        }
        // Re-seeded whenever the server truth changes (the view may be
        // reused for another poll).
        .onChange(of: myVotes) { _, _ in resetStaging() }
        .onChange(of: poll.pollName) { _, _ in resetStaging() }
        .onChange(of: targets) { old, _ in animateBars(from: old) }
    }

    private func resetStaging() {
        pending = Set(myVotes)
        hasStagedEdits = false
    }

    /// Bars grow from where they were (zero the first time) to their share,
    /// a row at a time; with Reduce Motion they are simply there.
    private func animateBars(from old: [String: Double]) {
        let goal = targets
        guard !reduceMotion else { shown = goal; return }
        for (index, option) in (poll.options ?? []).enumerated() {
            if shown[option.id] == nil { shown[option.id] = old[option.id] ?? 0 }
            withAnimation(.smooth(duration: 0.7).delay(Double(index) * 0.07)) {
                shown[option.id] = goal[option.id] ?? 0
            }
        }
    }

    /// 投票 · 单选, who took part and when it closes, and whether it's open.
    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "chart.bar")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 40, height: 40)
                .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(headline)
                    .font(Theme.body(16, weight: .bold))
                    .foregroundStyle(Theme.text)
                Text(subline)
                    .font(Theme.body(12))
                    .foregroundStyle(Theme.textMuted)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            Text(poll.isClosed ? AppString("已结束") : AppString("进行中"))
                .font(Theme.body(12, weight: .bold))
                .foregroundStyle(poll.isClosed ? Theme.textMuted : Theme.accent)
                .padding(.horizontal, 9)
                .frame(height: 24)
                .background(poll.isClosed ? Theme.chip : Theme.accent.opacity(0.12), in: Capsule())
        }
    }

    private var headline: String {
        let kind = poll.isMultiple ? AppString("多选") : AppString("单选")
        if let title = poll.title, !title.isEmpty { return "\(title) · \(kind)" }
        return AppString("投票 · \(kind)")
    }

    /// 312 人参与 · 11 月 21 日 20:00 结束（还有 3 天）
    private var subline: String {
        var parts = [AppString("\(poll.voters ?? poll.totalVotes) 人参与")]
        if let close = DiscourseFormat.date(poll.close) {
            let when = close.formatted(.dateTime.month().day().hour().minute().locale(AppLanguage.resolved.locale))
            if poll.isClosed || close < Date() {
                parts.append(AppString("\(when) 结束"))
            } else {
                let days = Int(ceil(close.timeIntervalSinceNow / 86_400))
                parts.append(AppString("\(when) 结束（还有 \(days) 天）"))
            }
        }
        if poll.isMultiple, let min = poll.min, let max = poll.max {
            parts.append(AppString("可选 \(min)–\(max) 项"))
        }
        return parts.joined(separator: " · ")
    }

    private func optionRow(_ option: PollOptionResult) -> some View {
        let isSelected = selection.contains(option.id)
        let isMine = myVotes.contains(option.id) && !hasStagedEdits
        let votes = option.votes ?? 0
        let isLeader = showsResults && votes > 0 && votes == leaderVotes
        let share = targets[option.id] ?? 0
        let drawn = shown[option.id] ?? 0
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)

        return Button {
            toggle(option.id)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: selectionSymbol(isSelected: isSelected))
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(isSelected ? Theme.accent : Theme.textFaint)
                    .contentTransition(.symbolEffect(.replace))
                HStack(spacing: 6) {
                    Text(option.html ?? "")
                        .font(Theme.body(15, weight: isLeader ? .semibold : .medium))
                        .foregroundStyle(Theme.text)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                    if isMine && showsResults {
                        tag(AppString("我的选择"), text: .white, fill: Theme.accent)
                    }
                    if isLeader {
                        tag(AppString("最高票"), text: AdminTone.amber.text, fill: AdminTone.amber.fill)
                    }
                }
                Spacer(minLength: 6)
                // Always laid out, so the row keeps its height and its text
                // its width when the results appear.
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(verbatim: "\(Int((share * 100).rounded()))%")
                        .font(Theme.body(14, weight: .bold))
                        .foregroundStyle(Theme.text)
                        .contentTransition(.numericText(value: share))
                    Text(AppString("\(votes) 票"))
                        .font(Theme.body(12))
                        .foregroundStyle(Theme.textMuted)
                        .contentTransition(.numericText(value: Double(votes)))
                }
                .monospacedDigit()
                .opacity(showsResults ? 1 : 0)
                .animation(reduceMotion ? nil : .smooth(duration: 0.6), value: share)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 46)
            .frame(maxWidth: .infinity, alignment: .leading)
            // The bar: the share of the votes, behind the row's text.
            .background(alignment: .leading) {
                GeometryReader { proxy in
                    Rectangle()
                        .fill(barColor(isMine: isMine, isLeader: isLeader))
                        .frame(width: proxy.size.width * drawn)
                }
            }
            .background(Theme.surface)
            .clipShape(shape)
            .overlay(shape.strokeBorder(isSelected ? Theme.accent : Theme.divider, lineWidth: isSelected ? 1.5 : 1))
            .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: isSelected)
        }
        .buttonStyle(.pressable)
        .disabled(!canInteract)
        .accessibilityValue(showsResults ? AppString("\(Int((share * 100).rounded()))%，\(votes) 票") : "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func barColor(isMine: Bool, isLeader: Bool) -> Color {
        if isMine { return Theme.accent.opacity(0.24) }
        if isLeader { return Theme.accent.opacity(0.16) }
        return Theme.accent.opacity(0.09)
    }

    private func tag(_ title: String, text: Color, fill: Color) -> some View {
        Text(title)
            .font(Theme.body(11, weight: .bold))
            .foregroundStyle(text)
            .padding(.horizontal, 6)
            .frame(height: 18)
            .background(fill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .fixedSize()
            .transition(.scale(scale: 0.8).combined(with: .opacity))
    }

    // MARK: Footer

    /// Within the poll's limits (a single poll: exactly one).
    private var stagedIsValid: Bool {
        let count = pending.count
        if poll.isMultiple {
            let low = max(1, poll.min ?? 1)
            let high = poll.max ?? Int.max
            return (low...max(low, high)).contains(count)
        }
        return count == 1
    }

    @ViewBuilder
    private var hint: some View {
        if canInteract, !hasVoted || hasStagedEdits {
            if poll.isMultiple, let min = poll.min, let max = poll.max {
                Text(AppString("已选 \(pending.count) 项 · 可选 \(min)–\(max) 项"))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            } else {
                Text(AppString("选好后点「投票」，投票后可以看到结果"))
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            hint
                .font(Theme.body(12))
                .foregroundStyle(Theme.textMuted)
            if canInteract || isBusy {
                HStack(spacing: 10) {
                    if hasVoted {
                        Button(AppString("取消投票")) { onRemoveVote() }
                            .buttonStyle(.bordered)
                            .tint(.primary)
                    }
                    Button {
                        submitPending()
                    } label: {
                        ZStack {
                            Text(hasVoted ? AppString("修改投票") : AppString("投票")).opacity(isBusy ? 0 : 1)
                            if isBusy { ProgressView().controlSize(.small).tint(.white) }
                        }
                        .fontWeight(.bold)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .disabled(!(hasStagedEdits && stagedIsValid) || isBusy)
                }
                .buttonBorderShape(.capsule)
                .controlSize(.regular)
                .disabled(isBusy)
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
        return isSelected ? "checkmark.circle.fill" : "circle"
    }

    private func toggle(_ optionID: String) {
        guard canInteract else { return }
        var next = selection
        if poll.isMultiple {
            if next.contains(optionID) {
                next.remove(optionID)
            } else if let max = poll.max, next.count >= max {
                return
            } else {
                next.insert(optionID)
            }
        } else {
            next = [optionID]
        }
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.22)) {
            pending = next
            hasStagedEdits = next != Set(myVotes)
        }
    }

    private func submitPending() {
        // Staging stays until the store's (optimistic) votes arrive, so the
        // selection never flickers back to the old choice.
        onVote(Array(pending))
    }
}

// MARK: - Lottery

// `LotteryView` lives in LotteryCard.swift.

// MARK: - Red envelope

/// Status banner. Intentionally has no claim button — `discourse-red-envelope`
/// claims automatically from an `on(:post_created)` hook, so the way to open one
/// is to reply to the topic.
struct RedEnvelopeBanner: View {
    let envelope: TopicRedEnvelope
    /// 回帖后领取: there is no claim endpoint — a reply claims it — so the
    /// button opens the reply panel.
    var onReply: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(AppString("回帖的人各领一份，金额随机"))
                .font(Theme.body(14))
                .foregroundStyle(.white.opacity(0.9))

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(envelope.totalPoints ?? 0)")
                    .font(Theme.heading(36, weight: .bold))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                Text(AppString("能量 · \(envelope.totalCount ?? 0) 份"))
                    .font(Theme.body(17, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer(minLength: 0)
                if isExhausted {
                    Text(AppString("已领完"))
                        .font(Theme.body(12, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9)
                        .frame(height: 24)
                        .background(.white.opacity(0.22), in: Capsule())
                }
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.28))
                    Capsule()
                        .fill(.white)
                        .frame(width: max(2, proxy.size.width * claimedFraction))
                }
            }
            .frame(height: 6)

            Text(AppString("已领 \(envelope.claimedCount ?? 0) / \(envelope.totalCount ?? 0) 份 · 剩余 \(envelope.remainingPoints ?? 0) 能量 · 领到的金额显示在每条回复上"))
                .font(Theme.body(12))
                .foregroundStyle(.white.opacity(0.88))
                .fixedSize(horizontal: false, vertical: true)

            if !isExhausted, let onReply {
                Button(action: onReply) {
                    Text(AppString("回帖后领取"))
                        .font(Theme.body(16, weight: .bold))
                        .foregroundStyle(Color(hex: 0xC2410C))
                        .padding(.horizontal, 20)
                        .frame(height: 48)
                        .background(.white, in: Capsule())
                }
                .buttonStyle(.pressable)
                .padding(.top, 4)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [Color(hex: 0xC2410C), Color(hex: 0xEA580C)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
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
