import Foundation
import CryptoKit
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
    #expect(encoded.contains(Data("NTLMSSP\u{0}".utf8)))
    #expect(!encoded.contains(Data([0x06, 0x06, 0x2B, 0x06, 0x01, 0x05, 0x05, 0x02])))
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

@Test func spnegoWrapsAndExtractsNTLMNegotiateToken() throws {
    let token = sspiRSNegotiateToken()
    let spnego = RDPSPNEGO.negTokenInit(mechToken: token)

    #expect(spnego.prefix(2) == Data([0x60, 0x48]))
    #expect(spnego.dropFirst(2).prefix(8) == Data([
        0x06, 0x06,
        0x2B, 0x06, 0x01, 0x05, 0x05, 0x02,
    ]))
    #expect(try RDPSPNEGO.mechanismToken(from: spnego) == token)
}

@Test func spnegoWrapsAndExtractsNTLMResponseToken() throws {
    let token = Data("NTLMSSP\u{0}response".utf8)
    let spnego = RDPSPNEGO.negTokenResponse(responseToken: token)

    #expect(spnego.prefix(5) == Data([
        0xA1, 0x16,
        0x30, 0x14,
        0xA2,
    ]))
    #expect(try RDPSPNEGO.mechanismToken(from: spnego) == token)
}

@Test func spnegoStillAcceptsRawNTLMTokenForCompatibility() throws {
    let token = Data("NTLMSSP\u{0}raw".utf8)

    #expect(try RDPSPNEGO.mechanismToken(from: token) == token)
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
    #expect(securityBuffer(token, at: 44) == utf16LittleEndian("KRDPSWIFT"))
    #expect(securityBuffer(token, at: 12).count == 24)
    #expect(securityBuffer(token, at: 12) != Data(repeating: 0, count: 24))
    #expect(securityBuffer(token, at: 20).count > 48)
    #expect(securityBuffer(token, at: 52).count == 16)
}

@Test func ntlmContextUsesConfiguredWorkstationNameWhenVersionNegotiated() throws {
    let context = RDPCredSSPNTLMContext(
        credentials: RDPCredentials(username: "User", domain: "Domain", password: "Password"),
        workstationName: "MACBOOK",
        randomBytes: { count in Data(repeating: 0xA4, count: count) },
        currentFileTime: { 130_475_779_380_041_523 }
    )
    _ = try context.initialize(inputToken: nil)

    let step = try context.initialize(inputToken: localChallengeMessage())
    let token = try #require(step.outputToken)

    #expect(securityBuffer(token, at: 44) == utf16LittleEndian("MACBOOK"))
    #expect(Data(token[64 ..< 72]) == Data([0x06, 0x01, 0xB1, 0x1D, 0x00, 0x00, 0x00, 0x0F]))
}

@Test func ntlmContextSendsLMv2ResponseWhenChallengeIncludesTimestamp() throws {
    var randomCalls = 0
    let context = RDPCredSSPNTLMContext(
        credentials: RDPCredentials(username: "User", domain: "Domain", password: "Password"),
        randomBytes: { count in
            randomCalls += 1
            if randomCalls == 1 {
                return Data([0x20, 0xC0, 0x2B, 0x3D, 0xC0, 0x61, 0xA7, 0x73])
            }
            return Data(repeating: 0xA4, count: count)
        },
        currentFileTime: { 130_475_779_380_041_523 }
    )
    _ = try context.initialize(inputToken: nil)

    let step = try context.initialize(inputToken: localChallengeMessage())
    let token = try #require(step.outputToken)
    let lmResponse = securityBuffer(token, at: 12)

    #expect(lmResponse.count == 24)
    #expect(lmResponse != Data(repeating: 0, count: 24))
    #expect(lmResponse.suffix(8) == Data([0x20, 0xC0, 0x2B, 0x3D, 0xC0, 0x61, 0xA7, 0x73]))
}

