import Foundation

/// What a client authenticates with by RDSTLS after a Server Redirection whose
/// Password field is PK-encrypted: the redirection's GUID, user name, domain and
/// Password field, the last sent as the redirection gave it.
struct RDPRDSTLSPasswordCredentials: Equatable, Sendable {
    var redirectionGuid: Data
    var username: String
    var domain: String
    var password: Data
}

/// The RDSTLS PDUs a client sends and reads, version 1 with password
/// credentials, laid out as FreeRDP 3.32's libfreerdp/core/rdstls.c has them:
/// every field little-endian, each variable one after a 16-bit byte count.
enum RDPRDSTLS {
    static let version1: UInt16 = 0x0001
    static let capabilitiesPDUType: UInt16 = 0x0001
    static let authenticationRequestPDUType: UInt16 = 0x0002
    static let authenticationResponsePDUType: UInt16 = 0x0004
    static let capabilitiesDataType: UInt16 = 0x0001
    static let passwordCredentialsDataType: UInt16 = 0x0001
    static let resultCodeDataType: UInt16 = 0x0001

    /// The length of the server PDU at the start of the stream, which its type
    /// sets, or nil until its type has arrived.
    static func serverPDULength(readableByteCount: Int, byteAt: (Int) -> UInt8) throws -> Int? {
        guard readableByteCount >= 4 else {
            return nil
        }
        switch UInt16(byteAt(2)) | UInt16(byteAt(3)) << 8 {
        case capabilitiesPDUType:
            return 8
        case authenticationResponsePDUType:
            return 10
        case let pduType:
            throw RDPConnectionError.receive(
                "received unexpected RDSTLS PDU type 0x\(String(format: "%04x", pduType))",
                failure: .protocolViolation
            )
        }
    }

    /// Checks the server's Capabilities PDU offers version 1, the one password
    /// credentials use.
    static func checkCapabilities(_ data: Data) throws {
        var cursor = ByteCursor(data)
        let version = try cursor.readLittleEndianUInt16()
        let pduType = try cursor.readLittleEndianUInt16()
        let dataType = try cursor.readLittleEndianUInt16()
        let supportedVersions = try cursor.readLittleEndianUInt16()
        guard version == version1,
              pduType == capabilitiesPDUType,
              dataType == capabilitiesDataType,
              supportedVersions & version1 != 0
        else {
            throw RDPConnectionError.protocolViolation("RDSTLS Capabilities PDU does not offer version 1")
        }
    }

    /// The Authentication Request PDU with password credentials. The user name and
    /// domain are null-terminated; the password goes as `credentials.password` holds it.
    static func authenticationRequest(_ credentials: RDPRDSTLSPasswordCredentials) throws -> Data {
        var data = Data()
        data.appendLittleEndianUInt16(version1)
        data.appendLittleEndianUInt16(authenticationRequestPDUType)
        data.appendLittleEndianUInt16(passwordCredentialsDataType)
        var username = Data(utf16LittleEndian: credentials.username)
        username.appendLittleEndianUInt16(0)
        var domain = Data(utf16LittleEndian: credentials.domain)
        domain.appendLittleEndianUInt16(0)
        for field in [credentials.redirectionGuid, username, domain, credentials.password] {
            guard let count = UInt16(exactly: field.count) else {
                throw RDPConnectionError.protocolViolation("redirection credentials do not fit an RDSTLS Authentication Request")
            }
            data.appendLittleEndianUInt16(count)
            data.append(field)
        }
        return data
    }

    /// The resultCode of the server's Authentication Response PDU.
    static func authenticationResult(_ data: Data) throws -> RDPRDSTLSResultCode {
        var cursor = ByteCursor(data)
        let version = try cursor.readLittleEndianUInt16()
        let pduType = try cursor.readLittleEndianUInt16()
        let dataType = try cursor.readLittleEndianUInt16()
        let resultCode = try cursor.readLittleEndianUInt32()
        guard version == version1,
              pduType == authenticationResponsePDUType,
              dataType == resultCodeDataType
        else {
            throw RDPConnectionError.protocolViolation("RDSTLS Authentication Response PDU is malformed")
        }
        return RDPRDSTLSResultCode(rawValue: resultCode)
    }
}

/// The resultCode of an RDSTLS Authentication Response: success, or the Win32 error
/// code the server rejected the credentials with. The constants are the ones FreeRDP
/// 3.32 names (libfreerdp/core/rdstls.c).
public struct RDPRDSTLSResultCode: RawRepresentable, Hashable, Encodable, Sendable, CustomStringConvertible {
    public var rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    /// The server accepted the credentials.
    public static let success = RDPRDSTLSResultCode(rawValue: 0x0000_0000)
    /// The server denied access, such as for a redirection GUID it did not issue.
    public static let accessDenied = RDPRDSTLSResultCode(rawValue: 0x0000_0005)
    /// The user name, domain or password is wrong.
    public static let logonFailure = RDPRDSTLSResultCode(rawValue: 0x0000_052E)
    /// The account may not sign in at this time.
    public static let invalidLogonHours = RDPRDSTLSResultCode(rawValue: 0x0000_0530)
    /// The password has expired.
    public static let passwordExpired = RDPRDSTLSResultCode(rawValue: 0x0000_0532)
    /// The account is disabled.
    public static let accountDisabled = RDPRDSTLSResultCode(rawValue: 0x0000_0533)
    /// The password must be changed before signing in.
    public static let passwordMustChange = RDPRDSTLSResultCode(rawValue: 0x0000_0773)
    /// The account is locked out.
    public static let accountLockedOut = RDPRDSTLSResultCode(rawValue: 0x0000_0775)

    /// The code's Win32 name, such as ERROR_LOGON_FAILURE, for the constants above.
    public var name: String? {
        switch self {
        case .success: "ERROR_SUCCESS"
        case .accessDenied: "ERROR_ACCESS_DENIED"
        case .logonFailure: "ERROR_LOGON_FAILURE"
        case .invalidLogonHours: "ERROR_INVALID_LOGON_HOURS"
        case .passwordExpired: "ERROR_PASSWORD_EXPIRED"
        case .accountDisabled: "ERROR_ACCOUNT_DISABLED"
        case .passwordMustChange: "ERROR_PASSWORD_MUST_CHANGE"
        case .accountLockedOut: "ERROR_ACCOUNT_LOCKED_OUT"
        default: nil
        }
    }

    /// The name and code, such as "ERROR_LOGON_FAILURE (0x0000052e)".
    public var description: String {
        let code = "0x\(String(format: "%08x", rawValue))"
        return name.map { "\($0) (\(code))" } ?? "code \(code)"
    }
}
