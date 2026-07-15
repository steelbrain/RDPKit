import Foundation
import CryptoKit
import Security

private enum RDPLicenseSecurityFlags {
    static let encrypted: UInt16 = 0x0008
    static let licensePacket: UInt16 = 0x0080
}

private enum RDPLicensePreambleFlags {
    static let versionMask: UInt8 = 0x0F
    static let extendedErrorSupported: UInt8 = 0x80
    static let allowedMask: UInt8 = versionMask | extendedErrorSupported
    static let version2: UInt8 = 0x02
    static let version3: UInt8 = 0x03
}

private enum RDPLicenseBinaryBlobType {
    static let data: UInt16 = 0x0001
    static let random: UInt16 = 0x0002
    static let certificate: UInt16 = 0x0003
    static let error: UInt16 = 0x0004
    static let encryptedData: UInt16 = 0x0009
    static let keyExchangeAlgorithms: UInt16 = 0x000D
    static let scope: UInt16 = 0x000E
    static let clientUserName: UInt16 = 0x000F
    static let clientMachineName: UInt16 = 0x0010
}

private enum RDPLicenseErrorCode {
    static let invalidMAC: UInt32 = 0x0000_0003
    static let invalidScope: UInt32 = 0x0000_0004
    static let noLicenseServer: UInt32 = 0x0000_0006
    static let validClient: UInt32 = 0x0000_0007
    static let invalidClient: UInt32 = 0x0000_0008
    static let invalidProductID: UInt32 = 0x0000_000B
    static let invalidMessageLength: UInt32 = 0x0000_000C
}

private enum RDPLicenseStateTransition {
    static let totalAbort: UInt32 = 0x0000_0001
    static let noTransition: UInt32 = 0x0000_0002
    static let resetPhaseToStart: UInt32 = 0x0000_0003
    static let resendLastMessage: UInt32 = 0x0000_0004
}

public struct RDPStoredClientLicense: Codable, Equatable, Sendable {
    public var version: UInt32
    public var scope: String
    public var companyName: String
    public var productID: String
    public var licenseInfo: Data

    public init(
        version: UInt32,
        scope: String,
        companyName: String,
        productID: String,
        licenseInfo: Data
    ) {
        self.version = version
        self.scope = scope
        self.companyName = companyName
        self.productID = productID
        self.licenseInfo = licenseInfo
    }

    func matches(_ request: RDPServerLicensePDU) -> Bool {
        guard request.productVersion == version,
              request.productCompanyName == companyName,
              request.productID == productID,
              !licenseInfo.isEmpty else {
            return false
        }
        return request.scopes.isEmpty || request.scopes.contains(scope)
    }
}

struct RDPServerLicensePDU: Equatable, Sendable {
    var channelID: UInt16
    var securityFlags: UInt16
    var messageType: UInt8
    var flags: UInt8
    var messageSize: UInt16
    var errorCode: UInt32?
    var stateTransition: UInt32?
    var serverRandom: Data?
    var productVersion: UInt32?
    var productCompanyName: String?
    var productID: String?
    var keyExchangeAlgorithms: [UInt32]
    var certificateByteCount: Int?
    var serverCertificatePublicKey: RDPRSAPublicKey?
    var scopeCount: UInt32?
    var scopes: [String]
    var encryptedPlatformChallenge: Data?
    var platformChallengeMAC: Data?
    var encryptedLicenseInfo: Data?
    var licenseInfoMAC: Data?

    var typeName: String {
        switch messageType {
        case 0x01:
            return "license-request"
        case 0x02:
            return "license-platform-challenge"
        case 0x03:
            return "license-new-license"
        case 0x04:
            return "license-upgrade-license"
        case 0xFF:
            guard errorCode == RDPLicenseErrorCode.validClient,
                  stateTransition == RDPLicenseStateTransition.noTransition
            else {
                return "license-error-0x\(String(format: "%08x", errorCode ?? 0))"
            }
            return "license-error-valid-client"
        default:
            return "license-message-0x\(String(format: "%02x", messageType))"
        }
    }

