//
//  BlockedUsersStore.swift
//  nodeloc
//
//  屏蔽 — one place for blocking an author, and for hiding what they wrote.
//
//  App Review guideline 1.2 asks three things of a block, and they are easy to
//  get half-right:
//
//  1. it must hide the person's content *instantly*. Discourse's ignore takes
//     effect server-side, so the next fetch is clean — but the list already on
//     screen is not, and previously nothing removed those rows. So the blocked
//     names are held here, every topic list filters through them, and because
//     this is `@Observable` the rows disappear on the same frame the block
//     succeeds, with no refetch.
//  2. it must notify the developer about the content. Blocking therefore also
//     files a `notify_moderators` flag on the post that prompted it, which is
//     the flag type Discourse routes to the staff inbox.
//  3. it must persist. The server's ignore list is authoritative, but it isn't
//     read before the first feed renders, so the set is mirrored into
//     `UserDefaults` and reloaded at launch.
//
//  Names are compared lowercased throughout: Discourse usernames are
//  case-insensitive, and a feed row's `authorUsername` keeps whatever casing
//  the serializer sent.
//

import Foundation

@MainActor
@Observable
final class BlockedUsersStore {
    static let shared = BlockedUsersStore()

    private static let defaultsKey = "app.blockedUsernames"
    private static let localOnlyKey = "app.blockedUsernames.localOnly"

    /// Lowercased usernames this reader has blocked.
    private(set) var usernames: Set<String>
    /// The subset the server refused — staff, whom Discourse lets nobody
    /// ignore. Tracked separately so `loadFromServer` doesn't un-hide them, and
    /// so unblocking them doesn't call an endpoint that would fail.
    private(set) var localOnly: Set<String>
    /// The server's own answer to whether this account may ignore anyone
    /// (`ignore_allowed_groups`, trust level 2 by default). Assume yes until
    /// told otherwise, so nothing is disabled on a stale guess.
    private(set) var canIgnoreOnServer = true

    private let client = DiscourseClient()

    private init() {
        let stored = UserDefaults.standard.stringArray(forKey: Self.defaultsKey) ?? []
        usernames = Set(stored.map { $0.lowercased() })
        let storedLocal = UserDefaults.standard.stringArray(forKey: Self.localOnlyKey) ?? []
        localOnly = Set(storedLocal.map { $0.lowercased() })
    }

    func isBlocked(_ username: String?) -> Bool {
        guard let username, !username.isEmpty else { return false }
        return usernames.contains(username.lowercased())
    }

    /// Drops everything by a blocked author. Used by every topic list, so one
    /// block empties them all at once.
    func visible(_ posts: [Post]) -> [Post] {
        guard !usernames.isEmpty else { return posts }
        return posts.filter { !isBlocked($0.authorUsername) }
    }

    /// How far a block got. The reader always stops seeing the person; how much
    /// the *server* was willing to do about it varies.
    enum Outcome {
        /// Discourse's ignore: their posts are hidden server-side too, and no
        /// notifications.
        case ignored
        /// Ignore was refused but mute was allowed: no more notifications, and
        /// their content is hidden by this app.
        case muted
        /// The server refused both — blocking staff, which Discourse doesn't
        /// permit. Hidden here regardless.
        case hiddenLocally
    }

    /// Blocks `username`, hides their content, and tells the moderators why.
    ///
    /// Does not throw. The reader asked not to see someone again, and that part
    /// is entirely ours to honour — so it happens first and unconditionally,
    /// and the server calls only decide how *far* the block reaches.
    ///
    /// That ordering matters for more than tidiness. Discourse gates ignore
    /// behind `ignore_allowed_groups`, which defaults to admins, moderators and
    /// trust level 2 — so a new account is refused with "Sorry, you can't
    /// ignore that user", and blocking used to fail outright with that error on
    /// screen. Mute needs only trust level 1, so it is tried next; and staff
    /// can be neither ignored nor muted by anyone.
    ///
    /// `reportingPostID` is the post that prompted it, when there is one — a
    /// block from a feed card or a reply has one, a block from a profile does
    /// not. The report is best-effort for the same reason.
    @discardableResult
    func block(username: String, reportingPostID: Int?) async -> Outcome {
        // The rows come off the screen on this frame, whatever the server says.
        record(username)

        var outcome = Outcome.hiddenLocally
        do {
            _ = try await client.setUserNotificationLevel(
                username: username,
                level: UserNotificationLevel.ignore.rawValue,
                expiringAt: UserNotificationLevel.ignore.expiry
            )
            outcome = .ignored
        } catch {
            // Ignore refused. Mute is the weaker form the server is far more
            // likely to allow, and it still stops the notifications.
            if (try? await client.setUserNotificationLevel(
                username: username,
                level: UserNotificationLevel.mute.rawValue
            )) != nil {
                outcome = .muted
            }
        }

        if outcome == .hiddenLocally {
            localOnly.insert(username.lowercased())
            persist()
        }

        if let reportingPostID {
            await notifyModerators(postID: reportingPostID, username: username)
        }
        return outcome
    }

