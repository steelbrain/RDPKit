import Foundation
@testable import RDPKit
import Testing

@Test func parsesServerLicenseRequest() throws {
    let license = try #require(try RDPServerLicensePDU.parseIfPresent(fromTPKT: mcsSendDataIndication(
        channelID: 1003,
        userData: serverLicenseRequestUserData()
    )))

    #expect(license.typeName == "license-request")
    #expect(license.channelID == 1003)
    #expect(license.securityFlags == 0x0080)
    #expect(license.messageType == 0x01)
    #expect(license.serverRandom == Data(0 ..< 32))
    #expect(license.productVersion == 0x0006_0001)
    #expect(license.productCompanyName == "Microsoft Corporation")
    #expect(license.productID == "A02")
    #expect(license.keyExchangeAlgorithms == [0x0000_0001])
    #expect(license.certificateByteCount == 0)
    #expect(license.scopeCount == 1)
    #expect(license.scopes == ["localhost"])
}

@Test func parsesLicenseErrorValidClientFromServerPacket() throws {
    let license = try #require(try RDPServerLicensePDU.parseIfPresent(fromTPKT: mcsSendDataIndication(
        channelID: 1003,
        userData: Data([
            0x80, 0x00, 0x00, 0x00,
            0xFF, 0x03, 0x10, 0x00,
            0x07, 0x00, 0x00, 0x00,
            0x02, 0x00, 0x00, 0x00,
            0x04, 0x00, 0x00, 0x00,
        ])
    )))

    #expect(license.channelID == 1003)
    #expect(license.securityFlags == 0x0080)
    #expect(license.messageType == 0xFF)
    #expect(license.messageSize == 16)
    #expect(license.errorCode == 0x0000_0007)
    #expect(license.stateTransition == 0x0000_0002)
    #expect(license.typeName == "license-error-valid-client")
}

@Test func rejectsServerLicenseRequestWithInvalidProductString() throws {
    #expect(throws: RDPDecodeError.invalidLicensePDU) {
        try RDPServerLicensePDU.parseIfPresent(fromTPKT: mcsSendDataIndication(
            channelID: 1003,
            userData: serverLicenseRequestUserData(companyName: Data([0x4D, 0x00]))
        ))
    }
}

@Test func rejectsServerLicenseRequestWithoutRSAKeyExchange() throws {
    #expect(throws: RDPDecodeError.invalidLicensePDU) {
        try RDPServerLicensePDU.parseIfPresent(fromTPKT: mcsSendDataIndication(
            channelID: 1003,
            userData: serverLicenseRequestUserData(keyExchangeAlgorithms: [0x0000_0002])
        ))
    }
}

@Test func acceptsEmptyServerLicenseRequestBlobsWithIgnoredTypes() throws {
    let license = try #require(try RDPServerLicensePDU.parseIfPresent(fromTPKT: mcsSendDataIndication(
        channelID: 1003,
        userData: serverLicenseRequestUserData(
            certificateType: 0x1234,
            scopeType: 0x5678,
            scopePayload: Data()
        )
    )))

    #expect(license.typeName == "license-request")
    #expect(license.certificateByteCount == 0)
    #expect(license.scopeCount == 1)
}

@Test func rejectsServerLicenseRequestWithImpossibleScopeCount() {
    #expect(throws: RDPDecodeError.invalidLicensePDU) {
        try RDPServerLicensePDU.parseIfPresent(fromTPKT: mcsSendDataIndication(
            channelID: 1003,
            userData: serverLicenseRequestUserData(scopeCount: UInt32.max, scopePayload: nil)
        ))
    }
}

@Test func parsesServerLicenseRequestWithCertificate() throws {
    let certificate = proprietaryServerCertificate()
    let license = try #require(try RDPServerLicensePDU.parseIfPresent(fromTPKT: mcsSendDataIndication(
        channelID: 1003,
        userData: serverLicenseRequestUserData(certificatePayload: certificate)
    )))

    #expect(license.typeName == "license-request")
    #expect(license.certificateByteCount == certificate.count)
}

