//
//  PushSettingsPage.swift
//  nodeloc
//
//  推送通知 settings: a master switch plus per-kind toggles gating what the
//  background poll banners (see PushNotificationService).
//

import SwiftUI

struct PushSettingsPage: View {
    let onClose: () -> Void

    private var service = PushNotificationService.shared
    private var preferences = PushPreferences.shared

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    private var permissionDenied: Bool {
        service.authorizationStatus == .denied
    }

    /// The switch shows on only when the user opted in *and* the system
    /// permission stands.
    private var pushIsOn: Bool {
        preferences.isEnabled && !permissionDenied
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Form {
                Group {
                    SettingsSection(title: AppString("推送"), footer: masterFooter) {
                        SettingsToggleRow(
                            title: AppString("允许推送通知"),
                            detail: AppString("应用在后台定期检查并推送新通知"),
                            isOn: masterBinding
                        )
                        if permissionDenied {
                            SettingsNavRow(title: AppString("前往系统设置开启"), icon: "gear") {
                                openSystemSettings()
                            }
                        }
                    }

                    if pushIsOn {
                        SettingsSection(
                            title: AppString("允许的通知类型"),
                            footer: AppString("关闭的类型不会推送，但仍会出现在站内通知列表。")
                        ) {
                            ForEach(PushCategory.allCases) { category in
                                SettingsToggleRow(
                                    title: category.title,
                                    detail: category.detail,
                                    isOn: binding(for: category)
                                )
                            }
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
        .background(Theme.bg.ignoresSafeArea())
        // The user may have flipped the permission in system settings while
        // this page was away.
        .task { await service.refreshAuthorizationStatus() }
    }

    private var header: some View {
        SettingsBar(title: AppString("推送通知"), onClose: onClose)
    }

    private var masterFooter: String {
        if permissionDenied {
            return AppString("通知权限已被系统拒绝，需要在系统设置中重新允许。")
        }
        return AppString("推送由系统安排的后台检查触发，可能有几分钟到数小时的延迟。")
    }

    private var masterBinding: Binding<Bool> {
        Binding(
            get: { pushIsOn },
            set: { newValue in
                Task { await service.setEnabled(newValue) }
            }
        )
    }

    private func binding(for category: PushCategory) -> Binding<Bool> {
        Binding(
            get: { preferences.allows(category) },
            set: { preferences.setAllows($0, for: category) }
        )
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
