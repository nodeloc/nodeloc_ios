//
//  ComposeTags.swift
//  nodeloc
//
//  Tags on a new topic (App-iOS-Compose, -ComposeTags), and the AFF line the
//  scheme asks for: when the body has an off-site link, one line saying how
//  AFF / invite links must be marked. The app never decides whether a link is
//  AFF; it only reminds, and puts the AFF tag first in the chooser.
//
//  The node's requirements come from `GET /api/v1/nodes/{slug}` `posting`
//  (`min_tags`, `tags_restricted`, `tag_options`); the server is the one that
//  enforces them.
//

import SwiftUI

/// `GET /api/v1/nodes/{slug}` → `posting`.
nonisolated struct NLNodePosting: Codable, Sendable, Equatable {
    let minTags: Int?
    let tagsRestricted: Bool?
    let tagOptions: [String]?
}

private nonisolated struct NLNodePostingEnvelope: Codable, Sendable {
    let posting: NLNodePosting?
}

private nonisolated struct NLNodeTagList: Codable, Sendable {
    nonisolated struct Tag: Codable, Sendable {
        let name: String
        let topicCount: Int?
    }
    let tags: [Tag]
}

extension DiscourseClient {
    /// `GET /api/v1/tags?q=&limit=&node=` — site tags matching `query`, most
    /// used first; with no query, the most used overall.
    func searchTags(_ query: String, node: String?, limit: Int = 12) async -> [String] {
        var items = [URLQueryItem(name: "limit", value: String(limit))]
        if !query.isEmpty { items.append(URLQueryItem(name: "q", value: query)) }
        if let node, !node.isEmpty { items.append(URLQueryItem(name: "node", value: node)) }
        guard let list: NLNodeTagList = try? await get("api/v1/tags", query: items) else { return [] }
        return list.tags.map(\.name)
    }

    func nodePosting(slug: String) async throws -> NLNodePosting? {
        let envelope: NLNodePostingEnvelope = try await get("api/v1/nodes/\(Self.pathEscape(slug))")
        return envelope.posting
    }

    /// The tags a topic in this node may take: the node's own list when it
    /// restricts them, else the ones in use there, most used first.
    func nodeTagChoices(slug: String, posting: NLNodePosting?) async -> [String] {
        if posting?.tagsRestricted == true, let options = posting?.tagOptions, !options.isEmpty {
            return options
        }
        guard let list: NLNodeTagList = try? await get("api/v1/nodes/\(Self.pathEscape(slug))/tags") else {
            return posting?.tagOptions ?? []
        }
        return list.tags.sorted { ($0.topicCount ?? 0) > ($1.topicCount ?? 0) }.map(\.name)
    }
}

/// Whether text has a link to somewhere other than this site.
enum OffsiteLinkDetector {
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    static func hasOffsiteLink(_ text: String) -> Bool {
        guard let detector, !text.isEmpty else { return false }
        let range = NSRange(text.startIndex..., in: text)
        for match in detector.matches(in: text, range: range) {
            guard let url = match.url, let host = url.host?.lowercased() else { continue }
            if url.scheme == "mailto" { continue }
            if host == "nodeloc.com" || host.hasSuffix(".nodeloc.com") { continue }
            return true
        }
        return false
    }
}

/// 含 AFF / 邀请链接的请在链接前写 #AFF，主题还要加 AFF 标签；推广请发到推广节点。
struct AffLinkHint: View {
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "link")
                .font(.system(size: 14, weight: .semibold))
                .padding(.top, 2)
            (Text(AppString("含 AFF / 邀请链接的请在链接前写 ")) + Text("#AFF").bold().foregroundColor(Theme.text)
                + Text(AppString("，主题还要加 AFF 标签；推广请发到推广节点。")))
                .font(Theme.body(13))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Theme.textMuted)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// The row under the composer's title bar: the chosen tags and 「+ 标签」.
struct ComposeTagRow: View {
    let tags: [String]
    let onAdd: () -> Void
    /// Takes a tag off right here — tapping the chip or its ×.
    var onRemove: ((String) -> Void)? = nil

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(tags, id: \.self) { tag in
                Button { onRemove?(tag) } label: {
                    HStack(spacing: 2) {
                        TagLookChip(name: tag)
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.textFaint)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
                .accessibilityLabel(AppString("移除标签 \(tag)"))
            }
            Button(action: onAdd) {
                HStack(spacing: 3) {
                    Image(systemName: "plus").font(.system(size: 11, weight: .bold))
                    Text(AppString("标签"))
                }
                .font(Theme.body(12, weight: .medium))
                .foregroundStyle(Theme.textMuted)
                .padding(.horizontal, 9)
                .frame(height: 24)
                .overlay(Capsule().strokeBorder(Theme.divider, lineWidth: 1))
                .contentShape(Capsule())
            }
            .buttonStyle(.pressable)
            .accessibilityLabel(AppString("选标签"))
        }
    }
}

/// 选标签: AFF on top (pressed when the body has an off-site link), then the
/// node's tags.
struct ComposeTagPicker: View {
    let nodeSlug: String
    let options: [String]
    let minTags: Int
    let hasOffsiteLink: Bool
    /// The node allows only its own list (`tags_restricted`): no search, no
    /// new tags. Otherwise any tag (≤ 20 characters, letters, digits, _ + . -)
    /// is accepted, up to five (content/topics.go `cleanTags`).
    var restricted = false
    @Binding var selected: [String]

    @State private var query = ""
    @State private var results: [String] = []
    /// Shown when the node has no tags of its own yet: the site's most used.
    @State private var popular: [String] = []

    @Environment(\.dismiss) private var dismiss
    private static let maximum = 5
    private static let aff = "AFF"

