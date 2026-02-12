import Foundation
import Security
import CryptoKit

// Manages SSH keys and credentials in the iOS Keychain
final class KeychainService {

    static let shared = KeychainService()

    private let servicePrefix = "com.hoshi.ssh"

    private init() {}

    // MARK: - Password Storage

    // Store a password for a server in the Keychain
    func storePassword(_ password: String, forServer serverID: UUID) throws {
        let account = "password-\(serverID.uuidString)"
        guard let data = password.data(using: .utf8) else {
            throw SSHConnectionError.keychainError(reason: "Failed to encode password")
        }

        // Delete any existing entry first
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: servicePrefix,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        // Add the new entry
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: servicePrefix,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw SSHConnectionError.keychainError(reason: "Failed to store password (status: \(status))")
        }
    }

    // Retrieve a password for a server from the Keychain
    func retrievePassword(forServer serverID: UUID) throws -> String? {
        let account = "password-\(serverID.uuidString)"

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: servicePrefix,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return nil
        }

        guard status == errSecSuccess, let data = result as? Data,
              let password = String(data: data, encoding: .utf8) else {
            throw SSHConnectionError.keychainError(reason: "Failed to retrieve password (status: \(status))")
        }

        return password
    }

    // Delete a password for a server from the Keychain
    func deletePassword(forServer serverID: UUID) {
        let account = "password-\(serverID.uuidString)"

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: servicePrefix,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - SSH Key Storage

    // Store an SSH private key in the Keychain
    func storePrivateKey(_ keyData: Data, withTag tag: String) throws {
        let account = "sshkey-\(tag)"

        // Delete existing entry
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: servicePrefix,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        // Store the key
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: servicePrefix,
            kSecAttrAccount as String: account,
            kSecValueData as String: keyData,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw SSHConnectionError.keychainError(reason: "Failed to store SSH key (status: \(status))")
        }
    }

    // Retrieve an SSH private key from the Keychain
    func retrievePrivateKey(withTag tag: String) throws -> Data? {
        let account = "sshkey-\(tag)"

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: servicePrefix,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return nil
        }

        guard status == errSecSuccess, let data = result as? Data else {
            throw SSHConnectionError.keychainError(reason: "Failed to retrieve SSH key (status: \(status))")
        }

        return data
    }

    // Delete an SSH key from the Keychain
    func deletePrivateKey(withTag tag: String) {
        let account = "sshkey-\(tag)"

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: servicePrefix,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // List all stored SSH key tags
    func listKeyTags() -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: servicePrefix,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            return []
        }

        return items.compactMap { item in
            guard let account = item[kSecAttrAccount as String] as? String,
                  account.hasPrefix("sshkey-") else { return nil }
            return String(account.dropFirst("sshkey-".count))
        }
    }
}