    /// Blocks and reports what happened, in the reader's language.
    ///
    /// Shared so the four block entry points can't describe the same action
    /// differently — and so none of them claims notifications have stopped
    /// when the server only let us hide things locally.
    func blockAndConfirm(username: String, reportingPostID: Int?) async {
        let outcome = await block(username: username, reportingPostID: reportingPostID)
        let reported = reportingPostID != nil
        switch outcome {
        case .ignored, .muted:
            ToastCenter.shared.show(
                reported
                    ? AppString("已屏蔽 @\(username)，并已通知管理员")
                    : AppString("已屏蔽 @\(username)")
            )
        case .hiddenLocally:
            // Almost always staff, whom Discourse won't let anyone ignore. Say
            // what actually happened rather than implying more.
            ToastCenter.shared.show(AppString("已在此设备上隐藏 @\(username) 的内容"))
        }
    }

    /// Reads the account's real block list and adopts it wholesale.
    ///
    /// Authoritative, unlike `adopt`: the server's ignore *and* mute lists are
    /// what this account actually has, so a name removed on the website stops
    /// being hidden here too. Only the local-only entries are kept — the staff
    /// the server refused to ignore, which would otherwise reappear.
    ///
    /// Also records whether ignoring is permitted at all, so the block list can
    /// explain itself instead of just failing.
    @discardableResult
    func loadFromServer() async -> Bool {
        guard let username = DiscourseAuth.shared.username else { return false }
        guard let response = try? await client.user(username) else { return false }

        let server = Set(
            ((response.user.ignoredUsernames ?? []) + (response.user.mutedUsernames ?? []))
                .map { $0.lowercased() }
        )
        canIgnoreOnServer = response.user.canIgnoreUsers ?? true
        // Local-only blocks are the ones the server never accepted; keep them
        // rather than letting a reload quietly un-hide someone.
        localOnly.formUnion(usernames.subtracting(server))
        usernames = server.union(localOnly)
        persist()
        return true
    }

    /// Lifts a block: back to 常规 on the server, and out of the local set.
    ///
    /// Reports failure so the list can say so — unlike blocking, where hiding
    /// locally is always honourable, un-hiding while the server still ignores
    /// them would show content the account is set to hide.
    func unblock(username: String) async -> Bool {
        let key = username.lowercased()
        let wasLocalOnly = localOnly.contains(key)

        if !wasLocalOnly {
            guard (try? await client.setUserNotificationLevel(
                username: username,
                level: UserNotificationLevel.normal.rawValue
            )) != nil else { return false }
        }

        usernames.remove(key)
        localOnly.remove(key)
        persist()
        return true
    }

    private func record(_ username: String) {
        usernames.insert(username.lowercased())
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(Array(usernames), forKey: Self.defaultsKey)
        UserDefaults.standard.set(Array(localOnly), forKey: Self.localOnlyKey)
    }

    /// `notify_moderators` — Discourse's "something else" flag, which opens a
    /// staff message rather than a scored spam/abuse flag. That is the right
    /// one here: the reader is reporting a person's conduct, not classifying
    /// the post.
    private func notifyModerators(postID: Int, username: String) async {
        let message = AppString(
            "用户在 App 中屏蔽了 @\(username)，并将其内容举报为不当内容，请审核。"
        )
        _ = try? await client.flag(
            id: postID,
            typeID: FlagType.notifyModeratorsTypeID,
            message: message
        )
    }
}
