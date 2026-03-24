//
//  ContentView.swift
//  CMP Tracking
//
//  Created by Megan Dramski on 3/18/26.
//

import SwiftUI
import UserNotifications

// MARK: - Root Content View

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @State private var showDispatcherLogin = false

    var body: some View {
        if appState.isLoggedIn && appState.userRole == .dispatcher {
            DispatcherView()
        } else if appState.isLoggedIn && appState.userRole == .driver {
            DriverView()
        } else if showDispatcherLogin {
            AuthView(showDispatcherLogin: $showDispatcherLogin)
        } else {
            // Default: driver waiting screen — no sign-in required
            DriverWaitingView(showDispatcherLogin: $showDispatcherLogin)
        }
    }
}

// MARK: - Driver Waiting Screen (default launch screen — no auth)

struct DriverWaitingView: View {
    @Binding var showDispatcherLogin: Bool
    @EnvironmentObject var appState: AppState
    @State private var notifScheduled = false

    var body: some View {
        ZStack {
            Color(red: 0.06, green: 0.06, blue: 0.11).ignoresSafeArea()

            VStack(spacing: 32) {
                Spacer()

                RouteloAnimatedIcon(size: 80)

                VStack(spacing: 12) {
                    Text("Waiting for your load…")
                        .font(.title2).fontWeight(.bold).foregroundColor(.white)
                    Text("Your dispatcher will send you an SMS link.\nTap it and your load will appear here.")
                        .font(.subheadline).foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                VStack(spacing: 8) {
                    Image(systemName: "message.fill")
                        .font(.system(size: 48))
                        .foregroundColor(.accentColor.opacity(0.4))
                    Text("📱 Check your SMS")
                        .font(.caption).foregroundColor(.secondary)
                }

                Spacer()

                // ── DEBUG: notification tester ────────────────────────────
                #if DEBUG
                VStack(spacing: 6) {
                    Button(action: scheduleTestNotification) {
                        Label(
                            notifScheduled ? "Notification sent in 5s ✓" : "Test Notification (5s)",
                            systemImage: notifScheduled ? "checkmark.circle.fill" : "bell.badge"
                        )
                        .font(.caption).fontWeight(.semibold)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(Color.blue.opacity(0.15))
                        .foregroundColor(notifScheduled ? .green : .blue)
                        .cornerRadius(10)
                        .overlay(RoundedRectangle(cornerRadius: 10)
                            .stroke((notifScheduled ? Color.green : Color.blue).opacity(0.4), lineWidth: 1))
                    }
                    .disabled(notifScheduled)
                    Text("Background the app to see it")
                        .font(.caption2).foregroundColor(.secondary)
                }
                .padding(.bottom, 4)
                #endif

                // Small unobtrusive dispatcher link at the bottom
                Button(action: { showDispatcherLogin = true }) {
                    Text("Dispatcher Portal →")
                        .font(.caption).foregroundColor(.secondary)
                }
                .padding(.bottom, 32)
            }
        }
    }

    // MARK: - Debug notification helper
    #if DEBUG
    private func scheduleTestNotification() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "🚛 Test Notification"
            content.body  = "Routelo notifications are working!"
            content.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false)
            let request = UNNotificationRequest(
                identifier: "debug-test-\(UUID().uuidString)",
                content: content,
                trigger: trigger
            )
            UNUserNotificationCenter.current().add(request) { _ in
                DispatchQueue.main.async { notifScheduled = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 10) { notifScheduled = false }
            }
        }
    }
    #endif
}

// MARK: - Auth View (Dispatcher only)

