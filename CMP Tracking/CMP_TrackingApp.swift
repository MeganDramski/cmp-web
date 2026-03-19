//
//  CMP_TrackingApp.swift
//  CMP Tracking
//
//  Created by Megan Dramski on 3/18/26.
//

import SwiftUI
import SwiftData

@main
struct CMP_TrackingApp: App {
    @StateObject private var appState   = AppState.shared
    @StateObject private var authManager = AuthManager()
    @State private var trackingToken: String? = nil

    // SwiftData container storing UserAccount records
    let modelContainer: ModelContainer = {
        let schema = Schema([UserAccount.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("Could not create SwiftData ModelContainer: \(error)")
        }
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
            .onOpenURL { url in handleDeepLink(url) }
            .onAppear {
                // Give AuthManager access to the SwiftData context, then restore session
                authManager.modelContext = modelContainer.mainContext
                authManager.restoreSession()
                if let account = authManager.currentAccount {
                    appState.login(from: account)
                }
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
