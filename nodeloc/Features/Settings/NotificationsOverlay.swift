//
//  NotificationsOverlay.swift
//  nodeloc
//
//  The notifications list.
//

import SwiftUI

// MARK: - Notifications

struct NotificationsOverlay: View {
    @State private var store = NotificationsStore()

    var body: some View {
        VStack(spacing: 0) {
            OverlayHeader(title: "Notifications")
            ScrollView {
                LazyVStack(spacing: 0) {
                    if store.isLoading && store.items.isEmpty {
                        ProgressView().tint(Theme.accent).padding(.top, 40)
                    }
                    ForEach(store.items) { notification in
                        NotificationRow(notification: notification)
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
        .background(Theme.bg.ignoresSafeArea())
        .task { await store.load() }
    }
}

private struct NotificationRow: View {
    let notification: AppNotification

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: iconWeight))
                .foregroundStyle(iconColor)
                .frame(width: 32, height: 32)
                .background(iconBg, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                // Interpolating the two styled runs instead of `+` (deprecated in iOS 26).
                let namePart = Text(notification.name).font(Theme.body(13, weight: .semibold))
                let textPart = Text(" \(notification.text)").font(Theme.body(13))
                Text("\(namePart)\(textPart)")
                    .foregroundStyle(Theme.text)
                Text(notification.time).font(Theme.body(11)).foregroundStyle(Theme.muted(0.5))
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 12).padding(.horizontal, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(notification.unread ? Theme.accent.opacity(0.06) : .clear)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.divider).frame(height: 1)
        }
    }

    private var icon: String {
        switch notification.kind {
        case .like: return "heart.fill"
        case .comment: return "bubble.left"
        case .message: return "envelope.fill"
        case .success: return "checkmark"
        case .star: return "star.fill"
        }
    }
    private var iconWeight: Font.Weight {
        (notification.kind == .success || notification.kind == .comment) ? .bold : .regular
    }
    private var iconColor: Color {
        switch notification.kind {
        case .like: return Theme.love
        case .comment: return Theme.accent700
        case .message: return Theme.text
        case .success: return Theme.success
        case .star: return Theme.accent2_600
        }
    }
    private var iconBg: Color {
        switch notification.kind {
        case .like: return Theme.surface.blended(with: Theme.love, fraction: 0.15)
        case .comment: return Theme.surface.blended(with: Theme.accent, fraction: 0.15)
        case .message: return Theme.surface.blended(with: Theme.text, fraction: 0.08)
        case .success: return Theme.surface.blended(with: Theme.success, fraction: 0.15)
        case .star: return Theme.surface.blended(with: Theme.accent2_500, fraction: 0.18)
        }
    }
}
