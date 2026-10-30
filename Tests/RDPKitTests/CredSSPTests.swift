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

@Test func spnegoRejectsInitiatorTokenFromServer() {
    let ntlmOID = Data([0x06, 0x0A, 0x2B, 0x06, 0x01, 0x04, 0x01, 0x82, 0x37, 0x02, 0x02, 0x0A])
    let spnegoOID = Data([0x06, 0x06, 0x2B, 0x06, 0x01, 0x05, 0x05, 0x02])
    let negTokenInit = context(0, sequence(
        context(0, sequence(ntlmOID)) + context(2, octetString(Data("NTLMSSP\u{0}".utf8)))
    ))

    #expect(throws: RDPDecodeError.self) {
        try RDPSPNEGO.mechanismToken(from: wrap(tag: 0x60, spnegoOID + negTokenInit))
    }
}

@Test func spnegoExtractsNTLMResponseTokenFromNegTokenResp() throws {
    let token = Data("NTLMSSP\u{0}response".utf8)
    // NegTokenResp with only responseToken [2] (MS-CSSP 2.2.1.1, RFC 4178 4.2.2).
    let spnego = Data([0xA1, 0x16, 0x30, 0x14, 0xA2, 0x12, 0x04, 0x10]) + token

    #expect(try RDPSPNEGO.mechanismToken(from: spnego) == token)
}

@Test func spnegoAcceptsRawNTLMToken() throws {
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
    #expect(token.littleEndianUInt32(at: 60) == 0xE288_9235)
    #expect(securityBuffer(token, at: 28) == utf16LittleEndian("Domain"))
    #expect(securityBuffer(token, at: 36) == utf16LittleEndian("User"))
    #expect(securityBuffer(token, at: 44) == utf16LittleEndian("RDPKIT"))
    #expect(securityBuffer(token, at: 12) == Data(count: 24))
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

@Test func ntlmContextSendsZeroLMResponseWhenChallengeIncludesTimestamp() throws {
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

    #expect(securityBuffer(token, at: 12) == Data(count: 24))
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

@Test func ntlmContextReplacesServerSuppliedChannelBindingsAVPair() throws {
    var randomCalls = 0
    let channelBindingsHash = Data(0x30 ..< 0x40)
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

    let bindings = Data(0x10 ..< 0x20)
    let step = try context.initialize(inputToken: localChallengeMessageWithChannelBindings(bindings))
    let token = try #require(step.outputToken)
    let targetInfo = ntlmV2TargetInfo(fromAuthenticateToken: token)

    #expect(msvAvChannelBindingsValues(in: targetInfo) == [channelBindingsHash])
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

    #expect(token.littleEndianUInt32(at: 60) == serverFlags | 0x0000_1000)
    #expect(Data(token[64 ..< 72]) == Data(repeating: 0, count: 8))
    // Without NTLMSSP_NEGOTIATE_VERSION only the Version is zeroed: this client set the flag
    // in its NEGOTIATE_MESSAGE, so it still sends its name ([MS-NLMP] 3.1.5.1.2).
    #expect(securityBuffer(token, at: 44) == utf16LittleEndian("RDPKIT"))
}

/// The MIC is HMAC_MD5 of the ExportedSessionKey over the NEGOTIATE, CHALLENGE and
/// AUTHENTICATE messages, the last with its MIC zeroed ([MS-NLMP] 3.1.5.1.2): the Workstation
/// in the payload is covered.
@Test func ntlmContextMICCoversTheWorkstation() throws {
    let context = RDPCredSSPNTLMContext(
        credentials: RDPCredentials(username: "User", domain: "Domain", password: "Password"),
        workstationName: "MACBOOK",
        randomBytes: { count in Data(repeating: count == 8 ? 0xAA : 0x55, count: count) },
        currentFileTime: { 0 }
    )
    let negotiate = try #require(context.initialize(inputToken: nil).outputToken)
    let challenge = localChallengeMessage()
    let token = try #require(context.initialize(inputToken: challenge).outputToken)
    var zeroedMIC = token
    zeroedMIC.replaceSubrange(72 ..< 88, with: Data(count: 16))
    // NTLMSSP_NEGOTIATE_KEY_EXCH is negotiated, so the ExportedSessionKey is the client's random key.
    let exportedSessionKey = SymmetricKey(data: Data(repeating: 0x55, count: 16))
    let mic = HMAC<Insecure.MD5>.authenticationCode(for: negotiate + challenge + zeroedMIC, using: exportedSessionKey)

    #expect(securityBuffer(token, at: 44) == utf16LittleEndian("MACBOOK"))
    #expect(Data(token[72 ..< 88]) == Data(mic))
}

@Test func ntlmContextSealingKeyFollowsNegotiatedKeyStrength() throws {
    let challengeFlags = localChallengeMessage().littleEndianUInt32(at: 20)

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
        with: challenge.littleEndianUInt32(at: 20) & ~UInt32(0x0000_0001)
    )

    try expectNTLMFailure(
        for: challenge,
        containing: "server did not negotiate NTLM Unicode encoding"
    )
}

@Test func ntlmContextRejectsChallengeWithoutExtendedSessionSecurityOrSealing() throws {
    for removedFlag in [UInt32(0x0008_0000), UInt32(0x0000_0020)] {
        var challenge = localChallengeMessage()
        replaceLittleEndianUInt32(
            in: &challenge,
            at: 20,
            with: challenge.littleEndianUInt32(at: 20) & ~removedFlag
        )

        try expectNTLMFailure(
            for: challenge,
            containing: "server did not negotiate NTLM extended session security and sealing"
        )
    }
}

@Test func ntlmContextRejectsTargetInfoThatOverflowsAuthenticateField() throws {
    // 65,524 bytes of server target info grow past UInt16.max once the client adds its AV pairs.
    var targetInfo = Data([0x03, 0x00, 0xB0, 0xFF]) + Data(repeating: 0x41, count: 0xFFB0)
    targetInfo += securityBuffer(localChallengeMessage(), at: 40)

    try expectNTLMFailure(
        for: challengeMessage(replacingTargetInfo: targetInfo),
        containing: "NTLM authenticate message field is too long"
    )
}

/// A user name or domain past an AUTHENTICATE_MESSAGE field's 16-bit length is the configuration's fault.
@Test func ntlmContextRejectsCredentialsTooLongForAuthenticateFields() throws {
    for credentials in [
        RDPCredentials(username: String(repeating: "u", count: 32768), domain: "Domain", password: "Password"),
        RDPCredentials(username: "User", domain: String(repeating: "d", count: 32768), password: "Password"),
    ] {
        let context = RDPCredSSPNTLMContext(
            credentials: credentials,
            randomBytes: { count in Data(repeating: 0, count: count) },
            currentFileTime: { 0 }
        )
        _ = try context.initialize(inputToken: nil)

        let error = #expect(throws: RDPCredSSPError.self) {
            try context.initialize(inputToken: localChallengeMessage())
        }
        #expect(error?.failure == .invalidConfiguration)
        #expect(error?.description == "CredSSP NTLM failed: the user name or domain is too long for an NTLM message")
    }
}

