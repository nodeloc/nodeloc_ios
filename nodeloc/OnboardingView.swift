//
//  OnboardingView.swift
//  nodeloc
//

import SwiftUI

struct OnboardingView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NodelocLogo()
                .padding(.bottom, 28)

            Text("Find your people.")
                .font(Theme.heading(30))
                .padding(.bottom, 8)
            Text("NODELOC is a home for every interest — pick a few Nodes to start your feed.")
                .font(Theme.body(14))
                .foregroundStyle(Theme.muted(0.75))
                .padding(.bottom, 28)

            ScrollView {
                FlowLayout(spacing: 8) {
                    ForEach(SampleData.interestNames, id: \.self) { name in
                        interestChip(name)
                    }
                }
            }
            .scrollIndicators(.hidden)
            .frame(maxHeight: .infinity, alignment: .top)

            HStack {
                Text("\(app.interests.count) selected")
                    .font(Theme.body(12))
                    .foregroundStyle(Theme.muted(0.55))
                Spacer()
                Button("Continue") { app.onboardingDone = true }
                    .buttonStyle(PrimaryButtonStyle())
                    .frame(minWidth: 132)
                    .disabled(app.interests.isEmpty)
                    .opacity(app.interests.isEmpty ? 0.45 : 1)
            }
            .padding(.top, 20)
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 32)
        .background(Theme.bg)
    }

    private func interestChip(_ name: String) -> some View {
        let selected = app.interests.contains(name)
        return Text(name)
            .font(Theme.body(13))
            .foregroundStyle(selected ? Theme.accent100 : Theme.text)
            .padding(.vertical, 9)
            .padding(.horizontal, 16)
            .background(selected ? Theme.accent800 : .clear, in: Capsule())
            .overlay {
                Capsule().strokeBorder(selected ? Theme.accent : Theme.divider, lineWidth: 1)
            }
            .contentShape(Capsule())
            .onTapGesture {
                withAnimation(.easeOut(duration: 0.15)) { app.toggleInterest(name) }
            }
    }
}

/// Simple wrapping flow layout for chips/tags.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rows: [[CGSize]] = [[]]
        var x: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, !rows[rows.count - 1].isEmpty {
                rows.append([])
                x = 0
            }
            rows[rows.count - 1].append(size)
            x += size.width + spacing
        }
        let height = rows.reduce(CGFloat(0)) { acc, row in
            acc + (row.map(\.height).max() ?? 0) + spacing
        } - (rows.isEmpty ? 0 : spacing)
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: max(height, 0))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            sub.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
