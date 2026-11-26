//
//  DiscourseShape.swift
//  nodeloc
//
//  The adapter: turns the backend's `/api/v1` payloads into the JSON shapes
//  the app's models (`DiscourseModels.swift`) decode. The screens and stores
//  were written against those models, and they also cache "the server's own
//  bytes" to re-decode later (`ProfileSnapshot`, `ChatStorage`), so producing
//  the same shape — and decoding it through the same models — keeps every one
//  of those paths working with a single decoding path, as before.
//
//  Keys are snake_case because the models decode with `.convertFromSnakeCase`.
//

import Foundation

@MainActor
enum DiscourseShape {
    typealias Object = [String: Any]

    static var state: NodelocAdapterState { .shared }

    // MARK: Helpers

    static func time(_ raw: String?) -> Any {
        NLDate.normalize(raw) ?? NSNull()
    }

    static func value(_ optional: Any?) -> Any {
        optional ?? NSNull()
    }

    /// The models treat an avatar template with `{size}` as Discourse's; a
    /// plain URL passes through `avatarURL(template:)` unchanged.
    static func avatar(_ raw: String?, username: String? = nil) -> Any {
        if let raw, !raw.isEmpty { return raw }
        if let username, let known = state.avatar(for: username) { return known }
        return NSNull()
    }

    static func user(username: String, id: Int? = nil, name: String? = nil, avatar raw: String? = nil) -> Object {
        state.remember(username: username, id: id, avatar: raw)
        return [
            "id": id.flatMap { $0 > 0 ? $0 : nil } ?? state.userID(for: username),
            "username": username,
            "name": value(name),
            "avatar_template": avatar(raw, username: username),
        ]
    }

    // MARK: Nodes

    static func category(_ node: NLNode, children: [NLNode]? = nil, isMine: Bool = false) -> Object {
        let mine = state.myNodes[node.slug]
        var object: Object = [
            "id": node.id,
            "name": node.name,
            "slug": node.slug,
            "color": value(node.color),
            "topic_count": value(node.topicCount),
            "post_count": value(node.postCount),
            "member_count": value(node.memberCount),
            "description": value(node.description),
            "description_excerpt": value(node.description),
            "parent_category_id": value(node.parentId),
            "is_joined": mine != nil || (node.joined ?? false),
            "is_creator": isMine || mine?.role == "owner",
            "url": "/n/\(node.slug)",
            "style_type": node.logoUrl != nil ? "square" : (node.icon != nil ? "emoji" : "square"),
            "emoji": value(node.icon),
        ]
        if let logo = node.logoUrl { object["uploaded_logo"] = ["url": logo] }
        if let level = mine?.notificationLevel ?? node.notificationLevel {
            object["notification_level"] = notificationLevel(node: level)
        } else if state.mutedNodes.contains(node.slug) {
            object["notification_level"] = 0
        }
        if let children {
            object["subcategory_list"] = children.map { category($0) }
        }
        return object
    }

    /// Node levels as Discourse's `NotificationLevels` integers.
    static func notificationLevel(node level: String) -> Int {
        switch level {
        case "watching": return 3
        case "tracking": return 2
        case "muted": return 0
        default: return 1
        }
    }

    static func nodeLevel(fromDiscourse level: Int) -> String {
        switch level {
        case 3, 4: return "watching"
        case 2: return "tracking"
        case 0: return "muted"
        default: return "normal"
        }
    }

    // MARK: Topic lists

