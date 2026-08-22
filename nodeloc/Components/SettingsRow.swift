//
//  SettingsRow.swift
//  nodeloc
//
//  The row vocabulary the preference screens are built from.
//

import SwiftUI

/// A titled group of rows, with an optional explanatory footer.
struct SettingsSection<Content: View>: View {
    let title: String
    var footer: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(Theme.body(12, weight: .semibold))
                .foregroundStyle(Theme.muted(0.55))
                .padding(.horizontal, 20)
                .padding(.bottom, 8)

            VStack(spacing: 0) {
                content
            }

            if let footer {
                Text(footer)
                    .font(Theme.body(11))
                    .foregroundStyle(Theme.muted(0.5))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 20)
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
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) { rowDivider }
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
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.muted(0.3))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) { rowDivider }
        .sheet(isPresented: $isPresented) {
            SettingsOptionSheet(
                title: title,
                options: options,
                label: label,
                selection: $selection
            )
        }
    }
}

/// The option list a picker row opens.
private struct SettingsOptionSheet<Option: Identifiable & Equatable>: View {
    @Environment(\.dismiss) private var dismiss

    let title: String
    let options: [Option]
    let label: (Option) -> String
    @Binding var selection: Option

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(options) { option in
                        Button {
                            selection = option
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                Text(label(option))
                                    .font(Theme.body(15))
                                    .foregroundStyle(Theme.text)
                                    .multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true)

                                Spacer(minLength: 8)

                                if option == selection {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundStyle(Theme.accent)
                                }
                            }
                            .padding(.horizontal, 18)
                            .padding(.vertical, 13)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(option == selection ? Theme.accent.opacity(0.07) : .clear)
                            .contentShape(Rectangle())
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

/// A row that pushes to another screen.
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
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(isDestructive ? Theme.danger : tint)
                        .frame(width: 24)
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
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) { rowDivider }
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
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) { rowDivider }
    }
}

/// Shared hairline, inset to line up with the row's text.
@ViewBuilder
private var rowDivider: some View {
    Rectangle()
        .fill(Theme.divider)
        .frame(height: 1)
        .padding(.leading, 20)
}
