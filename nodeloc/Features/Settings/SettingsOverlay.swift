//
//  SettingsOverlay.swift
//  nodeloc
//
//  Settings.
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
        case profile, associatedAccounts, security, pushNotifications, postSource, blockedUsers, deleteAccount
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
        case .pushNotifications: PushSettingsPage(onClose: onClose)
        case .postSource: PostSourcePage(onClose: onClose)
        case .blockedUsers: BlockedUsersPage(onClose: onClose)
        case .deleteAccount: DeleteAccountPage(onClose: onClose)
        }
    }

    private var settingsList: some View {
        VStack(spacing: 0) {
            OverlayHeader(title: AppString("设置"))
            ScrollView {
                LazyVStack(spacing: 0) {
                    // Account editing + preferences, shown only to a real
                    // account: these fields are owner-serialized, so there is
                    // nothing to edit as a guest.
                    if isSignedIn {
                        SettingsSection(title: AppString("账户")) {
                            SettingsNavRow(title: AppString("个人资料"), icon: "person.crop.circle") {
                                withAnimation(.panelSlide) { openAccountPage = .profile }
                            }
                            SettingsNavRow(title: AppString("关联账户"), icon: "link") {
                                withAnimation(.panelSlide) { openAccountPage = .associatedAccounts }
                            }
                            SettingsNavRow(title: AppString("安全性"), icon: "lock.shield") {
                                withAnimation(.panelSlide) { openAccountPage = .security }
                            }
                        }

                        SettingsSection(title: AppString("偏好设置")) {
                            ForEach(PreferenceGroup.allCases) { group in
                                SettingsNavRow(title: group.title, icon: group.icon) {
                                    withAnimation(.panelSlide) { openGroup = group }
                                }
                            }
                            // Server-side like the rest of this section, but its
                            // own endpoint rather than a user_option — hence a
                            // page instead of a row in one of the groups.
                            // Guideline 1.2: a block has to be reversible, and
                            // Discourse already keeps the list — see
                            // `BlockedUsersPage`.
                            SettingsNavRow(title: AppString("屏蔽的用户"), icon: "hand.raised") {
                                withAnimation(.panelSlide) { openAccountPage = .blockedUsers }
                            }
                            SettingsNavRow(title: AppString("发帖来源"), icon: "iphone.gen3") {
                                withAnimation(.panelSlide) { openAccountPage = .postSource }
                            }
                        }
                    }

                    SettingsSection(title: AppString("账号")) {
                        SettingsNavRow(title: AppString("通知"), icon: "bell.fill") {
                            app.overlay = .notifications
                        }
                        if isSignedIn {
                            SettingsNavRow(title: AppString("推送通知"), icon: "bell.badge") {
                                withAnimation(.panelSlide) { openAccountPage = .pushNotifications }
                            }
                        }
                        if isSignedIn {
                            SettingsNavRow(
                                title: AppString("退出登录"),
                                icon: "rectangle.portrait.and.arrow.right",
                                isDestructive: true
                            ) {
                                signOut()
                            }
                            // Required by App Store guideline 5.1.1(v): an app
                            // that creates accounts has to let them be deleted
                            // from inside the app.
                            SettingsNavRow(
                                title: AppString("注销账号"),
                                icon: "person.crop.circle.badge.xmark",
                                isDestructive: true
                            ) {
                                withAnimation(.panelSlide) { openAccountPage = .deleteAccount }
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
