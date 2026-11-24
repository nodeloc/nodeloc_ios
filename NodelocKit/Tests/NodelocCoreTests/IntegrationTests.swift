import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import NodelocCore

/// End-to-end against a running backend with the demo seed data
/// (`nodeloc seed`). Skipped unless `NODELOC_IT_BASE_URL` is set, e.g.
///
///     NODELOC_IT_BASE_URL=http://127.0.0.1:8180 swift test
///
/// Writes to that instance (a reply, a vote, a bookmark, direct messages), so
/// point it at a throwaway database only.
final class IntegrationTests: XCTestCase {
    static let password = ProcessInfo.processInfo.environment["NODELOC_IT_PASSWORD"] ?? "nodeloc-demo-2026"

    final class MemoryStore: CredentialStore {
        var values: [String: String] = [:]
        func get(_ account: String) -> String? { values[account] }
        func set(_ value: String, for account: String) { values[account] = value }
        func delete(_ account: String) { values[account] = nil }
    }

    struct Session {
        let auth: DiscourseAuth
        let login: DiscourseLogin
        let client: DiscourseClient
    }

    private func baseURL() throws -> URL {
        guard let raw = ProcessInfo.processInfo.environment["NODELOC_IT_BASE_URL"], let url = URL(string: raw) else {
            throw XCTSkip("NODELOC_IT_BASE_URL not set")
        }
        return url
    }

    @MainActor
    private func signIn(_ username: String) async throws -> Session {
        let base = try baseURL()
        let auth = DiscourseAuth()
        let login = DiscourseLogin(auth: auth, baseURL: base, store: MemoryStore())
        try await login.login(identifier: username, password: Self.password)
        XCTAssertTrue(auth.isAuthenticated)
        // URLSession sends no Sec-Fetch-Mode, so the server hands this client
        // a bearer token rather than only the website cookie.
        guard case .bearer = auth.credential else {
            XCTFail("expected a bearer token, got \(String(describing: auth.credential))")
            return Session(auth: auth, login: login, client: DiscourseClient(baseURL: base, auth: auth))
        }
        XCTAssertEqual(auth.username, username)
        return Session(auth: auth, login: login, client: DiscourseClient(baseURL: base, auth: auth))
    }

