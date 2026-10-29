import Foundation

/// A field of ``RDPCredentials``, as a validation error names it.
public enum RDPCredentialField: Hashable, Sendable {
    case username
    case domain
    case password
}

public enum RDPCredentialValidationError: Error, Equatable, CustomStringConvertible, Sendable {
    case missingUsernameOrPassword
    /// The field, as connecting would send it, is longer than
    /// ``RDPCredentials/maximumFieldLength``: connecting would fail with
    /// ``RDPConnectionFailure/invalidConfiguration``.
    case fieldTooLong(RDPCredentialField)

    public var description: String {
        switch self {
        case .missingUsernameOrPassword:
            "Username and password are required when credentials are provided."
        case let .fieldTooLong(field):
            "\(Self.name(of: field)) is too long: RDP sends at most "
                + "\(RDPCredentials.maximumFieldLength) characters (UTF-16 code units)."
        }
    }

    private static func name(of field: RDPCredentialField) -> String {
        switch field {
        case .username: "Username"
        case .domain: "Domain"
        case .password: "Password"
        }
    }
}

public struct RDPCredentials: Equatable, Sendable {
    public var username: String
    public var domain: String?
    public var password: String

    /// With no domain, a user name in the form "DOMAIN\user" names both and is split at its
    /// first backslash, as mstsc and FreeRDP (`freerdp_parse_username`) do; NTLM and the
    /// Client Info PDU carry the two separately. A UPN, "user@domain", stays the user name.
    public init(username: String, domain: String? = nil, password: String) {
        if domain?.isEmpty != false,
           let separator = username.firstIndex(of: "\\"),
           username.index(after: separator) < username.endIndex
        {
            self.username = String(username[username.index(after: separator)...])
            self.domain = separator == username.startIndex ? nil : String(username[..<separator])
        } else {
            self.username = username
            self.domain = domain?.isEmpty == true ? nil : domain
        }
        self.password = password
    }

    public var qualifiedUsername: String {
        guard let domain, !domain.isEmpty else {
            return username
        }
        return "\(domain)\\\(username)"
    }

    /// The most UTF-16 code units a user name, domain or password can hold. Each goes in a
    /// 512-byte Client Info PDU field with its terminator ([MS-RDPBCGR] 2.2.1.11.1.1), the
    /// tightest limit connecting enforces; NTLM's 16-bit lengths allow more.
    public static let maximumFieldLength = RDPClientInfoLimits.standardFieldByteCount / 2 - 1

    /// Trims the user name and domain, and throws for credentials connecting cannot send:
    /// a user name or password missing, or a field longer than ``maximumFieldLength`` once
    /// "DOMAIN\user" is split. Returns nil when every field is empty.
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

        let credentials = RDPCredentials(
            username: trimmedUsername,
            domain: trimmedDomain,
            password: password
        )
        let fields: [(field: RDPCredentialField, value: String)] = [
            (.username, credentials.username),
            (.domain, credentials.domain ?? ""),
            (.password, credentials.password),
        ]
        if let tooLong = fields.first(where: { $0.value.utf16.count > maximumFieldLength }) {
            throw RDPCredentialValidationError.fieldTooLong(tooLong.field)
        }
        return credentials
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
