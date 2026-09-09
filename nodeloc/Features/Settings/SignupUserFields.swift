//
//  SignupUserFields.swift
//  nodeloc
//
//  The admin's custom profile fields, collected during signup.
//
//  Not hardcoded, because they are *site* configuration and change without the
//  app: nodeloc added a required "Gender" dropdown after 1.0 shipped, and every
//  signup then failed with "you haven't filled in all the required fields" for
//  a field the app had never heard of. So the definitions come from
//  `site.json`, whatever they happen to be, and the form is built from them.
//
//  Only the fields the server marks required at registration are asked for.
//  Optional ones belong in profile editing, not in the way of signing up.
//

import SwiftUI

/// Loads the site's field definitions and holds the answers.
@MainActor
@Observable
final class SignupUserFieldsModel {
    /// Only what registration actually requires, in the admin's own order.
    private(set) var fields: [DiscourseUserField] = []
    /// Answers keyed by field id, ready for `DiscourseLogin.signup`.
    var values: [Int: String] = [:]
    private(set) var isLoading = false

    /// True when every required field has an answer — what the continue button
    /// should be gated on, so the failure happens here rather than as a server
    /// rejection after the account is half-made.
    var isComplete: Bool {
        fields.allSatisfy { field in
            guard field.isRequiredAtSignup else { return true }
            let value = values[field.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // A `confirm` field is a checkbox: "true" is the only answer that
            // counts as filled in.
            return field.isConfirm ? value == "true" : !value.isEmpty
        }
    }

    /// Nothing to ask, so the step can be skipped entirely.
    var isEmpty: Bool { fields.isEmpty }

    func load() async {
        guard fields.isEmpty, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let site = await SiteResources.shared.siteResponse()
        fields = (site?.userFields ?? [])
            .filter { $0.isRequiredAtSignup }
            .sorted { ($0.position ?? 0) < ($1.position ?? 0) }
    }
}

/// The form rows for those fields. Used by both auth flows so a new required
/// field appears in each without being wired up twice.
struct SignupUserFieldsSection: View {
    let model: SignupUserFieldsModel

    var body: some View {
        ForEach(model.fields) { field in
            row(for: field)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // The field's `description` is deliberately not drawn. On nodeloc it
    // restates the name — "Gender identity" under a control already labelled
    // "Gender" — and no other row in this form carries a subtitle. If an admin
    // ever writes a description that actually instructs (a format, a rule),
    // this is the decision to revisit.

    /// Styled as the surrounding form is, not as the system draws a `Picker`.
    ///
    /// These rows sit between `AuthInputField` capsules, and a stock menu
    /// picker and `.roundedBorder` field next to those read as a different
    /// app. The shape comes from `AuthFieldCapsule` so the two can't drift.
    @ViewBuilder
    private func row(for field: DiscourseUserField) -> some View {
        let selection = binding(for: field)
        let name = field.name ?? ""

        if field.isDropdown, let options = field.options, !options.isEmpty {
            Menu {
                Picker(name, selection: selection) {
                    // A blank entry, so the picker can start unanswered rather
                    // than silently defaulting to the first option — which
                    // would submit an answer nobody chose.
                    Text(AppString("请选择")).tag("")
                    ForEach(options, id: \.self) { option in
                        // Shown verbatim: the server validates the submitted
                        // value against this exact list, so translating the
                        // label would mean submitting something it rejects.
                        Text(option).tag(option)
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    // The name until there's an answer, then the answer — the
                    // same trade a placeholder makes in the fields above.
                    Text(selection.wrappedValue.isEmpty ? name : selection.wrappedValue)
                        .font(Theme.body(18))
                        .foregroundStyle(
                            selection.wrappedValue.isEmpty ? Theme.muted(0.55) : Theme.text
                        )
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    Image(systemName: "chevron.down")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.muted(0.6))
                }
                .modifier(AuthFieldCapsule(isFilled: !selection.wrappedValue.isEmpty))
                // A menu's label is hit-tested like any other drawn content,
                // so without this only the text and chevron would open it.
                .contentShape(Capsule())
            }
        } else if field.isConfirm {
            // The label stays here: a lone switch in a capsule says nothing
            // about what is being agreed to.
            Toggle(isOn: Binding(
                get: { selection.wrappedValue == "true" },
                set: { selection.wrappedValue = $0 ? "true" : "" }
            )) {
                Text(name)
                    .font(Theme.body(16))
                    .foregroundStyle(Theme.text)
                    .lineLimit(2)
            }
            .tint(Theme.accent)
            .modifier(AuthFieldCapsule(isFilled: selection.wrappedValue == "true"))
        } else {
            // `text`, and anything new the app doesn't recognise — a plain
            // field is a better guess than refusing to draw the row, which
            // would make registration impossible. Reuses the form's own field,
            // so it gets the same tap target and clear button.
            AuthInputField(name, text: selection)
        }
    }

    private func binding(for field: DiscourseUserField) -> Binding<String> {
        Binding(
            get: { model.values[field.id] ?? "" },
            set: { model.values[field.id] = $0 }
        )
    }
}
