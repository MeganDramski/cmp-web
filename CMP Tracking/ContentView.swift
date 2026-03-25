//
//  ContentView.swift
//  CMP Tracking
//

import SwiftUI

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
            DriverWaitingView(showDispatcherLogin: $showDispatcherLogin)
        }
    }
}

// MARK: - Driver Waiting Screen

struct DriverWaitingView: View {
    @Binding var showDispatcherLogin: Bool
    @EnvironmentObject var appState: AppState

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
                        .multilineTextAlignment(.center).padding(.horizontal, 32)
                }
                VStack(spacing: 8) {
                    Image(systemName: "message.fill").font(.system(size: 48))
                        .foregroundColor(.accentColor.opacity(0.4))
                    Text("📱 Check your SMS").font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                #if DEBUG
                Button(action: injectTestLoad) {
                    Label("Load Test Data (Simulator)", systemImage: "hammer.fill")
                        .font(.caption).fontWeight(.semibold)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(Color.orange.opacity(0.15)).foregroundColor(.orange)
                        .cornerRadius(10)
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.orange.opacity(0.4), lineWidth: 1))
                }
                .padding(.bottom, 8)
                #endif
                Button(action: { showDispatcherLogin = true }) {
                    Text("Dispatcher Portal →").font(.caption).foregroundColor(.secondary)
                }
                .padding(.bottom, 32)
            }
        }
    }

    #if DEBUG
    private func injectTestLoad() {
        let testDriver = Driver(id: "test-driver-001", name: "Test Driver",
                                phone: "5550001234", email: "testdriver@routelo.app", role: .driver)
        let testLoad = Load(
            id: "test-load-001", loadNumber: "CMP-TEST-001",
            description: "Test Load — Electronics", weight: 12000,
            pickupAddress: "123 Warehouse Blvd, Chicago, IL 60601",
            deliveryAddress: "456 Distribution Ave, Dallas, TX 75201",
            pickupDate: Date(), deliveryDate: Date().addingTimeInterval(86400),
            status: .assigned,
            assignedDriverId: testDriver.id, assignedDriverName: testDriver.name,
            assignedDriverEmail: testDriver.email, assignedDriverPhone: testDriver.phone,
            trackingToken: "test-token-abc123",
            customerName: "Acme Corp", customerEmail: "logistics@acme.com",
            customerPhone: "5550009999", dispatcherEmail: "dispatcher@routelo.app",
            notifyCustomer: false, lastLocation: nil,
            notes: "Handle with care. Simulator test load.", completedAt: nil
        )
        LoadStore.shared.upsert(testLoad)
        appState.login(as: testDriver)
    }
    #endif
}

// MARK: - Auth View (3 tabs: Sign In / Create Account / New Company)

private enum AuthTab { case signIn, createAccount, newCompany }

struct AuthView: View {
    @Binding var showDispatcherLogin: Bool
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var authManager: AuthManager
    @State private var tab: AuthTab = .signIn

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 28) {
                    VStack(spacing: 8) {
                        HStack {
                            Button(action: { showDispatcherLogin = false }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "chevron.left"); Text("Back")
                                }
                                .foregroundColor(.accentColor).font(.subheadline)
                            }
                            Spacer()
                        }
                        .padding(.horizontal)
                        RouteloLogo(size: 70)
                        Text("Dispatcher Portal").font(.subheadline).foregroundColor(.secondary)
                    }
                    .padding(.top, 20)

                    Picker("", selection: $tab) {
                        Text("Sign In").tag(AuthTab.signIn)
                        Text("Create\nAccount").tag(AuthTab.createAccount)
                        Text("New\nCompany").tag(AuthTab.newCompany)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)

                    switch tab {
                    case .signIn:        SignInForm(isDriverRole: false)
                    case .createAccount: CreateAccountForm()
                    case .newCompany:    NewCompanyForm()
                    }

                    Spacer(minLength: 40)
                }
            }
            .navigationBarHidden(true)
        }
    }
}

// MARK: - Sign In Form