    @MainActor
    func testReaderAndWriterJourney() async throws {
        NodelocAdapterState.shared.reset()
        let alice = try await signIn("alice")
        let client = alice.client

        // Who am I.
        let me = try await client.currentUser()
        XCTAssertEqual(me.currentUser.username, "alice")

        // Wrong password and the second-factor signal surface as AuthError.
        let other = DiscourseLogin(auth: DiscourseAuth(), baseURL: try baseURL(), store: MemoryStore())
        do {
            try await other.login(identifier: "alice", password: "wrong-password-123")
            XCTFail("wrong password signed in")
        } catch AuthError.loginFailed(let message) {
            XCTAssertFalse(message.isEmpty)
        }

        // Site, nodes.
        let site = try await client.site()
        XCTAssertFalse(site.categories?.isEmpty ?? true)
        let categories = try await client.categories(includeSubcategories: true)
        XCTAssertFalse(categories.categoryList.categories.isEmpty)

        // Feeds: latest pages by cursor, hot and the personal feed by offset.
        let latest = try await client.topicList(feed: .latest)
        XCTAssertFalse(latest.topicList.topics.isEmpty)
        let hot = try await client.topicList(feed: .hot)
        XCTAssertFalse(hot.topicList.topics.isEmpty)
        let best = try await client.topicList(feed: .best)
        XCTAssertFalse(best.topicList.topics.isEmpty)

        // A node's own list.
        let nodeTopic = try XCTUnwrap(latest.topicList.topics.first { ($0.categoryId ?? 0) > 0 })
        let nodeList = try await client.nodeTopics(path: "", categoryID: nodeTopic.categoryId!)
        XCTAssertTrue(nodeList.topicList?.topics.contains { $0.categoryId == nodeTopic.categoryId } ?? false)

        // A topic with replies: OP, reply tree, children.
        let busy = try XCTUnwrap(latest.topicList.topics.filter { ($0.postsCount ?? 0) > 2 && $0.categoryId != nil }.first)
        let topic = try await client.topic(id: busy.id)
        XCTAssertEqual(topic.postStream.posts.first?.postNumber, 1)
        let tree = try await client.nestedTopic(id: busy.id, sort: "best")
        XCTAssertFalse(tree.roots?.isEmpty ?? true)
        if let parent = tree.roots?.first(where: { ($0.directReplyCount ?? 0) > 0 }), let number = parent.postNumber {
            let children = try await client.nestedChildren(topicID: busy.id, postNumber: number, sort: "best")
            XCTAssertFalse(children.children?.isEmpty ?? true)
        }
        // Somebody else's points are private.
        do {
            _ = try await client.pointsTotal(username: "bob")
            XCTFail("another user's balance was served")
        } catch DiscourseError.unsupported {}
        let mine = try await client.pointsTotal(username: "alice")
        XCTAssertNotNil(mine.totalScores)

        // Reply, then find it by id the way the reader does after posting.
        let created = try await client.reply(topicID: busy.id, raw: "来自 iOS 适配层的集成测试回复 \(UUID().uuidString.prefix(6))")
        let replyID = try XCTUnwrap(created.id)
        let fetched = try await client.topicPosts(topicID: busy.id, postIDs: [replyID])
        XCTAssertEqual(fetched.postStream.posts.first?.id, replyID)
        XCTAssertEqual(fetched.postStream.posts.first?.yours, true)

        // Vote on someone else's reply; the cached copy follows.
        let target = try XCTUnwrap(tree.roots?.first { $0.username != "alice" })
        _ = try await client.castVote(postID: target.id, direction: .up)
        let voted = try await client.topicPosts(topicID: busy.id, postIDs: [target.id])
        XCTAssertEqual(voted.postStream.posts.first?.voteDirection, .up)
        _ = try await client.castVote(postID: target.id, direction: .none)

        // Bookmark shows up in the profile's bookmarks activity.
        _ = try await client.bookmark(postID: target.id)
        let bookmarks = try await client.userActions(username: "alice", filter: 3)
        XCTAssertTrue(bookmarks.userActions.contains { $0.postId == target.id })
        let folders = try await client.bookmarkFolders()
        XCTAssertEqual(folders.total, bookmarks.userActions.count)
        _ = try await client.removeBookmark(postID: target.id)

        // Notifications and unread marking.
        let notifications = try await client.notifications()
        XCTAssertFalse(notifications.notifications.isEmpty)
        _ = try await client.markNotificationsRead()

        // Profile and summary, with follow state round-tripping.
        let bob = try await client.user("bob")
        XCTAssertEqual(bob.user.username, "bob")
        _ = try await client.userSummary("bob")
        try await client.follow(username: "bob")
        let followed = try await client.user("bob")
        XCTAssertEqual(followed.user.isFollowed, true)
        XCTAssertEqual(followed.user.totalFollowers, (bob.user.totalFollowers ?? 0) + 1)
        try await client.unfollow(username: "bob")

        // Profile activity: Bob's topics and replies, paged by the screen's
        // row count.
        let bobTopics = try await client.userActions(username: "bob", filter: 4)
        XCTAssertFalse(bobTopics.userActions.isEmpty)
        XCTAssertTrue(bobTopics.userActions.allSatisfy { $0.username == "bob" && $0.postNumber == 1 })
        let bobReplies = try await client.userActions(username: "bob", filter: 5)
        XCTAssertFalse(bobReplies.userActions.isEmpty)
        let more = try await client.userActions(username: "bob", filter: 5, offset: bobReplies.userActions.count)
        XCTAssertTrue(Set(more.userActions.map(\.id)).isDisjoint(with: bobReplies.userActions.map(\.id)))

        // Voting from a list row, on the first post the summary names.
        let row = try XCTUnwrap(latest.topicList.topics.first { $0.opPostId != nil && $0.opCanVoteDown == true })
        _ = try await client.castVote(postID: row.opPostId!, direction: .up)
        let again = try await client.topicList(feed: .latest)
        XCTAssertEqual(again.topicList.topics.first { $0.id == row.id }?.opVoteDirection, .up)
        _ = try await client.castVote(postID: row.opPostId!, direction: .none)

        // The topic bell.
        _ = try await client.setTopicNotification(topicID: busy.id, level: 3)
        let watched = try await client.topicList(feed: .latest)
        XCTAssertEqual(watched.topicList.topics.first { $0.id == busy.id }?.notificationLevel, 3)
        _ = try await client.setTopicNotification(topicID: busy.id, level: 1)

        // Search: posts when the server has a search API, users and nodes
        // always.
        let search = try await client.search("VPS")
        XCTAssertNotNil(search.categories ?? search.topics)

        // Tags and mention lookup.
        _ = try await client.searchTags(term: "")
        let users = try await client.searchUsers(term: "bo")
        XCTAssertTrue(users.users?.contains { $0.username == "bob" } ?? false)

        // Upload an image.
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")!
        let upload = try await client.uploadChatMedia(data: png, fileName: "dot.png", mimeType: "image/png")
        XCTAssertTrue(upload.url?.contains("/uploads/") ?? false)

        // That image as the avatar: /me reports it, no second call needed.
        _ = try await client.pickAvatar(username: "alice", uploadID: upload.id)
        let withAvatar = try await client.currentUser()
        XCTAssertNotNil(withAvatar.currentUser.avatarTemplate)

        // The search API: posts and their topics.
        let found = try await client.search("Go")
        XCTAssertFalse(found.posts?.isEmpty ?? true)
        XCTAssertFalse(found.topics?.isEmpty ?? true)

        // Check-in answers either way without throwing.
        _ = try await client.checkIn()

        // Joining and leaving a node by the id the screens hold.
        let joinable = try XCTUnwrap(NodelocAdapterState.shared.allNodes.first { $0.parentId != nil && $0.joined != true })
        _ = try await client.joinNode(categoryID: joinable.id)
        let joined = try await client.sidebarNodes()
        XCTAssertTrue(joined.communities?.contains { $0.id == joinable.id } ?? false)
        XCTAssertNotNil(NodelocAdapterState.shared.myNodes[joinable.slug])
        _ = try await client.setCategoryNotification(categoryID: joinable.id, level: 3)
        XCTAssertEqual(NodelocAdapterState.shared.myNodes[joinable.slug]?.notificationLevel, "watching")
        _ = try await client.leaveNode(categoryID: joinable.id)

        // A custom feed: create, add a node, list its topics, delete.
        let feed = try await client.createCustomFeed(name: "测试订阅", description: "", isPrivate: true, showOnProfile: false)
        let withNode = try await client.addCustomFeedNode(feedID: feed.customFeed.id, categoryID: nodeTopic.categoryId!)
        XCTAssertEqual(withNode.customFeed.nodes?.first?.id, nodeTopic.categoryId)
        let feedTopics = try await client.customFeedTopics(username: "alice", slug: feed.customFeed.slug)
        XCTAssertNotNil(feedTopics.topicList)
        try await client.deleteCustomFeed(id: feed.customFeed.id)

        // Edit the reply, read it back raw, delete it.
        let raw = try await client.postRaw(id: replyID)
        XCTAssertTrue(raw.raw?.contains("集成测试") ?? false)
        _ = try await client.updatePost(id: replyID, raw: (raw.raw ?? "") + "（已编辑）")
        _ = try await client.deletePost(id: replyID)

        // Bob was replied to? At least his notifications load and shape.
        let bobSession = try await signIn("bob")
        _ = try await bobSession.client.notifications()
    }

