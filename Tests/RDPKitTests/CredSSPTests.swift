import Foundation
@testable import RDPKit
import Testing

@Test func credSSPTSRequestEncodesInitialNegoToken() throws {
    let request = RDPCredSSPTSRequest(negoTokens: [Data([0x01, 0x02, 0x03])])

    #expect(request.encoded() == Data([
        0x30, 0x12,
        0xA0, 0x03, 0x02, 0x01, 0x06,
        0xA1, 0x0B,
        0x30, 0x09,
        0x30, 0x07,
        0xA0, 0x05,
        0x04, 0x03, 0x01, 0x02, 0x03,
    ]))
    #expect(try RDPCredSSPTSRequest.parse(request.encoded()) == request)
}

@Test func credSSPTSRequestParsesSSPIRSInitialNTLMRequest() throws {
    let clientNonce = Data([
        0x22, 0x10, 0x12, 0xAD, 0x12, 0x5C, 0x7A, 0x15,
        0xFE, 0xB6, 0x4B, 0x1F, 0xCB, 0x94, 0x83, 0x3A,
        0xC5, 0x6F, 0x66, 0x4C, 0xF3, 0xBC, 0xE7, 0x54,
        0x8A, 0x5D, 0x9E, 0x05, 0x0A, 0x46, 0x91, 0xDB,
    ])
    let negotiateToken = sspiRSNegotiateToken()
    let request = RDPCredSSPTSRequest(
        version: 6,
        negoTokens: [negotiateToken],
        clientNonce: clientNonce
    )

    let encoded = Data([
        0x30, 0x5B, 0xA0, 0x03, 0x02, 0x01, 0x06, 0xA1,
        0x30, 0x30, 0x2E, 0x30, 0x2C, 0xA0, 0x2A, 0x04,
        0x28,
    ]) + negotiateToken + Data([
        0xA5, 0x22, 0x04, 0x20,
    ]) + clientNonce

    #expect(try RDPCredSSPTSRequest.parse(encoded) == request)
    #expect(request.encoded() == encoded)
}

@Test func ntlmContextWritesCredSSPNegotiateToken() throws {
    let context = RDPCredSSPNTLMContext(
        credentials: RDPCredentials(username: "User", domain: "Domain", password: "Password"),
        randomBytes: { count in Data(repeating: 0, count: count) },
        currentFileTime: { 0 }
    )

    let step = try context.initialize(inputToken: nil)

    #expect(step.isComplete == false)
    #expect(step.outputToken == sspiRSNegotiateToken())
}

@Test func ntlmContextWritesAuthenticateTokenFields() throws {
    var randomCalls = 0
    let context = RDPCredSSPNTLMContext(
        credentials: RDPCredentials(username: "User", domain: "Domain", password: "Password"),
        randomBytes: { count in
            randomCalls += 1
            if randomCalls == 1 {
                return Data([0x20, 0xC0, 0x2B, 0x3D, 0xC0, 0x61, 0xA7, 0x73])
            }
            return Data([
                0xA4, 0xF1, 0xBA, 0xA6, 0x7C, 0xDC, 0x1A, 0x12,
                0x20, 0xC0, 0x2B, 0x3D, 0xC0, 0x61, 0xA7, 0x73,
            ]).prefix(count)
        },
        currentFileTime: { 130_475_779_380_041_523 }
    )
    _ = try context.initialize(inputToken: nil)

    let step = try context.initialize(inputToken: localChallengeMessage())
    let token = try #require(step.outputToken)

    #expect(step.isComplete)
    #expect(token.prefix(12) == Data([
        0x4E, 0x54, 0x4C, 0x4D, 0x53, 0x53, 0x50, 0x00,
        0x03, 0x00, 0x00, 0x00,
    ]))
    #expect(littleEndianUInt32(token, at: 60) == 0xE288_9235)
    #expect(securityBuffer(token, at: 28) == utf16LittleEndian("Domain"))
    #expect(securityBuffer(token, at: 36) == utf16LittleEndian("User"))
    #expect(securityBuffer(token, at: 44).isEmpty)
    #expect(securityBuffer(token, at: 12).count == 24)
    #expect(securityBuffer(token, at: 20).count > 48)
    #expect(securityBuffer(token, at: 52).count == 16)
}

@Test func credSSPTSRequestParsesAuthInfoPubKeyAndNonce() throws {
    let request = RDPCredSSPTSRequest(
        version: 5,
        authInfo: Data([0x10, 0x11]),
        pubKeyAuth: Data([0x20, 0x21]),
        errorCode: 0xC000_006D,
        clientNonce: Data(repeating: 0x7A, count: 32)
    )

    let parsed = try RDPCredSSPTSRequest.parse(request.encoded())

    #expect(parsed.version == 5)
    #expect(parsed.authInfo == Data([0x10, 0x11]))
    #expect(parsed.pubKeyAuth == Data([0x20, 0x21]))
    #expect(parsed.errorCode == 0xC000_006D)
    #expect(parsed.clientNonce == Data(repeating: 0x7A, count: 32))
}

private func sspiRSNegotiateToken() -> Data {
    Data([
        0x4E, 0x54, 0x4C, 0x4D, 0x53, 0x53, 0x50, 0x00,
        0x01, 0x00, 0x00, 0x00,
        0xB7, 0x82, 0x08, 0xE2,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x06, 0x01, 0xB1, 0x1D, 0x00, 0x00, 0x00, 0x0F,
    ])
}

