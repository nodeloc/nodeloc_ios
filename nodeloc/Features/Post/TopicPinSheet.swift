//
//  TopicPinSheet.swift
//  nodeloc
//
//  置顶设置 for a topic: the three ways Discourse features one.
//

import SwiftUI

/// Discourse has three distinct featured modes, and the web's 置顶 modal is the
/// only place that shows them together:
///
/// - **节点内置顶** (`status: pinned`) tops the lists of its own node. Available
///   to staff *and* node moderators, via `details.can_pin_unpin_topic`.
/// - **全站置顶** (`status: pinned_globally`) tops every list. Staff only — no
///   server flag reports it, so the web reads `currentUser.canManageTopic` and
///   this sheet reads `DiscourseAuth.isStaff`.
/// - **横幅** (`make-banner`) floats above every page until each reader
///   dismisses it, gated by `details.can_banner_topic`, and only one exists
///   site-wide.
///
/// Both pins take an optional deadline, after which the server unpins on its
/// own, and any reader can clear a pin for themselves — a fourth state that is
/// not a permission at all.
struct TopicPinSheet: View {
    let topic: TopicStore

    @Environment(\.dismiss) private var dismiss
    @State private var nodeName: String?
    @State private var stats: TopicFeatureStats?
    @State private var scope: PinScope = .node
    @State private var hasDeadline = false
    @State private var deadline = Date().addingTimeInterval(7 * 24 * 3600)
    @State private var isBusy = false

    private enum PinScope: String, CaseIterable, Identifiable {
        case node, global
        var id: String { rawValue }
        var label: String { self == .node ? AppString("节点内置顶") : AppString("全站置顶") }
    }

    /// Only staff may pin globally; a node moderator gets the node pin alone.
    private var canPinGlobally: Bool {
        topic.canPinTopic && DiscourseAuth.shared.isStaff
    }

    private var nodeLabel: String { nodeName ?? AppString("本节点") }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if topic.isTopicPinned {
                        currentPinSection
                    } else if topic.canPinTopic {
                        pinOptionsSection
                    }

