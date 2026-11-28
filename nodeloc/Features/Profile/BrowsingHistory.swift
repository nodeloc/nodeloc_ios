//
//  BrowsingHistory.swift
//  nodeloc
//
//  浏览记录 (App-iOS-Viewed). The server keeps no browsing history, so this
//  one lives on the device, per account: a topic is recorded when its reader
//  opens and its furthest floor updated when the reader closes; a node when
//  its page opens. Newest first, at most `cap` entries. It does not sync with
//  the web or between devices.
//

import SwiftUI

struct HistoryEntry: Codable, Identifiable, Hashable {
    enum Kind: String, Codable { case topic, node }

    var kind: Kind
    var topicID: Int?
    var title: String
    var nodeSlug: String?
    var nodeName: String?
    var author: String?
    var viewedAt: Date
    /// The furthest floor seen, and how many there were then.
    var lastFloor: Int?
    var totalFloors: Int?
    var votes: Int?
    var replies: Int?
    var imageURL: URL?

    var id: String {
        switch kind {
        case .topic: "t\(topicID ?? 0)"
        case .node: "n\(nodeSlug ?? "")"
        }
    }
}

@MainActor
@Observable
final class BrowsingHistory {
    static let shared = BrowsingHistory()
    static let cap = 300

    private(set) var entries: [HistoryEntry] = []
    private(set) var isPaused = false
    private var loadedKey: String?

    private var key: String { "history.v1.\(DiscourseAuth.shared.username?.lowercased() ?? "guest")" }
    private var pauseKey: String { key + ".paused" }

    func prepare() {
        guard loadedKey != key else { return }
        loadedKey = key
        isPaused = UserDefaults.standard.bool(forKey: pauseKey)
        if let data = UserDefaults.standard.data(forKey: key),
           let saved = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
            entries = saved
        } else {
            entries = []
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    func setPaused(_ paused: Bool) {
        prepare()
        isPaused = paused
        UserDefaults.standard.set(paused, forKey: pauseKey)
    }

    /// A topic's reader opened (or a node's page). Moves it to the top.
    func record(_ entry: HistoryEntry) {
        prepare()
        guard !isPaused else { return }
        var next = entry
        if let old = entries.first(where: { $0.id == entry.id }) {
            next.lastFloor = max(entry.lastFloor ?? 0, old.lastFloor ?? 0)
        }
        entries.removeAll { $0.id == entry.id }
        entries.insert(next, at: 0)
        if entries.count > Self.cap { entries.removeLast(entries.count - Self.cap) }
        save()
    }

    /// The reader closed: how far down it got.
    func updateFloor(topicID: Int, floor: Int, total: Int?) {
        prepare()
        guard !isPaused, let index = entries.firstIndex(where: { $0.kind == .topic && $0.topicID == topicID }) else { return }
        entries[index].lastFloor = max(entries[index].lastFloor ?? 0, floor)
        if let total, total > 0 { entries[index].totalFloors = total }
        save()
    }

    func remove(_ ids: Set<String>) {
        entries.removeAll { ids.contains($0.id) }
        save()
    }

    func clear() {
        entries = []
        save()
    }

    /// Topics of this node in the history, for a node row's 「看了 N 个主题」.
    func topicCount(inNode slug: String) -> Int {
        entries.filter { $0.kind == .topic && $0.nodeSlug == slug }.count
    }
}

// MARK: - Page

struct BrowsingHistoryPage: View {
    let onClose: () -> Void

    @Environment(AppState.self) private var app
    @State private var history = BrowsingHistory.shared
    @State private var filter: HistoryEntry.Kind?
    @State private var query = ""
    @State private var confirmClear = false

    private var visible: [HistoryEntry] {
        let term = query.trimmingCharacters(in: .whitespaces).lowercased()
        return history.entries.filter { entry in
            (filter == nil || entry.kind == filter)
                && (term.isEmpty || entry.title.lowercased().contains(term) || (entry.nodeSlug ?? "").contains(term))
        }
    }

