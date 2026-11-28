//
//  NotificationsOverlay.swift
//  nodeloc
//
//  The notifications list.
//

import SwiftUI

// MARK: - Notifications

struct NotificationsOverlay: View {
    @Environment(AppState.self) private var app
    @State private var store = NotificationsStore()

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: AppString("通知")) { closeOverlay(app) }
            ScrollView {
                LazyVStack(spacing: 0) {
                    if store.isLoading && store.items.isEmpty {
                        ProgressView().tint(Theme.accent).padding(.top, 40)
                    } else if store.items.isEmpty, let errorText = store.errorText {
                        VStack(spacing: 12) {
                            EmptyStateView(icon: "exclamationmark.triangle", message: errorText)
                            Button(AppString("重试")) { Task { await store.reload() } }
                                .buttonStyle(.bordered)
                                .tint(Theme.accent)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 80)
                    } else if store.items.isEmpty {
                        EmptyStateView(
                            icon: "bell",
                            message: DiscourseAuth.shared.isAuthenticated
                                ? AppString("暂无通知")
                                : AppString("登录后查看你的通知")
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.top, 80)
                    }
                    ForEach(store.items) { notification in
                        NotificationRow(
                            notification: notification,
                            onOpen: { store.markRead(id: notification.id) }
                        )
                    }
                }
            }
            .scrollIndicators(.hidden)
            // A failed refetch keeps what's on screen (see `load`).
            .refreshable { await store.reload() }
        }
        .background(Theme.bg.ignoresSafeArea())
        .task { await store.load() }
    }
}

private struct NotificationRow: View {
    let notification: AppNotification
    /// Clears this row's unread dot.
    var onOpen: (() -> Void)?
    @Environment(\.openURL) private var openURL

    /// A notification with nowhere to go opens its own text rather than
    /// leaving a row that ignores the tap.
    @State private var showsDetail = false

    var body: some View {
        Button {
            onOpen?()
            if let url = notification.url { openURL(url) } else { showsDetail = true }
        } label: {
            rowContent
        }
        .buttonStyle(.pressable)
        .sheet(isPresented: $showsDetail) {
            NotificationDetailSheet(notification: notification)
        }
    }

    private var rowContent: some View {
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
                Text(notification.time).font(Theme.body(11)).foregroundStyle(Theme.textMuted)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 12).padding(.horizontal, Theme.pagePadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(notification.unread ? Theme.accent.opacity(0.06) : .clear)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.divider).frame(height: 1)
        }
    }

    private var icon: String {
        switch notification.kind {
        case .like: return "heart.fill"
        case .comment: return "arrowshape.turn.up.left.fill"
        case .message: return "envelope.fill"
        case .success: return "checkmark"
        case .star: return "star.fill"
        case .system: return "bell.fill"
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
        case .system: return Theme.accent700
        }
    }
    private var iconBg: Color {
        switch notification.kind {
        case .like: return Theme.surface.blended(with: Theme.love, fraction: 0.15)
        case .comment: return Theme.surface.blended(with: Theme.accent, fraction: 0.15)
        case .message: return Theme.surface.blended(with: Theme.text, fraction: 0.08)
        case .success: return Theme.surface.blended(with: Theme.success, fraction: 0.15)
        case .star: return Theme.surface.blended(with: Theme.accent2_500, fraction: 0.18)
        case .system: return Theme.surface.blended(with: Theme.accent, fraction: 0.15)
        }
    }
}

/// A notification that points nowhere: its title and text in full.
struct NotificationDetailSheet: View {
    let notification: AppNotification
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(notification.name)
                        .font(Theme.body(13, weight: .semibold))
                        .foregroundStyle(Theme.textMuted)
                    Text(notification.text)
                        .font(Theme.body(17))
                        .foregroundStyle(Theme.text)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(notification.time)
                        .font(Theme.body(12))
                        .foregroundStyle(Theme.textMuted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            .navigationTitle(AppString("通知"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(AppString("完成")) { dismiss() }
                }
            }
        }
        .standardSheet([.medium, .large])
    }
}
