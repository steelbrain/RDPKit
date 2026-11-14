import Foundation
@testable import RDPKit
import Testing

@Test func parsesServerLicenseRequest() throws {
    let license = try #require(try parseServerLicense(mcsSendDataIndication(
        channelID: 1003,
        userData: serverLicenseRequestUserData()
    )))

    #expect(license.typeName == "license-request")
    let request = try #require(license.request)
    #expect(request.serverRandom == Data(0 ..< 32))
    #expect(request.productVersion == 0x0006_0001)
    #expect(request.companyName == "Microsoft Corporation")
    #expect(request.productID == "A02")
    #expect(request.keyExchangeAlgorithms == [0x0000_0001])
    #expect(request.certificateByteCount == 0)
    #expect(request.scopeCount == 1)
    #expect(request.scopes == ["localhost"])
}

@Test func parsesLicenseErrorValidClientFromServerPacket() throws {
    let license = try #require(try parseServerLicense(mcsSendDataIndication(
        channelID: 1003,
        userData: Data([
            0x80, 0x00, 0x00, 0x00,
            0xFF, 0x03, 0x10, 0x00,
            0x07, 0x00, 0x00, 0x00,
            0x02, 0x00, 0x00, 0x00,
            0x04, 0x00, 0x00, 0x00,
        ])
    )))

    #expect(license.alert == RDPLicenseErrorAlert(errorCode: 0x0000_0007, stateTransition: 0x0000_0002))
    #expect(license.typeName == "license-error-valid-client")
}

@Test func rejectsServerLicenseRequestWithInvalidProductString() throws {
    #expect(throws: RDPDecodeError.invalidLicensePDU) {
        try parseServerLicense(mcsSendDataIndication(
            channelID: 1003,
            userData: serverLicenseRequestUserData(companyName: Data([0x4D, 0x00]))
        ))
    }
}

@Test func rejectsServerLicenseRequestWithoutRSAKeyExchange() throws {
    #expect(throws: RDPDecodeError.invalidLicensePDU) {
        try parseServerLicense(mcsSendDataIndication(
            channelID: 1003,
            userData: serverLicenseRequestUserData(keyExchangeAlgorithms: [0x0000_0002])
        ))
    }
}

@Test func acceptsEmptyServerLicenseRequestBlobsWithIgnoredTypes() throws {
    let license = try #require(try parseServerLicense(mcsSendDataIndication(
        channelID: 1003,
        userData: serverLicenseRequestUserData(
            certificateType: 0x1234,
            scopeType: 0x5678,
            scopePayload: Data()
        )
    )))

    #expect(license.typeName == "license-request")
    #expect(license.request?.certificateByteCount == 0)
    #expect(license.request?.scopeCount == 1)
}

@Test func rejectsServerLicenseRequestWithImpossibleScopeCount() {
    #expect(throws: RDPDecodeError.invalidLicensePDU) {
        try parseServerLicense(mcsSendDataIndication(
            channelID: 1003,
            userData: serverLicenseRequestUserData(scopeCount: UInt32.max, scopePayload: nil)
        ))
    }
}

@Test func parsesServerLicenseRequestWithCertificate() throws {
    let certificate = proprietaryServerCertificate()
    let license = try #require(try parseServerLicense(mcsSendDataIndication(
        channelID: 1003,
        userData: serverLicenseRequestUserData(certificatePayload: certificate)
    )))

    #expect(license.typeName == "license-request")
    #expect(license.request?.certificateByteCount == certificate.count)
}

@Test func parsesServerLicenseRequestWithX509CertificateChain() throws {
    let certificate = try MockKRDPTLS.rdpX509CertificateChain()
    let license = try #require(try parseServerLicense(mcsSendDataIndication(
        channelID: 1003,
        userData: serverLicenseRequestUserData(certificatePayload: certificate)
    )))
    let publicKey = try #require(license.request?.serverCertificatePublicKey)

    #expect(license.typeName == "license-request")
    #expect(license.request?.certificateByteCount == certificate.count)
    #expect(publicKey.publicExponent == 0x0001_0001)
    #expect(publicKey.modulus.count == 256)
    #expect(publicKey.keyByteCount == 264)
}

/// Windows names the RSA key of the terminal server certificate by a signature
/// algorithm, shaWithRSAEncryption (1.3.14.3.2.15); the license server
/// certificate before it names its key rsaEncryption.
@Test func parsesServerLicenseRequestWithTerminalServerX509CertificateChain() throws {
    let certificate = try #require(Data(base64Encoded: terminalServerCertificateChainBase64))
    let license = try #require(try parseServerLicense(mcsSendDataIndication(
        channelID: 1003,
        userData: serverLicenseRequestUserData(certificatePayload: certificate)
    )))
    let publicKey = try #require(license.request?.serverCertificatePublicKey)

    #expect(publicKey.publicExponent == 0x0001_0001)
    #expect(publicKey.modulus.count == 256)
    // The terminal server's key, not the license server's.
    #expect(publicKey.modulus.suffix(8) == Data([0xA6, 0x81, 0x58, 0xC6, 0xF0, 0x6B, 0x90, 0xC8]))
    #expect(publicKey.keyByteCount == 264)
}

