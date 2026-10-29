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

/// Connect asks for the account's password without a delay, and gets it from the lookup pending.
@MainActor
@Test func aLookupWithoutADelayEndsTheWaitOfTheOnePendingForItsKey() async throws {
    let reads = PasswordReads(["anees@desktop.example:3389": "secret"])
    let lookup = RememberedPasswordLookup { reads.read($0) }
    let anees = try key(username: "anees")

    let answer = await withCheckedContinuation { continuation in
        lookup.lookUp(anees, after: .seconds(5)) { continuation.resume(returning: (from: "the first lookup", $0)) }
        lookup.lookUp(anees, after: .zero) { continuation.resume(returning: (from: "the second lookup", $0)) }
    }

    #expect(answer.from == "the second lookup")
    #expect(try answer.1.get() == "secret")
    #expect(reads.readAccounts.count == 1)
}

/// A Keychain read that waits, as for the user to allow access, until `finish()`.
private final class SlowRead: @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private let (starts, start) = AsyncStream.makeStream(of: Void.self)
    private var reads = 0

    var count: Int {
        lock.withLock { reads }
    }

    func read() -> String? {
        lock.withLock { reads += 1 }
        start.yield()
        gate.wait()
        return "secret"
    }

    func started() async {
        var iterator = starts.makeAsyncIterator()
        _ = await iterator.next()
    }

    func finish() {
        gate.signal()
    }
}

@MainActor
@Test func aLookupWithoutADelayForTheKeyBeingReadWaitsForThatRead() async throws {
    let read = SlowRead()
    let lookup = RememberedPasswordLookup { _ in read.read() }
    let anees = try key(username: "anees")
    let (answers, answer) = AsyncStream.makeStream(of: Result<String?, Error>.self)

    lookup.lookUp(anees, after: .milliseconds(1)) { answer.yield($0) }
    await read.started()
    lookup.lookUp(anees, after: .zero) { _ in
        Issue.record("A second lookup for the key being read ran.")
    }
    read.finish()

    var iterator = answers.makeAsyncIterator()
    let result = try #require(await iterator.next())
    #expect(try result.get() == "secret")
    #expect(read.count == 1)
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

private func choice(_ password: String, remember: Bool) -> RememberedPasswordChoice {
    RememberedPasswordChoice(password: password, rememberPassword: remember)
}

/// Fills `savedPassword` into `current` for a request that began when the form showed `asked`.
private func answer(
    _ savedPassword: String?,
    asked: RememberedPasswordChoice,
    current: RememberedPasswordChoice? = nil,
    keepsEnteredPassword: Bool = false
) throws -> (choice: RememberedPasswordChoice, loaded: Bool) {
    let request = try RememberedPasswordRequest(
        key: key(username: "anees"),
        asked: asked,
        keepsEnteredPassword: keepsEnteredPassword
    )
    var filled = current ?? asked
    let loaded = request.fill(&filled, with: savedPassword)
    return (filled, loaded)
}

@Test func anAnswerFillsInTheSavedPasswordAsAnAnswerAtOnceWould() throws {
    // The account changed with another account's password in the form: the saved one replaces it.
    let loaded = try answer("secret", asked: choice("other", remember: false))
    #expect(loaded.choice == choice("secret", remember: true))
    #expect(loaded.loaded)

    // Nothing saved: an empty password unticks Remember, an entered one keeps it.
    #expect(try answer(nil, asked: choice("", remember: true)).choice == choice("", remember: false))
    #expect(try answer(nil, asked: choice("typed", remember: true)).choice == choice("typed", remember: true))

    // A session window keeps the draft's password and Remember choice, unless it has none.
    let draft = try answer("secret", asked: choice("newer", remember: false), keepsEnteredPassword: true)
    #expect(draft.choice == choice("newer", remember: false))
    #expect(draft.loaded == false)
    let emptyDraft = try answer("secret", asked: choice("", remember: false), keepsEnteredPassword: true)
    #expect(emptyDraft.choice == choice("secret", remember: true))
}

/// The user unticked Remember, or typed a password, after changing the account but before
/// Keychain answered: as with an answer at once, their change stands.
@Test func anAnswerKeepsWhatTheUserChangedWhileItWasOnItsWay() throws {
    let unticked = try answer("secret", asked: choice("other", remember: true), current: choice("other", remember: false))
    #expect(unticked.choice == choice("secret", remember: false))
    #expect(unticked.loaded)

    let typed = try answer("secret", asked: choice("", remember: false), current: choice("typed", remember: false))
    #expect(typed.choice == choice("typed", remember: true))
    #expect(typed.loaded == false)

    let ticked = try answer(nil, asked: choice("", remember: false), current: choice("", remember: true))
    #expect(ticked.choice == choice("", remember: true))
}
