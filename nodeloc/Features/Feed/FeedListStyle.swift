//
//  FeedListStyle.swift
//  nodeloc
//
//  The home feed's three list styles (design App-iOS-Feed / -FeedCompact /
//  -FeedCard), chosen in 设置 → 偏好 → 默认列表视图:
//
//  - 紧凑 — text only: the title, then one meta line (node, time, tag; votes
//    and replies on the right).
//  - 展开 — the default: node line, title beside a 96×72 thumbnail, bare
//    action bar. That row is `FeedTopicRowContent`.
//  - 卡片 — the card with large media: an image pager (or inline video) at
//    the media's own shape. That row is `PostCard` / `NodeTopicRow.cardRow`.
//
//  The home feed and the node pages share one choice (`NodeReadingModeStore`).
//

import SwiftUI

// MARK: - 紧凑

/// The 紧凑 row: a 16pt semibold title on two lines at most, then one 13pt
/// meta line — bold n/node, time, the first tag, the moderators' report count
/// — with "N 赞 · N 评论" on the right. No images, no avatars.
struct CompactTopicRow: View {
    @Environment(AppState.self) private var app
    let post: Post
    let onTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if post.pinned || app.isPinned(post) {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Theme.accent)
                        .accessibilityLabel(AppString("置顶"))
                }
                Text(post.title)
                    .font(Theme.body(16, weight: .semibold))
                    .lineSpacing(4)
                    .foregroundStyle(Theme.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            meta
        }
        .padding(.horizontal, 16)
        .padding(.top, 11)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.chip).frame(height: 1)
        }
    }

    private var meta: some View {
        HStack(spacing: 6) {
            Text(post.node)
                .font(Theme.body(13, weight: .semibold))
                .foregroundStyle(Theme.text)
                .layoutPriority(1)
            Text("· \(post.time)")
                .fixedSize()
            if let tag = post.tags.first {
                // Text only here (the 紧凑 meta line), in the tag's colour
                // when it has one.
                CompactTagText(name: tag)
                    .layoutPriority(-1)
            }
            if let reports = post.reportCount, reports > 0 {
                Text(AppString("\(reports) 人举报"))
                    .font(Theme.body(13, weight: .bold))
                    .foregroundStyle(Theme.modStripText)
                    .padding(.horizontal, 7)
                    .background(Theme.modStrip, in: Capsule())
                    .fixedSize()
            }
            Spacer(minLength: 6)
            Text(AppString("\(Self.count(app.voteCount(post))) 赞 · \(Self.count(post.comments)) 评论"))
                .monospacedDigit()
                .fixedSize()
        }
        .font(Theme.body(13))
        .foregroundStyle(Theme.textMuted)
        .lineLimit(1)
    }

    /// 1.2k above a thousand, the plain number below.
    static func count(_ value: Int) -> String {
        guard value >= 1000 else { return "\(value)" }
        let text = String(format: "%.1f", Double(value) / 1000)
        return (text.hasSuffix(".0") ? String(text.dropLast(2)) : text) + "k"
    }
}

/// "· tag" on the 紧凑 meta line, in the tag's own text colour if it has one.
private struct CompactTagText: View {
    let name: String
    @Environment(\.colorScheme) private var colorScheme
    private var store = TagLookStore.shared

    init(name: String) { self.name = name }

    var body: some View {
        let look = store.look(name)
        Text("· \(name)")
            .font(Theme.body(13, weight: .bold))
            .foregroundStyle(look.color == nil ? Theme.text : TagPalette(look: TagLook(color: look.color, style: "soft"), dark: colorScheme == .dark).ink)
    }
}
