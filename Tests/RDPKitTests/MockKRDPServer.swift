import Foundation
import CryptoKit
import NIOCore
import NIOPosix
@preconcurrency import NIOSSL
@testable import RDPKit

final class MockKRDPServer {
    let port: UInt16
    let transcript: MockKRDPServerTranscript
    let connectionLog: MockKRDPConnectionLog

    private let group: MultiThreadedEventLoopGroup
    private let channel: Channel

    var connectionCount: Int {
        connectionLog.connectionCount
    }

    private init(
        port: UInt16,
        group: MultiThreadedEventLoopGroup,
        channel: Channel,
        transcript: MockKRDPServerTranscript,
        connectionLog: MockKRDPConnectionLog
    ) {
        self.port = port
        self.group = group
        self.channel = channel
        self.transcript = transcript
        self.connectionLog = connectionLog
    }

    static func start(
        securityProtocol: MockKRDPSecurityProtocol = .tls,
        clipboardFiles: [RDPClipboardLocalFile] = [],
        graphicsBehavior: MockKRDPGraphicsBehavior = .sendFirstFrame,
        graphicsCapabilitySelection: MockKRDPGraphicsCapabilitySelection = .fixedVersion81,
        autoDetectBehavior: MockKRDPAutoDetectBehavior = .singleRTT,
        redirectionBehavior: MockKRDPRedirectionBehavior = .none,
        remoteClipboardText: String? = nil,
        audioEnabled: Bool = false,
        waitForCompatibilityTraffic: Bool = false
    ) throws -> MockKRDPServer {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let transcript = MockKRDPServerTranscript()
        let connectionLog = MockKRDPConnectionLog()
        do {
            let tlsContext = try NIOSSLContext(configuration: MockKRDPTLS.configuration())
            let channel = try ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { channel in
                    channel.pipeline.addHandler(MockKRDPServerHandler(
                        tlsContext: tlsContext,
                        securityProtocol: securityProtocol,
                        graphicsBehavior: graphicsBehavior,
                        graphicsCapabilitySelection: graphicsCapabilitySelection,
                        autoDetectBehavior: autoDetectBehavior,
                        redirectionBehavior: redirectionBehavior,
                        clipboardFiles: clipboardFiles,
                        remoteClipboardText: remoteClipboardText,
                        audioEnabled: audioEnabled,
                        waitForCompatibilityTraffic: waitForCompatibilityTraffic,
                        transcript: transcript,
                        connectionLog: connectionLog
                    ))
                }
                .bind(host: "127.0.0.1", port: 0)
                .wait()

            guard let port = channel.localAddress?.port,
                  let serverPort = UInt16(exactly: port)
            else {
                throw MockKRDPServerError.missingPort
            }

            return MockKRDPServer(
                port: serverPort,
                group: group,
                channel: channel,
                transcript: transcript,
                connectionLog: connectionLog
            )
        } catch {
            try? group.syncShutdownGracefully()
            throw error
        }
    }

    func stop() {
        try? channel.close().wait()
        try? group.syncShutdownGracefully()
    }
}

enum MockKRDPSecurityProtocol {
    case tls
    case credSSP(credentials: RDPCredentials)

    var selectedProtocols: RDPSecurityProtocols {
        switch self {
        case .tls:
            .tls
        case .credSSP:
            .credSSP
        }
    }
}

enum MockKRDPGraphicsBehavior {
    case sendFirstFrame
    case sendFragmentedBitmapCompositionFrame
    case sendClearCodecBandsFrame
    case sendCAVideoRemoteFXFrame
    case sendVideoBeforeBitmapCompositionFrame
    case sendInvalidGraphicsPDU
    case sendEmptyFrameThenStall
    case stallAfterCapsConfirm
}

enum MockKRDPGraphicsCapabilitySelection {
    case fixedVersion81
    case firstAdvertised
    case firstAdvertisedThinClientSmallCache

    func selectedCapability(from advertise: RDPGFXCapsAdvertisePDU?) -> RDPGFXCapabilitySet {
        switch self {
        case .fixedVersion81:
            return Self.fixedVersion81Capability
        case .firstAdvertised:
            return advertise?.capabilitySets.first ?? Self.fixedVersion81Capability
        case .firstAdvertisedThinClientSmallCache:
            return Self.thinClientSmallCacheCapability(
                version: advertise?.capabilitySets.first?.version
                    ?? RDPGFXCapabilityVersion.version81
            )
        }
    }

    private static var fixedVersion81Capability: RDPGFXCapabilitySet {
        .version81(flags: RDPGFXCapabilityFlags.defaultVersion81)
    }

    private static func thinClientSmallCacheCapability(version: UInt32) -> RDPGFXCapabilitySet {
        switch version {
        case RDPGFXCapabilityVersion.version8:
            .version8(flags: RDPGFXCapabilityFlags.defaultVersion8)
        case RDPGFXCapabilityVersion.version81:
            .version81(flags: RDPGFXCapabilityFlags.defaultVersion8)
        default:
            .version107(flags: RDPGFXCapabilityFlags.defaultVersion107)
        }
    }
}

enum MockKRDPAutoDetectBehavior {
    case singleRTT
    case bandwidthMeasure
}

enum MockKRDPRedirectionBehavior {
    case none
    /// Send a server redirection PDU (carrying a routing-token load-balance
    /// cookie, no target host) on the first connection only, so the client
    /// reconnects to the same server with the token attached.
    case redirectFirstConnection
}

/// Connection counter shared across the per-connection handler instances so the
/// mock can behave differently on a reconnect (e.g. after a redirection).
final class MockKRDPConnectionLog: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func registerConnection() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }

    var connectionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

enum MockKRDPServerError: Error {
    case missingPort
    case invalidClientPDU
}

struct MockDisplayControlLayoutSummary: Equatable, Sendable {
    var monitorCount: UInt32
    var primaryWidth: UInt32
    var primaryHeight: UInt32
    var primaryDesktopScaleFactor: UInt32
    var primaryDeviceScaleFactor: UInt32
}

struct MockKRDPServerTranscriptSnapshot: Equatable, Sendable {
    var inputEvents: [RDPSlowPathInputEvent]
    var clipboardStaticFlags: [UInt32]
    var clientClipboardMessages: [RDPClipboardMessageSummary]
    var receivedLocalClipboardText: String?
    var audioClientMessages: [RDPAudioMessageSummary]
    var deviceRedirectionClientMessages: [String]
    var displayControlLayouts: [MockDisplayControlLayoutSummary]
    var credSSPMessages: [String]
}

final class MockKRDPServerTranscript: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedInputEvents: [RDPSlowPathInputEvent] = []
    private var recordedClipboardStaticFlags: [UInt32] = []
    private var recordedClientClipboardMessages: [RDPClipboardMessageSummary] = []
    private var recordedReceivedLocalClipboardText: String?
    private var recordedAudioClientMessages: [RDPAudioMessageSummary] = []
    private var recordedDeviceRedirectionClientMessages: [String] = []
    private var recordedDisplayControlLayouts: [MockDisplayControlLayoutSummary] = []
    private var recordedCredSSPMessages: [String] = []

    var snapshot: MockKRDPServerTranscriptSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return MockKRDPServerTranscriptSnapshot(
            inputEvents: recordedInputEvents,
            clipboardStaticFlags: recordedClipboardStaticFlags,
            clientClipboardMessages: recordedClientClipboardMessages,
            receivedLocalClipboardText: recordedReceivedLocalClipboardText,
            audioClientMessages: recordedAudioClientMessages,
            deviceRedirectionClientMessages: recordedDeviceRedirectionClientMessages,
            displayControlLayouts: recordedDisplayControlLayouts,
            credSSPMessages: recordedCredSSPMessages
        )
    }

    func recordInputEvents(_ events: [RDPSlowPathInputEvent]) {
        lock.lock()
        recordedInputEvents.append(contentsOf: events)
        lock.unlock()
    }

    func recordClipboard(flags: UInt32, message: RDPClipboardMessageSummary) {
        lock.lock()
        recordedClipboardStaticFlags.append(flags)
        recordedClientClipboardMessages.append(message)
        lock.unlock()
    }

    func recordLocalClipboardText(_ text: String) {
        lock.lock()
        recordedReceivedLocalClipboardText = text
        lock.unlock()
    }

    func recordAudioMessage(_ message: RDPAudioMessageSummary) {
        lock.lock()
        recordedAudioClientMessages.append(message)
        lock.unlock()
    }

    func recordDeviceRedirectionMessage(_ message: String) {
        lock.lock()
        recordedDeviceRedirectionClientMessages.append(message)
        lock.unlock()
    }

    func recordDisplayControlLayout(_ layout: MockDisplayControlLayoutSummary) {
        lock.lock()
        recordedDisplayControlLayouts.append(layout)
        lock.unlock()
    }

    func recordCredSSPMessage(_ message: String) {
        lock.lock()
        recordedCredSSPMessages.append(message)
        lock.unlock()
    }
}

private enum MockKRDPConstants {
    static let userChannelID: UInt16 = 1002
    static let ioChannelID: UInt16 = 1003
    static let dynamicChannelID: UInt16 = 1004
    static let messageChannelID: UInt16 = 1005
    static let serverUserID: UInt16 = 1006
    static let clipboardChannelID: UInt16 = 1007
    static let deviceRedirectionChannelID: UInt16 = 1008
    static let audioChannelID: UInt16 = 1009
    static let shareID: UInt32 = 0x0001_03EE
    static let graphicsDynamicChannelID: UInt32 = 7
    static let displayControlDynamicChannelID: UInt32 = 17
    static let audioDynamicChannelID: UInt32 = 19
    static let remoteFileGroupDescriptorWFormatID: UInt32 = 0xC006
    static let remoteFileContentsFormatID: UInt32 = 0xC007
    static let frameID: UInt32 = 1
    static let width: UInt16 = 64
    static let height: UInt16 = 32
}

private struct MockMCSSendDataRequest {
    var initiator: UInt16
    var channelID: UInt16
    var userData: Data
}

private struct MockClientShareDataPDU {
    var pduType2: UInt8
    var payload: Data
}

private final class MockCredSSPServer {
    private enum Stage {
        case negotiate
        case authenticate
        case credentials
        case complete
    }

    private let credentials: RDPCredentials
    private let transcript: MockKRDPServerTranscript
    private let subjectPublicKey: Data
    private let serverChallenge = Data([0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF])
    private let timestamp: UInt64 = 0x01DA_0000_0000_0000
    private var stage = Stage.negotiate
    private var clientNonce = Data()
    private var negotiatedFlags: UInt32 = 0
    private var sendSigningKey = Data()
    private var receiveSigningKey = Data()
    private var sendSealingKey: MockNTLMRC4?
    private var receiveSealingKey: MockNTLMRC4?
    private var sendSequenceNumber: UInt32 = 0
    private var receiveSequenceNumber: UInt32 = 0

    init(credentials: RDPCredentials, transcript: MockKRDPServerTranscript) throws {
        self.credentials = credentials
        self.transcript = transcript
        subjectPublicKey = try MockKRDPTLS.subjectPublicKey()
    }

    var isComplete: Bool {
        if case .complete = stage {
            return true
        }
        return false
    }

    func handle(_ data: Data) throws -> Data? {
        let request = try RDPCredSSPTSRequest.parse(data)
        switch stage {
        case .negotiate:
            transcript.recordCredSSPMessage("ntlm-negotiate")
            guard let nonce = request.clientNonce,
                  nonce.count == 32,
                  request.negoTokens.last?.starts(with: Data("NTLMSSP\u{0}".utf8)) == true
            else {
                throw MockKRDPServerError.invalidClientPDU
            }
            clientNonce = nonce
            stage = .authenticate
            return RDPCredSSPTSRequest(
                version: 6,
                negoTokens: [challengeMessage()]
            ).encoded()

        case .authenticate:
            transcript.recordCredSSPMessage("ntlm-authenticate")
            if let nonce = request.clientNonce {
                clientNonce = nonce
            }
            guard let authenticate = request.negoTokens.last else {
                throw MockKRDPServerError.invalidClientPDU
            }
            try installKeys(from: authenticate)
            guard let clientPubKeyAuth = request.pubKeyAuth else {
                throw MockKRDPServerError.invalidClientPDU
            }
            let binding = try unwrap(clientPubKeyAuth)
            guard binding == RDPCredSSPPublicKeyBinding.clientServerHash(
                subjectPublicKey: subjectPublicKey,
                nonce: clientNonce
            ) else {
                throw MockKRDPServerError.invalidClientPDU
            }
            stage = .credentials
            return try RDPCredSSPTSRequest(
                version: 6,
                pubKeyAuth: wrap(RDPCredSSPPublicKeyBinding.serverClientHash(
                    subjectPublicKey: subjectPublicKey,
                    nonce: clientNonce
                ))
            ).encoded()

        case .credentials:
            transcript.recordCredSSPMessage("credentials")
            guard let authInfo = request.authInfo,
                  try unwrap(authInfo).isEmpty == false
            else {
                throw MockKRDPServerError.invalidClientPDU
            }
            stage = .complete
            return nil

        case .complete:
            throw MockKRDPServerError.invalidClientPDU
        }
    }