@Test func ntlmContextSendsLMv2ResponseWhenChallengeOmitsTimestamp() throws {
    var randomCalls = 0
    let context = RDPCredSSPNTLMContext(
        credentials: RDPCredentials(username: "User", domain: "Domain", password: "Password"),
        randomBytes: { count in
            randomCalls += 1
            if randomCalls == 1 {
                return Data([0x20, 0xC0, 0x2B, 0x3D, 0xC0, 0x61, 0xA7, 0x73])
            }
            return Data(repeating: 0xA4, count: count)
        },
        currentFileTime: { 130_475_779_380_041_523 }
    )
    _ = try context.initialize(inputToken: nil)

    let step = try context.initialize(inputToken: localChallengeMessageWithoutTimestamp())
    let token = try #require(step.outputToken)
    let lmResponse = securityBuffer(token, at: 12)

    #expect(lmResponse.count == 24)
    #expect(lmResponse != Data(repeating: 0, count: 24))
    #expect(lmResponse.suffix(8) == Data([0x20, 0xC0, 0x2B, 0x3D, 0xC0, 0x61, 0xA7, 0x73]))
}

@Test func ntlmContextUpdatesExistingMsvAvFlagsForMIC() throws {
    var randomCalls = 0
    let context = RDPCredSSPNTLMContext(
        credentials: RDPCredentials(username: "User", domain: "Domain", password: "Password"),
        randomBytes: { count in
            randomCalls += 1
            if randomCalls == 1 {
                return Data([0x20, 0xC0, 0x2B, 0x3D, 0xC0, 0x61, 0xA7, 0x73])
            }
            return Data(repeating: 0xA4, count: count)
        },
        currentFileTime: { 130_475_779_380_041_523 }
    )
    _ = try context.initialize(inputToken: nil)

    let step = try context.initialize(inputToken: localChallengeMessageWithExistingMsvAvFlags())
    let token = try #require(step.outputToken)
    let targetInfo = ntlmV2TargetInfo(fromAuthenticateToken: token)

    #expect(msvAvFlagsValues(in: targetInfo) == [0x0000_0003])
}

@Test func ntlmContextOmitsChannelBindingsWhenCBTIsUnavailable() throws {
    var randomCalls = 0
    let context = RDPCredSSPNTLMContext(
        credentials: RDPCredentials(username: "User", domain: "Domain", password: "Password"),
        randomBytes: { count in
            randomCalls += 1
            if randomCalls == 1 {
                return Data([0x20, 0xC0, 0x2B, 0x3D, 0xC0, 0x61, 0xA7, 0x73])
            }
            return Data(repeating: 0xA4, count: count)
        },
        currentFileTime: { 130_475_779_380_041_523 }
    )
    _ = try context.initialize(inputToken: nil)

    let step = try context.initialize(inputToken: localChallengeMessage())
    let token = try #require(step.outputToken)
    let targetInfo = ntlmV2TargetInfo(fromAuthenticateToken: token)

    #expect(msvAvChannelBindingsValues(in: targetInfo).isEmpty)
}

@Test func ntlmContextAddsConfiguredChannelBindingsHash() throws {
    var randomCalls = 0
    let channelBindingsHash = Data(0x10 ..< 0x20)
    let context = RDPCredSSPNTLMContext(
        credentials: RDPCredentials(username: "User", domain: "Domain", password: "Password"),
        channelBindingsHash: channelBindingsHash,
        randomBytes: { count in
            randomCalls += 1
            if randomCalls == 1 {
                return Data([0x20, 0xC0, 0x2B, 0x3D, 0xC0, 0x61, 0xA7, 0x73])
            }
            return Data(repeating: 0xA4, count: count)
        },
        currentFileTime: { 130_475_779_380_041_523 }
    )
    _ = try context.initialize(inputToken: nil)

    let step = try context.initialize(inputToken: localChallengeMessage())
    let token = try #require(step.outputToken)
    let targetInfo = ntlmV2TargetInfo(fromAuthenticateToken: token)

    #expect(msvAvChannelBindingsValues(in: targetInfo) == [channelBindingsHash])
}

