import Foundation
import RDPKit

struct ConnectionProfile: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var host: String
    var port: UInt16
    var username: String
    var domain: String
    var desktopWidth: UInt16
    var desktopHeight: UInt16
    var hideCertificateWarnings: Bool
    var timeoutSeconds: Int
    var graphicsCapabilityProfile: RDPGraphicsCapabilityProfile
    var clipboardSharingEnabled: Bool
    var audioPlaybackEnabled: Bool
    var rememberPassword: Bool
    var updatedAt: Date

    var identity: RDPConnectionIdentity {
        RDPConnectionIdentity(
            host: host,
            port: port,
            username: username,
            domain: domain
        )
    }

    var displayName: String {
        identity.displayName
    }

    func hasSameIdentity(as other: ConnectionProfile) -> Bool {
        identity.hasSameConnectionIdentity(as: other.identity)
    }
}

extension ConnectionProfile {
    /// Decodes profiles other RDPClient builds wrote, older or newer: a field that is missing,
    /// or that this build cannot read, such as a graphics profile it does not know, takes the
    /// value a new connection starts with. Only the ID and host are required.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, default defaultValue: T) -> T {
            (try? container.decodeIfPresent(T.self, forKey: key)) ?? defaultValue
        }
        id = try container.decode(UUID.self, forKey: .id)
        host = try container.decode(String.self, forKey: .host)
        port = value(.port, default: 3389)
        username = value(.username, default: "")
        domain = value(.domain, default: "")
        desktopWidth = value(.desktopWidth, default: 1920)
        desktopHeight = value(.desktopHeight, default: 1080)
        hideCertificateWarnings = value(.hideCertificateWarnings, default: false)
        timeoutSeconds = value(.timeoutSeconds, default: 10)
        graphicsCapabilityProfile = value(.graphicsCapabilityProfile, default: .automatic)
        clipboardSharingEnabled = value(.clipboardSharingEnabled, default: true)
        audioPlaybackEnabled = value(.audioPlaybackEnabled, default: false)
        rememberPassword = value(.rememberPassword, default: false)
        updatedAt = value(.updatedAt, default: .distantPast)
    }
}

struct ConnectionProfileList: Equatable {
    /// The profiles this build can read, most recently updated first.
    var profiles: [ConnectionProfile] = []
    /// Stored profiles it cannot read, such as ones a newer build wrote. They stay stored as
    /// they are.
    var unreadableCount = 0

    /// The other profiles for `profile`'s account on the same server, which share its saved
    /// password: those with the same `credentialAccountName`. Saving merges such profiles, but
    /// ones saved by earlier builds can be two.
    func profiles(sharingSavedPasswordWith profile: ConnectionProfile) -> [ConnectionProfile] {
        guard let account = profile.identity.credentialAccountName else {
            return []
        }
        return profiles.filter { $0.id != profile.id && $0.identity.credentialAccountName == account }
    }

    /// The saved profile with `profile`'s ID, when it is for another account: saving `profile`
    /// takes that profile off its account, as deleting it would.
    func profile(movedOffItsAccountBy profile: ConnectionProfile) -> ConnectionProfile? {
        guard let saved = profiles.first(where: { $0.id == profile.id }),
              saved.identity.credentialAccountName != profile.identity.credentialAccountName
        else {
            return nil
        }
        return saved
    }

    /// The profiles saving `profile` replaces: when it moves `profile` off its account, the
    /// others saved for the account it moves to, so one account keeps one profile.
    func profiles(replacedBy profile: ConnectionProfile) -> [ConnectionProfile] {
        guard self.profile(movedOffItsAccountBy: profile) != nil else {
            return []
        }
        return profiles.filter { $0.id != profile.id && $0.hasSameIdentity(as: profile) }
    }
}

extension KeychainCredentialStore {
    /// Takes `profile` off its account, as it is deleted or saved under another one. The saved
    /// password goes with the last profile for its account, so it stays while `sharingProfiles`
    /// use that account. Returns whether a password was deleted.
    func releaseSavedPassword(of profile: ConnectionProfile, sharingProfiles: [ConnectionProfile]) throws -> Bool {
        guard let key = KeychainCredentialKey(identity: profile.identity) else {
            return false
        }
        guard sharingProfiles.isEmpty else {
            // One saved under this profile's earlier name, which the others may spell
            // otherwise and never find, moves to the account's name.
            try moveLegacyPasswords(for: key, keptBy: sharingProfiles.map(\.identity))
            return false
        }
        // Deleting tells whether there was one, so Keychain is not read first.
        return try deletePassword(for: key)
    }