@Test func rejectsServerLicenseRequestWithMalformedCertificate() throws {
    var certificate = proprietaryServerCertificate()
    certificate[certificate.index(certificate.startIndex, offsetBy: 16)] = 0

    #expect(throws: RDPDecodeError.invalidLicensePDU) {
        try parseServerLicense(mcsSendDataIndication(
            channelID: 1003,
            userData: serverLicenseRequestUserData(certificatePayload: certificate)
        ))
    }
}

@Test func clientNewLicenseRequestEncryptsPremasterSecretWithRawRSA() throws {
    let publicKey = RDPRSAPublicKey(
        modulus: Data([0xA1, 0x0C]),
        publicExponent: 17,
        keyByteCount: 2
    )
    var randomCalls = 0
    let request = try RDPClientNewLicenseRequestPDU(
        channelID: 1003,
        serverPublicKey: publicKey,
        username: "rdp-user",
        machineName: "mac",
        randomBytes: { count in
            randomCalls += 1
            return randomCalls == 1
                ? Data(repeating: 0x11, count: count)
                : Data([65]) + Data(repeating: 0, count: count - 1)
        }
    )

    #expect(request.clientRandom == Data(repeating: 0x11, count: 32))
    #expect(request.encryptedPremasterSecret == Data([0xE6, 0x0A]))
}

@Test func clientNewLicenseRequestEncodesSpecFields() throws {
    let request = RDPClientNewLicenseRequestPDU(
        channelID: 1003,
        clientRandom: Data(repeating: 0x11, count: 32),
        encryptedPremasterSecret: Data([0xE6, 0x0A]),
        username: "rdp-user",
        machineName: "mac"
    )
    let userData = try request.encodedUserData()
    var cursor = ByteCursor(userData)

    #expect(try cursor.readLittleEndianUInt16() == 0x0080)
    #expect(try cursor.readLittleEndianUInt16() == 0)
    #expect(try cursor.readUInt8() == 0x13)
    #expect(try cursor.readUInt8() == 0x03)
    #expect(try cursor.readLittleEndianUInt16() == UInt16(cursor.remaining + 4))
    #expect(try cursor.readLittleEndianUInt32() == 0x0000_0001)
    #expect(try cursor.readLittleEndianUInt32() == 0x0401_0000)
    #expect(try cursor.readData(count: 32) == Data(repeating: 0x11, count: 32))
    let encryptedPremaster = try readLicenseBlob(&cursor)
    #expect(encryptedPremaster.type == 0x0002)
    #expect(encryptedPremaster.data == Data([0xE6, 0x0A]))
    let username = try readLicenseBlob(&cursor)
    #expect(username.type == 0x000F)
    #expect(username.data == Data("rdp-user\u{0}".utf8))
    let machineName = try readLicenseBlob(&cursor)
    #expect(machineName.type == 0x0010)
    #expect(machineName.data == Data("mac\u{0}".utf8))
    #expect(cursor.remaining == 0)
}

@Test func clientNewLicenseRequestSendsNonASCIINamesAsUTF8() throws {
    let request = RDPClientNewLicenseRequestPDU(
        channelID: 1003,
        clientRandom: Data(repeating: 0x11, count: 32),
        encryptedPremasterSecret: Data([0xE6, 0x0A]),
        username: "José",
        machineName: "Büro-Mac"
    )
    var cursor = try ByteCursor(request.encodedUserData())
    _ = try cursor.readData(count: 8 + 8 + 32)
    _ = try readLicenseBlob(&cursor)

    #expect(try readLicenseBlob(&cursor).data == Data("José\u{0}".utf8))
    #expect(try readLicenseBlob(&cursor).data == Data("Büro-Mac\u{0}".utf8))
}

@Test func storedClientLicenseMatchesServerLicenseRequestProductAndScope() throws {
    let license = try #require(try parseServerLicense(mcsSendDataIndication(
        channelID: 1003,
        userData: serverLicenseRequestUserData()
    )))
    let storedLicense = RDPStoredClientLicense(
        version: 0x0006_0001,
        scope: "localhost",
        companyName: "Microsoft Corporation",
        productID: "A02",
        licenseInfo: Data([0x30, 0x82])
    )

    let request = try #require(license.request)
    #expect(storedLicense.matches(request))
    #expect(RDPStoredClientLicense(
        version: 0x0006_0001,
        scope: "other",
        companyName: "Microsoft Corporation",
        productID: "A02",
        licenseInfo: Data([0x30, 0x82])
    ).matches(request) == false)
}