struct SignInForm: View {
    var isDriverRole: Bool = false
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var authManager: AuthManager
    @State private var loginId = ""
    @State private var password = ""
    @State private var errorMsg: String? = nil
    @State private var showPassword = false
    private var isDisabled: Bool { loginId.isEmpty || password.isEmpty || authManager.isLoading }

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 14) {
                TextField("Email", text: $loginId)
                    .textFieldStyle(.roundedBorder).keyboardType(.emailAddress)
                    .autocapitalization(.none).autocorrectionDisabled().textContentType(.emailAddress)
                HStack {
                    Group {
                        if showPassword { TextField("Password", text: $password) }
                        else            { SecureField("Password", text: $password) }
                    }
                    .textContentType(.password)
                    Button(action: { showPassword.toggle() }) {
                        Image(systemName: showPassword ? "eye.slash" : "eye").foregroundColor(.secondary)
                    }
                }
                .textFieldStyle(.roundedBorder)
            }
            .padding(.horizontal)
            if let msg = errorMsg { Text(msg).font(.caption).foregroundColor(.red).padding(.horizontal) }
            Button(action: signIn) {
                if authManager.isLoading {
                    ProgressView().tint(.white).frame(maxWidth: .infinity).padding()
                        .background(Color.accentColor).cornerRadius(14)
                } else {
                    Text("Sign In").fontWeight(.semibold).frame(maxWidth: .infinity).padding()
                        .background(Color.accentColor).foregroundColor(.white).cornerRadius(14)
                }
            }
            .padding(.horizontal).disabled(isDisabled).opacity(isDisabled ? 0.5 : 1)
        }
    }

    private func signIn() {
        errorMsg = nil
        authManager.signIn(loginId: loginId, role: .dispatcher, password: password) { err in
            if let err = err { self.errorMsg = err }
            else if let account = self.authManager.currentAccount { self.appState.login(from: account) }
        }
    }
}

// MARK: - Create Account Form

struct CreateAccountForm: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var authManager: AuthManager
    @State private var name = "", email = "", phone = "", password = "", confirmPassword = ""
    @State private var selectedRole: UserRole = .driver
    @State private var errorMsg: String? = nil
    @State private var showPassword = false
    private var isDriver: Bool { selectedRole == .driver }
    private var isDisabled: Bool {
        name.isEmpty || password.isEmpty ||
        (isDriver && phone.isEmpty) || (!isDriver && email.isEmpty) || authManager.isLoading
    }

    var body: some View {
        VStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("I am a…").font(.headline).padding(.horizontal)
                Picker("Role", selection: $selectedRole) {
                    Text("🚛  Driver").tag(UserRole.driver)
                    Text("📋  Dispatcher").tag(UserRole.dispatcher)
                }
                .pickerStyle(.segmented).padding(.horizontal)
            }
            VStack(spacing: 14) {
                TextField("Full Name", text: $name).textFieldStyle(.roundedBorder).textContentType(.name)
                HStack {
                    TextField(isDriver ? "Phone Number (required)" : "Phone Number (optional)", text: $phone)
                        .textFieldStyle(.roundedBorder).keyboardType(.phonePad).textContentType(.telephoneNumber)
                    if isDriver { Image(systemName: "asterisk").font(.caption).foregroundColor(.red) }
                }
                HStack {
                    TextField(isDriver ? "Email (optional)" : "Email (required)", text: $email)
                        .textFieldStyle(.roundedBorder).keyboardType(.emailAddress)
                        .autocapitalization(.none).autocorrectionDisabled().textContentType(.emailAddress)
                    if !isDriver { Image(systemName: "asterisk").font(.caption).foregroundColor(.red) }
                }
                HStack {
                    Group {
                        if showPassword { TextField("Password (min. 6 chars)", text: $password) }
                        else            { SecureField("Password (min. 6 chars)", text: $password) }
                    }
                    .textContentType(.newPassword)
                    Button(action: { showPassword.toggle() }) {
                        Image(systemName: showPassword ? "eye.slash" : "eye").foregroundColor(.secondary)
                    }
                }
                .textFieldStyle(.roundedBorder)
                SecureField("Confirm Password", text: $confirmPassword)
                    .textFieldStyle(.roundedBorder).textContentType(.newPassword)
            }
            .padding(.horizontal)
            HStack(spacing: 4) {
                Image(systemName: "info.circle").foregroundColor(.secondary)
                Text(isDriver ? "Drivers sign in with their phone number."
                             : "Dispatchers sign in with their email address.")
                    .foregroundColor(.secondary)
            }
            .font(.caption).padding(.horizontal)
            if let msg = errorMsg { Text(msg).font(.caption).foregroundColor(.red).padding(.horizontal) }
            Button(action: createAccount) {
                if authManager.isLoading {
                    ProgressView().tint(.white).frame(maxWidth: .infinity).padding()
                        .background(Color.accentColor).cornerRadius(14)
                } else {
                    Text("Create Account").fontWeight(.semibold).frame(maxWidth: .infinity).padding()
                        .background(Color.accentColor).foregroundColor(.white).cornerRadius(14)
                }
            }
            .padding(.horizontal).disabled(isDisabled).opacity(isDisabled ? 0.5 : 1)
        }
    }

    private func createAccount() {
        errorMsg = nil
        guard password == confirmPassword else { errorMsg = "Passwords do not match."; return }
        if isDriver && phone.isEmpty  { errorMsg = "Phone number is required for drivers."; return }
        if !isDriver && email.isEmpty { errorMsg = "Email is required for dispatchers."; return }
        authManager.createAccount(name: name, email: email, phone: phone,
                                  password: password, role: selectedRole) { err in
            if let err = err { self.errorMsg = err }
            else if let account = self.authManager.currentAccount { self.appState.login(from: account) }
        }
    }
}

