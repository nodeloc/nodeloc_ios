import Foundation
import XCTest
@testable import NodelocCore

/// The adapter against payloads recorded from the backend's seed data: each
/// must decode as a DTO, shape into the app's model, and keep its meaning.
final class ShapeTests: XCTestCase {
    static func fixture(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures") else {
            throw XCTSkip("missing fixture \(name)")
        }
        return try Data(contentsOf: url)
    }

    @MainActor
    private func primeNodes() throws {
        let nodes = try NodelocJSON.decode(NLNodeList.self, from: Self.fixture("nodes"))
        NodelocAdapterState.shared.reset()
        NodelocAdapterState.shared.store(nodes: nodes.nodes)
    }

    @MainActor
    func testTopicListShapesIntoLatestResponse() async throws {
        try primeNodes()
        let page = try NodelocJSON.decode(NLTopicPage.self, from: Self.fixture("topics"))
        XCTAssertFalse(page.topics.isEmpty)
        let latest: LatestResponse = try NodelocJSON.decode(object: DiscourseShape.latest(page.topics, hasMore: true))
        XCTAssertEqual(latest.topicList.topics.count, page.topics.count)
        XCTAssertNotNil(latest.topicList.moreTopicsUrl)

        let first = try XCTUnwrap(latest.topicList.topics.first)
        let source = page.topics[0]
        XCTAssertEqual(first.id, source.id)
        XCTAssertEqual(first.title, source.title)
        XCTAssertEqual(first.postsCount, (source.replyCount ?? 0) + 1)
        // The node resolves to its real id, so the screens can address it.
        let node = try XCTUnwrap(NodelocAdapterState.shared.nodesBySlug[source.nodeSlug])
        XCTAssertEqual(first.categoryId, node.id)
        // The author is reachable through posters → users, as FeedMapper reads it.
        let posterID = try XCTUnwrap(first.posters?.first?.userId)
        XCTAssertEqual(latest.users?.first { $0.id == posterID }?.username, source.author)
        // Times parse with the app's own parser.
        XCTAssertNotNil(DiscourseFormat.date(first.createdAt))
    }

    @MainActor
    func testTopicDetailShapesIntoTopicResponse() async throws {
        try primeNodes()
        let detail = try NodelocJSON.decode(NLTopicDetail.self, from: Self.fixture("topic"))
        let topic: TopicResponse = try NodelocJSON.decode(object: DiscourseShape.topicResponse(detail))
        XCTAssertEqual(topic.id, detail.topic.id)
        XCTAssertEqual(topic.postStream.posts.count, detail.posts.count)
        let op = try XCTUnwrap(topic.postStream.posts.first)
        XCTAssertEqual(op.postNumber, 1)
        XCTAssertEqual(op.username, detail.posts[0].author)
        XCTAssertEqual(op.voteScore, detail.posts[0].score)
        XCTAssertFalse((op.cooked ?? "").isEmpty)
    }

    @MainActor
    func testThreadRebuildsTheReplyTree() async throws {
        let thread = try NodelocJSON.decode(NLThreadPage.self, from: Self.fixture("thread"))
        let roots: NestedTopicResponse = try NodelocJSON.decode(object: [
            "roots": DiscourseShape.nestedRoots(thread.posts, canModerate: false),
            "has_more_roots": false,
        ])
        let depthOne = thread.posts.filter { ($0.depth ?? 1) == 1 }
        XCTAssertEqual(roots.roots?.count, depthOne.count)
        // Every deeper row hangs under the post it replies to.
        for post in thread.posts where (post.depth ?? 1) > 1 {
            let parent = try XCTUnwrap(post.replyToPostNumber)
            let holder = roots.roots?.first { $0.postNumber == parent }
            XCTAssertTrue(holder?.children?.contains { $0.id == post.id } ?? false, "post \(post.postNumber) not under \(parent)")
        }
    }

    @MainActor
    func testNotificationsMapToFormatterTypes() async throws {
        let list = try NodelocJSON.decode(NLNotifications.self, from: Self.fixture("notifications"))
        let shaped: NotificationsResponse = try NodelocJSON.decode(object: [
            "notifications": list.notifications.map(DiscourseShape.notification),
        ])
        XCTAssertEqual(shaped.notifications.count, list.notifications.count)
        for (item, source) in zip(shaped.notifications, list.notifications) where source.kind == "system" {
            // System notices are shown by their own title.
            XCTAssertEqual(item.notificationType, 14)
            XCTAssertEqual(item.data?.topicTitle, source.data?["title"]?.string)
        }
    }

    @MainActor
    func testChatOverviewShapesChannelsAndDirects() async throws {
        let overview = try NodelocJSON.decode(NLChatOverview.self, from: Self.fixture("chat"))
        let shaped: ChatChannelsResponse = try NodelocJSON.decode(object: DiscourseShape.chatChannels(overview))
        XCTAssertEqual(shaped.publicChannels?.count, overview.channels.count)
        XCTAssertEqual(shaped.directMessageChannels?.count, overview.directs.count + overview.groups.count)
        if let direct = overview.directs.first {
            let channel = try XCTUnwrap(shaped.directMessageChannels?.first { $0.id == direct.id })
            XCTAssertTrue(channel.isDirectMessage)
            XCTAssertEqual(channel.chatable?.users?.first?.username, direct.with)
            // The adapter remembers that this id is read by username.
            XCTAssertEqual(NodelocAdapterState.shared.conversations[direct.id]?.username, direct.with)
        }
    }

    @MainActor
    func testChatMessagesComeOldestFirst() async throws {
        let page = try NodelocJSON.decode(NLChatPage.self, from: Self.fixture("channel_messages"))
        let shaped: ChatMessagesResponse = try NodelocJSON.decode(object: DiscourseShape.chatMessages(page, channelID: 1))
        let ids = shaped.messages.map(\.id)
        XCTAssertEqual(ids, ids.sorted())
        XCTAssertEqual(ids.count, page.messages.count)
        XCTAssertNotNil(shaped.messages.first?.user?.username)
    }

    @MainActor
    func testUserProfileShapes() async throws {
        let profile = try NodelocJSON.decode(NLUserProfile.self, from: Self.fixture("user"))
        let shaped: UserResponse = try NodelocJSON.decode(object: DiscourseShape.userProfile(profile, avatar: nil))
        XCTAssertEqual(shaped.user.username, profile.user.username)
        XCTAssertEqual(shaped.user.postCount, profile.stats?.postCount)
    }

    @MainActor
    func testCurrentUserShapes() async throws {
        let me = try NodelocJSON.decode(NLUserEnvelope.self, from: Self.fixture("me"))
        let shaped: CurrentUserResponse = try NodelocJSON.decode(object: DiscourseShape.currentUser(
            me.user, avatar: "/uploads/a.png", unreadNotifications: 3, unreadMessages: 1, balance: 42
        ))
        XCTAssertEqual(shaped.currentUser.username, me.user.username)
        XCTAssertEqual(shaped.currentUser.unreadNotifications, 3)
        XCTAssertEqual(shaped.currentUser.gamificationScore, 42)
    }

    @MainActor
    func testCategoriesNestSubcategories() async throws {
        let nodes = try NodelocJSON.decode(NLNodeList.self, from: Self.fixture("nodes"))
        let section = try XCTUnwrap(nodes.nodes.first { $0.parentId == nil })
        let children = nodes.nodes.filter { $0.parentId == section.id }
        let shaped: CategoriesResponse = try NodelocJSON.decode(object: [
            "category_list": ["categories": [DiscourseShape.category(section, children: children)]],
        ])
        XCTAssertEqual(shaped.categoryList.categories.first?.subcategoryList?.count, children.count)
    }
}
