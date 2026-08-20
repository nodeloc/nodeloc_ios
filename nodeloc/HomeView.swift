//
//  HomeView.swift
//  nodeloc
//

import SwiftUI

struct HomeView: View {
    @Environment(AppState.self) private var app
    let postTransitionNamespace: Namespace.ID
    @State private var feed = FeedStore()
    @State private var lastOffset: CGFloat = 0
    @State private var headerHiddenAmount: CGFloat = 0

    var body: some View {
        ZStack(alignment: .top) {
            // Feed
            ScrollView {
                LazyVStack(spacing: 0) {
                    Color.clear.frame(height: headerHeight)
                    if feed.posts.isEmpty && feed.isLoading {
                        ProgressView()
                            .tint(Theme.accent)
                            .padding(.top, 40)
                    }
                    ForEach(feed.posts) { post in
                        PostCard(post: post, postTransitionNamespace: postTransitionNamespace)
                    }
                }
                .padding(.bottom, 100)
            }
            .scrollIndicators(.hidden)
            .refreshable { await feed.load() }
            .task { await feed.loadIfNeeded() }
            .onScrollGeometryChange(for: CGFloat.self) { geo in
                geo.contentOffset.y
            } action: { _, newValue in
                handleScroll(newValue)
            }

            if app.overlay != .post {
                persistentHeaderButtons
            }
        }
    }

    private let headerHeight: CGFloat = 56
    private let quickRevealThreshold: CGFloat = 14

    // MARK: Scroll → collapse behaviour

    private func handleScroll(_ top: CGFloat) {
        let last = lastOffset
        lastOffset = top
        let delta = top - last

        if top <= 0 {
            revealHeader(animated: true)
            return
        }

        if delta > 0 {
            headerHiddenAmount = min(headerHeight, max(0, headerHiddenAmount + delta))
            if headerHiddenAmount >= headerHeight, top > 32, !app.navCollapsed {
                withAnimation(.spring(duration: 0.3)) { app.navCollapsed = true }
            }
        } else if delta < 0 {
            let pullDistance = abs(delta)
            if pullDistance >= quickRevealThreshold {
                revealHeader(animated: true)
            } else if top < headerHeight {
                headerHiddenAmount = min(headerHiddenAmount, max(0, top))
                if headerHiddenAmount == 0, app.navCollapsed {
                    withAnimation(.spring(duration: 0.3)) { app.navCollapsed = false }
                }
            }
        }
    }

    private func revealHeader(animated: Bool) {
        let changes = {
            headerHiddenAmount = 0
            app.navCollapsed = false
        }

        if animated {
            withAnimation(.spring(duration: 0.26)) { changes() }
        } else {
            changes()
        }
    }

    // MARK: Header

    private var persistentHeaderButtons: some View {
        HStack {
            Button { app.overlay = .sidebar } label: {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.headerText)
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.glass(.regular.tint(Theme.bg.opacity(0.34))))
            .buttonBorderShape(.circle)
            .shadow(color: .black.opacity(0.08), radius: 9, y: 6)

            Spacer()

            Button {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
                    app.overlay = .compose
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.glass(.regular.tint(Theme.accent.opacity(0.14))))
            .buttonBorderShape(.circle)
            .shadow(color: .black.opacity(0.08), radius: 9, y: 6)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

}

// MARK: - Post card

struct PostCard: View {
    @Environment(AppState.self) private var app
    let post: Post
    let postTransitionNamespace: Namespace.ID
    @State private var selectedMediaIndex = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            postHeader
            postBody
            mediaPreview
            actionRow
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.bg)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.divider).frame(height: 1)
        }
        .matchedGeometryEffect(
            id: postTransitionID(post.id),
            in: postTransitionNamespace,
            properties: .frame,
            anchor: .center,
            isSource: app.overlay != .post || app.selectedPost.id != post.id
        )
        .contentShape(Rectangle())
        .onTapGesture {
            app.selectedPost = post
            withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) {
                app.overlay = .post
            }
        }
    }

    private var postHeader: some View {
        HStack(spacing: 7) {
            RemoteAvatar(
                url: post.avatarURL,
                letter: post.avatarLetter,
                variant: post.variant,
                size: 26
            )

            Text(post.node)
                .font(Theme.body(12, weight: .semibold))
                .foregroundStyle(Theme.text)
                .lineLimit(1)

            Text("· \(post.time)")
                .font(Theme.body(11))
                .foregroundStyle(Theme.muted(0.46))
                .lineLimit(1)

            if app.isPinned(post) {
                Label("Pinned", systemImage: "pin.fill")
                    .labelStyle(CompactLabelStyle())
                    .font(Theme.body(10, weight: .semibold))
                    .foregroundStyle(Theme.accent700)
                    .padding(.vertical, 3)
                    .padding(.horizontal, 7)
                    .background(Theme.accent.opacity(0.1), in: Capsule())
            }

            Spacer(minLength: 0)

            Button {} label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.muted(0.4))
                    .frame(width: 30, height: 26)
            }
            .buttonStyle(.plain)
        }
    }

    private var postBody: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(post.title)
                .font(Theme.heading(16, weight: .semibold))
                .foregroundStyle(Theme.text)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)

            if !post.excerpt.isEmpty {
                Text(post.excerpt)
                    .font(Theme.body(13))
                    .lineSpacing(3)
                    .foregroundStyle(Theme.text.opacity(0.72))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var mediaPreview: some View {
        if !mediaItems.isEmpty {
            FeedMediaCarousel(items: mediaItems, selection: $selectedMediaIndex)
            .padding(.top, 2)
        } else if post.hasImage {
            ImagePlaceholder()
                .frame(height: FeedMediaCarousel.defaultHeight)
                .padding(.top, 2)
        }
    }

    private var actionRow: some View {
        HStack(spacing: 8) {
            Button {
                app.toggleLike(post)
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(app.isLiked(post) ? Theme.accent : Theme.muted(0.5))
                    Text("\(app.voteCount(post))")
                        .font(Theme.body(12, weight: .semibold))
                        .foregroundStyle(Theme.text.opacity(0.74))
                    Rectangle()
                        .fill(Theme.divider)
                        .frame(width: 1, height: 14)
                    Image(systemName: "arrow.down")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Theme.muted(0.42))
                }
                .padding(.vertical, 7)
                .padding(.horizontal, 10)
                .background(Theme.neutral300, in: Capsule())
            }
            .buttonStyle(.plain)

            FeedActionPill(systemImage: "bubble.left", text: "\(post.comments)")
            FeedActionPill(systemImage: "arrowshape.turn.up.right", text: "Share")

            Spacer(minLength: 0)
        }
        .padding(.top, 2)
    }

    private var mediaItems: [PostMedia] {
        if !post.media.isEmpty { return post.media }
        if let imageURL = post.imageURL {
            return [PostMedia(url: imageURL, width: nil, height: nil)]
        }
        return []
    }
}

