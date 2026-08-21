//
//  OverlayShared.swift
//  nodeloc
//
//  Pieces used by more than one overlay. These lived at the top of
//  Overlays.swift as `private` declarations; splitting that file into one file
//  per feature meant they had to become internal so the new files can reach
//  them.
//

import SwiftUI

// MARK: - Shared overlay header

struct OverlayHeader: View {
    @Environment(AppState.self) private var app
    let title: String
    var titleWeight: Font.Weight = .medium

    var body: some View {
        HStack(spacing: 10) {
            Button { dismissOverlay() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.text)
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.glass(.regular.tint(Theme.bg.opacity(0.34))))
            .buttonBorderShape(.circle)
            Text(title).font(Theme.body(15, weight: titleWeight))
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    private func dismissOverlay() {
        closeOverlay(app)
    }
}

func closeOverlay(_ app: AppState) {
    if app.overlay == .post {
        withAnimation(.panelSlide) {
            app.overlay = nil
        }
    } else {
        withAnimation(.quick) {
            app.overlay = nil
        }
    }
}

func nodelocSiteURL(_ path: String) -> URL? {
    if path.hasPrefix("http") { return URL(string: path) }
    if path.hasPrefix("/") {
        return URL(string: path, relativeTo: DiscourseConfig.baseURL)?.absoluteURL
    }
    return URL(string: "/\(path)", relativeTo: DiscourseConfig.baseURL)?.absoluteURL
}

// MARK: - Safe area

extension UIApplication {
    /// Status-bar height, for views that ignore the safe area and have to add
    /// it back themselves.
    ///
    /// `max` rather than `first` because scene order is not defined, and the
    /// fallback is a real status-bar height rather than zero: the list is empty
    /// until a window attaches, and returning zero there collapses the banner
    /// that this value is sizing and slides it under the notch.
    static var topSafeAreaInset: CGFloat {
        shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow?.safeAreaInsets.top }
            .max() ?? 47
    }
}

// MARK: - Node identity

/// Two nodes side by side, for the two-column browse grid.
struct NodeCardPair: Identifiable {
    let first: SidebarNodeSummary
    let second: SidebarNodeSummary?

    var id: Int { first.id }
}

struct NodeAvatar: View {
    let node: SidebarNodeSummary
    var size: CGFloat = 40
    var cornerRadius: CGFloat = 12

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        Group {
            if let logoURL = node.logoURL {
                CachedRemoteImage(url: logoURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    fallback
                }
            } else {
                fallback
            }
        }
        .frame(width: size, height: size)
        .background(nodeAccentColor(node.colorHex).opacity(0.16), in: shape)
        .clipShape(shape)
    }

    private var fallback: some View {
        Text(node.name.first.map(String.init) ?? "#")
            .font(Theme.heading(size * 0.4, weight: .bold))
            .foregroundStyle(nodeAccentColor(node.colorHex))
    }
}

/// Like `NodeAvatar` but bordered, used in list rows rather than headers.
struct NodeSummaryIcon: View {
    let node: SidebarNodeSummary
    var size: CGFloat = 42
    var cornerRadius: CGFloat = 13

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        Group {
            if let logoURL = node.logoURL {
                CachedRemoteImage(url: logoURL) { image in
                    image
                        .resizable()
                        .scaledToFill()
                } placeholder: {
                    fallback
                }
            } else {
                fallback
            }
        }
        .frame(width: size, height: size)
        .background(nodeAccentColor(node.colorHex).opacity(0.16), in: shape)
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(Theme.divider, lineWidth: 1)
        }
    }

    private var fallback: some View {
        Text(node.name.first.map(String.init) ?? "#")
            .font(Theme.heading(size * 0.36, weight: .bold))
            .foregroundStyle(nodeAccentColor(node.colorHex))
            .frame(width: size, height: size)
    }
}

func nodeAccentColor(_ hex: String) -> Color {
    let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
    guard let value = UInt32(cleaned, radix: 16) else { return Theme.accent }
    return Color(hex: value)
}

extension Color {
    static let neutral900Scrim = Theme.neutral900.opacity(0.55)
}

// MARK: - App identity

struct AppLogo: View {
    let app: DirectoryApp
    var size: CGFloat = 64
    var cornerRadius: CGFloat = 16

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        Group {
            if let url = NodeSummaryFactory.resolvedURL(app.logoUrl) {
                CachedRemoteImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    fallback
                }
            } else {
                fallback
            }
        }
        .frame(width: size, height: size)
        .background(Theme.surface, in: shape)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Theme.divider, lineWidth: 1))
    }

    private var fallback: some View {
        Text(app.name.first.map(String.init) ?? "#")
            .font(Theme.heading(size * 0.38, weight: .bold))
            .foregroundStyle(Theme.accent)
    }
}

// MARK: - Sheet scaffolding

extension View {
    /// The detent + drag-indicator pair every sheet in the app repeats.
    func standardSheet(_ detents: Set<PresentationDetent> = [.medium, .large]) -> some View {
        presentationDetents(detents)
            .presentationDragIndicator(.visible)
    }
}

/// Icon over a short message, for a list with nothing in it.
struct EmptyStateView: View {
    let icon: String
    let message: String
    var iconSize: CGFloat = 30

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: iconSize, weight: .medium))
                .foregroundStyle(Theme.muted(0.34))
            Text(message)
                .font(Theme.body(14, weight: .medium))
                .foregroundStyle(Theme.muted(0.58))
                .multilineTextAlignment(.center)
        }
    }
}
