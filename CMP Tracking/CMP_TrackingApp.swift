//
//  CMP_TrackingApp.swift
//  CMP Tracking
//
//  Created by Megan Dramski on 3/18/26.
//

import SwiftUI
import SwiftData
import UserNotifications

// MARK: - Notification Delegate

/// Receives local notification callbacks on behalf of the app.
/// • Foreground: shows the banner while the app is open.
/// • Tap: routes the driver to their dashboard.
final class AppNotificationDelegate: NSObject, UNUserNotificationCenterDelegate, ObservableObject {

    /// Set to true when a pickup-reminder notification is tapped — DriverView observes this.
    @Published var shouldOpenDriverDashboard = false

    // Show banner even when the app is in the foreground
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                 willPresent notification: UNNotification,
                                 withCompletionHandler handler: @escaping (UNNotificationPresentationOptions) -> Void) {
        handler([.banner, .sound, .badge])
    }

    // Handle tap on a pickup reminder notification
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                 didReceive response: UNNotificationResponse,
                                 withCompletionHandler handler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        if (info["action"] as? String) == "openDriver" {
            DispatchQueue.main.async { self.shouldOpenDriverDashboard = true }
        }
        handler()
    }
}

@main
struct CMP_TrackingApp: App {
    @StateObject private var appState    = AppState.shared
    @StateObject private var authManager = AuthManager()
    @StateObject private var notifDelegate = AppNotificationDelegate()
    @State private var trackingToken: String? = nil

    // SwiftData container — tries on-disk, self-heals on schema mismatch.
    // Accounts are ALSO persisted in the Keychain so they survive any reset.
    // This eliminates the "app reinstalls itself" crash loop caused by
    // SwiftData schema changes between Xcode builds.
    let modelContainer: ModelContainer = {
        let schema = Schema([UserAccount.self])
        let storeURL = URL.applicationSupportDirectory
            .appendingPathComponent("default.store")

        // 1. Try the existing on-disk store
        let diskConfig = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        if let container = try? ModelContainer(for: schema, configurations: [diskConfig]) {
            return container
        }

        // 2. Schema mismatch — wipe the corrupted store and recreate it.
        //    Keychain holds all account data so nothing is truly lost.
        let fm = FileManager.default
        let storeDir = URL.applicationSupportDirectory
        for ext in ["", "-shm", "-wal"] {
            let file = storeDir.appendingPathComponent("default.store\(ext)")
            try? fm.removeItem(at: file)
        }
        if let container = try? ModelContainer(for: schema, configurations: [diskConfig]) {
            return container
        }

        // 3. Last resort — pure in-memory (Keychain re-seeds on next launch)
        let memConfig = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return (try? ModelContainer(for: schema, configurations: [memConfig]))
            ?? { fatalError("SwiftData: cannot create any ModelContainer") }()
    }()

    var body: some Scene {
        WindowGroup {
            Group {
                if let token = trackingToken {
                    CustomerTrackingView(trackingToken: token)
                } else {
                    ContentView()
                }
            }
            .environmentObject(appState)
            .environmentObject(authManager)
            .environmentObject(notifDelegate)
            .onOpenURL { url in handleDeepLink(url) }
            .onAppear {
                // Register the notification delegate so foreground banners & taps work
                UNUserNotificationCenter.current().delegate = notifDelegate

                // Give AuthManager access to the SwiftData context, then restore session
                authManager.modelContext = modelContainer.mainContext
                authManager.restoreSession()
                if let account = authManager.currentAccount {
                    appState.login(from: account)
                }
                // Request permission to show local arrival & pickup notifications
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
            }
        }
        .modelContainer(modelContainer)
    }

    private func handleDeepLink(_ url: URL) {
        let components = url.pathComponents
        if let trackIndex = components.firstIndex(of: "track"),
           trackIndex + 1 < components.count {
            trackingToken = components[trackIndex + 1]
        }
    }
}