private struct FeedMediaCarousel: View {
    let items: [PostMedia]
    @Binding var selection: Int
    @State private var availableWidth: CGFloat = 362

    var body: some View {
        ZStack {
            TabView(selection: $selection) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    FeedMediaPage(item: item)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: previewHeight)
            .background(Theme.surface)

            if items.count > 1 {
                carouselControls
            }
        }
        .frame(height: previewHeight)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous)
                .strokeBorder(Theme.divider, lineWidth: 1)
        }
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { availableWidth = proxy.size.width }
                    .onChange(of: proxy.size.width) { _, newValue in
                        availableWidth = newValue
                    }
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous))
    }

    private var carouselControls: some View {
        ZStack {
            HStack {
                pageButton(systemImage: "chevron.left") {
                    guard selection > 0 else { return }
                    withAnimation(.easeInOut(duration: 0.18)) { selection -= 1 }
                }
                .opacity(selection > 0 ? 1 : 0)

                Spacer(minLength: 0)

                pageButton(systemImage: "chevron.right") {
                    guard selection < items.count - 1 else { return }
                    withAnimation(.easeInOut(duration: 0.18)) { selection += 1 }
                }
                .opacity(selection < items.count - 1 ? 1 : 0)
            }
            .padding(.horizontal, 8)

            VStack {
                HStack {
                    Spacer(minLength: 0)
                    Text("\(selection + 1)/\(items.count)")
                        .font(Theme.body(11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 8)
                        .background(.black.opacity(0.58), in: Capsule())
                }
                Spacer(minLength: 0)
            }
            .padding(8)
        }
    }

    private func pageButton(systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(.black.opacity(0.46), in: Circle())
        }
        .buttonStyle(.plain)
    }

    private var previewHeight: CGFloat {
        guard let first = items.first,
              let width = first.width,
              let height = first.height,
              width > 0,
              height > 0 else {
            return Self.defaultHeight
        }

        let previewWidth = min(max(availableWidth, 1), 500)
        let rawHeight = previewWidth * CGFloat(height) / CGFloat(width)
        return min(max(rawHeight, Self.minHeight), Self.maxHeight)
    }

    static let defaultHeight: CGFloat = 230
    private static let minHeight: CGFloat = 170
    private static let maxHeight: CGFloat = 320
}

private struct FeedMediaPage: View {
    let item: PostMedia

    var body: some View {
        AsyncImage(url: item.url) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .scaledToFill()
            case .failure:
                ImagePlaceholder()
            default:
                StripePattern()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }
}

private struct FeedActionPill: View {
    let systemImage: String
    let text: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .labelStyle(CompactLabelStyle())
            .font(Theme.body(12, weight: .semibold))
            .foregroundStyle(Theme.text.opacity(0.62))
            .padding(.vertical, 7)
            .padding(.horizontal, 10)
            .background(Theme.neutral300, in: Capsule())
    }
}

/// A compact icon+text label used in post meta rows.
struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.font(.system(size: 13))
            configuration.title
        }
    }
}

/// Diagonal-hatch image placeholder matching the design.
struct ImagePlaceholder: View {
    var body: some View {
        ZStack {
            StripePattern()
            Image(systemName: "photo")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(Theme.muted(0.5))
        }
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct StripePattern: View {
    var body: some View {
        GeometryReader { geo in
            let count = Int((geo.size.width + geo.size.height) / 16) + 2
            Theme.surface
                .overlay {
                    ForEach(0..<count, id: \.self) { i in
                        Rectangle()
                            .fill(Theme.neutral400)
                            .frame(width: 8)
                            .rotationEffect(.degrees(-45))
                            .offset(x: CGFloat(i) * 16 - geo.size.height)
                    }
                }
                .clipped()
        }
    }
}

extension Color {
    /// Approximate CSS color-mix by blending in sRGB.
    func blended(with other: Color, fraction: Double) -> Color {
        Color(UIColor { traits in
            let a = UIColor(self).resolvedColor(with: traits)
            let b = UIColor(other).resolvedColor(with: traits)
            var ar: CGFloat = 0, ag: CGFloat = 0, ab: CGFloat = 0, aa: CGFloat = 0
            var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
            a.getRed(&ar, green: &ag, blue: &ab, alpha: &aa)
            b.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
            let f = CGFloat(fraction)
            return UIColor(
                red: ar + (br - ar) * f,
                green: ag + (bg - ag) * f,
                blue: ab + (bb - ab) * f,
                alpha: aa + (ba - aa) * f
            )
        })
    }
}
