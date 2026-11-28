//
//  LotteryCard.swift
//  nodeloc
//
//  The lottery (抽奖) on a topic's first post, after the design's iOS
//  artboards 日常 11–15: a red ticket card with the countdown, the turnout,
//  the participants and the prize tiers (with their winners once drawn), plus
//  the floating 买票 bar that stands in for the reply bar while it is open,
//  and the 买票 sheet.
//
//  Backend (`internal/play`): GET /api/v1/posts/{id}/lottery,
//  POST /api/v1/lotteries/{id}/tickets ({tickets, random} + Idempotency-Key),
//  GET /api/v1/lotteries/{id}/participants, DELETE /api/v1/lotteries/{id}
//  (admins). Statuses: open · drawn · failed (流拍) · cancelled.
//

import SwiftUI

// MARK: - Palette

/// The design's lottery colours. The card itself is the same red in both
/// modes; the white panels on it go dark.
private enum LotteryPalette {
    static let red = Color(hex: 0xC81E1E)
    static let redDeep = Color(hex: 0xA80F18)
    static let redMid = Color(hex: 0xD2231C)
    static let redLight = Color(hex: 0xE5482A)
    static let gold = Color(hex: 0xFFD58A)
    static let subtitle = Color(hex: 0xFFE1C2)

    static let panel = Color(light: 0xFFFFFF, dark: 0x161B19)
    static let box = Color(light: 0xFFFFFF, dark: 0x202624)
    static let link = Color(light: 0xB3121B, dark: 0xFF8A80)
    static let overflow = Color(light: 0x0F1A1C, dark: 0xF1F4F2)
    static let onOverflow = Color(light: 0xFFFFFF, dark: 0x0F1A1C)

    static let openFill = Color(light: 0xEEF7F2, dark: 0x133D31)
    static let openText = Color(light: 0x00573B, dark: 0x7BEBC5)
    static let warnFill = Color(light: 0xFBEAE2, dark: 0x3A1E12)
    static let warnText = Color(light: 0xA33A00, dark: 0xFFB38A)
    static let luckFill = Color(light: 0xFFF1D6, dark: 0x3A2A12)
    static let luckText = Color(light: 0x8A5200, dark: 0xFFC98A)
    static let sheetBg = Color(light: 0xF2F5F6, dark: 0x0F1412)

    /// 一等奖 gold, 二等奖 silver, 三等奖 bronze, then silver.
    static func tier(_ index: Int) -> (fill: Color, text: Color) {
        switch index {
        case 0: (Color(light: 0xFFE9CF, dark: 0x3A2A12), Color(light: 0x8A4B00, dark: 0xFFC98A))
        case 2: (Color(light: 0xF3E3D3, dark: 0x33241A), Color(light: 0x7A3E10, dark: 0xE8B48A))
        default: (Theme.chip, Theme.textSecondary)
        }
    }
}

// MARK: - Shared helpers

enum LotteryText {
    /// "11 月 21 日（周六）20:00" in Chinese, the locale's own short form otherwise.
    static func drawTime(_ date: Date) -> String {
        let locale = AppLanguage.resolved.locale
        // Cached per locale and pattern: one was built per call, per render.
        let formatter: DateFormatter
        if locale.identifier.hasPrefix("zh") {
            formatter = DiscourseFormat.cachedFormatter(
                locale: locale,
                format: Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year)
                    ? "M 月 d 日（EEE）HH:mm"
                    : "yyyy 年 M 月 d 日（EEE）HH:mm"
            )
        } else {
            formatter = DiscourseFormat.cachedFormatter(locale: locale, template: "MMMdEEEHHmm")
        }
        return formatter.string(from: date)
    }

    /// The server's tier names, bronze = 0.
    static func tierName(_ level: Int) -> String {
        Tier.names.indices.contains(level) ? AppString(String.LocalizationValue(Tier.names[level])) : "TL\(level)"
    }

    static func count(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic))
    }
}

/// An overlapping row of avatars with a "+N" chip, as on the design.
private struct LotteryAvatarStack: View {
    let people: [LotteryParticipant]
    let overflow: Int
    var size: CGFloat = 32
    var ring: Color = LotteryPalette.panel

