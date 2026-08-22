//
//  AccountSecurityPages.swift
//  nodeloc
//
//  Associated accounts and security (password, 2FA, sessions). Things iOS
//  can't do natively — connecting a new OAuth account, registering a WebAuthn
//  security key — open the matching web settings page in the in-app browser.
//

import SwiftUI

// MARK: - Associated accounts

struct AssociatedAccountsPage: View {
    let onClose: () -> Void

    private var store = SecurityStore.shared
    @State private var pendingRevoke: AssociatedAccount?

    init(onClose: @escaping () -> Void) { self.onClose = onClose }

    var body: some View {
        VStack(spacing: 0) {
            SettingsPageHeader(title: "关联账户", onClose: onClose)
            ScrollView {
                VStack(spacing: 0) {
                    if store.associatedAccounts.isEmpty {
                        EmptyStateView(icon: "link", message: "还没有关联的账户")
                            .padding(.top, 60)
                    } else {
                        SettingsSection(title: "已关联") {
                            ForEach(store.associatedAccounts) { account in
                                accountRow(account)
                            }
                        }
                    }

                    SettingsSection(
                        title: "连接",
                        footer: "连接新账户需要在网页中授权，将在内置浏览器中打开。"
                    ) {
                        SettingsNavRow(title: "连接新账户", icon: "plus.circle") {
                            openWeb("/my/preferences/account")
                        }
                    }
                }
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
        }
        .background(Theme.bg.ignoresSafeArea())
        .task { await store.load() }
        .confirmationDialog(
            "断开与 \(pendingRevoke?.name ?? "") 的关联？",
            isPresented: Binding(get: { pendingRevoke != nil }, set: { if !$0 { pendingRevoke = nil } }),
            titleVisibility: .visible
        ) {
            Button("断开", role: .destructive) {
                if let account = pendingRevoke { Task { await store.revoke(account) } }
            }
            Button("取消", role: .cancel) {}
        }
    }

    private func accountRow(_ account: AssociatedAccount) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(account.name.capitalized).font(Theme.body(14)).foregroundStyle(Theme.text)
                if let desc = account.description, !desc.isEmpty {
                    Text(desc).font(Theme.body(11)).foregroundStyle(Theme.muted(0.5)).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Button("断开") { pendingRevoke = account }
                .font(Theme.body(13, weight: .semibold))
                .foregroundStyle(Theme.danger)
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.divider).frame(height: 1).padding(.leading, 20) }
    }
}

// MARK: - Security

struct SecurityPage: View {
    let onClose: () -> Void

    private var store = SecurityStore.shared
    @State private var showConfirm = false
    @State private var showTOTPSetup = false
    @State private var pendingAction: (() async -> Void)?
    @State private var showPasswordSent = false

    init(onClose: @escaping () -> Void) { self.onClose = onClose }

