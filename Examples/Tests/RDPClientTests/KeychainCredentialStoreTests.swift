import Foundation
@testable import RDPClient
import RDPKit
import Testing

/// Stands in for Keychain. `interruption` runs once, after the call it names, as another thread
/// could between two calls; the tests make every call from one thread.
private final class Passwords: KeychainPasswords, @unchecked Sendable {
    private(set) var saved: [String: String]
    private(set) var reads = 0
    var interruption: (afterCall: Int, run: () -> Void)?
    private var calls = 0

    init(_ saved: [String: String]) {
        self.saved = saved
    }

    func password(account: String) -> String? {
        defer { called() }
        reads += 1
        return saved[account]
    }

    func savePassword(_ password: String, account: String) {
        saved[account] = password
        called()
    }

    func rename(account: String, to newAccount: String) -> KeychainPasswordRename {
        defer { called() }
        guard let password = saved[account] else {
            return .notFound
        }
        guard saved[newAccount] == nil else {
            return .newNameTaken
        }
        saved[account] = nil
        saved[newAccount] = password
        return .renamed
    }

    func deletePassword(account: String) -> Bool {
        defer { called() }
        return saved.removeValue(forKey: account) != nil
    }

    private func called() {
        calls += 1
        if let interruption, interruption.afterCall == calls {
            self.interruption = nil
            interruption.run()
        }
    }
}

private let currentAccount = "anees@desktop.example:3389"
/// The name RDPKit 0.1 to 0.3 gave the account, with the host as typed.
private let legacyAccount = "anees@Desktop.Example:3389"

private func typedKey() throws -> KeychainCredentialKey {
    try #require(KeychainCredentialKey(host: "Desktop.Example", portText: "3389", username: "anees", domain: ""))
}

@Test func aPasswordSavedUnderItsLegacyNameMovesToTheCurrentName() throws {
    let passwords = Passwords([legacyAccount: "secret"])
    let store = KeychainCredentialStore(passwords: passwords)

    #expect(try store.password(for: typedKey()) == "secret")
    #expect(passwords.saved == [currentAccount: "secret"])
}

/// Delete Profile can delete the password while a session window's lookup moves it from its
/// legacy name. Wherever the deletion falls, the password stays deleted.
@Test func aPasswordDeletedWhileItMovesFromItsLegacyNameStaysDeleted() throws {
    let key = try typedKey()
    for call in 1 ... 10 {
        let passwords = Passwords([legacyAccount: "secret"])
        let store = KeychainCredentialStore(passwords: passwords)
        passwords.interruption = (call, { _ = try? store.deletePassword(for: key) })

        let password = try store.password(for: key)

        guard passwords.interruption == nil else {
            // The lookup made fewer calls.
            break
        }
        #expect(passwords.saved.isEmpty, "Deleted after call \(call)")
        #expect(password == nil || password == "secret")
    }
}

/// A password saved under the current name while the legacy one moves is the newer one.
@Test func aPasswordSavedWhileTheLegacyOneMovesStays() throws {
    let key = try typedKey()
    let passwords = Passwords([legacyAccount: "older"])
    let store = KeychainCredentialStore(passwords: passwords)
    // After the lookup found nothing under the current name, and read the legacy password.
    passwords.interruption = (2, { try? store.savePassword("newer", for: key) })

    #expect(try store.password(for: key) == "newer")
    #expect(passwords.saved == [currentAccount: "newer"])
}

/// Delete Profile learns from the deletion whether the profile had a saved password, under
/// either name, so it reads nothing beside a lookup that may be on its way.
@Test func deletingAPasswordTellsWhetherOneWasSavedWithoutReading() throws {
    let key = try typedKey()
    let savedPasswords = [
        [currentAccount: "secret"],
        [legacyAccount: "secret"],
        [currentAccount: "newer", legacyAccount: "older"],
        [:],
    ]
    for saved in savedPasswords {
        let passwords = Passwords(saved)

        #expect(try KeychainCredentialStore(passwords: passwords).deletePassword(for: key) == !saved.isEmpty)
        #expect(passwords.saved.isEmpty)
        #expect(passwords.reads == 0)
    }
}

/// Deleting a profile for "Desktop.Example" while one for "desktop.example" keeps the account:
/// that one never tries the deleted one's legacy name, so a password saved under it moves to the
/// account's name, or goes when that name has one already. One spelled alike tries it itself.
@Test func aLegacyPasswordOnlyTheDeletedProfileFindsMovesToTheAccountName() throws {
    let key = try typedKey()
    let spelledOtherwise = RDPConnectionIdentity(host: "desktop.example", username: "anees")
    let spelledAlike = RDPConnectionIdentity(host: "Desktop.Example", username: "anees")
    let cases: [(saved: [String: String], keptBy: RDPConnectionIdentity, left: [String: String])] = [
        ([legacyAccount: "secret"], spelledOtherwise, [currentAccount: "secret"]),
        ([legacyAccount: "older", currentAccount: "newer"], spelledOtherwise, [currentAccount: "newer"]),
        ([currentAccount: "secret"], spelledOtherwise, [currentAccount: "secret"]),
        ([legacyAccount: "secret"], spelledAlike, [legacyAccount: "secret"]),
    ]
    for (saved, keptBy, left) in cases {
        let passwords = Passwords(saved)

        try KeychainCredentialStore(passwords: passwords).moveLegacyPasswords(for: key, keptBy: [keptBy])

        #expect(passwords.saved == left)
        #expect(passwords.reads == 0)
    }
}