    static func parseIfPresent(fromTPKT packet: Data) throws -> RDPServerLicensePDU? {
        guard let indication = try? MCSSendDataIndicationPDU.parse(fromTPKT: packet) else {
            return nil
        }
        guard indication.userData.count >= 4 else {
            return nil
        }

        var cursor = ByteCursor(indication.userData)
        let securityFlags = try cursor.readLittleEndianUInt16()
        _ = try cursor.readLittleEndianUInt16()
        guard securityFlags & RDPLicenseSecurityFlags.licensePacket != 0 else {
            return nil
        }
        guard securityFlags & RDPLicenseSecurityFlags.encrypted == 0 else {
            throw RDPDecodeError.invalidLicensePDU
        }
        guard cursor.remaining >= 4 else {
            throw RDPDecodeError.invalidLicensePDU
        }

        let messageType = try cursor.readUInt8()
        let flags = try cursor.readUInt8()
        let messageSize = try cursor.readLittleEndianUInt16()
        guard licensePreambleFlagsAreValid(flags),
              serverLicenseMessageTypeIsValid(messageType),
              messageSize >= 4,
              Int(messageSize) == cursor.remaining + 4
        else {
            throw RDPDecodeError.invalidLicensePDU
        }
        let messageBody = try cursor.readData(count: Int(messageSize) - 4)

        var errorCode: UInt32?
        var stateTransition: UInt32?
        var serverLicenseRequest: RDPServerLicenseRequest?
        var serverPlatformChallenge: RDPServerPlatformChallenge?
        var serverEncryptedLicense: RDPServerEncryptedLicense?
        switch messageType {
        case 0x01:
            serverLicenseRequest = try RDPServerLicenseRequest.parse(messageBody)
        case 0x02:
            serverPlatformChallenge = try RDPServerPlatformChallenge.parse(messageBody)
        case 0x03, 0x04:
            serverEncryptedLicense = try RDPServerEncryptedLicense.parse(messageBody)
        case 0xFF:
            var messageCursor = ByteCursor(messageBody)
            guard messageCursor.remaining >= 12 else {
                throw RDPDecodeError.invalidLicensePDU
            }
            errorCode = try messageCursor.readLittleEndianUInt32()
            stateTransition = try messageCursor.readLittleEndianUInt32()
            guard serverLicenseErrorCodeIsValid(errorCode),
                  licenseStateTransitionIsValid(stateTransition)
            else {
                throw RDPDecodeError.invalidLicensePDU
            }
            let blobType = try messageCursor.readLittleEndianUInt16()
            let blobLength = try messageCursor.readLittleEndianUInt16()
            guard blobType == RDPLicenseBinaryBlobType.error,
                  Int(blobLength) == messageCursor.remaining
            else {
                throw RDPDecodeError.invalidLicensePDU
            }
            _ = try messageCursor.readData(count: Int(blobLength))
            if errorCode == RDPLicenseErrorCode.validClient,
               stateTransition != RDPLicenseStateTransition.noTransition || blobLength != 0 {
                throw RDPDecodeError.invalidLicensePDU
            }
        default:
            break
        }

        return RDPServerLicensePDU(
            channelID: indication.channelID,
            securityFlags: securityFlags,
            messageType: messageType,
            flags: flags,
            messageSize: messageSize,
            errorCode: errorCode,
            stateTransition: stateTransition,
            serverRandom: serverLicenseRequest?.serverRandom,
            productVersion: serverLicenseRequest?.productVersion,
            productCompanyName: serverLicenseRequest?.companyName,
            productID: serverLicenseRequest?.productID,
            keyExchangeAlgorithms: serverLicenseRequest?.keyExchangeAlgorithms ?? [],
            certificateByteCount: serverLicenseRequest?.certificateByteCount,
            serverCertificatePublicKey: serverLicenseRequest?.serverCertificatePublicKey,
            scopeCount: serverLicenseRequest?.scopeCount,
            scopes: serverLicenseRequest?.scopes ?? [],
            encryptedPlatformChallenge: serverPlatformChallenge?.encryptedChallenge,
            platformChallengeMAC: serverPlatformChallenge?.mac,
            encryptedLicenseInfo: serverEncryptedLicense?.encryptedLicenseInfo,
            licenseInfoMAC: serverEncryptedLicense?.mac
        )
    }
}