    var body: some View {
        VStack(spacing: 0) {
            SettingsPageHeader(title: "安全性", onClose: onClose)
            ScrollView {
                VStack(spacing: 0) {
                    passwordSection
                    twoFactorSection
                    sessionsSection
                    securityKeySection
                }
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
        }
        .background(Theme.bg.ignoresSafeArea())
        .task { await store.load() }
        .sheet(isPresented: $showConfirm) {
            ConfirmPasswordSheet { ok in
                showConfirm = false
                if ok, let action = pendingAction { Task { await action() } }
                pendingAction = nil
            }
        }
        .sheet(isPresented: $showTOTPSetup) {
            TOTPSetupSheet()
        }
        .alert("已发送", isPresented: $showPasswordSent) {
            Button("好") {}
        } message: {
            Text("重置密码的邮件已发送，请查收。")
        }
    }

    // MARK: Password

    private var passwordSection: some View {
        SettingsSection(
            title: "密码",
            footer: "为安全起见，密码只能通过邮件中的链接修改。"
        ) {
            SettingsNavRow(title: "更改密码", icon: "key") {
                Task { await store.requestPasswordReset(); showPasswordSent = true }
            }
        }
    }

    // MARK: 2FA

    private var twoFactorSection: some View {
        SettingsSection(title: "两步验证") {
            if store.totpEnabled {
                HStack {
                    Label("身份验证器", systemImage: "checkmark.shield.fill")
                        .font(Theme.body(14)).foregroundStyle(Theme.text)
                    Spacer()
                    Text("已开启").font(Theme.body(12)).foregroundStyle(Theme.success)
                }
                .padding(.horizontal, 20).padding(.vertical, 12)
                .overlay(alignment: .bottom) { rowLine }

                SettingsNavRow(title: "关闭两步验证", icon: "shield.slash", isDestructive: true) {
                    runConfirmed { await store.disableTOTP() }
                }
            } else {
                SettingsNavRow(title: "设置身份验证器", icon: "shield") {
                    runConfirmed { showTOTPSetup = true }
                }
            }
        }
    }

    // MARK: Sessions

    @ViewBuilder
    private var sessionsSection: some View {
        if !store.sessions.isEmpty {
            SettingsSection(title: "登录设备") {
                ForEach(store.sessions) { token in
                    sessionRow(token)
                }
                if store.sessions.contains(where: { $0.isActive != true }) {
                    SettingsNavRow(title: "注销所有其它设备", icon: "arrow.right.square", isDestructive: true) {
                        runConfirmed { await store.revokeAllOtherSessions() }
                    }
                }
            }
        }
    }

    private func sessionRow(_ token: UserAuthToken) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(token.clientName ?? token.osName ?? "未知设备")
                    .font(Theme.body(14)).foregroundStyle(Theme.text)
                if let seen = token.seenAt {
                    Text(seen).font(Theme.body(11)).foregroundStyle(Theme.muted(0.5)).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if token.isActive == true {
                Text("当前设备").font(Theme.body(12)).foregroundStyle(Theme.muted(0.5))
            } else {
                Button("注销") { Task { await store.revokeSession(token) } }
                    .font(Theme.body(13, weight: .semibold)).foregroundStyle(Theme.danger)
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .overlay(alignment: .bottom) { rowLine }
    }

    // MARK: Security keys (browser)

    private var securityKeySection: some View {
        SettingsSection(
            title: "安全密钥与通行密钥",
            footer: "安全密钥需要在网页中注册，将在内置浏览器中打开。"
        ) {
            SettingsNavRow(title: "管理安全密钥", icon: "key.horizontal") {
                openWeb("/my/preferences/security")
            }
        }
    }

    // MARK: Confirm-session gate

    /// Runs `action` once the session is confirmed, prompting for the password
    /// only when it isn't already trusted.
    private func runConfirmed(_ action: @escaping () async -> Void) {
        Task {
            if await store.isSessionTrusted() {
                await action()
            } else {
                pendingAction = action
                showConfirm = true
            }
        }
    }

    private var rowLine: some View {
        Rectangle().fill(Theme.divider).frame(height: 1).padding(.leading, 20)
    }
}

// MARK: - Confirm password

/// Asks for the account password to trust the session before a sensitive op.
private struct ConfirmPasswordSheet: View {
    let onResult: (Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    private var store = SecurityStore.shared
    @State private var password = ""
    @State private var isChecking = false

    init(onResult: @escaping (Bool) -> Void) { self.onResult = onResult }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("请输入你的密码以继续。")
                    .font(Theme.body(14)).foregroundStyle(Theme.muted(0.7))

                SecureField("密码", text: $password)
                    .textFieldStyle(.plain)
                    .font(Theme.body(15))
                    .padding(.horizontal, 14).padding(.vertical, 12)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                Button {
                    Task {
                        isChecking = true
                        let ok = await store.confirm(password: password)
                        isChecking = false
                        if ok { onResult(true) }
                    }
                } label: {
                    if isChecking { ProgressView().tint(.white).frame(maxWidth: .infinity) }
                    else { Text("确认").frame(maxWidth: .infinity) }
                }
                .buttonStyle(PrimaryButtonStyle(block: true))
                .disabled(password.isEmpty || isChecking)

                Spacer()
            }
            .padding(20)
            .background(Theme.bg)
            .navigationTitle("确认身份")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { onResult(false); dismiss() }
                }
            }
        }
        .standardSheet([.medium])
    }
}

