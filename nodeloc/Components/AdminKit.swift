//
//  AdminKit.swift
//  nodeloc
//
//  The building blocks of the management screens (节点管理, 审核队列,
//  操作日志, 管理台, 用户管理 …), taken from the iOS admin artboards: a grey
//  grouped background with white cards, iOS-settings rows with a coloured
//  squircle icon, stat tiles, tinted status badges, filter chips and a
//  segmented control. One vocabulary so the pages can't drift apart.
//

import SwiftUI

// MARK: - Tokens

enum AdminTheme {
    /// The grouped page background (#F2F5F6).
    static let pageBg = Color(light: 0xF2F5F6, dark: 0x0B0F0E)
    /// Cards and grouped lists (#FFFFFF).
    static let card = Color(light: 0xFFFFFF, dark: 0x171C1A)
    /// Row separators inside a card (#E5EBEE).
    static let separator = Color(light: 0xE5EBEE, dark: 0x262D2A)
    /// The disclosure chevron (#C4C4C9).
    static let chevron = Color(light: 0xC4C4C9, dark: 0x5A625E)

    static let cardRadius: CGFloat = 14
    static let listRadius: CGFloat = 12
    static let inset: CGFloat = 16

    /// The squircle icon colours the artboards use for each kind of tool.
    enum IconTint {
        static let slate = Color(hex: 0x576F76)
        static let green = Color(hex: 0x007A52)
        static let blue = Color(hex: 0x1F5FBF)
        static let purple = Color(hex: 0x5F3DC4)
        static let rust = Color(hex: 0xC2410C)
        static let amber = Color(hex: 0xD9822B)
        static let brick = Color(hex: 0xA33A00)
        static let red = Color(hex: 0xC92A2A)
        static let teal = Color(hex: 0x0B7285)
        static let grey = Color(hex: 0x6B6B70)
    }
}

/// A badge's colour pair (fill, text).
enum AdminTone {
    case neutral, green, orange, amber, blue, purple

    var fill: Color {
        switch self {
        case .neutral: Color(light: 0xE5EBEE, dark: 0x262D2A)
        case .green: Color(light: 0xE3F4EC, dark: 0x133D31)
        case .orange: Color(light: 0xFFF0E6, dark: 0x3A2216)
        case .amber: Color(light: 0xFFEFD6, dark: 0x33270F)
        case .blue: Color(light: 0xE4EEFF, dark: 0x1A2638)
        case .purple: Color(light: 0xEEE8FF, dark: 0x2A2240)
        }
    }

    var text: Color {
        switch self {
        case .neutral: Color(light: 0x576F76, dark: 0x9AA39F)
        case .green: Color(light: 0x007A52, dark: 0x26D99B)
        case .orange: Color(light: 0xA33A00, dark: 0xFF9F6B)
        case .amber: Color(light: 0x8A5200, dark: 0xF5C37A)
        case .blue: Color(light: 0x1F5FBF, dark: 0x9CC0FF)
        case .purple: Color(light: 0x5F3DC4, dark: 0xB9A6FF)
        }
    }
}

// MARK: - Page chrome

/// The artboards' top bar: a 44pt glass circle on each side and the title
/// centred between them.
struct AdminHeader<Trailing: View>: View {
    let title: String
    var leadingIcon = "chevron.left"
    let onBack: () -> Void
    @ViewBuilder var trailing: () -> Trailing

    /// No bar of its own any more: the title and the trailing actions go
    /// to the system navigation bar of the stack the page is pushed on, and
    /// the system back button (and edge swipe) leave it. `onBack` is kept for
    /// the callers' sake; a pushed page never needs it.
    var body: some View {
        Color.clear
            .frame(height: 0)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { trailing() }
            }
    }
}

extension AdminHeader where Trailing == EmptyView {
    init(title: String, leadingIcon: String = "chevron.left", onBack: @escaping () -> Void) {
        self.init(title: title, leadingIcon: leadingIcon, onBack: onBack) { EmptyView() }
    }
}

/// A 44pt glass circle with one glyph — the header's buttons.
struct AdminCircleButton: View {
    let systemName: String
    var accessibilityLabel: String = ""
    let action: () -> Void

    var body: some View {
        // A plain glyph: these sit in the system navigation bar, which draws
        // the glass. Their own glass circle and shadow showed as a second,
        // offset bubble beside the system's — "two buttons overlapping".
        Button(action: action) {
            BarIcon(systemName: systemName)
        }
        .accessibilityLabel(accessibilityLabel)
    }
}

/// A glass capsule with a text label — 选择, 管理 and the like.
struct AdminCapsuleButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.body(17, weight: .semibold))
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 14)
                .frame(height: 44)
        }
        .glassButton(tint: FloatingHeader.glassTint, shape: .capsule)
        .shadow(color: .black.opacity(0.10), radius: 9, y: 6)
    }
}

