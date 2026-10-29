import Foundation
import RDPKit
import Security

struct KeychainCredentialKey: Equatable, Sendable {
    let identity: RDPConnectionIdentity

    init?(identity: RDPConnectionIdentity) {
        guard identity.credentialAccountName != nil else {
            return nil
        }
        self.identity = identity
    }

    /// The key for the connection form's fields, or nil when the target or username is incomplete.
    init?(host: String, portText: String, username: String, domain: String) {
        guard let target = try? RDPConnectionTarget(host: host, portText: portText) else {
            return nil
        }
        self.init(identity: RDPConnectionIdentity(
            host: target.host,
            port: target.port,
            username: username,
            domain: domain
        ))
    }

    var account: String {
        guard let account = identity.credentialAccountName else {
            preconditionFailure("KeychainCredentialKey requires a credential account identity.")
        }
        return account
    }
}

struct KeychainCredentialStore: Sendable {
    private let service = "com.steelbrain.rdpclient.credentials"

    func password(for key: KeychainCredentialKey) throws -> String? {
        if let password = try password(account: key.account) {
            return password
        }
        // Accounts once kept the host's case; adopt one saved that way under the current name.
        let usernamePrefix = (key.identity.qualifiedUsername ?? "") + "@"
        guard let legacyAccount = try accounts().first(where: {
            $0 != key.account && $0.hasPrefix(usernamePrefix) && $0.caseInsensitiveCompare(key.account) == .orderedSame
        }),
            let password = try password(account: legacyAccount)
        else {
            return nil
        }
        try savePassword(password, for: key)
        try deletePassword(account: legacyAccount)
        return password
    }

    func savePassword(_ password: String, for key: KeychainCredentialKey) throws {
        let passwordData = Data(password.utf8)
        let attributes: [String: Any] = [
            kSecValueData as String: passwordData,
        ]
        let updateStatus = SecItemUpdate(baseQuery(for: key) as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainCredentialError.unexpectedStatus(updateStatus)
        }

        var query = baseQuery(for: key)
        query[kSecValueData as String] = passwordData
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainCredentialError.unexpectedStatus(addStatus)
        }
    }

    func deletePassword(for key: KeychainCredentialKey) throws {
        try deletePassword(account: key.account)
    }

    private func password(account: String) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainCredentialError.unexpectedStatus(status)
        }
        guard let data = result as? Data,
              let password = String(data: data, encoding: .utf8)
        else {
            throw KeychainCredentialError.invalidPasswordData
        }
        return password
    }

    private func deletePassword(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainCredentialError.unexpectedStatus(status)
        }
    }

    /// The accounts this app has saved passwords under.
    private func accounts() throws -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return []
        }
        guard status == errSecSuccess else {
            throw KeychainCredentialError.unexpectedStatus(status)
        }
        return (result as? [[String: Any]] ?? []).compactMap { $0[kSecAttrAccount as String] as? String }
    }

    private func baseQuery(for key: KeychainCredentialKey) -> [String: Any] {
        baseQuery(account: key.account)
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

enum KeychainCredentialError: Error, CustomStringConvertible {
    case invalidPasswordData
    case unexpectedStatus(OSStatus)

    var description: String {
        switch self {
        case .invalidPasswordData:
            "Keychain password data was not valid UTF-8."
        case let .unexpectedStatus(status):
            "Keychain returned OSStatus \(status)."
        }
    }
}

enum CredentialPersistenceRequest: Sendable {
    case save(key: KeychainCredentialKey, password: String)
    case delete(key: KeychainCredentialKey)
}

enum CredentialPersistenceResult: Sendable {
    case saved
    case deleted
}

func persistCredentialsIfNeeded(
    _ request: CredentialPersistenceRequest?,
    store: KeychainCredentialStore
) -> Result<CredentialPersistenceResult, Error>? {
    guard let request else {
        return nil
    }

    do {
        switch request {
        case let .save(key, password):
            try store.savePassword(password, for: key)
            return .success(.saved)
        case let .delete(key):
            try store.deletePassword(for: key)
            return .success(.deleted)
        }
    } catch {
        return .failure(error)
    }
}
