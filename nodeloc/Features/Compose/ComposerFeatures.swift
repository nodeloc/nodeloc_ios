//
//  ComposerFeatures.swift
//  nodeloc
//
//  Poll and red-envelope composition.
//
//  These two work very differently on the server, and the difference drives the
//  design here:
//
//  * A **poll** is pure markup. The composer emits a `[poll …]` block that
//    Discourse's markdown pipeline parses when the post is cooked, so it ships
//    with the post body and needs no extra request.
//
//  * A **red envelope** is a separate database record. The web client posts to
//    `/red-envelopes.json` with the *topic id* only after the topic exists
//    (`addModelCallback("post", "afterCreate")` in the plugin's
//    red-envelope-topic-creation.js). So it is a strict two-step flow, and the
//    second step can fail on its own.
//

import SwiftUI

// MARK: - Poll

/// Mirrors the option set in poll-ui-builder.gjs.
nonisolated enum PollKind: String, Sendable, CaseIterable, Identifiable {
    case regular
    case multiple
    case number

    var id: String { rawValue }

    var label: String {
        switch self {
        case .regular: AppString("单选")
        case .multiple: AppString("多选")
        case .number: AppString("评分")
        }
    }
}

nonisolated enum PollResultVisibility: String, Sendable, CaseIterable, Identifiable {
    case always
    case onVote = "on_vote"
    case onClose = "on_close"
    case staffOnly = "staff_only"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .always: AppString("始终公开")
        case .onVote: AppString("投票后可见")
        case .onClose: AppString("结束后可见")
        case .staffOnly: AppString("仅管理员")
        }
    }
}

/// How long the poll stays open. The markup always carries an absolute
/// `close=<ISO8601>`; the duration is only a way to pick one.
nonisolated enum PollDuration: Int, Sendable, CaseIterable, Identifiable {
    case never = 0
    case oneDay = 1
    case threeDays = 3
    case sevenDays = 7
    case thirtyDays = 30

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .never: AppString("不自动结束")
        case .oneDay: AppString("1 天")
        case .threeDays: AppString("3 天")
        case .sevenDays: AppString("7 天")
        case .thirtyDays: AppString("30 天")
        }
    }

    func closeDate(from now: Date) -> Date? {
        guard self != .never else { return nil }
        return Calendar.current.date(byAdding: .day, value: rawValue, to: now)
    }
}

nonisolated struct PollOption: Identifiable, Sendable, Equatable {
    let id: UUID
    var text: String

    init(id: UUID = UUID(), text: String = "") {
        self.id = id
        self.text = text
    }
}

