//
//  ReviewQueuePage.swift
//  nodeloc
//
//  审核队列 — the site-wide queue for staff, and a node's own queue for its
//  owner and moderators. Both endpoints answer the same shape, so one page
//  serves both and only the scope differs.
//
//  Two things are deliberately the server's call rather than this page's:
//
//  - How much reputation this reader may take in one go arrives as
//    `reputationPenaltyMax` (1000 with the site-wide permission, 20 for
//    someone who is only a node's owner or moderator). Hard-coding either
//    would produce a picker whose top entries always 422.
//  - Whether an item can be acted on at all: `ownAction` marks an appeal
//    against the reader's own penalty, which only a site administrator may
//    settle.
//

import SwiftUI

@MainActor
@Observable
final class ReviewQueueStore {
    private let client = DiscourseClient()

    let scope: DiscourseClient.ReviewScope

    private(set) var items: [NLReviewQueue.Item] = []
    private(set) var counts: [String: Int] = [:]
    /// What this reader may take per decision. Nil until the first load, and
    /// 0 would mean "may not deduct at all".
    private(set) var reputationPenaltyMax: Int?
    private(set) var isLoading = false
    private(set) var errorText: String?
    var status = "pending"
    private var nextBefore: Int?

    init(scope: DiscourseClient.ReviewScope) {
        self.scope = scope
    }

