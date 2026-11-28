//
//  EditHistorySheet.swift
//  nodeloc
//
//  编辑历史: every saved version of a post, a word-level comparison with the
//  version before it, and a rollback for whoever may edit the post.
//

import SwiftUI

/// Which post the sheet is about, and whether this viewer may roll it back.
struct EditHistoryTarget: Identifiable {
    let postID: Int
    /// The server's `can_edit` on the post. Rolling back is an edit, so the
    /// same permission gates it; the server is still the real gate.
    let canRestore: Bool
    var id: Int { postID }
}

/// The sheet behind 已编辑 N 次.
///
/// Versions run newest first, the way the design lists them, with the current
/// one marked. Picking one shows either what it changed against the version
/// before it (对比上一版) or its whole text (此版全文). Unchanged paragraphs
/// fold into a "… N 段未改动" line so a one-word fix in a long post is not a
/// scroll hunt.
struct EditHistorySheet: View {
    let target: EditHistoryTarget
    let load: () async throws -> [NLRevision]
    let restore: (Int) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var revisions: [NLRevision] = []
    @State private var selected: Int?
    @State private var mode: Mode = .compare
    @State private var isLoading = true
    @State private var loadFailed = false
    @State private var confirmRestore: Int?
    @State private var isRestoring = false

    private enum Mode: Hashable { case compare, full }

    private var newestFirst: [NLRevision] { revisions.reversed() }
    private var currentNumber: Int? { revisions.last?.number }

    private var selectedRevision: NLRevision? {
        guard let selected else { return revisions.last }
        return revisions.first { $0.number == selected }
    }

