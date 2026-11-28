//
//  AccountSecurityPages.swift
//  nodeloc
//
//  Associated accounts and security (password, 2FA, sessions). Things iOS
//  can't do natively — connecting a new OAuth account, registering a WebAuthn
//  security key — open the matching web settings page in the in-app browser.
//

import CoreImage.CIFilterBuiltins
import SwiftUI

// MARK: - Associated accounts

struct AssociatedAccountsPage: View {
    let onClose: () -> Void

    private var store = SecurityStore.shared
    @State private var pendingUnlink: NLIdentities.Identity?
    @Environment(BrowserState.self) private var browser

    init(onClose: @escaping () -> Void) { self.onClose = onClose }

    private var linked: [NLIdentities.Identity] { store.identities.filter(\.linked) }
    /// Apple binds natively below, so it is left out of the web-linked list.
    private var available: [NLIdentities.Identity] {
        store.identities.filter { !$0.linked && $0.provider.lowercased() != "apple" }
    }

    var body: some View {
        Form {
            loginSection
            if !linked.isEmpty { linkedSection }
            availableSection
        }
        .navigationTitle(AppString("关联账户"))
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if !store.identitiesLoaded { ProgressView() }
        }
        .refreshable { await reload() }
        .task { await reload() }
        // Back from the web page where 连接 was done: show what it linked.
        .onChange(of: browser.url) { old, new in
            if old != nil, new == nil { Task { await reload() } }
        }
        // The server's refusals (the last way in, a provider not bound) as it words them.
        .onChange(of: store.errorText) { _, text in
            guard let text else { return }
            ToastCenter.shared.show(text)
            store.errorText = nil
        }
        .alert(
            AppString("断开 \(pendingUnlink.map(label) ?? "")？"),
            isPresented: Binding(get: { pendingUnlink != nil }, set: { if !$0 { pendingUnlink = nil } }),
            presenting: pendingUnlink
        ) { identity in
            Button(AppString("取消"), role: .cancel) {}
            Button(AppString("断开"), role: .destructive) {
                Task { await store.unlink(identity) }
            }
        } message: { identity in
            Text(identity.provider.lowercased() == "telegram"
                 ? AppString("断开后不能再用它登录，也收不到发到 Telegram 的通知。以后可以重新连接。")
                 : AppString("断开后不能再用它登录。以后可以重新连接。"))
        }
    }

    private func reload() async {
        await store.loadIdentities()
        await store.load(force: true)
    }

    // MARK: 登录方式

    private var loginSection: some View {
        Section {
            NavigationLink {
                SecurityPage(onClose: {})
            } label: {
                HStack(spacing: 12) {
                    ProviderTile(symbol: "lock")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(AppString("邮箱和密码")).fontWeight(.semibold)
                        Text(passwordLine)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(.vertical, 4)
            }
        } header: {
            Text(AppString("登录方式"))
        } footer: {
            Text(AppString("至少要保留一种能登录的方式。只剩最后一种时不能断开。"))
        }
    }

    private var passwordLine: String {
        let state: String? = switch store.hasPassword {
        case true?: AppString("已设置密码")
        case false?: AppString("未设置密码")
        case nil: nil
        }
        return [store.email.map(Self.masked), state].compactMap { $0 }.joined(separator: " · ")
    }

    /// `linjianchuan@example.com` → `lin***@example.com`.
    static func masked(_ email: String) -> String {
        guard let at = email.firstIndex(of: "@") else { return email }
        let local = email[..<at]
        return String(local.prefix(3)) + "***" + email[at...]
    }

    // MARK: 已关联

    private var linkedSection: some View {
        Section {
            ForEach(linked, id: \.provider) { identity in
                HStack(spacing: 12) {
                    ProviderTile(provider: identity.provider)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(label(identity)).fontWeight(.semibold)
                            .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
                        if let who = identity.name?.nilIfEmpty ?? identity.email?.nilIfEmpty {
                            Text(who.contains("@") ? Self.masked(who) : who)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        if let when = linkedDate(identity) {
                            Text(AppString("\(when) 关联"))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Spacer(minLength: 8)
                    Button(AppString("断开"), role: .destructive) { pendingUnlink = identity }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .controlSize(.small)
                }
                .padding(.vertical, 4)
            }
        } header: {
            HStack {
                Text(AppString("已关联"))
                Spacer()
                Text(AppString("\(linked.count) 个")).textCase(nil)
            }
        }
    }

    // MARK: 可以连接

    private var availableSection: some View {
        Section {
            ForEach(available, id: \.provider) { identity in
                HStack(spacing: 12) {
                    ProviderTile(provider: identity.provider)
                    Text(label(identity))
                        // The separator starts at the name, not at the button.
                        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
                    Spacer(minLength: 8)
                    Button {
                        openWeb("/settings")
                    } label: {
                        Text(AppString("连接"))
                            .foregroundStyle(Color(.label))
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                    .tint(Color(.label))
                }
                .padding(.vertical, 2)
            }
            // Apple binds natively: the one provider iOS authorizes without a
            // web round-trip, and binding it here is what keeps the first
            // Sign in with Apple from making a second account.
            if !store.hasAppleAccount, !store.identities.contains(where: { $0.provider.lowercased() == "apple" && $0.linked }) {
                NativeAppleSignInButton(
                    perform: { await store.linkApple($0) },
                    onFallbackToWeb: { openWeb("/settings") },
                    height: SocialAuthButtonStyle.height
                )
                .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
            }
        } header: {
            Text(AppString("可以连接"))
        } footer: {
            Text(AppString("连接新账户要在网页里授权，会在 App 内置的浏览器里打开。"))
        }
    }

    private func label(_ identity: NLIdentities.Identity) -> String {
        identity.label?.nilIfEmpty ?? identity.provider.capitalized
    }

    private func linkedDate(_ identity: NLIdentities.Identity) -> String? {
        guard let date = DiscourseFormat.date(identity.linkedAt) else { return nil }
        return date.formatted(.dateTime.year().month().locale(AppLanguage.resolved.locale))
    }
}

/// The 40pt rounded tile in front of a sign-in method: the provider's own
/// mark (the same artwork as the sign-in buttons), or a symbol.
private struct ProviderTile: View {
    var provider: String? = nil
    var symbol: String? = nil

    init(provider: String) { self.provider = provider }
    init(symbol: String) { self.symbol = symbol }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(symbol != nil ? Theme.accent.opacity(0.14) : Color(.tertiarySystemFill))
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            } else if let provider {
                SocialProviderIcon(provider: SocialAuthProvider(name: provider), size: markSize(provider), monochromeTint: Color(.label))
            }
        }
        .frame(width: 40, height: 40)
        .accessibilityHidden(true)
    }

    /// Optically matched: the round marks fill their box, X and Apple don't.
    private func markSize(_ provider: String) -> CGFloat {
        switch provider.lowercased() {
        case "twitter", "x": 18
        case "apple": 20
        case "google", "google_oauth2": 21
        default: 23
        }
    }
}