/// Everything the poll card collects. `markup` reproduces the exact string the
/// web builder produces so the server parses it identically.
nonisolated struct PollDraft: Sendable, Equatable {
    var kind: PollKind = .regular
    var results: PollResultVisibility = .always
    var isPublic = true
    var duration: PollDuration = .threeDays
    var title = ""
    var options: [PollOption] = [PollOption(), PollOption()]
    /// Only meaningful for `.multiple`.
    var minChoices = 1
    var maxChoices = 2

    var filledOptions: [String] {
        options
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Nil when the poll is ready to post; otherwise the reason it isn't.
    /// Mirrors the builder's validations in poll-ui-builder.gjs.
    func validationError(maximumOptions: Int) -> String? {
        let filled = filledOptions
        if filled.count < 1 {
            return AppString("投票至少需要一个选项。")
        }
        if filled.count > maximumOptions {
            return AppString("投票最多 \(maximumOptions) 个选项。")
        }
        if Set(filled).count != filled.count {
            return AppString("选项不能重复。")
        }
        if kind == .multiple {
            if minChoices < 1 { return AppString("最少可选数至少为 1。") }
            if maxChoices > filled.count { return AppString("最多可选数不能超过选项数量。") }
            if minChoices > maxChoices { return AppString("最少可选数不能大于最多可选数。") }
        }
        return nil
    }

    /// Byte-for-byte the shape produced by `pollOutput` in poll-ui-builder.gjs.
    func markup(now: Date = Date()) -> String {
        var header = "[poll"
        header += " type=\(kind.rawValue)"
        header += " results=\(results.rawValue)"

        if kind != .regular {
            header += " min=\(minChoices)"
            header += " max=\(maxChoices)"
        }
        header += " public=\(isPublic ? "true" : "false")"
        if kind != .number {
            header += " chartType=bar"
        }
        if let close = duration.closeDate(from: now) {
            header += " close=\(Self.iso8601.string(from: close))"
        }
        header += "]"

        var output = header + "\n"
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty {
            output += "# \(trimmedTitle)\n"
        }
        if kind != .number {
            for option in filledOptions {
                output += "* \(option)\n"
            }
        }
        output += "[/poll]\n"
        return output
    }

    /// `Date.toISOString()` in JS — always UTC with milliseconds.
    static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()
}

// MARK: - Red envelope

/// Not markup — this is posted to `/red-envelopes.json` once the topic exists.
nonisolated struct RedEnvelopeDraft: Sendable, Equatable {
    var totalPoints = ""
    var totalCount = ""

    var points: Int? { Int(totalPoints.trimmingCharacters(in: .whitespaces)) }
    var count: Int? { Int(totalCount.trimmingCharacters(in: .whitespaces)) }

    /// Mirrors `isValid`/`errorMessage` in red-envelope-composer.gjs and the
    /// server-side checks in red_envelope_service.rb.
    func validationError(limits: RedEnvelopeLimits, userPoints: Int?) -> String? {
        guard let points, let count else { return AppString("请填写能量总数和红包个数。") }
        if points <= 0 || count <= 0 { return AppString("能量和个数必须大于 0。") }
        if count < limits.minCount || count > limits.maxCount {
            return AppString("红包个数需在 \(limits.minCount)–\(limits.maxCount) 之间。")
        }
        if points < limits.minPoints {
            return AppString("红包总能量至少 \(limits.minPoints)。")
        }
        if points < count {
            return AppString("总能量不能少于红包个数。")
        }
        if points < count * limits.minAveragePoints {
            return AppString("每个红包平均至少 \(limits.minAveragePoints) 能量，当前需要 \(count * limits.minAveragePoints)。")
        }
        if let userPoints, points > userPoints {
            return AppString("你的能量不足（当前 \(userPoints)）。")
        }
        return nil
    }
}

/// Server-configured bounds. Defaults match the plugin's settings.yml so the UI
/// still behaves sanely if the settings aren't readable.
nonisolated struct RedEnvelopeLimits: Sendable, Equatable {
    var minPoints = 10
    var minAveragePoints = 10
    var minCount = 1
    var maxCount = 100

    static let `default` = RedEnvelopeLimits()
}

// MARK: - Lottery

/// One prize tier. `quantity` is how many winners draw this prize.
nonisolated struct LotteryLevel: Identifiable, Sendable, Equatable {
    let id: UUID
    var name: String
    var prize: String
    var quantity: Int

    init(id: UUID = UUID(), name: String = "", prize: String = "", quantity: Int = 1) {
        self.id = id
        self.name = name
        self.prize = prize
        self.quantity = quantity
    }

    var isComplete: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !prize.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

/// Like the red envelope, a lottery is a server-side record rather than markup —
/// but it hangs off the **post**, not the topic.
nonisolated struct LotteryDraft: Sendable, Equatable {
    var title = ""
    var minParticipants = 5
    /// Empty means unlimited; the server turns 0 into 1_000_000.
    var maxParticipants = ""
    var maxTicketsPerUser = 10
    var minTrustLevel = 1
    var drawAt: Date?
    var levels: [LotteryLevel] = [LotteryLevel()]

    var completeLevels: [LotteryLevel] { levels.filter(\.isComplete) }

    var parsedMaxParticipants: Int? {
        let trimmed = maxParticipants.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let value = Int(trimmed), value > 0 else { return nil }
        return value
    }

    /// Mirrors `disableSave` + the validation getters in lottery-ui-builder.gjs.
    func validationError(limits: LotteryLimits, now: Date = Date()) -> String? {
        if title.trimmingCharacters(in: .whitespaces).isEmpty {
            return AppString("请填写抽奖标题。")
        }
        if minParticipants < 1 {
            return AppString("最少参与人数至少为 1。")
        }
        if let max = parsedMaxParticipants, minParticipants >= max {
            return AppString("最少参与人数必须小于最多参与人数。")
        }
        if maxTicketsPerUser < 1 {
            return AppString("每人最多票数至少为 1。")
        }
        guard let drawAt else {
            return AppString("请选择开奖时间。")
        }
        if drawAt <= now {
            return AppString("开奖时间必须晚于现在。")
        }
        if limits.maxDrawDays > 0,
           let latest = Calendar.current.date(byAdding: .day, value: limits.maxDrawDays, to: now),
           drawAt > latest {
            return AppString("开奖时间最多为 \(limits.maxDrawDays) 天后。")
        }
        if completeLevels.isEmpty {
            return AppString("至少需要一个完整的奖项（名称和奖品）。")
        }
        return nil
    }

    /// The JSON body `lottery_controller#create` permits.
    func payload(postID: Int) -> LotteryCreatePayload {
        LotteryCreatePayload(
            post_id: postID,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            min_participants: minParticipants,
            // The builder sends 0 for unlimited and the controller maps it to
            // 1_000_000; sending nothing would fail the model's presence check.
            max_participants: parsedMaxParticipants ?? 0,
            max_tickets_per_user: maxTicketsPerUser,
            min_trust_level: minTrustLevel,
            draw_at: drawAt.map { PollDraft.iso8601.string(from: $0) },
            levels: completeLevels.map {
                LotteryLevelPayload(
                    name: $0.name.trimmingCharacters(in: .whitespaces),
                    prize: $0.prize.trimmingCharacters(in: .whitespaces),
                    quantity: max(1, $0.quantity)
                )
            }
        )
    }
}

/// Snake-cased to match the controller's permitted params verbatim.
nonisolated struct LotteryCreatePayload: Encodable, Sendable {
    let post_id: Int
    let title: String
    let min_participants: Int
    let max_participants: Int
    let max_tickets_per_user: Int
    let min_trust_level: Int
    let draw_at: String?
    let levels: [LotteryLevelPayload]
}

nonisolated struct LotteryLevelPayload: Encodable, Sendable {
    let name: String
    let prize: String
    let quantity: Int
}

nonisolated struct LotteryLimits: Sendable, Equatable {
    var minTrustLevel = 1
    var minTicketsPerUser = 1
    var maxTicketsPerUser = 10
    var maxDrawDays = 30

    static let `default` = LotteryLimits()
}

// MARK: - Poll card

/// The inline poll editor shown above the body, matching the web composer's
/// card: duration menu in the header, reorderable options, and a close button.
struct PollComposerCard: View {
    @Binding var draft: PollDraft
    let maximumOptions: Int
    let onRemove: () -> Void

    @FocusState private var focusedOption: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            VStack(spacing: 8) {
                ForEach($draft.options) { $option in
                    optionRow($option)
                }

                if draft.options.count < maximumOptions {
                    addOptionRow
                }
            }

            if draft.kind == .multiple {
                multipleChoiceRow
            }

            // Held back until something is typed — a freshly added poll is
            // always "empty", and flagging that immediately reads as an error
            // the user caused.
            if !draft.filledOptions.isEmpty,
               let error = draft.validationError(maximumOptions: maximumOptions) {
                Text(error)
                    .font(Theme.body(12, weight: .medium))
                    .foregroundStyle(Theme.danger)
            }
        }
        .padding(14)
        .background(Theme.bg, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Theme.divider, lineWidth: 1.2)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Menu {
                Picker("类型", selection: $draft.kind) {
                    ForEach(PollKind.allCases) { Text($0.label).tag($0) }
                }
                Picker("结果", selection: $draft.results) {
                    ForEach(PollResultVisibility.allCases) { Text($0.label).tag($0) }
                }
                Picker("结束时间", selection: $draft.duration) {
                    ForEach(PollDuration.allCases) { Text($0.label).tag($0) }
                }
                Toggle("公开投票人", isOn: $draft.isPublic)
            } label: {
                HStack(spacing: 4) {
                    Text(draft.duration == .never ? AppString("投票不自动结束") : AppString("投票结束于 \(draft.duration.label)"))
                        .font(Theme.body(14, weight: .medium))
                        .foregroundStyle(Theme.text)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.muted(0.6))
                }
            }

            Spacer(minLength: 8)

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(Theme.muted(0.45), in: Circle())
            }
            .buttonStyle(.pressable)
        }
    }

    private func optionRow(_ option: Binding<PollOption>) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.muted(0.4))

            TextField("选项", text: option.text)
                .font(Theme.body(14))
                .foregroundStyle(Theme.text)
                .focused($focusedOption, equals: option.wrappedValue.id)

            if draft.options.count > 1 {
                Button {
                    draft.options.removeAll { $0.id == option.wrappedValue.id }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.muted(0.5))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.pressable)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var addOptionRow: some View {
        Button {
            let option = PollOption()
            draft.options.append(option)
            focusedOption = option.id
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                Text("添加选项")
                    .font(Theme.body(14))
                Spacer()
            }
            .foregroundStyle(Theme.muted(0.62))
            .padding(.horizontal, 10)
            .frame(height: 38)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.pressable)
    }

    private var multipleChoiceRow: some View {
        HStack(spacing: 10) {
            Text("可选数量")
                .font(Theme.body(13))
                .foregroundStyle(Theme.muted(0.62))
            Spacer(minLength: 8)
            // Stacked rather than side by side: two steppers plus their labels
            // exceed a narrow screen, and `.fixedSize()` on both would force
            // the row wider than the composer.
            VStack(alignment: .trailing, spacing: 4) {
                Stepper(
                    AppString("最少 \(draft.minChoices)"),
                    value: $draft.minChoices,
                    in: 1...max(1, draft.filledOptions.count)
                )
                Stepper(
                    AppString("最多 \(draft.maxChoices)"),
                    value: $draft.maxChoices,
                    in: 1...max(1, draft.filledOptions.count)
                )
            }
            .font(Theme.body(13))
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Red envelope sheet

struct RedEnvelopeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var draft: RedEnvelopeDraft
    let limits: RedEnvelopeLimits
    let userPoints: Int?
    /// Nil clears an already-attached envelope.
    let onConfirm: (RedEnvelopeDraft?) -> Void

    @State private var working = RedEnvelopeDraft()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("能量总数") {
                        TextField("0", text: $working.totalPoints)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("红包个数") {
                        TextField("0", text: $working.totalCount)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        if let userPoints {
                            Text("当前能量 \(userPoints)")
                        }
                        Text("每个红包平均至少 \(limits.minAveragePoints) 能量，个数 \(limits.minCount)–\(limits.maxCount)。")
                        Text("红包会在帖子发布后创建。")
                    }
                }

                if let error = working.validationError(limits: limits, userPoints: userPoints) {
                    Section {
                        Text(error)
                            .font(Theme.body(13, weight: .medium))
                            .foregroundStyle(Theme.danger)
                    }
                }
            }
            .navigationTitle("红包")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("添加") {
                        draft = working
                        onConfirm(working)
                        dismiss()
                    }
                    .disabled(working.validationError(limits: limits, userPoints: userPoints) != nil)
                }
                if draft.points != nil {
                    ToolbarItem(placement: .destructiveAction) {
                        Button("移除", role: .destructive) {
                            onConfirm(nil)
                            dismiss()
                        }
                    }
                }
            }
            .onAppear { working = draft }
        }
        .presentationDetents([.medium])
    }
}