    private var groups: [(String, [HistoryEntry])] {
        let calendar = Calendar.current
        var order: [String] = []
        var buckets: [String: [HistoryEntry]] = [:]
        for entry in visible {
            let label: String
            if calendar.isDateInToday(entry.viewedAt) { label = AppString("今天") }
            else if calendar.isDateInYesterday(entry.viewedAt) { label = AppString("昨天") }
            else if let week = calendar.dateInterval(of: .weekOfYear, for: Date()), week.contains(entry.viewedAt) { label = AppString("本周更早") }
            else { label = AppString("更早") }
            if buckets[label] == nil { order.append(label) }
            buckets[label, default: []].append(entry)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    // The same chips as 草稿箱, counted from the local history.
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach([HistoryEntry.Kind?.none, .some(.topic), .some(.node)], id: \.self) { kind in
                                CountFilterChip(
                                    title: kind == nil ? AppString("全部") : (kind == .topic ? AppString("帖子") : AppString("节点")),
                                    count: kind == nil ? history.entries.count : history.entries.filter { $0.kind == kind }.count,
                                    isOn: filter == kind
                                ) {
                                    withAnimation(.snappy) { filter = kind }
                                }
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                    if history.isPaused {
                        Label(AppString("记录已暂停。现在看的内容不会出现在这里，已有的记录不受影响。"), systemImage: "pause.circle")
                            .font(Theme.body(13))
                            .foregroundStyle(AdminTone.amber.text)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(AdminTone.amber.fill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }

            if visible.isEmpty {
                Section {
                    EmptyStateView(icon: "clock.arrow.circlepath", message: history.entries.isEmpty ? AppString("还没有浏览记录") : AppString("没有找到相关记录"))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 30)
                        .listRowBackground(Color.clear)
                } footer: {
                    if history.entries.isEmpty { deviceNote }
                }
                .listSectionSeparator(.hidden)
            }

            ForEach(groups, id: \.0) { label, entries in
                Section {
                    ForEach(entries) { entry in
                        Button { open(entry) } label: { HistoryRow(entry: entry, history: history) }
                            .buttonStyle(.plain)
                            .swipeActions {
                                Button(AppString("删除"), role: .destructive) { history.remove([entry.id]) }
                            }
                    }
                } header: {
                    HStack {
                        Text(label).font(Theme.body(16, weight: .bold)).foregroundStyle(Theme.text)
                        Text(AppString("\(entries.count) 条")).font(Theme.body(13)).foregroundStyle(Theme.textMuted)
                        Spacer()
                        Button(AppString("删除这一组")) { history.remove(Set(entries.map(\.id))) }
                            .font(Theme.body(13, weight: .semibold))
                            .foregroundStyle(Theme.textMuted)
                            .buttonStyle(.borderless)
                    }
                    .textCase(nil)
                }
            }

            // Where the count and the device-only note went.
            if !history.entries.isEmpty {
                Section {} footer: { deviceNote }
                    .listSectionSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        // Hidden until the list is pulled down.
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: AppString("在浏览记录里搜索"))
        .navigationTitle(AppString("浏览记录"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        history.setPaused(!history.isPaused)
                    } label: {
                        Label(history.isPaused ? AppString("恢复记录") : AppString("暂停记录"),
                              systemImage: history.isPaused ? "play" : "pause")
                    }
                    Button(role: .destructive) {
                        confirmClear = true
                    } label: {
                        Label(AppString("清空"), systemImage: "trash")
                    }
                    .disabled(history.entries.isEmpty)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel(AppString("更多"))
            }
        }
        .onAppear { history.prepare() }
        .alert(AppString("清空全部浏览记录？"), isPresented: $confirmClear) {
            Button(AppString("清空"), role: .destructive) { history.clear() }
            Button(AppString("取消"), role: .cancel) {}
        } message: {
            Text(AppString("只清除这台设备上的记录，不能恢复。"))
        }
    }

    private var deviceNote: some View {
        Text(AppString("共 \(history.entries.count) 条 · 只有你自己能看到，只保存在这台设备上"))
            .font(Theme.body(12))
            .foregroundStyle(Theme.textMuted)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
    }

    private func open(_ entry: HistoryEntry) {
        switch entry.kind {
        case .topic:
            guard let id = entry.topicID else { return }
            let floor = entry.lastFloor ?? 0
            app.openTopicPage(id: id, postNumber: floor > 1 ? floor : nil, nodeSlug: entry.nodeSlug)
        case .node:
            if let slug = entry.nodeSlug { app.openNode(slug: slug) }
        }
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry
    let history: BrowsingHistory

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    if let slug = entry.nodeSlug, let node = NodeCatalog.shared.cachedNode(slug: slug) {
                        NodeAvatar(node: node, size: 20, cornerRadius: 10)
                    }
                    Text(entry.nodeSlug.map { "n/\($0)" } ?? "")
                        .font(Theme.body(13, weight: .semibold))
                    Text("· " + [entry.kind == .node ? AppString("节点") : entry.author, entry.viewedAt.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(AppLanguage.resolved.locale))].compactMap { $0 }.joined(separator: " · "))
                        .font(Theme.body(13))
                        .foregroundStyle(Theme.textMuted)
                }
                .lineLimit(1)
                Text(entry.kind == .node ? "n/\(entry.nodeSlug ?? "") · \(entry.nodeName ?? entry.title)" : entry.title)
                    .font(Theme.body(16, weight: .bold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                progress
                if entry.kind == .topic, entry.votes != nil || entry.replies != nil {
                    HStack(spacing: 14) {
                        Label("\(entry.votes ?? 0)", systemImage: "arrow.up")
                        Label("\(entry.replies ?? 0)", systemImage: "bubble.left")
                    }
                    .labelStyle(CompactLabelStyle())
                    .font(Theme.body(12, weight: .semibold))
                    .foregroundStyle(Theme.textMuted)
                }
            }
            Spacer(minLength: 6)
            if let url = entry.imageURL {
                CachedRemoteImage(url: url) { $0.resizable().scaledToFill() } placeholder: { Theme.chip }
                    .frame(width: 72, height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var progress: some View {
        if entry.kind == .node {
            Text(AppString("看了 \(history.topicCount(inNode: entry.nodeSlug ?? "")) 个主题"))
                .font(Theme.body(12))
                .foregroundStyle(Theme.textMuted)
        } else if let total = entry.totalFloors, total > 0 {
            let floor = min(entry.lastFloor ?? 1, total)
            HStack(spacing: 8) {
                ProgressView(value: Double(floor), total: Double(total))
                    .tint(Theme.accent)
                    .frame(width: 50)
                Text(floor >= total ? AppString("看完了") : AppString("看到 #\(floor) 楼，共 \(total) 楼"))
                    .font(Theme.body(12))
                    .foregroundStyle(Theme.textMuted)
            }
        }
    }
}
