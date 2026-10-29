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
