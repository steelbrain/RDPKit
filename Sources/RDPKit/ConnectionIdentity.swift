import Foundation

public enum RDPConnectionValidationError: Error, Equatable, CustomStringConvertible, Sendable {
    case missingHost
    case invalidPort
    case invalidDesktopSize

    public var description: String {
        switch self {
        case .missingHost:
            "Host is required."
        case .invalidPort:
            "Port must be between 1 and 65535."
        case .invalidDesktopSize:
            "Display size must be between 640x480 and 8192x8192."
        }
    }
}

public struct RDPConnectionTarget: Equatable, Hashable, Sendable {
    public var host: String
    public var port: UInt16

    public init(host: String, port: UInt16 = 3389) throws {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedHost.isEmpty == false else {
            throw RDPConnectionValidationError.missingHost
        }
        guard port != 0 else {
            throw RDPConnectionValidationError.invalidPort
        }

        self.host = trimmedHost
        self.port = port
    }

    public init(host: String, portText: String) throws {
        let trimmedPort = portText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsedPort = UInt16(trimmedPort) else {
            throw RDPConnectionValidationError.invalidPort
        }
        try self.init(host: host, port: parsedPort)
    }
}

public struct RDPDesktopSize: Equatable, Hashable, Sendable {
    public var width: UInt16
    public var height: UInt16

    public init(width: UInt16, height: UInt16) throws {
        guard (640 ... 8192).contains(width),
              (480 ... 8192).contains(height)
        else {
            throw RDPConnectionValidationError.invalidDesktopSize
        }

        self.width = width
        self.height = height
    }

    public init(widthText: String, heightText: String) throws {
        let trimmedWidth = widthText.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedHeight = heightText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsedWidth = UInt16(trimmedWidth),
              let parsedHeight = UInt16(trimmedHeight)
        else {
            throw RDPConnectionValidationError.invalidDesktopSize
        }

        try self.init(width: parsedWidth, height: parsedHeight)
    }

    /// The desktop to connect with so that sending `request` through Display Control once
    /// connected resizes nothing: its size, whose width Display Control rounds down to even,
    /// raised to the 640x480 a connection takes at least.
    public init(_ request: RDPDisplayRequest) {
        width = UInt16(max(request.width, 640))
        height = UInt16(max(request.height, 480))
    }
}

/// A password that may be saved under an earlier name of an account, and how to move it to the
/// account's name, ``RDPConnectionIdentity/credentialAccountName``, in an app's own store such
/// as Keychain: rename it in one step, rather than save it again, so one deleted meanwhile
/// stays deleted. Nothing saved under ``legacyAccountName`` means nothing to move.
public struct RDPCredentialAccountMove: Equatable, Sendable {
    /// The earlier name, one of ``RDPConnectionIdentity/legacyCredentialAccountNames``.
    public var legacyAccountName: String
    /// The account's name.
    public var accountName: String
    /// What to do when ``accountName`` has a password already: true deletes the one under
    /// ``legacyAccountName``, which is older; false leaves it for the lookup of the profile
    /// whose earlier name it is.
    public var deletesLegacyPasswordWhenTaken: Bool

    public init(legacyAccountName: String, accountName: String, deletesLegacyPasswordWhenTaken: Bool) {
        self.legacyAccountName = legacyAccountName
        self.accountName = accountName
        self.deletesLegacyPasswordWhenTaken = deletesLegacyPasswordWhenTaken
    }
}

public struct RDPConnectionIdentity: Equatable, Hashable, Sendable {
    public var host: String
    public var port: UInt16
    public var username: String
    public var domain: String?

    public init(
        host: String,
        port: UInt16 = 3389,
        username: String = "",
        domain: String? = nil
    ) {
        self.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        self.port = port
        self.username = username.trimmingCharacters(in: .whitespacesAndNewlines)

        let trimmedDomain = domain?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.domain = trimmedDomain.isEmpty ? nil : trimmedDomain
    }

    public var displayName: String {
        accountPrefix + targetName
    }

    public var qualifiedUsername: String? {
        guard username.isEmpty == false else {
            return nil
        }
        guard let domain else {
            return username
        }
        return "\(domain)\\\(username)"
    }