// MARK: - New Company Form

struct NewCompanyForm: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var authManager: AuthManager
    @State private var companyName  = ""
    @State private var adminName    = ""
    @State private var adminEmail   = ""
    @State private var password     = ""
    @State private var showPassword = false
    @State private var isLoading    = false
    @State private var errorMsg: String? = nil

    private var isDisabled: Bool {
        companyName.isEmpty || adminName.isEmpty || adminEmail.isEmpty ||
        password.count < 8 || isLoading
    }

    var body: some View {
        VStack(spacing: 20) {
            HStack(spacing: 10) {
                Image(systemName: "building.2.fill").foregroundColor(.accentColor)
                Text("Create a new company and become its admin dispatcher.")
                    .font(.caption).foregroundColor(.secondary)
            }
            .padding(12).background(Color.accentColor.opacity(0.08)).cornerRadius(10).padding(.horizontal)

            VStack(spacing: 14) {
                TextField("Company Name", text: $companyName)
                    .textFieldStyle(.roundedBorder).textContentType(.organizationName)
                TextField("Your Name", text: $adminName)
                    .textFieldStyle(.roundedBorder).textContentType(.name)
                TextField("Work Email", text: $adminEmail)
                    .textFieldStyle(.roundedBorder).keyboardType(.emailAddress)
                    .autocapitalization(.none).autocorrectionDisabled().textContentType(.emailAddress)
                HStack {
                    Group {
                        if showPassword { TextField("Password (min 8 chars)", text: $password) }
                        else            { SecureField("Password (min 8 chars)", text: $password) }
                    }
                    .textContentType(.newPassword)
                    Button(action: { showPassword.toggle() }) {
                        Image(systemName: showPassword ? "eye.slash" : "eye").foregroundColor(.secondary)
                    }
                }
                .textFieldStyle(.roundedBorder)
            }
            .padding(.horizontal)

            if let msg = errorMsg {
                Text(msg).font(.caption).foregroundColor(.red)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.08)).cornerRadius(8).padding(.horizontal)
            }

            Button(action: register) {
                if isLoading {
                    ProgressView().tint(.white).frame(maxWidth: .infinity).padding()
                        .background(Color.accentColor).cornerRadius(14)
                } else {
                    Text("Create Company & Sign In").fontWeight(.semibold)
                        .frame(maxWidth: .infinity).padding()
                        .background(Color.accentColor).foregroundColor(.white).cornerRadius(14)
                }
            }
            .padding(.horizontal).disabled(isDisabled).opacity(isDisabled ? 0.5 : 1)

            Text("A welcome email will be sent to your work address.\nActivate your subscription to start dispatching.")
                .font(.caption2).foregroundColor(.secondary).multilineTextAlignment(.center).padding(.horizontal)
        }
    }

    private func register() {
        errorMsg = nil
        isLoading = true
        guard let url = URL(string: "\(AWSConfig.baseURL)/companies/register") else {
            errorMsg = "Invalid server URL."; isLoading = false; return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 15
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "companyName": companyName.trimmingCharacters(in: .whitespaces),
            "adminName":   adminName.trimmingCharacters(in: .whitespaces),
            "adminEmail":  adminEmail.lowercased().trimmingCharacters(in: .whitespaces),
            "password":    password
        ])
        URLSession.shared.dataTask(with: req) { data, response, error in
            DispatchQueue.main.async {
                isLoading = false
                if let error = error { errorMsg = "Network error: \(error.localizedDescription)"; return }
                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    errorMsg = "Company registration failed."; return
                }
                if let e = json["error"] as? String { errorMsg = e; return }
                guard let token  = json["token"]                   as? String,
                      let user   = json["user"]                    as? [String: Any],
                      let email  = user["email"]                   as? String,
                      let name   = user["name"]                    as? String else {
                    errorMsg = "Company registration failed."; return
                }
                // Store JWT then sign in
                UserDefaults.standard.set(token, forKey: "cmp.aws.jwt")
                let account = UserAccount(email: email, name: name, phone: "",
                                          role: "dispatcher", passwordHash: "")
                authManager.currentAccount = account
                appState.login(from: account)
            }
        }.resume()
    }
}