struct AuthView: View {
    @Binding var showDispatcherLogin: Bool
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var authManager: AuthManager
    @State private var isCreatingAccount = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 32) {

                    // ── Back + Logo ───────────────────────────────────────
                    VStack(spacing: 8) {
                        HStack {
                            Button(action: { showDispatcherLogin = false }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "chevron.left")
                                    Text("Back")
                                }
                                .foregroundColor(.accentColor)
                                .font(.subheadline)
                            }
                            Spacer()
                        }
                        .padding(.horizontal)

                        RouteloLogo(size: 70)
                        Text("Dispatcher Portal")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, 20)

                    // ── Form ──────────────────────────────────────────────
                    if isCreatingAccount {
                        CreateAccountForm()
                    } else {
                        SignInForm(isDriverRole: false)
                    }

                    // ── Toggle ────────────────────────────────────────────
                    Button(action: { isCreatingAccount.toggle() }) {
                        HStack(spacing: 4) {
                            Text(isCreatingAccount ? "Already have an account?" : "Don't have an account?")
                                .foregroundColor(.secondary)
                            Text(isCreatingAccount ? "Sign In" : "Create Account")
                                .fontWeight(.semibold)
                                .foregroundColor(.accentColor)
                        }
                        .font(.subheadline)
                    }
                    .padding(.bottom, 40)
                }
            }
            .navigationBarHidden(true)
        }
    }
}

// MARK: - Sign In Form

struct SignInForm: View {
    var isDriverRole: Bool = false   // false = dispatcher only (no role picker shown)

    @EnvironmentObject var appState: AppState
    @EnvironmentObject var authManager: AuthManager

    @State private var loginId      = ""
    @State private var password     = ""
    @State private var errorMsg: String? = nil
    @State private var showPassword = false
    @State private var selectedRole: UserRole = .dispatcher

    private var placeholder: String { "Email" }
    private var isDisabled: Bool { loginId.isEmpty || password.isEmpty || authManager.isLoading }

    var body: some View {
        VStack(spacing: 20) {

            // ── Fields ────────────────────────────────────────────────────
            VStack(spacing: 14) {
                TextField(placeholder, text: $loginId)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.emailAddress)
                    .autocapitalization(.none)
                    .autocorrectionDisabled()
                    .textContentType(.emailAddress)

                HStack {
                    Group {
                        if showPassword {
                            TextField("Password", text: $password)
                        } else {
                            SecureField("Password", text: $password)
                        }
                    }
                    .textContentType(.password)
                    Button(action: { showPassword.toggle() }) {
                        Image(systemName: showPassword ? "eye.slash" : "eye")
                            .foregroundColor(.secondary)
                    }
                }
                .textFieldStyle(.roundedBorder)
            }
            .padding(.horizontal)

            // ── Error ─────────────────────────────────────────────────────
            if let msg = errorMsg {
                Text(msg).font(.caption).foregroundColor(.red).padding(.horizontal)
            }

            // ── Sign In Button ─────────────────────────────────────────────
            Button(action: signIn) {
                if authManager.isLoading {
                    ProgressView().tint(.white)
                        .frame(maxWidth: .infinity).padding()
                        .background(Color.accentColor).cornerRadius(14)
                } else {
                    Text("Sign In")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity).padding()
                        .background(Color.accentColor).foregroundColor(.white).cornerRadius(14)
                }
            }
            .padding(.horizontal)
            .disabled(isDisabled)
            .opacity(isDisabled ? 0.5 : 1)
        }
    }

    private func signIn() {
        errorMsg = nil
        authManager.signIn(loginId: loginId, role: .dispatcher, password: password) { err in
            if let err = err {
                self.errorMsg = err
            } else if let account = self.authManager.currentAccount {
                self.appState.login(from: account)
            }
        }
    }
}

// MARK: - Create Account Form