    var body: some View {
        HStack(spacing: -8) {
            ForEach(Array(people.enumerated()), id: \.offset) { index, person in
                RemoteAvatar(
                    url: person.avatarTemplate.flatMap { DiscourseClient().avatarURL(template: $0, size: 96) },
                    letter: String((person.username ?? "?").prefix(1)).uppercased(),
                    variant: index % 2,
                    size: size - 4
                )
                .padding(2)
                .background(ring, in: Circle())
                .zIndex(Double(people.count - index))
            }
            if overflow > 0 {
                Text("+\(overflow)")
                    .font(Theme.body(size > 30 ? 12 : 11, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(LotteryPalette.onOverflow)
                    .fixedSize()
                    .padding(.horizontal, size > 30 ? 8 : 6)
                    .frame(minWidth: size - 4, minHeight: size - 4)
                    .background(LotteryPalette.overflow, in: Capsule())
                    .padding(2)
                    .background(ring, in: Capsule())
            }
        }
    }
}

// MARK: - Card

struct LotteryView: View {
    let lottery: PostLottery
    let isBusy: Bool
    /// Refetches the lottery (once the draw time passes, to pick up the result).
    var onRefresh: () async -> Void = {}
    var onCancel: () -> Void = {}
    var loadParticipants: () async throws -> LotteryParticipantsResponse = {
        throw DiscourseError.badResponse(404, message: nil, code: "not_found")
    }
    var onOpenProfile: (String) -> Void = { _ in }

    @State private var peopleSheet: LotteryPeopleSheet.Content?
    @State private var confirmsCancel = false

    private var me: String? { DiscourseAuth.shared.username?.lowercased() }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if lottery.isOpen {
                countdownPanel
            }
            if showsParticipants {
                participantsRow
            }
            if let banner {
                bannerView(banner)
            }
            if !(lottery.levels ?? []).isEmpty {
                prizesPanel
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { cardBackground }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: LotteryPalette.redDeep.opacity(0.25), radius: 15, y: 10)
        .sheet(item: $peopleSheet) { content in
            LotteryPeopleSheet(content: content, onOpenProfile: { name in
                peopleSheet = nil
                onOpenProfile(name)
            })
        }
        .alert(AppString("关闭抽奖并退票？"), isPresented: $confirmsCancel) {
            Button(AppString("再想想"), role: .cancel) {}
            Button(AppString("关闭并退票"), role: .destructive) { onCancel() }
        } message: {
            Text("已售出的 \(lottery.ticketsCount ?? 0) 张票款会原路退回给参与者，关闭后不能再开启。")
        }
        // Past the draw time the server's job picks a result within a minute
        // or so; poll a few times rather than leave "开奖中" up until a reload.
        .task(id: lottery.isOpen ? lottery.drawAt : nil) {
            guard lottery.isOpen, let drawDate = lottery.drawDate else { return }
            let wait = drawDate.timeIntervalSinceNow
            if wait > 0 {
                guard wait < 6 * 3600 else { return }
                try? await Task.sleep(for: .seconds(wait + 3))
            }
            for _ in 0..<12 {
                if Task.isCancelled { return }
                await onRefresh()
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    // MARK: Background

    private var cardBackground: some View {
        ZStack {
            LinearGradient(
                stops: [
                    .init(color: LotteryPalette.redDeep, location: 0),
                    .init(color: LotteryPalette.redMid, location: 0.55),
                    .init(color: LotteryPalette.redLight, location: 1),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            // Dot pattern.
            Canvas { context, size in
                let dot = Path(ellipseIn: CGRect(x: 0, y: 0, width: 2.8, height: 2.8))
                var y: CGFloat = 6.6
                while y < size.height {
                    var x: CGFloat = 6.6
                    while x < size.width {
                        context.fill(dot.offsetBy(dx: x, dy: y), with: .color(Color(hex: 0xFFDE96).opacity(0.22)))
                        x += 16
                    }
                    y += 16
                }
            }
            GeometryReader { proxy in
                let size = proxy.size
                RadialGradient(colors: [Color(hex: 0xFFD678).opacity(0.45), .clear],
                               center: UnitPoint(x: 0.08, y: -0.1), startRadius: 0,
                               endRadius: max(size.width, size.height) * 0.38)
                RadialGradient(colors: [Color(hex: 0xFFC85A).opacity(0.35), .clear],
                               center: UnitPoint(x: 1.05, y: 1.1), startRadius: 0,
                               endRadius: max(size.width, size.height) * 0.42)
                Circle()
                    .strokeBorder(Color(hex: 0xFFD678).opacity(0.25), lineWidth: 10)
                    .frame(width: 120, height: 120)
                    .position(x: size.width + 18 - 60, y: -22 + 60)
                Rectangle()
                    .fill(LotteryPalette.gold.opacity(0.8))
                    .frame(width: 8, height: 8)
                    .rotationEffect(.degrees(45))
                    .position(x: size.width - 70 - 4, y: 18)
                Rectangle()
                    .fill(Color(hex: 0xFFE7B0).opacity(0.7))
                    .frame(width: 6, height: 6)
                    .rotationEffect(.degrees(45))
                    .position(x: size.width * 0.46 + 3, y: 11)
            }
        }
        .accessibilityHidden(true)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Image("LucideGift")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 17, height: 17)
                .foregroundStyle(LotteryPalette.gold)
                .frame(width: 32, height: 32)
                .background(Color.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color(hex: 0xFFD678).opacity(0.5), lineWidth: 1)
                }

            VStack(alignment: .leading, spacing: 1) {
                Text(lottery.title?.isEmpty == false ? lottery.title! : AppString("抽奖"))
                    .font(Theme.body(16, weight: .bold))
                    .tracking(0.3)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                Text(subtitle)
                    .font(Theme.body(12))
                    .monospacedDigit()
                    .foregroundStyle(LotteryPalette.subtitle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    statusChip(now: context.date)
                }
                if lottery.canClose == true && lottery.isOpen {
                    Button {
                        confirmsCancel = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "xmark.circle")
                                .font(.system(size: 11, weight: .semibold))
                            Text("关闭")
                        }
                        .font(Theme.body(12, weight: .bold))
                        .foregroundStyle(LotteryPalette.warnText)
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(LotteryPalette.panel, in: Capsule())
                        .overlay { Capsule().strokeBorder(Color(hex: 0xE7B9A3), lineWidth: 1) }
                    }
                    .buttonStyle(.pressable)
                    .disabled(isBusy)
                    .accessibilityHint(Text("仅管理员可见"))
                }
            }
        }
    }

    private var subtitle: String {
        let draw = lottery.drawDate.map(LotteryText.drawTime) ?? ""
        switch lottery.status {
        case "drawn":
            let at = DiscourseFormat.date(lottery.drawnAt).map(LotteryText.drawTime) ?? draw
            return AppString("已于 \(at) 开奖")
        case "failed": return AppString("\(draw) 流拍")
        case "cancelled": return AppString("已关闭，票款已退回")
        default: return AppString("\(draw) 开奖")
        }
    }

    private func statusChip(now: Date) -> some View {
        let (label, fill, text): (String, Color, Color) = {
            switch lottery.status {
            case "open" where lottery.isDrawing(now: now):
                return (AppString("开奖中"), LotteryPalette.luckFill, LotteryPalette.luckText)
            case "open": return (AppString("进行中"), LotteryPalette.openFill, LotteryPalette.openText)
            case "drawn": return (AppString("已开奖"), Theme.chip, Theme.textMuted)
            case "failed": return (AppString("已流拍"), LotteryPalette.warnFill, LotteryPalette.warnText)
            case "cancelled": return (AppString("已关闭"), Theme.chip, Theme.textMuted)
            default: return (lottery.status ?? "", Theme.chip, Theme.textMuted)
            }
        }()
        return Text(label)
            .font(Theme.body(12, weight: .bold))
            .foregroundStyle(text)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(fill, in: Capsule())
            .fixedSize()
    }

    // MARK: Countdown + turnout

    private var countdownPanel: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 20) {
                countdown
                turnout
            }
            VStack(alignment: .leading, spacing: 12) {
                countdown
                turnout
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LotteryPalette.panel.opacity(0.97), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var countdown: some View {
        // Seconds are on screen, so it ticks every second; only this subtree
        // re-renders.
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = max(0, Int((lottery.drawDate ?? context.date).timeIntervalSince(context.date)))
            VStack(alignment: .leading, spacing: 4) {
                Text(remaining > 0 ? "距离开奖" : "正在开奖")
                    .font(Theme.body(12))
                    .foregroundStyle(Theme.textMuted)
                if remaining > 0 {
                    HStack(spacing: 6) {
                        countdownBox(remaining / 86_400, unit: AppString("天"), pad: false)
                        countdownBox(remaining % 86_400 / 3600, unit: AppString("时"))
                        countdownBox(remaining % 3600 / 60, unit: AppString("分"))
                        countdownBox(remaining % 60, unit: AppString("秒"))
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text("距离开奖还有 \(remaining / 86_400) 天 \(remaining % 86_400 / 3600) 小时 \(remaining % 3600 / 60) 分"))
                } else {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("马上公布结果")
                            .font(Theme.body(15, weight: .semibold))
                            .foregroundStyle(Theme.text)
                    }
                    .frame(height: 48)
                }
            }
        }
        .fixedSize()
    }

    private func countdownBox(_ value: Int, unit: String, pad: Bool = true) -> some View {
        VStack(spacing: 0) {
            Text(pad ? String(format: "%02d", value) : "\(value)")
                .font(.system(size: Theme.scaledSize(22), weight: .heavy, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Theme.text)
                .contentTransition(.numericText(countsDown: true))
            Text(unit)
                .font(Theme.body(11))
                .foregroundStyle(Theme.textMuted)
        }
        .frame(minWidth: 48)
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .background(LotteryPalette.box, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        }
    }

    private var turnout: some View {
        let count = lottery.participantsCount ?? 0
        let minimum = lottery.minParticipants ?? 1
        let target = minimum > 1 ? minimum : (lottery.hasParticipantCap ? (lottery.maxParticipants ?? 0) : 0)
        let fraction = target > 0 ? min(1, Double(count) / Double(target)) : 1
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("已有 \(count) 人参与")
                Spacer(minLength: 8)
                if minimum > 1 {
                    Text("至少 \(minimum) 人开奖")
                } else if lottery.hasParticipantCap {
                    Text("限 \(lottery.maxParticipants ?? 0) 人")
                }
            }
            .font(Theme.body(12))
            .foregroundStyle(Theme.textMuted)

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.chip)
                    Capsule()
                        .fill(LinearGradient(colors: [LotteryPalette.redMid, Color(hex: 0xF08A24)],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: proxy.size.width * fraction)
                }
            }
            .frame(height: 6)

            Text(turnoutCaption)
                .font(Theme.body(12))
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .monospacedDigit()
        .frame(minWidth: 200, maxWidth: .infinity, alignment: .leading)
    }

    private var turnoutCaption: String {
        var parts = [AppString("已售 \(LotteryText.count(lottery.ticketsCount ?? 0)) 张"), AppString("每张 1 能量")]
        if let level = lottery.minTrustLevel, level > 0 {
            parts.append(AppString("参与者需\(LotteryText.tierName(level))及以上"))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Participants

    private var showsParticipants: Bool {
        !(lottery.participants ?? []).isEmpty || (lottery.participantsCount ?? 0) > 0
    }

    private var participantsRow: some View {
        let strip = Array((lottery.participants ?? []).prefix(6))
        let total = lottery.participantsCount ?? strip.count
        return HStack(spacing: 12) {
            Text("参与者")
                .font(Theme.body(13, weight: .bold))
                .foregroundStyle(Theme.text)
            Button {
                peopleSheet = .participants(load: loadParticipants, total: total)
            } label: {
                HStack(spacing: 10) {
                    if strip.isEmpty {
                        Text("\(total) 人")
                            .font(Theme.body(13))
                            .foregroundStyle(Theme.textMuted)
                            .monospacedDigit()
                    } else {
                        LotteryAvatarStack(people: strip, overflow: max(0, total - strip.count))
                    }
                    Spacer(minLength: 0)
                    HStack(spacing: 2) {
                        Text("全部")
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .bold))
                    }
                    .font(Theme.body(13, weight: .bold))
                    .foregroundStyle(LotteryPalette.link)
                }
                .frame(height: 40)
                .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            .accessibilityLabel(Text("查看全部 \(total) 位参与者及购票数"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(LotteryPalette.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: Result banner

    private enum Banner {
        case won(level: String, prize: String)
        case lost(tickets: Int)
        case failed
        case cancelled
    }

    private var myPrize: LotteryPrizeLevel? {
        guard let me else { return nil }
        return lottery.levels?.first { level in
            (level.winners ?? []).contains { $0.username?.lowercased() == me }
        }
    }

    private var banner: Banner? {
        let mine = lottery.userTickets ?? 0
        switch lottery.status {
        case "drawn":
            if let prize = myPrize { return .won(level: prize.name ?? "", prize: prize.prize ?? "") }
            return mine > 0 ? .lost(tickets: mine) : nil
        case "failed": return .failed
        case "cancelled": return .cancelled
        default: return nil
        }
    }

    private func bannerView(_ banner: Banner) -> some View {
        let mine = lottery.userTickets ?? 0
        let (icon, title, detail, fill, text): (String, String, String, Color, Color) = {
            switch banner {
            case let .won(level, prize):
                return ("party.popper", AppString("恭喜，你抽中了\(level)"),
                        AppString("奖品是 \(prize)，发帖人会私信你确认领奖方式。"),
                        LotteryPalette.openFill, LotteryPalette.openText)
            case let .lost(tickets):
                return ("face.smiling", AppString("这次没中"),
                        AppString("你的 \(tickets) 张票都没中奖。共 \(lottery.participantsCount ?? 0) 人参与，售出 \(LotteryText.count(lottery.ticketsCount ?? 0)) 张。"),
                        Theme.surface, Theme.textSecondary)
            case .failed:
                let refund = mine > 0
                    ? AppString("你的 \(mine) 张票款已原路退回。")
                    : AppString("票款已原路退回给参与者。")
                return ("arrow.uturn.backward.circle", AppString("参与人数不足，本次抽奖流拍"),
                        AppString("只有 \(lottery.participantsCount ?? 0) 人参与（至少需要 \(lottery.minParticipants ?? 0) 人），") + refund,
                        LotteryPalette.warnFill, LotteryPalette.warnText)
            case .cancelled:
                return ("xmark.circle", AppString("抽奖已被关闭"),
                        mine > 0 ? AppString("你的 \(mine) 张票款已原路退回。") : AppString("票款已原路退回给参与者。"),
                        LotteryPalette.warnFill, LotteryPalette.warnText)
            }
        }()
        return HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .medium))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.body(15, weight: .bold))
                Text(detail)
                    .font(Theme.body(13))
                    .opacity(0.85)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(text)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(fill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: Prizes

    private var prizesPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("奖项")
                .font(Theme.body(13, weight: .bold))
                .foregroundStyle(Theme.text)
                .padding(.bottom, 6)
            ForEach(Array((lottery.levels ?? []).enumerated()), id: \.offset) { index, level in
                prizeRow(level, index: index)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LotteryPalette.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func prizeRow(_ level: LotteryPrizeLevel, index: Int) -> some View {
        let colors = LotteryPalette.tier(index)
        let winners = level.winners ?? []
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Text(level.name ?? "")
                    .font(Theme.body(12, weight: .bold))
                    .foregroundStyle(colors.text)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .frame(minWidth: 52, minHeight: 24)
                    .background(colors.fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text(level.prize ?? "")
                    .font(Theme.body(15, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(level.quantity ?? 1) 名")
                    .font(Theme.body(13))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize()
            }
            if lottery.isDrawn, !winners.isEmpty {
                winnersButton(level, winners: winners)
            }
        }
        .padding(.vertical, 6)
        .frame(minHeight: 48)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.chip).frame(height: 1)
        }
    }

    private func winnersButton(_ level: LotteryPrizeLevel, winners: [LotteryParticipant]) -> some View {
        let includesMe = me.map { name in winners.contains { $0.username?.lowercased() == name } } ?? false
        let shown = Array(winners.prefix(includesMe ? 3 : 3))
        let label: String = {
            if includesMe {
                return winners.count == 1 ? AppString("你") : AppString("你和另外 \(winners.count - 1) 人")
            }
            let first = winners.first?.username ?? ""
            return winners.count == 1 ? first : AppString("\(first) 等 \(winners.count) 人")
        }()
        return Button {
            peopleSheet = .winners(level: level.name ?? "", prize: level.prize ?? "", people: winners)
        } label: {
            HStack(spacing: 8) {
                LotteryAvatarStack(
                    people: shown,
                    overflow: max(0, winners.count - shown.count),
                    size: 28,
                    ring: includesMe ? LotteryPalette.openFill : Theme.surface
                )
                Text(label)
                    .font(Theme.body(13, weight: .bold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
            }
            .padding(.leading, 4)
            .padding(.trailing, 10)
            .frame(height: 36)
            .background(includesMe ? LotteryPalette.openFill : Theme.surface, in: Capsule())
        }
        .buttonStyle(.pressable)
        .accessibilityLabel(Text("\(level.name ?? "")中奖名单，共 \(winners.count) 人"))
    }
}

// MARK: - People sheet (participants / winners)

struct LotteryPeopleSheet: View {
    enum Content: Identifiable {
        case participants(load: () async throws -> LotteryParticipantsResponse, total: Int)
        case winners(level: String, prize: String, people: [LotteryParticipant])

        var id: String {
            switch self {
            case .participants: "participants"
            case let .winners(level, prize, _): "winners-\(level)-\(prize)"
            }
        }
    }

    let content: Content
    let onOpenProfile: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var people: [LotteryParticipant]?
    @State private var ticketTotal: Int?
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Group {
                if let people {
                    List {
                        if case let .winners(_, prize, _) = content, !prize.isEmpty {
                            Section {
                                Text(prize)
                                    .font(Theme.body(15, weight: .medium))
                                    .foregroundStyle(Theme.text)
                            }
                        }
                        Section {
                            ForEach(Array(people.enumerated()), id: \.offset) { index, person in
                                row(person, index: index)
                            }
                        } footer: {
                            if case .participants = content, let ticketTotal {
                                Text("共 \(people.count) 人，售出 \(LotteryText.count(ticketTotal)) 张")
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                } else if let errorText {
                    ContentUnavailableView(errorText, systemImage: "exclamationmark.triangle")
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(AppString("完成")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .task { await load() }
    }

    private var title: String {
        switch content {
        case let .participants(_, total): AppString("参与者 · \(total) 人")
        case let .winners(level, _, people): AppString("\(level) · \(people.count) 人")
        }
    }

    private func load() async {
        switch content {
        case let .participants(load, _):
            do {
                let response = try await load()
                people = response.participants
                ticketTotal = response.ticketCount
            } catch {
                errorText = AppString("参与者加载失败")
            }
        case let .winners(_, _, list):
            people = list
        }
    }

    private func row(_ person: LotteryParticipant, index: Int) -> some View {
        let isMe = person.username?.lowercased() == DiscourseAuth.shared.username?.lowercased()
        return Button {
            if let name = person.username { onOpenProfile(name) }
        } label: {
            HStack(spacing: 12) {
                RemoteAvatar(
                    url: person.avatarTemplate.flatMap { DiscourseClient().avatarURL(template: $0, size: 96) },
                    letter: String((person.username ?? "?").prefix(1)).uppercased(),
                    variant: index % 2,
                    size: 34
                )
                Text(isMe ? AppString("\(person.username ?? "")（我）") : (person.username ?? ""))
                    .font(Theme.body(15, weight: isMe ? .semibold : .regular))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let tickets = person.tickets {
                    Text("\(LotteryText.count(tickets)) 张")
                        .font(Theme.body(14))
                        .monospacedDigit()
                        .foregroundStyle(Theme.textMuted)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Bottom bar

/// What the viewer can do about an open lottery, shared by the bar and sheet.
struct LotteryEligibility {
    let lottery: PostLottery
    let isGuest: Bool

    var owned: Int { lottery.userTickets ?? 0 }
    var cap: Int { max(1, lottery.maxTicketsPerUser ?? 1) }
    var room: Int { max(0, cap - owned) }
    var least: Int { max(1, (lottery.minTicketsPerUser ?? 1) - owned) }

    /// Why the viewer can't buy, or nil when they can.
    func blocker(now: Date = Date()) -> String? {
        if !lottery.isOpen || lottery.isDrawing(now: now) { return AppString("正在开奖") }
        if !FeatureFlags.shared.lotteryEnabled { return AppString("抽奖功能暂不可用") }
        if isGuest { return nil }
        if lottery.isOwner == true { return AppString("不能参与自己发起的抽奖") }
        if let need = lottery.minTrustLevel, need > 0, let mine = lottery.viewerTrustLevel, mine < need {
            return AppString("升到\(LotteryText.tierName(need))后才能参与")
        }
        if room <= 0 { return AppString("每人最多 \(cap) 张，你已经买满了") }
        if owned == 0 && lottery.isFull { return AppString("参与人数已满") }
        return nil
    }
}

/// Stands in for the reply bar while the lottery is open: the price, where
/// the viewer stands, a reply button and 买票.
struct LotteryActionBar: View {
    let lottery: PostLottery
    let isGuest: Bool
    let onReply: () -> Void
    let onGuest: () -> Void
    /// Buys; returns the number of tickets added, or the server's reason.
    let onBuy: (Int, Bool) async -> Result<Int, LotteryBuyError>

    @State private var balance: Int?
    @State private var showsBuy = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            bar(now: context.date)
        }
        .task(id: lottery.userTickets) { await loadBalance() }
        .sheet(isPresented: $showsBuy) {
            LotteryBuySheet(lottery: lottery, balance: balance, onBuy: { quantity, random in
                let result = await onBuy(quantity, random)
                if case .success = result { await loadBalance() }
                return result
            })
        }
    }

    private func bar(now: Date) -> some View {
        let eligibility = LotteryEligibility(lottery: lottery, isGuest: isGuest)
        let blocker = eligibility.blocker(now: now)
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("每张 1 能量")
                    .font(Theme.body(15, weight: .bold))
                    .foregroundStyle(Theme.text)
                Text(statusLine(eligibility, blocker: blocker))
                    .font(Theme.body(12))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onReply) {
                Image(systemName: "bubble.left")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .frame(width: 44, height: 44)
                    .background(Theme.neutral300, in: Circle())
            }
            .buttonStyle(.pressable)
            .accessibilityLabel(Text("回复"))

            Button {
                if isGuest { onGuest() } else { showsBuy = true }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "ticket")
                        .font(.system(size: 15, weight: .semibold))
                    Text(buttonTitle(eligibility, blocker: blocker))
                }
                .font(Theme.body(16, weight: .bold))
                .foregroundStyle(blocker == nil ? Color.white : Theme.textMuted)
                .padding(.horizontal, 22)
                .frame(minWidth: 104, minHeight: 44)
                .background(blocker == nil ? LotteryPalette.red : Theme.chip, in: Capsule())
            }
            .buttonStyle(.pressable)
            .disabled(blocker != nil)
        }
        .padding(.leading, 18)
        .padding(.trailing, 8)
        .frame(height: 60)
        .glassSurface(tint: FloatingHeader.glassTint, in: .capsule)
        .shadow(color: FloatingHeader.shadow, radius: 9, y: 6)
        .padding(.horizontal, 12)
        .padding(.bottom, -min(UIApplication.bottomSafeAreaInset * 0.55, 14))
    }

    private func statusLine(_ eligibility: LotteryEligibility, blocker: String?) -> String {
        if isGuest { return AppString("登录后参与抽奖") }
        if let blocker { return blocker }
        let balanceText = balance.map { AppString("余额 \(LotteryText.count($0)) 能量") }
        if eligibility.owned > 0 {
            return AppString("你持有 \(LotteryText.count(eligibility.owned)) 张 · 还能买 \(LotteryText.count(eligibility.room)) 张")
        }
        return [AppString("还没参与"), balanceText].compactMap { $0 }.joined(separator: " · ")
    }

    private func buttonTitle(_ eligibility: LotteryEligibility, blocker: String?) -> String {
        if blocker != nil {
            if !lottery.isOpen || lottery.isDrawing() { return AppString("开奖中") }
            if eligibility.room <= 0 && lottery.isOwner != true { return AppString("已买满") }
            return AppString("不能参与")
        }
        return eligibility.owned > 0 ? AppString("再买") : AppString("买票")
    }

    private func loadBalance() async {
        guard !isGuest, let name = DiscourseAuth.shared.username else { return }
        if let total = try? await DiscourseClient().pointsTotal(username: name).totalScores {
            balance = total
        }
    }
}

struct LotteryBuyError: Error {
    let message: String
}

// MARK: - Buy sheet

struct LotteryBuySheet: View {
    let lottery: PostLottery
    let balance: Int?
    let onBuy: (Int, Bool) async -> Result<Int, LotteryBuyError>

    @Environment(\.dismiss) private var dismiss
    @State private var quantity = 1
    @State private var isBuying = false
    @State private var errorText: String?
    @State private var holdProgress: CGFloat = 0
    @State private var isHolding = false

    private var eligibility: LotteryEligibility { LotteryEligibility(lottery: lottery, isGuest: false) }
    /// The most this purchase can be: the per-user room, and what the balance covers.
    private var upper: Int {
        var value = eligibility.room
        if let balance { value = min(value, max(balance, 0)) }
        return value
    }
    private var lower: Int { min(eligibility.least, max(upper, 1)) }
    private var canBuy: Bool { upper >= lower && upper > 0 && !isBuying }

    var body: some View {
        VStack(spacing: 0) {
            navBar
            Text(subtitle)
                .font(Theme.body(13))
                .foregroundStyle(Theme.textMuted)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .padding(.horizontal, 16)
                .padding(.bottom, 4)

            ScrollView {
                VStack(spacing: 18) {
                    stepper
                    presets
                    summary
                    if let errorText {
                        Text(errorText)
                            .font(Theme.body(13, weight: .medium))
                            .foregroundStyle(Theme.danger)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    actions
                    Text("随缘：按住 3 秒，随机买 \(lower)–\(max(upper, lower)) 张，松手取消。票买了不能退，除非抽奖流拍或被关闭。")
                        .font(Theme.body(13))
                        .foregroundStyle(Theme.textMuted)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    LotteryRulesLink()
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 24)
            }
        }
        .background(LotteryPalette.sheetBg.ignoresSafeArea())
        .presentationDetents([.height(600), .large])
        .presentationDragIndicator(.visible)
        .onAppear { quantity = min(max(lower, min(10, upper)), max(upper, lower)) }
        .interactiveDismissDisabled(isBuying)
    }

    private var subtitle: String {
        let title = lottery.title ?? AppString("抽奖")
        guard let date = lottery.drawDate else { return title }
        return AppString("\(title) · \(LotteryText.drawTime(date)) 开奖")
    }

    private var navBar: some View {
        ZStack {
            Text("买票")
                .font(Theme.body(17, weight: .semibold))
                .foregroundStyle(Theme.text)
            HStack {
                Button(AppString("取消")) { dismiss() }
                    .font(Theme.body(17))
                    .foregroundStyle(Theme.accent)
                    .disabled(isBuying)
                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .padding(.top, 12)
    }

    private var stepper: some View {
        HStack(spacing: 28) {
            stepButton("minus", label: AppString("少买一张"), enabled: quantity > lower) { quantity -= 1 }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(quantity)")
                    .font(.system(size: 56, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.text)
                    .contentTransition(.numericText())
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                Text("张")
                    .font(Theme.body(16))
                    .foregroundStyle(Theme.textMuted)
            }
            .frame(minWidth: 96)
            stepButton("plus", label: AppString("多买一张"), enabled: quantity < upper) { quantity += 1 }
        }
        .animation(.snappy, value: quantity)
    }

    private func stepButton(_ symbol: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(Theme.text)
                .frame(width: 52, height: 52)
                .background(LotteryPalette.panel, in: Circle())
        }
        .buttonStyle(.pressable)
        .disabled(!enabled || isBuying)
        .opacity(enabled ? 1 : 0.35)
        .accessibilityLabel(Text(label))
    }

    private var presets: some View {
        let options: [(Int, String)] = [5, 10, 50].filter { $0 >= lower && $0 < upper }.map { ($0, AppString("\($0) 张")) }
            + (upper > 0 ? [(upper, AppString("最多 \(LotteryText.count(upper))"))] : [])
        return HStack(spacing: 8) {
            ForEach(options, id: \.0) { value, title in
                let selected = quantity == value
                Button {
                    quantity = value
                } label: {
                    Text(title)
                        .font(Theme.body(14, weight: .bold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .foregroundStyle(selected ? LotteryPalette.onOverflow : Theme.text)
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                        .background(selected ? LotteryPalette.overflow : LotteryPalette.panel, in: Capsule())
                }
                .buttonStyle(.pressable)
                .disabled(isBuying)
            }
        }
    }

    private var summary: some View {
        VStack(spacing: 0) {
            summaryRow(AppString("花费"), value: AppString("\(LotteryText.count(quantity)) 能量"), strong: true)
            Divider().overlay(Theme.chip).padding(.leading, 16)
            if let balance {
                summaryRow(AppString("买完后余额"), value: AppString("\(LotteryText.count(balance - quantity)) 能量"))
                Divider().overlay(Theme.chip).padding(.leading, 16)
            }
            let low = lottery.minTicketsPerUser ?? 1
            summaryRow(
                AppString("每人限购"),
                value: AppString("\(low)–\(LotteryText.count(eligibility.cap)) 张 · 买完还能再买 \(LotteryText.count(max(0, eligibility.room - quantity))) 张")
            )
        }
        .background(LotteryPalette.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func summaryRow(_ title: String, value: String, strong: Bool = false) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .foregroundStyle(Theme.text)
            Spacer(minLength: 8)
            Text(value)
                .fontWeight(strong ? .bold : .regular)
                .foregroundStyle(strong ? Theme.text : Theme.textMuted)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
        }
        .font(Theme.body(16))
        .padding(.horizontal, 16)
        .frame(minHeight: 48)
    }

    private var actions: some View {
        HStack(spacing: 10) {
            luckyButton
            Button {
                Task { await buy(quantity, random: false) }
            } label: {
                Group {
                    if isBuying && !isHolding {
                        ProgressView().tint(.white)
                    } else if let balance, balance < quantity {
                        Text("能量不足")
                    } else {
                        Text("买 \(LotteryText.count(quantity)) 张 · \(LotteryText.count(quantity)) 能量")
                    }
                }
                .font(Theme.body(17, weight: .bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(LotteryPalette.red, in: Capsule())
            }
            .buttonStyle(.pressable)
            .disabled(!canBuy || quantity < lower || quantity > upper)
            .opacity(canBuy ? 1 : 0.5)
        }
    }

    /// Press and hold for three seconds; letting go early cancels.
    private var luckyButton: some View {
        HStack(spacing: 6) {
            Image(systemName: "dice")
                .font(.system(size: 16, weight: .semibold))
            Text("随缘")
        }
        .font(Theme.body(16, weight: .bold))
        .foregroundStyle(LotteryPalette.luckText)
        .padding(.horizontal, 20)
        .frame(height: 52)
        .background {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    LotteryPalette.luckFill
                    LotteryPalette.luckText.opacity(0.18)
                        .frame(width: proxy.size.width * holdProgress)
                }
            }
        }
        .clipShape(Capsule())
        .opacity(canBuy ? 1 : 0.5)
        .onLongPressGesture(minimumDuration: 3, maximumDistance: 40) {
            isHolding = false
            holdProgress = 0
            Task { await buy(0, random: true) }
        } onPressingChanged: { pressing in
            guard canBuy else { return }
            isHolding = pressing
            if pressing {
                withAnimation(.linear(duration: 3)) { holdProgress = 1 }
            } else {
                withAnimation(.easeOut(duration: 0.2)) { holdProgress = 0 }
            }
        }
        .disabled(!canBuy)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("随缘：按住 3 秒，随机买 \(lower) 到 \(max(upper, lower)) 张"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { Task { await buy(0, random: true) } }
    }

    private func buy(_ count: Int, random: Bool) async {
        guard canBuy else { return }
        isBuying = true
        errorText = nil
        let result = await onBuy(count, random)
        isBuying = false
        switch result {
        case let .success(added):
            ToastCenter.shared.show(random ? AppString("随缘买到 \(added) 张") : AppString("已买 \(added) 张"))
            dismiss()
        case let .failure(error):
            errorText = error.message
        }
    }
}