/// Compact summary shown in the composer once an envelope is attached.
struct RedEnvelopeChip: View {
    let draft: RedEnvelopeDraft
    let onTap: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "yensign.circle.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.danger)

            VStack(alignment: .leading, spacing: 2) {
                Text("红包 \(draft.totalPoints) 能量 · \(draft.totalCount) 个")
                    .font(Theme.body(14, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text("发布后自动创建")
                    .font(Theme.body(11))
                    .foregroundStyle(Theme.muted(0.58))
            }

            Spacer(minLength: 8)

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.muted(0.6))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.pressable)
        }
        .padding(12)
        .background(Theme.bg, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Theme.divider, lineWidth: 1.2)
        }
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture(perform: onTap)
    }
}

// MARK: - Lottery sheet

struct LotterySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var draft: LotteryDraft
    let limits: LotteryLimits
    let trustLevels: [Int: String]
    /// Nil clears an already-attached lottery.
    let onConfirm: (LotteryDraft?) -> Void

    @State private var working = LotteryDraft()
    private let isAttached: Bool

    init(
        draft: Binding<LotteryDraft>,
        limits: LotteryLimits,
        trustLevels: [Int: String],
        isAttached: Bool,
        onConfirm: @escaping (LotteryDraft?) -> Void
    ) {
        _draft = draft
        self.limits = limits
        self.trustLevels = trustLevels
        self.isAttached = isAttached
        self.onConfirm = onConfirm
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("基本") {
                    LabeledContent("标题") {
                        TextField("抽奖标题", text: $working.title)
                            .multilineTextAlignment(.trailing)
                    }
                    DatePicker(
                        AppString("开奖时间"),
                        selection: Binding(
                            get: { working.drawAt ?? defaultDrawDate },
                            set: { working.drawAt = $0 }
                        ),
                        in: Date()...maximumDrawDate,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                }

                Section {
                    Stepper("最少参与人数 \(working.minParticipants)", value: $working.minParticipants, in: 1...100_000)
                    LabeledContent("最多参与人数") {
                        TextField("不限", text: $working.maxParticipants)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                    }
                    Stepper(
                        AppString("每人最多 \(working.maxTicketsPerUser) 票"),
                        value: $working.maxTicketsPerUser,
                        in: limits.minTicketsPerUser...max(limits.minTicketsPerUser, limits.maxTicketsPerUser)
                    )
                    Picker("参与门槛", selection: $working.minTrustLevel) {
                        ForEach(trustLevels.keys.sorted(), id: \.self) { level in
                            Text(trustLevels[level] ?? "TL\(level)").tag(level)
                        }
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("参与者每张票消耗 1 能量，开奖后归发起人。人数不足会流抽并原路退还。")
                        // Guideline 5.3.2: the rules have to be reachable in the
                        // app, and the prize limit is what keeps this a points
                        // game rather than a raffle with real-world stakes.
                        Text("奖品仅限站内虚拟物品（能量、徽章、头衔等），不得为现金、实物或可兑换站外权益的物品。")
                        LotteryRulesLink()
                    }
                }

                Section("奖项") {
                    ForEach($working.levels) { $level in
                        levelRow($level)
                    }
                    Button {
                        working.levels.append(LotteryLevel())
                    } label: {
                        Label("添加奖项", systemImage: "plus")
                    }
                }

                if let error = working.validationError(limits: limits) {
                    Section {
                        Text(error)
                            .font(Theme.body(13, weight: .medium))
                            .foregroundStyle(Theme.danger)
                    }
                }

                Section {
                    Text("抽奖会在帖子发布后创建。")
                        .font(Theme.body(12))
                        .foregroundStyle(Theme.muted(0.6))
                }
            }
            .navigationTitle("抽奖")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("添加") {
                        draft = working
                        onConfirm(working)
                        dismiss()
                    }
                    .disabled(working.validationError(limits: limits) != nil)
                }
                if isAttached {
                    ToolbarItem(placement: .destructiveAction) {
                        Button("移除", role: .destructive) {
                            onConfirm(nil)
                            dismiss()
                        }
                    }
                }
            }
            .onAppear {
                working = draft
                if working.drawAt == nil { working.drawAt = defaultDrawDate }
                if working.minTrustLevel == 1, limits.minTrustLevel != 1 {
                    working.minTrustLevel = limits.minTrustLevel
                }
            }
        }
    }

    private func levelRow(_ level: Binding<LotteryLevel>) -> some View {
        VStack(spacing: 6) {
            HStack {
                TextField("等级名，如 一等奖", text: level.name)
                if working.levels.count > 1 {
                    Button {
                        working.levels.removeAll { $0.id == level.wrappedValue.id }
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(Theme.danger)
                    }
                    .buttonStyle(.pressable)
                }
            }
            TextField("奖品（限站内虚拟物品）", text: level.prize)
            Stepper("数量 \(level.wrappedValue.quantity)", value: level.quantity, in: 1...10_000)
        }
        .font(Theme.body(14))
    }

    private var defaultDrawDate: Date {
        Calendar.current.date(byAdding: .day, value: 3, to: Date()) ?? Date()
    }

    private var maximumDrawDate: Date {
        let days = limits.maxDrawDays > 0 ? limits.maxDrawDays : 365
        return Calendar.current.date(byAdding: .day, value: days, to: Date()) ?? Date()
    }
}

