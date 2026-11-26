//
//  RemoteNotifications.swift
//  nodeloc
//
//  The APNs half of push. SwiftUI has no hook for a device token — it arrives
//  through `UIApplicationDelegate` and nowhere else — so the app installs this
//  adaptor purely to forward three callbacks to `PushNotificationService`.
//
//  What has to be set in Xcode, because neither can be added from code:
//   1. Signing & Capabilities → + Capability → **Push Notifications**. That
//      writes `aps-environment` into the entitlements *and* turns the
//      capability on for the App ID, which is what makes APNs accept the app.
//   2. Background Modes → **Remote notifications**, for the silent pushes that
//      keep the badge honest while the app is closed. (`fetch` is already on
//      for the polling fallback.)
//  Without them registration fails with a "no valid aps-environment" error,
//  which `didFailToRegister` surfaces instead of swallowing — see
//  `PushNotificationService.remoteRegistrationError`.
//

import SwiftUI
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        // Hex, which is the form every APNs provider API expects.
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { @MainActor in
            await PushNotificationService.shared.deviceTokenArrived(token)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        Task { @MainActor in
            PushNotificationService.shared.remoteRegistrationFailed(error)
        }
    }

    /// A silent push (`content-available: 1`), or the data half of an alert
    /// push. Used to keep the badge and the inbox in step without waiting for
    /// the reader to open the app.
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any]
    ) async -> UIBackgroundFetchResult {
        await PushNotificationService.shared.remoteNotificationArrived(userInfo)
    }
}
