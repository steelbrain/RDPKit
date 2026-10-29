import Foundation
@testable import RDPClient
import Testing

/// Stands in for Keychain, and records the accounts a lookup read.
private final class PasswordReads: @unchecked Sendable {
    private let lock = NSLock()
    private let passwords: [String: String]
    private var accounts: [String] = []

    init(_ passwords: [String: String] = [:]) {
        self.passwords = passwords
    }

    var readAccounts: [String] {
        lock.withLock { accounts }
    }

    func read(_ key: KeychainCredentialKey) -> String? {
        lock.withLock { accounts.append(key.account) }
        return passwords[key.account]
    }
}

private func key(username: String) throws -> KeychainCredentialKey {
    try #require(KeychainCredentialKey(host: "desktop.example", portText: "3389", username: username, domain: ""))
}

@MainActor
@Test func aLookupReplacedBeforeItsDelayEndsNeverReadsKeychain() async throws {
    let reads = PasswordReads(["anees@desktop.example:3389": "secret"])
    let lookup = RememberedPasswordLookup { reads.read($0) }
    let partial = try key(username: "an")
    let complete = try key(username: "anees")

    let result = await withCheckedContinuation { continuation in
        lookup.lookUp(partial, after: .seconds(60)) { _ in
            Issue.record("A replaced lookup delivered its result.")
        }
        lookup.lookUp(complete, after: .zero) { continuation.resume(returning: $0) }
    }

    #expect(try result.get() == "secret")
    #expect(reads.readAccounts == ["anees@desktop.example:3389"])
}

@MainActor
@Test func aLookupForTheKeyAlreadyPendingLeavesThatOneRunning() async throws {
    let reads = PasswordReads()
    let lookup = RememberedPasswordLookup { reads.read($0) }
    let anees = try key(username: "anees")

    let result = await withCheckedContinuation { continuation in
        lookup.lookUp(anees, after: .zero) { continuation.resume(returning: $0) }
        lookup.lookUp(anees, after: .zero) { _ in
            Issue.record("A second lookup for the pending key ran.")
        }
    }

    #expect(try result.get() == nil)
    #expect(reads.readAccounts.count == 1)
}

@MainActor
@Test func aCancelledLookupDeliversNothing() async throws {
    let reads = PasswordReads()
    let lookup = RememberedPasswordLookup { reads.read($0) }
    let anees = try key(username: "anees")

    lookup.lookUp(anees, after: .zero) { _ in
        Issue.record("A cancelled lookup delivered its result.")
    }
    lookup.cancel()
    // The same key can be looked up again afterwards.
    let result = await withCheckedContinuation { continuation in
        lookup.lookUp(anees, after: .zero) { continuation.resume(returning: $0) }
    }

    #expect(try result.get() == nil)
    #expect(reads.readAccounts.count == 1)
}
