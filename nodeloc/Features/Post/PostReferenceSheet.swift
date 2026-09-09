//
//  PostReferenceSheet.swift
//  nodeloc
//
//  The half sheet behind an `@user` / `#node` / `#tag` badge in a post body.
//
//  Each kind reuses the screen it already had — the profile, the node page, the
//  tag list — so a reference is a shortcut to an existing destination rather
//  than a second, thinner version of it.
//

import SwiftUI

struct PostReferenceSheet: View {
    let reference: PostReference
    let onClose: () -> Void

    @Environment(AppState.self) private var app
    @Environment(BrowserState.self) private var browser
    /// The node page needs a full summary and a badge only carries the slug.
    @State private var node: SidebarNodeSummary?
    @State private var nodeLookupFailed = false

    var body: some View {
        switch reference.kind {
        case .user:
            PublicProfileOverlay(
                target: UserProfileTarget(username: reference.slug, displayName: reference.label),
                onClose: onClose
            )

        case .tag:
            TagTopicsView(
                slug: reference.slug,
                label: reference.label,
                onOpenPost: openPost
            )

        case .node:
            nodeContent
        }
    }

    @ViewBuilder
    private var nodeContent: some View {
        if let node {
            NodeDetailOverlay(node: node, onClose: onClose)
        } else {
            ProgressView()
                .tint(Theme.accent)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.bg)
                .task {
                    guard node == nil, !nodeLookupFailed else { return }
                    node = await NodeCatalog.shared.node(slug: reference.slug)
                    guard node == nil else { return }
                    // Unknown slug — hand it to the browser rather than leaving
                    // a spinner up, matching how `routedNodeSlug` gives up.
                    nodeLookupFailed = true
                    onClose()
                    if let url = PostInlineRenderer.resolvedLink(reference.href) {
                        browser.open(url)
                    }
                }
        }
    }

    /// Opening a topic replaces the reference rather than stacking on it: the
    /// sheet closes and the post overlay takes over.
    private func openPost(_ post: Post) {
        onClose()
        app.markTopicOpened(id: post.id)
        app.selectedPost = post
        withAnimation(.expandCollapse) {
            app.overlay = .post
        }
    }
}
