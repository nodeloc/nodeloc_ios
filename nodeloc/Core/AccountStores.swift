//
//  AccountStores.swift
//  nodeloc
//
//  Editing state for the profile, associated-accounts, and security screens.
//  Kept out of Stores.swift, which is already oversized.
//

import SwiftUI

// MARK: - Profile editing

@MainActor
@Observable
final class ProfileEditStore {
    static let shared = ProfileEditStore()

    private let client = DiscourseClient()

    // Editable fields, seeded from the server and written back optimistically.
    var name = ""
    var bio = ""
    var website = ""
    var location = ""
    /// The admin-given personal 头衔 (`users.title`). Read-only here: only an
    /// admin sets it (`PUT /admin/users/{id}/title`), and it outranks the
    /// group title chosen below.
    private(set) var title: String?
    private(set) var avatarURL: URL?
    private(set) var cardBackgroundURL: URL?

    /// The groups you're in (`GET /api/v1/me/groups`) and the one you wear
    /// (`primary_group_id`, 0 = none). The worn group's 头衔 shows by your
    /// name whenever you have no personal title.
    private(set) var groups: [NLMyGroups.Group] = []
    private(set) var primaryGroupID = 0

    /// What the 头衔 picker offers: groups that grant a title, plus the worn
    /// one if it grants none, so the current choice is always listed.
    var titleGroups: [NLMyGroups.Group] {
        groups.filter { $0.title?.isEmpty == false || $0.id == primaryGroupID }
    }

    private(set) var isLoading = false
    private(set) var isSaving = false
    var errorText: String?
    /// A 422's messages by field (`name`, `bio`, `website`, `location`,
    /// `signature`), shown under the matching input.
    var fieldErrors: [String: String] = [:]

    /// The personal signature (`GET/PUT /api/v1/me/settings` → `signature`),
    /// shown under the first post of your topics.
    private(set) var signature = ""

    /// The server's limits (account/rules.go, admin.go, settings.go).
    static let nameLimit = 50
    static let bioLimit = 3000
    static let websiteLimit = 300
    static let locationLimit = 100
    static let signatureLimit = 300

    /// Something typed differs from what the server holds.
    var isDirty: Bool { isLoaded && [name, bio, website, location] != savedText }

    /// What the server would refuse, said before asking it.
    var localErrors: [String: String] {
        var errors: [String: String] = [:]
        if name.count > Self.nameLimit { errors["name"] = AppString("昵称最多 \(Self.nameLimit) 个字") }
        if bio.count > Self.bioLimit { errors["bio"] = AppString("自我介绍最多 \(Self.bioLimit) 个字") }
        let site = website.trimmingCharacters(in: .whitespaces)
        if !site.isEmpty, !(site.lowercased().hasPrefix("http://") || site.lowercased().hasPrefix("https://")) {
            errors["website"] = AppString("网址需以 http:// 或 https:// 开头")
        } else if site.count > Self.websiteLimit {
            errors["website"] = AppString("网址过长")
        }
        if location.count > Self.locationLimit { errors["location"] = AppString("所在地最多 \(Self.locationLimit) 个字") }
        return errors
    }

    /// Whose profile the fields hold. A Bool here survived a sign-out, so the
    /// next account opened the page on the previous one's fields — and closing
    /// it saved them into the new account.
    private var loadedUsername: String?

    private var username: String? { DiscourseAuth.shared.username }

