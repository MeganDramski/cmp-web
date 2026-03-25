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
    @State private var driverLink: DriverDeepLink? = nil

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
                if let link = driverLink {
                    // Driver tapped SMS link — skip all auth, go straight to tracking
                    DriverLinkView(link: link)
                } else if let token = trackingToken {
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
        guard let scheme = url.scheme?.lowercased() else { return }
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let qToken  = comps?.queryItems?.first(where: { $0.name == "token"  })?.value ?? ""
        let qLoadId = comps?.queryItems?.first(where: { $0.name == "loadId" })?.value ?? ""

        // ── Driver deep links ─────────────────────────────────────────────
        // cmptracking://load?token=xxx&loadId=yyy   (from browser Accept button)
        // routelo://driver?token=xxx&loadId=yyy     (legacy / direct)
        let isDriverLink = (scheme == "cmptracking" && url.host == "load")
                        || (scheme == "cmptracking")          // any cmptracking path
                        || (scheme == "routelo" && url.host == "driver")
                        || (scheme == "routelo" && url.host == "load")

        if isDriverLink && (!qToken.isEmpty || !qLoadId.isEmpty) {
            DispatchQueue.main.async {
                self.driverLink = DriverDeepLink(token: qToken, loadId: qLoadId)
            }
            return
        }

        // ── Customer shipment tracking link ───────────────────────────────
        // routelo://track/xxx  or  cmptracking://track/xxx
        let pathComponents = url.pathComponents
        if let trackIndex = pathComponents.firstIndex(of: "track"),
           trackIndex + 1 < pathComponents.count {
            let token = pathComponents[trackIndex + 1]
            DispatchQueue.main.async { self.trackingToken = token }
            return
        }

        // ── Stripe billing callback ───────────────────────────────────────
        // https://...amplifyapp.com/dispatcher.html?billing=success
        // https://...amplifyapp.com/dispatcher.html?billing=cancelled
        if comps?.queryItems?.contains(where: { $0.name == "billing" }) == true {
            NotificationCenter.default.post(name: .billingCallback, object: url)
            return
        }

        // ── Fallback: any token/loadId query params on either scheme ──────
        if !qToken.isEmpty || !qLoadId.isEmpty {
            DispatchQueue.main.async {
                self.driverLink = DriverDeepLink(token: qToken, loadId: qLoadId)
            }
        }
    }
}