@Test func ntlmContextPadsAuthenticateTargetInfoAfterMsvAvEOL() throws {
    var randomCalls = 0
    let context = RDPCredSSPNTLMContext(
        credentials: RDPCredentials(username: "User", domain: "Domain", password: "Password"),
        randomBytes: { count in
            randomCalls += 1
            if randomCalls == 1 {
                return Data([0x20, 0xC0, 0x2B, 0x3D, 0xC0, 0x61, 0xA7, 0x73])
            }
            return Data(repeating: 0xA4, count: count)
        },
        currentFileTime: { 130_475_779_380_041_523 }
    )
    _ = try context.initialize(inputToken: nil)

    let step = try context.initialize(inputToken: localChallengeMessage())
    let token = try #require(step.outputToken)
    let targetInfo = ntlmV2TargetInfo(fromAuthenticateToken: token)

    #expect(terminatingMsvAvEOLOffset(in: targetInfo) == targetInfo.count - 4)
    #expect(targetInfo.suffix(4) == Data(repeating: 0, count: 4))
}

@Test func ntlmContextPreservesServerSuppliedChannelBindingsAVPair() throws {
    var randomCalls = 0
    let context = RDPCredSSPNTLMContext(
        credentials: RDPCredentials(username: "User", domain: "Domain", password: "Password"),
        randomBytes: { count in
            randomCalls += 1
            if randomCalls == 1 {
                return Data([0x20, 0xC0, 0x2B, 0x3D, 0xC0, 0x61, 0xA7, 0x73])
            }
            return Data(repeating: 0xA4, count: count)
        },
        currentFileTime: { 130_475_779_380_041_523 }
    )
    _ = try context.initialize(inputToken: nil)

    let bindings = Data(0x10 ..< 0x20)
    let step = try context.initialize(inputToken: localChallengeMessageWithChannelBindings(bindings))
    let token = try #require(step.outputToken)
    let targetInfo = ntlmV2TargetInfo(fromAuthenticateToken: token)

    #expect(msvAvChannelBindingsValues(in: targetInfo) == [bindings])
}

@Test func ntlmContextAuthenticateFlagsFollowServerNegotiation() throws {
    var randomCalls = 0
    let context = RDPCredSSPNTLMContext(
        credentials: RDPCredentials(username: "User", domain: "Domain", password: "Password"),
        randomBytes: { count in
            randomCalls += 1
            if randomCalls == 1 {
                return Data([0x20, 0xC0, 0x2B, 0x3D, 0xC0, 0x61, 0xA7, 0x73])
            }
            return Data(repeating: 0xA4, count: count)
        },
        currentFileTime: { 130_475_779_380_041_523 }
    )
    _ = try context.initialize(inputToken: nil)

    var challenge = localChallengeMessage()
    let serverFlags = UInt32(0x0000_0001)
        | UInt32(0x0000_0004)
        | UInt32(0x0000_0010)
        | UInt32(0x0000_0020)
        | UInt32(0x0000_0200)
        | UInt32(0x0000_8000)
        | UInt32(0x0008_0000)
        | UInt32(0x0080_0000)
        | UInt32(0x4000_0000)
    replaceLittleEndianUInt32(in: &challenge, at: 20, with: serverFlags)

    let step = try context.initialize(inputToken: challenge)
    let token = try #require(step.outputToken)

    #expect(littleEndianUInt32(token, at: 60) == serverFlags | 0x0000_1000)
    #expect(Data(token[64 ..< 72]) == Data(repeating: 0, count: 8))
    #expect(securityBuffer(token, at: 44).isEmpty)
}