struct RDPClientNewLicenseRequestPDU: Equatable, Sendable {
    static let preferredKeyExchangeAlgorithm: UInt32 = 0x0000_0001
    static let platformID: UInt32 = 0x0401_0000
    static let clientRandomByteCount = 32
    static let premasterSecretByteCount = 48

    var channelID: UInt16
    var clientRandom: Data
    var premasterSecret: Data?
    var encryptedPremasterSecret: Data
    var username: String
    var machineName: String

    init(
        channelID: UInt16,
        serverPublicKey: RDPRSAPublicKey,
        username: String,
        machineName: String,
        randomBytes: (Int) throws -> Data = secureRandomData(count:)
    ) throws {
        let clientRandom = try randomBytes(Self.clientRandomByteCount)
        let premasterSecret = try randomBytes(Self.premasterSecretByteCount)
        guard clientRandom.count == Self.clientRandomByteCount,
              premasterSecret.count == Self.premasterSecretByteCount else {
            throw RDPDecodeError.invalidLicensePDU
        }

        self.channelID = channelID
        self.clientRandom = clientRandom
        self.premasterSecret = premasterSecret
        encryptedPremasterSecret = try serverPublicKey.encryptRawLittleEndian(premasterSecret)
        self.username = username
        self.machineName = machineName
    }

    init(
        channelID: UInt16,
        clientRandom: Data,
        premasterSecret: Data? = nil,
        encryptedPremasterSecret: Data,
        username: String,
        machineName: String
    ) {
        self.channelID = channelID
        self.clientRandom = clientRandom
        self.premasterSecret = premasterSecret
        self.encryptedPremasterSecret = encryptedPremasterSecret
        self.username = username
        self.machineName = machineName
    }

    func encodedTPKT(userChannelID: UInt16) throws -> Data {
        MCSSendDataRequestPDU(
            initiator: userChannelID,
            channelID: channelID,
            userData: try encodedUserData()
        ).encodedTPKT()
    }

    func encodedUserData() throws -> Data {
        guard clientRandom.count == Self.clientRandomByteCount,
              !encryptedPremasterSecret.isEmpty else {
            throw RDPDecodeError.invalidLicensePDU
        }

        var body = Data()
        body.appendLittleEndianUInt32(Self.preferredKeyExchangeAlgorithm)
        body.appendLittleEndianUInt32(Self.platformID)
        body.append(clientRandom)
        try appendLicenseBlob(type: RDPLicenseBinaryBlobType.random, payload: encryptedPremasterSecret, to: &body)
        try appendLicenseBlob(
            type: RDPLicenseBinaryBlobType.clientUserName,
            payload: try nullTerminatedANSI(username),
            to: &body
        )
        try appendLicenseBlob(
            type: RDPLicenseBinaryBlobType.clientMachineName,
            payload: try nullTerminatedANSI(machineName),
            to: &body
        )

        return try licenseUserData(messageType: 0x13, body: body)
    }
}

struct RDPClientLicenseInformationPDU: Equatable, Sendable {
    var channelID: UInt16
    var clientRandom: Data
    var premasterSecret: Data?
    var encryptedPremasterSecret: Data
    var storedLicense: RDPStoredClientLicense
    var encryptedHardwareID: Data
    var mac: Data

    init(
        channelID: UInt16,
        serverPublicKey: RDPRSAPublicKey,
        serverRandom: Data,
        storedLicense: RDPStoredClientLicense,
        randomBytes: (Int) throws -> Data = secureRandomData(count:)
    ) throws {
        let clientRandom = try randomBytes(RDPClientNewLicenseRequestPDU.clientRandomByteCount)
        let premasterSecret = try randomBytes(RDPClientNewLicenseRequestPDU.premasterSecretByteCount)
        guard clientRandom.count == RDPClientNewLicenseRequestPDU.clientRandomByteCount,
              premasterSecret.count == RDPClientNewLicenseRequestPDU.premasterSecretByteCount,
              !storedLicense.licenseInfo.isEmpty else {
            throw RDPDecodeError.invalidLicensePDU
        }

        let keys = try RDPLicenseKeys.derive(
            clientRandom: clientRandom,
            serverRandom: serverRandom,
            premasterSecret: premasterSecret
        )
        let hardwareID = clientHardwareID()

        self.channelID = channelID
        self.clientRandom = clientRandom
        self.premasterSecret = premasterSecret
        encryptedPremasterSecret = try serverPublicKey.encryptRawLittleEndian(premasterSecret)
        self.storedLicense = storedLicense
        encryptedHardwareID = keys.encrypt(hardwareID)
        mac = keys.mac(hardwareID)
    }

