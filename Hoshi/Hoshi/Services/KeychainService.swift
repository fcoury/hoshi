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
        let deleteStatus = SecItemDelete(deleteQuery as CFDictionary)
        guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
            throw SSHConnectionError.keychainError(
                reason: "Failed to replace password (status: \(deleteStatus))"
            )
        }

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
    func deletePassword(forServer serverID: UUID) throws {
        let account = "password-\(serverID.uuidString)"

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: servicePrefix,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SSHConnectionError.keychainError(
                reason: "Failed to delete password (status: \(status))"
            )
        }
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
        let deleteStatus = SecItemDelete(deleteQuery as CFDictionary)
        guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
            throw SSHConnectionError.keychainError(
                reason: "Failed to replace SSH key (status: \(deleteStatus))"
            )
        }

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
    func deletePrivateKey(withTag tag: String) throws {
        let account = "sshkey-\(tag)"

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: servicePrefix,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SSHConnectionError.keychainError(
                reason: "Failed to delete SSH key (status: \(status))"
            )
        }
    }

    // MARK: - Known SSH Hosts

    // Store a trusted host key without silently replacing an existing pin.
    func storeKnownHostKey(
        _ publicKey: String,
        hostname: String,
        port: Int,
        algorithm: String
    ) throws {
        let account = knownHostAccount(hostname: hostname, port: port, algorithm: algorithm)
        guard let data = publicKey.data(using: .utf8) else {
            throw SSHConnectionError.keychainError(reason: "Failed to encode SSH host key")
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: servicePrefix,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let existingKey = try retrieveKnownHostKey(
                hostname: hostname,
                port: port,
                algorithm: algorithm
            )
            guard existingKey == publicKey else {
                throw SSHConnectionError.keychainError(
                    reason: "A different SSH host key is already trusted for \(hostname):\(port)"
                )
            }
            return
        }

        guard status == errSecSuccess else {
            throw SSHConnectionError.keychainError(
                reason: "Failed to store SSH host key (status: \(status))"
            )
        }
    }

    // Retrieve the trusted host key for a host, port, and negotiated algorithm.
    func retrieveKnownHostKey(hostname: String, port: Int, algorithm: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: servicePrefix,
            kSecAttrAccount as String: knownHostAccount(
                hostname: hostname,
                port: port,
                algorithm: algorithm
            ),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }

        guard status == errSecSuccess,
              let data = result as? Data,
              let publicKey = String(data: data, encoding: .utf8) else {
            throw SSHConnectionError.keychainError(
                reason: "Failed to retrieve SSH host key (status: \(status))"
            )
        }

        return publicKey
    }

    // Remove one trusted host key without affecting other servers or algorithms.
    func deleteKnownHostKey(hostname: String, port: Int, algorithm: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: servicePrefix,
            kSecAttrAccount as String: knownHostAccount(
                hostname: hostname,
                port: port,
                algorithm: algorithm
            ),
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SSHConnectionError.keychainError(
                reason: "Failed to delete SSH host key (status: \(status))"
            )
        }
    }

    private func knownHostAccount(hostname: String, port: Int, algorithm: String) -> String {
        let normalizedHostname = hostname.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "hostkey-\(normalizedHostname):\(port):\(algorithm)"
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
