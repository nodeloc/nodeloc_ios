//
//  SettingsOverlay.swift
//  nodeloc
//
//  Settings and the Nodeloc Pro upsell.
//

import SwiftUI

// MARK: - Settings

struct SettingsOverlay: View {
    @Environment(AppState.self) private var app

    var body: some View {
        VStack(spacing: 0) {
            OverlayHeader(title: "Settings")
            ScrollView {
                LazyVStack(spacing: 0) {
                    accountActionRow(label: "通知", icon: "bell.fill", tint: Theme.accent) {
                        app.overlay = .notifications
                    }
                    accountActionRow(label: "Nodeloc Pro", icon: "sparkle", tint: Theme.accent) {
                        app.overlay = .pro
                    }
                    if app.authed && !app.isGuest {
                        accountActionRow(label: "退出登录", icon: "rectangle.portrait.and.arrow.right", tint: Theme.danger, danger: true) {
                            DiscourseLogin.shared.signOut()
                            app.overlay = nil
                            app.onboardingDone = false
                            app.isGuest = false
                            app.authed = false
                        }
                    }

                    ForEach(SampleData.settings) { row in
                        HStack {
                            Text(row.label)
                                .font(Theme.body(14))
                                .foregroundStyle(row.danger ? Theme.danger : Theme.text)
                            Spacer()
                            Text(row.detail).font(Theme.body(12)).foregroundStyle(Theme.muted(0.4))
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Theme.muted(0.3))
                        }
                        .padding(.vertical, 14).padding(.horizontal, 20)
                        .contentShape(Rectangle())
                        .onTapGesture { handle(row) }
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(Theme.divider).frame(height: 1)
                        }
                    }
                }
                .padding(.top, 4)
            }
            .scrollIndicators(.hidden)
        }
        .background(Theme.bg.ignoresSafeArea())
    }

    private func accountActionRow(
        label: String,
        icon: String,
        tint: Color,
        danger: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 24)
            Text(label)
                .font(Theme.body(14))
                .foregroundStyle(danger ? Theme.danger : Theme.text)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.muted(0.3))
        }
        .padding(.vertical, 14).padding(.horizontal, 20)
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.divider).frame(height: 1)
        }
    }

    private func handle(_ row: SettingRow) {
        guard row.label == "Log out" else { return }
        DiscourseLogin.shared.signOut()
        app.overlay = nil
        app.onboardingDone = false
        app.isGuest = false
        app.authed = false
    }
}

// MARK: - Nodeloc Pro

struct ProOverlay: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app

        VStack(spacing: 0) {
            OverlayHeader(title: "Nodeloc Pro")
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Go further on NODELOC.").font(Theme.heading(32)).padding(.bottom, 6)
                    Text("No ads, custom badges, and priority in the queue.")
                        .font(Theme.body(13)).foregroundStyle(Theme.muted(0.75))
                        .padding(.bottom, 18)

                    VStack(alignment: .leading, spacing: 8) {
                        proFeature("Ad-free browsing")
                        proFeature("Animated profile badge")
                        proFeature("Early access to new Nodes")
                    }
                    .padding(.bottom, 18)

                    SegmentedControl(
                        selection: $app.plan,
                        options: [(.monthly, "Monthly"), (.yearly, "Yearly · save 33%")]
                    )
                    .padding(.bottom, 16)

                    // Price
                    HStack(alignment: .firstTextBaseline) {
                        Text(app.planPrice).font(Theme.heading(26, weight: .semibold))
                        Spacer()
                        Text(app.planPeriod).font(Theme.body(12)).foregroundStyle(Theme.muted(0.55))
                    }
                    .padding(Theme.space3)
                    .frame(maxWidth: .infinity)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous))
                    .padding(.bottom, 18)

                    // Payment method
                    HStack(spacing: Theme.space3) {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .strokeBorder(Theme.divider, lineWidth: 1)
                            .background(Theme.surface)
                            .frame(width: 26, height: 18)
                            .overlay(Rectangle().fill(Theme.neutral500).frame(height: 2.5).padding(.horizontal, 3), alignment: .center)
                        Text("•••• 4242").font(Theme.body(13))
                        Spacer()
                        Button("Edit") {}.buttonStyle(GhostButtonStyle())
                    }
                    .padding(Theme.space3)
                    .frame(maxWidth: .infinity)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous))
                    .padding(.bottom, 18)

                    Button("Subscribe") {}
                        .buttonStyle(PrimaryButtonStyle(block: true))

                    Text("Cancel anytime. Renews automatically.")
                        .font(Theme.body(11)).foregroundStyle(Theme.muted(0.45))
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                        .padding(.top, 10)
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
        }
        .background(Theme.bg.ignoresSafeArea())
    }

    private func proFeature(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Theme.success)
            Text(text).font(Theme.body(13))
        }
    }
}