    func load(status: String? = nil) async {
        if let status, status != self.status {
            self.status = status
            items = []
        }
        isLoading = items.isEmpty
        errorText = nil
        defer { isLoading = false }
        do {
            let queue = try await client.reviewQueue(scope, status: self.status)
            items = queue.items
            counts = queue.counts ?? [:]
            reputationPenaltyMax = queue.reputationPenaltyMax
            nextBefore = queue.nextBefore
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func loadMore() async {
        guard let before = nextBefore, !isLoading else { return }
        guard let queue = try? await client.reviewQueue(scope, status: status, before: before) else { return }
        items += queue.items
        nextBefore = queue.nextBefore
    }

    /// Settles an item and drops it from the list — it no longer belongs under
    /// the current filter.
    func resolve(
        _ item: NLReviewQueue.Item,
        action: String,
        note: String? = nil,
        reputationPenalty: Int? = nil
    ) async {
        do {
            try await client.resolveReviewItem(
                scope, id: item.id, action: action, note: note, reputationPenalty: reputationPenalty
            )
            items.removeAll { $0.id == item.id }
            ToastCenter.shared.show(AppString("已处理"))
        } catch {
            ToastCenter.shared.showError(error)
        }
    }

    /// Returns reputation without touching the decision or the post.
    func refundReputation(_ item: NLReviewQueue.Item) async {
        do {
            let refunded = try await client.refundReviewReputation(scope, id: item.id)
            ToastCenter.shared.show(AppString("已返还 \(refunded) 声望"))
            await load()
        } catch {
            ToastCenter.shared.showError(error)
        }
    }
}

struct ReviewQueuePage: View {
    let onClose: () -> Void

    @State private var store: ReviewQueueStore
    @State private var penaltyTarget: NLReviewQueue.Item?

    init(scope: DiscourseClient.ReviewScope, onClose: @escaping () -> Void) {
        self.onClose = onClose
        _store = State(initialValue: ReviewQueueStore(scope: scope))
    }

    private let statuses = ["pending", "resolved", "rejected"]

    var body: some View {
        VStack(spacing: 0) {
            SettingsPageHeader(title: AppString("审核队列"), onClose: onClose)

            statusPicker

            ScrollView {
                LazyVStack(spacing: 12) {
                    if store.isLoading, store.items.isEmpty {
                        ProgressView().tint(Theme.accent).padding(.vertical, 44)
                    } else if let errorText = store.errorText, store.items.isEmpty {
                        Text(errorText)
                            .font(Theme.body(13))
                            .foregroundStyle(Theme.muted(0.55))
                            .padding(.vertical, 44)
                    } else if store.items.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "checkmark.circle")
                                .font(.system(size: 28, weight: .semibold))
                                .foregroundStyle(Theme.success)
                            Text(AppString("没有待处理的项"))
                                .font(Theme.body(14))
                                .foregroundStyle(Theme.muted(0.55))
                        }
                        .padding(.vertical, 56)
                    } else {
                        ForEach(store.items) { item in
                            card(item)
                        }
                        Color.clear.frame(height: 1)
                            .onAppear { Task { await store.loadMore() } }
                    }
                }
                .padding(16)
            }
        }
        .background(Theme.bg)
        .task { await store.load() }
        .sheet(item: $penaltyTarget) { item in
            ReputationPenaltySheet(
                maximum: store.reputationPenaltyMax ?? 0,
                onConfirm: { penalty, note in
                    await store.resolve(item, action: "delete_post", note: note, reputationPenalty: penalty)
                }
            )
        }
    }

    private var statusPicker: some View {
        HStack(spacing: 8) {
            ForEach(statuses, id: \.self) { value in
                Button {
                    Task { await store.load(status: value) }
                } label: {
                    HStack(spacing: 4) {
                        Text(statusTitle(value))
                        if let count = store.counts[value], count > 0 {
                            Text("\(count)")
                                .font(Theme.body(10, weight: .semibold))
                        }
                    }
                    .font(Theme.body(13, weight: store.status == value ? .semibold : .regular))
                    .foregroundStyle(store.status == value ? Theme.accent700 : Theme.muted(0.5))
                    .padding(.vertical, 6)
                    .padding(.horizontal, 12)
                    .background(
                        store.status == value ? Theme.accent.opacity(0.12) : Color.clear,
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

    private func statusTitle(_ value: String) -> String {
        switch value {
        case "resolved": AppString("已成立")
        case "rejected": AppString("不成立")
        default: AppString("待处理")
        }
    }

    private func card(_ item: NLReviewQueue.Item) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Text(kindTitle(item.kind))
                    .font(Theme.body(13, weight: .semibold))
                    .foregroundStyle(Theme.text)
                if item.priority == true {
                    Text(AppString("优先"))
                        .font(Theme.body(10, weight: .semibold))
                        .foregroundStyle(Theme.danger)
                        .padding(.vertical, 2)
                        .padding(.horizontal, 6)
                        .background(Theme.danger.opacity(0.1), in: Capsule())
                }
                Spacer(minLength: 0)
                if let created = item.createdAt {
                    Text(DiscourseFormat.relative(created))
                        .font(Theme.body(11))
                        .foregroundStyle(Theme.muted(0.4))
                }
            }

            if let title = item.topicTitle, !title.isEmpty {
                Text(title)
                    .font(Theme.body(13))
                    .foregroundStyle(Theme.text.opacity(0.85))
                    .lineLimit(2)
            }

            // Why it was held: the sentence, plus the words it matched when
            // the filter is what caught it.
            if let reason = item.payload?["reason"]?.string, !reason.isEmpty {
                Text(reason)
                    .font(Theme.body(12))
                    .foregroundStyle(Theme.muted(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }
            // A content appeal carries the author's own words.
            if let text = item.payload?["text"]?.string, !text.isEmpty {
                Text(text)
                    .font(Theme.body(12))
                    .foregroundStyle(Theme.text.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let author = item.author {
                authorLine(author, username: item.targetUsername)
            }

            if let reports = item.reports, !reports.isEmpty {
                ForEach(Array(reports.enumerated()), id: \.offset) { _, report in
                    HStack(spacing: 6) {
                        Image(systemName: "flag")
                            .font(.system(size: 9))
                        Text(report.reasonLabel ?? report.reason ?? "")
                        if let note = report.note, !note.isEmpty {
                            Text("· \(note)").lineLimit(1)
                        }
                    }
                    .font(Theme.body(11))
                    .foregroundStyle(Theme.muted(0.5))
                }
            }

            actions(item)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// The author's record, so a decision isn't made on one post alone. Inside
    /// a node's queue these three numbers only count that node.
    private func authorLine(_ author: NLReviewQueue.Author, username: String?) -> some View {
        HStack(spacing: 8) {
            if let username { Text("@\(username)") }
            if let tier = author.tierName { Text("· \(tier)") }
            if let posts = author.posts { Text(AppString("· \(posts) 帖")) }
            if let deleted = author.deletedPosts, deleted > 0 {
                Text(AppString("· 被删 \(deleted)")).foregroundStyle(Theme.danger.opacity(0.8))
            }
            if let reported = author.timesReported, reported > 0 {
                Text(AppString("· 被举报 \(reported)")).foregroundStyle(Theme.danger.opacity(0.8))
            }
            Spacer(minLength: 0)
        }
        .font(Theme.body(11))
        .foregroundStyle(Theme.muted(0.5))
    }

    @ViewBuilder
    private func actions(_ item: NLReviewQueue.Item) -> some View {
        // An appeal against this reader's own penalty: only a site admin may
        // settle it, and the server answers 403 to anyone else.
        if item.ownAction == true {
            Text(AppString("这是对你自己做出的处罚的申诉，需要其他管理人员处理"))
                .font(Theme.body(11))
                .foregroundStyle(Theme.muted(0.5))
        } else if store.status == "pending" {
            HStack(spacing: 8) {
                ForEach(availableActions(for: item.kind), id: \.0) { action, title, destructive in
                    Button {
                        // Deleting is the one decision that may also cost
                        // reputation, so it goes through the sheet.
                        if action == "delete_post" {
                            penaltyTarget = item
                        } else {
                            Task { await store.resolve(item, action: action) }
                        }
                    } label: {
                        Text(title)
                            .font(Theme.body(12, weight: .semibold))
                            .foregroundStyle(destructive ? Theme.danger : Theme.accent700)
                            .padding(.vertical, 6)
                            .padding(.horizontal, 12)
                            .background(
                                (destructive ? Theme.danger : Theme.accent).opacity(0.1),
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.pressable)
                }
                Spacer(minLength: 0)
            }
        } else if item.payload?["reputation_penalty"]?.int ?? 0 > 0,
                  item.payload?["reputation_refunded"]?.int ?? 0 == 0 {
            // Settled against the author and the reputation is still taken.
            Button {
                Task { await store.refundReputation(item) }
            } label: {
                Text(AppString("只返还声望"))
                    .font(Theme.body(12, weight: .semibold))
                    .foregroundStyle(Theme.accent700)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 12)
                    .background(Theme.accent.opacity(0.1), in: Capsule())
            }
            .buttonStyle(.pressable)
        }
    }

    /// Which decisions this kind of item accepts. Appeals are upheld or not;
    /// everything else is founded or not.
    private func availableActions(for kind: String) -> [(String, String, Bool)] {
        switch kind {
        case "content_appeal":
            [("restore", AppString("恢复内容"), false),
             ("uphold", AppString("维持原处理"), true),
             ("ignore", AppString("忽略"), false)]
        case "penalty_appeal", "node_restriction_appeal":
            [("lift", AppString("解除处罚"), false),
             ("uphold", AppString("维持原处罚"), true),
             ("ignore", AppString("忽略"), false)]
        case "pending_post":
            [("approve", AppString("通过"), false),
             ("delete_post", AppString("删除"), true)]
        default:
            [("delete_post", AppString("删除"), true),
             ("hide_post", AppString("隐藏"), true),
             ("reject", AppString("不成立"), false)]
        }
    }

    private func kindTitle(_ kind: String) -> String {
        switch kind {
        case "pending_post": AppString("待审帖子")
        case "content_appeal": AppString("内容申诉")
        case "penalty_appeal": AppString("处罚申诉")
        case "node_restriction_appeal": AppString("节点处罚申诉")
        case "risk_flag": AppString("风控")
        default: AppString("举报")
        }
    }
}

/// Deleting through the queue may also cost the author reputation. The cap
/// comes from the queue response — the reader's own standing decides it — and
/// "don't deduct" is the default.
struct ReputationPenaltySheet: View {
    let maximum: Int
    let onConfirm: (Int?, String?) async -> Void

    @State private var penalty = 0
    @State private var note = ""
    @State private var isSubmitting = false
    @Environment(\.dismiss) private var dismiss

    /// The web's presets, minus any the reader's cap puts out of reach.
    private var presets: [Int] { [5, 10, 20, 50, 100].filter { $0 <= maximum } }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Text(AppString("处理理由"))
                    .font(Theme.body(12, weight: .semibold))
                    .foregroundStyle(Theme.muted(0.55))
                TextField(AppString("可选"), text: $note)
                    .font(Theme.body(14))
                    .padding(10)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                if maximum > 0 {
                    Text(AppString("扣除声望（最多 \(maximum)）"))
                        .font(Theme.body(12, weight: .semibold))
                        .foregroundStyle(Theme.muted(0.55))
                    HStack(spacing: 8) {
                        chip(AppString("不扣"), value: 0)
                        ForEach(presets, id: \.self) { value in
                            chip("\(value)", value: value)
                        }
                        Spacer(minLength: 0)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(16)
            .background(Theme.bg)
            .navigationTitle(AppString("删除"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppString("取消")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSubmitting {
                        ProgressView().controlSize(.small)
                    } else {
                        Button(AppString("确定")) {
                            Task {
                                isSubmitting = true
                                await onConfirm(
                                    penalty > 0 ? penalty : nil,
                                    note.isEmpty ? nil : note
                                )
                                isSubmitting = false
                                dismiss()
                            }
                        }
                    }
                }
            }
        }
    }

    private func chip(_ title: String, value: Int) -> some View {
        Button { penalty = value } label: {
            Text(title)
                .font(Theme.body(12, weight: penalty == value ? .semibold : .regular))
                .foregroundStyle(penalty == value ? Theme.accent700 : Theme.muted(0.5))
                .padding(.vertical, 6)
                .padding(.horizontal, 12)
                .background(
                    penalty == value ? Theme.accent.opacity(0.12) : Theme.surface,
                    in: Capsule()
                )
        }
        .buttonStyle(.pressable)
    }
}