    private func challengeMessage() -> Data {
        let targetName = utf16LittleEndian("MOCK")
        let targetInfo = targetInfo()
        let payloadOffset = 56
        let targetInfoOffset = payloadOffset + targetName.count

        var message = Data()
        message.append(Self.ntlmSignature)
        message.appendLittleEndianUInt32(2)
        append(fieldLength: targetName.count, offset: payloadOffset, to: &message)
        message.appendLittleEndianUInt32(Self.challengeFlags)
        message.append(serverChallenge)
        message.append(Data(repeating: 0, count: 8))
        append(fieldLength: targetInfo.count, offset: targetInfoOffset, to: &message)
        message.append(Self.version)
        message.append(targetName)
        message.append(targetInfo)
        return message
    }

    private func targetInfo() -> Data {
        var data = Data()
        data.appendLittleEndianUInt16(2)
        data.appendLittleEndianUInt16(8)
        data.append(utf16LittleEndian("MOCK"))
        data.appendLittleEndianUInt16(7)
        data.appendLittleEndianUInt16(8)
        data.appendLittleEndianUInt64(timestamp)
        data.appendLittleEndianUInt16(0)
        data.appendLittleEndianUInt16(0)
        return data
    }

    private func installKeys(from authenticate: Data) throws {
        guard authenticate.count >= 88,
              authenticate.prefix(Self.ntlmSignature.count) == Self.ntlmSignature,
              try readLittleEndianUInt32(authenticate, at: 8) == 3
        else {
            throw MockKRDPServerError.invalidClientPDU
        }

        let ntResponse = try readSecurityBuffer(authenticate, at: 20)
        guard ntResponse.count >= 16 else {
            throw MockKRDPServerError.invalidClientPDU
        }
        let proof = Data(ntResponse.prefix(16))
        let responsePayload = Data(ntResponse.dropFirst(16))
        let ntlmV2Hash = Self.ntlmV2Hash(credentials: credentials)
        guard Self.hmacMD5(key: ntlmV2Hash, data: serverChallenge + responsePayload) == proof else {
            throw MockKRDPServerError.invalidClientPDU
        }
        let keyExchangeKey = Self.hmacMD5(key: ntlmV2Hash, data: proof)
        negotiatedFlags = try readLittleEndianUInt32(authenticate, at: 60)

        let exportedSessionKey: Data
        if negotiatedFlags & Self.negotiateKeyExchange != 0 {
            let encryptedRandomSessionKey = try readSecurityBuffer(authenticate, at: 52)
            exportedSessionKey = MockNTLMRC4(key: keyExchangeKey).process(encryptedRandomSessionKey)
        } else {
            exportedSessionKey = keyExchangeKey
        }

        sendSigningKey = Self.md5(exportedSessionKey + Self.serverSigningMagic)
        receiveSigningKey = Self.md5(exportedSessionKey + Self.clientSigningMagic)
        sendSealingKey = MockNTLMRC4(key: Self.md5(exportedSessionKey + Self.serverSealingMagic))
        receiveSealingKey = MockNTLMRC4(key: Self.md5(exportedSessionKey + Self.clientSealingMagic))
    }

    private func wrap(_ message: Data) throws -> Data {
        guard !sendSigningKey.isEmpty,
              let sendSealingKey
        else {
            throw MockKRDPServerError.invalidClientPDU
        }

        let sequenceNumber = sendSequenceNumber
        let digest = Self.hmacMD5(
            key: sendSigningKey,
            data: Self.sequenceInput(sequenceNumber: sequenceNumber, data: message)
        )
        let encryptedMessage = sendSealingKey.process(message)
        let checksum = negotiatedFlags & Self.negotiateKeyExchange != 0
            ? sendSealingKey.process(Data(digest.prefix(8)))
            : Data(digest.prefix(8))
        sendSequenceNumber &+= 1
        return Self.signature(checksum: checksum, sequenceNumber: sequenceNumber) + encryptedMessage
    }

    private func unwrap(_ message: Data) throws -> Data {
        guard !receiveSigningKey.isEmpty,
              let receiveSealingKey,
              message.count >= Self.signatureSize
        else {
            throw MockKRDPServerError.invalidClientPDU
        }

        let signature = Data(message.prefix(Self.signatureSize))
        let sequenceNumber = try readLittleEndianUInt32(signature, at: 12)
        guard sequenceNumber == receiveSequenceNumber else {
            throw MockKRDPServerError.invalidClientPDU
        }

        let encryptedMessage = Data(message.dropFirst(Self.signatureSize))
        let decryptedMessage = receiveSealingKey.process(encryptedMessage)
        let digest = Self.hmacMD5(
            key: receiveSigningKey,
            data: Self.sequenceInput(sequenceNumber: sequenceNumber, data: decryptedMessage)
        )
        let checksum = negotiatedFlags & Self.negotiateKeyExchange != 0
            ? receiveSealingKey.process(Data(digest.prefix(8)))
            : Data(digest.prefix(8))
        let expectedSignature = Self.signature(checksum: checksum, sequenceNumber: sequenceNumber)
        guard signature == expectedSignature else {
            throw MockKRDPServerError.invalidClientPDU
        }
        receiveSequenceNumber &+= 1
        return decryptedMessage
    }

    private func readSecurityBuffer(_ data: Data, at offset: Int) throws -> Data {
        let length = Int(try readLittleEndianUInt16(data, at: offset))
        let bufferOffset = Int(try readLittleEndianUInt32(data, at: offset + 4))
        return try readData(data, at: bufferOffset, count: length)
    }

    private func readData(_ data: Data, at offset: Int, count: Int) throws -> Data {
        guard offset >= 0,
              count >= 0,
              offset <= data.count,
              count <= data.count - offset
        else {
            throw MockKRDPServerError.invalidClientPDU
        }
        let start = data.index(data.startIndex, offsetBy: offset)
        return data.subdata(in: start ..< data.index(start, offsetBy: count))
    }

    private func readLittleEndianUInt16(_ data: Data, at offset: Int) throws -> UInt16 {
        guard offset >= 0, offset <= data.count - 2 else {
            throw MockKRDPServerError.invalidClientPDU
        }
        return UInt16(data[data.index(data.startIndex, offsetBy: offset)])
            | UInt16(data[data.index(data.startIndex, offsetBy: offset + 1)]) << 8
    }

    private func readLittleEndianUInt32(_ data: Data, at offset: Int) throws -> UInt32 {
        guard offset >= 0, offset <= data.count - 4 else {
            throw MockKRDPServerError.invalidClientPDU
        }
        return UInt32(data[data.index(data.startIndex, offsetBy: offset)])
            | UInt32(data[data.index(data.startIndex, offsetBy: offset + 1)]) << 8
            | UInt32(data[data.index(data.startIndex, offsetBy: offset + 2)]) << 16
            | UInt32(data[data.index(data.startIndex, offsetBy: offset + 3)]) << 24
    }

    private func append(fieldLength: Int, offset: Int, to data: inout Data) {
        data.appendLittleEndianUInt16(UInt16(fieldLength))
        data.appendLittleEndianUInt16(UInt16(fieldLength))
        data.appendLittleEndianUInt32(UInt32(offset))
    }

    private func utf16LittleEndian(_ value: String) -> Data {
        var data = Data()
        for codeUnit in value.utf16 {
            data.appendLittleEndianUInt16(codeUnit)
        }
        return data
    }

    private static func ntlmV2Hash(credentials: RDPCredentials) -> Data {
        let ntHash = md4(utf16LittleEndian(credentials.password))
        let identity = utf16LittleEndian(credentials.username.uppercased() + (credentials.domain ?? ""))
        return hmacMD5(key: ntHash, data: identity)
    }

    private static func sequenceInput(sequenceNumber: UInt32, data: Data) -> Data {
        var input = Data()
        input.appendLittleEndianUInt32(sequenceNumber)
        input.append(data)
        return input
    }

    private static func signature(checksum: Data, sequenceNumber: UInt32) -> Data {
        var signature = Data()
        signature.appendLittleEndianUInt32(1)
        signature.append(checksum.prefix(8))
        signature.appendLittleEndianUInt32(sequenceNumber)
        return signature
    }

    private static func utf16LittleEndian(_ value: String) -> Data {
        var data = Data()
        for codeUnit in value.utf16 {
            data.appendLittleEndianUInt16(codeUnit)
        }
        return data
    }

    private static func md4(_ data: Data) -> Data {
        var message = [UInt8](data)
        let bitLength = UInt64(message.count) * 8
        message.append(0x80)
        while message.count % 64 != 56 {
            message.append(0)
        }
        for shift in stride(from: 0, to: 64, by: 8) {
            message.append(UInt8((bitLength >> UInt64(shift)) & 0xFF))
        }

        var a: UInt32 = 0x6745_2301
        var b: UInt32 = 0xEFCD_AB89
        var c: UInt32 = 0x98BA_DCFE
        var d: UInt32 = 0x1032_5476

        for chunkStart in stride(from: 0, to: message.count, by: 64) {
            var words = [UInt32](repeating: 0, count: 16)
            for index in 0 ..< 16 {
                let offset = chunkStart + index * 4
                words[index] = UInt32(message[offset])
                    | UInt32(message[offset + 1]) << 8
                    | UInt32(message[offset + 2]) << 16
                    | UInt32(message[offset + 3]) << 24
            }

            let originalA = a
            let originalB = b
            let originalC = c
            let originalD = d

            for index in 0 ..< 16 {
                let shift = [3, 7, 11, 19][index % 4]
                switch index % 4 {
                case 0:
                    a = rotateLeft(a &+ f(b, c, d) &+ words[index], by: shift)
                case 1:
                    d = rotateLeft(d &+ f(a, b, c) &+ words[index], by: shift)
                case 2:
                    c = rotateLeft(c &+ f(d, a, b) &+ words[index], by: shift)
                default:
                    b = rotateLeft(b &+ f(c, d, a) &+ words[index], by: shift)
                }
            }

            let round2Order = [0, 4, 8, 12, 1, 5, 9, 13, 2, 6, 10, 14, 3, 7, 11, 15]
            for index in 0 ..< 16 {
                let shift = [3, 5, 9, 13][index % 4]
                let word = words[round2Order[index]]
                switch index % 4 {
                case 0:
                    a = rotateLeft(a &+ g(b, c, d) &+ word &+ 0x5A82_7999, by: shift)
                case 1:
                    d = rotateLeft(d &+ g(a, b, c) &+ word &+ 0x5A82_7999, by: shift)
                case 2:
                    c = rotateLeft(c &+ g(d, a, b) &+ word &+ 0x5A82_7999, by: shift)
                default:
                    b = rotateLeft(b &+ g(c, d, a) &+ word &+ 0x5A82_7999, by: shift)
                }
            }

            let round3Order = [0, 8, 4, 12, 2, 10, 6, 14, 1, 9, 5, 13, 3, 11, 7, 15]
            for index in 0 ..< 16 {
                let shift = [3, 9, 11, 15][index % 4]
                let word = words[round3Order[index]]
                switch index % 4 {
                case 0:
                    a = rotateLeft(a &+ h(b, c, d) &+ word &+ 0x6ED9_EBA1, by: shift)
                case 1:
                    d = rotateLeft(d &+ h(a, b, c) &+ word &+ 0x6ED9_EBA1, by: shift)
                case 2:
                    c = rotateLeft(c &+ h(d, a, b) &+ word &+ 0x6ED9_EBA1, by: shift)
                default:
                    b = rotateLeft(b &+ h(c, d, a) &+ word &+ 0x6ED9_EBA1, by: shift)
                }
            }

            a &+= originalA
            b &+= originalB
            c &+= originalC
            d &+= originalD
        }

        var digest = Data()
        digest.appendLittleEndianUInt32(a)
        digest.appendLittleEndianUInt32(b)
        digest.appendLittleEndianUInt32(c)
        digest.appendLittleEndianUInt32(d)
        return digest
    }

    private static func md5(_ data: Data) -> Data {
        Data(Insecure.MD5.hash(data: data))
    }

    private static func hmacMD5(key: Data, data: Data) -> Data {
        let key = SymmetricKey(data: key)
        return Data(HMAC<Insecure.MD5>.authenticationCode(for: data, using: key))
    }