    var body: some View {
        NavigationStack {
        VStack(spacing: 0) {
            ModSheetHeader(title: AppString("选标签"), onCancel: { dismiss() })
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    // Search first, its matches and 新建 right under it, so
                    // they stay in view above the keyboard while typing.
                    if !restricted {
                        VStack(alignment: .leading, spacing: 8) {
                            searchField
                            if !trimmedQuery.isEmpty {
                                FlowLayout(spacing: 8) {
                                    ForEach(results, id: \.self) { tag in chip(tag) }
                                    if canCreate {
                                        Button { toggle(trimmedQuery); query = "" } label: {
                                            Label(AppString("新建标签 \(trimmedQuery)"), systemImage: "plus")
                                                .font(Theme.body(14, weight: .semibold))
                                                .foregroundStyle(Theme.accent)
                                                .padding(.horizontal, 14)
                                                .frame(height: 36)
                                                .overlay(Capsule().strokeBorder(Theme.accent.opacity(0.5), lineWidth: 1))
                                        }
                                        .buttonStyle(.pressable)
                                    }
                                }
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        ModSectionLabel(
                            title: nodeSlug.isEmpty ? AppString("全站标签")
                                : restricted ? AppString("n/\(nodeSlug) 的标签") : AppString("n/\(nodeSlug) 和全站的标签"),
                            note: minTags > 0
                                ? AppString("至少选 \(minTags) 个，最多 \(Self.maximum) 个")
                                : AppString("最多 \(Self.maximum) 个")
                        )
                        // Picked tags that aren't in the list (searched or new)
                        // stay visible, so they can be taken off again.
                        FlowLayout(spacing: 8) {
                            ForEach(shownTags, id: \.self) { tag in
                                chip(tag)
                            }
                        }
                    }
                    ModPillButton(title: AppString("完成 · 已选 \(selected.count) 个"), style: .ink, height: 50) {
                        dismiss()
                    }
                }
                .padding(.horizontal, AdminTheme.inset)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
        }
        .background(AdminTheme.pageBg)
        .standardSheet([.medium, .large])
        .task {
            // A node nobody has tagged in yet has no list of its own; the
            // site's popular tags give something to pick from.
            // Site-wide tags are open to every node that doesn't restrict
            // its own: the node's tags first, then the most used overall.
            if !restricted {
                popular = await DiscourseClient().searchTags("", node: nodeSlug.isEmpty ? nil : nodeSlug, limit: 16)
            }
        }
        .task(id: trimmedQuery) {
            guard !trimmedQuery.isEmpty else { results = []; return }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            results = await DiscourseClient().searchTags(trimmedQuery, node: nodeSlug, limit: 8)
        }
            }
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "#"))
    }

    /// The node's list (or the popular ones), plus anything picked that isn't in it.
    private var shownTags: [String] {
        var list = options
        if !restricted {
            for tag in popular where !list.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) {
                list.append(tag)
            }
        }
        for tag in selected where !list.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) {
            list.insert(tag, at: 0)
        }
        return list
    }

    /// The server's tag rule: up to 20 characters of letters, digits, _ + . -.
    private var canCreate: Bool {
        let tag = trimmedQuery
        guard !tag.isEmpty, tag.count <= 20,
              !results.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) else { return false }
        return tag.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "_+.-".unicodeScalars.contains($0) }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "number").foregroundStyle(Theme.textMuted)
            TextField(AppString("输入标签名"), text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .onSubmit { if canCreate { toggle(trimmedQuery); query = "" } }
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textFaint) }
                    .buttonStyle(.plain)
            }
        }
        .font(Theme.body(15))
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(Theme.bg, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.divider, lineWidth: 1))
    }

    private var hasAff: Bool { selected.contains { $0.caseInsensitiveCompare(Self.aff) == .orderedSame } }

    private var affCard: some View {
        HStack(spacing: 12) {
            Text(Self.aff)
                .font(Theme.body(14, weight: .bold))
                .foregroundStyle(AdminTone.amber.text)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(Theme.bg, in: Capsule())
            (Text(AppString("帖子里有 AFF / 返利 / 邀请链接或邀请码时")) + Text(AppString("必须加")).bold()
                + Text(AppString("，链接前还要写 #AFF。")))
                .font(Theme.body(13))
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                toggle(Self.aff)
            } label: {
                Text(hasAff ? AppString("已添加") : AppString("添加"))
                    .font(Theme.body(15, weight: .bold))
                    .foregroundStyle(hasAff ? Theme.text : Theme.bg)
                    .padding(.horizontal, 16)
                    .frame(height: 36)
                    .background(hasAff ? Theme.bg : Theme.text, in: Capsule())
            }
            .buttonStyle(.pressable)
        }
        .padding(12)
        .background(AdminTone.amber.fill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func chip(_ tag: String) -> some View {
        let on = selected.contains(tag)
        return Button {
            toggle(tag)
        } label: {
            HStack(spacing: 5) {
                if on { Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)) }
                Text(tag)
            }
            .font(Theme.body(14, weight: on ? .bold : .medium))
            .foregroundStyle(on ? Theme.bg : Theme.text)
            .padding(.horizontal, 14)
            .frame(height: 36)
            .background(on ? Theme.text : Theme.bg, in: Capsule())
            .overlay { if !on { Capsule().strokeBorder(Color(light: 0xC9D3D8, dark: 0x3A4440), lineWidth: 1) } }
        }
        .buttonStyle(.pressable)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func toggle(_ tag: String) {
        if let index = selected.firstIndex(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) {
            selected.remove(at: index)
        } else if selected.count < Self.maximum {
            selected.append(tag)
        } else {
            ToastCenter.shared.show(AppString("最多 \(Self.maximum) 个标签，先去掉一个再加。"))
        }
    }
}
