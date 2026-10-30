import CryptoKit
import Foundation

struct RDPCredSSPTSRequest: Equatable, Sendable {
    var version: Int
    var negoTokens: [Data]
    var authInfo: Data?
    var pubKeyAuth: Data?
    var errorCode: UInt32?
    var clientNonce: Data?

    init(
        version: Int = 6,
        negoTokens: [Data] = [],
        authInfo: Data? = nil,
        pubKeyAuth: Data? = nil,
        errorCode: UInt32? = nil,
        clientNonce: Data? = nil
    ) {
        if let clientNonce {
            precondition(clientNonce.count == 32)
        }
        self.version = version
        self.negoTokens = negoTokens
        self.authInfo = authInfo
        self.pubKeyAuth = pubKeyAuth
        self.errorCode = errorCode
        self.clientNonce = clientNonce
    }

    func encoded() -> Data {
        var body = Data()
        body.append(RDPASN1.context(0, RDPASN1.integer(version)))
        if !negoTokens.isEmpty {
            body.append(RDPASN1.context(1, encodedNegoData()))
        }
        if let authInfo {
            body.append(RDPASN1.context(2, RDPASN1.octetString(authInfo)))
        }
        if let pubKeyAuth {
            body.append(RDPASN1.context(3, RDPASN1.octetString(pubKeyAuth)))
        }
        if let errorCode {
            body.append(RDPASN1.context(4, RDPASN1.integer(Int(Int32(bitPattern: errorCode)))))
        }
        if let clientNonce {
            body.append(RDPASN1.context(5, RDPASN1.octetString(clientNonce)))
        }
        return RDPASN1.sequence(body)
    }

    static func parse(_ data: Data) throws -> RDPCredSSPTSRequest {
        var reader = RDPASN1Reader(data)
        var sequence = try reader.readConstructed(tag: 0x30)
        guard reader.isAtEnd else {
            throw RDPDecodeError.invalidCredSSPMessage
        }

        var request = RDPCredSSPTSRequest()
        var fieldTags = Set<UInt8>()
        while !sequence.isAtEnd {
            let field = try sequence.readElement()
            guard fieldTags.insert(field.tag).inserted else {
                throw RDPDecodeError.invalidCredSSPMessage
            }
            switch field.tag {
            case 0xA0:
                request.version = try RDPASN1.explicitInteger(from: field.payload)
            case 0xA1:
                request.negoTokens = try parseNegoData(field.payload)
            case 0xA2:
                request.authInfo = try RDPASN1.explicitOctetString(from: field.payload)
            case 0xA3:
                request.pubKeyAuth = try RDPASN1.explicitOctetString(from: field.payload)
            case 0xA4:
                request.errorCode = try RDPASN1.explicitNTStatus(from: field.payload)
            case 0xA5:
                let clientNonce = try RDPASN1.explicitOctetString(from: field.payload)
                guard clientNonce.count == 32 else {
                    throw RDPDecodeError.invalidCredSSPMessage
                }
                request.clientNonce = clientNonce
            default:
                throw RDPDecodeError.invalidCredSSPMessage
            }
        }
        guard fieldTags.contains(0xA0), request.version >= 2 else {
            throw RDPDecodeError.invalidCredSSPMessage
        }
        return request
    }

    private func encodedNegoData() -> Data {
        var entries = Data()
        for token in negoTokens {
            entries.append(RDPASN1.sequence(RDPASN1.context(0, RDPASN1.octetString(token))))
        }
        return RDPASN1.sequence(entries)
    }

    private static func parseNegoData(_ data: Data) throws -> [Data] {
        var reader = RDPASN1Reader(data)
        var sequence = try reader.readConstructed(tag: 0x30)
        guard reader.isAtEnd else {
            throw RDPDecodeError.invalidCredSSPMessage
        }

        var tokens: [Data] = []
        while !sequence.isAtEnd {
            var item = try sequence.readConstructed(tag: 0x30)
            let tokenField = try item.readElement()
            guard tokenField.tag == 0xA0, item.isAtEnd else {
                throw RDPDecodeError.invalidCredSSPMessage
            }
            tokens.append(try RDPASN1.explicitOctetString(from: tokenField.payload))
        }
        return tokens
    }
}

