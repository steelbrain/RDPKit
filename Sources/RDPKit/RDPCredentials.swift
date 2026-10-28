import Foundation

public enum RDPCredentialValidationError: Error, Equatable, CustomStringConvertible, Sendable {
    case missingUsernameOrPassword

    public var description: String {
        switch self {
        case .missingUsernameOrPassword:
            "Username and password are required when credentials are provided."
        }
    }
}

public struct RDPCredentials: Equatable, Sendable {
    public var username: String
    public var domain: String?
    public var password: String

    public init(username: String, domain: String? = nil, password: String) {
        self.username = username
        self.domain = domain?.isEmpty == true ? nil : domain
        self.password = password
    }

    public var qualifiedUsername: String {
        guard let domain, !domain.isEmpty else {
            return username
        }
        return "\(domain)\\\(username)"
    }

    public static func validated(
        username: String,
        domain: String? = nil,
        password: String
    ) throws -> RDPCredentials? {
        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDomain = domain?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if trimmedUsername.isEmpty, trimmedDomain.isEmpty, password.isEmpty {
            return nil
        }
        guard trimmedUsername.isEmpty == false, password.isEmpty == false else {
            throw RDPCredentialValidationError.missingUsernameOrPassword
        }

        return RDPCredentials(
            username: trimmedUsername,
            domain: trimmedDomain,
            password: password
        )
    }
}

/// Descriptions and mirrors leave the password out, so logging credentials, or a configuration
/// that holds them, does not leak it.
extension RDPCredentials: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        "RDPCredentials(username: \(String(reflecting: username)), domain: \(String(reflecting: domain)), password: <redacted>)"
    }

    public var debugDescription: String {
        description
    }

    public var customMirror: Mirror {
        Mirror(
            self,
            children: ["username": username, "domain": domain as Any, "password": "<redacted>"],
            displayStyle: .struct
        )
    }
}
