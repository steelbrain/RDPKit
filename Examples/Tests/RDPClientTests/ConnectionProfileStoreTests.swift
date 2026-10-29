import Foundation
@testable import RDPClient
import Testing

private let storageKey = "connection-profiles.v1"

private func makeDefaults() throws -> UserDefaults {
    let suiteName = "RDPClientTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
}

private func writeElements(_ elements: [Any], to defaults: UserDefaults) throws {
    defaults.set(try JSONSerialization.data(withJSONObject: elements), forKey: storageKey)
}

private func appendElement(_ element: Any, to defaults: UserDefaults) throws {
    let data = try #require(defaults.data(forKey: storageKey))
    let elements = try #require(try JSONSerialization.jsonObject(with: data) as? [Any])
    try writeElements(elements + [element], to: defaults)
}

private func storedElements(in defaults: UserDefaults) throws -> [[String: Any]] {
    let data = try #require(defaults.data(forKey: storageKey))
    return try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
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
        graphicsCapabilityProfile: .avc420,
        clipboardSharingEnabled: true,
        audioPlaybackEnabled: false,
        rememberPassword: true,
        updatedAt: Date(timeIntervalSinceReferenceDate: 1000)
    )
}

@Test func aProfileWithMissingOrUnknownFieldsTakesTheDefaults() throws {
    let defaults = try makeDefaults()
    let id = UUID()
    try writeElements([
        [
            "id": id.uuidString,
            "host": "desktop.example",
            "username": "anees",
            // A graphics profile from a newer build, and a field of a type this build does not read.
            "graphicsCapabilityProfile": "av1",
            "timeoutSeconds": "soon",
        ] as [String: Any],
    ], to: defaults)

    let list = try ConnectionProfileStore(defaults: defaults).profiles()

    #expect(list.unreadableCount == 0)
    let loaded = try #require(list.profiles.first)
    #expect(loaded.id == id)
    #expect(loaded.host == "desktop.example")
    #expect(loaded.username == "anees")
    #expect(loaded.port == 3389)
    #expect(loaded.domain.isEmpty)
    #expect(loaded.desktopWidth == 1920)
    #expect(loaded.desktopHeight == 1080)
    #expect(loaded.timeoutSeconds == 10)
    #expect(loaded.graphicsCapabilityProfile == .automatic)
    #expect(loaded.clipboardSharingEnabled)
    #expect(loaded.audioPlaybackEnabled == false)
    #expect(loaded.rememberPassword == false)
    #expect(loaded.updatedAt == .distantPast)
}

@Test func anUnreadableProfileIsSkippedAndKeptWhenOthersAreSaved() throws {
    let defaults = try makeDefaults()
    let store = ConnectionProfileStore(defaults: defaults)
    let kept = profile(host: "kept.example")
    _ = try store.save(kept)
    let unreadable: [String: Any] = ["host": "no-id.example", "fromNewerBuild": [1, 2, 3]]
    try appendElement(unreadable, to: defaults)

    let list = try store.profiles()
    #expect(list.profiles == [kept])
    #expect(list.unreadableCount == 1)

    let added = profile(host: "added.example")
    #expect(try store.save(added).profiles.count == 2)
    #expect(try store.delete(id: kept.id).profiles == [added])

    let elements = try storedElements(in: defaults)
    #expect(elements.count == 2)
    #expect(elements.contains { NSDictionary(dictionary: $0).isEqual(to: unreadable) })
}

@Test func savingAProfileKeepsFieldsANewerBuildAdded() throws {
    let defaults = try makeDefaults()
    let id = UUID()
    try writeElements([
        [
            "id": id.uuidString,
            "host": "desktop.example",
            "username": "anees",
            "displayScale": 2,
        ] as [String: Any],
    ], to: defaults)
    let store = ConnectionProfileStore(defaults: defaults)

    var edited = try #require(try store.profiles().profiles.first)
    edited.desktopWidth = 2560
    _ = try store.save(edited)

    let element = try #require(try storedElements(in: defaults).first)
    #expect(element["displayScale"] as? Int == 2)
    #expect(element["desktopWidth"] as? Int == 2560)
    #expect(try store.profiles().profiles == [edited])
}

