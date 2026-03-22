//
//  AuthManager.swift
//  CMP Tracking
//
//  Auth flow:
//    • Accounts are stored in BOTH the iOS Keychain (survives reinstall) and
//      SwiftData (fast local queries). On first launch after reinstall the
//      Keychain copy is used to re-seed SwiftData automatically.
//    • If AWSConfig.baseURL is set → register/login also syncs to AWS DynamoDB.
//    • Session (last-logged-in email) is stored in Keychain so the user
//      stays signed in after reinstall.
//

import Foundation
import SwiftData
import CryptoKit

// MARK: - Keychain keys
private enum KC {
    static let accounts = "cmp.accounts"
    static let session  = "cmp.session.email"
}

// Codable mirror used for Keychain serialisation
private struct StoredAccount: Codable {
    var email: String
    var name: String
    var phone: String
    var role: String
    var passwordHash: String
}

// MARK: - Auth Manager

@MainActor
class AuthManager: ObservableObject {

    @Published var currentAccount: UserAccount? = nil
    @Published var isLoggedIn: Bool = false
    @Published var authError: String? = nil
    @Published var isLoading: Bool = false

    var modelContext: ModelContext? = nil

    // MARK: - Password Hashing

    static func hash(_ password: String) -> String {
        let data   = Data(password.utf8)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Create Account

    func createAccount(name: String,
                       email: String,
                       phone: String,
                       password: String,
                       role: UserRole,
                       completion: ((String?) -> Void)? = nil) {
        guard password.count >= 6 else {
            let msg = "Password must be at least 6 characters."
            authError = msg; completion?(msg); return
        }
        let trimmedEmail = email.lowercased().trimmingCharacters(in: .whitespaces)

        if AWSManager.shared.isConfigured {
            isLoading = true
            AWSManager.shared.register(name: name, email: trimmedEmail, phone: phone,
                                       password: password, role: role.rawValue) { [weak self] result in
                guard let self else { return }
                self.isLoading = false
                switch result {
                case .success(let awsUser):
                    self.cacheLocally(awsUser: awsUser, password: password)
                    self.signInLocally(identifier: trimmedEmail)
                    completion?(nil)
                case .failure(let error):
                    let msg = error.localizedDescription
                    self.authError = msg; completion?(msg)
                }
            }
        } else {
            completion?(createLocalAccount(name: name, email: trimmedEmail,
                                           phone: phone, password: password, role: role))
        }
    }

    // MARK: - Sign In (phone for drivers, email for dispatchers) (phone for drivers, email for dispatchers)

    /// New unified sign-in. loginId = phone number for drivers, email for dispatchers.
    func signIn(loginId: String,
                role: UserRole,
                password: String,
                completion: ((String?) -> Void)? = nil) {
        let trimmed = loginId.trimmingCharacters(in: .whitespaces)

        if AWSManager.shared.isConfigured {
            // AWS always uses email — for drivers, pass phone as email field temporarily
            // TODO: update Lambda to support phone lookup
            isLoading = true
            AWSManager.shared.login(email: trimmed, password: password) { [weak self] result in
                guard let self else { return }
                self.isLoading = false
                switch result {
                case .success(let response):
                    self.cacheLocally(awsUser: response.user, password: password)
                    self.signInLocally(identifier: trimmed, role: role)
                    completion?(nil)
                case .failure(let error):
                    let msg = error.localizedDescription
                    self.authError = msg; completion?(msg)
                }
            }
        } else {
            completion?(signInLocal(loginId: trimmed, role: role, password: password))
        }
    }

    // Keep old email-only signature for AWS cache path
    func signIn(email: String, password: String, completion: ((String?) -> Void)? = nil) {
        signIn(loginId: email, role: .dispatcher, password: password, completion: completion)
    }

    // MARK: - Restore Session on App Launch

    func restoreSession() {
        reseedSwiftDataFromKeychain()

        // Session key stores the account's primary identifier (email or phone)
        let savedId = KeychainHelper.string(for: KC.session)
                   ?? UserDefaults.standard.string(forKey: KC.session)
        guard let savedId else { return }
        guard let ctx = modelContext else { return }

        // Try matching by email first, then phone
        let allAccounts = (try? ctx.fetch(FetchDescriptor<UserAccount>())) ?? []
        let account = allAccounts.first(where: {
            $0.email.lowercased() == savedId.lowercased() ||
            normalizePhone($0.phone) == normalizePhone(savedId)
        })
        if let account {
            currentAccount = account
            isLoggedIn     = true
        }
    }

    // MARK: - Sign Out

    func signOut() {
        AWSManager.shared.signOut()
        KeychainHelper.delete(KC.session)
        UserDefaults.standard.removeObject(forKey: KC.session)
        currentAccount = nil
        isLoggedIn     = false
    }

    // MARK: - Private: Keychain account store

    private func allKeychainAccounts() -> [StoredAccount] {
        guard let data = KeychainHelper.data(for: KC.accounts),
              let accounts = try? JSONDecoder().decode([StoredAccount].self, from: data)
        else { return [] }
        return accounts
    }

    private func saveKeychainAccount(_ account: StoredAccount) {
        var all = allKeychainAccounts()
        // Match by email OR phone to avoid duplicates
        if let idx = all.firstIndex(where: {
            (!account.email.isEmpty && $0.email == account.email) ||
            (!account.phone.isEmpty && normalizePhone($0.phone) == normalizePhone(account.phone))
        }) {
            all[idx] = account
        } else {
            all.append(account)
        }
        if let data = try? JSONEncoder().encode(all) {
            KeychainHelper.save(data, for: KC.accounts)
        }
    }

    /// Strips everything except digits from a phone number for comparison.
    private func normalizePhone(_ phone: String) -> String {
        phone.filter { $0.isNumber }
    }

    /// After a reinstall SwiftData is empty but Keychain still has accounts.
    private func reseedSwiftDataFromKeychain() {
        guard let ctx = modelContext else { return }
        let keychainAccounts = allKeychainAccounts()
        guard !keychainAccounts.isEmpty else { return }
        for stored in keychainAccounts {
            // Match by email or phone
            let all = (try? ctx.fetch(FetchDescriptor<UserAccount>())) ?? []
            let exists = all.contains {
                $0.email == stored.email ||
                (!stored.phone.isEmpty && normalizePhone($0.phone) == normalizePhone(stored.phone))
            }
            if !exists {
                ctx.insert(UserAccount(email: stored.email, name: stored.name,
                                       phone: stored.phone, role: stored.role,
                                       passwordHash: stored.passwordHash))
            }
        }
        try? ctx.save()
    }

    // MARK: - Private helpers

    private func cacheLocally(awsUser: AWSUser, password: String) {
        let stored = StoredAccount(email: awsUser.email, name: awsUser.name,
                                   phone: awsUser.phone, role: awsUser.role,
                                   passwordHash: AuthManager.hash(password))
        saveKeychainAccount(stored)
        guard let ctx = modelContext else { return }
        let email = awsUser.email
        let all = (try? ctx.fetch(FetchDescriptor<UserAccount>())) ?? []
        if let existing = all.first(where: { $0.email == email }) {
            existing.name = awsUser.name; existing.phone = awsUser.phone
            existing.role = awsUser.role
            existing.passwordHash = AuthManager.hash(password)
        } else {
            ctx.insert(UserAccount(email: email, name: awsUser.name, phone: awsUser.phone,
                                   role: awsUser.role, passwordHash: AuthManager.hash(password)))
        }
        try? ctx.save()
    }

    /// Find account by email or phone and mark session active.
    private func signInLocally(identifier: String, role: UserRole? = nil) {
        guard let ctx = modelContext else { return }
        let all = (try? ctx.fetch(FetchDescriptor<UserAccount>())) ?? []
        let account = all.first(where: {
            $0.email.lowercased() == identifier.lowercased() ||
            normalizePhone($0.phone) == normalizePhone(identifier)
        })
        guard let account else { return }
        currentAccount = account
        isLoggedIn     = true
        authError      = nil
        // Save the identifier used (phone or email) so restoreSession can find it
        let sessionId = identifier
        KeychainHelper.save(sessionId, for: KC.session)
        UserDefaults.standard.set(sessionId, forKey: KC.session)
    }

    // ── Local-only account creation (no AWS) ─────────────────────
    private func createLocalAccount(name: String, email: String, phone: String,
                                    password: String, role: UserRole) -> String? {
        guard let ctx = modelContext else { return "Database not ready." }
        let trimmedEmail = email.lowercased().trimmingCharacters(in: .whitespaces)
        let trimmedPhone = phone.trimmingCharacters(in: .whitespaces)
        let all = (try? ctx.fetch(FetchDescriptor<UserAccount>())) ?? []

        // Check duplicates by email (if provided) or phone (if driver)
        if !trimmedEmail.isEmpty && all.contains(where: { $0.email == trimmedEmail }) {
            return "An account with that email already exists."
        }
        if !trimmedPhone.isEmpty &&
            all.contains(where: { normalizePhone($0.phone) == normalizePhone(trimmedPhone) }) {
            return "An account with that phone number already exists."
        }

        let hash = AuthManager.hash(password)
        // For drivers without email, use phone as a synthetic email key
        let accountEmail = trimmedEmail.isEmpty ? "driver_\(normalizePhone(trimmedPhone))@cmp.local" : trimmedEmail
        let account = UserAccount(email: accountEmail, name: name, phone: trimmedPhone,
                                  role: role.rawValue, passwordHash: hash)
        ctx.insert(account)
        try? ctx.save()

        let stored = StoredAccount(email: accountEmail, name: name, phone: trimmedPhone,
                                   role: role.rawValue, passwordHash: hash)
        saveKeychainAccount(stored)
        signIn(account: account)
        return nil
    }

    // ── Local-only sign in by phone OR email ─────────────────────
    private func signInLocal(loginId: String, role: UserRole, password: String) -> String? {
        guard let ctx = modelContext else { return "Database not ready." }
        let all = (try? ctx.fetch(FetchDescriptor<UserAccount>())) ?? []

        // Match on email or phone, also filter by role to avoid ambiguity
        let account = all.first(where: {
            $0.role == role.rawValue && (
                $0.email.lowercased() == loginId.lowercased() ||
                normalizePhone($0.phone) == normalizePhone(loginId)
            )
        }) ?? all.first(where: {  // fallback: ignore role
            $0.email.lowercased() == loginId.lowercased() ||
            normalizePhone($0.phone) == normalizePhone(loginId)
        })

        guard let account else {
            let hint = role == .driver ? "phone number" : "email"
            return "No account found for that \(hint)."
        }
        guard account.passwordHash == AuthManager.hash(password) else {
            return "Incorrect password."
        }
        signIn(account: account)
        return nil
    }

    private func signIn(account: UserAccount) {
        currentAccount = account
        isLoggedIn     = true
        authError      = nil
        // Use phone as session id for drivers (no email), email for dispatchers
        let sessionId = account.role == UserRole.driver.rawValue && !account.phone.isEmpty
            ? account.phone
            : account.email
        KeychainHelper.save(sessionId, for: KC.session)
        UserDefaults.standard.set(sessionId, forKey: KC.session)
    }

}
