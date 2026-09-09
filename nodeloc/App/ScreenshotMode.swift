//
//  ScreenshotMode.swift
//  nodeloc
//
//  Launch-argument hooks for capturing App Store screenshots.
//
//  The problem this solves: the app opens on the auth screen, and neither
//  `isGuest` nor `onboardingDone` is persisted, so there is no way to reach the
//  feed from a script — `simctl` has no tap command. Rather than drive the UI,
//  the capture script asks for the screen it wants directly.
//
//  Wrapped in `#if DEBUG` so none of it exists in a Release build. A Release
//  binary can't be launched with arguments from the App Store anyway, but
//  compiling it out means there is nothing to reason about at review time.
//

#if DEBUG
import Foundation

enum ScreenshotMode {
    /// Skips auth and onboarding and lands on the feed as a guest.
    static var isActive: Bool {
        arguments.contains("-screenshotMode")
    }

    /// `home` / `nodes` / `chat` / `profile` / `search`.
    static var tab: String? { value(for: "-screenshotTab") }

    /// Opens a topic on top of the chosen tab, for a post-detail shot.
    static var topicID: Int? { value(for: "-screenshotTopic").flatMap(Int.init) }

    /// Opens the sidebar drawer, for a navigation shot on iPhone.
    static var showsSidebar: Bool {
        arguments.contains("-screenshotSidebar")
    }

    private static var arguments: [String] { ProcessInfo.processInfo.arguments }

    /// Reads `-flag value`, which is the shape `simctl launch` passes through.
    private static func value(for flag: String) -> String? {
        guard let index = arguments.firstIndex(of: flag),
              arguments.index(after: index) < arguments.endIndex
        else { return nil }
        return arguments[arguments.index(after: index)]
    }
}
#endif
