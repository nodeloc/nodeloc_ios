//
//  Components.swift
//  nodeloc
//
//  Reusable UI primitives built from the Nocturne tokens.
//

import SwiftUI
import UIKit

// MARK: - Brand

struct NodelocLogo: View {
    var markSize: CGFloat = 30
    var wordSize: CGFloat = 19

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: markSize * 0.3, style: .continuous)
                .fill(Theme.accent)
                .frame(width: markSize, height: markSize)
            Text("NODELOC")
                .font(Theme.heading(wordSize, weight: .semibold))
                .tracking(-0.4)
        }
    }
}

// MARK: - Avatar

struct Avatar: View {
    let letter: String
    var variant: Int = 0
    var size: CGFloat = 34
    var cornerRadius: CGFloat? = nil   // nil == circle
    /// Explicit override colors (used for the current-user avatar).
    var bg: Color? = nil
    var fg: Color? = nil

    var body: some View {
        let palette = Theme.avatarColors(variant)
        let fill = bg ?? palette.bg
        let text = fg ?? palette.fg
        let shape = RoundedRectangle(cornerRadius: cornerRadius ?? size / 2, style: .continuous)
        Text(letter)
            .font(Theme.heading(size * 0.36, weight: .semibold))
            .foregroundStyle(text)
            .frame(width: size, height: size)
            .background(fill, in: shape)
    }
}

struct RemoteAvatar: View {
    let url: URL?
    let letter: String
    var variant: Int = 0
    var size: CGFloat = 34
    var cornerRadius: CGFloat? = nil

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius ?? size / 2, style: .continuous)

        Group {
            if let url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .failure:
                        fallback
                    default:
                        fallback.opacity(0.55)
                    }
                }
            } else {
                fallback
            }
        }
        .frame(width: size, height: size)
        .background(Theme.neutral300, in: shape)
        .clipShape(shape)
    }

    private var fallback: some View {
        Avatar(letter: letter, variant: variant, size: size, cornerRadius: cornerRadius)
    }
}

private final class RemoteImageMemoryCache {
    static let shared = RemoteImageMemoryCache()

    private let cache = NSCache<NSURL, UIImage>()

    private init() {
        cache.countLimit = 160
        cache.totalCostLimit = 24 * 1024 * 1024
    }

    func image(for url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    func insert(_ image: UIImage, for url: URL, cost: Int) {
        cache.setObject(image, forKey: url as NSURL, cost: cost)
    }
}

struct CachedRemoteImage<Content: View, Placeholder: View>: View {
    let url: URL?
    let content: (Image) -> Content
    let placeholder: () -> Placeholder
    @State private var image: UIImage?

    init(
        url: URL?,
        @ViewBuilder content: @escaping (Image) -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.url = url
        self.content = content
        self.placeholder = placeholder
    }

    var body: some View {
        Group {
            if let image {
                content(Image(uiImage: image))
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            await loadImage()
        }
    }

    @MainActor
    private func loadImage() async {
        guard let url else {
            image = nil
            return
        }

        if let cached = RemoteImageMemoryCache.shared.image(for: url) {
            image = cached
            return
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                return
            }
            guard let loaded = UIImage(data: data) else { return }
            RemoteImageMemoryCache.shared.insert(loaded, for: url, cost: data.count)
            image = loaded
        } catch {
            // Keep the placeholder visible when image loading fails.
        }
    }
}

// MARK: - Tags

enum TagStyle { case accent, accent2, neutral, outline }

struct TagChip: View {
    let text: String
    var style: TagStyle = .neutral
    var padding: EdgeInsets = EdgeInsets(top: 3, leading: 10, bottom: 3, trailing: 10)

    var body: some View {
        Text(text)
            .font(Theme.body(11))
            .tracking(0.2)
            .foregroundStyle(foreground)
            .padding(padding)
            .background(background, in: RoundedRectangle(cornerRadius: Theme.radiusMd * 0.75, style: .continuous))
            .overlay {
                if style == .outline {
                    RoundedRectangle(cornerRadius: Theme.radiusMd * 0.75, style: .continuous)
                        .strokeBorder(Theme.accent, lineWidth: 1)
                }
            }
    }

    private var foreground: Color {
        switch style {
        case .accent: return Theme.accent100
        case .accent2: return Theme.accent2_100
        case .neutral: return Theme.neutral100
        case .outline: return Theme.accent
        }
    }
    private var background: Color {
        switch style {
        case .accent: return Theme.accent800
        case .accent2: return Color(hex: 0x804609)
        case .neutral: return Theme.neutral800
        case .outline: return .clear
        }
    }
}

// MARK: - Card container

struct Card<Content: View>: View {
    var background: Color = Theme.surface
    var elevation: Elevation? = .sm
    var padding: CGFloat = Theme.space3
    var axis: Axis = .vertical
    @ViewBuilder var content: Content

