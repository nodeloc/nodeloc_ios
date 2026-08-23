//
//  nodelocApp.swift
//  nodeloc
//
//  Created by Jungle on 2026/08/19.
//

import SwiftUI

@main
struct nodelocApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // BGTaskScheduler requires its tasks to be registered before the app
        // finishes launching, so push wiring happens here rather than in a view.
        PushNotificationService.shared.configure()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                PushNotificationService.shared.appDidBecomeActive()
            case .background:
                PushNotificationService.shared.scheduleBackgroundRefresh()
                // The website session's `_t` token rotates; snapshot the jar's
                // current cookies so the next launch restores a live session.
                DiscourseLogin.shared.persistRotatedSession()
            default:
                break
            }
        }
    }
}