enum RDPCredSSPCredentials {
    static func passwordCredentials(_ credentials: RDPCredentials) -> Data {
        var passwordBody = Data()
        passwordBody.append(RDPASN1.context(0, RDPASN1.octetString(Data(utf16LittleEndian: credentials.domain ?? ""))))
        passwordBody.append(RDPASN1.context(1, RDPASN1.octetString(Data(utf16LittleEndian: credentials.username))))
        passwordBody.append(RDPASN1.context(2, RDPASN1.octetString(Data(utf16LittleEndian: credentials.password))))
        let passwordCreds = RDPASN1.sequence(passwordBody)

        var credentialsBody = Data()
        credentialsBody.append(RDPASN1.context(0, RDPASN1.integer(1)))
        credentialsBody.append(RDPASN1.context(1, RDPASN1.octetString(passwordCreds)))
        return RDPASN1.sequence(credentialsBody)
    }
}

enum RDPCredSSPPublicKeyBinding {
    static func clientServerHash(subjectPublicKey: Data, nonce: Data) -> Data {
        bindingHash(
            magic: "CredSSP Client-To-Server Binding Hash",
            subjectPublicKey: subjectPublicKey,
            nonce: nonce
        )
    }

    static func serverClientHash(subjectPublicKey: Data, nonce: Data) -> Data {
        bindingHash(
            magic: "CredSSP Server-To-Client Binding Hash",
            subjectPublicKey: subjectPublicKey,
            nonce: nonce
        )
    }

    static func legacyServerResponse(subjectPublicKey: Data) throws -> Data {
        guard !subjectPublicKey.isEmpty else {
            throw RDPDecodeError.invalidCredSSPMessage
        }
        var response = subjectPublicKey
        response[response.startIndex] &+= 1
        return response
    }

    private static func bindingHash(magic: String, subjectPublicKey: Data, nonce: Data) -> Data {
        var input = Data(magic.utf8)
        input.append(0)
        input.append(nonce)
        input.append(subjectPublicKey)
        return Data(SHA256.hash(data: input))
    }
}

enum RDPCredSSPCertificate {
    /// The SubjectPublicKey BIT STRING contents that CredSSP binds to (MS-CSSP 3.1.5 step 3).
    static func subjectPublicKey(fromCertificateDER certificate: Data) throws -> Data {
        var tbsCertificate = try certificateFields(certificate).tbsCertificate
        if tbsCertificate.peekTag == 0xA0 {
            _ = try tbsCertificate.readElement()
        }
        // serialNumber, signature, issuer, validity, subject
        for _ in 0 ..< 5 {
            _ = try tbsCertificate.readElement()
        }

        var subjectPublicKeyInfo = try tbsCertificate.readConstructed(tag: 0x30)
        _ = try subjectPublicKeyInfo.readElement()
        let subjectPublicKey = try subjectPublicKeyInfo.readElement()
        guard subjectPublicKey.tag == 0x03,
              subjectPublicKeyInfo.isAtEnd,
              subjectPublicKey.payload.first == 0
        else {
            throw RDPDecodeError.invalidCredSSPMessage
        }
        return Data(subjectPublicKey.payload.dropFirst())
    }

    /// MD5 of the gss_channel_bindings_struct (MS-NLMP 2.2.2.1 MsvAvChannelBindings) whose
    /// application data is the RFC 5929 tls-server-end-point binding.
    static func ntlmChannelBindingsHash(fromCertificateDER certificate: Data) throws -> Data {
        var signatureAlgorithm = try certificateFields(certificate).signatureAlgorithm
        var algorithm = try signatureAlgorithm.readObjectIdentifier()
        if algorithm == rsassaPSS {
            algorithm = try pssHashAlgorithm(parameters: &signatureAlgorithm)
        }
        // RFC 5929 4.1: the certificate signature's hash, with SHA-256 replacing MD5 and SHA-1.
        let certificateDigest = switch algorithm {
        case sha384WithRSAEncryption, ecdsaWithSHA384, sha384:
            Data(SHA384.hash(data: certificate))
        case sha512WithRSAEncryption, ecdsaWithSHA512, sha512:
            Data(SHA512.hash(data: certificate))
        default:
            Data(SHA256.hash(data: certificate))
        }
        let applicationData = Data("tls-server-end-point:".utf8) + certificateDigest
        // Empty initiator and acceptor addresses: two (address type, length) pairs of zeros.
        var bindings = Data(count: 16)
        bindings.appendLittleEndianUInt32(UInt32(applicationData.count))
        bindings.append(applicationData)
        return Data(Insecure.MD5.hash(data: bindings))
    }