@Test func savingReplacesTheProfileWithTheSameIDOrIdentity() throws {
    let defaults = try makeDefaults()
    let store = ConnectionProfileStore(defaults: defaults)
    let original = profile(host: "desktop.example")
    _ = try store.save(original)

    var renamed = original
    renamed.desktopWidth = 2560
    #expect(try store.save(renamed).profiles == [renamed])

    // A new profile for the same host and account replaces the saved one.
    let sameIdentity = profile(host: "DESKTOP.example")
    #expect(try store.save(sameIdentity).profiles == [sameIdentity])
}

/// "LAB\anees" with no domain signs in as "anees" in LAB, under the same saved password.
@Test func savingTheDomainInTheUsernameReplacesTheProfileWithThatDomain() throws {
    let store = try ConnectionProfileStore(defaults: makeDefaults())
    var domainApart = profile(host: "desktop.example")
    domainApart.domain = "LAB"
    _ = try store.save(domainApart)

    var domainInUsername = profile(host: "desktop.example")
    domainInUsername.username = "LAB\\anees"
    #expect(try store.save(domainInUsername).profiles == [domainInUsername])
}

/// Profiles saved before identities matched by account name can be two for one account, under
/// one saved password: Delete Profile leaves it to the last of them.
@Test func aSavedPasswordIsSharedByEveryProfileForItsAccount() throws {
    let defaults = try makeDefaults()
    var domainApart = profile(host: "desktop.example")
    domainApart.domain = "LAB"
    var domainInUsername = profile(host: "Desktop.Example")
    domainInUsername.username = "LAB\\anees"
    let otherAccount = profile(host: "desktop.example")
    var noUsername = profile(host: "desktop.example")
    noUsername.username = ""
    var alsoNoUsername = noUsername
    alsoNoUsername.id = UUID()
    let encoder = JSONEncoder()
    try writeElements(
        [domainApart, domainInUsername, otherAccount, noUsername, alsoNoUsername].map {
            try JSONSerialization.jsonObject(with: encoder.encode($0))
        },
        to: defaults
    )
    let store = ConnectionProfileStore(defaults: defaults)

    let list = try store.profiles()
    #expect(list.profile(sharingSavedPasswordWith: domainApart) == domainInUsername)
    #expect(list.profile(sharingSavedPasswordWith: domainInUsername) == domainApart)
    #expect(list.profile(sharingSavedPasswordWith: otherAccount) == nil)
    // Without a username there is no saved password to share.
    #expect(list.profile(sharingSavedPasswordWith: noUsername) == nil)

    #expect(try store.delete(id: domainInUsername.id).profile(sharingSavedPasswordWith: domainApart) == nil)
}

@Test func storedDataThatIsNotAProfileListIsReportedAndNeverOverwritten() throws {
    let defaults = try makeDefaults()
    let corrupt = Data("{\"connections\": 3}".utf8)
    defaults.set(corrupt, forKey: storageKey)
    let store = ConnectionProfileStore(defaults: defaults)

    #expect(throws: ConnectionProfileStoreError.self) { try store.profiles() }
    #expect(throws: ConnectionProfileStoreError.self) { try store.save(profile(host: "desktop.example")) }
    #expect(throws: ConnectionProfileStoreError.self) { try store.delete(id: UUID()) }
    #expect(defaults.data(forKey: storageKey) == corrupt)
}

@Test func noStoredProfilesIsAnEmptyList() throws {
    let list = try ConnectionProfileStore(defaults: makeDefaults()).profiles()

    #expect(list == ConnectionProfileList())
}
