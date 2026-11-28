//
//  SettingsOverlay.swift
//  nodeloc
//
//  Settings.
//

import SwiftUI

// MARK: - Settings

/// The account sub-pages of Settings, each pushed on the app's page stack.
enum SettingsAccountPage: String, Identifiable {
    case profile, associatedAccounts, security, pushNotifications, postSource, blockedUsers, deleteAccount
    var id: String { rawValue }
}

/// 设置: a native inset grouped `Form` pushed on the app-wide page stack,
/// with the system navigation bar. Every sub-page pushes the same way.
struct SettingsOverlay: View {
    @Environment(AppState.self) private var app
    var onClose: () -> Void = {}

    @State private var confirmSignOut = false

    private var isSignedIn: Bool { app.authed && !app.isGuest }

    var body: some View {
        Form {
            // Account editing + preferences, shown only to a real account:
            // these fields are owner-serialized, so there is nothing to edit
            // as a guest.
            if isSignedIn {
                SettingsSection(title: AppString("账户")) {
                    SettingsNavRow(title: AppString("个人资料"), icon: "person.crop.circle") {
                        app.pushPage(.settingsAccount(.profile))
                    }
                    SettingsNavRow(title: AppString("关联账户"), icon: "link") {
                        app.pushPage(.settingsAccount(.associatedAccounts))
                    }
                    SettingsNavRow(title: AppString("安全性"), icon: "lock.shield") {
                        app.pushPage(.settingsAccount(.security))
                    }
                }

                // 草稿箱, 账号状态, 审核队列 and 管理台 live in the sidebar
                // (我的, 我管理的节点), and the notifications list in 消息 › 通知;
                // this page is settings only.
                SettingsSection(title: AppString("偏好设置")) {
                    ForEach(PreferenceGroup.allCases) { group in
                        SettingsNavRow(title: group.title, icon: group.icon) {
                            app.pushPage(.settingsPreference(group))
                        }
                        if group == .notifications {
                            SettingsNavRow(title: AppString("推送通知"), icon: "bell.badge") {
                                app.pushPage(.settingsAccount(.pushNotifications))
                            }
                        }
                    }
                    // Guideline 1.2: a block has to be reversible.
                    SettingsNavRow(title: AppString("屏蔽的用户"), icon: "hand.raised") {
                        app.pushPage(.settingsAccount(.blockedUsers))
                    }
                    if NodelocFeatures.postSource {
                        SettingsNavRow(title: AppString("发帖来源"), icon: "iphone.gen3") {
                            app.pushPage(.settingsAccount(.postSource))
                        }
                    }
                }
            }

            // A guest still has the device's own display settings, and a way in.
            if !isSignedIn {
                SettingsSection(title: AppString("偏好设置")) {
                    ForEach(PreferenceGroup.allCases.filter { !$0.needsAccount }) { group in
                        SettingsNavRow(title: group.title, icon: group.icon) {
                            app.pushPage(.settingsPreference(group))
                        }
                    }
                }
            }

            Section {
                if !isSignedIn {
                    SettingsNavRow(title: AppString("登录"), icon: "person.crop.circle") {
                        presentAuth(app)
                    }
                }
                if isSignedIn {
                    SettingsNavRow(
                        title: AppString("退出登录"),
                        icon: "rectangle.portrait.and.arrow.right",
                        isDestructive: true
                    ) {
                        confirmSignOut = true
                    }
                    // Anchored to the row: attached to the Form, the dialog's
                    // popover pointed at the top of the screen.
                    .confirmationDialog(AppString("退出登录？"), isPresented: $confirmSignOut, titleVisibility: .visible) {
                        Button(AppString("退出登录"), role: .destructive) { signOut() }
                        Button(AppString("取消"), role: .cancel) {}
                    }
                    // App Store guideline 5.1.1(v): accounts made in the app
                    // can be deleted in the app.
                    SettingsNavRow(
                        title: AppString("注销账号"),
                        icon: "person.crop.circle.badge.xmark",
                        isDestructive: true
                    ) {
                        app.pushPage(.settingsAccount(.deleteAccount))
                    }
                }
            }
        }
        .navigationTitle(AppString("设置"))
        .navigationBarTitleDisplayMode(.inline)
    }

    /// One account sub-page, for the page stack.
    @ViewBuilder
    static func accountPage(_ page: SettingsAccountPage, onClose: @escaping () -> Void) -> some View {
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

    /// Signing out leaves the whole stack: back to the signed-out state.
    private func signOut() {
        DiscourseLogin.shared.signOut()
        app.pageStack = []
        app.overlay = nil
        app.onboardingDone = false
        app.isGuest = false
        app.authed = false
    }
}