    static func topicListItem(_ topic: NLTopicSummary) -> Object {
        let nodeID = state.nodeID(forSlug: topic.nodeSlug)
        state.setNode(slug: topic.nodeSlug, topicID: topic.id)
        state.remember(username: topic.author, id: topic.authorId, avatar: topic.authorAvatar)
        let authorID = state.userID(for: topic.author)
        let replies = topic.replyCount ?? 0
        let highest = topic.lastReadPostNumber.map { $0 + (topic.unreadCount ?? 0) }
        var object: Object = [
            "id": topic.id,
            "title": topic.title,
            "slug": "topic",
            "posts_count": replies + 1,
            "reply_count": replies,
            "like_count": max(topic.voteScore ?? 0, 0),
            "op_like_count": max(topic.voteScore ?? 0, 0),
            "views": value(topic.views),
            "created_at": time(topic.createdAt),
            "last_posted_at": time(topic.lastPostedAt ?? topic.createdAt),
            "bumped_at": time(topic.bumpedAt ?? topic.lastPostedAt ?? topic.createdAt),
            "category_id": nodeID,
            "pinned": topic.pinned ?? false,
            "pinned_globally": false,
            "archetype": "regular",
            "excerpt": value(topic.excerpt),
            "last_read_post_number": value(topic.lastReadPostNumber),
            "highest_post_number": value(highest),
            "tags": (topic.tags ?? []).map { ["name": $0, "slug": $0] as Object },
            "posters": [["user_id": authorID, "description": "Original Poster"] as Object],
        ]
        if let image = topic.imageUrl { object["image_url"] = image }
        // The first post's id and the reader's vote let the row vote in place.
        if let firstPost = topic.firstPostId {
            let viewerVote = state.overrides(for: firstPost)?.viewerVote ?? topic.viewerVote ?? 0
            object["op_post_id"] = firstPost
            object["op_vote_score"] = topic.voteScore ?? 0
            object["op_vote_direction"] = vote(direction: viewerVote)
            object["op_can_vote_down"] = state.me.map { $0.username.lowercased() != topic.author.lowercased() } ?? false
            object["liked"] = viewerVote > 0
        }
        if let level = state.topicLevels[topic.id] { object["notification_level"] = level }
        if topic.solved == true { object["solved"] = true }
        if topic.hidden == true { object["topic_hidden"] = true }
        // Only a manager's response carries these; absence is "not a manager
        // here", which is different from "no reports".
        if let reports = topic.reportCount { object["report_count"] = reports }
        if let item = topic.reviewItemId { object["review_item_id"] = item }
        return object
    }

    /// A node's pinned rows, shaped like any other list so the same card
    /// renders them. `pinned_until` rides along for the "until" line.
    static func pinnedCarousel(_ pins: [NLNodePins.Pin], nodeSlug: String) -> Object {
        var rows: [Object] = []
        var users: [Object] = []
        var seen = Set<String>()
        for pin in pins {
            let slug = pin.nodeSlug ?? nodeSlug
            let nodeID = state.nodeID(forSlug: slug)
            state.setNode(slug: slug, topicID: pin.id)
            let author = pin.author ?? ""
            state.remember(username: author, id: nil, avatar: pin.authorAvatar)
            if !author.isEmpty, seen.insert(author.lowercased()).inserted {
                users.append(user(username: author, avatar: pin.authorAvatar))
            }
            let replies = pin.replyCount ?? 0
            var row: Object = [
                "id": pin.id,
                "title": pin.title,
                "slug": "topic",
                "posts_count": replies + 1,
                "reply_count": replies,
                "like_count": max(pin.voteScore ?? 0, 0),
                "op_like_count": max(pin.voteScore ?? 0, 0),
                "created_at": time(pin.createdAt),
                "last_posted_at": time(pin.createdAt),
                "bumped_at": time(pin.createdAt),
                "category_id": nodeID,
                "pinned": true,
                "pinned_globally": false,
                "archetype": "regular",
                "excerpt": value(pin.excerpt),
                "pinned_at": time(pin.pinnedAt),
                "pinned_until": time(pin.pinnedUntil),
                "posters": [["user_id": state.userID(for: author), "description": "Original Poster"] as Object],
            ]
            if let image = pin.imageUrl { row["image_url"] = image }
            rows.append(row)
        }
        return ["users": users, "topic_list": ["topics": rows] as Object]
    }

    static func users(for topics: [NLTopicSummary]) -> [Object] {
        var seen = Set<String>()
        var out: [Object] = []
        for topic in topics where seen.insert(topic.author.lowercased()).inserted {
            out.append(user(username: topic.author, avatar: topic.authorAvatar))
        }
        return out
    }

    static func latest(_ topics: [NLTopicSummary], hasMore: Bool) -> Object {
        var list: Object = ["topics": topics.map(topicListItem)]
        if hasMore { list["more_topics_url"] = "/latest?page=next" }
        return ["users": users(for: topics), "topic_list": list]
    }

    // MARK: Posts and topics