/// Using the context out of order is this client's own failure, not the server's.
@Test func ntlmContextUsedOutOfOrderIsAClientFailure() throws {
    let context = RDPCredSSPNTLMContext(
        credentials: RDPCredentials(username: "User", domain: "Domain", password: "Password"),
        randomBytes: { count in Data(repeating: 0, count: count) },
        currentFileTime: { 0 }
    )

    let wrapError = #expect(throws: RDPCredSSPError.self) { try context.wrap(Data([0x01])) }
    let unwrapError = #expect(throws: RDPCredSSPError.self) { try context.unwrap(Data(count: 16)) }
    let tokenError = #expect(throws: RDPCredSSPError.self) { try context.initialize(inputToken: localChallengeMessage()) }
    _ = try context.initialize(inputToken: nil)
    _ = try context.initialize(inputToken: localChallengeMessage())
    let completeError = #expect(throws: RDPCredSSPError.self) { try context.initialize(inputToken: localChallengeMessage()) }

    #expect([wrapError, unwrapError, tokenError, completeError].map { $0?.failure } == Array(repeating: .clientFailure, count: 4))
}

@Test func ntlmContextUnwrapRejectsTamperedSignature() throws {
    let context = RDPCredSSPNTLMContext(
        credentials: RDPCredentials(username: "User", domain: "Domain", password: "Password"),
        randomBytes: { count in Data(repeating: 0x55, count: count) },
        currentFileTime: { 0 }
    )
    _ = try context.initialize(inputToken: nil)
    _ = try context.initialize(inputToken: localChallengeMessage())

    #expect(throws: RDPCredSSPError.self) {
        try context.unwrap(Data(repeating: 0x01, count: 48))
    }
}