// MARK: - Security

struct SecurityPage: View {
    let onClose: () -> Void

    private var store = SecurityStore.shared
    @State private var showTOTPSetup = false
    @State private var showPasswordChange = false
    /// Which 2FA action is waiting for a code: turning it off, or new backup codes.
    @State private var codePurpose: CodePurpose?
    @State private var code = ""
    @State private var regeneratedCodes: [String]?

    private enum CodePurpose { case disable, backupCodes }

    init(onClose: @escaping () -> Void) { self.onClose = onClose }

    var body: some View {
        VStack(spacing: 0) {
            SettingsBar(title: AppString("安全性"), onClose: onClose)
            Form {
                Group {
                    passwordSection
                    twoFactorSection
                    sessionsSection
                    securityKeySection
                }
            }
            .scrollIndicators(.hidden)
            .refreshable { await store.load(force: true) }
        }
        .background(Theme.bg.ignoresSafeArea())
        .task { await store.load() }
        // The store's outcomes were set and never shown: a refused revoke or
        // a failed 2FA change looked exactly like success.
        .onChange(of: store.errorText) { _, text in
            guard let text else { return }
            ToastCenter.shared.show(text)
            store.errorText = nil
        }
        .onChange(of: store.infoText) { _, text in
            guard let text else { return }
            ToastCenter.shared.show(text)
            store.infoText = nil
        }
        .sheet(isPresented: $showTOTPSetup) {
            TOTPSetupSheet()
        }
        .sheet(isPresented: $showPasswordChange) {
            ChangePasswordSheet()
        }
        .sheet(isPresented: Binding(
            get: { regeneratedCodes != nil },
            set: { if !$0 { regeneratedCodes = nil } }
        )) {
            BackupCodesSheet(codes: regeneratedCodes ?? [])
        }
        .alert(
            codePurpose == .disable ? AppString("关闭两步验证") : AppString("重新生成备用码"),
            isPresented: Binding(get: { codePurpose != nil }, set: { if !$0 { codePurpose = nil } })
        ) {
            TextField(AppString("验证码或备用码"), text: $code)
                .keyboardType(.asciiCapable)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button(AppString("取消"), role: .cancel) { code = "" }
            Button(AppString("确认")) {
                let purpose = codePurpose
                let entered = code.trimmingCharacters(in: .whitespacesAndNewlines)
                code = ""
                Task {
                    switch purpose {
                    case .disable: _ = await store.disableTOTP(code: entered)
                    case .backupCodes: regeneratedCodes = await store.generateBackupCodes(code: entered)
                    case nil: break
                    }
                }
            }
        } message: {
            Text(AppString("输入身份验证器上的 6 位验证码。"))
        }
    }