/// Compact summary shown in the composer once a lottery is attached.
struct LotteryChip: View {
    let draft: LotteryDraft
    let onTap: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "gift.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.accent2)

            VStack(alignment: .leading, spacing: 2) {
                Text(draft.title.isEmpty ? AppString("抽奖") : draft.title)
                    .font(Theme.body(14, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Text(summary)
                    .font(Theme.body(11))
                    .foregroundStyle(Theme.muted(0.58))
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.muted(0.6))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.pressable)
        }
        .padding(12)
        .background(Theme.bg, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Theme.divider, lineWidth: 1.2)
        }
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture(perform: onTap)
    }

    private var summary: String {
        let prizes = draft.completeLevels.reduce(0) { $0 + max(1, $1.quantity) }
        var parts = [AppString("\(draft.completeLevels.count) 个奖项 · \(prizes) 份奖品")]
        if let drawAt = draft.drawAt {
            parts.append(Self.dateFormat.string(from: drawAt) + AppString(" 开奖"))
        }
        return parts.joined(separator: " · ")
    }

    /// Deliberately not a `static let`: a cached formatter would freeze the
    /// language at whichever one was current the first time it was touched, and
    /// the interface language can change while the app is running.
    private static var dateFormat: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = AppLanguage.resolved.locale
        formatter.setLocalizedDateFormatFromTemplate("MdHm")
        return formatter
    }
}

#Preview("投票卡片") {
    @Previewable @State var draft = PollDraft()
    return VStack {
        PollComposerCard(draft: $draft, maximumOptions: 20, onRemove: {})
    }
    .padding(20)
    .background(Theme.bg)
}

#Preview("抽奖卡片") {
    var d = LotteryDraft()
    d.title = AppString("抽 5 台小鸡")
    d.drawAt = Date().addingTimeInterval(86_400 * 3)
    d.levels = [
        LotteryLevel(name: AppString("一等奖"), prize: "1H1G VPS", quantity: 2),
        LotteryLevel(name: AppString("二等奖"), prize: "512M VPS", quantity: 8),
    ]
    return VStack {
        LotteryChip(draft: d, onTap: {}, onRemove: {})
    }
    .padding(20)
    .background(Theme.bg)
}

#Preview("红包卡片") {
    var d = RedEnvelopeDraft()
    d.totalPoints = "500"
    d.totalCount = "10"
    return VStack {
        RedEnvelopeChip(draft: d, onTap: {}, onRemove: {})
    }
    .padding(20)
    .background(Theme.bg)
}