// MARK: - TOTP setup

/// Walks through enabling an authenticator: show the QR + secret, take the
/// 6-digit code, then reveal the backup codes.
private struct TOTPSetupSheet: View {
    @Environment(\.dismiss) private var dismiss
    private var store = SecurityStore.shared

    @State private var setup: TOTPCreateResponse?
    @State private var code = ""
    @State private var deviceName = "身份验证器"
    @State private var backupCodes: [String] = []
    @State private var isWorking = false
    @State private var enabled = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if enabled {
                        backupCodesView
                    } else {
                        setupView
                    }
                }
                .padding(20)
            }
            .background(Theme.bg)
            .navigationTitle("两步验证")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(enabled ? "完成" : "取消") { dismiss() }
                }
            }
        }
        .standardSheet([.large])
        .task {
            if setup == nil { setup = await store.createTOTP() }
        }
    }

    @ViewBuilder
    private var setupView: some View {
        Text("用身份验证器 App 扫描二维码，或手动输入密钥。")
            .font(Theme.body(13)).foregroundStyle(Theme.muted(0.7))

        if let qr = setup?.qr, let image = qrImage(qr) {
            image.resizable().interpolation(.none).scaledToFit()
                .frame(width: 200, height: 200)
                .frame(maxWidth: .infinity)
        } else {
            ProgressView().frame(maxWidth: .infinity).frame(height: 200)
        }

        if let key = setup?.key {
            Text(key)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(Theme.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }

        TextField("名称", text: $deviceName)
            .textFieldStyle(.plain).font(Theme.body(15))
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

        TextField("6 位验证码", text: $code)
            .textFieldStyle(.plain).font(Theme.body(15))
            .keyboardType(.numberPad)
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

        Button {
            Task {
                isWorking = true
                if await store.enableTOTP(token: code, name: deviceName) {
                    backupCodes = await store.generateBackupCodes()
                    enabled = true
                }
                isWorking = false
            }
        } label: {
            if isWorking { ProgressView().tint(.white).frame(maxWidth: .infinity) }
            else { Text("启用").frame(maxWidth: .infinity) }
        }
        .buttonStyle(PrimaryButtonStyle(block: true))
        .disabled(code.count < 6 || isWorking)
    }

    @ViewBuilder
    private var backupCodesView: some View {
        Label("两步验证已开启", systemImage: "checkmark.shield.fill")
            .font(Theme.body(15, weight: .semibold)).foregroundStyle(Theme.success)

        if !backupCodes.isEmpty {
            Text("请保存这些备份码。每个只能用一次，可在无法使用验证器时登录。")
                .font(Theme.body(13)).foregroundStyle(Theme.muted(0.7))
            VStack(alignment: .leading, spacing: 6) {
                ForEach(backupCodes, id: \.self) { c in
                    Text(c).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    /// The QR is a `data:image/png;base64,…` string.
    private func qrImage(_ dataURL: String) -> Image? {
        guard let comma = dataURL.firstIndex(of: ","),
              let data = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...])),
              let ui = UIImage(data: data) else { return nil }
        return Image(uiImage: ui)
    }
}

// MARK: - Shared header + browser helper

/// A back-button header for the account sub-pages, matching PreferencePage.
struct SettingsPageHeader: View {
    let title: String
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onClose) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.text)
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.glass(.regular.tint(Theme.bg.opacity(0.34))))
            .buttonBorderShape(.circle)
            Text(title).font(Theme.body(15, weight: .medium))
            Spacer()
        }
        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 12)
    }
}

/// Opens a site-relative path in the in-app browser.
@MainActor
func openWeb(_ path: String) {
    if let url = URL(string: path, relativeTo: DiscourseConfig.baseURL)?.absoluteURL {
        BrowserState.shared.open(url)
    }
}
