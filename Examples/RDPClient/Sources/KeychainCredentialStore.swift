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
        // A password saved by an earlier release is moved to the current name.
        for legacyAccount in key.identity.legacyCredentialAccountNames {
            if let password = try password(account: legacyAccount) {
                try savePassword(password, for: key)
                try deletePassword(account: legacyAccount)
                return password
            }
        }
        return nil
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

        // No kSecAttrAccessible: macOS applies it only in the data-protection keychain, and that
        // needs an application-identifier entitlement, which a SwiftPM executable lacks. The
        // login keychain these items go to ignores it.
        var query = baseQuery(for: key)
        query[kSecValueData as String] = passwordData
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainCredentialError.unexpectedStatus(addStatus)
        }
    }

    func deletePassword(for key: KeychainCredentialKey) throws {
        try deletePassword(account: key.account)
        for legacyAccount in key.identity.legacyCredentialAccountNames {
            try deletePassword(account: legacyAccount)
        }
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

/// Looks up the saved password for the account a connection form shows while the user edits
/// it: once the edits pause, and off the main actor, since a Keychain read blocks and can wait
/// for the user to allow access.
@MainActor
final class RememberedPasswordLookup {
    /// How long the host, port, username and domain must stay unchanged before a lookup.
    nonisolated static let typingDelay: Duration = .milliseconds(300)

    private let readPassword: @Sendable (KeychainCredentialKey) throws -> String?
    private var task: Task<Void, Never>?
    private var pendingKey: KeychainCredentialKey?

    convenience init(store: KeychainCredentialStore = KeychainCredentialStore()) {
        self.init { try store.password(for: $0) }
    }

    init(readPassword: @escaping @Sendable (KeychainCredentialKey) throws -> String?) {
        self.readPassword = readPassword
    }

    /// Reads `key`'s password after `delay` and passes the result to `apply`, unless `cancel()`
    /// or a lookup for another key comes first. A lookup for the key already pending leaves that
    /// one running.
    func lookUp(
        _ key: KeychainCredentialKey,
        after delay: Duration = typingDelay,
        apply: @escaping @MainActor (Result<String?, Error>) -> Void
    ) {
        guard key != pendingKey else {
            return
        }
        task?.cancel()
        pendingKey = key
        let readPassword = readPassword
        task = Task { [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            guard Task.isCancelled == false else {
                return
            }
            let result = await Task.detached(priority: .userInitiated) {
                Result { try readPassword(key) }
            }.value
            guard Task.isCancelled == false, let self else {
                return
            }
            self.task = nil
            self.pendingKey = nil
            apply(result)
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        pendingKey = nil
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