@Test func ntlmContextSealingKeyFollowsNegotiatedKeyStrength() throws {
    let challengeFlags = littleEndianUInt32(localChallengeMessage(), at: 20)

    let sealed128 = try sealedNTLMMessage(challengeFlags: challengeFlags)
    let sealed56 = try sealedNTLMMessage(challengeFlags: challengeFlags & ~UInt32(0x2000_0000))
    let sealed40 = try sealedNTLMMessage(challengeFlags: challengeFlags & ~UInt32(0xA000_0000))

    #expect(sealed128.count == 20)
    #expect(sealed56.count == 20)
    #expect(sealed40.count == 20)
    #expect(sealed128 != sealed56)
    #expect(sealed56 != sealed40)
    #expect(sealed128 != sealed40)
}

@Test func ntlmContextRejectsTargetInfoWithoutTerminator() throws {
    let challenge = challengeMessage(
        replacingTargetInfo: Data(securityBuffer(localChallengeMessage(), at: 40).dropLast(4))
    )

    try expectNTLMFailure(for: challenge, containing: "missing NTLM target info terminator")
}

@Test func ntlmContextRejectsTargetInfoWithTrailingAVPairsAfterTerminator() throws {
    var targetInfo = securityBuffer(localChallengeMessage(), at: 40)
    targetInfo.append(Data([
        0x06, 0x00,
        0x04, 0x00,
        0x00, 0x00, 0x00, 0x00,
    ]))

    try expectNTLMFailure(
        for: challengeMessage(replacingTargetInfo: targetInfo),
        containing: "invalid NTLM target info terminator"
    )
}

@Test func ntlmContextRejectsChallengeWithoutUnicodeNegotiation() throws {
    var challenge = localChallengeMessage()
    replaceLittleEndianUInt32(
        in: &challenge,
        at: 20,
        with: littleEndianUInt32(challenge, at: 20) & ~UInt32(0x0000_0001)
    )

    try expectNTLMFailure(
        for: challenge,
        containing: "server did not negotiate NTLM Unicode encoding"
    )
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

@Test func credSSPPublicKeyBindingHashesUseDirectionNonceAndSubjectPublicKey() {
    let subjectPublicKey = Data([0x30, 0x03, 0x02, 0x01, 0x01])
    let nonce = Data(0x00 ..< 0x20)
    let otherNonce = Data(0x20 ..< 0x40)

    var clientInput = Data("CredSSP Client-To-Server Binding Hash".utf8)
    clientInput.append(0)
    clientInput.append(nonce)
    clientInput.append(subjectPublicKey)
    var serverInput = Data("CredSSP Server-To-Client Binding Hash".utf8)
    serverInput.append(0)
    serverInput.append(nonce)
    serverInput.append(subjectPublicKey)

    let clientHash = RDPCredSSPPublicKeyBinding.clientServerHash(
        subjectPublicKey: subjectPublicKey,
        nonce: nonce
    )
    let serverHash = RDPCredSSPPublicKeyBinding.serverClientHash(
        subjectPublicKey: subjectPublicKey,
        nonce: nonce
    )

    #expect(clientHash == Data(SHA256.hash(data: clientInput)))
    #expect(serverHash == Data(SHA256.hash(data: serverInput)))
    #expect(clientHash != serverHash)
    #expect(RDPCredSSPPublicKeyBinding.clientServerHash(
        subjectPublicKey: subjectPublicKey,
        nonce: otherNonce
    ) != clientHash)
}

@Test func credSSPLegacyPublicKeyResponseIncrementsFirstByte() throws {
    #expect(try RDPCredSSPPublicKeyBinding.legacyServerResponse(
        subjectPublicKey: Data([0xFE, 0x01, 0x02])
    ) == Data([0xFF, 0x01, 0x02]))

    #expect(throws: RDPDecodeError.invalidCredSSPMessage) {
        try RDPCredSSPPublicKeyBinding.legacyServerResponse(subjectPublicKey: Data())
    }
}