    /// The account a password for this identity is stored under: `qualifiedUsername`, then `@`,
    /// the host in lowercase, `:` and the port, as in `LAB\anees@server.local:3389`. Nil without
    /// a username.
    ///
    /// The name ignores case exactly where `hasSameConnectionIdentity(as:)` does: in the host
    /// only. The username and domain keep their case: Windows ignores it, but other servers need
    /// not. RDPKit keeps this name stable across releases; if it ever changes, the old form is
    /// added to `legacyCredentialAccountNames`.
    public var credentialAccountName: String? {
        guard let qualifiedUsername else {
            return nil
        }
        return "\(qualifiedUsername)@\(normalizedHost):\(port)"
    }

    /// Names earlier RDPKit releases gave `credentialAccountName` for this identity, newest
    /// first, without any that equal the current name. A client that finds nothing saved under
    /// `credentialAccountName` can look these up and move what it finds to the current name.
    ///
    /// RDPKit 0.1 to 0.3 kept the host's case, as in `LAB\anees@Server.Local:3389`, so a
    /// password saved then is found only while the host is entered as it was when saving.
    public var legacyCredentialAccountNames: [String] {
        guard let qualifiedUsername else {
            return []
        }
        let hostAsEntered = "\(qualifiedUsername)@\(host):\(port)"
        return hostAsEntered == credentialAccountName ? [] : [hostAsEntered]
    }

    /// The steps that move passwords saved under earlier names of this identity's account to
    /// ``credentialAccountName``, in order, for an app's own store such as Keychain; none
    /// without a username.
    ///
    /// With no `others`, as when a lookup finds nothing under the account's name, each of
    /// ``legacyCredentialAccountNames`` moves, and is deleted when the account's name has a
    /// password already, the newer one.
    ///
    /// With `others`, the identities that keep the account once this one goes, as profiles
    /// still saved for it do, two kinds of earlier name move:
    /// 1. Each of theirs this identity does not share, as their lookups would move it. It
    ///    stays when the account's name has a password. This identity's password then cannot
    ///    take the account's name, where their lookups would read it in place of their own.
    /// 2. Each of this identity's that none of them share, as their lookups never try it. It is
    ///    deleted when the account's name has a password.
    ///
    /// An earlier name one of them shares stays for its lookup. Identities of other accounts
    /// are left out.
    public func legacyCredentialMoves(keptBy others: [RDPConnectionIdentity] = []) -> [RDPCredentialAccountMove] {
        guard let accountName = credentialAccountName else {
            return []
        }
        let ownNames = legacyCredentialAccountNames
        var namesInUse: [String] = []
        for other in others where other.credentialAccountName == accountName {
            for name in other.legacyCredentialAccountNames where !namesInUse.contains(name) {
                namesInUse.append(name)
            }
        }
        let theirs = namesInUse.filter { !ownNames.contains($0) }.map {
            RDPCredentialAccountMove(legacyAccountName: $0, accountName: accountName, deletesLegacyPasswordWhenTaken: false)
        }
        let own = ownNames.filter { !namesInUse.contains($0) }.map {
            RDPCredentialAccountMove(legacyAccountName: $0, accountName: accountName, deletesLegacyPasswordWhenTaken: true)
        }
        return theirs + own
    }

    /// Whether `other` is the same account on the same server, so the two share a saved
    /// password: exactly when their `credentialAccountName`s match. The user name and domain
    /// compare as `qualifiedUsername` joins them, so "LAB\anees" with no domain, which
    /// `RDPCredentials` signs in as "anees" in LAB, is the same account as "anees" in LAB.
    /// Without a user name, the domains compare.
    public func hasSameConnectionIdentity(as other: RDPConnectionIdentity) -> Bool {
        guard normalizedHost == other.normalizedHost, port == other.port else {
            return false
        }
        guard qualifiedUsername != nil || other.qualifiedUsername != nil else {
            return (domain ?? "") == (other.domain ?? "")
        }
        return qualifiedUsername == other.qualifiedUsername
    }

    private var accountPrefix: String {
        guard let qualifiedUsername else {
            return ""
        }
        return "\(qualifiedUsername)@"
    }

    private var targetName: String {
        port == 3389 ? host : "\(host):\(port)"
    }

    private var normalizedHost: String {
        host.lowercased()
    }
}