                    if topic.canBannerTopic {
                        Divider().overlay(Theme.divider)
                        bannerSection
                    }
                }
                .padding(20)
            }
            .scrollIndicators(.hidden)
            .background(Theme.bg)
            .navigationTitle("置顶设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .disabled(isBusy)
        }
        .standardSheet([.medium, .large])
        .task {
            // Counts are advisory; the node name only decorates the copy. Both
            // load after the sheet is already usable.
            if let id = topic.topicCategoryID {
                nodeName = await NodeCatalog.shared.node(id: id)?.name
            }
            stats = await topic.featureStats()
            scope = topic.isTopicPinnedGlobally && canPinGlobally ? .global : .node
        }
    }

    // MARK: Already pinned

    @ViewBuilder
    private var currentPinSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "pin.fill")
                    .font(.system(size: 13, weight: .semibold))
                Text(topic.isTopicPinnedGlobally ? AppString("已全站置顶") : AppString("已在 \(nodeLabel) 内置顶"))
                    .font(Theme.body(15, weight: .semibold))
            }
            .foregroundStyle(Theme.accent700)

            Text(
                topic.isTopicPinnedGlobally
                    ? AppString("本主题排在所有列表最上方，直到被取消置顶。")
                    : AppString("本主题排在 \(nodeLabel) 列表最上方；其它列表不受影响。")
            )
            .font(Theme.body(12))
            .foregroundStyle(Theme.muted(0.55))
            .fixedSize(horizontal: false, vertical: true)

            if let until = topic.topicPinnedUntil {
                Text("将于 \(until.formatted(date: .abbreviated, time: .shortened)) 自动取消置顶。")
                    .font(Theme.body(12))
                    .foregroundStyle(Theme.muted(0.55))
            }

            if let statsLine {
                Text(statsLine)
                    .font(Theme.body(12))
                    .foregroundStyle(Theme.muted(0.45))
            }

            if topic.canPinTopic {
                primaryButton(AppString("取消置顶"), systemImage: "pin.slash", tint: Theme.danger) {
                    await topic.unpinTopic()
                    dismiss()
                }

                // Switching scope is one call — the status name is what decides
                // `pinned_globally`, so there is no need to unpin first.
                if canPinGlobally {
                    secondaryButton(
                        topic.isTopicPinnedGlobally ? AppString("改为仅在 \(nodeLabel) 内置顶") : AppString("改为全站置顶")
                    ) {
                        await topic.pinTopic(
                            globally: !topic.isTopicPinnedGlobally,
                            until: topic.topicPinnedUntil
                        )
                        dismiss()
                    }
                }
            }

            // Anyone can dismiss a pin for themselves; it changes nothing for
            // anybody else.
            secondaryButton(topic.isPinClearedForMe ? AppString("恢复置顶（仅对我）") : AppString("对我取消置顶")) {
                await topic.setPinClearedForMe(!topic.isPinClearedForMe)
            }
        }
    }

    // MARK: Not pinned yet

    @ViewBuilder
    private var pinOptionsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            if canPinGlobally {
                Picker("范围", selection: $scope) {
                    ForEach(PinScope.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.segmented)
            }

            Text(
                scope == .global
                    ? AppString("置顶到所有列表的最上方。全站置顶会盖过节点置顶，通常只用于公告。")
                    : AppString("置顶到 \(nodeLabel) 列表的最上方。读者读完后可以自行取消置顶。")
            )
            .font(Theme.body(12))
            .foregroundStyle(Theme.muted(0.55))
            .fixedSize(horizontal: false, vertical: true)

            if let statsLine {
                Text(statsLine)
                    .font(Theme.body(12))
                    .foregroundStyle(Theme.muted(0.45))
            }

            Toggle(isOn: $hasDeadline) {
                Text("设置自动取消时间")
                    .font(Theme.body(14))
            }
            .tint(Theme.accent)

            if hasDeadline {
                DatePicker(
                    AppString("取消置顶时间"),
                    selection: $deadline,
                    in: Date()...,
                    displayedComponents: [.date, .hourAndMinute]
                )
                .font(Theme.body(14))
            }

            primaryButton(scope.label, systemImage: "pin.fill") {
                await topic.pinTopic(globally: scope == .global, until: hasDeadline ? deadline : nil)
                dismiss()
            }
        }
    }

    // MARK: Banner

    @ViewBuilder
    private var bannerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.topthird.inset.filled")
                    .font(.system(size: 13, weight: .semibold))
                Text("横幅主题")
                    .font(Theme.body(15, weight: .semibold))
            }
            .foregroundStyle(Theme.text)

            Text("横幅显示在每个页面的顶部，读者可以自行关闭。全站只能有一个横幅——设置新的会替换掉原来的。")
                .font(Theme.body(12))
                .foregroundStyle(Theme.muted(0.55))
                .fixedSize(horizontal: false, vertical: true)

            if let count = stats?.bannerCount {
                Text(count > 0 ? AppString("当前已有一个横幅主题。") : AppString("当前没有横幅主题。"))
                    .font(Theme.body(12))
                    .foregroundStyle(Theme.muted(0.45))
            }

            if topic.isTopicBanner {
                primaryButton(AppString("取消横幅"), systemImage: "rectangle.slash", tint: Theme.danger) {
                    await topic.toggleBanner()
                    dismiss()
                }
            } else {
                secondaryButton(AppString("设为横幅主题")) {
                    await topic.toggleBanner()
                    dismiss()
                }
            }
        }
    }

    // MARK: Pieces

    /// "N 个已置顶" for whichever scope is in view, straight from
    /// `/topics/feature_stats.json`.
    private var statsLine: String? {
        guard let stats else { return nil }
        let global = topic.isTopicPinned ? topic.isTopicPinnedGlobally : scope == .global
        if global {
            guard let count = stats.pinnedGloballyCount else { return nil }
            return count > 0 ? AppString("全站已有 \(count) 个置顶主题。") : AppString("全站目前没有置顶主题。")
        }
        guard let count = stats.pinnedInCategoryCount else { return nil }
        return count > 0 ? AppString("\(nodeLabel) 已有 \(count) 个置顶主题。") : AppString("\(nodeLabel) 目前没有置顶主题。")
    }

    private func primaryButton(
        _ title: String,
        systemImage: String,
        tint: Color = Theme.accent,
        action: @escaping () async -> Void
    ) -> some View {
        Button {
            run(action)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                Text(title)
                    .font(Theme.body(15, weight: .semibold))
            }
            .foregroundStyle(Theme.bg)
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(tint, in: Capsule())
        }
        .buttonStyle(.pressable)
    }

    private func secondaryButton(_ title: String, action: @escaping () async -> Void) -> some View {
        Button {
            run(action)
        } label: {
            Text(title)
                .font(Theme.body(14, weight: .semibold))
                .foregroundStyle(Theme.text)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(Theme.surface, in: Capsule())
        }
        .buttonStyle(.pressable)
    }

    private func run(_ action: @escaping () async -> Void) {
        isBusy = true
        Task {
            await action()
            isBusy = false
        }
    }
}
