//
//  CountFilterChip.swift
//  nodeloc
//
//  The filter chip of the list pages (草稿箱, 浏览记录): a capsule with the
//  name and its count, ink when picked.
//

import SwiftUI

struct CountFilterChip: View {
    let title: String
    let count: Int?
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title).fontWeight(.semibold)
                if let count {
                    Text(verbatim: "\(count)")
                        .foregroundStyle(isOn ? AnyShapeStyle(.white.opacity(0.75)) : AnyShapeStyle(.secondary))
                }
            }
            .font(.subheadline)
            .foregroundStyle(isOn ? Color.white : Color.primary)
            .padding(.horizontal, 16)
            .frame(height: 36)
            .background(isOn ? Color(light: 0x0F1A1C, dark: 0x3A4A4E) : Color(.secondarySystemFill), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