@Test func clientLicenseInformationEncodesSpecFieldsAndHardwareMAC() throws {
    let publicKey = RDPRSAPublicKey(
        modulus: Data([0xA1, 0x0C]),
        publicExponent: 17,
        keyByteCount: 2
    )
    let serverRandom = Data(repeating: 0x22, count: 32)
    var randomCalls = 0
    let storedLicense = RDPStoredClientLicense(
        version: 0x0006_0001,
        scope: "localhost",
        companyName: "Microsoft Corporation",
        productID: "A02",
        licenseInfo: Data([0x30, 0x82, 0x01, 0x02])
    )
    let request = try RDPClientLicenseInformationPDU(
        channelID: 1003,
        serverPublicKey: publicKey,
        serverRandom: serverRandom,
        storedLicense: storedLicense,
        randomBytes: { count in
            randomCalls += 1
            return randomCalls == 1
                ? Data(repeating: 0x11, count: count)
                : Data([65]) + Data(repeating: 0, count: count - 1)
        }
    )
    let userData = try request.encodedUserData()
    var cursor = ByteCursor(userData)

    #expect(try cursor.readLittleEndianUInt16() == 0x0080)
    #expect(try cursor.readLittleEndianUInt16() == 0)
    #expect(try cursor.readUInt8() == 0x12)
    #expect(try cursor.readUInt8() == 0x03)
    #expect(try cursor.readLittleEndianUInt16() == UInt16(cursor.remaining + 4))
    #expect(try cursor.readLittleEndianUInt32() == 0x0000_0001)
    #expect(try cursor.readLittleEndianUInt32() == 0x0401_0000)
    #expect(try cursor.readData(count: 32) == Data(repeating: 0x11, count: 32))
    let encryptedPremaster = try readLicenseBlob(&cursor)
    let licenseInfo = try readLicenseBlob(&cursor)
    let encryptedHardwareID = try readLicenseBlob(&cursor)
    let mac = try cursor.readData(count: 16)
    let premasterSecret = try #require(request.premasterSecret)
    let keys = try RDPLicenseKeys.derive(
        clientRandom: request.clientRandom,
        serverRandom: serverRandom,
        premasterSecret: premasterSecret
    )
    let hardwareID = keys.decrypt(encryptedHardwareID.data)

    #expect(encryptedPremaster.type == 0x0002)
    #expect(encryptedPremaster.data == Data([0xE6, 0x0A]))
    #expect(licenseInfo.type == 0x0001)
    #expect(licenseInfo.data == storedLicense.licenseInfo)
    #expect(encryptedHardwareID.type == 0x0001)
    #expect(hardwareID == Data([0, 0, 1, 4]) + Data(repeating: 0, count: 16))
    #expect(mac == keys.mac(hardwareID))
    #expect(cursor.remaining == 0)
}

@Test func licenseKeysEncryptDecryptAndMacChallengeData() throws {
    let keys = try RDPLicenseKeys.derive(
        clientRandom: Data(repeating: 0x11, count: 32),
        serverRandom: Data(repeating: 0x22, count: 32),
        premasterSecret: Data(repeating: 0x33, count: 48)
    )
    let challenge = Data("platform-challenge".utf8)
    let encrypted = keys.encrypt(challenge)

    #expect(encrypted != challenge)
    #expect(keys.decrypt(encrypted) == challenge)
    #expect(keys.mac(challenge).count == 16)
}

@Test func clientPlatformChallengeResponseEncodesEncryptedBlobsAndMac() throws {
    let keys = try RDPLicenseKeys.derive(
        clientRandom: Data(repeating: 0x11, count: 32),
        serverRandom: Data(repeating: 0x22, count: 32),
        premasterSecret: Data(repeating: 0x33, count: 48)
    )
    let challenge = Data([0xAA, 0xBB, 0xCC])
    let response = try RDPClientPlatformChallengeResponsePDU(
        channelID: 1003,
        platformChallenge: challenge,
        keys: keys
    )
    let userData = try response.encodedUserData()
    var cursor = ByteCursor(userData)

    #expect(try cursor.readLittleEndianUInt16() == 0x0080)
    #expect(try cursor.readLittleEndianUInt16() == 0)
    #expect(try cursor.readUInt8() == 0x15)
    #expect(try cursor.readUInt8() == 0x03)
    #expect(try cursor.readLittleEndianUInt16() == UInt16(cursor.remaining + 4))

    let encryptedResponse = try readLicenseBlob(&cursor)
    let encryptedHardwareID = try readLicenseBlob(&cursor)
    let mac = try cursor.readData(count: 16)
    let responseData = keys.decrypt(encryptedResponse.data)
    let hardwareID = keys.decrypt(encryptedHardwareID.data)

    #expect(encryptedResponse.type == 0x0009)
    #expect(encryptedHardwareID.type == 0x0009)
    #expect(responseData == Data([0x00, 0x01, 0x00, 0x01, 0x03, 0x00, 0x03, 0x00, 0xAA, 0xBB, 0xCC]))
    #expect(hardwareID == Data([0, 0, 1, 4]) + Data(repeating: 0, count: 16))
    #expect(mac == keys.mac(responseData + hardwareID))
    #expect(cursor.remaining == 0)
}

@Test func clientLicenseEncodersRejectOversizedBinaryBlobs() throws {
    let oversizedPayload = Data(repeating: 0x30, count: Int(UInt16.max) + 1)
    let storedLicense = RDPStoredClientLicense(
        version: 0x0006_0001,
        scope: "localhost",
        companyName: "Microsoft Corporation",
        productID: "A02",
        licenseInfo: oversizedPayload
    )
    let licenseInformation = RDPClientLicenseInformationPDU(
        channelID: 1003,
        clientRandom: Data(repeating: 0x11, count: 32),
        encryptedPremasterSecret: Data([0xE6, 0x0A]),
        storedLicense: storedLicense,
        encryptedHardwareID: Data([0xAA]),
        mac: Data(repeating: 0x55, count: 16)
    )
    let newLicenseRequest = RDPClientNewLicenseRequestPDU(
        channelID: 1003,
        clientRandom: Data(repeating: 0x11, count: 32),
        encryptedPremasterSecret: Data([0xE6, 0x0A]),
        username: String(repeating: "a", count: Int(UInt16.max)),
        machineName: "mac"
    )
    let keys = try RDPLicenseKeys.derive(
        clientRandom: Data(repeating: 0x11, count: 32),
        serverRandom: Data(repeating: 0x22, count: 32),
        premasterSecret: Data(repeating: 0x33, count: 48)
    )

    #expect(throws: RDPDecodeError.invalidLicensePDU) {
        try licenseInformation.encodedUserData()
    }
    #expect(throws: RDPDecodeError.invalidLicensePDU) {
        try newLicenseRequest.encodedUserData()
    }
    #expect(throws: RDPDecodeError.invalidLicensePDU) {
        try RDPClientPlatformChallengeResponsePDU(
            channelID: 1003,
            platformChallenge: oversizedPayload,
            keys: keys
        )
    }
}

