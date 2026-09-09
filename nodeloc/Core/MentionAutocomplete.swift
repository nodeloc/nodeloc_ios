//
//  MentionAutocomplete.swift
//  nodeloc
//
//  @user and #node/#tag completion, the same two triggers the web composer has.
//

import Foundation

/// What the caret is sitting inside, if anything.
struct MentionToken: Equatable {
    enum Kind: Equatable {
        /// `@` — people.
        case user
        /// `#` — nodes and tags, which share one trigger on the web too.
        case reference
    }

    let kind: Kind
    /// The text after the trigger, which may be empty right after typing it.
    let query: String
    /// The trigger and query together, so replacing it is one splice.
    let range: Range<String.Index>
}

enum MentionScanner {
    /// The longest run of characters a username or slug can be. Past this the
    /// user is writing prose, not a name, and the popup should get out of the way.
    private static let maxQueryLength = 30

    /// The token the caret is in, or nil.
    ///
    /// Scans *backwards from the caret* rather than looking at the end of the
    /// text: editing in the middle of a paragraph is normal, and completing the
    /// wrong token would rewrite a different part of the draft than the one being
    /// typed in.
    static func token(in text: String, caretOffset: Int) -> MentionToken? {
        guard !text.isEmpty else { return nil }
        let clamped = min(max(caretOffset, 0), text.count)
        let caret = text.index(text.startIndex, offsetBy: clamped)

        var index = caret
        var length = 0
        while index > text.startIndex {
            let previous = text.index(before: index)
            let character = text[previous]

            if character == "@" || character == "#" {
                // A trigger only counts at the start of a word. Without this,
                // an email address or a C# in prose would open the popup.
                let beforeTrigger = previous > text.startIndex ? text[text.index(before: previous)] : " "
                guard beforeTrigger.isWhitespace || beforeTrigger.isNewline
                        || "([{【（\"'".contains(beforeTrigger) else { return nil }

                let query = String(text[text.index(after: previous)..<caret])
                return MentionToken(
                    kind: character == "@" ? .user : .reference,
                    query: query,
                    range: previous..<caret
                )
            }

            // Whitespace ends the search: the caret isn't in a token.
            if character.isWhitespace || character.isNewline { return nil }

            length += 1
            if length > maxQueryLength { return nil }
            index = previous
        }
        return nil
    }
}

/// One row in the completion list.
struct MentionSuggestion: Identifiable, Equatable {
    enum Kind: Equatable { case user, node, tag }

    let kind: Kind
    /// What goes in the draft, trigger included.
    let insertText: String
    let title: String
    var subtitle: String?
    var avatarURL: URL?
    /// Node colour, for the little square.
    var colorHex: String?

    var id: String { "\(kind)-\(insertText)" }
}

/// Drives the completion popup for one text field.
///
/// Deliberately dumb about the field itself: the view hands it text plus a caret
/// offset and gets back suggestions, so the reply composer and the post composer
/// share one implementation despite holding their drafts differently.
@MainActor
@Observable
final class MentionAutocompleteStore {
    private let client = DiscourseClient()

    private(set) var suggestions: [MentionSuggestion] = []
    private(set) var token: MentionToken?

    private var searchTask: Task<Void, Never>?
    /// The query the visible suggestions belong to, so an in-flight response for
    /// an older prefix can't overwrite newer results.
    private var currentKey: String?

    func update(text: String, caretOffset: Int) {
        guard let token = MentionScanner.token(in: text, caretOffset: caretOffset) else {
            clear()
            return
        }

        let key = "\(token.kind)-\(token.query.lowercased())"
        self.token = token
        guard key != currentKey else { return }
        currentKey = key

        searchTask?.cancel()
        searchTask = Task { [weak self] in
            // Short debounce: typing a name fires this on every keystroke, and
            // the user endpoint is a real request.
            try? await Task.sleep(for: .milliseconds(160))
            guard !Task.isCancelled else { return }
            await self?.search(token, key: key)
        }
    }

    func clear() {
        searchTask?.cancel()
        searchTask = nil
        currentKey = nil
        token = nil
        suggestions = []
    }

    /// What a caller needs to splice a suggestion in: the token's span as
    /// character offsets and the text to put there.
    ///
    /// Offsets rather than a finished string, because both composers hold an
    /// `AttributedString`. Rebuilding one from plain text would strip every
    /// bold, italic and link in the draft to insert a name.
    struct Insertion {
        let range: Range<Int>
        let replacement: String
        /// Where the caret belongs afterwards: past the name and its space, so
        /// typing continues.
        var caretOffset: Int { range.lowerBound + replacement.count }
    }

    func insertion(for suggestion: MentionSuggestion, in text: String) -> Insertion? {
        guard let token else { return nil }
        let lower = text.distance(from: text.startIndex, to: token.range.lowerBound)
        let upper = text.distance(from: text.startIndex, to: token.range.upperBound)
        clear()
        return Insertion(range: lower..<upper, replacement: suggestion.insertText + " ")
    }

    private func search(_ token: MentionToken, key: String) async {
        switch token.kind {
        case .user:
            let users = (try? await client.searchUsers(term: token.query))?.users ?? []
            guard currentKey == key else { return }
            suggestions = users.prefix(6).map { user in
                MentionSuggestion(
                    kind: .user,
                    insertText: "@\(user.username)",
                    title: user.username,
                    subtitle: user.name?.isEmpty == false && user.name != user.username ? user.name : nil,
                    avatarURL: user.avatarTemplate.flatMap { client.avatarURL(template: $0, size: 60) }
                )
            }

        case .reference:
            // Nodes come from the catalog already in memory — no request for
            // something the app has — and tags from their own endpoint.
            let nodes = await NodeCatalog.shared.matching(token.query, limit: 4)
            async let tagCall = try? client.searchTags(term: token.query, limit: 4)
            let tags = (await tagCall)?.results ?? []
            guard currentKey == key else { return }

            suggestions = nodes.map { node in
                MentionSuggestion(
                    kind: .node,
                    insertText: "#\(node.slug)",
                    title: node.name,
                    subtitle: "n/\(node.slug)",
                    colorHex: node.colorHex
                )
            } + tags.compactMap { tag in
                guard let name = tag.name ?? tag.text else { return nil }
                return MentionSuggestion(
                    kind: .tag,
                    insertText: "#\(tag.slug ?? name)",
                    title: name,
                    subtitle: tag.count.map { AppString("\($0) 个话题") }
                )
            }
        }
    }
}
