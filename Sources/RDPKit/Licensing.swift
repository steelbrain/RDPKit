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

    static func name(_ code: UInt32) -> String {
        switch code {
        case invalidMAC: "ERR_INVALID_MAC"
        case invalidScope: "ERR_INVALID_SCOPE"
        case noLicenseServer: "ERR_NO_LICENSE_SERVER"
        case validClient: "STATUS_VALID_CLIENT"
        case invalidClient: "ERR_INVALID_CLIENT"
        case invalidProductID: "ERR_INVALID_PRODUCTID"
        case invalidMessageLength: "ERR_INVALID_MESSAGE_LEN"
        default: "license error"
        }
    }
}

private enum RDPLicenseStateTransition {
    static let totalAbort: UInt32 = 0x0000_0001
    static let noTransition: UInt32 = 0x0000_0002
    static let resetPhaseToStart: UInt32 = 0x0000_0003
    static let resendLastMessage: UInt32 = 0x0000_0004

    static func name(_ transition: UInt32) -> String {
        switch transition {
        case totalAbort: "ST_TOTAL_ABORT"
        case noTransition: "ST_NO_TRANSITION"
        case resetPhaseToStart: "ST_RESET_PHASE_TO_START"
        case resendLastMessage: "ST_RESEND_LAST_MESSAGE"
        default: "state transition 0x\(String(format: "%08x", transition))"
        }
    }
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

    func matches(_ request: RDPServerLicenseRequest) -> Bool {
        guard request.productVersion == version,
              request.companyName == companyName,
              request.productID == productID,
              !licenseInfo.isEmpty else {
            return false
        }
        return request.scopes.isEmpty || request.scopes.contains(scope)
    }
}

/// A server licensing message ([MS-RDPELE] 2.2.2, [MS-RDPBCGR] 2.2.1.12.1.3).
enum RDPServerLicenseMessage: Equatable, Sendable {
    case licenseRequest(RDPServerLicenseRequest)
    case platformChallenge(RDPServerPlatformChallenge)
    case newLicense(RDPServerEncryptedLicense)
    case upgradeLicense(RDPServerEncryptedLicense)
    case errorAlert(RDPLicenseErrorAlert)
}

/// Licensing Error Message ([MS-RDPBCGR] 2.2.1.12.1.3).
struct RDPLicenseErrorAlert: Equatable, Sendable, CustomStringConvertible {
    var errorCode: UInt32
    var stateTransition: UInt32

    /// STATUS_VALID_CLIENT with ST_NO_TRANSITION: licensing is complete. Hosts
    /// in the licensing grace period send it in answer to a client license
    /// request as well as up front ([MS-RDPELE] 3.1.5.3).
    var isValidClient: Bool {
        errorCode == RDPLicenseErrorCode.validClient && stateTransition == RDPLicenseStateTransition.noTransition
    }

    var description: String {
        "\(RDPLicenseErrorCode.name(errorCode)) (0x\(String(format: "%08x", errorCode))), "
            + RDPLicenseStateTransition.name(stateTransition)
    }
}

/// A licensing PDU on the I/O channel: a security header with
/// SEC_LICENSE_PKT, a preamble and one server message ([MS-RDPBCGR] 2.2.1.12).
struct RDPServerLicensePDU: Equatable, Sendable {
    private static let serverMessageTypes: Set<UInt8> = [0x01, 0x02, 0x03, 0x04, 0xFF]

    var message: RDPServerLicenseMessage

    var typeName: String {
        switch message {
        case .licenseRequest:
            "license-request"
        case .platformChallenge:
            "license-platform-challenge"
        case .newLicense:
            "license-new-license"
        case .upgradeLicense:
            "license-upgrade-license"
        case let .errorAlert(alert):
            alert.isValidClient
                ? "license-error-valid-client"
                : "license-error-0x\(String(format: "%08x", alert.errorCode))"
        }
    }