@Test func credSSPTSRequestRejectsDuplicateFields() {
    let encoded = sequence(
        context(0, integer(6))
            + context(0, integer(5))
    )

    #expect(throws: RDPDecodeError.invalidCredSSPMessage) {
        try RDPCredSSPTSRequest.parse(encoded)
    }
}

@Test func credSSPTSRequestRejectsVersionBelowProtocolMinimum() {
    let encoded = sequence(context(0, integer(1)))

    #expect(throws: RDPDecodeError.invalidCredSSPMessage) {
        try RDPCredSSPTSRequest.parse(encoded)
    }
}

@Test func credSSPTSRequestRejectsNonMinimalDERInteger() {
    let encoded = sequence(context(0, Data([
        0x02, 0x02,
        0x00, 0x06,
    ])))

    #expect(throws: RDPDecodeError.invalidCredSSPMessage) {
        try RDPCredSSPTSRequest.parse(encoded)
    }
}

@Test func credSSPTSRequestAcceptsDERIntegerWithSignProtectionByte() throws {
    let encoded = sequence(context(0, Data([
        0x02, 0x02,
        0x00, 0x80,
    ])))

    #expect(try RDPCredSSPTSRequest.parse(encoded).version == 128)
}

@Test func credSSPTSRequestAcceptsHigherPeerVersion() throws {
    let encoded = sequence(context(0, integer(7)))

    #expect(try RDPCredSSPTSRequest.parse(encoded).version == 7)
}

@Test func credSSPTSRequestRejectsInvalidClientNonceLength() {
    let encoded = sequence(
        context(0, integer(6))
            + context(5, octetString(Data(repeating: 0xAA, count: 31)))
    )

    #expect(throws: RDPDecodeError.invalidCredSSPMessage) {
        try RDPCredSSPTSRequest.parse(encoded)
    }
}

@Test func credSSPTSRequestRejectsOversizedErrorCode() {
    let encoded = sequence(
        context(0, integer(6))
            + context(4, Data([
                0x02, 0x05,
                0x01, 0x00, 0x00, 0x00, 0x00,
            ]))
    )

    #expect(throws: RDPDecodeError.invalidCredSSPMessage) {
        try RDPCredSSPTSRequest.parse(encoded)
    }
}

@Test func credSSPTSRequestRejectsNonMinimalDERLengths() {
    let longFormShortLength = Data([
        0x30, 0x81, 0x05,
        0xA0, 0x03,
        0x02, 0x01, 0x06,
    ])
    let leadingZeroLongLength = Data([
        0x30, 0x82, 0x00, 0x05,
        0xA0, 0x03,
        0x02, 0x01, 0x06,
    ])

    #expect(throws: RDPDecodeError.invalidBERLength) {
        try RDPCredSSPTSRequest.parse(longFormShortLength)
    }
    #expect(throws: RDPDecodeError.invalidBERLength) {
        try RDPCredSSPTSRequest.parse(leadingZeroLongLength)
    }
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

private func localChallengeMessageWithExistingMsvAvFlags() -> Data {
    var message = localChallengeMessage()
    let existingFlags = Data([
        0x06, 0x00, 0x04, 0x00,
        0x01, 0x00, 0x00, 0x00,
    ])
    message.insert(contentsOf: existingFlags, at: message.count - 4)
    message[40] = 0x48
    message[42] = 0x48
    return message
}

private func localChallengeMessageWithoutTimestamp() -> Data {
    let timestampAVPair = Data([
        0x07, 0x00,
        0x08, 0x00,
        0xA9, 0x8D, 0x9B, 0x1A,
        0x6C, 0xB0, 0xCB, 0x01,
    ])
    var targetInfo = securityBuffer(localChallengeMessage(), at: 40)
    if let timestampRange = targetInfo.range(of: timestampAVPair) {
        targetInfo.removeSubrange(timestampRange)
    }
    return challengeMessage(replacingTargetInfo: targetInfo)
}