    private func previous(of revision: NLRevision) -> NLRevision? {
        revisions.last { $0.number < revision.number }
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if loadFailed || revisions.isEmpty {
                    EmptyStateView(
                        icon: "clock.arrow.circlepath",
                        message: loadFailed
                            ? AppString("编辑历史加载失败，请稍后重试")
                            : AppString("这条内容还没有编辑过")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    content
                }
            }
            .background(Theme.bg)
            .navigationTitle("编辑历史")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .disabled(isRestoring)
        }
        .standardSheet([.large])
        .task { await reload() }
        .alert(
            AppString("回滚到 v\(confirmRestore ?? 0)？"),
            isPresented: Binding(
                get: { confirmRestore != nil },
                set: { if !$0 { confirmRestore = nil } }
            )
        ) {
            Button(AppString("回滚")) {
                guard let number = confirmRestore else { return }
                confirmRestore = nil
                Task {
                    isRestoring = true
                    let ok = await restore(number)
                    isRestoring = false
                    if ok { dismiss() }
                }
            }
            Button("取消", role: .cancel) { confirmRestore = nil }
        } message: {
            Text("会把这一版的内容保存为新的版本，之前的版本都还保留在历史里。")
        }
    }

    private func reload() async {
        isLoading = true
        loadFailed = false
        do {
            revisions = try await load()
            selected = revisions.last?.number
        } catch {
            loadFailed = true
        }
        isLoading = false
    }

    // MARK: Layout

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                versionList
                if let revision = selectedRevision {
                    SegmentedControl(
                        selection: $mode,
                        options: [
                            (value: Mode.compare, label: AppString("对比上一版")),
                            (value: Mode.full, label: AppString("此版全文")),
                        ]
                    )
                    revisionDetail(revision)
                }
            }
            .padding(Theme.pagePadding)
        }
        .scrollIndicators(.hidden)
    }

    /// The versions as a row of cards, newest first (design App-iOS-History):
    /// version and badges, who and when, then what changed.
    private var versionList: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(newestFirst) { revision in
                    versionCard(revision)
                }
            }
            .padding(.horizontal, Theme.pagePadding)
        }
        .scrollIndicators(.hidden)
        .padding(.horizontal, -Theme.pagePadding)
    }

    private func versionCard(_ revision: NLRevision) -> some View {
        let isSelected = revision.number == selectedRevision?.number
        let shape = RoundedRectangle(cornerRadius: Theme.radiusLg, style: .continuous)
        return Button {
            withAnimation(SegmentedControl<Mode>.switching) { selected = revision.number }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(verbatim: "v\(revision.number)")
                        .font(Theme.heading(15, weight: .semibold))
                        .foregroundStyle(isSelected ? Theme.accent : Theme.text)
                    if revision.number == currentNumber {
                        badge(AppString("当前"), tint: Theme.accent)
                    }
                    if revision.byModerator == true {
                        badge(AppString("版主"), tint: Theme.accent2_600)
                    }
                }
                Text(verbatim: "\(editorName(revision)) · \(DiscourseFormat.relative(revision.createdAt))")
                    .font(Theme.body(12))
                    .foregroundStyle(Theme.neutral700)
                    .lineLimit(1)
                Text(summary(of: revision))
                    .font(Theme.body(12, weight: .medium))
                    .foregroundStyle(Theme.neutral600)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(minWidth: 128, alignment: .leading)
            .background(isSelected ? Theme.accent.opacity(0.08) : Theme.surface, in: shape)
            .overlay {
                shape.strokeBorder(isSelected ? Theme.accent : .clear, lineWidth: 1.5)
            }
            .contentShape(shape)
        }
        .buttonStyle(.pressable)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func badge(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(Theme.body(11, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.12), in: Capsule())
    }

    @ViewBuilder
    private func revisionDetail(_ revision: NLRevision) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 12) {
                Text(detailHeader(revision))
                    .font(Theme.body(12, weight: .medium))
                    .foregroundStyle(Theme.neutral700)

                switch mode {
                case .compare:
                    compareBody(revision)
                case .full:
                    if let title = revision.title, !title.isEmpty {
                        Text(title)
                            .font(Theme.heading(20, weight: .semibold))
                            .foregroundStyle(Theme.text)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(revision.raw ?? "")
                        .font(Theme.body(15))
                        .foregroundStyle(Theme.text)
                        .lineSpacing(5)
                        .textSelection(.enabled)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusLg, style: .continuous))

            if mode == .compare, previous(of: revision) != nil {
                HStack(spacing: 14) {
                    legend(AppString("新增"), color: Theme.accent)
                    legend(AppString("删除"), color: Theme.danger)
                    Spacer()
                    Label("仅作者和版主可见", systemImage: "eye")
                        .font(Theme.body(11, weight: .medium))
                        .foregroundStyle(Theme.neutral700)
                }
            }

            if target.canRestore, revision.number != currentNumber {
                Button {
                    confirmRestore = revision.number
                } label: {
                    Label(AppString("回滚到 v\(revision.number)"), systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(SecondaryButtonStyle(block: true))
                .padding(.top, 4)
            }
        }
    }

    @ViewBuilder
    private func compareBody(_ revision: NLRevision) -> some View {
        if let before = previous(of: revision) {
            let blocks = RevisionDiff.blocks(from: before.raw ?? "", to: revision.raw ?? "")
            VStack(alignment: .leading, spacing: 12) {
                // The title, when this version changed it: diffed like a
                // paragraph, at the title's size (first posts only).
                if let old = before.title, let new = revision.title, old != new {
                    Text(attributed(RevisionDiff.characterRuns(old, new)))
                        .font(Theme.heading(20, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    switch block {
                    case .unchanged(let count):
                        Text(AppString("… \(count) 段未改动"))
                            .font(Theme.body(12, weight: .medium))
                            .foregroundStyle(Theme.neutral600)
                    case .changed(let runs):
                        Text(attributed(runs))
                            .font(Theme.body(15))
                            .lineSpacing(5)
                    }
                }
            }
        } else {
            Text("原始版本，没有可以对比的上一版。")
                .font(Theme.body(13))
                .foregroundStyle(Theme.neutral700)
        }
    }

    private func legend(_ text: String, color: Color) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color.opacity(0.18))
                .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(color, lineWidth: 1))
                .frame(width: 12, height: 12)
            Text(text)
                .font(Theme.body(11, weight: .medium))
                .foregroundStyle(Theme.neutral700)
        }
    }

    // MARK: Text

    private func editorName(_ revision: NLRevision) -> String {
        let name = revision.editor?.name?.trimmingCharacters(in: .whitespaces)
        if let name, !name.isEmpty { return name }
        return revision.editor?.username ?? AppString("已注销用户")
    }

    private func detailHeader(_ revision: NLRevision) -> String {
        var parts = ["v\(revision.number)", editorName(revision), DiscourseFormat.relative(revision.createdAt)]
        if let reason = revision.reason?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty {
            parts.append(reason)
        }
        return parts.joined(separator: " · ")
    }

    /// The right-hand note on a version row: "原始版本", "改了标题", or the
    /// characters added and removed against the version before.
    private func summary(of revision: NLRevision) -> String {
        guard let before = previous(of: revision) else { return AppString("原始版本") }
        let (added, removed) = RevisionDiff.counts(from: before.raw ?? "", to: revision.raw ?? "")
        if added == 0, removed == 0 {
            if (before.title ?? "") != (revision.title ?? "") { return AppString("改了标题") }
            return AppString("未改正文")
        }
        return "+\(added) −\(removed) " + AppString("字")
    }

    private func attributed(_ runs: [RevisionDiff.Run]) -> AttributedString {
        var result = AttributedString()
        for run in runs {
            var piece = AttributedString(run.text)
            switch run.kind {
            case .same:
                piece.foregroundColor = Theme.text
            case .inserted:
                piece.foregroundColor = Theme.accent
                piece.backgroundColor = Theme.accent.opacity(0.14)
            case .deleted:
                piece.foregroundColor = Theme.danger
                piece.backgroundColor = Theme.danger.opacity(0.10)
                piece.strikethroughStyle = .single
            }
            result += piece
        }
        return result
    }
}