    // MARK: Password

    private var passwordSection: some View {
        SettingsSection(title: AppString("密码")) {
            SettingsNavRow(title: AppString("更改密码"), icon: "key") {
                showPasswordChange = true
            }
        }
    }

    // MARK: 2FA

    private var twoFactorSection: some View {
        SettingsSection(title: AppString("两步验证")) {
            if store.totpEnabled {
                LabeledContent {
                    Text(AppString("已开启")).foregroundStyle(Theme.success)
                } label: {
                    Label(AppString("身份验证器"), systemImage: "checkmark.shield.fill")
                }

                SettingsNavRow(title: AppString("重新生成备用码"), icon: "list.number") {
                    codePurpose = .backupCodes
                }
                SettingsNavRow(title: AppString("关闭两步验证"), icon: "shield.slash", isDestructive: true) {
                    codePurpose = .disable
                }
            } else {
                SettingsNavRow(title: AppString("设置身份验证器"), icon: "shield") {
                    showTOTPSetup = true
                }
            }
        }
    }

    // MARK: Sessions

    @ViewBuilder
    private var sessionsSection: some View {
        if !store.sessions.isEmpty {
            SettingsSection(title: AppString("登录设备")) {
                ForEach(store.sessions) { token in
                    sessionRow(token)
                }
                if store.sessions.contains(where: { $0.isActive != true }) {
                    SettingsNavRow(title: AppString("注销所有其它设备"), icon: "arrow.right.square", isDestructive: true) {
                        Task { await store.revokeAllOtherSessions() }
                    }
                }
            }
        }
    }

