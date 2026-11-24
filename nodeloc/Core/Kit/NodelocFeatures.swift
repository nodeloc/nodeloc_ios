//
//  NodelocFeatures.swift
//  nodeloc
//
//  Features the screens were built for that the NodeLoc backend doesn't
//  have. Their entry points check these, so the screens stay as they are and
//  turning one on later is a one-line change once the server supports it.
//

import Foundation

nonisolated enum NodelocFeatures {
    /// Emoji reactions on chat messages.
    static let chatReactions = false
    /// Editing a sent chat message.
    static let chatEditing = false
    /// Pinned chat messages.
    static let chatPins = false
    /// Quoting chat messages into a forum post.
    static let chatTranscripts = false
    /// Chat threads and chat history search.
    static let chatThreadsAndSearch = false
    /// Topic-style private messages; direct messages live in chat.
    static let topicPrivateMessages = false
    /// The posting-device line (小尾巴) and its privacy setting.
    static let postSource = false
    /// Who reacted to a post, by face.
    static let reactionUsers = false
    /// The random video feed.
    static let videoSuggestions = false
}
