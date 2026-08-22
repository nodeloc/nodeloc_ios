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

    /// The preference page pushed over the list, if any.
    @State private var openGroup: PreferenceGroup?
    /// The account sub-page pushed over the list, if any.
    @State private var openAccountPage: AccountPage?

    private enum AccountPage: String, Identifiable {
        case profile, associatedAccounts, security
        var id: String { rawValue }
    }

    private var isSignedIn: Bool { app.authed && !app.isGuest }

    var body: some View {
        ZStack {
            settingsList

            if let openGroup {
                PreferencePage(group: openGroup) {
                    withAnimation(.panelSlide) { self.openGroup = nil }
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
                .zIndex(1)
            }

            if let openAccountPage {
                accountPage(openAccountPage) {
                    withAnimation(.panelSlide) { self.openAccountPage = nil }
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
                .zIndex(1)
            }
        }
        .background(Theme.bg.ignoresSafeArea())
    }

    @ViewBuilder
    private func accountPage(_ page: AccountPage, onClose: @escaping () -> Void) -> some View {
        switch page {
        case .profile: ProfileEditPage(onClose: onClose)
        case .associatedAccounts: AssociatedAccountsPage(onClose: onClose)
        case .security: SecurityPage(onClose: onClose)
        }
    }

    private var settingsList: some View {
        VStack(spacing: 0) {
            OverlayHeader(title: "设置")
            ScrollView {
                LazyVStack(spacing: 0) {
                    // Account editing + preferences, shown only to a real
                    // account: these fields are owner-serialized, so there is
                    // nothing to edit as a guest.
                    if isSignedIn {
                        SettingsSection(title: "账户") {
                            SettingsNavRow(title: "个人资料", icon: "person.crop.circle") {
                                withAnimation(.panelSlide) { openAccountPage = .profile }
                            }
                            SettingsNavRow(title: "关联账户", icon: "link") {
                                withAnimation(.panelSlide) { openAccountPage = .associatedAccounts }
                            }
                            SettingsNavRow(title: "安全性", icon: "lock.shield") {
                                withAnimation(.panelSlide) { openAccountPage = .security }
                            }
                        }

                        SettingsSection(title: "偏好设置") {
                            ForEach(PreferenceGroup.allCases) { group in
                                SettingsNavRow(title: group.title, icon: group.icon) {
                                    withAnimation(.panelSlide) { openGroup = group }
                                }
                            }
                        }
                    }

                    SettingsSection(title: "账号") {
                        SettingsNavRow(title: "通知", icon: "bell.fill") {
                            app.overlay = .notifications
                        }
                        SettingsNavRow(title: "Nodeloc Pro", icon: "sparkle") {
                            app.overlay = .pro
                        }
                        if isSignedIn {
                            SettingsNavRow(
                                title: "退出登录",
                                icon: "rectangle.portrait.and.arrow.right",
                                isDestructive: true
                            ) {
                                signOut()
                            }
                        }
                    }
                }
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func signOut() {
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