    init(
        channelID: UInt16,
        clientRandom: Data,
        premasterSecret: Data? = nil,
        encryptedPremasterSecret: Data,
        storedLicense: RDPStoredClientLicense,
        encryptedHardwareID: Data,
        mac: Data
    ) {
        self.channelID = channelID
        self.clientRandom = clientRandom
        self.premasterSecret = premasterSecret
        self.encryptedPremasterSecret = encryptedPremasterSecret
        self.storedLicense = storedLicense
        self.encryptedHardwareID = encryptedHardwareID
        self.mac = mac
    }

    func encodedTPKT(userChannelID: UInt16) throws -> Data {
        MCSSendDataRequestPDU(
            initiator: userChannelID,
            channelID: channelID,
            userData: try encodedUserData()
        ).encodedTPKT()
    }

    func encodedUserData() throws -> Data {
        guard clientRandom.count == RDPClientNewLicenseRequestPDU.clientRandomByteCount,
              !encryptedPremasterSecret.isEmpty,
              !storedLicense.licenseInfo.isEmpty,
              !encryptedHardwareID.isEmpty,
              mac.count == 16 else {
            throw RDPDecodeError.invalidLicensePDU
        }

        var body = Data()
        body.appendLittleEndianUInt32(RDPClientNewLicenseRequestPDU.preferredKeyExchangeAlgorithm)
        body.appendLittleEndianUInt32(RDPClientNewLicenseRequestPDU.platformID)
        body.append(clientRandom)
        try appendLicenseBlob(type: RDPLicenseBinaryBlobType.random, payload: encryptedPremasterSecret, to: &body)
        try appendLicenseBlob(type: RDPLicenseBinaryBlobType.data, payload: storedLicense.licenseInfo, to: &body)
        try appendLicenseBlob(type: RDPLicenseBinaryBlobType.data, payload: encryptedHardwareID, to: &body)
        body.append(mac)
        return try licenseUserData(messageType: 0x12, body: body)
    }
}

struct RDPClientPlatformChallengeResponsePDU: Equatable, Sendable {
    static let platformChallengeVersion: UInt16 = 0x0100
    static let win32ClientType: UInt16 = 0x0100
    static let licenseDetailDetail: UInt16 = 0x0003

    var channelID: UInt16
    var encryptedPlatformChallengeResponse: Data
    var encryptedHardwareID: Data
    var mac: Data

    init(channelID: UInt16, platformChallenge: Data, keys: RDPLicenseKeys) throws {
        guard platformChallenge.count <= Int(UInt16.max) else {
            throw RDPDecodeError.invalidLicensePDU
        }

        self.channelID = channelID

        var responseData = Data()
        responseData.appendLittleEndianUInt16(Self.platformChallengeVersion)
        responseData.appendLittleEndianUInt16(Self.win32ClientType)
        responseData.appendLittleEndianUInt16(Self.licenseDetailDetail)
        responseData.appendLittleEndianUInt16(UInt16(platformChallenge.count))
        responseData.append(platformChallenge)

        let hardwareID = clientHardwareID()

        encryptedPlatformChallengeResponse = keys.encrypt(responseData)
        encryptedHardwareID = keys.encrypt(hardwareID)
        mac = keys.mac(responseData + hardwareID)
    }

    func encodedTPKT(userChannelID: UInt16) throws -> Data {
        MCSSendDataRequestPDU(
            initiator: userChannelID,
            channelID: channelID,
            userData: try encodedUserData()
        ).encodedTPKT()
    }

    func encodedUserData() throws -> Data {
        guard !encryptedPlatformChallengeResponse.isEmpty,
              !encryptedHardwareID.isEmpty,
              mac.count == 16 else {
            throw RDPDecodeError.invalidLicensePDU
        }

        var body = Data()
        try appendLicenseBlob(
            type: RDPLicenseBinaryBlobType.encryptedData,
            payload: encryptedPlatformChallengeResponse,
            to: &body
        )
        try appendLicenseBlob(
            type: RDPLicenseBinaryBlobType.encryptedData,
            payload: encryptedHardwareID,
            to: &body
        )
        body.append(mac)
        return try licenseUserData(messageType: 0x15, body: body)
    }
}

