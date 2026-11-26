//
//  nodelocApp.swift
//  nodeloc
//
//  Created by Jungle on 2026/08/19.
//

import SwiftUI
import UIKit

@main
struct nodelocApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // BGTaskScheduler requires its tasks to be registered before the app
        // finishes launching, so push wiring happens here rather than in a view.
        PushNotificationService.shared.configure()
        // Account-bound caches go with the account; the interface language
        // follows the device again.
        DiscourseLogin.onSignOut = {
            Task { await PushNotificationService.shared.unregisterFromServer() }
            ProfileSnapshot.clearAll()
            AppLanguage.accountChoice = nil
            Task { try? await ChatStorage.shared.clearAll() }
        }
        DiscourseLogin.onSignIn = {
            AppLanguage.accountChoice = nil
            // The token may already be in hand from before the sign-in.
            Task { await PushNotificationService.shared.syncRegistration() }
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                PushNotificationService.shared.appDidBecomeActive()
                ReleaseCheck.runOnce()
            case .background:
                PushNotificationService.shared.scheduleBackgroundRefresh()
                // A cookie session can rotate; keep the newest for next launch.
                DiscourseLogin.shared.persistRotatedSession()
            default:
                break
            }
        }
    }
}