    private static func f(_ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt32 {
        (x & y) | (~x & z)
    }

    private static func g(_ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt32 {
        (x & y) | (x & z) | (y & z)
    }

    private static func h(_ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt32 {
        x ^ y ^ z
    }

    private static func rotateLeft(_ value: UInt32, by shift: Int) -> UInt32 {
        (value << UInt32(shift)) | (value >> UInt32(32 - shift))
    }

    private static let ntlmSignature = Data("NTLMSSP\u{0}".utf8)
    private static let signatureSize = 16
    private static let version = Data([0x06, 0x01, 0xB1, 0x1D, 0x00, 0x00, 0x00, 0x0F])
    private static let clientSigningMagic = Data("session key to client-to-server signing key magic constant\u{0}".utf8)
    private static let serverSigningMagic = Data("session key to server-to-client signing key magic constant\u{0}".utf8)
    private static let clientSealingMagic = Data("session key to client-to-server sealing key magic constant\u{0}".utf8)
    private static let serverSealingMagic = Data("session key to server-to-client sealing key magic constant\u{0}".utf8)

    private static let negotiateUnicode: UInt32 = 0x0000_0001
    private static let negotiateRequestTarget: UInt32 = 0x0000_0004
    private static let negotiateSign: UInt32 = 0x0000_0010
    private static let negotiateSeal: UInt32 = 0x0000_0020
    private static let negotiateNTLM: UInt32 = 0x0000_0200
    private static let negotiateAlwaysSign: UInt32 = 0x0000_8000
    private static let negotiateExtendedSessionSecurity: UInt32 = 0x0008_0000
    private static let negotiateTargetInfo: UInt32 = 0x0080_0000
    private static let negotiateVersion: UInt32 = 0x0200_0000
    private static let negotiate128: UInt32 = 0x2000_0000
    private static let negotiateKeyExchange: UInt32 = 0x4000_0000
    private static let negotiate56: UInt32 = 0x8000_0000

    private static let challengeFlags = negotiate56
        | negotiate128
        | negotiateAlwaysSign
        | negotiateExtendedSessionSecurity
        | negotiateNTLM
        | negotiateRequestTarget
        | negotiateUnicode
        | negotiateTargetInfo
        | negotiateVersion
        | negotiateKeyExchange
        | negotiateSeal
        | negotiateSign
}

private final class MockNTLMRC4 {
    private var i = 0
    private var j = 0
    private var state = [UInt8](0 ... 255)

    init(key: Data) {
        precondition(key.isEmpty == false)
        var j = 0
        let keyBytes = [UInt8](key)
        for i in 0 ..< 256 {
            j = (j + Int(state[i]) + Int(keyBytes[i % keyBytes.count])) & 0xFF
            state.swapAt(i, j)
        }
    }

    func process(_ input: Data) -> Data {
        var output = Data()
        output.reserveCapacity(input.count)
        for byte in input {
            i = (i + 1) & 0xFF
            j = (j + Int(state[i])) & 0xFF
            state.swapAt(i, j)
            let keyIndex = (Int(state[i]) + Int(state[j])) & 0xFF
            output.append(byte ^ state[keyIndex])
        }
        return output
    }
}

private final class MockKRDPServerHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private enum Stage {
        case x224
        case credSSP
        case mcsConnectInitial
        case erectDomain
        case attachUser
        case channelJoin(Int)
        case clientInfo
        case autoDetectResponse
        case bandwidthMeasureResponse
        case confirmActive
        case finalization(Int)
        case finalizationFontList
        case dynamicCapabilitiesResponse
        case graphicsCreateResponse
        case graphicsCapsAdvertise
        case graphicsFrameAcknowledge
        case done
    }

    private let tlsContext: NIOSSLContext
    private let securityProtocol: MockKRDPSecurityProtocol
    private let graphicsBehavior: MockKRDPGraphicsBehavior
    private let graphicsCapabilitySelection: MockKRDPGraphicsCapabilitySelection
    private let autoDetectBehavior: MockKRDPAutoDetectBehavior
    private let redirectionBehavior: MockKRDPRedirectionBehavior
    private let clipboardFiles: [RDPClipboardLocalFile]
    private let remoteClipboardText: String?
    private let audioEnabled: Bool
    private let waitForCompatibilityTraffic: Bool
    private let transcript: MockKRDPServerTranscript
    private let connectionLog: MockKRDPConnectionLog
    private var connectionIndex = 0
    private var stage = Stage.x224
    private var received = Data()
    private var didReleaseGraphicsHandshake = false
    private var didReleaseGraphicsFrame = false
    private var credSSPServer: MockCredSSPServer?

    init(
        tlsContext: NIOSSLContext,
        securityProtocol: MockKRDPSecurityProtocol,
        graphicsBehavior: MockKRDPGraphicsBehavior,
        graphicsCapabilitySelection: MockKRDPGraphicsCapabilitySelection,
        autoDetectBehavior: MockKRDPAutoDetectBehavior,
        redirectionBehavior: MockKRDPRedirectionBehavior,
        clipboardFiles: [RDPClipboardLocalFile],
        remoteClipboardText: String?,
        audioEnabled: Bool,
        waitForCompatibilityTraffic: Bool,
        transcript: MockKRDPServerTranscript,
        connectionLog: MockKRDPConnectionLog
    ) {
        self.tlsContext = tlsContext
        self.securityProtocol = securityProtocol
        self.graphicsBehavior = graphicsBehavior
        self.graphicsCapabilitySelection = graphicsCapabilitySelection
        self.autoDetectBehavior = autoDetectBehavior
        self.redirectionBehavior = redirectionBehavior
        self.clipboardFiles = clipboardFiles
        self.remoteClipboardText = remoteClipboardText
        self.audioEnabled = audioEnabled
        self.waitForCompatibilityTraffic = waitForCompatibilityTraffic
        self.transcript = transcript
        self.connectionLog = connectionLog
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        if let bytes = buffer.readBytes(length: buffer.readableBytes) {
            received.append(contentsOf: bytes)
        }

        do {
            try processAvailablePackets(context: context)
        } catch {
            context.fireErrorCaught(error)
            context.close(promise: nil)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error _: Error) {
        context.close(promise: nil)
    }

    private func processAvailablePackets(context: ChannelHandlerContext) throws {
        while true {
            switch stage {
            case .credSSP:
                guard let message = try nextASN1Message() else {
                    return
                }
                try handleCredSSP(message, context: context)
            default:
                guard let packet = nextTPKT() else {
                    return
                }
                try handle(packet, context: context)
            }
        }
    }

    private func nextTPKT() -> Data? {
        guard received.count >= 4 else {
            return nil
        }
        let length = Int(received[received.index(received.startIndex, offsetBy: 2)]) << 8
            | Int(received[received.index(received.startIndex, offsetBy: 3)])
        guard length >= 4, received.count >= length else {
            return nil
        }
        let packet = Data(received.prefix(length))
        received.removeFirst(length)
        return packet
    }

    private func nextASN1Message() throws -> Data? {
        guard received.count >= 2 else {
            return nil
        }
        guard received[received.startIndex] == 0x30 else {
            throw MockKRDPServerError.invalidClientPDU
        }

        let firstLengthByte = received[received.index(after: received.startIndex)]
        let headerLength: Int
        let payloadLength: Int
        if firstLengthByte & 0x80 == 0 {
            headerLength = 2
            payloadLength = Int(firstLengthByte)
        } else {
            let lengthByteCount = Int(firstLengthByte & 0x7F)
            guard lengthByteCount > 0, lengthByteCount <= 4 else {
                throw MockKRDPServerError.invalidClientPDU
            }
            headerLength = 2 + lengthByteCount
            guard received.count >= headerLength else {
                return nil
            }
            var length = 0
            for offset in 0 ..< lengthByteCount {
                let byte = received[received.index(received.startIndex, offsetBy: 2 + offset)]
                length = (length << 8) | Int(byte)
            }
            payloadLength = length
        }

        let totalLength = headerLength + payloadLength
        guard received.count >= totalLength else {
            return nil
        }
        let message = Data(received.prefix(totalLength))
        received.removeFirst(totalLength)
        return message
    }

    private func handle(_ packet: Data, context: ChannelHandlerContext) throws {
        if try handleInputPacketIfPresent(packet, context: context) {
            return
        }
        if try handleClipboardPacketIfPresent(packet, context: context) {
            return
        }
        if try handleDeviceRedirectionPacketIfPresent(packet, context: context) {
            return
        }
        if try handleAudioPacketIfPresent(packet, context: context) {
            return
        }
        if try handleDisplayControlPacketIfPresent(packet, context: context) {
            return
        }
        if try handleDynamicCreateResponseIfPresent(packet, context: context) {
            return
        }

        switch stage {
        case .x224:
            _ = try TPKT.unwrap(packet)
            connectionIndex = connectionLog.registerConnection()
            writePacket(
                MockKRDPFixtures.x224ConnectionConfirm(selectedProtocols: securityProtocol.selectedProtocols),
                context: context
            )
            let tlsHandler = NIOSSLServerHandler(context: tlsContext)
            try context.channel.pipeline.syncOperations.addHandler(tlsHandler, position: .first)
            switch securityProtocol {
            case .tls:
                stage = .mcsConnectInitial
            case let .credSSP(credentials):
                credSSPServer = try MockCredSSPServer(credentials: credentials, transcript: transcript)
                stage = .credSSP
            }

        case .credSSP:
            throw MockKRDPServerError.invalidClientPDU

        case .mcsConnectInitial:
            _ = try X224DataTPDU.unwrap(packet)
            writePacket(
                MockKRDPFixtures.mcsConnectResponse(
                    clipboardEnabled: clipboardEnabled,
                    audioEnabled: audioEnabled
                ),
                context: context
            )
            stage = .erectDomain

        case .erectDomain:
            _ = try X224DataTPDU.unwrap(packet)
            stage = .attachUser

        case .attachUser:
            _ = try X224DataTPDU.unwrap(packet)
            writePacket(MockKRDPFixtures.attachUserConfirm(), context: context)
            stage = .channelJoin(0)

        case let .channelJoin(index):
            _ = try X224DataTPDU.unwrap(packet)
            let joinChannelIDs = MockKRDPFixtures.joinChannelIDs(
                clipboardEnabled: clipboardEnabled,
                audioEnabled: audioEnabled
            )
            let channelID = joinChannelIDs[index]
            writePacket(MockKRDPFixtures.channelJoinConfirm(channelID: channelID), context: context)
            let nextIndex = index + 1
            stage = nextIndex == joinChannelIDs.count
                ? .clientInfo
                : .channelJoin(nextIndex)

        case .clientInfo:
            try MockKRDPFixtures.expectSendDataRequest(packet, channelID: MockKRDPConstants.ioChannelID)
            writePacket(MockKRDPFixtures.autoDetectRequest(), context: context)
            stage = .autoDetectResponse

        case .autoDetectResponse:
            try MockKRDPFixtures.expectSendDataRequest(packet, channelID: MockKRDPConstants.messageChannelID)
            if autoDetectBehavior == .bandwidthMeasure {
                writePacket(MockKRDPFixtures.autoDetectBandwidthMeasureStop(), context: context)
                stage = .bandwidthMeasureResponse
                break
            }
            writePacket(MockKRDPFixtures.licenseValidClient(), context: context)
            writePacket(MockKRDPFixtures.demandActive(), context: context)
            stage = .confirmActive

        case .bandwidthMeasureResponse:
            let request = try MockKRDPFixtures.expectSendDataRequest(packet, channelID: MockKRDPConstants.messageChannelID)
            try MockKRDPFixtures.expectAutoDetectBandwidthResult(request.userData)
            writePacket(MockKRDPFixtures.licenseValidClient(), context: context)
            writePacket(MockKRDPFixtures.demandActive(), context: context)
            stage = .confirmActive

        case .confirmActive:
            try MockKRDPFixtures.expectSendDataRequest(packet, channelID: MockKRDPConstants.ioChannelID)
            writePacket(MockKRDPFixtures.serverSynchronize(), context: context)
            stage = .finalization(0)

        case let .finalization(count):
            try MockKRDPFixtures.expectSendDataRequest(packet, channelID: MockKRDPConstants.ioChannelID)
            let nextCount = count + 1
            if nextCount == 3 {
                writePacket(MockKRDPFixtures.controlGranted(), context: context)
                writePacket(MockKRDPFixtures.fontMap(), context: context)
                if clipboardEnabled {
                    writePacket(MockKRDPFixtures.clipboardMonitorReady(), context: context)
                    writePacket(MockKRDPFixtures.clipboardCapabilities(), context: context)
                    writePacket(
                        MockKRDPFixtures.clipboardFormatList(
                            includeFiles: clipboardFiles.isEmpty == false,
                            includeText: remoteClipboardText != nil
                        ),
                        context: context
                    )
                }
                if audioEnabled {
                    writePacket(MockKRDPFixtures.deviceRedirectionServerAnnounce(), context: context)
                    writePacket(MockKRDPFixtures.deviceRedirectionServerCapability(), context: context)
                    writePacket(MockKRDPFixtures.deviceRedirectionUserLoggedOn(), context: context)
                }
                if clipboardFiles.isEmpty || remoteClipboardText != nil || waitForCompatibilityTraffic {
                    releaseGraphicsHandshake(context: context)
                }
                stage = .finalizationFontList
            } else {
                stage = .finalization(nextCount)
            }

        case .finalizationFontList:
            try MockKRDPFixtures.expectSendDataRequest(packet, channelID: MockKRDPConstants.ioChannelID)
            stage = .dynamicCapabilitiesResponse

        case .dynamicCapabilitiesResponse:
            _ = try MockKRDPFixtures.staticVirtualChannelPayload(from: packet)
            writePacket(MockKRDPFixtures.graphicsCreateRequest(), context: context)
            stage = .graphicsCreateResponse

        case .graphicsCreateResponse:
            _ = try MockKRDPFixtures.staticVirtualChannelPayload(from: packet)
            stage = .graphicsCapsAdvertise

        case .graphicsCapsAdvertise:
            let staticPayload = try MockKRDPFixtures.staticVirtualChannelPayload(from: packet)
            if redirectionBehavior == .redirectFirstConnection, connectionIndex == 1 {
                writePacket(MockKRDPFixtures.serverRedirection(), context: context)
                stage = .done
                break
            }
            let dataPDU = try RDPDynamicVirtualChannelDataPDU.parseIfPresent(from: staticPayload)
            let advertise = try dataPDU.flatMap {
                try RDPGFXCapsAdvertisePDU.parseIfPresent(from: $0.payload)
            }
            let selectedCapability = graphicsCapabilitySelection.selectedCapability(from: advertise)
            writePacket(MockKRDPFixtures.graphicsCapsConfirm(capability: selectedCapability), context: context)
            if waitForCompatibilityTraffic {
                writePacket(MockKRDPFixtures.displayControlCreateRequest(), context: context)
                writePacket(MockKRDPFixtures.displayControlCaps(), context: context)
                if audioEnabled {
                    writePacket(MockKRDPFixtures.audioCreateRequest(), context: context)
                    writePacket(MockKRDPFixtures.audioFormats(), context: context)
                    writePacket(MockKRDPFixtures.audioTraining(), context: context)
                    writePacket(MockKRDPFixtures.audioWave2(), context: context)
                }
                maybeReleaseCompatibilityGraphicsFrame(context: context)
                break
            }
            switch graphicsBehavior {
            case .sendFirstFrame,
                 .sendFragmentedBitmapCompositionFrame,
                 .sendClearCodecBandsFrame,
                 .sendCAVideoRemoteFXFrame,
                 .sendVideoBeforeBitmapCompositionFrame,
                 .sendInvalidGraphicsPDU:
                releaseGraphicsFrame(context: context)
                stage = .graphicsFrameAcknowledge
            case .sendEmptyFrameThenStall:
                writePacket(MockKRDPFixtures.graphicsEmptyFrameUpdate(), context: context)
                stage = .graphicsFrameAcknowledge
            case .stallAfterCapsConfirm:
                stage = .done
            }

        case .graphicsFrameAcknowledge:
            _ = try MockKRDPFixtures.staticVirtualChannelPayload(from: packet)
            stage = .done

        case .done:
            break
        }
    }

    private func handleCredSSP(_ message: Data, context: ChannelHandlerContext) throws {
        guard let credSSPServer else {
            throw MockKRDPServerError.invalidClientPDU
        }

        let response = try credSSPServer.handle(message)
        if let response {
            writeRaw(response, context: context)
        }
        if credSSPServer.isComplete {
            stage = .mcsConnectInitial
        }
    }

    private var clipboardEnabled: Bool {
        clipboardFiles.isEmpty == false || remoteClipboardText != nil
    }

    private func handleInputPacketIfPresent(_ packet: Data, context: ChannelHandlerContext) throws -> Bool {
        guard let request = try? MockKRDPFixtures.clientSendDataRequest(from: packet),
              request.initiator == MockKRDPConstants.userChannelID,
              request.channelID == MockKRDPConstants.ioChannelID,
              let shareData = try MockKRDPFixtures.clientShareDataPDU(from: request.userData),
              shareData.pduType2 == 0x1C
        else {
            return false
        }

        transcript.recordInputEvents(try MockKRDPFixtures.inputEvents(from: shareData.payload))
        maybeReleaseCompatibilityGraphicsFrame(context: context)
        return true
    }

    private func handleClipboardPacketIfPresent(_ packet: Data, context: ChannelHandlerContext) throws -> Bool {
        guard clipboardEnabled,
              let request = try? MockKRDPFixtures.clientSendDataRequest(from: packet),
              request.initiator == MockKRDPConstants.userChannelID,
              request.channelID == MockKRDPConstants.clipboardChannelID
        else {
            return false
        }

        let staticPDU = try RDPStaticVirtualChannelPDU.parse(fromUserData: request.userData)
        guard staticPDU.isComplete else {
            throw MockKRDPServerError.invalidClientPDU
        }

        let clipboardPDU = try RDPClipboardPDU.parse(from: staticPDU.payload)
        transcript.recordClipboard(flags: staticPDU.flags, message: .summarize(clipboardPDU))
        if let response = try RDPClipboardFormatDataResponsePDU.parseIfPresent(from: clipboardPDU),
           response.ok,
           let text = try? response.decodedUnicodeText()
        {
            transcript.recordLocalClipboardText(text)
            maybeReleaseCompatibilityGraphicsFrame(context: context)
            return true
        }
        if let request = try RDPClipboardFormatDataRequestPDU.parseIfPresent(from: clipboardPDU) {
            let response = clipboardFormatDataResponse(for: request)
            writePacket(MockKRDPFixtures.clipboardPacket(response.encoded()), context: context)
            return true
        }

        if let formatList = try RDPClipboardFormatListPDU.parseIfPresent(from: clipboardPDU),
           formatList.formatIDs.contains(RDPClipboardFormatID.unicodeText)
        {
            writePacket(MockKRDPFixtures.clipboardFormatListResponse(), context: context)
            writePacket(MockKRDPFixtures.clipboardUnicodeTextRequest(), context: context)
            return true
        }

        if let request = try RDPClipboardFileContentsRequestPDU.parseIfPresent(from: clipboardPDU) {
            let response = clipboardFileContentsResponse(for: request)
            writePacket(MockKRDPFixtures.clipboardPacket(response.encoded()), context: context)
            if request.flags & RDPClipboardFileContentsFlags.range != 0 {
                releaseGraphicsHandshake(context: context)
            }
            return true
        }

        return true
    }

    private func handleDeviceRedirectionPacketIfPresent(
        _ packet: Data,
        context: ChannelHandlerContext
    ) throws -> Bool {
        guard audioEnabled,
              let request = try? MockKRDPFixtures.clientSendDataRequest(from: packet),
              request.initiator == MockKRDPConstants.userChannelID,
              request.channelID == MockKRDPConstants.deviceRedirectionChannelID
        else {
            return false
        }

        let staticPDU = try RDPStaticVirtualChannelPDU.parse(fromUserData: request.userData)
        guard staticPDU.isComplete else {
            throw MockKRDPServerError.invalidClientPDU
        }
        let pdu = try RDPDeviceRedirectionPDU.parse(from: staticPDU.payload)
        transcript.recordDeviceRedirectionMessage(pdu.typeName)
        maybeReleaseCompatibilityGraphicsFrame(context: context)
        return true
    }

    private func handleAudioPacketIfPresent(_ packet: Data, context: ChannelHandlerContext) throws -> Bool {
        guard audioEnabled,
              let request = try? MockKRDPFixtures.clientSendDataRequest(from: packet),
              request.initiator == MockKRDPConstants.userChannelID,
              request.channelID == MockKRDPConstants.dynamicChannelID
        else {
            return false
        }

        let staticPDU = try RDPStaticVirtualChannelPDU.parse(fromUserData: request.userData)
        guard staticPDU.isComplete,
              let dataPDU = try RDPDynamicVirtualChannelDataPDU.parseIfPresent(from: staticPDU.payload),
              dataPDU.channelID == MockKRDPConstants.audioDynamicChannelID
        else {
            return false
        }

        let audioPDU = try RDPAudioPDU.parse(from: dataPDU.payload)
        transcript.recordAudioMessage(.summarize(audioPDU))
        maybeReleaseCompatibilityGraphicsFrame(context: context)
        return true
    }

    private func handleDisplayControlPacketIfPresent(
        _ packet: Data,
        context: ChannelHandlerContext
    ) throws -> Bool {
        guard waitForCompatibilityTraffic,
              let request = try? MockKRDPFixtures.clientSendDataRequest(from: packet),
              request.initiator == MockKRDPConstants.userChannelID,
              request.channelID == MockKRDPConstants.dynamicChannelID
        else {
            return false
        }

        let staticPDU = try RDPStaticVirtualChannelPDU.parse(fromUserData: request.userData)
        guard staticPDU.isComplete,
              let dataPDU = try RDPDynamicVirtualChannelDataPDU.parseIfPresent(from: staticPDU.payload),
              dataPDU.channelID == MockKRDPConstants.displayControlDynamicChannelID,
              let layout = try MockKRDPFixtures.displayControlLayoutSummary(from: dataPDU.payload)
        else {
            return false
        }

        transcript.recordDisplayControlLayout(layout)
        maybeReleaseCompatibilityGraphicsFrame(context: context)
        return true
    }

    private func handleDynamicCreateResponseIfPresent(
        _ packet: Data,
        context _: ChannelHandlerContext
    ) throws -> Bool {
        guard waitForCompatibilityTraffic,
              let request = try? MockKRDPFixtures.clientSendDataRequest(from: packet),
              request.initiator == MockKRDPConstants.userChannelID,
              request.channelID == MockKRDPConstants.dynamicChannelID
        else {
            return false
        }

        let staticPDU = try RDPStaticVirtualChannelPDU.parse(fromUserData: request.userData)
        guard staticPDU.isComplete,
              MockKRDPFixtures.isDynamicCreateResponse(
                  staticPDU.payload,
                  channelIDs: [
                      MockKRDPConstants.displayControlDynamicChannelID,
                      MockKRDPConstants.audioDynamicChannelID,
                  ]
              )
        else {
            return false
        }

        return true
    }

    private func clipboardFormatDataResponse(
        for request: RDPClipboardFormatDataRequestPDU
    ) -> RDPClipboardFormatDataResponsePDU {
        if request.formatID == RDPClipboardFormatID.unicodeText,
           let remoteClipboardText
        {
            return .unicodeText(remoteClipboardText)
        }
        guard request.formatID == MockKRDPConstants.remoteFileGroupDescriptorWFormatID else {
            return .failure()
        }

        return .fileGroupDescriptorW(
            RDPClipboardFileGroupDescriptorW(descriptors: clipboardFiles.map(\.descriptor))
        )
    }

    private func clipboardFileContentsResponse(
        for request: RDPClipboardFileContentsRequestPDU
    ) -> RDPClipboardFileContentsResponsePDU {
        guard request.fileIndex >= 0,
              Int(request.fileIndex) < clipboardFiles.count
        else {
            return .failure(streamID: request.streamID)
        }

        let file = clipboardFiles[Int(request.fileIndex)]
        if request.flags & RDPClipboardFileContentsFlags.size != 0 {
            return .fileSize(streamID: request.streamID, byteCount: file.descriptor.fileSize)
        }

        guard request.flags & RDPClipboardFileContentsFlags.range != 0,
              request.position <= UInt64(file.contents.count),
              UInt64(request.requestedByteCount) <= UInt64(file.contents.count) - request.position,
              let lowerBound = Int(exactly: request.position),
              let requestedByteCount = Int(exactly: request.requestedByteCount)
        else {
            return .failure(streamID: request.streamID)
        }

        return .range(
            streamID: request.streamID,
            data: file.contents.subdata(in: lowerBound ..< (lowerBound + requestedByteCount))
        )
    }

    private func releaseGraphicsHandshake(context: ChannelHandlerContext) {
        guard didReleaseGraphicsHandshake == false else {
            return
        }

        didReleaseGraphicsHandshake = true
        writePacket(MockKRDPFixtures.dynamicCapabilitiesRequest(), context: context)
    }

    private func maybeReleaseCompatibilityGraphicsFrame(context: ChannelHandlerContext) {
        guard waitForCompatibilityTraffic else {
            return
        }

        let snapshot = transcript.snapshot
        guard snapshot.inputEvents.isEmpty == false,
              snapshot.clientClipboardMessages.map(\.typeName).contains("clipboard-format-data-response"),
              snapshot.receivedLocalClipboardText != nil,
              snapshot.deviceRedirectionClientMessages.contains("rdpdr-client-id-confirm"),
              snapshot.deviceRedirectionClientMessages.contains("rdpdr-client-name"),
              snapshot.deviceRedirectionClientMessages.contains("rdpdr-client-capability"),
              snapshot.deviceRedirectionClientMessages.contains("rdpdr-device-list-announce"),
              snapshot.displayControlLayouts.isEmpty == false,
              snapshot.audioClientMessages.map(\.typeName).contains("audio-formats"),
              snapshot.audioClientMessages.map(\.typeName).contains("audio-quality-mode"),
              snapshot.audioClientMessages.map(\.typeName).contains("audio-training"),
              snapshot.audioClientMessages.map(\.typeName).contains("audio-wave-confirm")
        else {
            return
        }

        releaseGraphicsFrame(context: context)
    }

    private func releaseGraphicsFrame(context: ChannelHandlerContext) {
        guard didReleaseGraphicsFrame == false else {
            return
        }

        didReleaseGraphicsFrame = true
        for packet in MockKRDPFixtures.graphicsFrameUpdatePackets(behavior: graphicsBehavior) {
            writePacket(packet, context: context)
        }
        stage = .graphicsFrameAcknowledge
    }

    @discardableResult
    private func writePacket(_ packet: Data, context: ChannelHandlerContext) -> EventLoopFuture<Void> {
        var buffer = context.channel.allocator.buffer(capacity: packet.count)
        buffer.writeBytes(packet)
        return context.writeAndFlush(wrapOutboundOut(buffer))
    }

    @discardableResult
    private func writeRaw(_ packet: Data, context: ChannelHandlerContext) -> EventLoopFuture<Void> {
        var buffer = context.channel.allocator.buffer(capacity: packet.count)
        buffer.writeBytes(packet)
        return context.writeAndFlush(wrapOutboundOut(buffer))
    }
}

extension MockKRDPServerHandler: @unchecked Sendable {}

private enum MockKRDPFixtures {
    static func joinChannelIDs(clipboardEnabled: Bool, audioEnabled: Bool = false) -> [UInt16] {
        var channelIDs = [
            MockKRDPConstants.userChannelID,
            MockKRDPConstants.ioChannelID,
            MockKRDPConstants.dynamicChannelID,
        ]
        if clipboardEnabled {
            channelIDs.append(MockKRDPConstants.clipboardChannelID)
        }
        if audioEnabled {
            channelIDs.append(MockKRDPConstants.deviceRedirectionChannelID)
            channelIDs.append(MockKRDPConstants.audioChannelID)
        }
        channelIDs.append(MockKRDPConstants.messageChannelID)
        return channelIDs
    }

    static func x224ConnectionConfirm(selectedProtocols: RDPSecurityProtocols = .tls) -> Data {
        var negotiationResponse = Data([
            0x02, 0x0B, 0x08, 0x00,
        ])
        negotiationResponse.appendLittleEndianUInt32(selectedProtocols.rawValue)
        return Data([
            0x03, 0x00, 0x00, 0x13,
            0x0E, 0xD0, 0x00, 0x00,
            0x00, 0x00, 0x00,
        ]) + negotiationResponse
    }

    static func mcsConnectResponse(clipboardEnabled: Bool = false, audioEnabled: Bool = false) -> Data {
        let domainParameters = Data([
            0x30, 0x1A,
            0x02, 0x01, 0x22,
            0x02, 0x01, 0x03,
            0x02, 0x01, 0x00,
            0x02, 0x01, 0x01,
            0x02, 0x01, 0x00,
            0x02, 0x01, 0x01,
            0x02, 0x03, 0x00, 0xFF, 0xF8,
            0x02, 0x01, 0x02,
        ])
        var channelIDs = [MockKRDPConstants.dynamicChannelID]
        if clipboardEnabled {
            channelIDs.append(MockKRDPConstants.clipboardChannelID)
        }
        if audioEnabled {
            channelIDs.append(MockKRDPConstants.deviceRedirectionChannelID)
            channelIDs.append(MockKRDPConstants.audioChannelID)
        }

        var serverNetworkData = Data()
        let serverNetworkDataLength = 8
            + channelIDs.count * 2
            + (channelIDs.count.isMultiple(of: 2) ? 0 : 2)
        serverNetworkData.append(contentsOf: [0x03, 0x0C])
        serverNetworkData.appendLittleEndianUInt16(UInt16(serverNetworkDataLength))
        serverNetworkData.appendLittleEndianUInt16(MockKRDPConstants.ioChannelID)
        serverNetworkData.appendLittleEndianUInt16(UInt16(channelIDs.count))
        for channelID in channelIDs {
            serverNetworkData.appendLittleEndianUInt16(channelID)
        }
        if channelIDs.count.isMultiple(of: 2) == false {
            serverNetworkData.appendLittleEndianUInt16(0)
        }
        let serverMessageChannelData = Data([
            0x04, 0x0C, 0x06, 0x00,
            0xED, 0x03,
        ])
        let serverBlocks = serverNetworkData + serverMessageChannelData
        let gccConnectData = Data([
            0x00, 0x05,
            0x00, 0x14, 0x7C, 0x00, 0x01,
            0x2A,
            0x14, 0x76, 0x0A, 0x01, 0x01, 0x00, 0x01, 0xC0, 0x00,
            0x4D, 0x63, 0x44, 0x6E,
            UInt8(serverBlocks.count),
        ]) + serverBlocks

        var mcsFields = Data()
        mcsFields.append(contentsOf: [0x0A, 0x01, 0x00])
        mcsFields.append(contentsOf: [0x02, 0x01, 0x00])
        mcsFields.append(domainParameters)
        mcsFields.append(berOctetString(gccConnectData))

        var mcs = Data()
        mcs.append(contentsOf: [0x7F, 0x66])
        mcs.append(berLength(mcsFields.count))
        mcs.append(mcsFields)

        return TPKT.wrap(Data([0x02, 0xF0, 0x80]) + mcs)
    }

    static func attachUserConfirm() -> Data {
        var data = Data([0x2E, 0x00])
        data.appendBigEndianUInt16(MockKRDPConstants.userChannelID - 1001)
        return X224DataTPDU.wrap(data)
    }

    static func channelJoinConfirm(channelID: UInt16) -> Data {
        var data = Data([0x3E, 0x00])
        data.appendBigEndianUInt16(MockKRDPConstants.userChannelID - 1001)
        data.appendBigEndianUInt16(channelID)
        data.appendBigEndianUInt16(channelID)
        return X224DataTPDU.wrap(data)
    }

    static func autoDetectRequest() -> Data {
        var payload = Data()
        payload.appendLittleEndianUInt16(0x1000)
        payload.appendLittleEndianUInt16(0)
        payload.appendUInt8(0x06)
        payload.appendUInt8(0x00)
        payload.appendLittleEndianUInt16(1)
        payload.appendLittleEndianUInt16(0x1001)
        return mcsSendDataIndication(
            channelID: MockKRDPConstants.messageChannelID,
            userData: payload
        )
    }

    static func autoDetectBandwidthMeasureStop() -> Data {
        var payload = Data()
        payload.appendLittleEndianUInt16(0x1000)
        payload.appendLittleEndianUInt16(0)
        payload.appendUInt8(0x08)
        payload.appendUInt8(0x00)
        payload.appendLittleEndianUInt16(1)
        payload.appendLittleEndianUInt16(0x002B)
        payload.appendLittleEndianUInt16(16)
        payload.append(Data(repeating: 0xA5, count: 16))
        return mcsSendDataIndication(
            channelID: MockKRDPConstants.messageChannelID,
            userData: payload
        )
    }

    static func expectAutoDetectBandwidthResult(_ userData: Data) throws {
        var cursor = ByteCursor(userData)
        guard try cursor.readLittleEndianUInt16() == 0x2000,
              try cursor.readLittleEndianUInt16() == 0,
              try cursor.readUInt8() == 0x0E,
              try cursor.readUInt8() == 0x01,
              try cursor.readLittleEndianUInt16() == 1,
              try cursor.readLittleEndianUInt16() == 0x0003,
              try cursor.readLittleEndianUInt32() == 16,
              try cursor.readLittleEndianUInt32() > 0,
              cursor.remaining == 0
        else {
            throw MockKRDPServerError.invalidClientPDU
        }
    }

    static func serverRedirection() -> Data {
        let cookie = Data("Cookie: msts=load-balanced\r\n".utf8)
        var fields = Data()
        fields.appendLittleEndianUInt32(UInt32(cookie.count))
        fields.append(cookie)

        let redirectionLength = UInt16(4 + 2 + 2 + 2 + 4 + fields.count)
        let totalLength = UInt16(6 + Int(redirectionLength))
        var payload = Data()
        payload.appendLittleEndianUInt16(totalLength)
        payload.appendLittleEndianUInt16(0x001A)
        payload.appendLittleEndianUInt16(0)
        payload.appendLittleEndianUInt32(0x0400_0000)
        payload.appendLittleEndianUInt16(redirectionLength)
        payload.appendLittleEndianUInt16(0)
        payload.appendLittleEndianUInt16(4)
        payload.appendLittleEndianUInt32(RDPServerRedirectionPDU.Flags.loadBalanceInfo.rawValue)
        payload.append(fields)
        return mcsSendDataIndication(
            channelID: MockKRDPConstants.ioChannelID,
            userData: payload
        )
    }

    static func licenseValidClient() -> Data {
        var payload = Data()
        payload.appendLittleEndianUInt16(0x0080)
        payload.appendLittleEndianUInt16(0)
        payload.appendUInt8(0xFF)
        payload.appendUInt8(0x03)
        payload.appendLittleEndianUInt16(16)
        payload.appendLittleEndianUInt32(0x0000_0007)
        payload.appendLittleEndianUInt32(0x0000_0002)
        payload.appendLittleEndianUInt16(0)
        payload.appendLittleEndianUInt16(0)
        return mcsSendDataIndication(
            channelID: MockKRDPConstants.ioChannelID,
            userData: payload
        )
    }

    static func demandActive() -> Data {
        let sourceDescriptor = Data("RDPKitMock".utf8)
        var capabilities = Data()
        capabilities.appendLittleEndianUInt16(1)
        capabilities.appendLittleEndianUInt16(0)
        capabilities.appendLittleEndianUInt16(0x0001)
        capabilities.appendLittleEndianUInt16(4)

        var data = Data()
        data.appendLittleEndianUInt16(UInt16(14 + sourceDescriptor.count + capabilities.count))
        data.appendLittleEndianUInt16(0x0011)
        data.appendLittleEndianUInt16(MockKRDPConstants.serverUserID)
        data.appendLittleEndianUInt32(MockKRDPConstants.shareID)
        data.appendLittleEndianUInt16(UInt16(sourceDescriptor.count))
        data.appendLittleEndianUInt16(UInt16(capabilities.count))
        data.append(sourceDescriptor)
        data.append(capabilities)
        return mcsSendDataIndication(
            channelID: MockKRDPConstants.ioChannelID,
            userData: data
        )
    }

    static func serverSynchronize() -> Data {
        var payload = Data()
        payload.appendLittleEndianUInt16(0x0001)
        payload.appendLittleEndianUInt16(MockKRDPConstants.serverUserID)
        return shareDataPacket(pduType2: 0x1F, payload: payload)
    }

    static func controlGranted() -> Data {
        var payload = Data()
        payload.appendLittleEndianUInt16(0x0002)
        payload.appendLittleEndianUInt16(MockKRDPConstants.serverUserID)
        payload.appendLittleEndianUInt32(0)
        return shareDataPacket(pduType2: 0x14, payload: payload)
    }

    static func fontMap() -> Data {
        var payload = Data()
        payload.appendLittleEndianUInt16(0)
        payload.appendLittleEndianUInt16(0)
        payload.appendLittleEndianUInt16(0x0003)
        payload.appendLittleEndianUInt16(0x0004)
        return shareDataPacket(pduType2: 0x28, payload: payload)
    }

    static func dynamicCapabilitiesRequest() -> Data {
        var payload = Data()
        payload.appendUInt8(RDPDynamicVirtualChannelHeader(command: .capabilities).encodedByte)
        payload.appendUInt8(0)
        payload.appendLittleEndianUInt16(2)
        return staticVirtualChannelPacket(payload)
    }

    static func clipboardMonitorReady() -> Data {
        clipboardPacket(RDPClipboardPDU(
            messageType: RDPClipboardMessageType.monitorReady
        ).encoded())
    }

    static func clipboardCapabilities() -> Data {
        clipboardPacket(RDPClipboardCapabilitiesPDU().encoded())
    }

    static func clipboardFormatList(includeFiles: Bool = true, includeText: Bool = false) -> Data {
        var entries: [RDPClipboardFormatListEntry] = []
        if includeText {
            entries.append(RDPClipboardFormatListEntry(formatID: RDPClipboardFormatID.unicodeText))
        }
        if includeFiles {
            entries.append(contentsOf: [
                RDPClipboardFormatListEntry(
                    formatID: MockKRDPConstants.remoteFileGroupDescriptorWFormatID,
                    formatName: RDPClipboardRegisteredFormatName.fileGroupDescriptorW
                ),
                RDPClipboardFormatListEntry(
                    formatID: MockKRDPConstants.remoteFileContentsFormatID,
                    formatName: RDPClipboardRegisteredFormatName.fileContents
                ),
            ])
        }
        return clipboardPacket(RDPClipboardFormatListPDU(entries: entries).encoded())
    }

    static func clipboardFormatListResponse() -> Data {
        clipboardPacket(RDPClipboardPDU(
            messageType: RDPClipboardMessageType.formatListResponse,
            messageFlags: RDPClipboardMessageFlags.responseOK
        ).encoded())
    }

    static func clipboardUnicodeTextRequest() -> Data {
        clipboardPacket(RDPClipboardFormatDataRequestPDU(
            formatID: RDPClipboardFormatID.unicodeText
        ).encoded())
    }

    static func clipboardPacket(_ payload: Data) -> Data {
        staticVirtualChannelPacket(payload, channelID: MockKRDPConstants.clipboardChannelID)
    }

    static func graphicsCreateRequest() -> Data {
        var payload = Data()
        payload.appendUInt8(RDPDynamicVirtualChannelHeader(command: .create).encodedByte)
        payload.appendUInt8(UInt8(MockKRDPConstants.graphicsDynamicChannelID))
        payload.append(Data(RDPGFXChannel.name.utf8))
        payload.appendUInt8(0)
        return staticVirtualChannelPacket(payload)
    }

    static func graphicsCapsConfirm(
        capability: RDPGFXCapabilitySet = MockKRDPGraphicsCapabilitySelection.fixedVersion81
            .selectedCapability(from: nil)
    ) -> Data {
        let capability = capability.encoded
        let confirm = graphicsMessage(commandID: RDPGFXCommandID.capsConfirm, payload: capability)
        return graphicsDynamicPacket(confirm)
    }

    static func displayControlCreateRequest() -> Data {
        dynamicCreateRequest(
            channelID: MockKRDPConstants.displayControlDynamicChannelID,
            channelName: RDPDisplayControlChannel.name
        )
    }

    static func displayControlCaps() -> Data {
        var payload = RDPDisplayControlHeader(
            type: RDPDisplayControlPDUType.caps,
            length: 20
        ).encoded()
        payload.appendLittleEndianUInt32(16)
        payload.appendLittleEndianUInt32(8192)
        payload.appendLittleEndianUInt32(8192)
        return dynamicPacket(
            payload,
            channelID: MockKRDPConstants.displayControlDynamicChannelID
        )
    }

    static func audioCreateRequest() -> Data {
        dynamicCreateRequest(
            channelID: MockKRDPConstants.audioDynamicChannelID,
            channelName: RDPAudioDynamicChannel.name
        )
    }

    static func audioFormats() -> Data {
        dynamicPacket(
            RDPAudioFormatsPDU(
                flags: RDPAudioCapabilityFlags.alive | RDPAudioCapabilityFlags.volume,
                version: 6,
                formats: [.pcmStereo48k16Bit]
            ).encoded(),
            channelID: MockKRDPConstants.audioDynamicChannelID
        )
    }

    static func audioTraining() -> Data {
        dynamicPacket(
            RDPAudioTrainingPDU(timestamp: 0x1234, packetSize: 0x4000).confirmEncoded(),
            channelID: MockKRDPConstants.audioDynamicChannelID
        )
    }

    static func audioWave2() -> Data {
        var payload = Data()
        payload.appendLittleEndianUInt16(0x2233)
        payload.appendLittleEndianUInt16(0)
        payload.appendUInt8(7)
        payload.append(Data(repeating: 0, count: 3))
        payload.appendLittleEndianUInt32(0x0102_0304)
        payload.append(Data([0x11, 0x22, 0x33, 0x44]))
        return dynamicPacket(
            RDPAudioPDU(messageType: RDPAudioMessageType.wave2, payload: payload).encoded(),
            channelID: MockKRDPConstants.audioDynamicChannelID
        )
    }

    static func deviceRedirectionServerAnnounce() -> Data {
        var payload = Data()
        payload.appendLittleEndianUInt16(RDPDeviceRedirectionVersion.major)
        payload.appendLittleEndianUInt16(RDPDeviceRedirectionVersion.minorRDP6)
        payload.appendLittleEndianUInt32(0x0BAD_F00D)
        return deviceRedirectionPacket(RDPDeviceRedirectionPDU(
            header: RDPDeviceRedirectionHeader(packetID: RDPDeviceRedirectionPacketID.serverAnnounce),
            payload: payload
        ).encoded())
    }

    static func deviceRedirectionServerCapability() -> Data {
        deviceRedirectionPacket(RDPDeviceRedirectionPDU(
            header: RDPDeviceRedirectionHeader(packetID: RDPDeviceRedirectionPacketID.serverCapability),
            payload: Data()
        ).encoded())
    }

    static func deviceRedirectionUserLoggedOn() -> Data {
        deviceRedirectionPacket(RDPDeviceRedirectionPDU(
            header: RDPDeviceRedirectionHeader(packetID: RDPDeviceRedirectionPacketID.userLoggedOn),
            payload: Data()
        ).encoded())
    }

    static func deviceRedirectionPacket(_ payload: Data) -> Data {
        staticVirtualChannelPacket(payload, channelID: MockKRDPConstants.deviceRedirectionChannelID)
    }

    static func graphicsFrameUpdatePackets(behavior: MockKRDPGraphicsBehavior) -> [Data] {
        switch behavior {
        case .sendFirstFrame:
            [graphicsDynamicPacket(avc420FrameMessages())]
        case .sendFragmentedBitmapCompositionFrame:
            fragmentedGraphicsDynamicPackets(zgfxMultipart(bitmapCompositionFrameMessages()))
        case .sendClearCodecBandsFrame:
            [graphicsDynamicPacket(clearCodecBandsFrameMessages())]
        case .sendCAVideoRemoteFXFrame:
            [graphicsDynamicPacket(cavideoRemoteFXFrameMessages())]
        case .sendVideoBeforeBitmapCompositionFrame:
            [graphicsDynamicPacket(videoBeforeBitmapCompositionFrameMessages())]
        case .sendInvalidGraphicsPDU:
            [graphicsDynamicPacket(Data([0x12, 0x00, 0x00]))]
        case .sendEmptyFrameThenStall:
            [graphicsEmptyFrameUpdate()]
        case .stallAfterCapsConfirm:
            []
        }
    }

    static func avc420FrameMessages() -> Data {
        let messages = createSurfaceMessage()
            + startFrameMessage()
            + wireToSurfaceMessage()
            + endFrameMessage()
        return messages
    }

    static func bitmapCompositionFrameMessages() -> Data {
        createSurfaceMessage(width: 4, height: 4)
            + mapSurfaceToOutputMessage(surfaceID: 1, x: 10, y: 20)
            + startFrameMessage(frameID: 2)
            + solidFillMessage(
                surfaceID: 1,
                color: [0x01, 0x02, 0x03, 0xFF],
                rects: [RDPGFXRect16(left: 0, top: 0, right: 4, bottom: 4)]
            )
            + surfaceToCacheMessage(
                surfaceID: 1,
                cacheKey: 0x0102_0304_0506_0708,
                cacheSlot: 7,
                sourceRect: RDPGFXRect16(left: 0, top: 0, right: 2, bottom: 2)
            )
            + solidFillMessage(
                surfaceID: 1,
                color: [0x09, 0x08, 0x07, 0xFF],
                rects: [RDPGFXRect16(left: 0, top: 0, right: 4, bottom: 4)]
            )
            + cacheToSurfaceMessage(
                cacheSlot: 7,
                surfaceID: 1,
                points: [RDPGFXPoint16(x: 2, y: 2)]
            )
            + wireToSurfaceMessage(
                surfaceID: 1,
                codecID: RDPGFXCodecID.clearCodec,
                destinationRect: RDPGFXRect16(left: 1, top: 1, right: 3, bottom: 2),
                bitmapData: clearCodecRawRegionStream(width: 2, height: 1, pixels: [
                    0x10, 0x20, 0x30,
                    0x40, 0x50, 0x60,
                ])
            )
            + endFrameMessage(frameID: 2)
    }

    static func clearCodecBandsFrameMessages() -> Data {
        createSurfaceMessage(width: 2, height: 3)
            + mapSurfaceToOutputMessage(surfaceID: 1, x: 0, y: 0)
            + startFrameMessage(frameID: 3)
            + wireToSurfaceMessage(
                surfaceID: 1,
                codecID: RDPGFXCodecID.clearCodec,
                destinationRect: RDPGFXRect16(left: 0, top: 0, right: 2, bottom: 3),
                bitmapData: clearCodecBandsStream(seqNumber: 0, bandsData: clearCodecTwoColumnBandsData())
            )
            + surfaceToCacheMessage(
                surfaceID: 1,
                cacheKey: 0x1111_2222_3333_4444,
                cacheSlot: 8,
                sourceRect: RDPGFXRect16(left: 0, top: 0, right: 2, bottom: 3)
            )
            + cacheToSurfaceMessage(
                cacheSlot: 8,
                surfaceID: 1,
                points: [RDPGFXPoint16(x: 0, y: 0)]
            )
            + endFrameMessage(frameID: 3)
    }

    static func cavideoRemoteFXFrameMessages() -> Data {
        createSurfaceMessage(width: 64, height: 64)
            + mapSurfaceToOutputMessage(surfaceID: 1, x: 10, y: 20)
            + startFrameMessage(frameID: 4)
            + wireToSurfaceMessage(
                surfaceID: 1,
                codecID: RDPGFXCodecID.cavideo,
                destinationRect: RDPGFXRect16(left: 0, top: 0, right: 64, bottom: 64),
                bitmapData: cavideoRemoteFXGrayTileStream()
            )
            + endFrameMessage(frameID: 4)
    }

    static func videoBeforeBitmapCompositionFrameMessages() -> Data {
        createSurfaceMessage()
            + mapSurfaceToOutputMessage(surfaceID: 1, x: 0, y: 0)
            + wireToSurfaceMessage()
            + startFrameMessage(frameID: 9)
            + wireToSurfaceMessage(
                surfaceID: 1,
                codecID: RDPGFXCodecID.clearCodec,
                destinationRect: RDPGFXRect16(left: 1, top: 1, right: 3, bottom: 2),
                bitmapData: clearCodecRawRegionStream(width: 2, height: 1, pixels: [
                    0x10, 0x20, 0x30,
                    0x40, 0x50, 0x60,
                ])
            )
            + endFrameMessage(frameID: 9)
    }

    static func graphicsEmptyFrameUpdate() -> Data {
        let messages = createSurfaceMessage()
            + startFrameMessage()
            + endFrameMessage()
        return graphicsDynamicPacket(messages)
    }

    @discardableResult
    static func expectSendDataRequest(_ packet: Data, channelID expectedChannelID: UInt16) throws -> MockMCSSendDataRequest {
        let request = try clientSendDataRequest(from: packet)
        guard request.initiator == MockKRDPConstants.userChannelID,
              request.channelID == expectedChannelID
        else {
            throw MockKRDPServerError.invalidClientPDU
        }
        return request
    }

    static func staticVirtualChannelPayload(from packet: Data) throws -> Data {
        let request = try clientSendDataRequest(from: packet)
        guard request.initiator == MockKRDPConstants.userChannelID,
              request.channelID == MockKRDPConstants.dynamicChannelID
        else {
            throw MockKRDPServerError.invalidClientPDU
        }
        return try RDPStaticVirtualChannelPDU.parse(fromUserData: request.userData).payload
    }

    static func clientSendDataRequest(from packet: Data) throws -> MockMCSSendDataRequest {
        var cursor = try ByteCursor(X224DataTPDU.unwrap(packet))
        let header = try cursor.readUInt8()
        guard header == 0x64 else {
            throw MockKRDPServerError.invalidClientPDU
        }

        let initiatorOffset = try cursor.readBigEndianUInt16()
        let channelID = try cursor.readBigEndianUInt16()
        let priority = try cursor.readUInt8()
        guard priority == 0x70, initiatorOffset <= UInt16.max - 1001 else {
            throw MockKRDPServerError.invalidClientPDU
        }

        let length = try cursor.readPERLength()
        let userData = try cursor.readData(count: length)
        guard cursor.remaining == 0 else {
            throw MockKRDPServerError.invalidClientPDU
        }
        return MockMCSSendDataRequest(
            initiator: 1001 + initiatorOffset,
            channelID: channelID,
            userData: userData
        )
    }

    static func clientShareDataPDU(from userData: Data) throws -> MockClientShareDataPDU? {
        guard userData.count >= 18 else {
            return nil
        }

        var cursor = ByteCursor(userData)
        let totalLength = try cursor.readLittleEndianUInt16()
        let pduType = try cursor.readLittleEndianUInt16()
        let type = pduType & 0x000F
        let protocolVersion = pduType >> 4
        guard type == 0x0007, protocolVersion == 0x0001 else {
            return nil
        }

        _ = try cursor.readLittleEndianUInt16()
        _ = try cursor.readLittleEndianUInt32()
        _ = try cursor.readUInt8()
        _ = try cursor.readUInt8()
        _ = try cursor.readLittleEndianUInt16()
        let pduType2 = try cursor.readUInt8()
        _ = try cursor.readUInt8()
        _ = try cursor.readLittleEndianUInt16()
        let payloadLength = totalLength == 0x8000
            ? cursor.remaining
            : Int(totalLength) - 18
        guard payloadLength >= 0, payloadLength <= cursor.remaining else {
            throw MockKRDPServerError.invalidClientPDU
        }
        return try MockClientShareDataPDU(
            pduType2: pduType2,
            payload: cursor.readData(count: payloadLength)
        )
    }

    static func inputEvents(from payload: Data) throws -> [RDPSlowPathInputEvent] {
        guard payload.count >= 4 else {
            throw MockKRDPServerError.invalidClientPDU
        }

        var cursor = ByteCursor(payload)
        let eventCount = try Int(cursor.readLittleEndianUInt16())
        _ = try cursor.readLittleEndianUInt16()
        var events: [RDPSlowPathInputEvent] = []
        events.reserveCapacity(eventCount)
        for _ in 0 ..< eventCount {
            _ = try cursor.readLittleEndianUInt32()
            let messageType = try cursor.readLittleEndianUInt16()
            switch messageType {
            case 0x0004:
                let flags = try cursor.readLittleEndianUInt16()
                let code = try cursor.readLittleEndianUInt16()
                _ = try cursor.readLittleEndianUInt16()
                events.append(.scancode(code: code, flags: flags))
            case 0x0005:
                let flags = try cursor.readLittleEndianUInt16()
                let codeUnit = try cursor.readLittleEndianUInt16()
                _ = try cursor.readLittleEndianUInt16()
                events.append(.unicode(codeUnit: codeUnit, isReleased: flags & 0x8000 != 0))
            case 0x8001:
                let flags = try cursor.readLittleEndianUInt16()
                let x = try cursor.readLittleEndianUInt16()
                let y = try cursor.readLittleEndianUInt16()
                if flags & 0x0800 != 0 {
                    events.append(.pointerMove(x: x, y: y))
                } else if flags & 0x0200 != 0 {
                    events.append(.verticalWheel(rotation: wheelRotation(from: flags), x: x, y: y))
                } else if flags & 0x0400 != 0 {
                    events.append(.horizontalWheel(rotation: wheelRotation(from: flags), x: x, y: y))
                } else if let button = pointerButton(from: flags) {
                    events.append(.pointerButton(button: button, isDown: flags & 0x8000 != 0, x: x, y: y))
                } else {
                    throw MockKRDPServerError.invalidClientPDU
                }
            case 0x8002:
                let flags = try cursor.readLittleEndianUInt16()
                let x = try cursor.readLittleEndianUInt16()
                let y = try cursor.readLittleEndianUInt16()
                if flags & RDPPointerButton.extended1.pointerFlag != 0 {
                    events.append(.pointerButton(
                        button: .extended1,
                        isDown: flags & 0x8000 != 0,
                        x: x,
                        y: y
                    ))
                } else if flags & RDPPointerButton.extended2.pointerFlag != 0 {
                    events.append(.pointerButton(
                        button: .extended2,
                        isDown: flags & 0x8000 != 0,
                        x: x,
                        y: y
                    ))
                } else {
                    throw MockKRDPServerError.invalidClientPDU
                }
            default:
                throw MockKRDPServerError.invalidClientPDU
            }
        }

        guard cursor.remaining == 0 else {
            throw MockKRDPServerError.invalidClientPDU
        }
        return events
    }

    static func displayControlLayoutSummary(from payload: Data) throws -> MockDisplayControlLayoutSummary? {
        guard payload.count >= 16 else {
            return nil
        }

        var cursor = ByteCursor(payload)
        let header = try RDPDisplayControlHeader.parse(from: &cursor)
        guard header.type == RDPDisplayControlPDUType.monitorLayout else {
            return nil
        }
        guard Int(header.length) == payload.count else {
            throw MockKRDPServerError.invalidClientPDU
        }

        let monitorLayoutSize = try cursor.readLittleEndianUInt32()
        let monitorCount = try cursor.readLittleEndianUInt32()
        guard monitorLayoutSize == 40, monitorCount > 0, cursor.remaining >= 40 else {
            throw MockKRDPServerError.invalidClientPDU
        }

        _ = try cursor.readLittleEndianUInt32()
        _ = try cursor.readLittleEndianUInt32()
        _ = try cursor.readLittleEndianUInt32()
        let width = try cursor.readLittleEndianUInt32()
        let height = try cursor.readLittleEndianUInt32()
        _ = try cursor.readLittleEndianUInt32()
        _ = try cursor.readLittleEndianUInt32()
        _ = try cursor.readLittleEndianUInt32()
        let desktopScaleFactor = try cursor.readLittleEndianUInt32()
        let deviceScaleFactor = try cursor.readLittleEndianUInt32()
        return MockDisplayControlLayoutSummary(
            monitorCount: monitorCount,
            primaryWidth: width,
            primaryHeight: height,
            primaryDesktopScaleFactor: desktopScaleFactor,
            primaryDeviceScaleFactor: deviceScaleFactor
        )
    }

    static func isDynamicCreateResponse(_ payload: Data, channelIDs: Set<UInt32>) -> Bool {
        guard payload.count >= 6 else {
            return false
        }

        do {
            var cursor = ByteCursor(payload)
            let header = try RDPDynamicVirtualChannelHeader(byte: cursor.readUInt8())
            guard header.command == .create else {
                return false
            }
            let channelID = try cursor.readDynamicVirtualChannelID(lengthCode: header.channelIDLength)
            guard channelIDs.contains(channelID),
                  cursor.remaining == 4
            else {
                return false
            }
            _ = try cursor.readLittleEndianUInt32()
            return true
        } catch {
            return false
        }
    }

    private static func pointerButton(from flags: UInt16) -> RDPPointerButton? {
        if flags & RDPPointerButton.left.pointerFlag != 0 {
            return .left
        }
        if flags & RDPPointerButton.right.pointerFlag != 0 {
            return .right
        }
        if flags & RDPPointerButton.middle.pointerFlag != 0 {
            return .middle
        }
        return nil
    }

    private static func wheelRotation(from flags: UInt16) -> Int {
        let magnitude = Int(flags & 0x01FF)
        return flags & 0x0100 == 0 ? magnitude : -magnitude
    }

    private static func shareDataPacket(pduType2: UInt8, payload: Data) -> Data {
        let userData = rdpShareDataPDUData(
            shareID: MockKRDPConstants.shareID,
            pduSource: MockKRDPConstants.serverUserID,
            pduType2: pduType2,
            payload: payload
        )
        return mcsSendDataIndication(
            channelID: MockKRDPConstants.ioChannelID,
            userData: userData
        )
    }

    private static func staticVirtualChannelPacket(
        _ payload: Data,
        channelID: UInt16 = MockKRDPConstants.dynamicChannelID
    ) -> Data {
        mcsSendDataIndication(
            channelID: channelID,
            userData: RDPStaticVirtualChannelPDU(payload: payload).encodedUserData()
        )
    }

    private static func graphicsDynamicPacket(_ payload: Data) -> Data {
        dynamicPacket(payload, channelID: MockKRDPConstants.graphicsDynamicChannelID)
    }

    private static func fragmentedGraphicsDynamicPackets(_ payload: Data) -> [Data] {
        let firstPayloadCount = min(41, payload.count)
        var packets: [Data] = [
            staticVirtualChannelPacket(dataFirstPayload(
                Data(payload.prefix(firstPayloadCount)),
                totalLength: UInt32(payload.count),
                channelID: MockKRDPConstants.graphicsDynamicChannelID
            )),
        ]

        var offset = firstPayloadCount
        while offset < payload.count {
            let count = min(37, payload.count - offset)
            packets.append(dynamicPacket(
                payload.subdata(in: offset ..< offset + count),
                channelID: MockKRDPConstants.graphicsDynamicChannelID
            ))
            offset += count
        }
        return packets
    }

    private static func dataFirstPayload(_ payload: Data, totalLength: UInt32, channelID: UInt32) -> Data {
        precondition(totalLength <= UInt16.max)
        var data = Data()
        data.appendUInt8(RDPDynamicVirtualChannelHeader(
            channelIDLength: dynamicVirtualChannelIDLengthCode(channelID),
            sp: 1,
            command: .dataFirst
        ).encodedByte)
        data.appendDynamicVirtualChannelID(channelID)
        data.appendLittleEndianUInt16(UInt16(totalLength))
        data.append(payload)
        return data
    }

    private static func dynamicPacket(_ payload: Data, channelID: UInt32) -> Data {
        let dynamicPayload = RDPDynamicVirtualChannelDataPDU(
            channelID: channelID,
            payload: payload
        ).encoded()
        return staticVirtualChannelPacket(dynamicPayload)
    }

    private static func dynamicCreateRequest(channelID: UInt32, channelName: String) -> Data {
        var payload = Data()
        payload.appendUInt8(RDPDynamicVirtualChannelHeader(
            channelIDLength: dynamicVirtualChannelIDLengthCode(channelID),
            command: .create
        ).encodedByte)
        payload.appendDynamicVirtualChannelID(channelID)
        payload.append(Data(channelName.utf8))
        payload.appendUInt8(0)
        return staticVirtualChannelPacket(payload)
    }

    private static func mcsSendDataIndication(channelID: UInt16, userData: Data) -> Data {
        var data = Data()
        data.appendUInt8(0x68)
        data.appendBigEndianUInt16(MockKRDPConstants.serverUserID - 1001)
        data.appendBigEndianUInt16(channelID)
        data.appendUInt8(0x70)
        data.appendPERLength(userData.count)
        data.append(userData)
        return X224DataTPDU.wrap(data)
    }

    private static func createSurfaceMessage(
        surfaceID: UInt16 = 1,
        width: UInt16 = MockKRDPConstants.width,
        height: UInt16 = MockKRDPConstants.height
    ) -> Data {
        var payload = Data()
        payload.appendLittleEndianUInt16(surfaceID)
        payload.appendLittleEndianUInt16(width)
        payload.appendLittleEndianUInt16(height)
        payload.appendUInt8(0x20)
        return graphicsMessage(commandID: RDPGFXCommandID.createSurface, payload: payload)
    }

    private static func mapSurfaceToOutputMessage(surfaceID: UInt16, x: UInt32, y: UInt32) -> Data {
        var payload = Data()
        payload.appendLittleEndianUInt16(surfaceID)
        payload.appendLittleEndianUInt16(0)
        payload.appendLittleEndianUInt32(x)
        payload.appendLittleEndianUInt32(y)
        return graphicsMessage(commandID: RDPGFXCommandID.mapSurfaceToOutput, payload: payload)
    }

    private static func startFrameMessage(frameID: UInt32 = MockKRDPConstants.frameID) -> Data {
        var payload = Data()
        payload.appendLittleEndianUInt32(0)
        payload.appendLittleEndianUInt32(frameID)
        return graphicsMessage(commandID: RDPGFXCommandID.startFrame, payload: payload)
    }

    private static func wireToSurfaceMessage(
        surfaceID: UInt16 = 1,
        codecID: UInt16 = RDPGFXCodecID.avc420,
        pixelFormat: UInt8 = 0x20,
        destinationRect: RDPGFXRect16 = RDPGFXRect16(
            left: 0,
            top: 0,
            right: MockKRDPConstants.width,
            bottom: MockKRDPConstants.height
        ),
        bitmapData: Data = avc420BitmapStream()
    ) -> Data {
        var payload = Data()
        payload.appendLittleEndianUInt16(surfaceID)
        payload.appendLittleEndianUInt16(codecID)
        payload.appendUInt8(pixelFormat)
        payload.append(rectangleData(destinationRect))
        payload.appendLittleEndianUInt32(UInt32(bitmapData.count))
        payload.append(bitmapData)
        return graphicsMessage(commandID: RDPGFXCommandID.wireToSurface1, payload: payload)
    }

    private static func solidFillMessage(
        surfaceID: UInt16,
        color: [UInt8],
        rects: [RDPGFXRect16]
    ) -> Data {
        var payload = Data()
        payload.appendLittleEndianUInt16(surfaceID)
        payload.append(contentsOf: color)
        payload.appendLittleEndianUInt16(UInt16(rects.count))
        for rect in rects {
            payload.append(rectangleData(rect))
        }
        return graphicsMessage(commandID: RDPGFXCommandID.solidFill, payload: payload)
    }

    private static func surfaceToCacheMessage(
        surfaceID: UInt16,
        cacheKey: UInt64,
        cacheSlot: UInt16,
        sourceRect: RDPGFXRect16
    ) -> Data {
        var payload = Data()
        payload.appendLittleEndianUInt16(surfaceID)
        payload.appendLittleEndianUInt64(cacheKey)
        payload.appendLittleEndianUInt16(cacheSlot)
        payload.append(rectangleData(sourceRect))
        return graphicsMessage(commandID: RDPGFXCommandID.surfaceToCache, payload: payload)
    }

    private static func cacheToSurfaceMessage(
        cacheSlot: UInt16,
        surfaceID: UInt16,
        points: [RDPGFXPoint16]
    ) -> Data {
        var payload = Data()
        payload.appendLittleEndianUInt16(cacheSlot)
        payload.appendLittleEndianUInt16(surfaceID)
        payload.appendLittleEndianUInt16(UInt16(points.count))
        for point in points {
            payload.appendLittleEndianUInt16(point.x)
            payload.appendLittleEndianUInt16(point.y)
        }
        return graphicsMessage(commandID: RDPGFXCommandID.cacheToSurface, payload: payload)
    }

    private static func endFrameMessage(frameID: UInt32 = MockKRDPConstants.frameID) -> Data {
        var payload = Data()
        payload.appendLittleEndianUInt32(frameID)
        return graphicsMessage(commandID: RDPGFXCommandID.endFrame, payload: payload)
    }

    private static func clearCodecRawRegionStream(width: UInt16, height: UInt16, pixels: [UInt8]) -> Data {
        var stream = Data([0x00, 0x00])
        stream.appendLittleEndianUInt32(0)
        stream.appendLittleEndianUInt32(0)
        stream.appendLittleEndianUInt32(UInt32(13 + pixels.count))
        stream.appendLittleEndianUInt16(0)
        stream.appendLittleEndianUInt16(0)
        stream.appendLittleEndianUInt16(width)
        stream.appendLittleEndianUInt16(height)
        stream.appendLittleEndianUInt32(UInt32(pixels.count))
        stream.appendUInt8(0)
        stream.append(contentsOf: pixels)
        return stream
    }

    private static func clearCodecBandsStream(seqNumber: UInt8, bandsData: Data) -> Data {
        var stream = Data([0x00, seqNumber])
        stream.appendLittleEndianUInt32(0)
        stream.appendLittleEndianUInt32(UInt32(bandsData.count))
        stream.appendLittleEndianUInt32(0)
        stream.append(bandsData)
        return stream
    }

    private static func clearCodecTwoColumnBandsData() -> Data {
        var bandsData = Data()
        bandsData.appendLittleEndianUInt16(0)
        bandsData.appendLittleEndianUInt16(1)
        bandsData.appendLittleEndianUInt16(0)
        bandsData.appendLittleEndianUInt16(2)
        bandsData.append(contentsOf: [0x00, 0x00, 0x00])
        bandsData.appendLittleEndianUInt16(0x0301)
        bandsData.append(contentsOf: [
            0x10, 0x20, 0x30,
            0x40, 0x50, 0x60,
        ])
        bandsData.appendLittleEndianUInt16(0x0100)
        bandsData.append(contentsOf: [
            0x70, 0x80, 0x90,
        ])
        return bandsData
    }

    private static func rectangleData(_ rect: RDPGFXRect16) -> Data {
        var data = Data()
        data.appendLittleEndianUInt16(rect.left)
        data.appendLittleEndianUInt16(rect.top)
        data.appendLittleEndianUInt16(rect.right)
        data.appendLittleEndianUInt16(rect.bottom)
        return data
    }

    private static func zgfxMultipart(_ data: Data) -> Data {
        let firstCount = data.count / 2
        let first = Data(data.prefix(firstCount))
        let second = data.dropFirst(firstCount)
        var encoded = Data([0xE1])
        encoded.appendLittleEndianUInt16(2)
        encoded.appendLittleEndianUInt32(UInt32(data.count))
        encoded.appendLittleEndianUInt32(UInt32(first.count + 1))
        encoded.appendUInt8(0x04)
        encoded.append(first)
        encoded.appendLittleEndianUInt32(UInt32(second.count + 1))
        encoded.appendUInt8(0x04)
        encoded.append(second)
        return encoded
    }

    private static func avc420BitmapStream() -> Data {
        var data = Data()
        data.appendLittleEndianUInt32(1)
        data.appendLittleEndianUInt16(0)
        data.appendLittleEndianUInt16(0)
        data.appendLittleEndianUInt16(MockKRDPConstants.width)
        data.appendLittleEndianUInt16(MockKRDPConstants.height)
        data.appendUInt8(24)
        data.appendUInt8(90)
        data.append(Data([
            0x00, 0x00, 0x00, 0x01, 0x67, 0x64, 0x00, 0x1F,
            0x00, 0x00, 0x01, 0x68, 0xEE, 0x3C, 0x80,
            0x00, 0x00, 0x01, 0x65, 0x88,
        ]))
        return data
    }

    private static func graphicsMessage(commandID: UInt16, payload: Data) -> Data {
        var data = Data()
        data.appendLittleEndianUInt16(commandID)
        data.appendLittleEndianUInt16(0)
        data.appendLittleEndianUInt32(UInt32(8 + payload.count))
        data.append(payload)
        return data
    }

    private static func berOctetString(_ value: Data) -> Data {
        var data = Data([0x04])
        data.append(berLength(value.count))
        data.append(value)
        return data
    }

    private static func berLength(_ length: Int) -> Data {
        if length < 0x80 {
            return Data([UInt8(length)])
        }
        return Data([0x82, UInt8((length >> 8) & 0xFF), UInt8(length & 0xFF)])
    }
}

private enum MockKRDPTLS {
    static func configuration() throws -> TLSConfiguration {
        let certificates = try certificates()
        let privateKey = try NIOSSLPrivateKey(bytes: Array(privateKeyPEM.utf8), format: .pem)
        return TLSConfiguration.makeServerConfiguration(
            certificateChain: certificates.map { .certificate($0) },
            privateKey: .privateKey(privateKey)
        )
    }

    static func subjectPublicKey() throws -> Data {
        guard let certificate = try certificates().first else {
            throw MockKRDPServerError.invalidClientPDU
        }
        return try RDPCredSSPCertificate.subjectPublicKey(
            fromCertificateDER: Data(certificate.toDERBytes())
        )
    }

    private static func certificates() throws -> [NIOSSLCertificate] {
        try NIOSSLCertificate.fromPEMBytes(Array(certificatePEM.utf8))
    }

    private static let certificatePEM = """
    -----BEGIN CERTIFICATE-----
    MIIDCTCCAfGgAwIBAgIUGA9DmuFCuF0rfQNVE8yBMUrixMkwDQYJKoZIhvcNAQEL
    BQAwFDESMBAGA1UEAwwJbG9jYWxob3N0MB4XDTI2MDYxMTA1MTcyMVoXDTM2MDYw
    ODA1MTcyMVowFDESMBAGA1UEAwwJbG9jYWxob3N0MIIBIjANBgkqhkiG9w0BAQEF
    AAOCAQ8AMIIBCgKCAQEAnzHzi0fY39RU7w2DrelHL+V2nQSPPiI8J4vJYvrkre5d
    xW92Tb2yOnW9qP3u3JMUx9UzS/YkLiRS0+d1npGdumO5Ui+Mm4jKt2BJIIc5LdSl
    dOS8DsbZe6TrZhlftgFgquqaMTi0Oc8gNrjHq7qoTyG0FayTQqFEMDYLkDlKPQyY
    8e0bldfF32SBWozPYzSv15QEjXRQByl5R0GDKP0p7dXvD+aLCrMBbqPqVH69Wv1D
    2q9fTK0lvTbiZIyi8+LU3hn+qa1FOJ55lNGeMnu8FQNA890tCik+HwvZVJ/wsUf7
    /oe7ppNudkozLEC97ebncgefMmMm7r4b6cxBX9rkKwIDAQABo1MwUTAdBgNVHQ4E
    FgQUieHycV/Z8lC3N4/QjGUYCw2CwJUwHwYDVR0jBBgwFoAUieHycV/Z8lC3N4/Q
    jGUYCw2CwJUwDwYDVR0TAQH/BAUwAwEB/zANBgkqhkiG9w0BAQsFAAOCAQEAMy/P
    BO5JpSoD0uHRfgkYwxGrqNPbcesAXyHtc0V3LprE9jatnpa7auKwC58wb0ZJakeN
    cu85YGpvhCJUr/X4eWnh77BOAPt3jrUwwq5Oy4kFjetcZiXHj0CYKRKCuBimx7vT
    /xjkifCTGcFkEf+EmJCWsA1Sdcdb++8xtGdwr9rjBkbJ0HmsYfsR20sOW8f+Odju
    GA/NBc4FjB1RHCmPb42tTxUx7FSjrABRfy1AERKnjvSwZoVEQXHY/K66rrsdmBWt
    z4YuDi9E2uHN4IxRSxVPCkjku9nzah0MjPfcRsnLQjfqnOSYe8sCrIEj+29xXyQS
    8wewUI+W+BPAKEpB8w==
    -----END CERTIFICATE-----
    """

    private static let privateKeyPEM = """
    -----BEGIN PRIVATE KEY-----
    MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQCfMfOLR9jf1FTv
    DYOt6Ucv5XadBI8+Ijwni8li+uSt7l3Fb3ZNvbI6db2o/e7ckxTH1TNL9iQuJFLT
    53WekZ26Y7lSL4ybiMq3YEkghzkt1KV05LwOxtl7pOtmGV+2AWCq6poxOLQ5zyA2
    uMeruqhPIbQVrJNCoUQwNguQOUo9DJjx7RuV18XfZIFajM9jNK/XlASNdFAHKXlH
    QYMo/Snt1e8P5osKswFuo+pUfr1a/UPar19MrSW9NuJkjKLz4tTeGf6prUU4nnmU
    0Z4ye7wVA0Dz3S0KKT4fC9lUn/CxR/v+h7umk252SjMsQL3t5udyB58yYybuvhvp
    zEFf2uQrAgMBAAECggEABflegpD2q/R27EwQiS7Vug/QmYHgGKlsontJDaRzf0d2
    6cx0a+RwUzTmu8T6LF+xcIv14D+wPRil3Xsawd5rEeFhXs39mjsFVUf3icRchyjE
    vZQPFQR6iUmEf/deme265/V+RdYzHtXabdNI9iilQ+fBSOyKAv60S8h4OwUhxEd5
    wzwTLS21/vtY/AiFxRzjzr/fWMiQz6rYNHfRPKmgxyQLpNZ9Kvr061lDzir3/Ymo
    YpDunwvw+WhveiCPsfhJI+IourB3mZ41BPz1CN4XfNhRmqQYCMSMdsqIwUj8ziaT
    77xSVKbg9JlyFyFFevUcKtd70MEgcWQMUbM65vN9KQKBgQDXEk1jcPTWNJwm/j7I
    jko/i9b8p/nS+jlSd2mTW/wECk7p3WzBbuZTdA1TFjA1fgedQ4L/jBbESPuzF7KL
    XOvo6D3rCmZbhFqZ6d7XxQYsf0F4ExQ31/6JkP5e+u9llZTmF0VyDQsuKjRF+OvE
    ciDkco8R/YCxqa6x+5sUi7r6TQKBgQC9fYEdlcYbFYCDZR7aQanJNK836vvKSD42
    P0fIB6m/3NJSJyheDh6WoX0NQfkzpJRFk2SgNRGJzgTB57FeoNBARt+SoNa3Bimo
    6qzIRx62ZX/+knUIQkgjhYR1ehaq4g5XzTWfiiA48LcHRG10npUTgv6H5N2rkmkm
    LEbjXREkVwKBgBD02XMgob0Nss4EN5D6XvI5pT6QQ8sVfVV6IrHCi9EJuwUHNx7d
    Dn2/5ZkKY8yj3hfRDc/2DIl3M5kAIkyIi/T18oPIcx9+BOKjpLUgTIdPlSrRXkO0
    3NWdv+BfKma4719gsFH4o0wFec+We4gmc19vhMYnVXEsbqCLtMNe7OP1AoGBAKih
    EdAUQ3JC1lUYHja5DLGkEvI+ScigNczsz6JxP10g1IKLml7pTcta9wBfX7fXlKO+
    IWR5FZx/HLi6yZuenPU2nSvNuoayE0zhWtX4hJppBVi1WTT6V1xVK6Wn+pgkCAOW
    +Ut7DmXdwePTv1xy69OrVXv17lcLOkvgR016uxCNAoGANnPk41YIAc+apqvt7rZG
    mIil2And447Dff+ytXrsDPUtg2Ryb1G04DiKraFntQKXCDhVAZ85qWNFFJ+/0mA6
    fucv0LtJojVaqV9V//doxF1zOMo1AMDH/R+u+s7r7c0mdOp2WEUNtB6HeZDWfl4n
    ep2QGCMax2Iz/CIb9ZuH3hI=
    -----END PRIVATE KEY-----
    """
}
