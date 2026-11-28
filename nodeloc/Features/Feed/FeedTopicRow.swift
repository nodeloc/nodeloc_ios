//
//  FeedTopicRow.swift
//  nodeloc
//
//  The home feed's topic row (design App-iOS-Feed): a node line — node avatar,
//  n/slug, time, ⋯ — then a 17pt title beside a 96×72 thumbnail, a tag chip,
//  and a bare action bar of vote / replies / 转发 / 分享. The pieces are shared
//  with the card-mode `PostCard`, so both modes keep one header and one bar.
//

import SwiftUI

// MARK: - Node avatar

/// The node's own avatar, a 22pt circle: its logo, else its glyph on the node
/// colour, else the first letter on the accent. Reads the catalog's cache
/// synchronously so a scrolled-in row draws it on its first frame.
struct FeedNodeAvatar: View {
    let nodeLabel: String
    var size: CGFloat = 22

    @State private var node: SidebarNodeSummary?

    init(nodeLabel: String, size: CGFloat = 22) {
        self.nodeLabel = nodeLabel
        self.size = size
        _node = State(initialValue: NodeCatalog.shared.cachedNode(slug: nodeLabel))
    }

    var body: some View {
        Group {
            if let node {
                NodeAvatar(node: node, size: size, cornerRadius: size / 2)
            } else {
                Text(letter)
                    .font(Theme.body(size * 0.45, weight: .bold))
                    .foregroundStyle(Theme.onAccent)
                    .frame(width: size, height: size)
                    .background(Theme.accentFill, in: Circle())
            }
        }
        .accessibilityHidden(true)
        .task(id: nodeLabel) {
            guard node == nil || node.map({ "n/\($0.slug)" != nodeLabel }) == true else { return }
            node = await NodeCatalog.shared.node(slug: nodeLabel)
        }
    }

    private var letter: String {
        let slug = nodeLabel.hasPrefix("n/") ? String(nodeLabel.dropFirst(2)) : nodeLabel
        return String(slug.prefix(1)).uppercased()
    }
}

// MARK: - Header

/// Node avatar, n/slug, time, pin and state badges, then ⋯ at the trailing
/// edge. 24pt tall, 13pt type.
struct FeedRowHeader: View {
    @Environment(AppState.self) private var app
    let post: Post
    /// Whether the n/slug label opens the node. Off on that node's own page.
    var linksNode = true
    var showsUnreadDot = false
    let onMore: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            FeedNodeAvatar(nodeLabel: post.node)

            if showsUnreadDot {
                Circle()
                    .fill(Theme.accent)
                    .frame(width: 7, height: 7)
            }

            Text(post.node)
                .font(Theme.body(13, weight: .semibold))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(-1)
                .contentShape(Rectangle())
                .onTapGesture {
                    guard linksNode, let slug = post.linkedNodeSlug else { return }
                    app.openNode(slug: slug)
                }

            Text("· \(post.time)")
                .font(Theme.body(13))
                .foregroundStyle(Theme.textMuted)
                .lineLimit(1)
                .fixedSize()

            if post.pinned || app.isPinned(post) {
                Label(post.pinnedGlobally ? AppString("全站置顶") : AppString("置顶"), systemImage: "pin.fill")
                    .labelStyle(CompactLabelStyle())
                    .font(Theme.body(11, weight: .bold))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 7)
                    .frame(height: 20)
                    .background(Theme.pinnedCard, in: Capsule())
                    .fixedSize()
            }

            TopicStateBadges(isSolved: post.isSolved, isHidden: post.isHidden)

            Spacer(minLength: 0)

            Button(action: onMore) {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.textFaint)
                    .frame(width: 32, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.pressableIcon)
            .accessibilityLabel(AppString("更多"))
        }
        .frame(height: 24)
    }
}

// MARK: - Thumbnail

/// 96×72, 12pt corners, a hairline inset. Bottom-right badge: the image count
/// when there is more than one, a play mark for a video.
struct FeedRowThumbnail: View {
    let post: Post