@Test func ntlmMD4MatchesRFC1320TestSuite() {
    let vectors = [
        ("", "31d6cfe0d16ae931b73c59d7e0c089c0"),
        ("a", "bde52cb31de33e46245e05fbdbd6fb24"),
        ("abc", "a448017aaf21d8525fc10ae87aa6729d"),
        ("message digest", "d9130a8164549fe818874806e1c7014b"),
        (String(repeating: "1234567890", count: 8), "e33b4ddc9c38f2199c3e7b164fcc0536"),
    ]
    for (input, digest) in vectors {
        #expect(RDPCredSSPNTLMContext.md4(Data(input.utf8)) == Data(rdpHexString: digest))
    }
}

@Test func ntlmNTOWFv2MatchesNLMPExampleAndKeepsSharpS() throws {
    // MS-NLMP 4.2.4.1.1
    #expect(RDPCredSSPNTLMContext.ntowfV2(password: "Password", username: "User", domain: "Domain")
        == Data(rdpHexString: "0c868a403bfd7a93a3001ef22ef02e3f"))

    // Windows upper-cases code point by code point, so "ß" is not expanded to "SS".
    let ntHash = RDPCredSSPNTLMContext.md4(utf16LittleEndian("Password"))
    let expected = Data(HMAC<Insecure.MD5>.authenticationCode(
        for: utf16LittleEndian("STRAßEDomain"),
        using: SymmetricKey(data: ntHash)
    ))
    #expect(RDPCredSSPNTLMContext.ntowfV2(password: "Password", username: "straße", domain: "Domain") == expected)
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
    for version in [Data([0x02, 0x01, 0x01]), Data([0x02, 0x01, 0xFF])] {
        #expect(throws: RDPDecodeError.invalidCredSSPMessage) {
            try RDPCredSSPTSRequest.parse(sequence(context(0, version)))
        }
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

@Test func credSSPTSRequestParsesNegativeNTStatusErrorCode() throws {
    let signed = sequence(context(0, integer(6)) + context(4, Data([0x02, 0x04, 0xC0, 0x00, 0x00, 0x6D])))
    let unsigned = sequence(context(0, integer(6)) + context(4, Data([0x02, 0x05, 0x00, 0xC0, 0x00, 0x00, 0x6D])))

    #expect(try RDPCredSSPTSRequest.parse(signed).errorCode == 0xC000_006D)
    #expect(try RDPCredSSPTSRequest.parse(unsigned).errorCode == 0xC000_006D)
    #expect(RDPCredSSPTSRequest(errorCode: 0xC000_006D).encoded() == signed)
}

@Test func credSSPTSRequestAcceptsNonMinimalErrorCodeFromFreeRDP2() throws {
    // FreeRDP 2.x ber_write_integer writes 0xFFFFFF80 in 4 bytes; DER needs only 0x80.
    let encoded = sequence(context(0, integer(6)) + context(4, Data([0x02, 0x04, 0xFF, 0xFF, 0xFF, 0x80])))

    #expect(try RDPCredSSPTSRequest.parse(encoded).errorCode == 0xFFFF_FF80)
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

// MS-NLMP 4.2.4: NTLMv2 example with User/Domain/Password, ServerChallenge
// 0123456789abcdef, client challenge aa*8, Time 0 and RandomSessionKey 55*16.
@Test func ntlmContextMatchesNLMPv2KnownAnswers() throws {
    let context = RDPCredSSPNTLMContext(
        credentials: RDPCredentials(username: "User", domain: "Domain", password: "Password"),
        randomBytes: { count in Data(repeating: count == 8 ? 0xAA : 0x55, count: count) },
        currentFileTime: { 0 }
    )
    _ = try context.initialize(inputToken: nil)
    let step = try context.initialize(inputToken: nlmpV2ChallengeMessage())
    let token = try #require(step.outputToken)

    // 4.2.4.2.1 LMv2 Response
    #expect(securityBuffer(token, at: 12) == Data([
        0x86, 0xC3, 0x50, 0x97, 0xAC, 0x9C, 0xEC, 0x10,
        0x25, 0x54, 0x76, 0x4A, 0x57, 0xCC, 0xCC, 0x19,
        0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA,
    ]))
    // 4.2.4.4 GSS_WrapEx: Signature followed by the sealed "Plaintext"
    #expect(try context.wrap(utf16LittleEndian("Plaintext")) == Data([
        0x01, 0x00, 0x00, 0x00, 0x7F, 0xB3, 0x8E, 0xC5,
        0xC5, 0x5D, 0x49, 0x76, 0x00, 0x00, 0x00, 0x00,
        0x54, 0xE5, 0x01, 0x65, 0xBF, 0x19, 0x36, 0xDC, 0x99,
        0x60, 0x20, 0xC1, 0x81, 0x1B, 0x0F, 0x06, 0xFB, 0x5F,
    ]))
}