    @MainActor
    func testDirectMessageWithLiveEvent() async throws {
        NodelocAdapterState.shared.reset()
        let alice = try await signIn("alice")
        let carol = try await signIn("carol")

        // Carol opens the stream before Alice writes.
        let realtime = NodelocRealtime.shared
        realtime.client = carol.client
        let received = expectation(description: "chat event reaches carol")
        received.assertForOverFulfill = false
        let handler = realtime.addHandler { event in
            if event.event == "chat", event.data.contains("\"new\"") { received.fulfill() }
        }
        defer { realtime.removeHandler(handler); realtime.client = DiscourseClient() }
        try await Task.sleep(nanoseconds: 1_500_000_000)

        // Alice starts (or continues) the conversation with Carol.
        let channel = try await alice.client.createDirectMessageChannel(usernames: ["carol"])
        let text = "集成测试私信 \(UUID().uuidString.prefix(6))"
        _ = try await alice.client.createChatMessage(channelID: channel.channel.id, message: text)

        await fulfillment(of: [received], timeout: 15)

        // Carol sees the conversation and the message.
        NodelocAdapterState.shared.reset()
        let carolChannels = try await carol.client.chatChannels()
        let direct = try XCTUnwrap(carolChannels.directMessageChannels?.first {
            $0.chatable?.users?.contains { $0.username == "alice" } ?? false
        })
        let messages = try await carol.client.chatMessages(channelID: direct.id)
        XCTAssertTrue(messages.messages.contains { DiscourseFormat.plainText($0.cooked).contains(text) })
        if let newest = messages.messages.last?.id {
            _ = try await carol.client.markChatChannelRead(channelID: direct.id, messageID: newest)
        }

        // A public channel: list, read, write.
        let channels = try await alice.client.chatChannels()
        if let lounge = channels.publicChannels?.first(where: { $0.currentUserMembership?.following == true }) {
            let before = try await alice.client.chatMessages(channelID: lounge.id)
            _ = try await alice.client.createChatMessage(channelID: lounge.id, message: "频道消息 \(UUID().uuidString.prefix(4))")
            let after = try await alice.client.chatMessages(channelID: lounge.id)
            XCTAssertGreaterThan(after.messages.last?.id ?? 0, before.messages.last?.id ?? 0)
        }

        // A conversation that doesn't exist yet keeps working under the id the
        // screen opened it with, before and after its first message.
        let fresh = try await alice.client.createDirectMessageChannel(usernames: ["grace"])
        let standIn = fresh.channel.id
        _ = try await alice.client.createChatMessage(channelID: standIn, message: "第一条消息")
        let firstPage = try await alice.client.chatMessages(channelID: standIn)
        XCTAssertFalse(firstPage.messages.isEmpty)
        if let newest = firstPage.messages.last?.id {
            _ = try await alice.client.markChatChannelRead(channelID: standIn, messageID: newest)
        }

        // Signing out ends the session server-side as well.
        carol.login.signOut()
        XCTAssertFalse(carol.auth.isAuthenticated)
    }