    /// The hashAlgorithm of RSASSA-PSS-params (RFC 4055 3.1), which an RSASSA-PSS signature
    /// names in its parameters rather than its OID; empty, as for the default SHA-1, when absent.
    private static func pssHashAlgorithm(parameters signatureAlgorithm: inout RDPASN1Reader) throws -> Data {
        guard signatureAlgorithm.peekTag == 0x30 else {
            return Data()
        }
        var parameters = try signatureAlgorithm.readConstructed(tag: 0x30)
        guard parameters.peekTag == 0xA0 else {
            return Data()
        }
        var hashAlgorithm = try parameters.readConstructed(tag: 0xA0)
        var identifier = try hashAlgorithm.readConstructed(tag: 0x30)
        return try identifier.readObjectIdentifier()
    }

    /// RFC 5280 4.1 Certificate: tbsCertificate, signatureAlgorithm, signatureValue.
    private static func certificateFields(
        _ certificate: Data
    ) throws -> (tbsCertificate: RDPASN1Reader, signatureAlgorithm: RDPASN1Reader) {
        var reader = RDPASN1Reader(certificate)
        var fields = try reader.readConstructed(tag: 0x30)
        let tbsCertificate = try fields.readConstructed(tag: 0x30)
        let signatureAlgorithm = try fields.readConstructed(tag: 0x30)
        _ = try fields.readElement()
        guard reader.isAtEnd, fields.isAtEnd else {
            throw RDPDecodeError.invalidCredSSPMessage
        }
        return (tbsCertificate, signatureAlgorithm)
    }

    private static let sha384WithRSAEncryption = Data([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0C])
    private static let sha512WithRSAEncryption = Data([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0D])
    private static let ecdsaWithSHA384 = Data([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x03])
    private static let ecdsaWithSHA512 = Data([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x04])
    private static let rsassaPSS = Data([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0A])
    private static let sha384 = Data([0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x02])
    private static let sha512 = Data([0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x03])
}

/// Server tokens come as raw NTLM messages or SPNEGO NegTokenResp (MS-CSSP 2.2.1.1);
/// an acceptor never sends NegTokenInit (RFC 4178 4.2.2).
enum RDPSPNEGO {
    private static let ntlmSignature = Data("NTLMSSP\u{0}".utf8)

    static func mechanismToken(from token: Data) throws -> Data {
        if token.starts(with: ntlmSignature) {
            return token
        }

        var reader = RDPASN1Reader(token)
        var negTokenResp = try reader.readConstructed(tag: 0xA1)
        var sequence = try negTokenResp.readConstructed(tag: 0x30)
        guard reader.isAtEnd, negTokenResp.isAtEnd else {
            throw RDPDecodeError.invalidCredSSPMessage
        }

        var responseToken: Data?
        while !sequence.isAtEnd {
            let field = try sequence.readElement()
            switch field.tag {
            case 0xA0, 0xA1, 0xA3:
                break
            case 0xA2:
                responseToken = try RDPASN1.explicitOctetString(from: field.payload)
            default:
                throw RDPDecodeError.invalidCredSSPMessage
            }
        }
        guard let responseToken else {
            throw RDPDecodeError.invalidCredSSPMessage
        }
        return responseToken
    }
}

enum RDPCredSSPError: Error, CustomStringConvertible {
    case missingCredentials
    /// The user name or domain does not fit an NTLM AUTHENTICATE_MESSAGE field.
    case credentialsTooLong
    case missingToken
    case missingPubKeyAuth
    /// The server's NTLM messages could not be used.
    case ntlm(String)
    /// NTLM failed on this side: no random bytes, or the context used out of order.
    case ntlmClient(String)
    case serverError(UInt32)
    case serverBindingMismatch

    var description: String {
        switch self {
        case .missingCredentials:
            "CredSSP requires credentials"
        case .credentialsTooLong:
            "CredSSP NTLM failed: the user name or domain is too long for an NTLM message"
        case .missingToken:
            "CredSSP server did not provide a negotiation token"
        case .missingPubKeyAuth:
            "CredSSP server did not provide pubKeyAuth"
        case let .ntlm(message), let .ntlmClient(message):
            "CredSSP NTLM failed: \(message)"
        case let .serverError(code):
            "CredSSP server returned \(RDPLogonStatus(rawValue: code))"
        case .serverBindingMismatch:
            "CredSSP server public-key binding did not match"
        }
    }

    var failure: RDPConnectionFailure {
        switch self {
        case .missingCredentials:
            .credentialsRequired
        case .credentialsTooLong:
            .invalidConfiguration
        case .ntlmClient:
            .clientFailure
        case let .serverError(code):
            .credSSP(status: RDPLogonStatus(rawValue: code))
        case .missingToken, .missingPubKeyAuth, .ntlm, .serverBindingMismatch:
            .protocolViolation
        }
    }
}

