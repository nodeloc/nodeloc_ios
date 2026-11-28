//
//  AchievementMedal.swift
//  nodeloc
//
//  The medal drawn for an `AchievementItem` (Core/Kit/AchievementsAPI.swift).
//  Kept out of Core/Kit, which also builds as the Foundation-only NodelocKit
//  package and has no `Theme`.
//

import SwiftUI

// MARK: - Medal

/// An achievement's icon on a disc graded bronze / silver / gold / rare.
/// Greyed out while still locked.
struct AchievementMedal: View {
    let item: AchievementItem
    var size: CGFloat = 52
    var locked = false

    var body: some View {
        let style = Self.style(for: item.tier)
        // The design's disc: a 145° gradient, a white inner ring, a hairline
        // outer ring in the grade's darker colour. Locked is flat grey.
        ZStack {
            if locked {
                Circle().fill(Theme.chip)
            } else {
                Circle().fill(
                    LinearGradient(colors: [style.top, style.bottom], startPoint: .topLeading, endPoint: .bottomTrailing)
                )
            }
            Circle().strokeBorder(Color.white.opacity(locked ? 0.35 : 0.7), lineWidth: 2)
            Image(systemName: item.symbolName)
                .font(.system(size: size * 0.4, weight: .bold))
                .foregroundStyle(locked ? Theme.textFaint : style.icon)
        }
        .frame(width: size, height: size)
        .overlay(Circle().stroke(locked ? Theme.hairline : style.bottom, lineWidth: 1).padding(-0.5))
    }

    /// 1 铜级, 2 银级, 3 金级, 4 稀有级 — the design's medal colours.
    static func style(for tier: Int?) -> (top: Color, bottom: Color, icon: Color) {
        switch tier {
        case 2: return (Color(hex: 0xF4F7F8), Color(hex: 0xC5D0D6), Color(hex: 0x2A3C42))
        case 3: return (Color(hex: 0xFFF4CF), Color(hex: 0xEBC65A), Color(hex: 0x6B4700))
        case 4: return (Color(hex: 0x1B3A2F), Color(hex: 0x0B1F18), Color(hex: 0x5CC79A))
        default: return (Color(hex: 0xF6E3D2), Color(hex: 0xD9A679), Color(hex: 0x7A3A10))
        }
    }
}