    /// Every read the screens make decodes into its model.
    @MainActor
    func testEveryReadDecodes() async throws {
        NodelocAdapterState.shared.reset()
        let client = try await signIn("alice").client
        _ = try await client.currentUser()
        let nodes = try await client.loadNodes()
        let section = try XCTUnwrap(nodes.first { $0.parentId == nil })
        _ = try await client.nodeBrowse(parentCategoryID: section.id)
        _ = try await client.recentlyVisitedNodes()
        _ = try await client.checkNodeSlug("zz-new")
        _ = try await client.customFeeds()
        _ = try await client.customFeedNodeSearch(term: "v")
        _ = try await client.searchTags(term: "", limit: 5)
        _ = try await client.featureFlags()
        _ = try await client.accountDetail(username: "alice")
        _ = try await client.listSecondFactors()
        _ = try await client.userBadges(username: "bob")
        _ = try await client.emojis()
        _ = try await client.pointsHistory(username: "alice")
        _ = try await client.privateMessages(username: "alice")
        _ = try await client.topicFeatureStats(categoryID: nil)
        _ = try await client.reactionUsers(postID: 1)
        _ = try await client.trustedSession()
        _ = try await client.checkUsername("alice")
        _ = try await client.checkUsername("someone-new-\(Int.random(in: 100...999))")
        _ = try await client.tagTopics(slug: "vps")
        _ = try await client.topicList(feed: .top)
        let chat = try await client.chatChannels()
        if let channel = chat.allChannels.first {
            _ = try await client.chatChannel(id: channel.id)
            _ = try await client.chatChannelMemberships(channelID: channel.id)
        }
        // The apps directory lives outside /api/v1 and may be switched off.
        _ = try? await client.appsDirectory()
    }

