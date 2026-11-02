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

private func profile(host: String) -> ConnectionProfile {
    ConnectionProfile(
        id: UUID(),
        host: host,
        port: 3389,
        username: "anees",
        domain: "",
        desktopWidth: 1920,
        desktopHeight: 1080,
        hideCertificateWarnings: false,
        timeoutSeconds: 10,
        graphicsCapabilityProfile: .automatic,
        clipboardSharingEnabled: true,
        audioPlaybackEnabled: false,
        rememberPassword: true,
        updatedAt: Date()
    )
}

/// Saving a profile under another account, as after editing its username, takes it off its
/// earlier account as Delete Profile does: that account's password goes, under its current
/// name and its legacy one, unless another profile still uses the account, which then gets the
/// legacy-named one. Saved on its own account, it releases nothing.
@Test func savingAProfileUnderAnotherAccountReleasesItsEarlierPassword() throws {
    let typed = profile(host: "Desktop.Example")
    var renamed = typed
    renamed.username = "bob"
    let bobAccount = "bob@desktop.example:3389"
    let alone = ConnectionProfileList(profiles: [typed])
    let passwords = Passwords([currentAccount: "newer", legacyAccount: "older", bobAccount: "bob's"])

    let store = KeychainCredentialStore(passwords: passwords)
    // Before the save, the earlier account's password stays, for a save that fails.
    try store.movePasswordsOfProfilesReplaced(by: renamed, in: alone)
    #expect(passwords.saved == [currentAccount: "newer", legacyAccount: "older", bobAccount: "bob's"])
    #expect(try store.releaseSavedPasswords(saved: renamed, over: alone) == typed)
    #expect(passwords.saved == [bobAccount: "bob's"])

    let shared = ConnectionProfileList(profiles: [typed, profile(host: "desktop.example")])
    let sharedPasswords = Passwords([legacyAccount: "secret"])
    let sharedStore = KeychainCredentialStore(passwords: sharedPasswords)
    #expect(try sharedStore.releaseSavedPasswords(saved: renamed, over: shared) == nil)
    #expect(sharedPasswords.saved == [currentAccount: "secret"])

    var resized = typed
    resized.desktopWidth = 2560
    let kept = Passwords([legacyAccount: "secret"])
    #expect(try KeychainCredentialStore(passwords: kept).releaseSavedPasswords(saved: resized, over: alone) == nil)
    #expect(kept.saved == [legacyAccount: "secret"])
    #expect(passwords.reads + sharedPasswords.reads + kept.reads == 0)
}

/// A profile moved to an account another profile was saved for replaces that one, which leaves
/// the account to it: a password saved under the replaced one's legacy name, which the moved
/// profile never tries, moves to the account's name.
@Test func aProfileMovedOverAnotherForItsAccountKeepsItsLegacyPassword() throws {
    let replaced = profile(host: "Desktop.Example")
    let moved = profile(host: "laptop.example")
    var movedHere = moved
    movedHere.host = "desktop.example"
    let saved = ConnectionProfileList(profiles: [replaced, moved])
    let passwords = Passwords([legacyAccount: "secret"])

    let store = KeychainCredentialStore(passwords: passwords)
    try store.movePasswordsOfProfilesReplaced(by: movedHere, in: saved)
    #expect(passwords.saved == [currentAccount: "secret"])
    #expect(try store.releaseSavedPasswords(saved: movedHere, over: saved) == nil)
    #expect(passwords.saved == [currentAccount: "secret"])

    // With Remember off, the account keeps no password: the replaced profile's goes once the
    // moved one is saved, and none moves before.
    var forgetting = movedHere
    forgetting.rememberPassword = false
    let forgotten = Passwords([legacyAccount: "secret"])
    let forgettingStore = KeychainCredentialStore(passwords: forgotten)
    try forgettingStore.movePasswordsOfProfilesReplaced(by: forgetting, in: saved)
    #expect(forgotten.saved == [legacyAccount: "secret"])
    #expect(try forgettingStore.releaseSavedPasswords(saved: forgetting, over: saved) == nil)
    #expect(forgotten.saved.isEmpty)
    #expect(passwords.reads + forgotten.reads == 0)
}