    static func vote(direction viewerVote: Int) -> String {
        viewerVote > 0 ? "up" : (viewerVote < 0 ? "down" : "none")
    }

    static func topicPost(_ post: NLPost, canModerate: Bool, nested: Bool = false) -> Object {
        let overrides = state.overrides(for: post.id)
        let upvotes = overrides?.upvotes ?? post.upvotes ?? 0
        let downvotes = overrides?.downvotes ?? post.downvotes ?? 0
        let viewerVote = overrides?.viewerVote ?? post.viewerVote ?? 0
        let me = state.me
        let yours = me.map { $0.id == post.authorId || $0.username.lowercased() == post.author.lowercased() } ?? false
        let deleted = post.deleted ?? false
        var object: Object = [
            "id": post.id,
            "username": post.author,
            "name": NSNull(),
            "avatar_template": avatar(post.authorAvatar, username: post.author),
            "created_at": time(post.createdAt),
            "cooked": NodelocMarkup.cooked(post.html),
            "post_number": post.postNumber,
            "reply_to_post_number": value(post.replyToPostNumber),
            // Upvotes double as likes, so the reader's like counters and the
            // vote control agree.
            "actions_summary": [["id": 2, "count": upvotes, "acted": viewerVote > 0] as Object],
            "version": value(post.version),
            "vote_score": upvotes - downvotes,
            "vote_direction": vote(direction: viewerVote),
            "can_vote_down": !yours,
            "user_title": value(post.authorTitle),
            // The server's own answer when it sent one (topic pages do).
            "can_edit": post.canEdit ?? (!deleted && (yours || canModerate)),
            "can_delete": post.canDelete ?? (!deleted && (yours || canModerate)),
            "can_recover": deleted && (yours || canModerate),
            "can_view_edit_history": (post.version ?? 1) > 1,
            "yours": yours,
            "bookmarked": overrides?.bookmarked ?? post.viewerBookmarked ?? false,
        ]
        if deleted {
            object["deleted_at"] = time(post.editedAt ?? post.createdAt)
            object["deleted_post_placeholder"] = true
            // Who removed it, and why, so the placeholder reads like the web's
            // ("deleted by the author" / "deleted by a moderator · reason").
            object["deleted_by_kind"] = value(post.deletedBy)
            object["delete_reason"] = value(post.deleteReason)
        }
        if post.authorBlocked == true {
            object["ignored_post_placeholder"] = true
        }
        if let reports = post.reportCount { object["report_count"] = reports }
        if let item = post.reviewItemId { object["review_item_id"] = item }
        if let group = post.authorGroup {
            object["flair_name"] = group.label ?? group.name
        }
        if nested {
            object["direct_reply_count"] = post.replies ?? post.replyCount ?? 0
            object["total_descendant_count"] = post.replies ?? post.replyCount ?? 0
        }
        return object
    }