struct RDPLicenseKeys: Equatable, Sendable {
    var macSaltKey: Data
    var licensingEncryptionKey: Data

    static func derive(clientRandom: Data, serverRandom: Data, premasterSecret: Data) throws -> RDPLicenseKeys {
        guard clientRandom.count == 32,
              serverRandom.count == 32,
              premasterSecret.count == 48 else {
            throw RDPDecodeError.invalidLicensePDU
        }

        let masterSecret = saltedHash(premasterSecret, salt: Data([0x41]), clientRandom: clientRandom, serverRandom: serverRandom)
            + saltedHash(premasterSecret, salt: Data([0x42, 0x42]), clientRandom: clientRandom, serverRandom: serverRandom)
            + saltedHash(premasterSecret, salt: Data([0x43, 0x43, 0x43]), clientRandom: clientRandom, serverRandom: serverRandom)
        let sessionKeyBlob = saltedHash2(masterSecret, salt: Data([0x41]), clientRandom: clientRandom, serverRandom: serverRandom)
            + saltedHash2(masterSecret, salt: Data([0x42, 0x42]), clientRandom: clientRandom, serverRandom: serverRandom)
            + saltedHash2(masterSecret, salt: Data([0x43, 0x43, 0x43]), clientRandom: clientRandom, serverRandom: serverRandom)
        return RDPLicenseKeys(
            macSaltKey: Data(sessionKeyBlob.prefix(16)),
            licensingEncryptionKey: md5(Data(sessionKeyBlob.dropFirst(16).prefix(16)) + clientRandom + serverRandom)
        )
    }

    func encrypt(_ data: Data) -> Data {
        RDPLicenseRC4(key: licensingEncryptionKey).process(data)
    }

    func decrypt(_ data: Data) -> Data {
        encrypt(data)
    }

    func mac(_ data: Data) -> Data {
        var length = Data()
        length.appendLittleEndianUInt32(UInt32(data.count))
        let inner = sha1(macSaltKey + Data(repeating: 0x36, count: 40) + length + data)
        return md5(macSaltKey + Data(repeating: 0x5C, count: 48) + inner)
    }

    private static func saltedHash(_ secret: Data, salt: Data, clientRandom: Data, serverRandom: Data) -> Data {
        md5(secret + sha1(salt + secret + clientRandom + serverRandom))
    }

    private static func saltedHash2(_ secret: Data, salt: Data, clientRandom: Data, serverRandom: Data) -> Data {
        md5(secret + sha1(salt + secret + serverRandom + clientRandom))
    }
}

private struct RDPServerPlatformChallenge: Equatable {
    var encryptedChallenge: Data
    var mac: Data

    static func parse(_ body: Data) throws -> RDPServerPlatformChallenge {
        var cursor = ByteCursor(body)
        guard cursor.remaining >= 24 else {
            throw RDPDecodeError.invalidLicensePDU
        }
        _ = try cursor.readLittleEndianUInt32()
        let encryptedChallenge = try readLicenseBlob(&cursor)
        guard !encryptedChallenge.data.isEmpty,
              cursor.remaining == 16
        else {
            throw RDPDecodeError.invalidLicensePDU
        }
        return RDPServerPlatformChallenge(
            encryptedChallenge: encryptedChallenge.data,
            mac: try cursor.readData(count: 16)
        )
    }
}

private func licenseUserData(messageType: UInt8, body: Data) throws -> Data {
    guard body.count <= Int(UInt16.max) - 4 else {
        throw RDPDecodeError.invalidLicensePDU
    }

    var payload = Data()
    payload.appendLittleEndianUInt16(RDPLicenseSecurityFlags.licensePacket)
    payload.appendLittleEndianUInt16(0)
    payload.appendUInt8(messageType)
    payload.appendUInt8(RDPLicensePreambleFlags.version3)
    payload.appendLittleEndianUInt16(UInt16(body.count + 4))
    payload.append(body)
    return payload
}

