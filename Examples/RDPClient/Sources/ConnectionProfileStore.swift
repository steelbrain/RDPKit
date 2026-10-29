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
    /// Decodes profiles saved before the graphics, clipboard, and audio options existed.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        host = try container.decode(String.self, forKey: .host)
        port = try container.decode(UInt16.self, forKey: .port)
        username = try container.decode(String.self, forKey: .username)
        domain = try container.decode(String.self, forKey: .domain)
        desktopWidth = try container.decode(UInt16.self, forKey: .desktopWidth)
        desktopHeight = try container.decode(UInt16.self, forKey: .desktopHeight)
        hideCertificateWarnings = try container.decode(Bool.self, forKey: .hideCertificateWarnings)
        timeoutSeconds = try container.decode(Int.self, forKey: .timeoutSeconds)
        graphicsCapabilityProfile = try container.decodeIfPresent(
            RDPGraphicsCapabilityProfile.self,
            forKey: .graphicsCapabilityProfile
        ) ?? .automatic
        clipboardSharingEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .clipboardSharingEnabled
        ) ?? true
        audioPlaybackEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .audioPlaybackEnabled
        ) ?? false
        rememberPassword = try container.decode(Bool.self, forKey: .rememberPassword)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }
}

struct ConnectionProfileStore {
    private let defaults: UserDefaults
    private let storageKey = "connection-profiles.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func profiles() -> [ConnectionProfile] {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([ConnectionProfile].self, from: data)
        else {
            return []
        }
        return sorted(decoded)
    }

    func save(_ profile: ConnectionProfile) throws -> [ConnectionProfile] {
        var nextProfiles = profiles()
        if let index = nextProfiles.firstIndex(where: { $0.id == profile.id }) {
            nextProfiles[index] = profile
        } else if let index = nextProfiles.firstIndex(where: { $0.hasSameIdentity(as: profile) }) {
            nextProfiles[index] = profile
        } else {
            nextProfiles.append(profile)
        }
        try saveProfiles(nextProfiles)
        return sorted(nextProfiles)
    }

    func delete(id: UUID) throws -> [ConnectionProfile] {
        let nextProfiles = profiles().filter { $0.id != id }
        try saveProfiles(nextProfiles)
        return sorted(nextProfiles)
    }

    private func saveProfiles(_ profiles: [ConnectionProfile]) throws {
        let data = try JSONEncoder().encode(sorted(profiles))
        defaults.set(data, forKey: storageKey)
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