/// Server-sized license data that fits its blob but not one MCS PDU throws
/// instead of trapping: a platform challenge and a stored (server-issued) license.
@Test func clientLicenseEncodersRejectServerDataLargerThanOneMCSPDU() throws {
    let keys = try RDPLicenseKeys.derive(
        clientRandom: Data(repeating: 0x11, count: 32),
        serverRandom: Data(repeating: 0x22, count: 32),
        premasterSecret: Data(repeating: 0x33, count: 48)
    )
    let challengeResponse = try RDPClientPlatformChallengeResponsePDU(
        channelID: 1003,
        platformChallenge: Data(repeating: 0xAA, count: 16340),
        keys: keys
    )
    let licenseInformation = RDPClientLicenseInformationPDU(
        channelID: 1003,
        clientRandom: Data(repeating: 0x11, count: 32),
        encryptedPremasterSecret: Data([0xE6, 0x0A]),
        storedLicense: RDPStoredClientLicense(
            version: 0x0006_0001,
            scope: "localhost",
            companyName: "Microsoft Corporation",
            productID: "A02",
            licenseInfo: Data(repeating: 0x30, count: 16340)
        ),
        encryptedHardwareID: Data([0xAA]),
        mac: Data(repeating: 0x55, count: 16)
    )

    #expect(throws: MCSUserDataTooLongError.self) {
        try challengeResponse.encodedTPKT(userChannelID: 1007)
    }
    #expect(throws: MCSUserDataTooLongError.self) {
        try licenseInformation.encodedTPKT(userChannelID: 1007)
    }
}

@Test func parsesNewLicenseInformationFields() throws {
    let licenseInfo = try RDPServerNewLicenseInformation.parse(newLicenseInformationData())

    #expect(licenseInfo.version == 0x0006_0001)
    #expect(licenseInfo.scope == "localhost")
    #expect(licenseInfo.companyName == "Microsoft Corporation")
    #expect(licenseInfo.productID == "A02")
    #expect(licenseInfo.licenseInfo == Data([0x30, 0x82, 0x01, 0x02]))
}

@Test func rejectsMalformedNewLicenseInformationFields() throws {
    var missingNullScope = newLicenseInformationData(scope: Data("localhost".utf8))
    #expect(throws: RDPDecodeError.invalidLicensePDU) {
        try RDPServerNewLicenseInformation.parse(missingNullScope)
    }

    missingNullScope = newLicenseInformationData(licenseInfo: Data())
    #expect(throws: RDPDecodeError.invalidLicensePDU) {
        try RDPServerNewLicenseInformation.parse(missingNullScope)
    }
}

@Test func serverNewLicenseExposesEncryptedLicenseInfoAndMac() throws {
    let encryptedLicenseInfo = Data([0xAA, 0xBB, 0xCC])
    let mac = Data(repeating: 0x55, count: 16)
    let license = try #require(try parseServerLicense(mcsSendDataIndication(
        channelID: 1003,
        userData: encryptedLicenseUserData(
            messageType: 0x03,
            encryptedBlobType: 0x1234,
            encryptedBlob: encryptedLicenseInfo,
            mac: mac
        )
    )))

    #expect(license.message == .newLicense(RDPServerEncryptedLicense(encryptedLicenseInfo: encryptedLicenseInfo, mac: mac)))
}

@Test func rejectsNonEmptyServerLicenseRequestBlobsWithWrongTypes() throws {
    let nonCertificate = serverLicenseRequestUserData(
        certificateType: 0x1234,
        certificatePayload: Data([0x01])
    )
    let nonScope = serverLicenseRequestUserData(
        scopeType: 0x5678,
        scopePayload: Data([0x00])
    )

    #expect(throws: RDPDecodeError.invalidLicensePDU) {
        try parseServerLicense(mcsSendDataIndication(
            channelID: 1003,
            userData: nonCertificate
        ))
    }
    #expect(throws: RDPDecodeError.invalidLicensePDU) {
        try parseServerLicense(mcsSendDataIndication(
            channelID: 1003,
            userData: nonScope
        ))
    }
}

@Test func ignoresIOChannelDataWithoutAServerLicensingPreamble() throws {
    let header: [UInt8] = [0x80, 0x00, 0x00, 0x00]
    let validClientBody: [UInt8] = [0x07, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00]
    let notLicensing: [[UInt8]] = [
        // wMsgSize does not cover the payload.
        header + [0xFF, 0x03, 0x10, 0x00] + validClientBody + [0x00],
        // Truncated preamble.
        header + [0xFF, 0x03, 0x10],
        // Preamble version 4.
        header + [0xFF, 0x04, 0x10, 0x00] + validClientBody,
        // A client-only message type (Client New License Request).
        header + [0x13, 0x03, 0x04, 0x00],
        // GRD's Demand Active: totalLength 0x0196 has the SEC_LICENSE_PKT bit.
        [0x96, 0x01, 0x11, 0x00, 0xEE, 0x03, 0xEE, 0x03, 0x01, 0x00, 0x04, 0x00],
    ]

    for userData in notLicensing {
        #expect(try parseServerLicense(mcsSendDataIndication(channelID: 1003, userData: Data(userData))) == nil)
    }
}