    private func sessionRow(_ token: UserAuthToken) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                // The backend's client name is the raw user agent, which runs
                // to several lines unclipped.
                Text(token.clientName ?? token.osName ?? AppString("未知设备"))
                    .lineLimit(2)
                if let seen = token.seenAt {
                    // The server sends an ISO timestamp; shown in the app's
                    // language and the device's time zone when it parses.
                    Text(DiscourseFormat.date(seen).map { $0.formatted(.dateTime.year().month().day().hour().minute().locale(AppLanguage.resolved.locale)) } ?? seen)
                        .font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if token.isActive == true {
                Text(AppString("当前设备")).font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize()
            } else {
                Button(AppString("注销"), role: .destructive) { Task { await store.revokeSession(token) } }
                    .buttonStyle(.borderless)
                    .fixedSize()
            }
        }
    }

    // MARK: Security keys (browser)

    private var securityKeySection: some View {
        SettingsSection(
            title: AppString("安全密钥与通行密钥"),
            footer: AppString("安全密钥需要在网页中注册，将在内置浏览器中打开。")
        ) {
            SettingsNavRow(title: AppString("管理安全密钥"), icon: "key.horizontal") {
                openWeb("/settings")
            }
        }
    }
}

// MARK: - Change password

/// `PUT /api/v1/me/password`: the current password and a new one.
private struct ChangePasswordSheet: View {
    @Environment(\.dismiss) private var dismiss
    private var store = SecurityStore.shared
    @State private var current = ""
    @State private var new = ""
    @State private var repeated = ""
    @State private var isWorking = false
    @State private var errorText: String?
    /// 422 field messages: `current_password`, `password` (the new one).
    @State private var fieldErrors: [String: String] = [:]

    /// The server's minimum (account/rules.go).
    private let minimumLength = 10

    private var mismatch: Bool { !repeated.isEmpty && new != repeated }

    private var canSubmit: Bool {
        !current.isEmpty && new.count >= minimumLength && new == repeated && !isWorking
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField(AppString("当前密码"), text: $current)
                        .textContentType(.password)
                    FieldErrorText(message: fieldErrors["current_password"])
                }
                Section {
                    SecureField(AppString("新密码"), text: $new)
                        .textContentType(.newPassword)
                    FieldErrorText(message: fieldErrors["password"])
                    SecureField(AppString("再次输入新密码"), text: $repeated)
                        .textContentType(.newPassword)
                    if mismatch {
                        FieldErrorText(message: AppString("两次输入的密码不一致"))
                    }
                } footer: {
                    Text(AppString("至少 \(minimumLength) 个字符。改好后，其他设备上的登录都会注销。"))
                }
                if let errorText {
                    Section {
                        FieldErrorText(message: errorText)
                    }
                }
            }
            .navigationTitle(AppString("更改密码"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppString("取消")) { dismiss() }
                }
            }
            .primaryToolbarAction(AppString("保存"), isEnabled: canSubmit, isWorking: isWorking) {
                Task { await submit() }
            }
            .onChange(of: current) { fieldErrors["current_password"] = nil }
            .onChange(of: new) { fieldErrors["password"] = nil }
        }
        .standardSheet([.large])
        .interactiveDismissDisabled(!current.isEmpty || !new.isEmpty)
    }

    private func submit() async {
        isWorking = true
        errorText = nil
        fieldErrors = [:]
        if await store.changePassword(current: current, new: new) {
            dismiss()
        } else {
            let fields = ServerFieldErrors.last()
            if fields.keys.contains(where: { $0 == "current_password" || $0 == "password" }) {
                fieldErrors = fields
            } else {
                errorText = store.errorText
            }
            store.errorText = nil
        }
        isWorking = false
    }
}

// MARK: - Backup codes

private struct BackupCodesSheet: View {
    let codes: [String]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    BackupCodesList(codes: codes)
                }
                .padding(Theme.pagePadding)
            }
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle(AppString("备用码"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(AppString("完成")) { dismiss() }
                }
            }
        }
        .standardSheet([.medium, .large])
    }
}

/// The codes, with what they are for and a way to copy them all.
private struct BackupCodesList: View {
    let codes: [String]