/// An NTSTATUS ([MS-ERREF] 2.3.1) a CredSSP server returned in its TSRequest
/// errorCode; the constants are the logon and account failures it reports.
public struct RDPLogonStatus: RawRepresentable, Hashable, Encodable, Sendable, CustomStringConvertible {
    public var rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let accessDenied = RDPLogonStatus(rawValue: 0xC000_0022)
    public static let noSuchUser = RDPLogonStatus(rawValue: 0xC000_0064)
    public static let wrongPassword = RDPLogonStatus(rawValue: 0xC000_006A)
    /// The user name or password is wrong; Windows does not say which.
    public static let logonFailure = RDPLogonStatus(rawValue: 0xC000_006D)
    public static let accountRestriction = RDPLogonStatus(rawValue: 0xC000_006E)
    public static let invalidLogonHours = RDPLogonStatus(rawValue: 0xC000_006F)
    public static let invalidWorkstation = RDPLogonStatus(rawValue: 0xC000_0070)
    public static let passwordExpired = RDPLogonStatus(rawValue: 0xC000_0071)
    public static let accountDisabled = RDPLogonStatus(rawValue: 0xC000_0072)
    /// The account may not log on remotely.
    public static let logonTypeNotGranted = RDPLogonStatus(rawValue: 0xC000_015B)
    public static let accountExpired = RDPLogonStatus(rawValue: 0xC000_0193)
    public static let passwordMustChange = RDPLogonStatus(rawValue: 0xC000_0224)
    public static let accountLockedOut = RDPLogonStatus(rawValue: 0xC000_0234)

    /// The status's name, such as STATUS_LOGON_FAILURE, for the constants above.
    public var name: String? {
        switch self {
        case .accessDenied: "STATUS_ACCESS_DENIED"
        case .noSuchUser: "STATUS_NO_SUCH_USER"
        case .wrongPassword: "STATUS_WRONG_PASSWORD"
        case .logonFailure: "STATUS_LOGON_FAILURE"
        case .accountRestriction: "STATUS_ACCOUNT_RESTRICTION"
        case .invalidLogonHours: "STATUS_INVALID_LOGON_HOURS"
        case .invalidWorkstation: "STATUS_INVALID_WORKSTATION"
        case .passwordExpired: "STATUS_PASSWORD_EXPIRED"
        case .accountDisabled: "STATUS_ACCOUNT_DISABLED"
        case .logonTypeNotGranted: "STATUS_LOGON_TYPE_NOT_GRANTED"
        case .accountExpired: "STATUS_ACCOUNT_EXPIRED"
        case .passwordMustChange: "STATUS_PASSWORD_MUST_CHANGE"
        case .accountLockedOut: "STATUS_ACCOUNT_LOCKED_OUT"
        default: nil
        }
    }

    /// The name and code, such as "STATUS_LOGON_FAILURE (0xc000006d)".
    public var description: String {
        "\(name ?? "NTSTATUS") (0x\(String(format: "%08x", rawValue)))"
    }
}

private struct RDPASN1Element {
    var tag: UInt8
    var payload: Data
}

private struct RDPASN1Reader {
    private let data: Data
    private var offset = 0

    init(_ data: Data) {
        self.data = data
    }

    var isAtEnd: Bool {
        offset == data.count
    }

    var peekTag: UInt8? {
        guard offset < data.count else {
            return nil
        }
        return data[index(at: offset)]
    }

    mutating func readConstructed(tag: UInt8) throws -> RDPASN1Reader {
        let element = try readElement()
        guard element.tag == tag else {
            throw RDPDecodeError.invalidBERTag(expected: tag, actual: element.tag)
        }
        return RDPASN1Reader(element.payload)
    }

    mutating func readObjectIdentifier() throws -> Data {
        let element = try readElement()
        guard element.tag == 0x06 else {
            throw RDPDecodeError.invalidCredSSPMessage
        }
        return element.payload
    }

    mutating func readElement() throws -> RDPASN1Element {
        try require(2)
        let tag = data[index(at: offset)]
        offset += 1
        let length = try readLength()
        try require(length)
        let payloadStart = index(at: offset)
        offset += length
        return RDPASN1Element(tag: tag, payload: data.subdata(in: payloadStart ..< index(at: offset)))
    }