    static func topicResponse(
        _ detail: NLTopicDetail,
        polls: [Int: [NLPoll]] = [:],
        lottery: NLLottery? = nil,
        redEnvelope: NLRedEnvelope? = nil
    ) -> Object {
        let topic = detail.topic
        let canModerate = detail.permissions?.moderate ?? false
        let me = state.me
        let first = detail.posts.first { $0.postNumber == 1 }
        let isAuthor = me.map { first?.authorId == $0.id || topic.author?.lowercased() == $0.username.lowercased() } ?? false
        var posts: [Object] = []
        for post in detail.posts {
            var object = topicPost(post, canModerate: canModerate)
            if let postPolls = polls[post.id] {
                object["polls"] = postPolls.map(poll)
                var votes: Object = [:]
                for item in postPolls {
                    let chosen = item.options.filter { $0.chosen == true }.map { String($0.id) }
                    if !chosen.isEmpty { votes[item.name] = chosen }
                }
                object["polls_votes"] = votes
            }
            if post.postNumber == 1, let lottery {
                object["lottery"] = self.lottery(lottery)
            }
            if let redEnvelope, post.postNumber > 1,
               let claim = redEnvelope.claims?.first(where: { $0.postId == post.id }) {
                object["red_envelope_claim"] = [
                    "post_id": post.id,
                    "points_received": value(claim.points),
                    "created_at": time(claim.createdAt),
                ] as Object
            }
            posts.append(object)
        }
        let nodeID = state.nodeID(forSlug: topic.nodeSlug)
        state.setNode(slug: topic.nodeSlug, topicID: topic.id)
        if let level = topic.notificationLevel {
            state.topicLevels[topic.id] = level == "watching" ? 3 : (level == "muted" ? 0 : 1)
        }
        var object: Object = [
            "id": topic.id,
            "title": topic.title,
            "slug": "topic",
            "posts_count": (topic.replyCount ?? 0) + 1,
            "like_count": max(topic.voteScore ?? 0, 0),
            "views": value(topic.views),
            "category_id": nodeID,
            "created_at": time(topic.createdAt),
            "post_stream": ["posts": posts, "stream": detail.posts.map(\.id)] as Object,
            "closed": topic.closed ?? false,
            "archived": false,
            "pinned": topic.pinned ?? false,
            "unpinned": false,
            "pinned_globally": false,
            "archetype": "regular",
            "details": [
                "can_edit": first?.canEdit ?? (isAuthor || canModerate),
                "can_delete": first?.canDelete ?? (isAuthor || canModerate),
                "can_moderate": canModerate,
                "can_close_topic": canModerate,
                "can_pin_unpin_topic": canModerate,
                "can_banner_topic": false,
            ] as Object,
        ]
        if topic.pinned == true {
            object["pinned_at"] = time(topic.createdAt)
            object["pinned_until"] = time(topic.pinnedUntil)
        }
        if let redEnvelope {
            object["red_envelope"] = self.redEnvelope(redEnvelope)
        }
        object["can_accept_answer"] = topic.canAccept ?? false
        if let answer = topic.acceptedAnswer {
            object["accepted_answer"] = acceptedAnswer(answer)
        }
        if let removal = topic.removal {
            object["removal"] = self.removal(removal)
        }
        return object
    }

    /// What a manager did to the first post. Passed through as it arrived —
    /// the server already decided which of these keys this reader may see.
    static func removal(_ removal: NLRemoval) -> Object {
        [
            "kind": value(removal.kind),
            "reason": value(removal.reason),
            "by": value(removal.by),
            "by_staff": removal.byStaff ?? false,
            "at": time(removal.at),
            "reputation_penalty": value(removal.reputationPenalty),
            "refunded": removal.refunded ?? false,
            "strikes_90d": value(removal.strikes90d),
            "appealable": removal.appealable ?? false,
            "appealed": removal.appealed ?? false,
            "appeal_deadline": time(removal.appealDeadline),
            "reputation_before": value(removal.reputationBefore),
            "reputation_after": value(removal.reputationAfter),
            "can_appeal": removal.canAppeal ?? false,
            "review_item_id": value(removal.reviewItemId),
        ]
    }

    /// The best-answer card's fields. Shared by the topic and `/thread`, which
    /// carries the same two keys at its top level.
    static func acceptedAnswer(_ answer: NLAcceptedAnswer) -> Object {
        [
            "post_id": answer.postId,
            "post_number": value(answer.postNumber),
            "username": value(answer.username),
            "accepted_by": value(answer.acceptedBy),
        ]
    }

    /// `/thread` rows (flat, with depth) → the nested view's roots with their
    /// children inlined.
    static func nestedRoots(_ posts: [NLPost], canModerate: Bool, rootDepth: Int = 1) -> [Object] {
        var roots: [Object] = []
        // Rows arrive depth-first, so a stack of open ancestors rebuilds the
        // tree.
        var stack: [(depth: Int, object: Object)] = []

        func close(downTo depth: Int) {
            while let last = stack.last, last.depth >= depth {
                stack.removeLast()
                if stack.isEmpty {
                    roots.append(last.object)
                } else {
                    var parent = stack.removeLast()
                    var children = parent.object["children"] as? [Object] ?? []
                    children.append(last.object)
                    parent.object["children"] = children
                    stack.append(parent)
                }
            }
        }

        for post in posts {
            let depth = post.depth ?? rootDepth
            close(downTo: depth)
            var object = topicPost(post, canModerate: canModerate, nested: true)
            object["children"] = [Object]()
            stack.append((depth, object))
        }
        close(downTo: Int.min)
        return roots
    }

