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
    var title: String?
    private(set) var avatarURL: URL?
    private(set) var cardBackgroundURL: URL?

    // Title options come from the user's badges.
    private(set) var badges: [BadgeDefinition] = []

    // 资质 (flair): chosen from the user's groups that carry a flair.
    // `allGroups` is kept too so the current flair still displays even if that
    // group no longer offers flair (an admin-set flair can be like this).
    private(set) var flairGroups: [UserGroupFlair] = []
    private(set) var allGroups: [UserGroupFlair] = []
    private(set) var flairGroupID: Int?

    /// The group currently supplying the flair, resolved from the full list.
    var currentFlairGroup: UserGroupFlair? {
        allGroups.first { $0.id == flairGroupID }
    }

    /// What the picker offers: flair-capable groups, plus the current one if it
    /// isn't already among them, so the active choice is always shown.
    var flairOptions: [UserGroupFlair] {
        var options = flairGroups
        if let current = currentFlairGroup, !options.contains(where: { $0.id == current.id }) {
            options.insert(current, at: 0)
        }
        return options
    }

    private(set) var isLoading = false
    private(set) var isSaving = false
    var errorText: String?

    private var loaded = false

    private var username: String? { DiscourseAuth.shared.username }

    /// Titles the user may pick: the display names of badges that allow a title.
    var titleOptions: [String] {
        badges.filter { $0.allowTitle == true }.map(\.name)
    }

    func load(force: Bool = false) async {
        guard let username, force || !loaded, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        if let response = try? await client.user(username) {
            apply(response.user)
            loaded = true
        }
        if let badges = try? await client.userBadges(username: username) {
            self.badges = badges.badges ?? []
        }
    }

    private func apply(_ profile: UserProfile) {
        name = profile.name ?? ""
        bio = profile.bioRaw ?? ""
        website = profile.website ?? profile.websiteName ?? ""
        location = profile.location ?? ""
        title = profile.title
        avatarURL = profile.avatarTemplate.flatMap { client.avatarURL(template: $0, size: 240) }
        cardBackgroundURL = NodeSummaryFactory.resolvedURL(profile.cardBackgroundUploadUrl)
        flairGroupID = profile.flairGroupId
        allGroups = profile.groups ?? []
        // Only groups with a flair can supply one.
        flairGroups = allGroups.filter { $0.flairUrl?.isEmpty == false }
    }

    /// Sets 资质 to a group's flair, or clears it. An empty value clears
    /// `flair_group_id` server-side.
    func setFlairGroup(_ id: Int?) async {
        flairGroupID = id
        await saveFields([("flair_group_id", id.map(String.init) ?? "")])
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
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return false
        }
    }

    func saveTextFields() async {
        await saveFields([
            ("name", name),
            ("bio_raw", bio),
            ("website", website),
            ("location", location),
        ])
    }

    /// Empty string clears the title server-side.
    func setTitle(_ newTitle: String?) async {
        title = newTitle
        await saveFields([("title", newTitle ?? "")])
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
                ToastCenter.shared.show(errorText!)
                return true
            }

            ToastCenter.shared.show(AppString("已绑定 Apple 账号"))
            return true
        } catch let error as DiscourseError {
            if case .badResponse(let code, _) = error {
                // Not deployed — the caller falls back to the web page.
                if code == 404 || code == 501 { return false }
                // The generic copy for 403/409 talks about *logging in*, which
                // is misleading here; the code is what makes this diagnosable.
                errorText = AppString("绑定失败（\(code)）")
            } else {
                errorText = error.errorDescription
            }
            ToastCenter.shared.show(errorText ?? AppString("绑定失败"))
            return true
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            ToastCenter.shared.show(errorText ?? AppString("绑定失败"))
            return true
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

    func requestPasswordReset() async {
        guard let login = username else { return }
        do {
            try await client.requestPasswordReset(login: login)
            infoText = AppString("重置密码的邮件已发送，请查收。")
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
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
        guard let result = try? await client.confirmSession(password: password) else { return false }
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

    func enableTOTP(token: String, name: String) async -> Bool {
        do {
            try await client.enableTOTP(token: token, name: name)
            totpEnabled = true
            return true
        } catch {
            errorText = AppString("验证码无效，请重试。")
            return false
        }
    }

    func disableTOTP() async {
        do {
            try await client.disableSecondFactor()
            totpEnabled = false
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func generateBackupCodes() async -> [String] {
        (try? await client.generateBackupCodes())?.backupCodes ?? []
    }
}