struct RDPServerNewLicenseInformation: Equatable, Sendable {
    var version: UInt32
    var scope: String
    var companyName: String
    var productID: String
    var licenseInfo: Data

    var storedClientLicense: RDPStoredClientLicense {
        RDPStoredClientLicense(
            version: version,
            scope: scope,
            companyName: companyName,
            productID: productID,
            licenseInfo: licenseInfo
        )
    }

    static func parse(_ data: Data) throws -> RDPServerNewLicenseInformation {
        var cursor = ByteCursor(data)
        guard cursor.remaining >= 20 else {
            throw RDPDecodeError.invalidLicensePDU
        }

        let version = try cursor.readLittleEndianUInt32()
        let scope = try readNullTerminatedANSIString(
            from: &cursor,
            byteCount: try cursor.readLittleEndianUInt32()
        )
        let companyName = try readNullTerminatedUnicodeString(
            from: &cursor,
            byteCount: try cursor.readLittleEndianUInt32()
        )
        let productID = try readNullTerminatedUnicodeString(
            from: &cursor,
            byteCount: try cursor.readLittleEndianUInt32()
        )
        let licenseInfoByteCount = try cursor.readLittleEndianUInt32()
        guard licenseInfoByteCount > 0,
              licenseInfoByteCount <= UInt32(cursor.remaining) else {
            throw RDPDecodeError.invalidLicensePDU
        }
        let licenseInfo = try cursor.readData(count: Int(licenseInfoByteCount))
        guard cursor.remaining == 0 else {
            throw RDPDecodeError.invalidLicensePDU
        }

        return RDPServerNewLicenseInformation(
            version: version,
            scope: scope,
            companyName: companyName,
            productID: productID,
            licenseInfo: licenseInfo
        )
    }
}

private struct RDPServerEncryptedLicense: Equatable {
    var encryptedLicenseInfo: Data
    var mac: Data

    static func parse(_ body: Data) throws -> RDPServerEncryptedLicense {
        var cursor = ByteCursor(body)
        let encryptedLicenseInfo = try readLicenseBlob(&cursor)
        guard !encryptedLicenseInfo.data.isEmpty,
              cursor.remaining == 16
        else {
            throw RDPDecodeError.invalidLicensePDU
        }
        return RDPServerEncryptedLicense(
            encryptedLicenseInfo: encryptedLicenseInfo.data,
            mac: try cursor.readData(count: 16)
        )
    }
}

private func serverLicenseMessageTypeIsValid(_ messageType: UInt8) -> Bool {
    switch messageType {
    case 0x01, 0x02, 0x03, 0x04, 0xFF:
        true
    default:
        false
    }
}

private func serverLicenseErrorCodeIsValid(_ errorCode: UInt32?) -> Bool {
    guard let errorCode else {
        return false
    }
    switch errorCode {
    case RDPLicenseErrorCode.invalidMAC,
         RDPLicenseErrorCode.invalidScope,
         RDPLicenseErrorCode.noLicenseServer,
         RDPLicenseErrorCode.validClient,
         RDPLicenseErrorCode.invalidClient,
         RDPLicenseErrorCode.invalidProductID,
         RDPLicenseErrorCode.invalidMessageLength:
        return true
    default:
        return false
    }
}

private func licenseStateTransitionIsValid(_ stateTransition: UInt32?) -> Bool {
    guard let stateTransition else {
        return false
    }
    switch stateTransition {
    case RDPLicenseStateTransition.totalAbort,
         RDPLicenseStateTransition.noTransition,
         RDPLicenseStateTransition.resetPhaseToStart,
         RDPLicenseStateTransition.resendLastMessage:
        return true
    default:
        return false
    }
}

private struct RDPServerLicenseRequest: Equatable {
    var serverRandom: Data
    var productVersion: UInt32
    var companyName: String
    var productID: String
    var keyExchangeAlgorithms: [UInt32]
    var certificateByteCount: Int
    var serverCertificatePublicKey: RDPRSAPublicKey?
    var scopeCount: UInt32
    var scopes: [String]

