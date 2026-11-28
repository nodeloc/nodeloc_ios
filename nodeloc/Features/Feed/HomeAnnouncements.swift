//
//  HomeAnnouncements.swift
//  nodeloc
//
//  The home announcements (`GET /api/v1/announcements/home`), the JSON twin
//  of the one on the web's front page. Readable signed out, so a guest sees
//  the same rows — but a guest has no account to record a dismissal against
//  and the dismissal endpoint would answer 401, so theirs are kept on the
//  device. A signed-in reader's go to the server and follow them everywhere.
//

import SwiftUI

@MainActor
@Observable
final class HomeAnnouncementStore {
    private let client = DiscourseClient()

    private(set) var announcements: [NLHomeAnnouncements.Announcement] = []

    /// Dismissals this device remembers. Only ever written for a guest; once
    /// they sign in the server's own list takes over, and these stay harmless.
    private static let localKey = "nodeloc.announcements.dismissed"
    private var locallyDismissed: Set<Int> {
        get { Set(UserDefaults.standard.array(forKey: Self.localKey) as? [Int] ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: Self.localKey) }
    }

    /// What the carousel should actually show.
    var visible: [NLHomeAnnouncements.Announcement] {
        let hidden = locallyDismissed
        return announcements.filter { !hidden.contains($0.id) }
    }

    func load() async {
        guard let loaded = try? await client.homeAnnouncements() else { return }
        announcements = loaded

    }

    /// Hides it here first so the card leaves at once, then records it. A guest
    /// only ever gets the local half.
    func dismiss(_ announcement: NLHomeAnnouncements.Announcement) async {
        locallyDismissed.insert(announcement.id)
        announcements.removeAll { $0.id == announcement.id }
        guard DiscourseAuth.shared.isAuthenticated else { return }
        try? await client.dismissAnnouncement(id: announcement.id)
    }
}

/// The home feed's announcements as a warm card above the list (design
/// App-iOS-Feed, 2026-11 revision): the kind's icon in a round tile, the title
/// in bold, two lines of the excerpt, 查看详情, page dots when there are
/// several, and × to dismiss. Steps to the next one every 6 s (not under
/// Reduce Motion); a swipe sideways steps by hand; a tap opens it.
struct HomeAnnouncementStrip: View {
    let announcements: [NLHomeAnnouncements.Announcement]
    let onOpen: (NLHomeAnnouncements.Announcement) -> Void
    var onDismiss: ((NLHomeAnnouncements.Announcement) -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var index = 0

    private enum Palette {
        static let fill = Color(light: 0xFFF4EC, dark: 0x2B1E14)
        static let border = Color(light: 0xF6DCC6, dark: 0x4A3220)
        static let iconFill = Color(light: 0xFFD9BF, dark: 0x4A2C16)
        static let iconInk = Color(light: 0x8A3A00, dark: 0xF5B98A)
        static let title = Color(light: 0x5A2600, dark: 0xFAD7B8)
        static let body = Color(light: 0x7A3E00, dark: 0xE8B48C)
        static let close = Color(light: 0x8A5A2B, dark: 0xCFA982)
        static let dotOn = Color(light: 0xB45309, dark: 0xF59E5B)
        static let dotOff = Color(light: 0xEBC9AE, dark: 0x5A4030)
    }

    var body: some View {
        if !announcements.isEmpty {
            let current = announcements[min(index, announcements.count - 1)]
            let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: current.chipSymbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Palette.iconInk)
                    .frame(width: 36, height: 36)
                    .background(Palette.iconFill, in: Circle())
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(current.title)
                        .font(Theme.body(15, weight: .bold))
                        .foregroundStyle(Palette.title)
                        .lineLimit(1)
                    if let excerpt = current.excerpt.map({ DiscourseFormat.plainText($0) }), !excerpt.isEmpty {
                        Text(excerpt)
                            .font(Theme.body(14))
                            .lineSpacing(3)
                            .foregroundStyle(Palette.body)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 4) {
                        Text(AppString("查看详情"))
                            .font(Theme.body(13, weight: .bold))
                            .foregroundStyle(Palette.iconInk)
                        Spacer(minLength: 8)
                        if announcements.count > 1 {
                            ForEach(0..<announcements.count, id: \.self) { i in
                                Capsule()
                                    .fill(i == index ? Palette.dotOn : Palette.dotOff)
                                    .frame(width: i == index ? 14 : 6, height: 6)
                            }
                            .accessibilityHidden(true)
                        }
                    }
                    .padding(.top, 6)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .id(current.id)
                .transition(.opacity)
            }
            .padding(.leading, 14)
            .padding(.trailing, 44)
            .padding(.top, 14)
            .padding(.bottom, 12)
            .background(Palette.fill, in: shape)
            .overlay { shape.strokeBorder(Palette.border, lineWidth: 1) }
            .overlay(alignment: .topTrailing) {
                if let onDismiss, current.dismissible ?? true {
                    Button { onDismiss(current) } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Palette.close)
                            .frame(width: 40, height: 40)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.pressableIcon)
                    .padding(4)
                    .accessibilityLabel(AppString("关闭这条公告"))
                }
            }
            .contentShape(shape)
            .onTapGesture { onOpen(current) }
            .simultaneousGesture(
                DragGesture(minimumDistance: 24).onEnded { value in
                    guard announcements.count > 1, abs(value.translation.width) > abs(value.translation.height) else { return }
                    step(value.translation.width < 0 ? 1 : -1)
                }
            )
            .accessibilityElement(children: .contain)
            .accessibilityAction(named: AppString("打开公告")) { onOpen(current) }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)
            .onChange(of: announcements.count) { _, count in
                if index >= count { index = max(count - 1, 0) }
            }
            .task(id: "\(index)-\(announcements.count)-\(reduceMotion)-\(scenePhase == .active)") {
                guard announcements.count > 1, !reduceMotion, scenePhase == .active else { return }
                try? await Task.sleep(for: .seconds(6))
                guard !Task.isCancelled else { return }
                step(1)
            }
        }
    }

    private func step(_ delta: Int) {
        let count = announcements.count
        guard count > 0 else { return }
        withAnimation(.easeInOut(duration: 0.3)) {
            index = ((index + delta) % count + count) % count
        }
    }
}