    func load(force: Bool = false) async {
        guard let username, force || loadedUsername != username, !isLoading else { return }
        if loadedUsername != username { reset() }
        isLoading = true
        defer { isLoading = false }

        do {
            let response = try await client.user(username)
            apply(response.user)
            loadedUsername = username
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        await loadGroups()
        await loadSignature()
    }

    private struct SettingsEnvelope: Decodable {
        struct Settings: Decodable { let signature: String? }
        let settings: Settings?
    }

    private func loadSignature() async {
        guard let data = try? await client.http.send("GET", "api/v1/me/settings"),
              let envelope = try? NodelocJSON.decode(SettingsEnvelope.self, from: data) else { return }
        signature = envelope.settings?.signature ?? ""
    }

    /// `PUT /api/v1/me/settings {"signature"}`. A refusal's message lands in
    /// `fieldErrors["signature"]`.
    func saveSignature(_ text: String) async -> Bool {
        isSaving = true
        defer { isSaving = false }
        fieldErrors["signature"] = nil
        do {
            try await client.http.send("PUT", "api/v1/me/settings", body: .json(["signature": text]))
            signature = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return true
        } catch {
            let fields = ServerFieldErrors.last()
            fieldErrors["signature"] = fields["signature"]
                ?? (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return false
        }
    }

    private func loadGroups() async {
        guard let mine = try? await client.myGroups() else { return }
        groups = mine.groups
        primaryGroupID = mine.primaryGroupId ?? mine.groups.first { $0.primary == true }?.id ?? 0
    }

    /// Whether the fields hold the signed-in account's profile. Saving
    /// before that would overwrite it with blanks.
    var isLoaded: Bool { loadedUsername != nil && loadedUsername == username }

    private func reset() {
        name = ""; bio = ""; website = ""; location = ""; title = nil; signature = ""; fieldErrors = [:]
        avatarURL = nil; cardBackgroundURL = nil
        groups = []; primaryGroupID = 0
        loadedUsername = nil
    }

    private func apply(_ profile: UserProfile) {
        name = profile.name ?? ""
        bio = profile.bioRaw ?? ""
        website = profile.website ?? profile.websiteName ?? ""
        location = profile.location ?? ""
        savedText = [name, bio, website, location]
        title = profile.title.flatMap { $0.isEmpty ? nil : $0 }
        avatarURL = profile.avatarTemplate.flatMap { client.avatarURL(template: $0, size: 240) }
        cardBackgroundURL = NodeSummaryFactory.resolvedURL(profile.cardBackgroundUploadUrl)
    }

    /// Wears a group's 头衔 (`PUT /api/v1/me/primary-group`), or none with 0.
    /// Rolls back and reports the server's message if it refuses.
    func setPrimaryGroup(_ id: Int) async {
        let previous = primaryGroupID
        guard id != previous else { return }
        primaryGroupID = id
        isSaving = true
        defer { isSaving = false }
        do {
            try await client.setPrimaryGroup(id)
        } catch {
            primaryGroupID = previous
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: Saving

    /// Writes a set of profile fields, rolling `errorText` if the server refuses.
    /// Local fields already hold the edited values (they are bound to the UI),
    /// so there is nothing to roll back on the happy path.
    @discardableResult
    func saveFields(_ items: [(String, String)]) async -> Bool {
        guard let username else { return false }
        isSaving = true
        defer { isSaving = false }
        do {
            try await client.updateProfile(username: username, items: items)
            return true
        } catch {
            let fields = ServerFieldErrors.last()
            if fields.isEmpty {
                errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            } else {
                fieldErrors = fields
            }
            return false
        }
    }

    /// The text fields as last read from or written to the server.
    private var savedText: [String] = []

    /// Saves the text fields, when they hold this account's profile and
    /// something changed.
    @discardableResult
    func saveTextFields() async -> Bool {
        let current = [name, bio, website, location]
        guard isLoaded, current != savedText else { return true }
        guard localErrors.isEmpty else { return false }
        fieldErrors = [:]
        guard await saveFields([
            ("name", name),
            ("bio_raw", bio),
            ("website", website),
            ("location", location),
        ]) else { return false }
        savedText = current
        return true
    }

    // MARK: Avatar + background

    func uploadAvatar(_ data: Data, mimeType: String) async {
        guard let username else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            let upload = try await client.uploadUserImage(
                data: data, fileName: "avatar.\(fileExtension(mimeType))",
                mimeType: mimeType, type: "avatar"
            )
            try await client.pickAvatar(username: username, uploadID: upload.id, type: "uploaded")
            if let url = upload.url { avatarURL = NodeSummaryFactory.resolvedURL(url) }
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func uploadCardBackground(_ data: Data, mimeType: String) async {
        isSaving = true
        defer { isSaving = false }
        do {
            let upload = try await client.uploadUserImage(
                data: data, fileName: "card.\(fileExtension(mimeType))",
                mimeType: mimeType, type: "card_background"
            )
            guard let url = upload.url else { return }
            if await saveFields([("card_background_upload_url", url)]) {
                cardBackgroundURL = NodeSummaryFactory.resolvedURL(url)
            }
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func removeCardBackground() async {
        if await saveFields([("card_background_upload_url", "")]) {
            cardBackgroundURL = nil
        }
    }

    private func fileExtension(_ mime: String) -> String {
        switch mime {
        case "image/png": return "png"
        case "image/gif": return "gif"
        case "image/webp": return "webp"
        default: return "jpg"
        }
    }
}

// MARK: - Associated accounts + security

@MainActor
@Observable
final class SecurityStore {
    static let shared = SecurityStore()

    private let client = DiscourseClient()

    private(set) var associatedAccounts: [AssociatedAccount] = []
    private(set) var sessions: [UserAuthToken] = []
    private(set) var totpEnabled = false
    private(set) var isLoading = false
    var errorText: String?
    var infoText: String?

    private var username: String? { DiscourseAuth.shared.username }

    func load(force: Bool = false) async {
        guard let username, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        guard let detail = try? await client.accountDetail(username: username) else { return }
        associatedAccounts = detail.user.associatedAccounts ?? []
        sessions = detail.user.userAuthTokens ?? []
        totpEnabled = detail.user.secondFactorEnabled ?? false
    }

    // MARK: Associated accounts

    var hasAppleAccount: Bool {
        associatedAccounts.contains { $0.name.lowercased() == "apple" }
    }

    /// Binds a native Apple credential to the *signed-in* account.
    ///
    /// The same endpoint the login button uses — what changes its meaning is
    /// the session travelling with the request. Cookies are deliberately left
    /// alone here: they are how the server knows which account to attach the
    /// Apple id to. (`DiscourseLogin.completeNativeAppleLogin` clears them
    /// first, which is right for signing *in* and wrong for linking.)
    ///
    /// Returns false when the endpoint isn't deployed, so the caller can fall
    /// back to the web preferences page.
    /// Failures land in `errorText`, which the page shows as a toast.
    func linkApple(_ credential: AppleSignInCredential) async -> Bool {
        errorText = nil
        do {
            try await client.nativeAppleLogin(credential)
            await load()

            // The server can answer 200 without having bound anything — that is
            // what a login-only implementation does with a session-bearing
            // request. Reporting success on the status code alone hid exactly
            // that, so confirm against the reloaded list instead.
            guard hasAppleAccount else {
                errorText = AppString("服务端没有返回绑定结果，请稍后重试。")
                return true
            }

            ToastCenter.shared.show(AppString("已绑定 Apple 账号"))
            return true
        } catch let error as DiscourseError {
            if case .badResponse(let code, _, _) = error {
                // Not deployed — the caller falls back to the web page.
                if code == 404 || code == 501 { return false }
                // The generic copy for 403/409 talks about *logging in*, which
                // is misleading here; the code is what makes this diagnosable.
                errorText = AppString("绑定失败（\(code)）")
            } else {
                errorText = error.errorDescription
            }
            return true
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return true
        }
    }

    /// 关联账户 (App-iOS-Linked): every provider the site offers, bound or
    /// not (`GET /api/v1/me/identities`), whether the account has a password,
    /// and its e-mail for the 邮箱和密码 row.
    private(set) var identities: [NLIdentities.Identity] = []
    private(set) var hasPassword: Bool?
    private(set) var email: String?
    private(set) var identitiesLoaded = false

    func loadIdentities() async {
        if let list: NLIdentities = try? await client.get("api/v1/me/identities") {
            identities = list.identities
            hasPassword = list.hasPassword
        }
        if let me: NLUserEnvelope = try? await client.get("api/v1/me") {
            email = me.user.email
        }
        identitiesLoaded = true
    }

    /// `DELETE /api/v1/me/identities/{provider}`. The server refuses the
    /// last way in (409 `last_login_method`); its message is shown as is.
    func unlink(_ identity: NLIdentities.Identity) async {
        guard let username else { return }
        do {
            try await client.revokeAssociatedAccount(username: username, provider: identity.provider)
            await loadIdentities()
            associatedAccounts.removeAll { $0.name == identity.provider }
            ToastCenter.shared.show(AppString("已断开 \(identity.label ?? identity.provider)"))
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func revoke(_ account: AssociatedAccount) async {
        guard let username else { return }
        let snapshot = associatedAccounts
        associatedAccounts.removeAll { $0.name == account.name }
        do {
            try await client.revokeAssociatedAccount(username: username, provider: account.name)
        } catch {
            associatedAccounts = snapshot
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: Password

    /// `PUT /api/v1/me/password`. The old path mailed a reset link to the
    /// *username*, which the backend refuses (it wants an e-mail address) —
    /// while the page announced the mail as sent regardless.
    func changePassword(current: String, new: String) async -> Bool {
        errorText = nil
        do {
            try await client.http.send(
                "PUT", "api/v1/me/password",
                body: .json(["current_password": current, "new_password": new])
            )
            infoText = AppString("密码已修改")
            return true
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return false
        }
    }

    // MARK: Sessions

    func revokeSession(_ token: UserAuthToken) async {
        guard let username else { return }
        let snapshot = sessions
        sessions.removeAll { $0.id == token.id }
        do {
            try await client.revokeAuthToken(username: username, tokenID: token.id)
        } catch {
            sessions = snapshot
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func revokeAllOtherSessions() async {
        guard let username else { return }
        do {
            try await client.revokeAuthToken(username: username, tokenID: nil)
            sessions = sessions.filter { $0.isActive == true }
            infoText = AppString("已注销其它设备。")
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: Confirm session

    /// Sensitive operations need a recently password-confirmed session.
    func isSessionTrusted() async -> Bool {
        (try? await client.trustedSession())?.isTrusted ?? false
    }

    func confirm(password: String) async -> Bool {
        errorText = nil
        guard let result = try? await client.confirmSession(password: password) else {
            errorText = AppString("验证失败，请稍后重试。")
            return false
        }
        if !result.isTrusted {
            errorText = AppString("密码不正确。")
        }
        return result.isTrusted
    }

    // MARK: TOTP

    func createTOTP() async -> TOTPCreateResponse? {
        do { return try await client.createTOTP() }
        catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return nil
        }
    }

    private struct BackupCodesEnvelope: Decodable {
        var backupCodes: [String]?
    }

    /// Turns the authenticator on. The backend answers with the backup codes
    /// in the same response (there is no separate call without a code), so
    /// they come back from here; nil means it failed.
    func enableTOTP(token: String, name: String) async -> [String]? {
        errorText = nil
        do {
            let data = try await client.enableTOTP(token: token, name: name)
            totpEnabled = true
            return (try? NodelocJSON.decode(BackupCodesEnvelope.self, from: data))?.backupCodes ?? []
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? AppString("验证码无效，请重试。")
            return nil
        }
    }

    /// Turning 2FA off needs a current code (or a backup code).
    func disableTOTP(code: String) async -> Bool {
        errorText = nil
        do {
            try await client.disableSecondFactor(code: code)
            totpEnabled = false
            infoText = AppString("两步验证已关闭")
            return true
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return false
        }
    }

    /// New backup codes, which also needs a current code.
    func generateBackupCodes(code: String) async -> [String]? {
        errorText = nil
        do {
            return try await client.generateBackupCodes(code: code).backupCodes ?? []
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return nil
        }
    }
}