@Test func parsesServerLicenseRequestWithX509CertificateChain() throws {
    let certificate = try MockKRDPTLS.rdpX509CertificateChain()
    let license = try #require(try RDPServerLicensePDU.parseIfPresent(fromTPKT: mcsSendDataIndication(
        channelID: 1003,
        userData: serverLicenseRequestUserData(certificatePayload: certificate)
    )))
    let publicKey = try #require(license.serverCertificatePublicKey)

    #expect(license.typeName == "license-request")
    #expect(license.certificateByteCount == certificate.count)
    #expect(publicKey.publicExponent == 0x0001_0001)
    #expect(publicKey.modulus.count == 256)
    #expect(publicKey.keyByteCount == 264)
}

@Test func rejectsServerLicenseRequestWithMalformedCertificate() throws {
    var certificate = proprietaryServerCertificate()
    certificate[certificate.index(certificate.startIndex, offsetBy: 16)] = 0

    #expect(throws: RDPDecodeError.invalidLicensePDU) {
        try RDPServerLicensePDU.parseIfPresent(fromTPKT: mcsSendDataIndication(
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

@Test func storedClientLicenseMatchesServerLicenseRequestProductAndScope() throws {
    let license = try #require(try RDPServerLicensePDU.parseIfPresent(fromTPKT: mcsSendDataIndication(
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

    #expect(storedLicense.matches(license))
    #expect(RDPStoredClientLicense(
        version: 0x0006_0001,
        scope: "other",
        companyName: "Microsoft Corporation",
        productID: "A02",
        licenseInfo: Data([0x30, 0x82])
    ).matches(license) == false)
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
    let license = try #require(try RDPServerLicensePDU.parseIfPresent(fromTPKT: mcsSendDataIndication(
        channelID: 1003,
        userData: encryptedLicenseUserData(
            messageType: 0x03,
            encryptedBlobType: 0x1234,
            encryptedBlob: encryptedLicenseInfo,
            mac: mac
        )
    )))

    #expect(license.typeName == "license-new-license")
    #expect(license.encryptedLicenseInfo == encryptedLicenseInfo)
    #expect(license.licenseInfoMAC == mac)
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
        try RDPServerLicensePDU.parseIfPresent(fromTPKT: mcsSendDataIndication(
            channelID: 1003,
            userData: nonCertificate
        ))
    }
    #expect(throws: RDPDecodeError.invalidLicensePDU) {
        try RDPServerLicensePDU.parseIfPresent(fromTPKT: mcsSendDataIndication(
            channelID: 1003,
            userData: nonScope
        ))
    }
}

@Test func rejectsLicensePDUWhenMessageSizeDoesNotConsumePayload() throws {
    let packet = mcsSendDataIndication(
        channelID: 1003,
        userData: Data([
            0x80, 0x00, 0x00, 0x00,
            0xFF, 0x03, 0x10, 0x00,
            0x07, 0x00, 0x00, 0x00,
            0x02, 0x00, 0x00, 0x00,
            0x04, 0x00, 0x00, 0x00,
            0x00,
        ])
    )

    #expect(throws: RDPDecodeError.invalidLicensePDU) {
        try RDPServerLicensePDU.parseIfPresent(fromTPKT: packet)
    }
}

@Test func rejectsLicensePDUWithTruncatedPreamble() throws {
    let packet = mcsSendDataIndication(
        channelID: 1003,
        userData: Data([
            0x80, 0x00, 0x00, 0x00,
            0xFF, 0x03, 0x10,
        ])
    )

    #expect(throws: RDPDecodeError.invalidLicensePDU) {
        try RDPServerLicensePDU.parseIfPresent(fromTPKT: packet)
    }
}

@Test func rejectsLicensePDUWithInvalidPreambleFlags() throws {
    let packet = mcsSendDataIndication(
        channelID: 1003,
        userData: Data([
            0x80, 0x00, 0x00, 0x00,
            0xFF, 0x04, 0x10, 0x00,
            0x07, 0x00, 0x00, 0x00,
            0x02, 0x00, 0x00, 0x00,
            0x04, 0x00, 0x00, 0x00,
        ])
    )

    #expect(throws: RDPDecodeError.invalidLicensePDU) {
        try RDPServerLicensePDU.parseIfPresent(fromTPKT: packet)
    }
}