    static func poll(_ poll: NLPoll) -> Object {
        var object: Object = [
            "id": poll.id,
            "name": poll.name,
            "type": value(poll.type),
            "status": poll.closed == true ? "closed" : "open",
            "results": value(poll.results),
            "min": value(poll.min),
            "max": value(poll.max),
            "voters": value(poll.voters),
            "close": time(poll.closeAt),
            "public": poll.public ?? false,
        ]
        object["options"] = poll.options.map { option -> Object in
            var item: Object = ["id": String(option.id), "html": option.text]
            if let votes = option.votes { item["votes"] = votes }
            return item
        }
        return object
    }

    static func lottery(_ lottery: NLLottery) -> Object {
        let me = state.me?.username.lowercased()
        let participants = lottery.participants ?? []
        let mine = lottery.myTickets ?? 0
        var winners: [Object] = []
        for prize in lottery.prizes ?? [] {
            for winner in prize.winners ?? [] {
                winners.append([
                    "username": winner.username,
                    "avatar_template": value(winner.avatarUrl),
                    "level_name": value(prize.name),
                    "prize": value(prize.prize),
                ])
            }
        }
        return [
            "id": lottery.id,
            "title": value(lottery.title),
            "post_id": value(lottery.postId),
            "min_participants": value(lottery.minParticipants),
            "max_participants": (lottery.maxParticipants ?? 0) == 0 ? 1_000_000 : lottery.maxParticipants!,
            "max_tickets_per_user": value(lottery.maxTickets),
            "min_trust_level": value(lottery.minTrustLevel),
            "draw_at": time(lottery.drawAt),
            "status": value(lottery.status),
            "levels": (lottery.prizes ?? []).enumerated().map { index, prize -> Object in
                ["id": index + 1, "name": value(prize.name), "prize": value(prize.prize), "quantity": value(prize.quantity)]
            },
            "tickets_count": value(lottery.ticketCount),
            "participants_count": value(lottery.participantCount),
            "user_tickets": mine,
            "is_participating": mine > 0 || participants.contains { $0.username.lowercased() == me },
            "can_draw": false,
            "can_manage": false,
            "can_close": false,
            "participants": participants.map { holder -> Object in
                ["username": holder.username, "avatar_template": value(holder.avatarUrl), "tickets": value(holder.tickets)]
            },
            "winners": winners,
        ]
    }

    static func redEnvelope(_ envelope: NLRedEnvelope) -> Object {
        let total = envelope.totalCount ?? 0
        let claimed = envelope.claimedCount ?? 0
        return [
            "id": envelope.topicId,
            "topic_id": envelope.topicId,
            "total_points": value(envelope.totalPoints),
            "total_count": total,
            "claimed_count": claimed,
            "remaining_points": value(envelope.remainingPoints),
            "available_count": max(total - claimed, 0),
            "exhausted": envelope.ended ?? (claimed >= total),
            "claim_percentage": total > 0 ? Double(claimed) / Double(total) * 100 : 0,
            "created_at": time(envelope.createdAt),
        ]
    }

    // MARK: Users

    static func currentUser(_ user: NLUser, avatar: String?, unreadNotifications: Int, unreadMessages: Int, balance: Int?) -> Object {
        [
            "current_user": [
                "id": user.id,
                "username": user.username,
                "name": value(user.name),
                "avatar_template": value(avatar.flatMap { $0.isEmpty ? nil : $0 }),
                "admin": user.role == "admin",
                "moderator": user.role == "moderator",
                "can_delete_account": !user.isStaff,
                "can_create_community": true,
                "can_create_poll": true,
                "gamification_score": value(balance),
                "unread_notifications": unreadNotifications,
                "new_personal_messages_notifications_count": unreadMessages,
                "groups": [Object](),
            ] as Object,
        ]
    }

