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

    // Badges + title options.
    private(set) var badges: [BadgeDefinition] = []
    private(set) var grants: [UserBadgeGrant] = []
    private(set) var maxFavoriteBadges = 2

    private(set) var isLoading = false
    private(set) var isSaving = false
    var errorText: String?

    private var loaded = false

    private var username: String? { DiscourseAuth.shared.username }

    /// Titles the user may pick: the display names of badges that allow a title.
    var titleOptions: [String] {
        let allowed = Set(badges.filter { $0.allowTitle == true }.map(\.name))
        return badges.filter { allowed.contains($0.name) }.map(\.name)
    }

    /// Badges currently featured on the profile card.
    var favoriteBadgeIDs: Set<Int> {
        Set(grants.filter { $0.isFavorite == true }.map(\.id))
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
            self.grants = badges.userBadges ?? []
        }
        // `max_favorite_badges` isn't in the client site settings the app reads,
        // so the conservative default of 2 (Discourse's own default) stands.
        // The server enforces the real cap regardless.
    }

    private func apply(_ profile: UserProfile) {
        name = profile.name ?? ""
        bio = profile.bioRaw ?? ""
        website = profile.website ?? profile.websiteName ?? ""
        location = profile.location ?? ""
        title = profile.title
        avatarURL = profile.avatarTemplate.flatMap { client.avatarURL(template: $0, size: 240) }
        cardBackgroundURL = NodeSummaryFactory.resolvedURL(profile.cardBackgroundUploadUrl)
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

    // MARK: Featured badges

    func toggleFavorite(_ grant: UserBadgeGrant) async {
        // Respect the server cap and the badge's own can_favorite flag.
        let isFav = favoriteBadgeIDs.contains(grant.id)
        if !isFav, favoriteBadgeIDs.count >= maxFavoriteBadges { return }
        guard grant.canFavorite == true else { return }

        do {
            try await client.toggleFavoriteBadge(userBadgeID: grant.id)
            // Reflect locally by flipping the grant's flag.
            grants = grants.map {
                $0.id == grant.id ? UserBadgeGrant(id: $0.id, badgeId: $0.badgeId, isFavorite: !isFav, canFavorite: $0.canFavorite) : $0
            }
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
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
            infoText = "重置密码的邮件已发送，请查收。"
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
            infoText = "已注销其它设备。"
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
            errorText = "密码不正确。"
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
            errorText = "验证码无效，请重试。"
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