@Test func rejectsClientOnlyLicenseMessageTypeFromServer() throws {
    let packet = mcsSendDataIndication(
        channelID: 1003,
        userData: Data([
            0x80, 0x00, 0x00, 0x00,
            0x13, 0x03, 0x04, 0x00,
        ])
    )

    #expect(throws: RDPDecodeError.invalidLicensePDU) {
        try RDPServerLicensePDU.parseIfPresent(fromTPKT: packet)
    }
}

@Test func rejectsLicenseErrorWithInvalidBlobTypeOrLength() throws {
    let invalidBlobType = mcsSendDataIndication(
        channelID: 1003,
        userData: Data([
            0x80, 0x00, 0x00, 0x00,
            0xFF, 0x03, 0x10, 0x00,
            0x07, 0x00, 0x00, 0x00,
            0x02, 0x00, 0x00, 0x00,
            0x01, 0x00, 0x00, 0x00,
        ])
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
        try RDPServerLicensePDU.parseIfPresent(fromTPKT: invalidBlobType)
    }
    #expect(throws: RDPDecodeError.invalidLicensePDU) {
        try RDPServerLicensePDU.parseIfPresent(fromTPKT: invalidBlobLength)
    }
}

@Test func rejectsLicenseErrorWithInvalidServerErrorCodeOrStateTransition() throws {
    let clientOnlyErrorCode = licenseErrorUserData(
        errorCode: 0x0000_0001,
        stateTransition: 0x0000_0001
    )
    let invalidStateTransition = licenseErrorUserData(
        errorCode: 0x0000_0006,
        stateTransition: 0x0000_0005
    )

    #expect(throws: RDPDecodeError.invalidLicensePDU) {
        try RDPServerLicensePDU.parseIfPresent(fromTPKT: mcsSendDataIndication(
            channelID: 1003,
            userData: clientOnlyErrorCode
        ))
    }
    #expect(throws: RDPDecodeError.invalidLicensePDU) {
        try RDPServerLicensePDU.parseIfPresent(fromTPKT: mcsSendDataIndication(
            channelID: 1003,
            userData: invalidStateTransition
        ))
    }
}

@Test func rejectsValidClientLicenseErrorWithNonFinalTransitionOrBlobData() throws {
    let nonFinalTransition = licenseErrorUserData(
        errorCode: 0x0000_0007,
        stateTransition: 0x0000_0003
    )
    let nonEmptyErrorBlob = licenseErrorUserData(
        errorCode: 0x0000_0007,
        stateTransition: 0x0000_0002,
        errorBlob: Data([0x01])
    )

    #expect(throws: RDPDecodeError.invalidLicensePDU) {
        try RDPServerLicensePDU.parseIfPresent(fromTPKT: mcsSendDataIndication(
            channelID: 1003,
            userData: nonFinalTransition
        ))
    }
    #expect(throws: RDPDecodeError.invalidLicensePDU) {
        try RDPServerLicensePDU.parseIfPresent(fromTPKT: mcsSendDataIndication(
            channelID: 1003,
            userData: nonEmptyErrorBlob
        ))
    }
}

@Test func parsesNonValidClientLicenseErrorWithBlobData() throws {
    let license = try #require(try RDPServerLicensePDU.parseIfPresent(fromTPKT: mcsSendDataIndication(
        channelID: 1003,
        userData: licenseErrorUserData(
            errorCode: 0x0000_0006,
            stateTransition: 0x0000_0001,
            errorBlob: Data([0x6E, 0x6F])
        )
    )))

    #expect(license.typeName == "license-error-0x00000006")
    #expect(license.errorCode == 0x0000_0006)
    #expect(license.stateTransition == 0x0000_0001)
}

@Test func parsesOpaqueServerPlatformChallengeAndLicenseMessages() throws {
    let platformChallenge = try #require(try RDPServerLicensePDU.parseIfPresent(fromTPKT: mcsSendDataIndication(
        channelID: 1003,
        userData: platformChallengeUserData(encryptedBlobType: 0x1234)
    )))
    let newLicense = try #require(try RDPServerLicensePDU.parseIfPresent(fromTPKT: mcsSendDataIndication(
        channelID: 1003,
        userData: encryptedLicenseUserData(messageType: 0x03)
    )))
    let upgradeLicense = try #require(try RDPServerLicensePDU.parseIfPresent(fromTPKT: mcsSendDataIndication(
        channelID: 1003,
        userData: encryptedLicenseUserData(messageType: 0x04)
    )))

    #expect(platformChallenge.typeName == "license-platform-challenge")
    #expect(newLicense.typeName == "license-new-license")
    #expect(upgradeLicense.typeName == "license-upgrade-license")
}