// MARK: - Grouped lists

/// A titled group: 13pt muted header, then the rows in one white card.
struct AdminSection<Content: View>: View {
    var title: String?
    var footer: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                Text(title)
                    .font(Theme.body(13))
                    .foregroundStyle(Theme.textMuted)
                    .padding(.horizontal, AdminTheme.inset)
                    .padding(.bottom, 7)
            }
            VStack(spacing: 0) { content }
                .background(AdminTheme.card, in: RoundedRectangle(cornerRadius: AdminTheme.listRadius, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: AdminTheme.listRadius, style: .continuous))
            if let footer {
                Text(footer)
                    .font(Theme.body(13))
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, AdminTheme.inset)
                    .padding(.top, 7)
            }
        }
        .padding(.horizontal, AdminTheme.inset)
    }
}

/// The coloured squircle in front of a row.
struct AdminIcon: View {
    let systemName: String
    let tint: Color
    var size: CGFloat = 30

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint, in: RoundedRectangle(cornerRadius: size * 0.233, style: .continuous))
    }
}

/// One row of a grouped list: icon, title (and subtitle), a value, a chevron,
/// and the separator under it starting at the text.
struct AdminRow<Accessory: View>: View {
    var icon: String?
    var tint: Color = AdminTheme.IconTint.slate
    let title: String
    var subtitle: String?
    var value: String?
    var titleColor: Color = Theme.text
    var showsChevron = true
    var isLast = false
    var action: (() -> Void)?
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        if let action {
            Button(action: action) { content.contentShape(Rectangle()) }
                .buttonStyle(SettingsRowButtonStyle())
        } else {
            content
        }
    }

    private var content: some View {
        HStack(spacing: 12) {
            if let icon {
                AdminIcon(systemName: icon, tint: tint)
            }
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(Theme.body(17))
                        .foregroundStyle(titleColor)
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(Theme.body(13))
                            .foregroundStyle(Theme.textMuted)
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let value {
                    // Wraps rather than clipping a long value (a date, a
                    // reason) and isn't the first thing squeezed.
                    Text(value)
                        .font(Theme.body(17))
                        .foregroundStyle(Theme.textMuted)
                        .lineLimit(3)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                        .layoutPriority(1)
                }
                accessory()
                if showsChevron && action != nil {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(AdminTheme.chevron)
                }
            }
            .padding(.trailing, 16)
            .padding(.vertical, subtitle == nil ? 0 : 7)
            .frame(minHeight: 44)
            .overlay(alignment: .bottom) {
                if !isLast {
                    Rectangle().fill(AdminTheme.separator).frame(height: 1)
                }
            }
        }
        .padding(.leading, 16)
    }
}

extension AdminRow where Accessory == EmptyView {
    init(
        icon: String? = nil,
        tint: Color = AdminTheme.IconTint.slate,
        title: String,
        subtitle: String? = nil,
        value: String? = nil,
        titleColor: Color = Theme.text,
        showsChevron: Bool = true,
        isLast: Bool = false,
        action: (() -> Void)? = nil
    ) {
        self.init(
            icon: icon, tint: tint, title: title, subtitle: subtitle, value: value,
            titleColor: titleColor, showsChevron: showsChevron, isLast: isLast, action: action
        ) { EmptyView() }
    }
}

// MARK: - Cards, tiles, badges, chips

extension View {
    /// A white card with the artboards' 14pt corners and 14/16 padding.
    func adminCard(padding: EdgeInsets = EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16)) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AdminTheme.card, in: RoundedRectangle(cornerRadius: AdminTheme.cardRadius, style: .continuous))
    }
}

/// A count with a tinted icon box: 待审核 9, 举报 3.
struct AdminStatTile: View {
    let icon: String
    let tone: AdminTone
    let value: String
    let label: String
    var action: (() -> Void)?

    var body: some View {
        Button { action?() } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(tone.text)
                    .frame(width: 36, height: 36)
                    .background(tone.fill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 0) {
                    Text(value)
                        .font(Theme.body(22, weight: .bold))
                        .foregroundStyle(Theme.text)
                        .monospacedDigit()
                    Text(label)
                        .font(Theme.body(12))
                        .foregroundStyle(Theme.textMuted)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(AdminTheme.card, in: RoundedRectangle(cornerRadius: AdminTheme.cardRadius, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .disabled(action == nil)
    }
}

/// A 22pt tinted capsule: 正常, 出错, 含外链, 6 人举报 …
struct AdminBadge: View {
    let text: String
    var tone: AdminTone = .neutral
    var icon: String?

    var body: some View {
        HStack(spacing: 3) {
            if let icon {
                Image(systemName: icon).font(.system(size: 10, weight: .semibold))
            }
            Text(text)
        }
        .font(Theme.body(12, weight: .semibold))
        .foregroundStyle(tone.text)
        .lineLimit(1)
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(tone.fill, in: Capsule())
    }
}

/// A filter pill: ink when selected, grey otherwise.
struct AdminFilterChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.body(14, weight: isSelected ? .bold : .medium))
                .foregroundStyle(isSelected ? Theme.bg : Theme.text)
                .lineLimit(1)
                .padding(.horizontal, 14)
                .frame(height: 34)
                .background(isSelected ? Theme.text : Theme.chip, in: Capsule())
        }
        .buttonStyle(.pressable)
    }
}