    /// The system-browser hand-off without the browser: a fresh session asks
    /// `/app-login` for a code (what the browser does after signing in), and
    /// the app exchanges it with its PKCE verifier.
    @MainActor
    func testAppCodeExchangeWithPKCE() async throws {
        NodelocAdapterState.shared.reset()
        let base = try baseURL()
        let alice = try await signIn("alice")

        func issueCode(_ pkce: NodelocPKCE) async throws -> String {
            var components = URLComponents(url: base.appending(path: "app-login"), resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "code_challenge", value: pkce.challenge)]
            var request = URLRequest(url: components.url!)
            if case .bearer(let token) = alice.auth.credential {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            let (_, response) = try await NoRedirect.session.data(for: request)
            let location = try XCTUnwrap((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Location"))
            XCTAssertTrue(location.hasPrefix("nodeloc://auth"), location)
            return try DiscourseLogin.socialCallback(XCTUnwrap(URL(string: location)))
        }

        // Right verifier: a new session for the same account.
        let pkce = NodelocPKCE.make()
        let code = try await issueCode(pkce)
        let auth = DiscourseAuth()
        let login = DiscourseLogin(auth: auth, baseURL: base, store: MemoryStore())
        try await login.completeSocialCode(code, codeVerifier: pkce.verifier)
        XCTAssertEqual(auth.username, "alice")
        guard case .bearer(let token) = auth.credential else { return XCTFail("no bearer token") }
        XCTAssertNotEqual(auth.credential, alice.auth.credential)
        XCTAssertFalse(token.isEmpty)
        let me = try await DiscourseClient(baseURL: base, auth: auth).currentUser()
        XCTAssertEqual(me.currentUser.username, "alice")

        // Wrong verifier: refused, and the code is spent.
        let other = NodelocPKCE.make()
        let stolen = try await issueCode(other)
        let thief = DiscourseLogin(auth: DiscourseAuth(), baseURL: base, store: MemoryStore())
        do {
            try await thief.completeSocialCode(stolen, codeVerifier: NodelocPKCE.make().verifier)
            XCTFail("a wrong verifier was accepted")
        } catch AuthError.loginFailed {}
        do {
            try await thief.completeSocialCode(stolen, codeVerifier: other.verifier)
            XCTFail("a spent code was accepted")
        } catch AuthError.loginFailed {}
    }

    /// Native Apple sign-in on a server without Apple configured: the list
    /// says so, the endpoint answers 404, and the app stops offering it.
    @MainActor
    func testAppleNativeUnavailableIsReported() async throws {
        let base = try baseURL()
        let client = DiscourseClient(baseURL: base, auth: DiscourseAuth())
        _ = try await client.authProviders()
        let login = DiscourseLogin(auth: DiscourseAuth(), baseURL: base, store: MemoryStore())
        let credential = AppleSignInCredential(identityToken: "not.a.jwt", nonce: "n", authorizationCode: nil, email: nil, fullName: nil)
        do {
            try await login.completeNativeAppleLogin(credential)
            XCTFail("a bogus Apple token signed in")
        } catch let error as DiscourseError {
            if NodelocAuthCapabilities.appleNative {
                XCTAssertEqual(error.serverCode, "apple_token_invalid")
            } else {
                XCTAssertEqual(error.statusCode, 404)
            }
        }
    }
}

/// A session that stops at the first redirect, to read `Location`.
final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let session = URLSession(configuration: .ephemeral, delegate: NoRedirect(), delegateQueue: nil)

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
