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

// MARK: - DeepLinkFetcher
// Lightweight helper: fetches a load by token and upserts it into LoadWallet.
// Used when a new driver link arrives while the app is already in the driver flow.
final class DeepLinkFetcher {
    private let link: DriverDeepLink

    init(link: DriverDeepLink) { self.link = link }

    func fetch() {
        let base = AWSConfig.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !base.isEmpty, !base.contains("REPLACE"),
              let url = URL(string: "\(base)/track/\(link.token)") else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let self, let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            let entry = LoadWallet.entry(from: json, link: self.link)
            DispatchQueue.main.async {
                LoadWallet.shared.add(entry: entry)
            }
        }.resume()
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
                } else if !LoadWallet.shared.cards.isEmpty && !(appState.isLoggedIn && appState.userRole == .driver) {
                    // Wallet has persisted cards from a previous session (unauthenticated driver flow)
                    DriverLinkView(link: DriverDeepLink(token: LoadWallet.shared.cards.first?.token ?? "",
                                                        loadId: LoadWallet.shared.cards.first?.id ?? ""))
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
        let isDriverLink = (scheme == "cmptracking" && url.host == "load")
                        || (scheme == "cmptracking")
                        || (scheme == "routelo" && url.host == "driver")
                        || (scheme == "routelo" && url.host == "load")

        if isDriverLink && (!qToken.isEmpty || !qLoadId.isEmpty) {
            let newLink = DriverDeepLink(token: qToken, loadId: qLoadId)
            DispatchQueue.main.async {
                if self.driverLink != nil || !LoadWallet.shared.cards.isEmpty {
                    // Already in driver wallet flow — fetch and add the new load to wallet
                    // Create a temporary VM just to fetch and upsert the new entry
                    let fetcher = DeepLinkFetcher(link: newLink)
                    fetcher.fetch()
                    // Hold reference so it isn't deallocated before fetch completes
                    self._pendingFetchers.append(fetcher)
                } else {
                    self.driverLink = newLink
                }
            }
            return
        }

        // ── Customer shipment tracking link ───────────────────────────────
        let pathComponents = url.pathComponents
        if let trackIndex = pathComponents.firstIndex(of: "track"),
           trackIndex + 1 < pathComponents.count {
            let token = pathComponents[trackIndex + 1]
            DispatchQueue.main.async { self.trackingToken = token }
            return
        }

        // ── Stripe billing callback ───────────────────────────────────────
        if comps?.queryItems?.contains(where: { $0.name == "billing" }) == true {
            NotificationCenter.default.post(name: .billingCallback, object: url)
            return
        }

        // ── Fallback ──────────────────────────────────────────────────────
        if !qToken.isEmpty || !qLoadId.isEmpty {
            let newLink = DriverDeepLink(token: qToken, loadId: qLoadId)
            DispatchQueue.main.async {
                if self.driverLink != nil || !LoadWallet.shared.cards.isEmpty {
                    let fetcher = DeepLinkFetcher(link: newLink)
                    fetcher.fetch()
                    self._pendingFetchers.append(fetcher)
                } else {
                    self.driverLink = newLink
                }
            }
        }
    }

    // Temporary storage for in-flight fetchers so ARC doesn't kill them
    private var _pendingFetchers: [DeepLinkFetcher] = []
}
