import CryptoKit
import Foundation

struct RDPCredSSPTSRequest: Equatable, Sendable {
    var version: Int = 6
    var negoTokens: [Data] = []
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
            body.append(RDPASN1.context(4, RDPASN1.integer(Int(errorCode))))
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
        var didReadVersion = false
        while !sequence.isAtEnd {
            let field = try sequence.readElement()
            switch field.tag {
            case 0xA0:
                request.version = try RDPASN1.explicitInteger(from: field.payload)
                didReadVersion = true
            case 0xA1:
                request.negoTokens = try parseNegoData(field.payload)
            case 0xA2:
                request.authInfo = try RDPASN1.explicitOctetString(from: field.payload)
            case 0xA3:
                request.pubKeyAuth = try RDPASN1.explicitOctetString(from: field.payload)
            case 0xA4:
                request.errorCode = UInt32(try RDPASN1.explicitInteger(from: field.payload))
            case 0xA5:
                request.clientNonce = try RDPASN1.explicitOctetString(from: field.payload)
            default:
                throw RDPDecodeError.invalidCredSSPMessage
            }
        }
        guard didReadVersion else {
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
        passwordBody.append(RDPASN1.context(0, RDPASN1.octetString(utf16LittleEndian(credentials.domain ?? ""))))
        passwordBody.append(RDPASN1.context(1, RDPASN1.octetString(utf16LittleEndian(credentials.username))))
        passwordBody.append(RDPASN1.context(2, RDPASN1.octetString(utf16LittleEndian(credentials.password))))
        let passwordCreds = RDPASN1.sequence(passwordBody)

        var credentialsBody = Data()
        credentialsBody.append(RDPASN1.context(0, RDPASN1.integer(1)))
        credentialsBody.append(RDPASN1.context(1, RDPASN1.octetString(passwordCreds)))
        return RDPASN1.sequence(credentialsBody)
    }

    private static func utf16LittleEndian(_ value: String) -> Data {
        var data = Data()
        for codeUnit in value.utf16 {
            data.appendLittleEndianUInt16(codeUnit)
        }
        return data
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
    static func subjectPublicKey(fromCertificateDER certificate: Data) throws -> Data {
        var certificateReader = RDPASN1Reader(certificate)
        var certificateSequence = try certificateReader.readConstructed(tag: 0x30)
        guard certificateReader.isAtEnd else {
            throw RDPDecodeError.invalidCredSSPMessage
        }

        var tbsCertificate = try certificateSequence.readConstructed(tag: 0x30)
        _ = try certificateSequence.readElement()
        _ = try certificateSequence.readElement()
        guard certificateSequence.isAtEnd else {
            throw RDPDecodeError.invalidCredSSPMessage
        }

        if tbsCertificate.peekTag == 0xA0 {
            _ = try tbsCertificate.readElement()
        }
        _ = try tbsCertificate.readElement()
        _ = try tbsCertificate.readElement()
        _ = try tbsCertificate.readElement()
        _ = try tbsCertificate.readElement()
        _ = try tbsCertificate.readElement()

        var subjectPublicKeyInfo = try tbsCertificate.readConstructed(tag: 0x30)
        _ = try subjectPublicKeyInfo.readElement()
        let subjectPublicKey = try subjectPublicKeyInfo.readElement()
        guard subjectPublicKey.tag == 0x03,
              subjectPublicKeyInfo.isAtEnd,
              subjectPublicKey.payload.first == 0
        else {
            throw RDPDecodeError.invalidCredSSPMessage
        }
        return subjectPublicKey.payload.dropFirst()
    }
}

enum RDPCredSSPError: Error, CustomStringConvertible {
    case missingCredentials
    case unsupportedVersion(Int)
    case missingToken
    case missingPubKeyAuth
    case ntlm(String)
    case serverError(UInt32)
    case serverBindingMismatch

    var description: String {
        switch self {
        case .missingCredentials:
            "CredSSP requires credentials"
        case let .unsupportedVersion(version):
            "CredSSP version \(version) is not supported"
        case .missingToken:
            "CredSSP server did not provide a negotiation token"
        case .missingPubKeyAuth:
            "CredSSP server did not provide pubKeyAuth"
        case let .ntlm(message):
            "CredSSP NTLM failed: \(message)"
        case let .serverError(code):
            "CredSSP server returned NTSTATUS 0x\(String(format: "%08x", code))"
        case .serverBindingMismatch:
            "CredSSP server public-key binding did not match"
        }
    }
}

private struct RDPASN1Element: Equatable {
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

    mutating func readExplicitInteger() throws -> Int {
        let element = try readElement()
        guard element.tag == 0x02, isAtEnd else {
            throw RDPDecodeError.invalidCredSSPMessage
        }
        return try RDPASN1.integerValue(from: element.payload)
    }

    mutating func readExplicitOctetString() throws -> Data {
        let element = try readElement()
        guard element.tag == 0x04, isAtEnd else {
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
        return RDPASN1Element(
            tag: tag,
            payload: data.subdata(in: payloadStart ..< index(at: offset))
        )
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
        var length = 0
        for _ in 0 ..< byteCount {
            length = (length << 8) | Int(data[index(at: offset)])
            offset += 1
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

    static func integer(_ value: Int) -> Data {
        precondition(value >= 0)
        var bytes = Data()
        var remaining = value
        repeat {
            bytes.insert(UInt8(remaining & 0xFF), at: 0)
            remaining >>= 8
        } while remaining > 0
        if bytes.first.map({ $0 & 0x80 != 0 }) == true {
            bytes.insert(0, at: 0)
        }
        return wrap(tag: 0x02, bytes)
    }

    static func integerValue(from data: Data) throws -> Int {
        guard !data.isEmpty, data.count <= MemoryLayout<Int>.size else {
            throw RDPDecodeError.invalidCredSSPMessage
        }
        guard data.first.map({ $0 & 0x80 == 0 }) == true else {
            throw RDPDecodeError.invalidCredSSPMessage
        }
        var value = 0
        for byte in data {
            value = (value << 8) | Int(byte)
        }
        return value
    }

    static func explicitInteger(from data: Data) throws -> Int {
        var reader = RDPASN1Reader(data)
        return try reader.readExplicitInteger()
    }

    static func explicitOctetString(from data: Data) throws -> Data {
        var reader = RDPASN1Reader(data)
        return try reader.readExplicitOctetString()
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