@Test func rejectsMalformedOpaqueServerLicenseMessages() throws {
    #expect(throws: RDPDecodeError.invalidLicensePDU) {
        try RDPServerLicensePDU.parseIfPresent(fromTPKT: mcsSendDataIndication(
            channelID: 1003,
            userData: platformChallengeUserData(encryptedBlob: Data())
        ))
    }
    #expect(throws: RDPDecodeError.invalidLicensePDU) {
        try RDPServerLicensePDU.parseIfPresent(fromTPKT: mcsSendDataIndication(
            channelID: 1003,
            userData: platformChallengeUserData(mac: Data(repeating: 0, count: 15))
        ))
    }
    #expect(throws: RDPDecodeError.invalidLicensePDU) {
        try RDPServerLicensePDU.parseIfPresent(fromTPKT: mcsSendDataIndication(
            channelID: 1003,
            userData: encryptedLicenseUserData(messageType: 0x03, encryptedBlob: Data())
        ))
    }
    #expect(throws: RDPDecodeError.invalidLicensePDU) {
        try RDPServerLicensePDU.parseIfPresent(fromTPKT: mcsSendDataIndication(
            channelID: 1003,
            userData: encryptedLicenseUserData(messageType: 0x04, suffix: Data([0x00]))
        ))
    }
}

@Test func ignoresNonLicensePackets() throws {
    #expect(try RDPServerLicensePDU.parseIfPresent(fromTPKT: Data([
        0x03, 0x00, 0x00, 0x19,
        0x02, 0xF0, 0x80,
        0x68, 0x00, 0x05, 0x03, 0xED, 0x70, 0x80, 0x0A,
        0x00, 0x10, 0x00, 0x00,
        0x06, 0x00, 0x23, 0x00, 0x01, 0x10,
    ])) == nil)
}

private func mcsSendDataIndication(channelID: UInt16, userData: Data) -> Data {
    var data = Data()
    data.appendUInt8(0x68)
    data.appendBigEndianUInt16(1006 - 1001)
    data.appendBigEndianUInt16(channelID)
    data.appendUInt8(0x70)
    data.appendPERLength(userData.count)
    data.append(userData)
    return X224DataTPDU.wrap(data)
}

private func licenseErrorUserData(
    errorCode: UInt32,
    stateTransition: UInt32,
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
    payload.appendLittleEndianUInt16(0x0004)
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

private func proprietaryServerCertificate() -> Data {
    var publicKey = Data()
    publicKey.appendLittleEndianUInt32(0x3141_5352)
    publicKey.appendLittleEndianUInt32(72)
    publicKey.appendLittleEndianUInt32(512)
    publicKey.appendLittleEndianUInt32(63)
    publicKey.appendLittleEndianUInt32(0x0001_0001)
    publicKey.append(Data(repeating: 0xA5, count: 64))
    publicKey.append(Data(repeating: 0, count: 8))

    var certificate = Data()
    certificate.appendLittleEndianUInt32(1)
    certificate.appendLittleEndianUInt32(1)
    certificate.appendLittleEndianUInt32(1)
    certificate.appendLittleEndianUInt16(0x0006)
    certificate.appendLittleEndianUInt16(UInt16(publicKey.count))
    certificate.append(publicKey)
    certificate.appendLittleEndianUInt16(0x0008)
    certificate.appendLittleEndianUInt16(72)
    certificate.append(Data(repeating: 0x5A, count: 72))
    return certificate
}

private func utf16LENullTerminated(_ value: String) -> Data {
    var data = Data()
    for codeUnit in value.utf16 {
        data.appendLittleEndianUInt16(codeUnit)
    }
    data.appendLittleEndianUInt16(0)
    return data
}
