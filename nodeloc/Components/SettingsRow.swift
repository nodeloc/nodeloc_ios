//
//  SettingsRow.swift
//  nodeloc
//
//  The row vocabulary the preference screens are built from. Rows sit inside a
//  rounded `Theme.surface` card per section, matching the grouped-card look the
//  sidebar and node pages use — not a flat hairline list.
//

import SwiftUI

// Native now: every settings page is a `Form` (inset grouped), so these are
// thin wrappers over `Section`, `Toggle`, `Picker`, `TextField` and plain
// button rows, keeping the call sites unchanged.

/// The system navigation bar for a settings page pushed on the app's stack:
/// the inline title, and trailing items (a saving spinner, 完成…) as native
/// toolbar items. The system back button and swipe leave the page, so
/// `onClose` is kept only for the callers' sake.
struct SettingsBar<Trailing: View>: View {
    let title: String
    var onClose: () -> Void = {}
    @ViewBuilder var trailing: () -> Trailing

    init(title: String, onClose: @escaping () -> Void = {}, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.onClose = onClose
        self.trailing = trailing
    }

    var body: some View {
        Color.clear
            .frame(height: 0)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { trailing() }
            }
    }
}

extension SettingsBar where Trailing == EmptyView {
    init(title: String, onClose: @escaping () -> Void = {}) {
        self.init(title: title, onClose: onClose) { EmptyView() }
    }
}

/// A titled group of rows: a `Section` of the page's `Form`.
struct SettingsSection<Content: View>: View {
    let title: String
    var footer: String?
    @ViewBuilder var content: Content

    var body: some View {
        Section {
            content
        } header: {
            Text(title)
        } footer: {
            if let footer { Text(footer) }
        }
    }
}

/// A boolean preference: a native `Toggle`.
struct SettingsToggleRow: View {
    let title: String
    var detail: String?
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .tint(Theme.accent)
    }
}

/// A preference chosen from a fixed set: a native `Picker` that pushes its
/// options (several labels run to a full sentence, too long for a menu).
struct SettingsPickerRow<Option: Identifiable & Equatable>: View {
    let title: String
    var detail: String?
    let options: [Option]
    let label: (Option) -> String
    @Binding var selection: Option

    var body: some View {
        Picker(selection: Binding(
            get: { selection.id },
            set: { id in if let option = options.first(where: { $0.id == id }) { selection = option } }
        )) {
            ForEach(options) { option in
                Text(label(option)).tag(option.id)
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .pickerStyle(.navigationLink)
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
        Button(role: isDestructive ? .destructive : nil, action: action) {
            HStack(spacing: 12) {
                if let icon {
                    Image(systemName: icon)
                        .foregroundStyle(isDestructive ? Theme.danger : tint)
                        .frame(width: 26)
                }
                Text(title)
                    .foregroundStyle(isDestructive ? Theme.danger : Theme.text)
                Spacer(minLength: 8)
                if let detail {
                    Text(detail)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if !isDestructive {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
    }
}

/// A free-text preference, e.g. the timezone identifier.
struct SettingsTextRow: View {
    let title: String
    var placeholder: String = ""
    @Binding var text: String
    var onCommit: () -> Void = {}

    var body: some View {
        LabeledContent(title) {
            TextField(placeholder, text: $text)
                .multilineTextAlignment(.trailing)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit(onCommit)
        }
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
                .font(.footnote)
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $text, axis: .vertical)
                .lineLimit(3...8)
        }
    }
}

/// A faint press highlight, for the few custom rows left in settings.
struct SettingsRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Theme.hover : .clear)
    }
}
