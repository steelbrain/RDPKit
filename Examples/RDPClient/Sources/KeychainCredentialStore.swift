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
    private let passwords: any KeychainPasswords

    init(passwords: any KeychainPasswords = LoginKeychainPasswords(service: "com.steelbrain.rdpclient.credentials")) {
        self.passwords = passwords
    }

    func password(for key: KeychainCredentialKey) throws -> String? {
        if let password = try passwords.password(account: key.account) {
            return password
        }
        // A password saved by an earlier release moves to the current name. It is renamed, in
        // one step, rather than saved again, so one deleted meanwhile, as by Delete Profile in
        // another window, stays deleted.
        for legacyAccount in key.identity.legacyCredentialAccountNames {
            guard let password = try passwords.password(account: legacyAccount) else {
                continue
            }
            switch try passwords.rename(account: legacyAccount, to: key.account) {
            case .renamed:
                return password
            case .notFound:
                // Deleted, or moved by another lookup, meanwhile.
                return try passwords.password(account: key.account)
            case .newNameTaken:
                // A password saved under the current name meanwhile is the newer one.
                try passwords.deletePassword(account: legacyAccount)
                return try passwords.password(account: key.account)
            }
        }
        return nil
    }

    func savePassword(_ password: String, for key: KeychainCredentialKey) throws {
        try passwords.savePassword(password, account: key.account)
    }

    func deletePassword(for key: KeychainCredentialKey) throws {
        try passwords.deletePassword(account: key.account)
        for legacyAccount in key.identity.legacyCredentialAccountNames {
            try passwords.deletePassword(account: legacyAccount)
        }
    }
}

/// The passwords Keychain keeps under one service, by account. Tests stand in for Keychain with
/// their own.
protocol KeychainPasswords: Sendable {
    func password(account: String) throws -> String?
    /// Replaces the password saved under `account`, or saves one.
    func savePassword(_ password: String, account: String) throws
    /// Moves the password saved under `account` to `newAccount`, in one step.
    func rename(account: String, to newAccount: String) throws -> KeychainPasswordRename
    /// Deletes the password saved under `account`, if there is one.
    func deletePassword(account: String) throws
}

enum KeychainPasswordRename {
    case renamed
    /// Nothing is saved under the account.
    case notFound
    /// A password is already saved under the new account.
    case newNameTaken
}

/// Generic passwords in the login keychain.
struct LoginKeychainPasswords: KeychainPasswords {
    let service: String

    func password(account: String) throws -> String? {
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

    func savePassword(_ password: String, account: String) throws {
        let passwordData = Data(password.utf8)
        let attributes: [String: Any] = [
            kSecValueData as String: passwordData,
        ]
        let updateStatus = SecItemUpdate(baseQuery(account: account) as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainCredentialError.unexpectedStatus(updateStatus)
        }

        // No kSecAttrAccessible: macOS applies it only in the data-protection keychain, and that
        // needs an application-identifier entitlement, which a SwiftPM executable lacks. The
        // login keychain these items go to ignores it.
        var query = baseQuery(account: account)
        query[kSecValueData as String] = passwordData
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainCredentialError.unexpectedStatus(addStatus)
        }
    }

    func rename(account: String, to newAccount: String) throws -> KeychainPasswordRename {
        let attributes: [String: Any] = [
            kSecAttrAccount as String: newAccount,
        ]
        let status = SecItemUpdate(baseQuery(account: account) as CFDictionary, attributes as CFDictionary)
        switch status {
        case errSecSuccess:
            return .renamed
        case errSecItemNotFound:
            return .notFound
        case errSecDuplicateItem:
            return .newNameTaken
        default:
            throw KeychainCredentialError.unexpectedStatus(status)
        }
    }

    func deletePassword(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainCredentialError.unexpectedStatus(status)
        }
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
    /// Whether the pending lookup still waits out its delay. Once it reads, nothing stops the read.
    private var isWaiting = false

    convenience init(store: KeychainCredentialStore = KeychainCredentialStore()) {
        self.init { try store.password(for: $0) }
    }

    init(readPassword: @escaping @Sendable (KeychainCredentialKey) throws -> String?) {
        self.readPassword = readPassword
    }

    /// Reads `key`'s password after `delay` and passes the result to `apply`, unless `cancel()`
    /// or a lookup for another key comes first. A lookup for the key already pending leaves that
    /// one running, unless that one still waits out its delay and this one has none: this one
    /// then replaces it. Either way Keychain is read once.
    func lookUp(
        _ key: KeychainCredentialKey,
        after delay: Duration = typingDelay,
        apply: @escaping @MainActor (Result<String?, Error>) -> Void
    ) {
        guard key != pendingKey || (isWaiting && delay == .zero) else {
            return
        }
        task?.cancel()
        pendingKey = key
        isWaiting = delay > .zero
        let readPassword = readPassword
        task = Task { [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            guard Task.isCancelled == false else {
                return
            }
            self?.isWaiting = false
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
        isWaiting = false
    }
}

/// A connection form's password and its Remember choice.
struct RememberedPasswordChoice: Equatable {
    var password: String
    var rememberPassword: Bool
}

/// A connection form's wait for Keychain's answer about its account.
struct RememberedPasswordRequest: Equatable {
    let key: KeychainCredentialKey
    /// The form's choice when its account changed to `key`.
    let asked: RememberedPasswordChoice
    /// Keeps the password the form had then, and its Remember choice, over the saved one.
    let keepsEnteredPassword: Bool

    /// Fills Keychain's answer into `choice`, the form's choice now, and returns whether it took
    /// the saved password. A saved password replaces the form's and ticks Remember; none unticks
    /// Remember for an empty password. What the user changed since the account did stays, as if
    /// Keychain had answered at once.
    func fill(_ choice: inout RememberedPasswordChoice, with savedPassword: String?) -> Bool {
        let keepsAskedPassword = keepsEnteredPassword && !asked.password.isEmpty
        let keepsPassword = keepsAskedPassword || choice.password != asked.password
        let keepsRemember = keepsAskedPassword || choice.rememberPassword != asked.rememberPassword
        guard let savedPassword else {
            if choice.password.isEmpty, !keepsRemember {
                choice.rememberPassword = false
            }
            return false
        }
        if !keepsRemember {
            choice.rememberPassword = true
        }
        guard !keepsPassword else {
            return false
        }
        choice.password = savedPassword
        return true
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