private func nlmpV2ChallengeMessage() -> Data {
    var targetInfo = Data([0x02, 0x00, 0x0C, 0x00]) + utf16LittleEndian("Domain")
    targetInfo += Data([0x01, 0x00, 0x0C, 0x00]) + utf16LittleEndian("Server")
    targetInfo += Data(repeating: 0, count: 4)
    var message = challengeMessage(replacingTargetInfo: targetInfo)
    replaceLittleEndianUInt32(in: &message, at: 20, with: 0xE28A_8233)
    message.replaceSubrange(24 ..< 32, with: [0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF])
    return message
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
    let length = Int(data.littleEndianUInt16(at: offset))
    let bufferOffset = Int(data.littleEndianUInt32(at: offset + 4))
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
        let avID = targetInfo.littleEndianUInt16(at: offset)
        let length = Int(targetInfo.littleEndianUInt16(at: offset + 2))
        offset += 4
        if avID == 0 {
            break
        }
        if avID == 6, length == 4 {
            values.append(targetInfo.littleEndianUInt32(at: offset))
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
        let avID = targetInfo.littleEndianUInt16(at: offset)
        let length = Int(targetInfo.littleEndianUInt16(at: offset + 2))
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
        let avID = targetInfo.littleEndianUInt16(at: offset)
        let length = Int(targetInfo.littleEndianUInt16(at: offset + 2))
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
    let targetInfoOffset = Int(message.littleEndianUInt32(at: 44))
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

/// An RSASSA-PSS signature names its hash in its parameters (RFC 4055 3.1); SHA-1, the
/// default when they name none, binds with SHA-256 as for any SHA-1 signature.
@Test func credSSPCertificateTakesTheChannelBindingHashOfAnRSAPSSSignatureFromItsParameters() throws {
    let rsassaPSS = Data([0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0A])
    func pssCertificate(hashOID: [UInt8]) -> Data {
        let hashAlgorithm = sequence(Data([0x06, UInt8(hashOID.count)] + hashOID) + Data([0x05, 0x00]))
        return testCertificate(signatureAlgorithm: rsassaPSS + sequence(context(0, hashAlgorithm)))
    }
    let sha384Certificate = pssCertificate(hashOID: [0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x02])
    let sha512Certificate = pssCertificate(hashOID: [0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x03])
    let defaultCertificate = testCertificate(signatureAlgorithm: rsassaPSS + sequence(Data()))

    #expect(try RDPCredSSPCertificate.ntlmChannelBindingsHash(fromCertificateDER: sha384Certificate)
        == ntlmChannelBindingsHash(certificateDigest: Data(SHA384.hash(data: sha384Certificate))))
    #expect(try RDPCredSSPCertificate.ntlmChannelBindingsHash(fromCertificateDER: sha512Certificate)
        == ntlmChannelBindingsHash(certificateDigest: Data(SHA512.hash(data: sha512Certificate))))
    #expect(try RDPCredSSPCertificate.ntlmChannelBindingsHash(fromCertificateDER: defaultCertificate)
        == ntlmChannelBindingsHash(certificateDigest: Data(SHA256.hash(data: defaultCertificate))))
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

/// A TSRequest errorCode is an NTSTATUS ([MS-ERREF] 2.3.1); logon failures are named.
@Test func credSSPServerErrorNamesLogonFailures() {
    #expect(
        RDPCredSSPError.serverError(0xC000_0234).description
            == "CredSSP server returned STATUS_ACCOUNT_LOCKED_OUT (0xc0000234)"
    )
    #expect(RDPCredSSPError.serverError(0xC000_0001).description == "CredSSP server returned NTSTATUS (0xc0000001)")
}