private func localChallengeMessageWithChannelBindings(_ bindings: Data) -> Data {
    var targetInfo = securityBuffer(localChallengeMessage(), at: 40)
    targetInfo.insert(contentsOf: Data([
        0x0A, 0x00,
        UInt8(bindings.count & 0xFF), UInt8((bindings.count >> 8) & 0xFF),
    ]) + bindings, at: targetInfo.count - 4)
    return challengeMessage(replacingTargetInfo: targetInfo)
}

private func securityBuffer(_ data: Data, at offset: Int) -> Data {
    guard offset + 8 <= data.count else {
        Issue.record("truncated security buffer header")
        return Data()
    }
    let length = Int(littleEndianUInt16(data, at: offset))
    let bufferOffset = Int(littleEndianUInt32(data, at: offset + 4))
    guard bufferOffset <= data.count, length <= data.count - bufferOffset else {
        Issue.record("invalid security buffer range")
        return Data()
    }
    let start = data.index(data.startIndex, offsetBy: bufferOffset)
    return data.subdata(in: start ..< data.index(start, offsetBy: length))
}

private func ntlmV2TargetInfo(fromAuthenticateToken token: Data) -> Data {
    let ntResponse = securityBuffer(token, at: 20)
    guard ntResponse.count >= 44 else {
        Issue.record("NTLMv2 response is too short")
        return Data()
    }
    return Data(ntResponse.dropFirst(44))
}

private func msvAvFlagsValues(in targetInfo: Data) -> [UInt32] {
    var values: [UInt32] = []
    var offset = 0
    while offset + 4 <= targetInfo.count {
        let avID = littleEndianUInt16(targetInfo, at: offset)
        let length = Int(littleEndianUInt16(targetInfo, at: offset + 2))
        offset += 4
        if avID == 0 {
            break
        }
        if avID == 6, length == 4 {
            values.append(littleEndianUInt32(targetInfo, at: offset))
        }
        offset += length
    }
    return values
}

private func msvAvChannelBindingsValues(in targetInfo: Data) -> [Data] {
    avPairValues(avID: 10, in: targetInfo)
}

private func terminatingMsvAvEOLOffset(in targetInfo: Data) -> Int? {
    var offset = 0
    while offset + 4 <= targetInfo.count {
        let avID = littleEndianUInt16(targetInfo, at: offset)
        let length = Int(littleEndianUInt16(targetInfo, at: offset + 2))
        offset += 4
        if avID == 0 {
            return length == 0 ? offset : nil
        }
        guard length <= targetInfo.count - offset else {
            Issue.record("truncated AV pair \(avID)")
            return nil
        }
        offset += length
    }
    return nil
}

private func avPairValues(avID expectedAVID: UInt16, in targetInfo: Data) -> [Data] {
    var values: [Data] = []
    var offset = 0
    while offset + 4 <= targetInfo.count {
        let avID = littleEndianUInt16(targetInfo, at: offset)
        let length = Int(littleEndianUInt16(targetInfo, at: offset + 2))
        offset += 4
        if avID == 0 {
            break
        }
        guard length <= targetInfo.count - offset else {
            Issue.record("truncated AV pair \(avID)")
            break
        }
        let value = targetInfo.subdata(in: offset ..< offset + length)
        if avID == expectedAVID {
            values.append(value)
        }
        offset += length
    }
    return values
}

private func challengeMessage(replacingTargetInfo targetInfo: Data) -> Data {
    var message = localChallengeMessage()
    let targetInfoOffset = Int(littleEndianUInt32(message, at: 44))
    replaceLittleEndianUInt16(in: &message, at: 40, with: UInt16(targetInfo.count))
    replaceLittleEndianUInt16(in: &message, at: 42, with: UInt16(targetInfo.count))
    message.replaceSubrange(message.index(message.startIndex, offsetBy: targetInfoOffset) ..< message.endIndex, with: targetInfo)
    return message
}

