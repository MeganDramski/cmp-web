//
//  KeychainHelper.swift
//  CMP Tracking
//
//  Thin wrapper around Security framework for reading/writing
//  small values (strings, Data) that survive app reinstall.
//  ✅ Data persists across reinstalls
//  ✅ Encrypted by the OS
//

import Foundation
import Security

enum KeychainHelper {

    // MARK: - Save

    @discardableResult
    static func save(_ value: String, for key: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        return save(data, for: key)
    }

    @discardableResult
    static func save(_ data: Data, for key: String) -> Bool {
        // Delete any existing item first
        delete(key)

        let query: [CFString: Any] = [
            kSecClass:           kSecClassGenericPassword,
            kSecAttrAccount:     key,
            kSecAttrService:     "com.cmpfreight.tracking",
            kSecValueData:       data,
            kSecAttrAccessible:  kSecAttrAccessibleAfterFirstUnlock,
        ]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    // MARK: - Read

    static func string(for key: String) -> String? {
        guard let data = data(for: key) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func data(for key: String) -> Data? {
        let query: [CFString: Any] = [
            kSecClass:            kSecClassGenericPassword,
            kSecAttrAccount:      key,
            kSecAttrService:      "com.cmpfreight.tracking",
            kSecReturnData:       true,
            kSecMatchLimit:       kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    // MARK: - Delete

    @discardableResult
    static func delete(_ key: String) -> Bool {
        let query: [CFString: Any] = [
            kSecClass:        kSecClassGenericPassword,
            kSecAttrAccount:  key,
            kSecAttrService:  "com.cmpfreight.tracking",
        ]
        return SecItemDelete(query as CFDictionary) == errSecSuccess
    }
}