@Test func licenseErrorIgnoresTheBlobTypeOfAnEmptyBlob() throws {
    // [MS-RDPBCGR] 2.2.1.12.1.2: wBlobType SHOULD be ignored when wBlobLen is 0.
    let license = try #require(try parseServerLicense(mcsSendDataIndication(
        channelID: 1003,
        userData: Data([
            0x80, 0x00, 0x00, 0x00,
            0xFF, 0x03, 0x10, 0x00,
            0x07, 0x00, 0x00, 0x00,
            0x02, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
        ])
    )))

    #expect(license.alert?.isValidClient == true)
}

@Test func parsesWindowsValidClientLicenseErrorWithUnusedFlagsHi() throws {
    // [MS-RDPBCGR] 4.1.11: flagsHi carries arbitrary bytes. Read as a Share
    // Control header, 0x0080/0x0302 would not match the PDU length.
    let indication = try MCSSendDataIndicationPDU.parse(fromTPKT: mcsSendDataIndication(
        channelID: 1003,
        userData: Data([
            0x80, 0x00, 0x02, 0x03,
            0xFF, 0x03, 0x10, 0x00,
            0x07, 0x00, 0x00, 0x00,
            0x02, 0x00, 0x00, 0x00,
            0x04, 0x00, 0x00, 0x00,
        ])
    ))

    guard case let .license(license) = try RDPIOChannelPDU.parse(indication, licensing: true) else {
        Issue.record("expected a licensing PDU")
        return
    }
    #expect(license.alert?.isValidClient == true)
}

@Test func rejectsLicenseErrorWithWrongBlobTypeOrLength() throws {
    let wrongBlobType = mcsSendDataIndication(
        channelID: 1003,
        userData: licenseErrorUserData(
            errorCode: 0x0000_0006,
            stateTransition: 0x0000_0001,
            errorBlobType: 0x0001,
            errorBlob: Data([0x01])
        )
    )
    let invalidBlobLength = mcsSendDataIndication(
        channelID: 1003,
        userData: Data([
            0x80, 0x00, 0x00, 0x00,
            0xFF, 0x03, 0x10, 0x00,
            0x07, 0x00, 0x00, 0x00,
            0x02, 0x00, 0x00, 0x00,
            0x04, 0x00, 0x01, 0x00,
        ])
    )

    #expect(throws: RDPDecodeError.invalidLicensePDU) {
        try parseServerLicense(wrongBlobType)
    }
    #expect(throws: RDPDecodeError.invalidLicensePDU) {
        try parseServerLicense(invalidBlobLength)
    }
}

@Test func licenseErrorKeepsUnknownCodesAndTransitionsForTheFailureMessage() throws {
    let unknownCode = try #require(try parseServerLicense(mcsSendDataIndication(
        channelID: 1003,
        userData: licenseErrorUserData(errorCode: 0x0000_0001, stateTransition: 0x0000_0001)
    )))
    let unknownTransition = try #require(try parseServerLicense(mcsSendDataIndication(
        channelID: 1003,
        userData: licenseErrorUserData(errorCode: 0x0000_0006, stateTransition: 0x0000_0005)
    )))

    #expect(unknownCode.alert?.description == "license error (0x00000001), ST_TOTAL_ABORT")
    #expect(unknownTransition.alert?.description
        == "ERR_NO_LICENSE_SERVER (0x00000006), state transition 0x00000005")
}

@Test func validClientNeedsNoTransition() throws {
    let nonFinalTransition = try #require(try parseServerLicense(mcsSendDataIndication(
        channelID: 1003,
        userData: licenseErrorUserData(errorCode: 0x0000_0007, stateTransition: 0x0000_0003)
    )))

    #expect(nonFinalTransition.alert?.isValidClient == false)
    #expect(nonFinalTransition.typeName == "license-error-0x00000007")
    #expect(nonFinalTransition.alert?.description == "STATUS_VALID_CLIENT (0x00000007), ST_RESET_PHASE_TO_START")
}

@Test func parsesNonValidClientLicenseErrorWithBlobData() throws {
    let license = try #require(try parseServerLicense(mcsSendDataIndication(
        channelID: 1003,
        userData: licenseErrorUserData(
            errorCode: 0x0000_0006,
            stateTransition: 0x0000_0001,
            errorBlob: Data([0x6E, 0x6F])
        )
    )))

    #expect(license.typeName == "license-error-0x00000006")
    let alert = try #require(license.alert)
    #expect(alert == RDPLicenseErrorAlert(errorCode: 0x0000_0006, stateTransition: 0x0000_0001))
    #expect(alert.isValidClient == false)
    #expect(alert.description == "ERR_NO_LICENSE_SERVER (0x00000006), ST_TOTAL_ABORT")
}