    var body: some View {
        if !codes.isEmpty {
            Text(AppString("请保存这些备份码。每个只能用一次，可在无法使用验证器时登录。"))
                .font(Theme.body(13)).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(codes, id: \.self) { c in
                    Text(c).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous))
            Button {
                UIPasteboard.general.string = codes.joined(separator: "\n")
                ToastCenter.shared.show(AppString("已复制"))
            } label: {
                Label(AppString("复制全部"), systemImage: "doc.on.doc")
                    .font(Theme.body(14, weight: .semibold))
            }
            .foregroundStyle(Theme.accent)
        }
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
    @State private var deviceName = AppString("身份验证器")
    @State private var backupCodes: [String] = []
    @State private var isWorking = false
    @State private var enabled = false
    @State private var failed = false
    @State private var errorText: String?

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
                .padding(Theme.pagePadding)
            }
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle(AppString("两步验证"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(enabled ? AppString("完成") : AppString("取消")) { dismiss() }
                }
                if !enabled {
                    PrimaryToolbarAction(
                        title: AppString("启用"),
                        isEnabled: code.count >= 6 && setup != nil,
                        isWorking: isWorking
                    ) {
                        Task { await enable() }
                    }
                }
            }
        }
        .standardSheet([.large])
        .task {
            if setup == nil {
                setup = await store.createTOTP()
                if setup == nil { failed = true }
            }
        }
    }

    @ViewBuilder
    private var setupView: some View {
        Text("用身份验证器 App 扫描二维码，或手动输入密钥。")
            .font(Theme.body(13)).foregroundStyle(Theme.textSecondary)

        if let qr = setup?.qr, let image = qrImage(qr) {
            image.resizable().interpolation(.none).scaledToFit()
                .frame(width: 200, height: 200)
                .padding(10)
                .background(Color.white, in: RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous))
                .frame(maxWidth: .infinity)
        } else if failed {
            Text(AppString("无法开始设置，请稍后重试。"))
                .font(Theme.body(13)).foregroundStyle(Theme.danger)
                .frame(maxWidth: .infinity).frame(height: 120)
        } else if setup == nil {
            ProgressView().frame(maxWidth: .infinity).frame(height: 200)
        }

        if let key = setup?.key {
            Text(key)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(Theme.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous))
        }

        TextField("6 位验证码", text: $code)
            .textFieldStyle(.plain).font(Theme.body(15))
            .keyboardType(.numberPad)
            .textContentType(.oneTimeCode)
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous))

        if let errorText {
            Text(errorText).font(Theme.body(12)).foregroundStyle(Theme.danger)
        }

    }

    private func enable() async {
        isWorking = true
        errorText = nil
        if let codes = await store.enableTOTP(token: code, name: deviceName) {
            backupCodes = codes
            enabled = true
        } else {
            errorText = store.errorText
            store.errorText = nil
        }
        isWorking = false
    }

    @ViewBuilder
    private var backupCodesView: some View {
        Label(AppString("两步验证已开启"), systemImage: "checkmark.shield.fill")
            .font(Theme.body(15, weight: .semibold)).foregroundStyle(Theme.success)

        BackupCodesList(codes: backupCodes)
    }

    /// The backend sends the `otpauth://` URI itself (Discourse sent a
    /// `data:image/png;base64,…` picture), so the code is drawn here; the old
    /// data-URL-only path left the sheet spinning forever.
    private func qrImage(_ value: String) -> Image? {
        if value.hasPrefix("data:") {
            guard let comma = value.firstIndex(of: ","),
                  let data = Data(base64Encoded: String(value[value.index(after: comma)...])),
                  let ui = UIImage(data: data) else { return nil }
            return Image(uiImage: ui)
        }
        guard !value.isEmpty else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cgImage = CIContext().createCGImage(output, from: output.extent)
        else { return nil }
        return Image(uiImage: UIImage(cgImage: cgImage))
    }
}

// MARK: - Browser helper

/// Opens a site-relative path in the in-app browser.
@MainActor
func openWeb(_ path: String) {
    if let url = URL(string: path, relativeTo: DiscourseConfig.baseURL)?.absoluteURL {
        BrowserState.shared.open(url)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