/// The iOS segmented control the queue uses: a grey track and a raised white
/// segment.
struct AdminSegmented<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, label: String)]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let selected = option.value == selection
                Button {
                    withAnimation(.quicker) { selection = option.value }
                } label: {
                    Text(option.label)
                        .font(Theme.body(13, weight: selected ? .semibold : .medium))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .frame(height: 30)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(Theme.segmentPill)
                                    .shadow(color: .black.opacity(0.14), radius: 1.5, y: 1)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Theme.chip, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

/// A full-width tinted action: 拒绝 / 通过, 忽略 / 删除.
struct AdminActionButton: View {
    let title: String
    var icon: String?
    var tone: AdminTone = .neutral
    /// Solid fill (the primary, destructive confirm) instead of a tint.
    var solid: Color?
    var height: CGFloat = 40
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon {
                    Image(systemName: icon).font(.system(size: 15, weight: .bold))
                }
                Text(title).lineLimit(1)
            }
            .font(Theme.body(15, weight: .semibold))
            .foregroundStyle(solid == nil ? tone.text : .white)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(solid ?? tone.fill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
    }
}

/// A round letter avatar in the node's colour — the hub's identity card.
struct AdminLetterAvatar: View {
    let letter: String
    var color: Color = Theme.accent
    var size: CGFloat = 44

    var body: some View {
        Text(letter)
            .font(Theme.body(size * 0.45, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color, in: Circle())
    }
}

/// A muted one-line explanation under the header (频道, 审核规则 …).
struct AdminNote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Theme.body(13))
            .foregroundStyle(Theme.textMuted)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 32)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Loading / failed / empty placeholder for a management page.
struct AdminStatePlaceholder: View {
    var isLoading: Bool
    var errorText: String?
    var emptyText: String?
    var retry: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            if isLoading {
                ProgressView().tint(Theme.accent)
            } else if let errorText {
                Text(errorText)
                    .font(Theme.body(14))
                    .foregroundStyle(Theme.textMuted)
                    .multilineTextAlignment(.center)
                if let retry {
                    Button(AppString("重试"), action: retry)
                        .font(Theme.body(14, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
            } else if let emptyText {
                Text(emptyText)
                    .font(Theme.body(14))
                    .foregroundStyle(Theme.textMuted)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
        .padding(.vertical, 48)
    }
}

/// 刚刚 / 12 分钟前 / 3 小时前 / 5 天前 / 3 个月前 / 2025-04-01 — the
/// artboards' Chinese relative times.
func adminRelative(_ iso: String?) -> String {
    guard let date = DiscourseFormat.date(iso) else { return "" }
    let seconds = Date().timeIntervalSince(date)
    if seconds < 0 {
        let days = Int(-seconds / 86_400)
        return days > 0 ? AppString("\(days) 天后") : AppString("今天")
    }
    switch seconds {
    case ..<60: return AppString("刚刚")
    case ..<3600: return AppString("\(Int(seconds / 60)) 分钟前")
    case ..<86_400: return AppString("\(Int(seconds / 3600)) 小时前")
    case ..<(86_400 * 30): return AppString("\(Int(seconds / 86_400)) 天前")
    case ..<(86_400 * 365): return AppString("\(Int(seconds / (86_400 * 30))) 个月前")
    default:
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}


/// A lone toolbar button's glyph: no frame of its own, so the system draws its
/// round glass button (a fixed frame turned it into a rounded rectangle).
/// `BarGlyph` is for buttons sharing one capsule.
struct BarIcon: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(Theme.text)
    }
}

/// One glyph in a top bar's tool capsule — the node page's and the post
/// reader's share it, so their icons match in symbol size, weight and frame.
struct BarGlyph: View {
    let systemName: String
    /// The system toolbar draws its items' symbols at this size, so a bar
    /// drawn by hand (the post reader's) passes it to look the same; inside
    /// a system toolbar the default is scaled up to it anyway.
    var size: CGFloat = 17

    static let height: CGFloat = 36
    /// The size the system toolbar's glyphs come out at.
    static let systemToolbarSize: CGFloat = 20

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(Theme.text)
            .frame(width: 40, height: Self.height)
            .contentShape(Rectangle())
    }
}