@Test func licenseKeysOpenVerifiedRejectsTamperedData() throws {
    let keys = try RDPLicenseKeys.derive(
        clientRandom: Data(repeating: 0x11, count: 32),
        serverRandom: Data(repeating: 0x22, count: 32),
        premasterSecret: Data(repeating: 0x33, count: 48)
    )
    let plaintext = Data("license-info".utf8)
    let encrypted = keys.encrypt(plaintext)

    #expect(try keys.openVerified(encrypted, mac: keys.mac(plaintext)) == plaintext)
    #expect(throws: RDPDecodeError.invalidLicensePDU) {
        try keys.openVerified(encrypted, mac: keys.mac(Data("other".utf8)))
    }
}

@Test func parsesOpaqueServerPlatformChallengeAndLicenseMessages() throws {
    let platformChallenge = try #require(try parseServerLicense(mcsSendDataIndication(
        channelID: 1003,
        userData: platformChallengeUserData(encryptedBlobType: 0x1234)
    )))
    let newLicense = try #require(try parseServerLicense(mcsSendDataIndication(
        channelID: 1003,
        userData: encryptedLicenseUserData(messageType: 0x03)
    )))
    let upgradeLicense = try #require(try parseServerLicense(mcsSendDataIndication(
        channelID: 1003,
        userData: encryptedLicenseUserData(messageType: 0x04)
    )))

    #expect(platformChallenge.typeName == "license-platform-challenge")
    #expect(newLicense.typeName == "license-new-license")
    #expect(upgradeLicense.typeName == "license-upgrade-license")
}

@Test func rejectsMalformedOpaqueServerLicenseMessages() throws {
    #expect(throws: RDPDecodeError.invalidLicensePDU) {
        try parseServerLicense(mcsSendDataIndication(
            channelID: 1003,
            userData: platformChallengeUserData(encryptedBlob: Data())
        ))
    }
    #expect(throws: RDPDecodeError.invalidLicensePDU) {
        try parseServerLicense(mcsSendDataIndication(
            channelID: 1003,
            userData: platformChallengeUserData(mac: Data(repeating: 0, count: 15))
        ))
    }
    #expect(throws: RDPDecodeError.invalidLicensePDU) {
        try parseServerLicense(mcsSendDataIndication(
            channelID: 1003,
            userData: encryptedLicenseUserData(messageType: 0x03, encryptedBlob: Data())
        ))
    }
    #expect(throws: RDPDecodeError.invalidLicensePDU) {
        try parseServerLicense(mcsSendDataIndication(
            channelID: 1003,
            userData: encryptedLicenseUserData(messageType: 0x04, suffix: Data([0x00]))
        ))
    }
}

@Test func ignoresNonLicensePackets() throws {
    #expect(try parseServerLicense(Data([
        0x03, 0x00, 0x00, 0x19,
        0x02, 0xF0, 0x80,
        0x68, 0x00, 0x05, 0x03, 0xED, 0x70, 0x80, 0x0A,
        0x00, 0x10, 0x00, 0x00,
        0x06, 0x00, 0x23, 0x00, 0x01, 0x10,
    ])) == nil)
}

private func parseServerLicense(_ packet: Data) throws -> RDPServerLicensePDU? {
    try RDPServerLicensePDU.parseIfPresent(from: MCSSendDataIndicationPDU.parse(fromTPKT: packet))
}

private extension RDPServerLicensePDU {
    var request: RDPServerLicenseRequest? {
        guard case let .licenseRequest(request) = message else {
            return nil
        }
        return request
    }

    var alert: RDPLicenseErrorAlert? {
        guard case let .errorAlert(alert) = message else {
            return nil
        }
        return alert
    }
}

private func licenseErrorUserData(
    errorCode: UInt32,
    stateTransition: UInt32,
    errorBlobType: UInt16 = 0x0004,
    errorBlob: Data = Data()
) -> Data {
    var payload = Data()
    payload.appendLittleEndianUInt16(0x0080)
    payload.appendLittleEndianUInt16(0)
    payload.appendUInt8(0xFF)
    payload.appendUInt8(0x03)
    payload.appendLittleEndianUInt16(UInt16(16 + errorBlob.count))
    payload.appendLittleEndianUInt32(errorCode)
    payload.appendLittleEndianUInt32(stateTransition)
    payload.appendLittleEndianUInt16(errorBlobType)
    payload.appendLittleEndianUInt16(UInt16(errorBlob.count))
    payload.append(errorBlob)
    return payload
}

private func serverLicenseRequestUserData(
    companyName: Data = utf16LENullTerminated("Microsoft Corporation"),
    productID: Data = utf16LENullTerminated("A02"),
    keyExchangeAlgorithms: [UInt32] = [0x0000_0001],
    certificateType: UInt16 = 0x0003,
    certificatePayload: Data = Data(),
    scopeCount: UInt32 = 1,
    scopeType: UInt16 = 0x000E,
    scopePayload: Data? = Data("localhost\u{0}".utf8)
) -> Data {
    var productInfo = Data()
    productInfo.appendLittleEndianUInt32(0x0006_0001)
    productInfo.appendLittleEndianUInt32(UInt32(companyName.count))
    productInfo.append(companyName)
    productInfo.appendLittleEndianUInt32(UInt32(productID.count))
    productInfo.append(productID)

    var keyExchangeBlob = Data()
    for algorithm in keyExchangeAlgorithms {
        keyExchangeBlob.appendLittleEndianUInt32(algorithm)
    }

    var body = Data(0 ..< 32)
    body.append(productInfo)
    appendLicenseBlob(type: 0x000D, payload: keyExchangeBlob, to: &body)
    appendLicenseBlob(type: certificateType, payload: certificatePayload, to: &body)
    body.appendLittleEndianUInt32(scopeCount)
    if let scopePayload {
        appendLicenseBlob(type: scopeType, payload: scopePayload, to: &body)
    }

    var payload = Data()
    payload.appendLittleEndianUInt16(0x0080)
    payload.appendLittleEndianUInt16(0)
    payload.appendUInt8(0x01)
    payload.appendUInt8(0x03)
    payload.appendLittleEndianUInt16(UInt16(body.count + 4))
    payload.append(body)
    return payload
}