    var body: some View {
        Group {
            if axis == .vertical {
                VStack(alignment: .leading, spacing: Theme.space2) { content }
            } else {
                HStack(spacing: Theme.space3) { content }
            }
        }
        .padding(padding)
        .frame(maxWidth: .infinity, alignment: axis == .vertical ? .topLeading : .leading)
        .background(background, in: RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous))
        .modifier(OptionalElevation(level: elevation))
    }
}

private struct OptionalElevation: ViewModifier {
    let level: Elevation?
    func body(content: Content) -> some View {
        if let level { content.elevation(level) } else { content }
    }
}

// MARK: - Segmented control

struct SegmentedControl<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, label: String)]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                let isSelected = selection == option.value
                Button {
                    selection = option.value
                } label: {
                    Text(option.label)
                        .font(Theme.body(13))
                        .foregroundStyle(isSelected ? Theme.accent : Theme.text)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .padding(.horizontal, 12)
                        .overlay {
                            if isSelected {
                                RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous)
                                    .strokeBorder(Theme.accent, lineWidth: 1)
                            }
                        }
                }
                .buttonStyle(.plain)
                if index < options.count - 1 {
                    Rectangle().fill(Theme.divider).frame(width: 1)
                }
            }
        }
        .background(Theme.bg, in: RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous)
                .strokeBorder(Theme.divider, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous))
    }
}

// MARK: - Text field

struct NodeField: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    var secure: Bool = false
    var keyboard: UIKeyboardType = .default

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(Theme.body(12))
                .foregroundStyle(Theme.muted(0.7))
            Group {
                if secure {
                    SecureField(placeholder, text: $text)
                } else {
                    TextField(placeholder, text: $text)
                }
            }
            .font(Theme.body(14))
            .textFieldStyle(.plain)
            .tint(Theme.accent)
            .keyboardType(keyboard)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .padding(.horizontal, 10)
            .frame(minHeight: 36)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous)
                    .strokeBorder(Theme.divider, lineWidth: 1)
            }
        }
    }
}

/// A plain search-style text field (no floating label).
struct PlainField: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        TextField(placeholder, text: $text)
            .font(Theme.body(14))
            .textFieldStyle(.plain)
            .tint(Theme.accent)
            .autocorrectionDisabled()
            .padding(.horizontal, 10)
            .frame(minHeight: 36)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous)
                    .strokeBorder(Theme.divider, lineWidth: 1)
            }
    }
}

// MARK: - Buttons

/// Outlined accent button (Nocturne `.btn-primary`).
struct PrimaryButtonStyle: ButtonStyle {
    var block = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.heading(14))
            .foregroundStyle(Theme.accent)
            .frame(maxWidth: block ? .infinity : nil)
            .padding(.vertical, Theme.space2)
            .padding(.horizontal, Theme.space3 * 1.2)
            .background(
                Theme.accent.opacity(configuration.isPressed ? 0.22 : 0),
                in: RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous)
                    .strokeBorder(Theme.accent, lineWidth: 1)
            }
            .contentShape(Rectangle())
    }
}

/// Neutral outlined button (`.btn-secondary`).
struct SecondaryButtonStyle: ButtonStyle {
    var block = false
    var leadingAligned = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.heading(14))
            .foregroundStyle(Theme.text)
            .frame(maxWidth: block ? .infinity : nil, alignment: leadingAligned ? .leading : .center)
            .padding(.vertical, Theme.space2)
            .padding(.horizontal, leadingAligned ? 16 : Theme.space3 * 1.2)
            .background(
                Theme.text.opacity(configuration.isPressed ? 0.14 : 0),
                in: RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous)
                    .strokeBorder(Theme.divider, lineWidth: 1)
            }
            .contentShape(Rectangle())
    }
}

/// Text-only accent button (`.btn-ghost`).
struct GhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.heading(12))
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, Theme.space1)
            .padding(.vertical, 2)
            .background(
                Theme.accent.opacity(configuration.isPressed ? 0.18 : 0),
                in: RoundedRectangle(cornerRadius: Theme.radiusSm, style: .continuous)
            )
            .contentShape(Rectangle())
    }
}

// MARK: - Fading rule

struct FadingRule: View {
    var body: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: Theme.divider, location: 0.12),
                .init(color: Theme.divider, location: 0.88),
                .init(color: .clear, location: 1),
            ],
            startPoint: .leading, endPoint: .trailing
        )
        .frame(height: 1)
        .padding(.vertical, Theme.space4)
    }
}

// MARK: - Section header (uppercase kicker)

struct SectionKicker: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(Theme.body(11))
            .tracking(0.9)
            .foregroundStyle(Theme.muted(0.5))
    }
}
