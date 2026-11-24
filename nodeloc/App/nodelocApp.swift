//
//  nodelocApp.swift
//  nodeloc
//
//  Created by Jungle on 2026/08/19.
//

import SwiftUI
import UIKit

/// Receives the APNs device token, which only an app delegate is given.
final class NodelocAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        PushNotificationService.shared.didRegisterForRemoteNotifications(deviceToken: deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        #if DEBUG
        print("[Push] APNs registration failed: \(error)")
        #endif
    }
}

@main
struct nodelocApp: App {
    @UIApplicationDelegateAdaptor(NodelocAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // BGTaskScheduler requires its tasks to be registered before the app
        // finishes launching, so push wiring happens here rather than in a view.
        PushNotificationService.shared.configure()
        // Account-bound caches go with the account; the interface language
        // follows the device again.
        DiscourseLogin.onSignOut = {
            ProfileSnapshot.clearAll()
            AppLanguage.accountChoice = nil
            Task { try? await ChatStorage.shared.clearAll() }
        }
        DiscourseLogin.onSignIn = {
            AppLanguage.accountChoice = nil
            PushNotificationService.shared.registerForRemotePushIfAllowed()
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