    static func parse(_ body: Data) throws -> RDPServerLicenseRequest {
        var cursor = ByteCursor(body)
        guard cursor.remaining >= 32 else {
            throw RDPDecodeError.invalidLicensePDU
        }
        let serverRandom = try cursor.readData(count: 32)
        let product = try parseProductInfo(&cursor)
        let keyExchangeList = try readLicenseBlob(&cursor)
        guard keyExchangeList.type == RDPLicenseBinaryBlobType.keyExchangeAlgorithms,
              !keyExchangeList.data.isEmpty,
              keyExchangeList.data.count.isMultiple(of: 4)
        else {
            throw RDPDecodeError.invalidLicensePDU
        }
        var keyExchangeCursor = ByteCursor(keyExchangeList.data)
        var keyExchangeAlgorithms: [UInt32] = []
        while keyExchangeCursor.remaining > 0 {
            keyExchangeAlgorithms.append(try keyExchangeCursor.readLittleEndianUInt32())
        }
        guard keyExchangeAlgorithms.contains(0x0000_0001) else {
            throw RDPDecodeError.invalidLicensePDU
        }

        let certificate = try readLicenseBlob(&cursor)
        guard certificate.type == RDPLicenseBinaryBlobType.certificate || certificate.data.isEmpty else {
            throw RDPDecodeError.invalidLicensePDU
        }
        let serverCertificatePublicKey: RDPRSAPublicKey?
        if !certificate.data.isEmpty {
            do {
                try validateRDPServerCertificate(certificate.data)
                serverCertificatePublicKey = try rdpServerCertificatePublicKey(certificate.data)
            } catch {
                throw RDPDecodeError.invalidLicensePDU
            }
        } else {
            serverCertificatePublicKey = nil
        }

        let scopeCount = try cursor.readLittleEndianUInt32()
        guard scopeCount <= UInt32(cursor.remaining / 4) else {
            throw RDPDecodeError.invalidLicensePDU
        }
        var scopes: [String] = []
        scopes.reserveCapacity(Int(scopeCount))
        for _ in 0 ..< scopeCount {
            let scope = try readLicenseBlob(&cursor)
            guard scope.type == RDPLicenseBinaryBlobType.scope || scope.data.isEmpty else {
                throw RDPDecodeError.invalidLicensePDU
            }
            if !scope.data.isEmpty {
                var scopeCursor = ByteCursor(scope.data)
                let scopeName = try readNullTerminatedANSIString(
                    from: &scopeCursor,
                    byteCount: UInt32(scope.data.count)
                )
                guard scopeCursor.remaining == 0 else {
                    throw RDPDecodeError.invalidLicensePDU
                }
                scopes.append(scopeName)
            }
        }
        guard cursor.remaining == 0 else {
            throw RDPDecodeError.invalidLicensePDU
        }

        return RDPServerLicenseRequest(
            serverRandom: serverRandom,
            productVersion: product.version,
            companyName: product.companyName,
            productID: product.productID,
            keyExchangeAlgorithms: keyExchangeAlgorithms,
            certificateByteCount: certificate.data.count,
            serverCertificatePublicKey: serverCertificatePublicKey,
            scopeCount: scopeCount,
            scopes: scopes
        )
    }

    private static func parseProductInfo(_ cursor: inout ByteCursor) throws -> (
        version: UInt32,
        companyName: String,
        productID: String
    ) {
        let version = try cursor.readLittleEndianUInt32()
        let companyNameByteCount = try cursor.readLittleEndianUInt32()
        let companyName = try readNullTerminatedUnicodeString(
            from: &cursor,
            byteCount: companyNameByteCount
        )
        let productIDByteCount = try cursor.readLittleEndianUInt32()
        let productID = try readNullTerminatedUnicodeString(
            from: &cursor,
            byteCount: productIDByteCount
        )
        return (version, companyName, productID)
    }
}

private func readLicenseBlob(_ cursor: inout ByteCursor) throws -> (type: UInt16, data: Data) {
    let type = try cursor.readLittleEndianUInt16()
    let length = try Int(cursor.readLittleEndianUInt16())
    guard length <= cursor.remaining else {
        throw RDPDecodeError.invalidLicensePDU
    }
    return (type, try cursor.readData(count: length))
}

private func appendLicenseBlob(type: UInt16, payload: Data, to data: inout Data) throws {
    guard payload.count <= Int(UInt16.max) else {
        throw RDPDecodeError.invalidLicensePDU
    }

    data.appendLittleEndianUInt16(type)
    data.appendLittleEndianUInt16(UInt16(payload.count))
    data.append(payload)
}