    /// Returns nil unless `indication` starts with a licensing security header
    /// and a server preamble (message type, version 2 or 3, size). A Share
    /// Control totalLength can have the SEC_LICENSE_PKT bit set, so the caller
    /// only tries this while licensing is in progress. Throws for a malformed
    /// message once the preamble matches.
    static func parseIfPresent(from indication: MCSSendDataIndicationPDU) throws -> RDPServerLicensePDU? {
        var cursor = ByteCursor(indication.userData)
        guard cursor.remaining >= 8 else {
            return nil
        }
        let securityFlags = try cursor.readLittleEndianUInt16()
        // flagsHi is unused and may hold any value ([MS-RDPBCGR] 2.2.8.1.1.2.1, 4.1.11).
        _ = try cursor.readLittleEndianUInt16()
        let messageType = try cursor.readUInt8()
        let flags = try cursor.readUInt8()
        let messageSize = try cursor.readLittleEndianUInt16()
        guard securityFlags & RDPLicenseSecurityFlags.licensePacket != 0,
              serverMessageTypes.contains(messageType),
              licensePreambleFlagsAreValid(flags),
              Int(messageSize) == cursor.remaining + 4
        else {
            return nil
        }
        guard securityFlags & RDPLicenseSecurityFlags.encrypted == 0 else {
            throw RDPDecodeError.invalidLicensePDU
        }
        let messageBody = try cursor.readData(count: cursor.remaining)

        let message: RDPServerLicenseMessage = switch messageType {
        case 0x01: try .licenseRequest(RDPServerLicenseRequest.parse(messageBody))
        case 0x02: try .platformChallenge(RDPServerPlatformChallenge.parse(messageBody))
        case 0x03: try .newLicense(RDPServerEncryptedLicense.parse(messageBody))
        case 0x04: try .upgradeLicense(RDPServerEncryptedLicense.parse(messageBody))
        default: try .errorAlert(parseErrorAlert(messageBody))
        }
        return RDPServerLicensePDU(message: message)
    }

    /// Any error code or state transition is kept so a failure can name it.
    private static func parseErrorAlert(_ body: Data) throws -> RDPLicenseErrorAlert {
        var cursor = ByteCursor(body)
        guard cursor.remaining >= 12 else {
            throw RDPDecodeError.invalidLicensePDU
        }
        let alert = try RDPLicenseErrorAlert(
            errorCode: cursor.readLittleEndianUInt32(),
            stateTransition: cursor.readLittleEndianUInt32()
        )
        let blobType = try cursor.readLittleEndianUInt16()
        let blobLength = try cursor.readLittleEndianUInt16()
        // wBlobType SHOULD be ignored when wBlobLen is 0 ([MS-RDPBCGR] 2.2.1.12.1.2).
        guard blobLength == 0 || blobType == RDPLicenseBinaryBlobType.error,
              Int(blobLength) == cursor.remaining
        else {
            throw RDPDecodeError.invalidLicensePDU
        }
        return alert
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
        try MCSSendDataRequestPDU.checked(
            initiator: userChannelID,
            channelID: channelID,
            userData: encodedUserData()
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
            payload: nullTerminatedString(username),
            to: &body
        )
        try appendLicenseBlob(
            type: RDPLicenseBinaryBlobType.clientMachineName,
            payload: nullTerminatedString(machineName),
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
        try MCSSendDataRequestPDU.checked(
            initiator: userChannelID,
            channelID: channelID,
            userData: encodedUserData()
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
        try MCSSendDataRequestPDU.checked(
            initiator: userChannelID,
            channelID: channelID,
            userData: encodedUserData()
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
        RDPRC4(key: licensingEncryptionKey).process(data)
    }

    func decrypt(_ data: Data) -> Data {
        encrypt(data)
    }

    /// Decrypts server licensing data and checks its MAC ([MS-RDPELE] 5.1.4,
    /// 5.1.5), as for the Platform Challenge and New/Upgrade License messages.
    func openVerified(_ encrypted: Data, mac expectedMAC: Data) throws -> Data {
        let data = decrypt(encrypted)
        guard mac(data) == expectedMAC else {
            throw RDPDecodeError.invalidLicensePDU
        }
        return data
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

struct RDPServerPlatformChallenge: Equatable, Sendable {
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
        let scopeByteCount = try cursor.readLittleEndianUInt32()
        let scope = try readNullTerminatedANSIString(from: &cursor, byteCount: scopeByteCount)
        let companyNameByteCount = try cursor.readLittleEndianUInt32()
        let companyName = try readNullTerminatedUnicodeString(from: &cursor, byteCount: companyNameByteCount)
        let productIDByteCount = try cursor.readLittleEndianUInt32()
        let productID = try readNullTerminatedUnicodeString(from: &cursor, byteCount: productIDByteCount)
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

struct RDPServerEncryptedLicense: Equatable, Sendable {
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

struct RDPServerLicenseRequest: Equatable, Sendable {
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

/// [MS-RDPELE] 2.2.2.2 asks for null-terminated ANSI user and machine names;
/// the server only records them, so non-ASCII names go out as UTF-8 (as
/// FreeRDP sends them) instead of failing the license request.
private func nullTerminatedString(_ value: String) -> Data {
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
        throw RDPConnectionError.clientFailure("failed to generate random bytes: \(status)")
    }
    return data
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