    private mutating func readLength() throws -> Int {
        try require(1)
        let first = data[index(at: offset)]
        offset += 1
        if first & 0x80 == 0 {
            return Int(first)
        }

        let byteCount = Int(first & 0x7F)
        guard byteCount > 0, byteCount <= 4 else {
            throw RDPDecodeError.invalidBERLength
        }
        try require(byteCount)
        guard data[index(at: offset)] != 0 else {
            throw RDPDecodeError.invalidBERLength
        }
        var length = 0
        for _ in 0 ..< byteCount {
            length = (length << 8) | Int(data[index(at: offset)])
            offset += 1
        }
        guard length >= 0x80 else {
            throw RDPDecodeError.invalidBERLength
        }
        return length
    }

    private func require(_ byteCount: Int) throws {
        guard data.count - offset >= byteCount else {
            throw RDPDecodeError.truncated(needed: byteCount, remaining: data.count - offset)
        }
    }

    private func index(at offset: Int) -> Data.Index {
        data.index(data.startIndex, offsetBy: offset)
    }
}

private enum RDPASN1 {
    static func sequence(_ payload: Data) -> Data {
        wrap(tag: 0x30, payload)
    }

    static func context(_ number: UInt8, _ payload: Data) -> Data {
        wrap(tag: 0xA0 + number, payload)
    }

    static func octetString(_ value: Data) -> Data {
        wrap(tag: 0x04, value)
    }

    /// Minimal two's-complement INTEGER (X.690 8.3).
    static func integer(_ value: Int) -> Data {
        var bytes = [UInt8(truncatingIfNeeded: value)]
        var remaining = value >> 8
        while remaining != (bytes[0] & 0x80 == 0 ? 0 : -1) {
            bytes.insert(UInt8(truncatingIfNeeded: remaining), at: 0)
            remaining >>= 8
        }
        return wrap(tag: 0x02, Data(bytes))
    }

    static func explicitInteger(from data: Data, requiresMinimalEncoding: Bool = true) throws -> Int {
        let bytes = try explicitPayload(tag: 0x02, from: data)
        guard let first = bytes.first, bytes.count <= MemoryLayout<Int>.size else {
            throw RDPDecodeError.invalidCredSSPMessage
        }
        let signExtension: UInt8 = first & 0x80 == 0 ? 0x00 : 0xFF
        // DER: the first nine bits are never all zeros or all ones.
        if requiresMinimalEncoding,
           bytes.count > 1,
           first == signExtension,
           (bytes[bytes.startIndex + 1] ^ signExtension) & 0x80 == 0
        {
            throw RDPDecodeError.invalidCredSSPMessage
        }
        var value = first & 0x80 == 0 ? 0 : -1
        for byte in bytes {
            value = value << 8 | Int(byte)
        }
        return value
    }

    /// errorCode is an NTSTATUS. Windows and FreeRDP-based servers encode failures such as
    /// 0xC000006D as a negative 32-bit INTEGER; the unsigned form is accepted too. FreeRDP 2.x
    /// writes every value from 0x80000000 in 4 bytes, which is not minimal from 0xFF800000.
    static func explicitNTStatus(from data: Data) throws -> UInt32 {
        let value = try explicitInteger(from: data, requiresMinimalEncoding: false)
        if let signedValue = Int32(exactly: value) {
            return UInt32(bitPattern: signedValue)
        }
        guard let unsignedValue = UInt32(exactly: value) else {
            throw RDPDecodeError.invalidCredSSPMessage
        }
        return unsignedValue
    }

    static func explicitOctetString(from data: Data) throws -> Data {
        try explicitPayload(tag: 0x04, from: data)
    }

    /// The payload of the single element an explicit context tag wraps.
    private static func explicitPayload(tag: UInt8, from data: Data) throws -> Data {
        var reader = RDPASN1Reader(data)
        let element = try reader.readElement()
        guard element.tag == tag, reader.isAtEnd else {
            throw RDPDecodeError.invalidCredSSPMessage
        }
        return element.payload
    }

    private static func wrap(tag: UInt8, _ payload: Data) -> Data {
        var data = Data([tag])
        data.append(length(payload.count))
        data.append(payload)
        return data
    }

    private static func length(_ value: Int) -> Data {
        precondition(value >= 0)
        if value < 0x80 {
            return Data([UInt8(value)])
        }

        var bytes = Data()
        var remaining = value
        while remaining > 0 {
            bytes.insert(UInt8(remaining & 0xFF), at: 0)
            remaining >>= 8
        }

        var data = Data([0x80 | UInt8(bytes.count)])
        data.append(bytes)
        return data
    }
}