private func clientHardwareID() -> Data {
    var hardwareID = Data()
    hardwareID.appendLittleEndianUInt32(RDPClientNewLicenseRequestPDU.platformID)
    hardwareID.append(Data(repeating: 0, count: 16))
    return hardwareID
}

private func nullTerminatedANSI(_ value: String) throws -> Data {
    guard value.allSatisfy({ $0.isASCII && !$0.isNewline }) else {
        throw RDPDecodeError.invalidLicensePDU
    }
    var data = Data(value.utf8)
    data.append(0)
    return data
}

private func md5(_ data: Data) -> Data {
    Data(Insecure.MD5.hash(data: data))
}

private func sha1(_ data: Data) -> Data {
    Data(Insecure.SHA1.hash(data: data))
}

private func secureRandomData(count: Int) throws -> Data {
    var data = Data(count: count)
    let status = data.withUnsafeMutableBytes { buffer in
        guard let baseAddress = buffer.baseAddress else {
            return errSecAllocate
        }
        return SecRandomCopyBytes(kSecRandomDefault, count, baseAddress)
    }
    guard status == errSecSuccess else {
        throw RDPDecodeError.invalidLicensePDU
    }
    return data
}

private final class RDPLicenseRC4 {
    private var state = Array(UInt8.min ... UInt8.max)
    private var i = 0
    private var j = 0

    init(key: Data) {
        var keyIndex = 0
        var j = 0
        for i in 0 ..< 256 {
            j = (j + Int(state[i]) + Int(key[key.index(key.startIndex, offsetBy: keyIndex)])) & 0xFF
            state.swapAt(i, j)
            keyIndex = (keyIndex + 1) % key.count
        }
    }

    func process(_ data: Data) -> Data {
        var output = Data()
        output.reserveCapacity(data.count)
        for byte in data {
            i = (i + 1) & 0xFF
            j = (j + Int(state[i])) & 0xFF
            state.swapAt(i, j)
            let keyByte = state[(Int(state[i]) + Int(state[j])) & 0xFF]
            output.append(byte ^ keyByte)
        }
        return output
    }
}

private func readNullTerminatedUnicodeString(
    from cursor: inout ByteCursor,
    byteCount: UInt32
) throws -> String {
    guard byteCount > 0,
          Int(byteCount) <= cursor.remaining,
          byteCount.isMultiple(of: 2)
    else {
        throw RDPDecodeError.invalidLicensePDU
    }
    let bytes = try cursor.readData(count: Int(byteCount))
    guard bytes.count >= 2,
          bytes[bytes.count - 2] == 0,
          bytes[bytes.count - 1] == 0
    else {
        throw RDPDecodeError.invalidLicensePDU
    }

    var codeUnits: [UInt16] = []
    codeUnits.reserveCapacity(bytes.count / 2)
    var index = bytes.startIndex
    while index < bytes.endIndex {
        codeUnits.append(UInt16(bytes[index]) | UInt16(bytes[bytes.index(after: index)]) << 8)
        index = bytes.index(index, offsetBy: 2)
    }
    codeUnits.removeLast()
    return String(decoding: codeUnits, as: UTF16.self)
}

private func readNullTerminatedANSIString(
    from cursor: inout ByteCursor,
    byteCount: UInt32
) throws -> String {
    guard byteCount > 0,
          Int(byteCount) <= cursor.remaining else {
        throw RDPDecodeError.invalidLicensePDU
    }
    let bytes = try cursor.readData(count: Int(byteCount))
    guard bytes.last == 0,
          bytes.dropLast().allSatisfy({ $0 < 0x80 }) else {
        throw RDPDecodeError.invalidLicensePDU
    }
    return String(decoding: bytes.dropLast(), as: UTF8.self)
}

private func licensePreambleFlagsAreValid(_ flags: UInt8) -> Bool {
    guard flags & ~RDPLicensePreambleFlags.allowedMask == 0 else {
        return false
    }

    switch flags & RDPLicensePreambleFlags.versionMask {
    case RDPLicensePreambleFlags.version2, RDPLicensePreambleFlags.version3:
        return true
    default:
        return false
    }
}
