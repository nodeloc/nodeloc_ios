//
//  TopicModSheet.swift
//  nodeloc
//
//  版主操作 (App-iOS-PostMod, "处理收成一项"): the topic's switches — pin,
//  lock, 精华, move — in one native sheet, and every removal or penalty
//  folded into a single 处理帖子和作者… that opens the handling dialog.
//
//  Who sees what follows the server: pin and lock for anyone who manages the
//  node (`details.can_moderate`); 精华 and move need `topics.curate`, which
//  only staff hold, so a node moderator doesn't see them at all.
//

import SwiftUI

/// The reasons the move endpoint accepts (content/manage.go `moveReasons`).
enum TopicMoveReason: String, CaseIterable, Identifiable {
    case wrongNode = "wrong_node"
    case duplicate
    case promotion
    case violation
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .wrongNode: AppString("分类错误")
        case .duplicate: AppString("重复")
        case .promotion: AppString("推广")
        case .violation: AppString("违规")
        case .other: AppString("其他")
        }
    }
}

struct TopicModSheet: View {
    let topic: TopicStore
    let title: String
    let nodeSlug: String?
    let author: String?
    /// 置顶… for a topic that isn't pinned: the existing pin sheet.
    let onPin: () -> Void
    /// 处理帖子和作者… on the first post: the handling dialog.
    let onModerate: () -> Void

    @Environment(\.dismiss) private var dismiss

    private var isStaff: Bool { DiscourseAuth.shared.isStaff }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    header
                }

                if topic.canPinTopic || topic.canCloseTopic || isStaff {
                    Section {
                        if topic.canPinTopic {
                            pinRow
                        }
                        if topic.canCloseTopic {
                            Toggle(isOn: Binding(
                                get: { topic.isTopicClosed },
                                set: { on in if on != topic.isTopicClosed { Task { await topic.toggleClosed() } } }
                            )) {
                                Label(AppString("锁定回复"), systemImage: "lock")
                            }
                        }
                        if isStaff {
                            Toggle(isOn: Binding(
                                get: { topic.isTopicFeatured },
                                set: { on in Task { await topic.setFeatured(on) } }
                            )) {
                                Label(AppString("设为精华"), systemImage: "star")
                            }
                            NavigationLink {
                                TopicMoveForm(topic: topic, currentSlug: nodeSlug) { dismiss() }
                            } label: {
                                Label(AppString("移动到其他节点"), systemImage: "folder")
                            }
                        }
                    }
                }

                Section {
                    Button {
                        dismiss()
                        onModerate()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "checkmark.shield")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(AdminTone.orange.text)
                                .frame(width: 26)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(AppString("处理帖子和作者…"))
                                    .foregroundStyle(AdminTone.orange.text)
                                Text(AppString("删除或隐藏、禁言或封禁、扣声望，一次做完"))
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } footer: {
                    Text(AppString("所有操作都会写入操作日志，作者会收到带原因的通知，可以申诉。"))
                }
            }
            .navigationTitle(AppString("版主操作"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(AppString("完成")) { dismiss() }
                }
            }
        }
        .tint(Theme.accent)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline)
                .lineLimit(2)
            Text(subtitle)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    /// n/indie · 林见川 · 你是这个节点的版主
    private var subtitle: String {
        let role = isStaff ? AppString("你是全站管理人员") : AppString("你是这个节点的版主")
        return [nodeSlug.map { "n/\($0)" }, author, role]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// Pinned: one tap takes it down, the state on the right. Not pinned: the
    /// pin sheet, which asks where and for how long.
    @ViewBuilder
    private var pinRow: some View {
        if topic.isTopicPinned {
            Button {
                Task { await topic.unpinTopic() }
            } label: {
                LabeledContent {
                    Text(AppString("已置顶"))
                } label: {
                    Label(AppString("取消置顶"), systemImage: "pin.slash")
                        .foregroundStyle(Theme.text)
                }
            }
        } else {
            Button {
                dismiss()
                onPin()
            } label: {
                LabeledContent {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.tertiary)
                } label: {
                    Label(AppString("置顶…"), systemImage: "pin")
                        .foregroundStyle(Theme.text)
                }
            }
        }
    }
}

/// 移动到其他节点: where, why, and a note the author is sent with it.
struct TopicMoveForm: View {
    let topic: TopicStore
    let currentSlug: String?
    let onMoved: () -> Void

    @State private var store = ComposeStore()
    @State private var target: SidebarNodeSummary?
    @State private var reason: TopicMoveReason = .wrongNode
    @State private var note = ""
    @State private var choosingNode = false
    @State private var isMoving = false

    private var canMove: Bool {
        guard let slug = target?.slug, !slug.isEmpty else { return false }
        return slug != currentSlug && !isMoving
    }

    var body: some View {
        Form {
            Section {
                Button {
                    choosingNode = true
                } label: {
                    LabeledContent {
                        Text(target.map { "n/\($0.slug)" } ?? AppString("选择节点"))
                    } label: {
                        Text(AppString("移到"))
                            .foregroundStyle(Theme.text)
                    }
                }
            } footer: {
                if let currentSlug {
                    Text(AppString("现在在 n/\(currentSlug)"))
                }
            }

            Section(AppString("原因")) {
                Picker(AppString("原因"), selection: $reason) {
                    ForEach(TopicMoveReason.allCases) { reason in
                        Text(reason.title).tag(reason)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }

            Section {
                TextField(AppString("说明（可选）"), text: $note, axis: .vertical)
                    .lineLimit(2...5)
            } footer: {
                Text(AppString("作者会收到带原因的通知。"))
            }
        }
        .navigationTitle(AppString("移动到其他节点"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            PrimaryToolbarAction(title: AppString("移动"), isEnabled: canMove, isWorking: isMoving) {
                guard let slug = target?.slug else { return }
                isMoving = true
                Task {
                    defer { isMoving = false }
                    if await topic.move(toNode: slug, reason: reason.rawValue, note: note) { onMoved() }
                }
            }
        }
        .sheet(isPresented: $choosingNode) {
            ComposeNodePicker(store: store, selection: $target, title: AppString("移到"))
        }
    }
}