    static let size = CGSize(width: 96, height: 72)

    @Environment(\.displayScale) private var displayScale

    /// Something to show at all.
    static func hasThumbnail(_ post: Post) -> Bool {
        post.media.first != nil || post.imageURL != nil || post.videoURL != nil
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        ZStack(alignment: .bottomTrailing) {
            if let url = imageURL {
                // A small variant, decoded at twice the tile's long edge at most:
                // enough for a wide image cropped to fill, never the original.
                CachedRemoteImage(url: url, maxPointSize: 160) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Theme.neutral300
                }
                .frame(width: Self.size.width, height: Self.size.height)
                .clipped()
            } else {
                Theme.neutral300
                    .frame(width: Self.size.width, height: Self.size.height)
            }

            if let badge {
                HStack(spacing: 3) {
                    Image(systemName: badge.symbol)
                        .font(.system(size: 9, weight: .bold))
                    if let text = badge.text {
                        Text(text)
                            .font(Theme.body(11, weight: .bold))
                            .monospacedDigit()
                    }
                }
                .foregroundStyle(.white)
                .padding(.leading, 5)
                .padding(.trailing, badge.text == nil ? 5 : 6)
                .frame(height: 18)
                .background(Color(hex: 0x0B1F18).opacity(0.78), in: Capsule())
                .padding(5)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipShape(shape)
        .overlay { shape.strokeBorder(Theme.text.opacity(0.06), lineWidth: 1) }
        .accessibilityHidden(true)
    }

    private var imageURL: URL? {
        if let media = post.media.first {
            return media.bestURL(forWidth: Self.size.width, scale: displayScale)
        }
        return post.imageURL
    }

    private var badge: (symbol: String, text: String?)? {
        if post.videoURL != nil { return ("play.fill", nil) }
        if post.media.count > 1 { return ("photo", "\(post.media.count)") }
        return nil
    }
}

// MARK: - Actions

/// The bare action bar: vote (128pt slot), replies (76), 转发 (40), 分享,
/// spread across the row at 44pt tall in the muted ink.
struct FeedRowActions: View {
    @Environment(AppState.self) private var app
    let post: Post
    let onComments: () -> Void
    /// Nil drops 转发 (the host can't present a composer).
    var onRepost: (() -> Void)?

    var body: some View {
        HStack(spacing: 0) {
            vote
                .frame(minWidth: 128, alignment: .leading)
            Spacer(minLength: 0)

            Button {
                // Lands in the reader with the reply panel open.
                if app.authed || DiscourseAuth.shared.isAuthenticated { app.pendingReplyFocus = true }
                onComments()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "bubble.left")
                        .font(.system(size: 17))
                    Text("\(post.comments)")
                        .font(Theme.body(14, weight: .semibold))
                        .monospacedDigit()
                }
                .frame(minWidth: 76, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            .accessibilityLabel(AppString("\(post.comments) 条评论"))
            Spacer(minLength: 0)

            if let onRepost {
                Button(action: onRepost) {
                    Image(systemName: "arrow.2.squarepath")
                        .font(.system(size: 17))
                        .frame(minWidth: 40, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
                .accessibilityLabel(AppString("转发"))
                Spacer(minLength: 0)
            }

            ShareLink(item: DiscourseConfig.baseURL.appending(path: "t/\(post.id)")) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 17))
                    .frame(minWidth: 32, minHeight: 44, alignment: .trailing)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            .accessibilityLabel(AppString("分享"))
        }
        .foregroundStyle(Theme.textMuted)
        .frame(height: 44)
        .padding(.trailing, 2)
    }

