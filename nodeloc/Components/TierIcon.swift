//
//  TierIcon.swift
//  nodeloc
//
//  The nine tiers' small solid marks (段位小图标), from the design's tier
//  sheet: 32-pt grid, filled with even-odd cut-outs, legible down to 16.
//  They're template images in the asset catalogue (`Tier1` … `Tier9`), so
//  they take whatever color the surrounding text has.
//

import SwiftUI

enum Tier {
    /// Bronze first, in the server's order.
    static let names = ["青铜", "白银", "黄金", "铂金", "钻石", "王者", "无双", "荣耀", "传奇"]

    /// 1…9 for a tier the app has a mark for, from its name when there is
    /// one (the name is what every endpoint sends) and otherwise its number.
    static func level(name: String?, number: Int?) -> Int? {
        if let name, let index = names.firstIndex(where: { name.contains($0) }) {
            return index + 1
        }
        if let number, (1...names.count).contains(number) { return number }
        return nil
    }
}

/// A tier's small mark. Draws nothing for a tier it doesn't recognise, so a
/// new tier on the server degrades to the name alone rather than a wrong mark.
struct TierIcon: View {
    let level: Int
    var size: CGFloat = 16

    init?(name: String?, number: Int? = nil, size: CGFloat = 16) {
        guard let level = Tier.level(name: name, number: number) else { return nil }
        self.level = level
        self.size = size
    }

    var body: some View {
        Image("Tier\(level)")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// The mark followed by the tier's name, for rows that name a member's tier.
struct TierLabel: View {
    let name: String
    var number: Int?
    var size: CGFloat = 12

    var body: some View {
        HStack(spacing: 3) {
            TierIcon(name: name, number: number, size: size)
            Text(name)
        }
    }
}