private func platformChallengeUserData(
    encryptedBlobType: UInt16 = 0x0009,
    encryptedBlob: Data = Data([0xAA, 0xBB, 0xCC]),
    mac: Data = Data(repeating: 0x55, count: 16),
    suffix: Data = Data()
) -> Data {
    var body = Data()
    body.appendLittleEndianUInt32(0)
    appendLicenseBlob(type: encryptedBlobType, payload: encryptedBlob, to: &body)
    body.append(mac)
    body.append(suffix)
    return licenseUserData(messageType: 0x02, body: body)
}

private func encryptedLicenseUserData(
    messageType: UInt8,
    encryptedBlobType: UInt16 = 0x0009,
    encryptedBlob: Data = Data([0xAA, 0xBB, 0xCC]),
    mac: Data = Data(repeating: 0x55, count: 16),
    suffix: Data = Data()
) -> Data {
    var body = Data()
    appendLicenseBlob(type: encryptedBlobType, payload: encryptedBlob, to: &body)
    body.append(mac)
    body.append(suffix)
    return licenseUserData(messageType: messageType, body: body)
}

private func newLicenseInformationData(
    scope: Data = Data("localhost\u{0}".utf8),
    companyName: Data = utf16LENullTerminated("Microsoft Corporation"),
    productID: Data = utf16LENullTerminated("A02"),
    licenseInfo: Data = Data([0x30, 0x82, 0x01, 0x02])
) -> Data {
    var data = Data()
    data.appendLittleEndianUInt32(0x0006_0001)
    data.appendLittleEndianUInt32(UInt32(scope.count))
    data.append(scope)
    data.appendLittleEndianUInt32(UInt32(companyName.count))
    data.append(companyName)
    data.appendLittleEndianUInt32(UInt32(productID.count))
    data.append(productID)
    data.appendLittleEndianUInt32(UInt32(licenseInfo.count))
    data.append(licenseInfo)
    return data
}

private func licenseUserData(messageType: UInt8, body: Data) -> Data {
    var payload = Data()
    payload.appendLittleEndianUInt16(0x0080)
    payload.appendLittleEndianUInt16(0)
    payload.appendUInt8(messageType)
    payload.appendUInt8(0x03)
    payload.appendLittleEndianUInt16(UInt16(body.count + 4))
    payload.append(body)
    return payload
}

private func appendLicenseBlob(type: UInt16, payload: Data, to data: inout Data) {
    data.appendLittleEndianUInt16(type)
    data.appendLittleEndianUInt16(UInt16(payload.count))
    data.append(payload)
}

private func readLicenseBlob(_ cursor: inout ByteCursor) throws -> (type: UInt16, data: Data) {
    let type = try cursor.readLittleEndianUInt16()
    let length = try Int(cursor.readLittleEndianUInt16())
    return (type, try cursor.readData(count: length))
}