private func expectNTLMFailure(for challenge: Data, containing expectedMessage: String) throws {
    let context = RDPCredSSPNTLMContext(
        credentials: RDPCredentials(username: "User", domain: "Domain", password: "Password"),
        randomBytes: { count in Data(repeating: 0, count: count) },
        currentFileTime: { 0 }
    )
    _ = try context.initialize(inputToken: nil)

    do {
        _ = try context.initialize(inputToken: challenge)
        #expect(Bool(false))
    } catch let error as RDPCredSSPError {
        #expect(String(describing: error).contains(expectedMessage))
    } catch {
        #expect(Bool(false))
    }
}

private func sealedNTLMMessage(challengeFlags: UInt32) throws -> Data {
    let context = RDPCredSSPNTLMContext(
        credentials: RDPCredentials(username: "User", domain: "Domain", password: "Password"),
        randomBytes: { count in Data(0 ..< UInt8(count)) },
        currentFileTime: { 130_475_779_380_041_523 }
    )
    _ = try context.initialize(inputToken: nil)
    var challenge = localChallengeMessage()
    replaceLittleEndianUInt32(in: &challenge, at: 20, with: challengeFlags)
    _ = try context.initialize(inputToken: challenge)
    return try context.wrap(Data([0x01, 0x02, 0x03, 0x04]))
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

private func replaceLittleEndianUInt16(in data: inout Data, at offset: Int, with value: UInt16) {
    data[data.index(data.startIndex, offsetBy: offset)] = UInt8(value & 0x00FF)
    data[data.index(data.startIndex, offsetBy: offset + 1)] = UInt8((value >> 8) & 0x00FF)
}

private func replaceLittleEndianUInt32(in data: inout Data, at offset: Int, with value: UInt32) {
    data[data.index(data.startIndex, offsetBy: offset)] = UInt8(value & 0x0000_00FF)
    data[data.index(data.startIndex, offsetBy: offset + 1)] = UInt8((value >> 8) & 0x0000_00FF)
    data[data.index(data.startIndex, offsetBy: offset + 2)] = UInt8((value >> 16) & 0x0000_00FF)
    data[data.index(data.startIndex, offsetBy: offset + 3)] = UInt8((value >> 24) & 0x0000_00FF)
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

@Test func credSSPCertificateExtractsSubjectPublicKeyContents() throws {
    let rsaPublicKey = Data([
        0x30, 0x0A,
        0x02, 0x03, 0x01, 0x00, 0x01,
        0x02, 0x03, 0x01, 0x00, 0x01,
    ])
    let subjectPublicKey = bitString(unusedBits: 0, payload: rsaPublicKey)
    let subjectPublicKeyInfo = sequence(
        sequence(Data([
            0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01,
            0x05, 0x00,
        ]))
            + subjectPublicKey
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

@Test func credSSPCertificateRejectsSubjectPublicKeyWithUnusedBits() throws {
    let subjectPublicKeyInfo = sequence(
        sequence(Data([
            0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01,
            0x05, 0x00,
        ]))
            + bitString(unusedBits: 1, payload: Data([0x30, 0x03, 0x02, 0x01, 0x01]))
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

    #expect(throws: RDPDecodeError.invalidCredSSPMessage) {
        try RDPCredSSPCertificate.subjectPublicKey(fromCertificateDER: certificate)
    }
}

@Test func credSSPCertificateComputesNTLMChannelBindingsHash() throws {
    let certificate = testCertificate(signatureAlgorithm: Data([
        0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0B,
        0x05, 0x00,
    ]))

    #expect(try RDPCredSSPCertificate.ntlmChannelBindingsHash(fromCertificateDER: certificate)
        == ntlmChannelBindingsHash(certificateDigest: Data(SHA256.hash(data: certificate))))
}

@Test func credSSPCertificateUsesSHA256ChannelBindingForSHA1Signature() throws {
    let certificate = testCertificate(signatureAlgorithm: Data([
        0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x05,
        0x05, 0x00,
    ]))

    #expect(try RDPCredSSPCertificate.ntlmChannelBindingsHash(fromCertificateDER: certificate)
        == ntlmChannelBindingsHash(certificateDigest: Data(SHA256.hash(data: certificate))))
}

@Test func credSSPCertificateUsesSHA384ChannelBindingForSHA384Signatures() throws {
    let rsaCertificate = testCertificate(signatureAlgorithm: Data([
        0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0C,
        0x05, 0x00,
    ]))
    let ecdsaCertificate = testCertificate(signatureAlgorithm: Data([
        0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x03,
    ]))

    #expect(try RDPCredSSPCertificate.ntlmChannelBindingsHash(fromCertificateDER: rsaCertificate)
        == ntlmChannelBindingsHash(certificateDigest: Data(SHA384.hash(data: rsaCertificate))))
    #expect(try RDPCredSSPCertificate.ntlmChannelBindingsHash(fromCertificateDER: ecdsaCertificate)
        == ntlmChannelBindingsHash(certificateDigest: Data(SHA384.hash(data: ecdsaCertificate))))
}

