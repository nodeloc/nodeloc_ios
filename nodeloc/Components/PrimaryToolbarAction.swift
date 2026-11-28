//
//  PrimaryToolbarAction.swift
//  nodeloc
//
//  A form's one primary action (保存, 提交, 创建…) as the system's own
//  confirmation button at the top right of the navigation bar: bold, the
//  system tint, disabled until the form is valid, and a small spinner in its
//  place while the request runs. Forms no longer carry a filled button at
//  the bottom of their content.
//

import SwiftUI

struct PrimaryToolbarAction: ToolbarContent {
    let title: String
    var isEnabled = true
    var isWorking = false
    let action: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) {
            if isWorking {
                ProgressView()
                    .accessibilityLabel(AppString("正在提交"))
            } else {
                Button(title, action: action)
                    .fontWeight(.semibold)
                    .disabled(!isEnabled)
            }
        }
    }
}

extension View {
    /// Puts the form's primary action in the navigation bar (see `PrimaryToolbarAction`).
    func primaryToolbarAction(
        _ title: String,
        isEnabled: Bool = true,
        isWorking: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        toolbar {
            PrimaryToolbarAction(title: title, isEnabled: isEnabled, isWorking: isWorking, action: action)
        }
    }
}

/// The message a 422 gave for one field, under that field.
struct FieldErrorText: View {
    let message: String?

    var body: some View {
        if let message, !message.isEmpty {
            Text(message)
                .font(.footnote)
                .foregroundStyle(Theme.danger)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