    /// Before `profile` is saved over `savedProfiles` with Remember on: a password the profiles
    /// it replaces saved under a legacy name, which `profile` never tries, moves to the
    /// account's name, where saving `profile`'s password replaces it. Their lookups read that
    /// name first, so should the save fail, they keep their password.
    func movePasswordsOfProfilesReplaced(
        by profile: ConnectionProfile,
        in savedProfiles: ConnectionProfileList
    ) throws {
        guard profile.rememberPassword else {
            return
        }
        for replaced in savedProfiles.profiles(replacedBy: profile) {
            _ = try releaseSavedPassword(of: replaced, sharingProfiles: [profile])
        }
    }

    /// Once `profile` is saved over `savedProfiles`, takes saved passwords off the accounts the
    /// save took profiles off, as Delete Profile does: the one `profile` moved off, and, with
    /// Remember off, the profiles' it replaced, whose account `profile` keeps without one. Only
    /// after the save, so that a save that fails leaves every password. Returns the saved
    /// `profile` when its earlier account's password was deleted.
    func releaseSavedPasswords(
        saved profile: ConnectionProfile,
        over savedProfiles: ConnectionProfileList
    ) throws -> ConnectionProfile? {
        if !profile.rememberPassword {
            for replaced in savedProfiles.profiles(replacedBy: profile) {
                _ = try releaseSavedPassword(of: replaced, sharingProfiles: [])
            }
        }
        guard let previous = savedProfiles.profile(movedOffItsAccountBy: profile),
              try releaseSavedPassword(
                  of: previous,
                  sharingProfiles: savedProfiles.profiles(sharingSavedPasswordWith: previous)
              )
        else {
            return nil
        }
        return previous
    }
}

enum ConnectionProfileStoreError: Error, CustomStringConvertible {
    case unreadableProfiles

    var description: String {
        switch self {
        case .unreadableProfiles:
            "Saved connections could not be read. RDPClient leaves them unchanged, so it cannot save or delete one."
        }
    }
}

/// Keeps profiles in UserDefaults as a JSON array. Each element is read on its own, and written
/// back as it was stored unless that profile is saved or deleted, so one this build cannot read,
/// and fields it does not know, survive.
struct ConnectionProfileStore {
    private let defaults: UserDefaults
    private let storageKey = "connection-profiles.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Throws when the stored data is not a JSON array; nothing is written over it then.
    func profiles() throws -> ConnectionProfileList {
        list(try storedProfiles())
    }

    func save(_ profile: ConnectionProfile) throws -> ConnectionProfileList {
        var stored = try storedProfiles()
        // One account on a server keeps one profile: one moved to another's account replaces
        // those saved for it.
        let replacedIDs = Set(list(stored).profiles(replacedBy: profile).map(\.id))
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(profile))
        guard var element = encoded as? [String: Any] else {
            preconditionFailure("A ConnectionProfile encodes as a JSON object.")
        }
        let index = stored.firstIndex { $0.profile?.id == profile.id }
            ?? stored.firstIndex { $0.profile?.hasSameIdentity(as: profile) == true }
        if let index {
            // Fields a newer build added to this profile stay.
            if let previous = stored[index].json as? [String: Any] {
                element = previous.merging(element) { _, new in new }
            }
            stored[index] = StoredProfile(json: element, profile: profile)
        } else {
            stored.append(StoredProfile(json: element, profile: profile))
        }
        stored.removeAll { $0.profile.map { replacedIDs.contains($0.id) } == true }
        try write(stored)
        return list(stored)
    }

    func delete(id: UUID) throws -> ConnectionProfileList {
        let stored = try storedProfiles().filter { $0.profile?.id != id }
        try write(stored)
        return list(stored)
    }

    /// One element of the stored array, and its profile when this build can decode it.
    private struct StoredProfile {
        var json: Any
        var profile: ConnectionProfile?
    }

    private func storedProfiles() throws -> [StoredProfile] {
        guard let data = defaults.data(forKey: storageKey) else {
            return []
        }
        guard let elements = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            throw ConnectionProfileStoreError.unreadableProfiles
        }
        let decoder = JSONDecoder()
        return elements.map { json in
            let profile = (try? JSONSerialization.data(withJSONObject: json, options: .fragmentsAllowed))
                .flatMap { try? decoder.decode(ConnectionProfile.self, from: $0) }
            return StoredProfile(json: json, profile: profile)
        }
    }

    private func write(_ stored: [StoredProfile]) throws {
        let data = try JSONSerialization.data(withJSONObject: stored.map(\.json))
        defaults.set(data, forKey: storageKey)
    }

    private func list(_ stored: [StoredProfile]) -> ConnectionProfileList {
        let profiles = stored.compactMap(\.profile)
        return ConnectionProfileList(
            profiles: sorted(profiles),
            unreadableCount: stored.count - profiles.count
        )
    }

    private func sorted(_ profiles: [ConnectionProfile]) -> [ConnectionProfile] {
        profiles.sorted { lhs, rhs in
            if lhs.updatedAt == rhs.updatedAt {
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
            return lhs.updatedAt > rhs.updatedAt
        }
    }
}