    static func userProfile(_ profile: NLUserProfile, avatar: String?) -> Object {
        let user = profile.user
        let stats = profile.stats
        let isMe = state.me?.id == user.id
        var object: Object = [
            "id": user.id,
            "username": user.username,
            "name": value(user.name),
            "avatar_template": value(avatar ?? user.avatarUrl),
            "created_at": time(user.createdAt),
            "title": value(user.title ?? user.tierName),
            "trust_level": value(user.trustLevel),
            "admin": user.role == "admin",
            "moderator": user.role == "moderator",
            "post_count": value(stats?.postCount),
            "topic_count": value(stats?.topicCount),
            "likes_received": value(stats?.votesReceived),
            "total_followers": value(user.followerCount ?? stats?.followerCount),
            "total_following": value(user.followingCount ?? stats?.followingCount),
            "can_follow": !isMe,
            "is_followed": user.viewerFollowing ?? profile.viewer?.following ?? false,
            "ignored": user.viewerBlocked ?? profile.viewer?.blocked ?? false,
        ]
        if let cover = user.coverUrl, !cover.isEmpty {
            object["profile_background_upload_url"] = cover
            object["card_background_upload_url"] = cover
        }
        if let bio = user.bioRaw, !bio.isEmpty { object["bio_raw"] = bio }
        if let html = user.bioHtml, !html.isEmpty {
            object["bio_excerpt"] = DiscourseFormat.plainTextParagraphs(html)
        } else if let bio = user.bioRaw, !bio.isEmpty {
            object["bio_excerpt"] = bio
        }
        if let website = user.website, !website.isEmpty {
            object["website"] = website
            object["website_name"] = URL(string: website)?.host ?? website
        }
        if let location = user.location, !location.isEmpty { object["location"] = location }
        // How many achievements are unlocked, and the public nodes this user
        // owns — the profile's "n / N 已解锁" and 管理的节点.
        object["achievement_count"] = value(user.achievementCount)
        object["owned_nodes"] = (user.ownedNodes ?? []).map {
            ["slug": $0.slug, "name": $0.name] as Object
        }
        return ["user": object, "badges": [Object]()]
    }

    // MARK: Notifications

    /// Backend kinds → the Discourse notification types the formatter and
    /// router already describe.
    static func notification(_ item: NLNotification) -> Object {
        let data = item.data
        var payload: Object = [:]
        let type: Int
        var topicTitle = item.topicTitle
        switch item.kind {
        case "mention": type = 1
        case "reply": type = 2
        case "vote": type = 5
        case "message":
            type = 6
            topicTitle = data?["excerpt"]?.string
            if let conversation = data?["conversation"]?.int { payload["chat_channel_id"] = conversation }
        case "watching", "followed_topic", "repost": type = 9
        case "node_topic", "node_hot_topic": type = 17
        case "follow":
            type = 800
            topicTitle = AppString("关注了你")
        default:
            // system and anything newer: shown by its own title and body,
            // which the backend already wrote in the reader's language.
            type = 14
            topicTitle = data?["title"]?.string ?? topicTitle
            if let body = data?["body"]?.string { payload["body"] = body }
        }
        if let topicTitle { payload["topic_title"] = topicTitle }
        if let actor = item.actor, item.kind != "system" {
            payload["display_username"] = item.actorCount.map { $0 > 1 ? "\(actor) +\($0 - 1)" : actor } ?? actor
            payload["username"] = actor
        }
        return [
            "id": item.id,
            "notification_type": type,
            "read": item.read,
            "created_at": time(item.createdAt),
            "data": payload,
            "topic_id": value(item.topicId),
            "post_number": value(item.postNumber),
            "slug": "topic",
        ]
    }

    // MARK: Chat

    static func chatUser(_ username: String, avatar raw: String? = nil) -> Object {
        if let me = state.me, me.username.lowercased() == username.lowercased() {
            return ["id": me.id, "username": me.username, "name": value(me.name), "avatar_template": value(state.myAvatar)]
        }
        state.remember(username: username, id: nil, avatar: raw)
        return [
            "id": state.userID(for: username),
            "username": username,
            "name": NSNull(),
            "avatar_template": avatar(raw, username: username),
        ]
    }

    static func lastMessage(excerpt: String?, kind: String?, sender: String?, at: String?) -> Object {
        var text = excerpt ?? ""
        switch kind {
        case "image": text = AppString("[图片]")
        case "video": text = AppString("[视频]")
        case "sticker": text = AppString("[表情]")
        case "deleted": text = AppString("[消息已删除]")
        case "event": text = text.isEmpty ? AppString("[系统消息]") : text
        default: break
        }
        var object: Object = ["message": text, "excerpt": text, "cooked": text, "created_at": time(at)]
        if let sender, !sender.isEmpty { object["user"] = chatUser(sender) }
        return object
    }

