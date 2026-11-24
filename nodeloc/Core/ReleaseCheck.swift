//
//  ReleaseCheck.swift
//  nodeloc
//
//  Asks the server once per launch whether a newer build is out, and says so
//  in a toast. A build below the server's minimum is told it must update.
//

import Foundation

@MainActor
enum ReleaseCheck {
    private static var didRun = false

    static func runOnce() {
        guard !didRun else { return }
        didRun = true
        Task {
            guard let answer = try? await DiscourseClient().releaseCheck(),
                  answer.updateAvailable, let latest = answer.latest else { return }
            if answer.updateRequired {
                ToastCenter.shared.show(AppString("这个版本已停止支持，请到 App Store 更新到 \(latest.version)"))
            } else {
                ToastCenter.shared.show(AppString("新版本 \(latest.version) 已发布，可以到 App Store 更新"))
            }
        }
    }
}
