//
//  HomeAnnouncements.swift
//  nodeloc
//
//  The home banner carousel (`GET /api/v1/announcements/home`), the JSON twin
//  of the one on the web's front page. Readable signed out, so a guest sees
//  the same rows — but a guest has no account to record a dismissal against
//  and the dismissal endpoint would answer 401, so theirs are kept on the
//  device. A signed-in reader's go to the server and follow them everywhere.
//

import SwiftUI

@MainActor
@Observable
final class HomeAnnouncementStore {
    private let client = DiscourseClient()

    private(set) var announcements: [NLHomeAnnouncements.Announcement] = []

    /// Dismissals this device remembers. Only ever written for a guest; once
    /// they sign in the server's own list takes over, and these stay harmless.
    private static let localKey = "nodeloc.announcements.dismissed"
    private var locallyDismissed: Set<Int> {
        get { Set(UserDefaults.standard.array(forKey: Self.localKey) as? [Int] ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: Self.localKey) }
    }

    /// What the carousel should actually show.
    var visible: [NLHomeAnnouncements.Announcement] {
        let hidden = locallyDismissed
        return announcements.filter { !hidden.contains($0.id) }
    }

    func load() async {
        guard let loaded = try? await client.homeAnnouncements() else { return }
        announcements = loaded
    }

    /// Hides it here first so the card leaves at once, then records it. A guest
    /// only ever gets the local half.
    func dismiss(_ announcement: NLHomeAnnouncements.Announcement) async {
        locallyDismissed.insert(announcement.id)
        announcements.removeAll { $0.id == announcement.id }
        guard DiscourseAuth.shared.isAuthenticated else { return }
        try? await client.dismissAnnouncement(id: announcement.id)
    }
}

/// The carousel itself: one card per announcement, swiped horizontally, above
/// the first topic row.
struct HomeAnnouncementCarousel: View {
    let announcements: [NLHomeAnnouncements.Announcement]
    let onOpen: (NLHomeAnnouncements.Announcement) -> Void
    let onDismiss: (NLHomeAnnouncements.Announcement) -> Void

    var body: some View {
        if !announcements.isEmpty {
            ScrollView(.horizontal) {
                LazyHStack(spacing: 12) {
                    ForEach(announcements) { announcement in
                        HomeAnnouncementCard(
                            announcement: announcement,
                            onOpen: { onOpen(announcement) },
                            onDismiss: { onDismiss(announcement) }
                        )
                    }
                }
                .padding(.horizontal, 16)
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollIndicators(.hidden)
        }
    }
}

private struct HomeAnnouncementCard: View {
    let announcement: NLHomeAnnouncements.Announcement
    let onOpen: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    if let kindName = announcement.kindName, !kindName.isEmpty {
                        Text(kindName)
                            .font(Theme.body(10, weight: .semibold))
                            .foregroundStyle(Theme.accent700)
                            .padding(.vertical, 3)
                            .padding(.horizontal, 7)
                            .background(Theme.accent.opacity(0.12), in: Capsule())
                    }

                    Spacer(minLength: 0)

                    // Every one is dismissible today, but the field decides.
                    if announcement.dismissible ?? true {
                        Button(action: onDismiss) {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Theme.muted(0.45))
                                .frame(width: 24, height: 24)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.pressableIcon)
                        .accessibilityLabel(AppString("关闭"))
                    }
                }

                Text(announcement.title)
                    .font(Theme.body(14, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                if let excerpt = announcement.excerpt, !excerpt.isEmpty {
                    Text(excerpt)
                        .font(Theme.body(12))
                        .foregroundStyle(Theme.muted(0.55))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
            .padding(14)
            .frame(width: 268, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Theme.muted(0.12), lineWidth: 1)
            )
        }
        .buttonStyle(.pressable)
    }
}