    static func chatChannel(_ channel: NLChatChannel) -> Object {
        state.store(conversation: .init(id: channel.id, kind: .channel, username: nil, name: channel.name))
        return [
            "id": channel.id,
            "title": channel.name,
            "slug": value(channel.slug),
            "description": value(channel.description),
            "chatable_type": "Category",
            "chatable": ["id": channel.id, "name": channel.name, "slug": value(channel.slug)] as Object,
            "last_message": lastMessage(excerpt: channel.excerpt, kind: channel.lastKind, sender: channel.lastSender, at: channel.lastMessageAt),
            "current_user_membership": [
                "unread_count": channel.unreadCount ?? 0,
                "following": channel.joined ?? false,
                "muted": channel.muted ?? false,
                "notification_level": (channel.muted ?? false) ? "never" : "mention",
            ] as Object,
        ]
    }

    static func chatGroup(_ group: NLChatGroup) -> Object {
        state.store(conversation: .init(id: group.id, kind: .group, username: nil, name: group.name))
        let members = (group.members ?? []).filter { $0.lowercased() != state.me?.username.lowercased() }
        return [
            "id": group.id,
            "title": group.name,
            "chatable_type": "DirectMessage",
            "chatable": [
                "id": group.id,
                "name": group.name,
                "group": true,
                "users": members.map { chatUser($0) },
            ] as Object,
            "last_message": lastMessage(excerpt: group.excerpt, kind: group.lastKind, sender: group.lastSender, at: group.lastMessageAt),
            "current_user_membership": [
                "unread_count": group.unreadCount ?? 0,
                "following": true,
                "muted": group.muted ?? false,
                "notification_level": (group.muted ?? false) ? "never" : "always",
            ] as Object,
        ]
    }

    static func chatDirect(_ direct: NLChatDirect) -> Object {
        state.store(conversation: .init(id: direct.id, kind: .direct, username: direct.with, name: direct.with))
        let sender = direct.lastFromMe == true ? state.me?.username : direct.with
        return directChannel(id: direct.id, with: direct.with, avatar: direct.avatar, last: lastMessage(
            excerpt: direct.excerpt, kind: direct.lastKind, sender: sender, at: direct.lastMessageAt
        ), unread: direct.unreadCount ?? 0, muted: direct.muted ?? false)
    }

    static func directChannel(id: Int, with username: String, avatar: String?, last: Object?, unread: Int, muted: Bool) -> Object {
        var object: Object = [
            "id": id,
            "title": username,
            "chatable_type": "DirectMessage",
            "chatable": [
                "id": id,
                "group": false,
                "users": [chatUser(username, avatar: avatar)],
            ] as Object,
            "current_user_membership": [
                "unread_count": unread,
                "following": true,
                "muted": muted,
                "notification_level": muted ? "never" : "always",
            ] as Object,
        ]
        if let last { object["last_message"] = last }
        return object
    }

    static func chatChannels(_ overview: NLChatOverview) -> Object {
        let publicChannels = overview.channels.map(chatChannel)
        let directs = overview.groups.map(chatGroup) + overview.directs.map(chatDirect)
        var tracking: Object = [:]
        for channel in overview.channels {
            tracking[String(channel.id)] = ["unread_count": channel.unreadCount ?? 0, "mention_count": channel.mentionCount ?? 0] as Object
        }
        for group in overview.groups {
            tracking[String(group.id)] = ["unread_count": group.unreadCount ?? 0, "mention_count": group.mentionCount ?? 0] as Object
        }
        for direct in overview.directs {
            tracking[String(direct.id)] = ["unread_count": direct.unreadCount ?? 0, "mention_count": 0] as Object
        }
        return [
            "public_channels": publicChannels,
            "direct_message_channels": directs,
            "tracking": ["channel_tracking": tracking] as Object,
        ]
    }