private func localChallengeMessage() -> Data {
    Data([
        0x4E, 0x54, 0x4C, 0x4D, 0x53, 0x53, 0x50, 0x00,
        0x02, 0x00, 0x00, 0x00,
        0x08, 0x00, 0x08, 0x00, 0x38, 0x00, 0x00, 0x00,
        0xB7, 0x82, 0x88, 0xE2,
        0x26, 0x6E, 0xCD, 0x75, 0xAA, 0x41, 0xE7, 0x6F,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x40, 0x00, 0x40, 0x00, 0x40, 0x00, 0x00, 0x00,
        0x06, 0x01, 0xB0, 0x1D, 0x00, 0x00, 0x00, 0x0F,
        0x57, 0x00, 0x49, 0x00, 0x4E, 0x00, 0x37, 0x00,
        0x02, 0x00, 0x08, 0x00, 0x57, 0x00, 0x49, 0x00,
        0x4E, 0x00, 0x37, 0x00, 0x01, 0x00, 0x08, 0x00,
        0x57, 0x00, 0x49, 0x00, 0x4E, 0x00, 0x37, 0x00,
        0x04, 0x00, 0x08, 0x00, 0x77, 0x00, 0x69, 0x00,
        0x6E, 0x00, 0x37, 0x00, 0x03, 0x00, 0x08, 0x00,
        0x77, 0x00, 0x69, 0x00, 0x6E, 0x00, 0x37, 0x00,
        0x07, 0x00, 0x08, 0x00, 0xA9, 0x8D, 0x9B, 0x1A,
        0x6C, 0xB0, 0xCB, 0x01, 0x00, 0x00, 0x00, 0x00,
    ])
}

private func securityBuffer(_ data: Data, at offset: Int) -> Data {
    let length = Int(littleEndianUInt16(data, at: offset))
    let bufferOffset = Int(littleEndianUInt32(data, at: offset + 4))
    let start = data.index(data.startIndex, offsetBy: bufferOffset)
    return data.subdata(in: start ..< data.index(start, offsetBy: length))
}

private func littleEndianUInt16(_ data: Data, at offset: Int) -> UInt16 {
    UInt16(data[data.index(data.startIndex, offsetBy: offset)])
        | UInt16(data[data.index(data.startIndex, offsetBy: offset + 1)]) << 8
}

private func littleEndianUInt32(_ data: Data, at offset: Int) -> UInt32 {
    UInt32(data[data.index(data.startIndex, offsetBy: offset)])
        | UInt32(data[data.index(data.startIndex, offsetBy: offset + 1)]) << 8
        | UInt32(data[data.index(data.startIndex, offsetBy: offset + 2)]) << 16
        | UInt32(data[data.index(data.startIndex, offsetBy: offset + 3)]) << 24
}

private func utf16LittleEndian(_ value: String) -> Data {
    var data = Data()
    for codeUnit in value.utf16 {
        data.appendLittleEndianUInt16(codeUnit)
    }
    return data
}

@Test func credSSPPasswordCredentialsUseTSPasswordCreds() {
    let credentials = RDPCredentials(username: "hello", domain: "WIN", password: "secret")
    let encoded = RDPCredSSPCredentials.passwordCredentials(credentials)

    #expect(encoded.starts(with: Data([
        0x30,
        0x33,
        0xA0, 0x03, 0x02, 0x01, 0x01,
        0xA1,
    ])))
    #expect(encoded.contains(Data([0x57, 0x00, 0x49, 0x00, 0x4E, 0x00])))
    #expect(encoded.contains(Data([0x68, 0x00, 0x65, 0x00, 0x6C, 0x00, 0x6C, 0x00, 0x6F, 0x00])))
    #expect(encoded.contains(Data([
        0x73, 0x00, 0x65, 0x00, 0x63, 0x00, 0x72, 0x00, 0x65, 0x00, 0x74, 0x00,
    ])))
}

@Test func credSSPCertificateExtractsSubjectPublicKeyBitStringPayload() throws {
    let rsaPublicKey = Data([
        0x30, 0x0A,
        0x02, 0x03, 0x01, 0x00, 0x01,
        0x02, 0x03, 0x01, 0x00, 0x01,
    ])
    let subjectPublicKeyInfo = sequence(
        sequence(Data([
            0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01,
            0x05, 0x00,
        ]))
            + bitString(unusedBits: 0, payload: rsaPublicKey)
    )
    let certificate = sequence(
        sequence(
            context(0, Data([0x02, 0x01, 0x02]))
                + Data([0x02, 0x01, 0x01])
                + sequence(Data([0x06, 0x01, 0x2A]))
                + sequence(Data())
                + sequence(Data())
                + sequence(Data())
                + subjectPublicKeyInfo
        )
            + sequence(Data([0x06, 0x01, 0x2A]))
            + bitString(unusedBits: 0, payload: Data([0x00]))
    )

    #expect(try RDPCredSSPCertificate.subjectPublicKey(fromCertificateDER: certificate) == rsaPublicKey)
}

private func sequence(_ payload: Data) -> Data {
    wrap(tag: 0x30, payload)
}

private func context(_ number: UInt8, _ payload: Data) -> Data {
    wrap(tag: 0xA0 + number, payload)
}

private func bitString(unusedBits: UInt8, payload: Data) -> Data {
    wrap(tag: 0x03, Data([unusedBits]) + payload)
}

private func wrap(tag: UInt8, _ payload: Data) -> Data {
    var data = Data([tag])
    if payload.count < 0x80 {
        data.append(UInt8(payload.count))
    } else {
        data.append(0x81)
        data.append(UInt8(payload.count))
    }
    data.append(payload)
    return data
}
