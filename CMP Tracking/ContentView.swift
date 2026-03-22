//
//  ContentView.swift
//  CMP Tracking
//
//  Created by Megan Dramski on 3/18/26.
//

import SwiftUI

// MARK: - Root Content View

struct ContentView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        if appState.isLoggedIn {
            switch appState.userRole {
            case .driver:
                DriverView()
            case .dispatcher:
                DispatcherView()
            }
        } else {
            AuthView()
        }
    }
}

// MARK: - Auth View (Sign In / Create Account)

struct AuthView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var authManager: AuthManager

    @State private var isCreatingAccount = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 32) {

                    // ── Logo ──────────────────────────────────────────────
                    VStack(spacing: 8) {
                        ParceloLogo(size: 90)
                        Text("Logistics. Simplified.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, 40)

                    // ── Form ──────────────────────────────────────────────
                    if isCreatingAccount {
                        CreateAccountForm()
                    } else {
                        SignInForm()
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
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var authManager: AuthManager

    @State private var loginId      = ""   // phone (driver) or email (dispatcher)
    @State private var password     = ""
    @State private var errorMsg: String? = nil
    @State private var showPassword = false
    @State private var selectedRole: UserRole = .driver

    private var isDriver: Bool { selectedRole == .driver }
    private var placeholder: String { isDriver ? "Phone Number" : "Email" }
    private var keyboardType: UIKeyboardType { isDriver ? .phonePad : .emailAddress }
    private var contentType: UITextContentType { isDriver ? .telephoneNumber : .emailAddress }
    private var isDisabled: Bool { loginId.isEmpty || password.isEmpty || authManager.isLoading }

    var body: some View {
        VStack(spacing: 20) {

            // ── Role Toggle ───────────────────────────────────────────────
            Picker("Role", selection: $selectedRole) {
                Text("🚛  Driver").tag(UserRole.driver)
                Text("📋  Dispatcher").tag(UserRole.dispatcher)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)

            // ── Fields ────────────────────────────────────────────────────
            VStack(spacing: 14) {
                TextField(placeholder, text: $loginId)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(keyboardType)
                    .autocapitalization(.none)
                    .autocorrectionDisabled()
                    .textContentType(contentType)
                    .animation(.easeInOut(duration: 0.2), value: isDriver)

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
        authManager.signIn(loginId: loginId, role: selectedRole, password: password) { err in
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