#Preview {
    ContentView()
        .environmentObject(AppState.shared)
        .environmentObject(AuthManager())
}
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

    var body: some View {
        ZStack {
            Color(red: 0.06, green: 0.06, blue: 0.11).ignoresSafeArea()

            VStack(spacing: 32) {
                Spacer()

                RouteloLogo(size: 80)

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

                // ── DEBUG: simulator test helper ──────────────────────────
                #if DEBUG
                Button(action: injectTestLoad) {
                    Label("Load Test Data (Simulator)", systemImage: "hammer.fill")
                        .font(.caption).fontWeight(.semibold)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(Color.orange.opacity(0.15))
                        .foregroundColor(.orange)
                        .cornerRadius(10)
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.orange.opacity(0.4), lineWidth: 1))
                }
                .padding(.bottom, 8)
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

    // MARK: - Debug helper

    #if DEBUG
    private func injectTestLoad() {
        let testDriver = Driver(
            id: "test-driver-001",
            name: "Test Driver",
            phone: "5550001234",
            email: "testdriver@routelo.app",
            role: .driver
        )

        let testLoad = Load(
            id: "test-load-001",
            loadNumber: "CMP-TEST-001",
            description: "Test Load — Electronics",
            weight: 12000,
            pickupAddress: "123 Warehouse Blvd, Chicago, IL 60601",
            deliveryAddress: "456 Distribution Ave, Dallas, TX 75201",
            pickupDate: Date(),
            deliveryDate: Date().addingTimeInterval(86400),
            status: .assigned,
            assignedDriverId: testDriver.id,
            assignedDriverName: testDriver.name,
            assignedDriverEmail: testDriver.email,
            assignedDriverPhone: testDriver.phone,
            trackingToken: "test-token-abc123",
            customerName: "Acme Corp",
            customerEmail: "logistics@acme.com",
            customerPhone: "5550009999",
            dispatcherEmail: "dispatcher@routelo.app",
            notifyCustomer: false,
            lastLocation: nil,
            notes: "Handle with care. Simulator test load.",
            completedAt: nil
        )

        LoadStore.shared.upsert(testLoad)
        appState.login(as: testDriver)
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

    var body: some View {
        ZStack {
            Color(red: 0.06, green: 0.06, blue: 0.11).ignoresSafeArea()

            VStack(spacing: 32) {
                Spacer()

                RouteloLogo(size: 80)

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

                // ── DEBUG: simulator test helper ──────────────────────────
                #if DEBUG
                Button(action: injectTestLoad) {
                    Label("Load Test Data (Simulator)", systemImage: "hammer.fill")
                        .font(.caption).fontWeight(.semibold)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(Color.orange.opacity(0.15))
                        .foregroundColor(.orange)
                        .cornerRadius(10)
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.orange.opacity(0.4), lineWidth: 1))
                }
                .padding(.bottom, 8)
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

    // MARK: - Debug helper

    #if DEBUG
    private func injectTestLoad() {
        let testDriver = Driver(
            id: "test-driver-001",
            name: "Test Driver",
            phone: "5550001234",
            email: "testdriver@routelo.app",
            role: .driver
        )

        let testLoad = Load(
            id: "test-load-001",
            loadNumber: "CMP-TEST-001",
            description: "Test Load — Electronics",
            weight: 12000,
            pickupAddress: "123 Warehouse Blvd, Chicago, IL 60601",
            deliveryAddress: "456 Distribution Ave, Dallas, TX 75201",
            pickupDate: Date(),
            deliveryDate: Date().addingTimeInterval(86400),
            status: .assigned,
            assignedDriverId: testDriver.id,
            assignedDriverName: testDriver.name,
            assignedDriverEmail: testDriver.email,
            assignedDriverPhone: testDriver.phone,
            trackingToken: "test-token-abc123",
            customerName: "Acme Corp",
            customerEmail: "logistics@acme.com",
            customerPhone: "5550009999",
            dispatcherEmail: "dispatcher@routelo.app",
            notifyCustomer: false,
            lastLocation: nil,
            notes: "Handle with care. Simulator test load.",
            completedAt: nil
        )

        LoadStore.shared.upsert(testLoad)
        appState.login(as: testDriver)
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
