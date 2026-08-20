//
//  Theme.swift
//  nodeloc
//
//  Nocturne design system — active "light" token override, translated to SwiftUI.
//  Source of truth: design_import/rendered.html (:root override block).
//

import SwiftUI

extension Color {
    /// Create a color from a packed 0xRRGGBB hex value.
    init(hex: UInt32, alpha: Double = 1) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }

    /// Create a dynamic color that follows the current light/dark appearance.
    init(light: UInt32, dark: UInt32, lightAlpha: Double = 1, darkAlpha: Double? = nil) {
        self.init(UIColor { traits in
            let isDark = traits.userInterfaceStyle == .dark
            let value = isDark ? dark : light
            let alpha = isDark ? (darkAlpha ?? lightAlpha) : lightAlpha
            let r = CGFloat((value >> 16) & 0xFF) / 255
            let g = CGFloat((value >> 8) & 0xFF) / 255
            let b = CGFloat(value & 0xFF) / 255
            return UIColor(red: r, green: g, blue: b, alpha: CGFloat(alpha))
        })
    }
}

/// Design tokens: colors, spacing, radii, typography.
enum Theme {

    // MARK: Core roles
    static let bg = Color(light: 0xFFFFFF, dark: 0x0B0F0E)
    static let surface = Color(light: 0xF7F7F7, dark: 0x171C1A)
    static let text = Color(light: 0x222222, dark: 0xF1F4F2)
    static let divider = Color(light: 0x222222, dark: 0xFFFFFF, lightAlpha: 0.12, darkAlpha: 0.14)
    static let accent = Color(light: 0x009966, dark: 0x26D99B)
    static let accent2 = Color(light: 0xFF9933, dark: 0xFFB15C)

    static let headerBg = Color(light: 0xFFFFFF, dark: 0x0B0F0E)
    static let headerText = Color(light: 0x333333, dark: 0xF1F4F2)
    static let selected = Color(light: 0xCDFEEE, dark: 0x133D31)
    static let hover = Color(light: 0xF2F2F2, dark: 0x202624)
    static let highlight = Color(light: 0xFFFF4D, dark: 0xD9C93F)
    static let danger = Color(light: 0xC80001, dark: 0xFF6B6B)
    static let success = Color(light: 0x009900, dark: 0x4ADB84)
    static let love = Color(light: 0xFA6C8D, dark: 0xFF7A9A)

    // MARK: Neutral ramp
    static let neutral100 = Color(light: 0xFFFFFF, dark: 0xF7FAF8)
    static let neutral200 = Color(light: 0xF7F7F7, dark: 0xEEF2EF)
    static let neutral300 = Color(light: 0xF2F2F2, dark: 0x232927)
    static let neutral400 = Color(light: 0xE3E3E3, dark: 0x343B38)
    static let neutral500 = Color(light: 0xBDBDBD, dark: 0x8B938F)
    static let neutral600 = Color(light: 0x8F8F8F, dark: 0xA6ADA9)
    static let neutral700 = Color(light: 0x666666, dark: 0xC4CBC7)
    static let neutral800 = Color(light: 0x333333, dark: 0x1D2320)
    static let neutral900 = Color(light: 0x222222, dark: 0x050807)

    // MARK: Accent ramp
    static let accent100 = Color(light: 0xCDFEEE, dark: 0xD7FFF2)
    static let accent200 = Color(light: 0xA3F6DC, dark: 0x9FF5D9)
    static let accent300 = Color(light: 0x6FE9C5, dark: 0x6FE9C5)
    static let accent400 = Color(light: 0x3AD4A8, dark: 0x42DDB1)
    static let accent500 = Color(light: 0x009966, dark: 0x26D99B)
    static let accent600 = Color(light: 0x00875A, dark: 0x55E2B0)
    static let accent700 = Color(light: 0x00714C, dark: 0x7BEBC5)
    static let accent800 = Color(light: 0x005A3E, dark: 0x064B38)
    static let accent900 = Color(light: 0x00402C, dark: 0x033326)

    // MARK: Accent-2 ramp
    static let accent2_100 = Color(light: 0xFFE9CC, dark: 0xFFE4BF)
    static let accent2_500 = Color(light: 0xFF9933, dark: 0xFFB15C)
    static let accent2_600 = Color(light: 0xE37E1A, dark: 0xFFC078)

    // MARK: Muted text helpers
    static func muted(_ pct: Double) -> Color { text.opacity(pct) }

    // MARK: Spacing scale
    static let space1: CGFloat = 2.8
    static let space2: CGFloat = 5.6
    static let space3: CGFloat = 8.4
    static let space4: CGFloat = 11.2
    static let space6: CGFloat = 16.8
    static let space8: CGFloat = 22.4

    // MARK: Radii
    static let radiusSm: CGFloat = 4
    static let radiusMd: CGFloat = 8
    static let radiusLg: CGFloat = 14

    // MARK: Typography — the system substitute for "Inter".
    static func heading(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight)
    }
    static func body(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    /// Two-variant avatar palette used across posts, chats, communities.
    static func avatarColors(_ variant: Int) -> (bg: Color, fg: Color) {
        variant == 0 ? (accent800, accent100) : (neutral800, neutral200)
    }
}

// MARK: - Elevation

enum Elevation { case sm, md, lg }

private struct ElevationModifier: ViewModifier {
    let level: Elevation
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        switch level {
        case .sm:
            content.overlay(border(Theme.neutral400))
        case .md:
            content
                .overlay(border(Theme.neutral400))
                .shadow(color: .black.opacity(0.08), radius: 9, y: 6)
        case .lg:
            content
                .overlay(border(Theme.neutral500))
                .shadow(color: .black.opacity(0.14), radius: 20, y: 16)
        }
    }

    private func border(_ color: Color) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .strokeBorder(color, lineWidth: 1)
    }
}

extension View {
    /// Applies a Nocturne elevation (hairline edge + optional ambient shadow).
    func elevation(_ level: Elevation, cornerRadius: CGFloat = Theme.radiusMd) -> some View {
        modifier(ElevationModifier(level: level, cornerRadius: cornerRadius))
    }

    func glassBackground<S: InsettableShape>(
        in shape: S,
        tint: Color = Theme.bg.opacity(0.42),
        stroke: Color = Theme.divider
    ) -> some View {
        background(tint, in: shape)
            .background(.ultraThinMaterial, in: shape)
            .overlay(shape.strokeBorder(stroke, lineWidth: 1))
    }

    func glassPanel(tint: Color = Theme.bg.opacity(0.48)) -> some View {
        background(tint)
            .background(.ultraThinMaterial)
    }
}