@Test func credSSPCertificateUsesSHA512ChannelBindingForSHA512Signatures() throws {
    let rsaCertificate = testCertificate(signatureAlgorithm: Data([
        0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0D,
        0x05, 0x00,
    ]))
    let ecdsaCertificate = testCertificate(signatureAlgorithm: Data([
        0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x04,
    ]))

    #expect(try RDPCredSSPCertificate.ntlmChannelBindingsHash(fromCertificateDER: rsaCertificate)
        == ntlmChannelBindingsHash(certificateDigest: Data(SHA512.hash(data: rsaCertificate))))
    #expect(try RDPCredSSPCertificate.ntlmChannelBindingsHash(fromCertificateDER: ecdsaCertificate)
        == ntlmChannelBindingsHash(certificateDigest: Data(SHA512.hash(data: ecdsaCertificate))))
}

private func ntlmChannelBindingsHash(certificateDigest: Data) -> Data {
    let token = Data("tls-server-end-point:".utf8) + certificateDigest
    var bindings = Data()
    bindings.appendLittleEndianUInt32(0)
    bindings.appendLittleEndianUInt32(0)
    bindings.appendLittleEndianUInt32(0)
    bindings.appendLittleEndianUInt32(0)
    bindings.appendLittleEndianUInt32(UInt32(token.count))
    bindings.append(token)
    return Data(Insecure.MD5.hash(data: bindings))
}

private func testCertificate(signatureAlgorithm: Data) -> Data {
    let subjectPublicKeyInfo = sequence(
        sequence(Data([
            0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01,
            0x05, 0x00,
        ]))
            + bitString(unusedBits: 0, payload: Data([0x01, 0x02, 0x03]))
    )
    return sequence(
        sequence(
            context(0, Data([0x02, 0x01, 0x02]))
                + Data([0x02, 0x01, 0x01])
                + sequence(signatureAlgorithm)
                + sequence(Data())
                + sequence(Data())
                + sequence(Data())
                + subjectPublicKeyInfo
        )
            + sequence(signatureAlgorithm)
            + bitString(unusedBits: 0, payload: Data([0x00]))
    )
}

private func sequence(_ payload: Data) -> Data {
    wrap(tag: 0x30, payload)
}

private func context(_ number: UInt8, _ payload: Data) -> Data {
    wrap(tag: 0xA0 + number, payload)
}

private func integer(_ value: Int) -> Data {
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

private func octetString(_ value: Data) -> Data {
    wrap(tag: 0x04, value)
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