struct CreateAccountForm: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var authManager: AuthManager

    @State private var name            = ""
    @State private var email           = ""
    @State private var phone           = ""
    @State private var password        = ""
    @State private var confirmPassword = ""
    @State private var selectedRole: UserRole = .driver
    @State private var errorMsg: String? = nil
    @State private var showPassword    = false

    private var isDriver: Bool { selectedRole == .driver }

    // Driver: phone required, email optional
    // Dispatcher: email required, phone optional
    private var isDisabled: Bool {
        name.isEmpty || password.isEmpty ||
        (isDriver  && phone.isEmpty) ||
        (!isDriver && email.isEmpty) ||
        authManager.isLoading
    }

    var body: some View {
        VStack(spacing: 20) {

            // ── Role Picker ───────────────────────────────────────────────
            VStack(alignment: .leading, spacing: 8) {
                Text("I am a…").font(.headline).padding(.horizontal)
                Picker("Role", selection: $selectedRole) {
                    Text("🚛  Driver").tag(UserRole.driver)
                    Text("📋  Dispatcher").tag(UserRole.dispatcher)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
            }

            // ── Fields ────────────────────────────────────────────────────
            VStack(spacing: 14) {
                TextField("Full Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.name)

                // Phone — required for drivers, optional for dispatchers
                HStack {
                    TextField(isDriver ? "Phone Number (required)" : "Phone Number (optional)",
                              text: $phone)
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.phonePad)
                        .textContentType(.telephoneNumber)
                    if isDriver {
                        Image(systemName: "asterisk").font(.caption).foregroundColor(.red)
                    }
                }

                // Email — required for dispatchers, optional for drivers
                HStack {
                    TextField(isDriver ? "Email (optional)" : "Email (required)",
                              text: $email)
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.emailAddress)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                        .textContentType(.emailAddress)
                    if !isDriver {
                        Image(systemName: "asterisk").font(.caption).foregroundColor(.red)
                    }
                }

                HStack {
                    Group {
                        if showPassword {
                            TextField("Password (min. 6 chars)", text: $password)
                        } else {
                            SecureField("Password (min. 6 chars)", text: $password)
                        }
                    }
                    .textContentType(.newPassword)
                    Button(action: { showPassword.toggle() }) {
                        Image(systemName: showPassword ? "eye.slash" : "eye")
                            .foregroundColor(.secondary)
                    }
                }
                .textFieldStyle(.roundedBorder)

                SecureField("Confirm Password", text: $confirmPassword)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.newPassword)
            }
            .padding(.horizontal)

            // ── Hint ──────────────────────────────────────────────────────
            HStack(spacing: 4) {
                Image(systemName: "info.circle").foregroundColor(.secondary)
                Text(isDriver
                     ? "Drivers sign in with their phone number."
                     : "Dispatchers sign in with their email address.")
                    .foregroundColor(.secondary)
            }
            .font(.caption)
            .padding(.horizontal)

            // ── Error ─────────────────────────────────────────────────────
            if let msg = errorMsg {
                Text(msg).font(.caption).foregroundColor(.red).padding(.horizontal)
            }

            // ── Create Button ─────────────────────────────────────────────
            Button(action: createAccount) {
                if authManager.isLoading {
                    ProgressView().tint(.white)
                        .frame(maxWidth: .infinity).padding()
                        .background(Color.accentColor).cornerRadius(14)
                } else {
                    Text("Create Account")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity).padding()
                        .background(Color.accentColor).foregroundColor(.white).cornerRadius(14)
                }
            }
            .padding(.horizontal)
            .disabled(isDisabled)
            .opacity(isDisabled ? 0.5 : 1)
        }
    }

    private func createAccount() {
        errorMsg = nil
        guard password == confirmPassword else { errorMsg = "Passwords do not match."; return }
        if isDriver && phone.isEmpty { errorMsg = "Phone number is required for drivers."; return }
        if !isDriver && email.isEmpty { errorMsg = "Email is required for dispatchers."; return }

        authManager.createAccount(
            name: name,
            email: email,
            phone: phone,
            password: password,
            role: selectedRole
        ) { err in
            if let err = err {
                self.errorMsg = err
            } else if let account = self.authManager.currentAccount {
                self.appState.login(from: account)
            }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AppState.shared)
        .environmentObject(AuthManager())
}