/// The Server Certificate of the Server License Request in MS-RDPELE 4.1: an
/// X.509 chain with dwVersion 0x80000002, of a self-signed license server
/// certificate and the terminal server certificate it signed.
private let terminalServerCertificateChainBase64 = [
    "AgAAgAIAAAD1AgAAMIIC8TCCAd2gAwIBAgIIAZ4kovKukIAwCQYFKw4DAh0FADAy",
    "MTAwEwYDVQQDHgwAUgBPAEQARQBOAFQwGQYDVQQHHhIAVwBPAFIASwBHAFIATwBV",
    "AFAwHhcNNzAwNTI3MDExMTAzWhcNNDkwNTI3MDExMTAzWjAyMTAwEwYDVQQDHgwA",
    "UgBPAEQARQBOAFQwGQYDVQQHHhIAVwBPAFIASwBHAFIATwBVAFAwggEiMA0GCSqG",
    "SIb3DQEBAQUAA4IBDwAwggEKAoIBAQCIrXyPi4J2Wr2Pb2IY4dmqQf3taAHGNDWw",
    "KQTKSkocfoAU9453uCX/FkdvveI0PS4CuVPkM3WtcyiAoE38bMAiUxss+PUBYBl+",
    "eRk5jbXOOVjdVSQ7VXtDwX8UL7BkOlSVK4hJDGEtrPhF9dqIGF+uQvh1xyZttbs5",
    "b8xVGzIROI3k6USEETaiYXaqTLTjVQ/kd47e46nqt0GUAFiqyTSimMYBGnYUAajc",
    "MHx3WiBxWqI/rxN+6P2EolvPJenHj6jyi4THBF5Tc04OiaM852hcJLeAUzxUyMFT",
    "qnFxPTYV1mqdfd6u+eavV665AZZd4E3N7cjX8wEDOBC+fEJnAacjAgMBAAGjEzAR",
    "MA8GA1UdEwQIMAYBAf8CAQAwCQYFKw4DAh0FAAOCAQEAgd3S0zPUo7aObn2f/XOf",
    "MQvdQoI/fiHfKMxZymrAqT0wfeGR23drixDm/bw8o1hIwjbdoAv1jhPaewQIRLTy",
    "qA0eCx0aP/mbS1pUxbO0A5N1s3JcPc9jDxXhZFjeUo2XeQ6kNNVmBVi4bnmyCYbV",
    "8O3Ea0yrArgWXzvtiF/R3kTjc0ch9wPO4W0QD5XPfKJ6pr8g2+GTBMhear7IAV0n",
    "sgMPZnXny+qNTpidIu0oQNJ9pEvvzL8BKm06Pr5HOPjqpMYwHV4lz/voPULdKeiZ",
    "iZ6/Oe53Cdk+i1I2truLvQ2yUqoszzhOTc8dbV0lF6ws9vBlWsn+MVO08AyUTg1U",
    "jv0EAAAwggT5MIID5aADAgECAgUBAAAAAjAJBgUrDgMCHQUAMDIxMDATBgNVBAMe",
    "DABSAE8ARABFAE4AVDAZBgNVBAceEgBXAE8AUgBLAEcAUgBPAFUAUDAeFw0wNzA1",
    "MjYxMjQ1NTNaFw0zODAxMTkwMzE0MDdaMIGSMYGPMCMGA1UEAx4cAG4AYwBhAGwA",
    "cgBwAGMAOgBSAE8ARABFAE4AVDAjBgNVBAceHABuAGMAYQBsAHIAcABjADoAUgBP",
    "AEQARQBOAFQwQwYDVQQFHjwAMQBCAGMASwBlAGIAaABwAFgAWgB0AEwAcQBPADcA",
    "UwBRAG4AQgBwAFIAZgB1AGQAZABkAFkAPQANAAowggEeMAkGBSsOAwIPBQADggEP",
    "ADCCAQoCggEBAMiQa/DGWIGmiRwO8vbZghJxpW5R2+AyZqqRdw6Iq0S305faeI8O",
    "RCZGfxbUxmPrylXlTostpm2DlaeoavrQviaArqsKZJAyjN9c+PnQftFrOil+fb0C",
    "o4Zs/aU1cdohtO6kl/OoshLbpCdXNskIIlxU95l7oy+4XNUWuBkna3GXFFvoHyPo",
    "XLgbc0tuegMT/5fpYrlKoFEjw2wyPgLyY5cjHMV42Py3B0uwVg9038VWKOSW/SCO",
    "ZVrmRe3BBT6rWFVAr+JHoExJo40542ZfkzNt+F/FVOX7VzreRRK1xwVLiB+0NQ98",
    "wHUXxmfdSIDLCr6d9pNgZTTrl69lbd+/b1sCAwEAAaOCAb8wggG7MBQGCSsGAQQB",
    "gjcSBAEB/wQEAQAFADA8BgkrBgEEAYI3EgIBAf8ELE0AaQBjAHIAbwBzAG8AZgB0",
    "ACAAQwBvAHIAcABvAHIAYQB0AGkAbwBuAAAAMIHNBgkrBgEEAYI3EgUBAf8EgbwA",
    "MAAAAQAAAAIAAAAJBAAAHABKAGYASgCwAAEAMwBkADIANgA3ADkANQA0AC0AZQBl",
    "AGIANwAtADEAMQBkADEALQBiADkANABlAC0AMAAwAGMAMAA0AGYAYQAzADAAOAAw",
    "AGQAAAAzAGQAMgA2ADcAOQA1ADQALQBlAGUAYgA3AC0AMQAxAGQAMQAtAGIAOQA0",
    "AGUALQAwADAAYwAwADQAZgBhADMAMAA4ADAAZAAAAAAAABAAgGQAAAAAADBuBgkr",
    "BgEEAYI3EgYBAf8EXgAwAAAAAA4APgBSAE8ARABFAE4AVAAAADcAOAA0ADQAMAAt",
    "ADAAMAA2AC0ANQA4ADYANwAwADQANQAtADcAMAAzADQANwAAAFcATwBSAEsARwBS",
    "AE8AVQBQAAAAAAAwJQYDVR0jAQH/BBswGaEQpA5SAE8ARABFAE4AVAAAAIIFAQAA",
    "AAIwCQYFKw4DAh0FAAOCAQEALuvHDbgdRxGdCYibUdxF3VZR4tEjETmbLdrH/nrX",
    "hOM9VHeXTRmSMGSgR8YvbZPSZHx2yCZFrVpEVOr2Syh3H3fq7HQCOGieeRRygzR0",
    "YtLBDKQL8qmwOLt80K6+v3RHFqCi0/wdubomEAbvuh1DAU5Ob1bK4O7Q+U6mYmP/",
    "2gvJFWFs7WsLxFhThg+MDBou38HyQ0jUrwp4NrJRMihswnV5P26ZZog+NNN/bZ0H",
    "5GvrhOIKu8p9OkBxsL5HnxJYMWErm0qaSY/ltAz1BE08zrzSeRXZKPQjVnefOGQ+",
    "A4iSBCZ2ubXfGdB4S3pgQCOR8RUiK7TnAlSpFiFbYJapXAAAAAAAAAAAAAAAAAAA",
    "AAA=",
].joined()
