//
//  SettingsRow.swift
//  nodeloc
//
//  The row vocabulary the preference screens are built from. Rows sit inside a
//  rounded `Theme.surface` card per section, matching the grouped-card look the
//  sidebar and node pages use — not a flat hairline list.
//

import SwiftUI

/// Corner radius shared by every settings card, matching the app's cards.
private let settingsCardRadius: CGFloat = 14
/// Inset of the card from the screen edge.
private let settingsCardInset: CGFloat = 16

/// A titled group of rows in one rounded surface card, with an optional footer.
struct SettingsSection<Content: View>: View {
    let title: String
    var footer: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(Theme.body(12, weight: .semibold))
                .foregroundStyle(Theme.muted(0.55))
                .padding(.horizontal, settingsCardInset + 4)
                .padding(.bottom, 8)

            VStack(spacing: 0) {
                content
            }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: settingsCardRadius, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: settingsCardRadius, style: .continuous))
            .padding(.horizontal, settingsCardInset)

            if let footer {
                Text(footer)
                    .font(Theme.body(11))
                    .foregroundStyle(Theme.muted(0.5))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, settingsCardInset + 4)
                    .padding(.top, 8)
            }
        }
        .padding(.top, 18)
    }
}

/// A boolean preference.
struct SettingsToggleRow: View {
    let title: String
    var detail: String?
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.body(14))
                    .foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail)
                        .font(Theme.body(11))
                        .foregroundStyle(Theme.muted(0.5))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .tint(Theme.accent)
        .settingsRowInsets()
    }
}

/// A preference chosen from a fixed set. The options open in a sheet rather
/// than a menu so long labels — several run to a full sentence — stay readable.
struct SettingsPickerRow<Option: Identifiable & Equatable>: View {
    let title: String
    var detail: String?
    let options: [Option]
    let label: (Option) -> String
    @Binding var selection: Option

    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(Theme.body(14))
                        .foregroundStyle(Theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail {
                        Text(detail)
                            .font(Theme.body(11))
                            .foregroundStyle(Theme.muted(0.5))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 8)

                Text(label(selection))
                    .font(Theme.body(13))
                    .foregroundStyle(Theme.muted(0.55))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.muted(0.35))
            }
            .settingsRowInsets()
            .contentShape(Rectangle())
        }
        .buttonStyle(SettingsRowButtonStyle())
        .sheet(isPresented: $isPresented) {
            SettingsOptionSheet(
                title: title,
                options: options,
                isSelected: { $0 == selection },
                label: label
            ) { option in
                selection = option
                isPresented = false
            }
        }
    }
}

/// A preference where several options can be chosen at once (e.g. featured
/// badges). Shows a summary and opens a checklist sheet.
struct SettingsMultiSelectRow<Option: Identifiable & Equatable>: View {
    let title: String
    var detail: String?
    let options: [Option]
    let label: (Option) -> String
    let isSelected: (Option) -> Bool
    /// Rejected (e.g. at the cap) selections do nothing; the closure decides.
    let toggle: (Option) -> Void
    var summary: String

    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(Theme.body(14))
                        .foregroundStyle(Theme.text)
                    if let detail {
                        Text(detail)
                            .font(Theme.body(11))
                            .foregroundStyle(Theme.muted(0.5))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 8)

                Text(summary)
                    .font(Theme.body(13))
                    .foregroundStyle(Theme.muted(0.55))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.muted(0.35))
            }
            .settingsRowInsets()
            .contentShape(Rectangle())
        }
        .buttonStyle(SettingsRowButtonStyle())
        .sheet(isPresented: $isPresented) {
            SettingsChecklistSheet(
                title: title,
                options: options,
                isSelected: isSelected,
                label: label,
                toggle: toggle
            )
        }
    }
}

/// A row that pushes to another screen or performs an action.
struct SettingsNavRow: View {
    let title: String
    var icon: String?
    var detail: String?
    var tint: Color = Theme.accent
    var isDestructive = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(isDestructive ? Theme.danger : tint)
                        .frame(width: 26)
                }
                Text(title)
                    .font(Theme.body(14))
                    .foregroundStyle(isDestructive ? Theme.danger : Theme.text)

                Spacer(minLength: 8)

                if let detail {
                    Text(detail)
                        .font(Theme.body(12))
                        .foregroundStyle(Theme.muted(0.4))
                        .lineLimit(1)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.muted(0.3))
            }
            .settingsRowInsets()
            .contentShape(Rectangle())
        }
        .buttonStyle(SettingsRowButtonStyle())
    }
}

/// A free-text preference, e.g. the timezone identifier.
struct SettingsTextRow: View {
    let title: String
    var placeholder: String = ""
    @Binding var text: String
    var onCommit: () -> Void = {}

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(Theme.body(14))
                .foregroundStyle(Theme.text)

            Spacer(minLength: 8)

            TextField(placeholder, text: $text)
                .font(Theme.body(13))
                .foregroundStyle(Theme.muted(0.7))
                .multilineTextAlignment(.trailing)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit(onCommit)
        }
        .settingsRowInsets()
    }
}

/// A multi-line free-text field, e.g. a bio. Label above, editor below.
struct SettingsMultilineRow: View {
    let title: String
    var placeholder: String = ""
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(Theme.body(14))
                .foregroundStyle(Theme.text)

            TextField(placeholder, text: $text, axis: .vertical)
                .font(Theme.body(13))
                .foregroundStyle(Theme.muted(0.75))
                .lineLimit(3...8)
                .textFieldStyle(.plain)
        }
        .settingsRowInsets()
    }
}

// MARK: - Row chrome

/// The consistent inset every settings row uses inside its card.
private struct SettingsRowInsets: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private extension View {
    func settingsRowInsets() -> some View { modifier(SettingsRowInsets()) }
}

/// A faint press highlight, so tappable rows react like the sidebar's do.
private struct SettingsRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Theme.hover : .clear)
    }
}

// MARK: - Option sheets

/// Single-choice list a picker row opens.
private struct SettingsOptionSheet<Option: Identifiable & Equatable>: View {
    let title: String
    let options: [Option]
    let isSelected: (Option) -> Bool
    let label: (Option) -> String
    let onPick: (Option) -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(options) { option in
                        Button {
                            onPick(option)
                        } label: {
                            optionRow(label(option), selected: isSelected(option))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 4)
            }
            .scrollIndicators(.hidden)
            .background(Theme.bg)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
        }
        .standardSheet()
    }
}

/// Multi-choice checklist a multi-select row opens.
private struct SettingsChecklistSheet<Option: Identifiable & Equatable>: View {
    let title: String
    let options: [Option]
    let isSelected: (Option) -> Bool
    let label: (Option) -> String
    let toggle: (Option) -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(options) { option in
                        Button {
                            toggle(option)
                        } label: {
                            optionRow(label(option), selected: isSelected(option))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 4)
            }
            .scrollIndicators(.hidden)
            .background(Theme.bg)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
        }
        .standardSheet()
    }
}

/// Shared option row for both sheets.
private func optionRow(_ text: String, selected: Bool) -> some View {
    HStack(spacing: 12) {
        Text(text)
            .font(Theme.body(15))
            .foregroundStyle(Theme.text)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)

        Spacer(minLength: 8)

        if selected {
            Image(systemName: "checkmark")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Theme.accent)
        }
    }
    .padding(.horizontal, 18)
    .padding(.vertical, 13)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(selected ? Theme.accent.opacity(0.07) : .clear)
    .contentShape(Rectangle())
}