    static func chatMessage(_ message: NLChatMessage, channelID: Int) -> Object {
        let deleted = message.deleted ?? false
        var html = message.html
        if let event = message.event {
            html = "<p>\(eventText(event, actor: message.sender))</p>"
        }
        var object: Object = [
            "id": message.id,
            "message": DiscourseFormat.plainText(html),
            "cooked": NodelocMarkup.cooked(html),
            "excerpt": NodelocMarkup.excerpt(html, limit: 120),
            "created_at": time(message.createdAt),
            "chat_channel_id": channelID,
            "user": chatUser(message.sender, avatar: message.avatar),
            "available_flags": [Any](),
            "reactions": [Any](),
        ]
        if deleted { object["deleted_at"] = time(message.createdAt) }
        if let reply = message.reply {
            var quoted: Object = ["id": reply.id, "excerpt": value(reply.excerpt), "message": value(reply.excerpt), "cooked": value(reply.excerpt)]
            if let sender = reply.sender, !sender.isEmpty { quoted["user"] = chatUser(sender) }
            if reply.kind == "image" { quoted["excerpt"] = AppString("[图片]") }
            if reply.kind == "deleted" { quoted["excerpt"] = AppString("[消息已删除]") }
            object["in_reply_to"] = quoted
        }
        return object
    }

    static func eventText(_ event: NLChatEvent, actor: String) -> String {
        let names = (event.users ?? []).map(\.username).joined(separator: "、")
        switch event.type {
        case "group_created": return AppString("\(actor) 创建了群聊")
        case "member_added": return AppString("\(actor) 邀请 \(names) 加入了群聊")
        case "member_removed": return AppString("\(actor) 将 \(names) 移出了群聊")
        case "member_left": return AppString("\(actor) 退出了群聊")
        case "group_renamed": return AppString("\(actor) 将群聊改名为「\(event.name ?? "")」")
        case "owner_transferred": return AppString("\(actor) 将群主转让给了 \(names)")
        case "channel_created": return AppString("\(actor) 创建了频道「\(event.name ?? "")」")
        default: return AppString("[系统消息]")
        }
    }

    /// The server pages newest-first; the models expect oldest-first.
    static func chatMessages(_ page: NLChatPage, channelID: Int) -> Object {
        let ordered = page.messages.sorted { $0.id < $1.id }
        if let newest = ordered.last?.id {
            state.newestMessageID[channelID] = max(state.newestMessageID[channelID] ?? 0, newest)
        }
        return [
            "messages": ordered.map { chatMessage($0, channelID: channelID) },
            "meta": [
                "can_load_more_past": page.nextBefore != nil,
                "can_load_more_future": false,
            ] as Object,
        ]
    }

    // MARK: Uploads

    static func upload(_ upload: NLUpload) -> Object {
        state.store(upload: upload)
        let ext = (upload.filename as NSString?)?.pathExtension ?? (upload.url as NSString).pathExtension
        return [
            "id": upload.id,
            "url": upload.url,
            "original_filename": value(upload.filename),
            "filesize": value(upload.size),
            "width": value(upload.width),
            "height": value(upload.height),
            "extension": ext,
        ]
    }

    // MARK: Custom feeds

    static func customFeed(_ feed: NLCustomFeed) -> Object {
        var object: Object = [
            "id": feed.id,
            "name": feed.name,
            "slug": String(feed.id),
            "description": value(feed.description),
            "color": value(feed.color),
            "url": "/feeds/\(feed.id)",
            "username": value(feed.owner),
            "node_count": feed.nodeCount ?? feed.nodes?.count ?? 0,
            "can_edit": feed.mine ?? false,
            "private": !(feed.public ?? true),
            "show_on_profile": feed.public ?? true,
        ]
        if let owner = feed.owner {
            object["creator"] = ["username": owner, "avatar_template": avatar(nil, username: owner)] as Object
        }
        if let nodes = feed.nodes {
            object["nodes"] = nodes.map { node -> Object in
                let known = state.nodesBySlug[node.slug]
                return [
                    "id": known?.id ?? state.nodeID(forSlug: node.slug),
                    "name": node.name ?? known?.name ?? node.slug,
                    "slug": node.slug,
                    "color": value(node.color ?? known?.color),
                    "member_count": value(node.memberCount ?? known?.memberCount),
                    "topic_count": value(known?.topicCount),
                    "is_joined": known?.joined ?? false,
                    "uploaded_logo": known?.logoUrl.map { ["url": $0] as Object } ?? NSNull(),
                ]
            }
        }
        return object
    }
}
