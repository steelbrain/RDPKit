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
        var query = baseQuery(for: key)
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
        let status = SecItemDelete(baseQuery(for: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainCredentialError.unexpectedStatus(status)
        }
    }

    private func baseQuery(for key: KeychainCredentialKey) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.account,
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