    @ViewBuilder
    private var vote: some View {
        if let score = app.voteScore(for: post) {
            VoteControl(
                score: score,
                direction: app.voteDirection(for: post),
                canVoteDown: post.canVoteDown,
                feedRow: true
            ) { direction, reaction in
                app.castVote(direction, on: post, reaction: reaction)
            }
        } else {
            // No vote data for this node: the like it always was.
            let liked = app.isLiked(post)
            Button { app.toggleLike(post) } label: {
                HStack(spacing: 8) {
                    Image(VoteControl.assetName(for: .up, filled: liked))
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 20, height: 20)
                        .frame(width: 22, height: 22)
                        .foregroundStyle(liked ? Theme.accent : Theme.textMuted)
                    Text("\(app.voteCount(post))")
                        .font(Theme.body(14, weight: .semibold))
                        .monospacedDigit()
                        .frame(minWidth: 30)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
        }
    }
}

// MARK: - Moderator strip

/// "N 人举报 · 去处理", shown only to readers who manage the node — the
/// server sends `report_count` to nobody else. Opens the topic.
struct FeedModStrip: View {
    let reportCount: Int
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 8) {
                Image(systemName: "flag")
                    .font(.system(size: 13, weight: .bold))
                Text(AppString("\(reportCount) 人举报 · 去处理"))
                    .font(Theme.body(13, weight: .bold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(AppString("仅版主可见"))
                    .font(Theme.body(12, weight: .medium))
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
            }
            .foregroundStyle(Theme.modStripText)
            .padding(.horizontal, 12)
            .frame(minHeight: 40)
            .background(Theme.modStrip, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
    }
}

// MARK: - Title + tag

/// 17pt semibold on a 24pt line, up to three lines, and the first tag as a
/// grey chip under it.
struct FeedRowTitle: View {
    let post: Post

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(post.title)
                .font(Theme.heading(17, weight: .semibold))
                .lineSpacing(3)
                .foregroundStyle(Theme.text)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                // Vertical-only: a long unbroken title must not widen the row.
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let tag = post.tags.first {
                // The tag's own look (colour, style, icon), as the web.
                TagLookChip(name: tag, size: .row)
            }
        }
    }
}

// MARK: - The row

/// One topic in the design's feed layout. Not a Button: the inner controls
/// (votes, replies, ⋯) must keep their own taps — see `NodeTopicRow.body`.
struct FeedTopicRowContent: View {
    let post: Post
    var linksNode = true
    var showsUnreadDot = false
    let onTap: () -> Void
    let onMore: () -> Void
    var onRepost: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FeedRowHeader(post: post, linksNode: linksNode, showsUnreadDot: showsUnreadDot, onMore: onMore)

            HStack(alignment: .top, spacing: 12) {
                FeedRowTitle(post: post)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if FeedRowThumbnail.hasThumbnail(post) {
                    FeedRowThumbnail(post: post)
                }
            }
            .padding(.top, 4)

            FeedRowActions(post: post, onComments: onTap, onRepost: onRepost)
                .padding(.top, 2)

            if let reports = post.reportCount, reports > 0 {
                FeedModStrip(reportCount: reports, onOpen: onTap)
                    .padding(.bottom, 12)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.chip).frame(height: 1)
        }
    }
}

/// The skeleton for `FeedTopicRowContent`, same metrics.
struct FeedTopicRowSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Circle().fill(Theme.neutral300).frame(width: 22, height: 22)
                SkeletonLine(widthFraction: 0.35)
            }
            .frame(height: 24)
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 9) {
                    SkeletonLine(widthFraction: 1, height: 15)
                    SkeletonLine(widthFraction: 0.65, height: 15)
                }
                .padding(.top, 4)
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Theme.neutral300)
                    .frame(width: 96, height: 72)
            }
            .padding(.top, 4)
            HStack {
                Capsule().fill(Theme.neutral300).frame(width: 96, height: 14)
                Spacer()
                Capsule().fill(Theme.neutral300).frame(width: 40, height: 14)
                Spacer()
                Capsule().fill(Theme.neutral300).frame(width: 18, height: 14)
                Spacer()
                Capsule().fill(Theme.neutral300).frame(width: 18, height: 14)
            }
            .frame(height: 44)
            .padding(.top, 2)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.chip).frame(height: 1)
        }
    }
}