// MARK: - Diff

/// Paragraph-then-character diff of two raw bodies.
///
/// Paragraphs are matched first (blank-line separated, as the composer writes
/// them), so moving between versions of a long post costs little; only a
/// paragraph that changed is diffed character by character, which is also
/// the unit that reads right for Chinese, where there are no spaces to split
/// words on.
enum RevisionDiff {
    struct Run {
        enum Kind { case same, inserted, deleted }
        let kind: Kind
        let text: String
    }

    enum Block {
        /// This many paragraphs in a row are identical in both versions.
        case unchanged(Int)
        /// One paragraph's worth of runs.
        case changed([Run])
    }

    /// Above this many cells the character table is skipped and the paragraph
    /// is shown as wholly removed and wholly added.
    private static let cellLimit = 250_000

    static func paragraphs(_ raw: String) -> [String] {
        raw.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static func blocks(from old: String, to new: String) -> [Block] {
        let ops = lcs(paragraphs(old), paragraphs(new))
        var blocks: [Block] = []
        var sameRun = 0
        var removed: [String] = []
        var added: [String] = []

        func flushChanges() {
            // Pair removed and added paragraphs in order, so an edited
            // paragraph shows inline changes rather than a whole delete and a
            // whole insert.
            let paired = min(removed.count, added.count)
            for i in 0..<paired {
                blocks.append(.changed(characterRuns(removed[i], added[i])))
            }
            for paragraph in removed.dropFirst(paired) {
                blocks.append(.changed([Run(kind: .deleted, text: paragraph)]))
            }
            for paragraph in added.dropFirst(paired) {
                blocks.append(.changed([Run(kind: .inserted, text: paragraph)]))
            }
            removed.removeAll()
            added.removeAll()
        }

        for op in ops {
            switch op {
            case .same:
                flushChanges()
                sameRun += 1
            case .deleted(let text):
                if sameRun > 0 { blocks.append(.unchanged(sameRun)); sameRun = 0 }
                removed.append(text)
            case .inserted(let text):
                if sameRun > 0 { blocks.append(.unchanged(sameRun)); sameRun = 0 }
                added.append(text)
            }
        }
        flushChanges()
        if sameRun > 0 { blocks.append(.unchanged(sameRun)) }
        return blocks
    }

    /// Characters added and removed, counted over the changed paragraphs.
    static func counts(from old: String, to new: String) -> (added: Int, removed: Int) {
        var added = 0
        var removed = 0
        for block in blocks(from: old, to: new) {
            guard case .changed(let runs) = block else { continue }
            for run in runs {
                switch run.kind {
                case .inserted: added += run.text.count
                case .deleted: removed += run.text.count
                case .same: break
                }
            }
        }
        return (added, removed)
    }

    static func characterRuns(_ old: String, _ new: String) -> [Run] {
        let a = Array(old)
        let b = Array(new)
        guard a.count * b.count <= cellLimit else {
            return [Run(kind: .deleted, text: old), Run(kind: .inserted, text: new)]
        }
        var runs: [Run] = []
        func push(_ kind: Run.Kind, _ character: Character) {
            if let last = runs.last, last.kind == kind {
                runs[runs.count - 1] = Run(kind: kind, text: last.text + String(character))
            } else {
                runs.append(Run(kind: kind, text: String(character)))
            }
        }
        for op in lcs(a, b) {
            switch op {
            case .same(let c): push(.same, c)
            case .deleted(let c): push(.deleted, c)
            case .inserted(let c): push(.inserted, c)
            }
        }
        return runs
    }

    private enum Op<T> {
        case same(T)
        case deleted(T)
        case inserted(T)
    }

    /// Classic longest-common-subsequence edit script, deletions before
    /// insertions at each change so a replaced word reads old-then-new.
    private static func lcs<T: Equatable>(_ a: [T], _ b: [T]) -> [Op<T>] {
        let n = a.count
        let m = b.count
        if n == 0 { return b.map { .inserted($0) } }
        if m == 0 { return a.map { .deleted($0) } }
        var table = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                table[i][j] = a[i] == b[j]
                    ? table[i + 1][j + 1] + 1
                    : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var ops: [Op<T>] = []
        var i = 0
        var j = 0
        while i < n, j < m {
            if a[i] == b[j] {
                ops.append(.same(a[i])); i += 1; j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                ops.append(.deleted(a[i])); i += 1
            } else {
                ops.append(.inserted(b[j])); j += 1
            }
        }
        while i < n { ops.append(.deleted(a[i])); i += 1 }
        while j < m { ops.append(.inserted(b[j])); j += 1 }
        return ops
    }
}
