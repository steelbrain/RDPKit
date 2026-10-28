import Foundation
import CryptoKit
import NIOCore
import NIOPosix
@preconcurrency import NIOSSL
@testable import RDPKit

/// A local RDP server for client tests. It speaks the KRdp-style flow by
/// default; `Options` switches individual steps to other server behaviors.
final class MockKRDPServer {
    struct Options {
        var securityProtocol = MockKRDPSecurityProtocol.tls
        var clipboardFiles: [RDPClipboardLocalFile] = []
        var graphicsBehavior = MockKRDPGraphicsBehavior.sendFirstFrame
        var graphicsCapabilitySelection = MockKRDPGraphicsCapabilitySelection.fixedVersion81
        var autoDetectBehavior = MockKRDPAutoDetectBehavior.singleRTT
        var licensingBehavior = MockKRDPLicensingBehavior.validClientThenDemandActive
        var redirectionBehavior = MockKRDPRedirectionBehavior.none
        var finalizationBehavior = MockKRDPFinalizationBehavior.grantBeforeFontList
        var auxiliaryDynamicChannelBehavior = MockKRDPAuxiliaryDynamicChannelBehavior.none
        var dynamicChannelVersion: UInt16 = 2
        var remoteClipboardText: String?
        var audioEnabled = false
        var waitForCompatibilityTraffic = false
        var requireBitmapCodecsCapability = false
    }

    let port: UInt16
    let transcript: Locked<MockKRDPServerTranscript>
    private let connections: Locked<Int>
    private let group: MultiThreadedEventLoopGroup
    private let channel: Channel

    var connectionCount: Int {
        connections.value
    }

    private init(
        port: UInt16,
        transcript: Locked<MockKRDPServerTranscript>,
        connections: Locked<Int>,
        group: MultiThreadedEventLoopGroup,
        channel: Channel
    ) {
        self.port = port
        self.transcript = transcript
        self.connections = connections
        self.group = group
        self.channel = channel
    }

    static func start(_ options: Options = Options()) throws -> MockKRDPServer {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let transcript = Locked(MockKRDPServerTranscript())
        let connections = Locked(0)
        do {
            let tlsContext = try NIOSSLContext(configuration: MockKRDPTLS.configuration())
            let channel = try ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { channel in
                    channel.pipeline.addHandler(MockKRDPServerHandler(
                        options: options,
                        tlsContext: tlsContext,
                        transcript: transcript,
                        connections: connections
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
                transcript: transcript,
                connections: connections,
                group: group,
                channel: channel
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
    case credSSPWithEarlyUserAuth(credentials: RDPCredentials, authorizationResult: RDPEarlyUserAuthorizationResult)
    case rdSTLS
    case standard
    case failure(code: UInt32)
}

enum MockKRDPGraphicsBehavior: Equatable {
    case sendFirstFrame
    case sendPointerUpdatesBeforeFirstFrame
    case sendCompressedCapsConfirmFirstFrame
    case sendFragmentedCompressedCapsConfirmFirstFrame
    case stallAfterFragmentedCapsConfirm
    case sendFragmentedBitmapCompositionFrame
    case sendClearCodecBandsFrame
    case sendCAVideoRemoteFXFrame
    case sendCAProgressiveFrame
    case sendVideoBeforeBitmapCompositionFrame
    case sendMultipleVideoUpdatesInFrame
    case sendTwoFramesInOnePayload
    case sendMultipleBitmapSurfacesInFrame
    case sendMalformedAVCFrame
    case sendInvalidGraphicsPDU
    case sendCompressedCAVideoRemoteFXFrame
    case sendUnsupportedCompressedDynamicData
    case sendCompressedDataLargerThanOnePDU
    case sendSoftSyncBeforeFrame
    case sendUnknownCloseBeforeFrame
    case sendEmptyFrameThenStall
    case closeAfterFirstFrame
    case setErrorInfoThenCloseAfterFirstFrame
    case setErrorInfoLogoffBeforeFrame
}

enum MockKRDPGraphicsCapabilitySelection {
    case fixedVersion81
    case firstAdvertised
    case firstAdvertisedDifferentFlags
    case version10

    func selectedCapability(from advertise: RDPGFXCapsAdvertisePDU?) -> RDPGFXCapabilitySet {
        switch self {
        case .fixedVersion81:
            return Self.fixedVersion81Capability
        case .firstAdvertised:
            return advertise?.capabilitySets.first ?? Self.fixedVersion81Capability
        case .firstAdvertisedDifferentFlags:
            return Self.differentFlagsCapability(
                version: advertise?.capabilitySets.first?.version
                    ?? RDPGFXCapabilityVersion.version81
            )
        case .version10:
            return Self.version10Capability
        }
    }

    private static var fixedVersion81Capability: RDPGFXCapabilitySet {
        .version81(flags: RDPGFXCapabilityFlags.defaultVersion81)
    }

    private static func differentFlagsCapability(version: UInt32) -> RDPGFXCapabilitySet {
        switch version {
        case RDPGFXCapabilityVersion.version8:
            .version8(flags: RDPGFXCapabilityFlags.thinClient)
        case RDPGFXCapabilityVersion.version81:
            .version81(flags: RDPGFXCapabilityFlags.defaultVersion8)
        default:
            .version107(flags: RDPGFXCapabilityFlags.smallCache)
        }
    }

    private static var version10Capability: RDPGFXCapabilitySet {
        var data = Data()
        data.appendLittleEndianUInt32(RDPGFXCapabilityFlags.smallCache)
        return RDPGFXCapabilitySet(version: RDPGFXCapabilityVersion.version10, data: data)
    }
}

enum MockKRDPAutoDetectBehavior {
    case singleRTT
    case bandwidthMeasure
    /// Only a connect-time Bandwidth Measure Start, which has no response
    /// ([MS-RDPBCGR] 2.2.14.1.2), then licensing.
    case noReplyRequestOnly
}

enum MockKRDPLicensingBehavior {
    case validClientThenDemandActive
    case validClientThenDemandActiveWithMonitorLayout
    case demandActiveOnly
    case serverLicenseRequest
    case serverLicenseRequestWithStoredClientLicense
    case serverLicenseRequestX509
    case noLicenseServerError
    case disconnectInsteadOfLicensing
}

enum MockKRDPRedirectionBehavior {
    case none
    /// Send a server redirection PDU (carrying a routing-token load-balance
    /// cookie, no target host) on the first connection only, so the client
    /// reconnects to the same server with the token attached.
    case redirectFirstConnection
    /// Windows connection brokers redirect right after licensing, in place
    /// of the Demand Active ([MS-RDPBCGR] 1.3.1.1, 3.1.5.2).
    case redirectInsteadOfDemandActive
}

enum MockKRDPFinalizationBehavior: Equatable {
    case grantBeforeFontList
    case waitForFontListBeforeGrant
    case waitForClientSynchronizeBeforeServerSynchronize
    case saveSessionInfoBeforeSynchronize
    /// Server emits Control(Cooperate) before Synchronize — legal interleaving some stacks produce.
    case controlCooperateBeforeSynchronize
    case grantControlWithoutFontMap
    case deactivateAfterFontMap
    case deactivateThenReactivateAfterFontMap
    case deactivateThenUserRequestedDisconnectAfterFontMap
    case setErrorInfoDeniedThenDeactivateAfterFontMap
    case setErrorInfoLogoffThenDeactivateAfterFontMap
    case userRequestedDisconnectAfterFontMap
}

enum MockKRDPAuxiliaryDynamicChannelBehavior {
    case none
    /// Windows-style channels this client does not implement; it must reject them.
    case unsupportedChannels
    case fragmentedGraphicsCreate

    var createRequests: [(channelID: UInt32, channelName: String)] {
        switch self {
        case .none, .fragmentedGraphicsCreate:
            []
        case .unsupportedChannels:
            [
                (1, "Microsoft::Windows::RDS::Input"),
                (2, "Microsoft::Windows::RDS::CoreInput"),
                (3, "AUDIO_INPUT"),
                (8, "Microsoft::Windows::RDS::MouseCursor"),
            ]
        }
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

/// What the mock received from the client.
struct MockKRDPServerTranscript: Equatable, Sendable {
    var inputEvents: [RDPSlowPathInputEvent] = []
    var clipboardStaticFlags: [UInt32] = []
    var clientClipboardMessages: [RDPClipboardMessageSummary] = []
    var receivedLocalClipboardText: String?
    var audioClientMessages: [RDPAudioMessageSummary] = []
    var dynamicCreateStatuses: [UInt32: Int32] = [:]
    var deviceRedirectionClientMessages: [String] = []
    var displayControlLayouts: [MockDisplayControlLayoutSummary] = []
    var dynamicCreateResponseStaticFlags: [UInt32] = []
    var displayControlStaticFlags: [UInt32] = []
    var audioDynamicStaticFlags: [UInt32] = []
    var credSSPMessages: [String] = []
    var credSSPGates: [String] = []
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

private typealias MockMCSSendDataRequest = (initiator: UInt16, channelID: UInt16, userData: Data)

private struct MockClientShareDataPDU {
    var pduType2: UInt8
    var payload: Data
}

/// The server side of CredSSP with NTLM ([MS-CSSP] 3.1.5, [MS-NLMP] 3.2.5).
/// It checks the client's proofs with the library's NTOWFv2 and RC4.
final class MockCredSSPServer {
    private enum Stage {
        case negotiate
        case authenticate
        case credentials
        case complete
    }

    private let credentials: RDPCredentials
    private let transcript: Locked<MockKRDPServerTranscript>
    private let subjectPublicKey: Data
    private let channelBindingsHash: Data
    private let serverChallenge = Data([0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF])
    private let timestamp: UInt64 = 0x01DA_0000_0000_0000
    private var stage = Stage.negotiate
    private var clientNonce = Data()
    private var negotiatedFlags: UInt32 = 0
    private var sendSigningKey = Data()
    private var receiveSigningKey = Data()
    private var sendSealingKey: RDPNTLMRC4?
    private var receiveSealingKey: RDPNTLMRC4?
    private var sendSequenceNumber: UInt32 = 0
    private var receiveSequenceNumber: UInt32 = 0

    init(credentials: RDPCredentials, transcript: Locked<MockKRDPServerTranscript> = Locked(MockKRDPServerTranscript())) throws {
        self.credentials = credentials
        self.transcript = transcript
        subjectPublicKey = try MockKRDPTLS.subjectPublicKey()
        channelBindingsHash = try MockKRDPTLS.ntlmChannelBindingsHash()
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
            record(message: "ntlm-negotiate")
            let negotiateToken = try request.negoTokens.last.map(RDPSPNEGO.mechanismToken(from:))
            guard let nonce = request.clientNonce,
                  nonce.count == 32,
                  negotiateToken?.starts(with: Self.ntlmSignature) == true
            else {
                throw MockKRDPServerError.invalidClientPDU
            }
            if request.negoTokens.last == negotiateToken {
                record(gate: "raw-ntlm-negotiate-token")
            }
            record(gate: "initial-client-nonce")
            clientNonce = nonce
            stage = .authenticate
            return RDPCredSSPTSRequest(
                version: 6,
                // Windows and FreeRDP-based servers send the raw NTLM challenge.
                negoTokens: [challengeMessage()]
            ).encoded()

        case .authenticate:
            record(message: "ntlm-authenticate")
            if let nonce = request.clientNonce {
                if nonce == clientNonce {
                    record(gate: "authenticate-client-nonce")
                }
                clientNonce = nonce
            }
            guard let authenticateToken = request.negoTokens.last else {
                throw MockKRDPServerError.invalidClientPDU
            }
            if authenticateToken.starts(with: Self.ntlmSignature) {
                record(gate: "raw-ntlm-authenticate-token")
            }
            try installKeys(from: RDPSPNEGO.mechanismToken(from: authenticateToken))
            guard let clientPubKeyAuth = request.pubKeyAuth else {
                throw MockKRDPServerError.invalidClientPDU
            }
            guard try unwrap(clientPubKeyAuth) == RDPCredSSPPublicKeyBinding.clientServerHash(
                subjectPublicKey: subjectPublicKey,
                nonce: clientNonce
            ) else {
                throw MockKRDPServerError.invalidClientPDU
            }
            record(gate: "nonce-bound-pubkeyauth")
            stage = .credentials
            return try RDPCredSSPTSRequest(
                version: 6,
                pubKeyAuth: wrap(RDPCredSSPPublicKeyBinding.serverClientHash(
                    subjectPublicKey: subjectPublicKey,
                    nonce: clientNonce
                ))
            ).encoded()

        case .credentials:
            record(message: "credentials")
            let expectedNonce = request.version >= 5 ? clientNonce : nil
            guard let authInfo = request.authInfo,
                  request.clientNonce == expectedNonce,
                  try unwrap(authInfo).isEmpty == false
            else {
                throw MockKRDPServerError.invalidClientPDU
            }
            record(gate: "credentials-client-nonce")
            stage = .complete
            return nil

        case .complete:
            throw MockKRDPServerError.invalidClientPDU
        }
    }

    private func record(message: String) {
        transcript.withLock { $0.credSSPMessages.append(message) }
    }

    private func record(gate: String) {
        transcript.withLock { $0.credSSPGates.append(gate) }
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
        let ntlmV2Hash = RDPCredSSPNTLMContext.ntowfV2(
            password: credentials.password,
            username: credentials.username,
            domain: credentials.domain ?? ""
        )
        guard Self.hmacMD5(key: ntlmV2Hash, data: serverChallenge + responsePayload) == proof else {
            throw MockKRDPServerError.invalidClientPDU
        }
        // NTLMv2_CLIENT_CHALLENGE: the AV pairs start 28 bytes in ([MS-NLMP] 2.2.2.7).
        if Data(responsePayload.dropFirst(28)).containsNTLMChannelBindings(channelBindingsHash) {
            record(gate: "ntlm-channel-bindings")
        }
        let keyExchangeKey = Self.hmacMD5(key: ntlmV2Hash, data: proof)
        negotiatedFlags = try readLittleEndianUInt32(authenticate, at: 60)

        var exportedSessionKey = keyExchangeKey
        if negotiatedFlags & Self.negotiateKeyExchange != 0 {
            exportedSessionKey = try RDPNTLMRC4(key: keyExchangeKey).process(readSecurityBuffer(authenticate, at: 52))
        }
        sendSigningKey = Self.md5(exportedSessionKey + Self.serverSigningMagic)
        receiveSigningKey = Self.md5(exportedSessionKey + Self.clientSigningMagic)
        sendSealingKey = RDPNTLMRC4(key: Self.md5(exportedSessionKey + Self.serverSealingMagic))
        receiveSealingKey = RDPNTLMRC4(key: Self.md5(exportedSessionKey + Self.clientSealingMagic))
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
        guard signature == Self.signature(checksum: checksum, sequenceNumber: sequenceNumber) else {
            throw MockKRDPServerError.invalidClientPDU
        }
        receiveSequenceNumber &+= 1
        return decryptedMessage
    }

    private func readSecurityBuffer(_ data: Data, at offset: Int) throws -> Data {
        var cursor = try ByteCursor(readData(data, at: offset, count: 8))
        let length = try Int(cursor.readLittleEndianUInt16())
        _ = try cursor.readLittleEndianUInt16()
        return try readData(data, at: Int(cursor.readLittleEndianUInt32()), count: length)
    }

    private func readLittleEndianUInt32(_ data: Data, at offset: Int) throws -> UInt32 {
        var cursor = try ByteCursor(readData(data, at: offset, count: 4))
        return try cursor.readLittleEndianUInt32()
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

    private func append(fieldLength: Int, offset: Int, to data: inout Data) {
        data.appendLittleEndianUInt16(UInt16(fieldLength))
        data.appendLittleEndianUInt16(UInt16(fieldLength))
        data.appendLittleEndianUInt32(UInt32(offset))
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

    private static func md5(_ data: Data) -> Data {
        Data(Insecure.MD5.hash(data: data))
    }

    private static func hmacMD5(key: Data, data: Data) -> Data {
        Data(HMAC<Insecure.MD5>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }

    private static let ntlmSignature = Data("NTLMSSP\u{0}".utf8)
    private static let signatureSize = 16
    private static let version = Data([0x06, 0x01, 0xB1, 0x1D, 0x00, 0x00, 0x00, 0x0F])
    private static let clientSigningMagic = Data("session key to client-to-server signing key magic constant\u{0}".utf8)
    private static let serverSigningMagic = Data("session key to server-to-client signing key magic constant\u{0}".utf8)
    private static let clientSealingMagic = Data("session key to client-to-server sealing key magic constant\u{0}".utf8)
    private static let serverSealingMagic = Data("session key to server-to-client sealing key magic constant\u{0}".utf8)

    private static let negotiateKeyExchange: UInt32 = 0x4000_0000
    /// 56, 128, KEY_EXCH, VERSION, TARGET_INFO, EXTENDED_SESSIONSECURITY,
    /// ALWAYS_SIGN, NTLM, SEAL, SIGN, REQUEST_TARGET and UNICODE ([MS-NLMP] 2.2.2.5).
    private static let challengeFlags: UInt32 = 0xE288_8235
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
        case clientNewLicenseRequest
        case clientLicenseInformation
        case confirmActive
        case finalization(Int)
        case finalizationFontList
        case dynamicCapabilitiesResponse
        case graphicsCreateResponse(Int)
        case graphicsCapsAdvertise
        case graphicsFrameAcknowledge
        case done
    }

    private let options: MockKRDPServer.Options
    private let tlsContext: NIOSSLContext
    private let transcript: Locked<MockKRDPServerTranscript>
    private let connections: Locked<Int>
    private var connectionIndex = 0
    private var stage = Stage.x224
    private var received = ClientByteStream()
    private var hasReactivated = false
    private var isAwaitingReactivation = false
    private var didReleaseGraphicsHandshake = false
    private var didReleaseGraphicsFrame = false
    private var credSSPServer: MockCredSSPServer?

    init(
        options: MockKRDPServer.Options,
        tlsContext: NIOSSLContext,
        transcript: Locked<MockKRDPServerTranscript>,
        connections: Locked<Int>
    ) {
        self.options = options
        self.tlsContext = tlsContext
        self.transcript = transcript
        self.connections = connections
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        if let bytes = buffer.readBytes(length: buffer.readableBytes) {
            received.append(bytes)
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
            if case .credSSP = stage {
                guard let message = try received.nextCredSSPMessage() else {
                    return
                }
                try handleCredSSP(message, context: context)
            } else {
                guard let packet = try received.nextPacket() else {
                    return
                }
                try handle(packet, context: context)
            }
        }
    }

    private func handle(_ packet: Data, context: ChannelHandlerContext) throws {
        if let request = try? mcsSendDataRequest(fromTPKT: packet),
           request.initiator == MockKRDPConstants.userChannelID,
           try handleChannelTraffic(request, context: context)
        {
            return
        }

        switch stage {
        case .x224:
            _ = try TPKT.unwrap(packet)
            connectionIndex = connections.withLock { count in
                count += 1
                return count
            }
            try answerConnectionRequest(context: context)

        case .credSSP:
            throw MockKRDPServerError.invalidClientPDU

        case .mcsConnectInitial:
            _ = try X224DataTPDU.unwrap(packet)
            write(
                MockKRDPFixtures.mcsConnectResponse(
                    clipboardEnabled: clipboardEnabled,
                    audioEnabled: options.audioEnabled,
                    clientRequestedProtocols: clientRequestedProtocols
                ),
                context: context
            )
            stage = .erectDomain

        case .erectDomain:
            _ = try X224DataTPDU.unwrap(packet)
            stage = .attachUser

        case .attachUser:
            _ = try X224DataTPDU.unwrap(packet)
            write(MockKRDPFixtures.attachUserConfirm(), context: context)
            stage = .channelJoin(0)

        case let .channelJoin(index):
            _ = try X224DataTPDU.unwrap(packet)
            let joinChannelIDs = MockKRDPFixtures.joinChannelIDs(
                clipboardEnabled: clipboardEnabled,
                audioEnabled: options.audioEnabled
            )
            write(MockKRDPFixtures.channelJoinConfirm(channelID: joinChannelIDs[index]), context: context)
            stage = index + 1 == joinChannelIDs.count ? .clientInfo : .channelJoin(index + 1)

        case .clientInfo:
            try MockKRDPFixtures.expectSendDataRequest(packet, channelID: MockKRDPConstants.ioChannelID)
            if options.autoDetectBehavior == .noReplyRequestOnly {
                write(MockKRDPFixtures.autoDetectRequest(requestType: 0x1014), context: context)
                write(MockKRDPFixtures.licenseValidClient(), context: context)
                write(MockKRDPFixtures.demandActive(), context: context)
                stage = .confirmActive
                break
            }
            write(MockKRDPFixtures.autoDetectRequest(), context: context)
            stage = .autoDetectResponse

        case .autoDetectResponse:
            try MockKRDPFixtures.expectSendDataRequest(packet, channelID: MockKRDPConstants.messageChannelID)
            if options.autoDetectBehavior == .bandwidthMeasure {
                write(MockKRDPFixtures.autoDetectBandwidthMeasureStop(), context: context)
                stage = .bandwidthMeasureResponse
                break
            }
            try startLicensing(context: context)

        case .bandwidthMeasureResponse:
            let request = try MockKRDPFixtures.expectSendDataRequest(packet, channelID: MockKRDPConstants.messageChannelID)
            try MockKRDPFixtures.expectAutoDetectBandwidthResult(request.userData)
            try startLicensing(context: context)

        case .clientNewLicenseRequest:
            let request = try MockKRDPFixtures.expectSendDataRequest(packet, channelID: MockKRDPConstants.ioChannelID)
            try MockKRDPFixtures.expectClientNewLicenseRequest(request.userData)
            // A host in its licensing grace period answers with STATUS_VALID_CLIENT
            // ([MS-RDPELE] 3.1.5.3); the X.509 variant goes straight to Demand Active.
            if options.licensingBehavior == .serverLicenseRequest {
                write(MockKRDPFixtures.licenseValidClient(), context: context)
            }
            write(MockKRDPFixtures.demandActive(), context: context)
            stage = .confirmActive

        case .clientLicenseInformation:
            let request = try MockKRDPFixtures.expectSendDataRequest(packet, channelID: MockKRDPConstants.ioChannelID)
            try MockKRDPFixtures.expectClientLicenseInformation(request.userData)
            write(MockKRDPFixtures.demandActive(), context: context)
            stage = .confirmActive

        case .confirmActive:
            let request = try MockKRDPFixtures.expectSendDataRequest(packet, channelID: MockKRDPConstants.ioChannelID)
            if options.requireBitmapCodecsCapability {
                let capabilityTypes = try MockKRDPFixtures.clientConfirmActiveCapabilityTypes(from: request.userData)
                guard capabilityTypes.contains(0x001D) else {
                    throw MockKRDPServerError.invalidClientPDU
                }
            }
            switch options.finalizationBehavior {
            case .waitForClientSynchronizeBeforeServerSynchronize:
                break
            case .saveSessionInfoBeforeSynchronize:
                write(MockKRDPFixtures.saveSessionInfo(), context: context)
                write(MockKRDPFixtures.serverSynchronize(), context: context)
                write(MockKRDPFixtures.serverControlCooperate(), context: context)
            case .controlCooperateBeforeSynchronize:
                write(MockKRDPFixtures.serverControlCooperate(), context: context)
                write(MockKRDPFixtures.serverSynchronize(), context: context)
            default:
                write(MockKRDPFixtures.serverSynchronize(), context: context)
                write(MockKRDPFixtures.serverControlCooperate(), context: context)
            }
            stage = .finalization(0)

        case let .finalization(count):
            try receiveClientFinalization(packet, count: count + 1, context: context)

        case .finalizationFontList:
            try MockKRDPFixtures.expectSendDataRequest(packet, channelID: MockKRDPConstants.ioChannelID)
            stage = isAwaitingReactivation ? .confirmActive : .dynamicCapabilitiesResponse
            isAwaitingReactivation = false

        case .dynamicCapabilitiesResponse:
            _ = try MockKRDPFixtures.staticVirtualChannelPayload(from: packet)
            let auxiliaryChannels = options.auxiliaryDynamicChannelBehavior.createRequests
            for createRequest in auxiliaryChannels {
                write(MockKRDPFixtures.dynamicCreateRequest(
                    channelID: createRequest.channelID,
                    channelName: createRequest.channelName
                ), context: context)
            }
            if options.auxiliaryDynamicChannelBehavior == .fragmentedGraphicsCreate {
                for createPacket in MockKRDPFixtures.fragmentedGraphicsCreateRequest() {
                    write(createPacket, context: context)
                }
            } else {
                write(MockKRDPFixtures.graphicsCreateRequest(), context: context)
            }
            stage = .graphicsCreateResponse(auxiliaryChannels.count + 1)

        case let .graphicsCreateResponse(remaining):
            let staticPayload = try MockKRDPFixtures.staticVirtualChannelPayload(from: packet)
            if let response = MockKRDPFixtures.dynamicCreateResponse(staticPayload) {
                transcript.withLock { $0.dynamicCreateStatuses[response.channelID] = response.status }
            }
            stage = remaining > 1 ? .graphicsCreateResponse(remaining - 1) : .graphicsCapsAdvertise

        case .graphicsCapsAdvertise:
            try answerGraphicsCapsAdvertise(packet, context: context)

        case .graphicsFrameAcknowledge:
            _ = try MockKRDPFixtures.staticVirtualChannelPayload(from: packet)
            if options.graphicsBehavior == .setErrorInfoThenCloseAfterFirstFrame {
                // ERRINFO_DISCONNECTED_BY_OTHERCONNECTION, then TCP close.
                write(MockKRDPFixtures.setErrorInfo(0x0000_0005), context: context)
            }
            if [.closeAfterFirstFrame, .setErrorInfoThenCloseAfterFirstFrame].contains(options.graphicsBehavior) {
                context.close(promise: nil)
            }
            stage = .done

        case .done:
            break
        }
    }

    private func answerConnectionRequest(context: ChannelHandlerContext) throws {
        let selectedProtocols: RDPSecurityProtocols
        switch options.securityProtocol {
        case .tls:
            selectedProtocols = .tls
        case let .credSSP(credentials):
            selectedProtocols = .credSSP
            credSSPServer = try MockCredSSPServer(credentials: credentials, transcript: transcript)
        case let .credSSPWithEarlyUserAuth(credentials, _):
            selectedProtocols = .credSSPWithEarlyUserAuth
            credSSPServer = try MockCredSSPServer(credentials: credentials, transcript: transcript)
        case .rdSTLS:
            write(MockKRDPFixtures.x224ConnectionConfirm(selectedProtocols: .rdSTLS), context: context)
            stage = .done
            return
        case .standard:
            write(MockKRDPFixtures.x224ConnectionConfirm(selectedProtocols: []), context: context)
            stage = .done
            return
        case let .failure(code):
            write(MockKRDPFixtures.x224ConnectionFailure(code: code), context: context)
            stage = .done
            return
        }
        write(MockKRDPFixtures.x224ConnectionConfirm(selectedProtocols: selectedProtocols), context: context)
        try context.channel.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: tlsContext), position: .first)
        stage = credSSPServer == nil ? .mcsConnectInitial : .credSSP
    }

    private func startLicensing(context: ChannelHandlerContext) throws {
        switch options.licensingBehavior {
        case .validClientThenDemandActive where options.redirectionBehavior == .redirectInsteadOfDemandActive
            && connectionIndex == 1:
            write(MockKRDPFixtures.licenseValidClient(), context: context)
            write(MockKRDPFixtures.serverRedirection(), context: context)
            stage = .done
        case .validClientThenDemandActive, .validClientThenDemandActiveWithMonitorLayout:
            write(MockKRDPFixtures.licenseValidClient(), context: context)
            write(MockKRDPFixtures.demandActive(), context: context)
            if options.licensingBehavior == .validClientThenDemandActiveWithMonitorLayout {
                write(MockKRDPFixtures.monitorLayout(), context: context)
            }
            stage = .confirmActive
        case .demandActiveOnly:
            write(MockKRDPFixtures.demandActive(), context: context)
            stage = .confirmActive
        case .serverLicenseRequest:
            write(MockKRDPFixtures.serverLicenseRequest(), context: context)
            stage = .clientNewLicenseRequest
        case .serverLicenseRequestWithStoredClientLicense:
            write(MockKRDPFixtures.serverLicenseRequest(), context: context)
            stage = .clientLicenseInformation
        case .serverLicenseRequestX509:
            write(
                MockKRDPFixtures.serverLicenseRequest(certificatePayload: try MockKRDPTLS.rdpX509CertificateChain()),
                context: context
            )
            stage = .clientNewLicenseRequest
        case .noLicenseServerError:
            write(MockKRDPFixtures.licenseError(code: 0x0000_0006, stateTransition: 0x0000_0001), context: context)
            stage = .done
        case .disconnectInsteadOfLicensing:
            write(MockKRDPFixtures.disconnectProviderUltimatum(), context: context)
            stage = .done
        }
    }

    /// The client's Synchronize, Cooperate, Request Control and Font List
    /// ([MS-RDPBCGR] 1.3.1.1); `count` is the number received so far.
    private func receiveClientFinalization(_ packet: Data, count: Int, context: ChannelHandlerContext) throws {
        let request = try MockKRDPFixtures.expectSendDataRequest(packet, channelID: MockKRDPConstants.ioChannelID)
        let behavior = options.finalizationBehavior
        let waitsForFontList = [
            .waitForFontListBeforeGrant,
            .waitForClientSynchronizeBeforeServerSynchronize,
        ].contains(behavior)
        if count == 1 {
            // The client targets the Demand Active pduSource ([MS-RDPBCGR] 3.2.5.3.13.1).
            guard try MockKRDPFixtures.clientShareDataPDU(from: request.userData)?.pduType2 == 0x1F,
                  try MockKRDPFixtures.clientSynchronizeTargetUser(from: request.userData)
                  == MockKRDPConstants.serverUserID
            else {
                throw MockKRDPServerError.invalidClientPDU
            }
            if behavior == .waitForClientSynchronizeBeforeServerSynchronize {
                write(MockKRDPFixtures.serverSynchronize(), context: context)
                write(MockKRDPFixtures.serverControlCooperate(), context: context)
            }
        }
        if count == 4, try MockKRDPFixtures.clientShareDataPDU(from: request.userData)?.pduType2 != 0x27 {
            throw MockKRDPServerError.invalidClientPDU
        }
        guard count == (waitsForFontList ? 4 : 3) else {
            stage = .finalization(count)
            return
        }
        if behavior == .grantControlWithoutFontMap {
            write(MockKRDPFixtures.controlGranted(), context: context)
            for _ in 0 ..< 7 {
                write(MockKRDPFixtures.saveSessionInfo(), context: context)
            }
            stage = .finalizationFontList
            return
        }
        sendFinalizationResponses(context: context)
        stage = waitsForFontList ? .dynamicCapabilitiesResponse : .finalizationFontList
    }

    private func answerGraphicsCapsAdvertise(_ packet: Data, context: ChannelHandlerContext) throws {
        let staticPayload = try MockKRDPFixtures.staticVirtualChannelPayload(from: packet)
        if options.redirectionBehavior == .redirectFirstConnection, connectionIndex == 1 {
            write(MockKRDPFixtures.serverRedirection(), context: context)
            stage = .done
            return
        }
        let advertise = try RDPDynamicVirtualChannelDataPDU.parseIfPresent(from: staticPayload).flatMap {
            try RDPGFXCapsAdvertisePDU.parseIfPresent(from: $0.payload)
        }
        let capability = options.graphicsCapabilitySelection.selectedCapability(from: advertise)
        switch options.graphicsBehavior {
        case .sendCompressedCapsConfirmFirstFrame:
            write(MockKRDPFixtures.compressedGraphicsCapsConfirmFirst(capability: capability), context: context)
        case .sendFragmentedCompressedCapsConfirmFirstFrame:
            for packet in MockKRDPFixtures.fragmentedCompressedGraphicsCapsConfirmFirst(capability: capability) {
                write(packet, context: context)
            }
        case .stallAfterFragmentedCapsConfirm:
            write(
                MockKRDPFixtures.fragmentedCompressedGraphicsCapsConfirmFirst(capability: capability)[0],
                context: context
            )
            stage = .done
            return
        default:
            write(MockKRDPFixtures.graphicsCapsConfirm(capability: capability), context: context)
        }
        if options.waitForCompatibilityTraffic {
            write(MockKRDPFixtures.displayControlCreateRequest(), context: context)
            write(MockKRDPFixtures.displayControlCaps(), context: context)
            if options.audioEnabled {
                write(MockKRDPFixtures.audioCreateRequest(), context: context)
                write(MockKRDPFixtures.audioFormats(), context: context)
                write(MockKRDPFixtures.audioTraining(), context: context)
                write(MockKRDPFixtures.audioWave2(), context: context)
            }
            maybeReleaseCompatibilityGraphicsFrame(context: context)
            return
        }
        switch options.graphicsBehavior {
        case .sendEmptyFrameThenStall:
            write(MockKRDPFixtures.graphicsEmptyFrameUpdate(), context: context)
            stage = .graphicsFrameAcknowledge
        default:
            releaseGraphicsFrame(context: context)
        }
    }

    private func handleCredSSP(_ message: Data, context: ChannelHandlerContext) throws {
        guard let credSSPServer else {
            throw MockKRDPServerError.invalidClientPDU
        }

        if let response = try credSSPServer.handle(message) {
            write(response, context: context)
        }
        guard credSSPServer.isComplete else {
            return
        }
        if case let .credSSPWithEarlyUserAuth(_, authorizationResult) = options.securityProtocol {
            var result = Data()
            result.appendLittleEndianUInt32(authorizationResult.rawValue)
            write(result, context: context)
            stage = authorizationResult == .success ? .mcsConnectInitial : .done
        } else {
            stage = .mcsConnectInitial
        }
    }

    private var clipboardEnabled: Bool {
        options.clipboardFiles.isEmpty == false || options.remoteClipboardText != nil
    }

    private var clientRequestedProtocols: RDPSecurityProtocols {
        switch options.securityProtocol {
        case .credSSPWithEarlyUserAuth:
            [.tls, .credSSP, .credSSPWithEarlyUserAuth]
        default:
            [.tls, .credSSP]
        }
    }

    // MARK: Channel traffic at any stage

    /// Handles input and virtual channel traffic; returns false for anything
    /// that belongs to the connection sequence.
    private func handleChannelTraffic(_ request: MockMCSSendDataRequest, context: ChannelHandlerContext) throws -> Bool {
        switch request.channelID {
        case MockKRDPConstants.ioChannelID:
            guard let shareData = try MockKRDPFixtures.clientShareDataPDU(from: request.userData),
                  shareData.pduType2 == 0x1C
            else {
                return false
            }
            let events = try MockKRDPFixtures.inputEvents(from: shareData.payload)
            transcript.withLock { $0.inputEvents += events }
        case MockKRDPConstants.clipboardChannelID where clipboardEnabled:
            try handleClipboard(completeStaticChannelPDU(request), context: context)
            return true
        case MockKRDPConstants.deviceRedirectionChannelID where options.audioEnabled:
            let pdu = try RDPDeviceRedirectionPDU.parse(from: completeStaticChannelPDU(request).payload)
            transcript.withLock { $0.deviceRedirectionClientMessages.append(pdu.typeName) }
        case MockKRDPConstants.dynamicChannelID where options.audioEnabled || options.waitForCompatibilityTraffic:
            let staticPDU = try RDPStaticVirtualChannelPDU.parse(
                fromUserData: request.userData,
                maximumChunkByteCount: RDPStaticVirtualChannelPDU.maximumPayloadByteCount
            )
            guard staticPDU.isComplete, try handleDynamicChannelTraffic(staticPDU) else {
                return false
            }
        default:
            return false
        }
        maybeReleaseCompatibilityGraphicsFrame(context: context)
        return true
    }

    private func completeStaticChannelPDU(_ request: MockMCSSendDataRequest) throws -> RDPStaticVirtualChannelPDU {
        let pdu = try RDPStaticVirtualChannelPDU.parse(
            fromUserData: request.userData,
            maximumChunkByteCount: RDPStaticVirtualChannelPDU.maximumPayloadByteCount
        )
        guard pdu.isComplete else {
            throw MockKRDPServerError.invalidClientPDU
        }
        return pdu
    }

    /// Records the audio, display control and create-response traffic that
    /// `waitForCompatibilityTraffic` waits for.
    private func handleDynamicChannelTraffic(_ staticPDU: RDPStaticVirtualChannelPDU) throws -> Bool {
        let payload = staticPDU.payload
        if options.waitForCompatibilityTraffic, MockKRDPFixtures.isDynamicCreateResponse(payload, channelIDs: [
            MockKRDPConstants.displayControlDynamicChannelID,
            MockKRDPConstants.audioDynamicChannelID,
        ]) {
            transcript.withLock { $0.dynamicCreateResponseStaticFlags.append(staticPDU.flags) }
            return true
        }
        guard let dataPDU = try RDPDynamicVirtualChannelDataPDU.parseIfPresent(from: payload) else {
            return false
        }
        switch dataPDU.channelID {
        case MockKRDPConstants.audioDynamicChannelID where options.audioEnabled:
            let audioPDU = try RDPAudioPDU.parse(from: dataPDU.payload)
            transcript.withLock {
                $0.audioDynamicStaticFlags.append(staticPDU.flags)
                $0.audioClientMessages.append(.summarize(audioPDU))
            }
        case MockKRDPConstants.displayControlDynamicChannelID where options.waitForCompatibilityTraffic:
            guard let layout = try MockKRDPFixtures.displayControlLayoutSummary(from: dataPDU.payload) else {
                return false
            }
            transcript.withLock {
                $0.displayControlLayouts.append(layout)
                $0.displayControlStaticFlags.append(staticPDU.flags)
            }
        default:
            return false
        }
        return true
    }

    private func handleClipboard(_ staticPDU: RDPStaticVirtualChannelPDU, context: ChannelHandlerContext) throws {
        let clipboardPDU = try RDPClipboardPDU.parse(from: staticPDU.payload)
        transcript.withLock {
            $0.clipboardStaticFlags.append(staticPDU.flags)
            $0.clientClipboardMessages.append(.summarize(clipboardPDU))
        }
        if let response = try RDPClipboardFormatDataResponsePDU.parseIfPresent(from: clipboardPDU),
           response.ok,
           let text = try? response.decodedUnicodeText()
        {
            transcript.withLock { $0.receivedLocalClipboardText = text }
            maybeReleaseCompatibilityGraphicsFrame(context: context)
        } else if let request = try RDPClipboardFormatDataRequestPDU.parseIfPresent(from: clipboardPDU) {
            for chunk in MockKRDPFixtures.clipboardPackets(clipboardFormatDataResponse(for: request).encoded()) {
                write(chunk, context: context)
            }
        } else if let formatList = try RDPClipboardFormatListPDU.parseIfPresent(from: clipboardPDU),
                  formatList.formatIDs.contains(RDPClipboardFormatID.unicodeText)
        {
            write(MockKRDPFixtures.clipboardFormatListResponse(), context: context)
            write(MockKRDPFixtures.clipboardUnicodeTextRequest(), context: context)
        } else if let request = try RDPClipboardFileContentsRequestPDU.parseIfPresent(from: clipboardPDU) {
            write(MockKRDPFixtures.clipboardPacket(clipboardFileContentsResponse(for: request).encoded()), context: context)
            if request.flags & RDPClipboardFileContentsFlags.range != 0 {
                releaseGraphicsHandshake(context: context)
            }
        }
    }

    private func clipboardFormatDataResponse(
        for request: RDPClipboardFormatDataRequestPDU
    ) -> RDPClipboardFormatDataResponsePDU {
        if request.formatID == RDPClipboardFormatID.unicodeText,
           let remoteClipboardText = options.remoteClipboardText
        {
            return .unicodeText(remoteClipboardText)
        }
        guard request.formatID == MockKRDPConstants.remoteFileGroupDescriptorWFormatID else {
            return .failure()
        }
        return .fileGroupDescriptorW(
            RDPClipboardFileGroupDescriptorW(descriptors: options.clipboardFiles.map(\.descriptor))
        )
    }

    private func clipboardFileContentsResponse(
        for request: RDPClipboardFileContentsRequestPDU
    ) -> RDPClipboardFileContentsResponsePDU {
        guard request.fileIndex >= 0,
              Int(request.fileIndex) < options.clipboardFiles.count
        else {
            return .failure(streamID: request.streamID)
        }

        let file = options.clipboardFiles[Int(request.fileIndex)]
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

    // MARK: Server-driven steps

    private func releaseGraphicsHandshake(context: ChannelHandlerContext) {
        guard didReleaseGraphicsHandshake == false else {
            return
        }

        didReleaseGraphicsHandshake = true
        write(MockKRDPFixtures.dynamicCapabilitiesRequest(version: options.dynamicChannelVersion), context: context)
    }

    private func sendFinalizationResponses(context: ChannelHandlerContext) {
        write(MockKRDPFixtures.controlGranted(), context: context)
        write(MockKRDPFixtures.fontMap(), context: context)
        if clipboardEnabled {
            write(MockKRDPFixtures.clipboardCapabilities(), context: context)
            write(MockKRDPFixtures.clipboardMonitorReady(), context: context)
            write(
                MockKRDPFixtures.clipboardFormatList(
                    includeFiles: options.clipboardFiles.isEmpty == false,
                    includeText: options.remoteClipboardText != nil
                ),
                context: context
            )
        }
        if options.audioEnabled {
            write(MockKRDPFixtures.deviceRedirectionServerAnnounce(), context: context)
            write(MockKRDPFixtures.deviceRedirectionServerCapability(), context: context)
            write(MockKRDPFixtures.deviceRedirectionUserLoggedOn(), context: context)
        }
        switch options.finalizationBehavior {
        case .setErrorInfoLogoffThenDeactivateAfterFontMap:
            write(MockKRDPFixtures.setErrorInfo(0x0000_000C), context: context)
            write(MockKRDPFixtures.deactivateAll(), context: context)
            write(MockKRDPFixtures.disconnectProviderUltimatum(), context: context)
        case .setErrorInfoDeniedThenDeactivateAfterFontMap:
            write(MockKRDPFixtures.setErrorInfo(0x0000_0007), context: context)
            write(MockKRDPFixtures.deactivateAll(), context: context)
        case .userRequestedDisconnectAfterFontMap:
            write(MockKRDPFixtures.disconnectProviderUltimatum(), context: context)
        case .deactivateThenUserRequestedDisconnectAfterFontMap:
            write(MockKRDPFixtures.deactivateAll(), context: context)
            write(MockKRDPFixtures.disconnectProviderUltimatum(), context: context)
        case .deactivateAfterFontMap:
            write(MockKRDPFixtures.deactivateAll(), context: context)
        case .deactivateThenReactivateAfterFontMap where !hasReactivated:
            // Deactivation-reactivation ([MS-RDPBCGR] 1.3.1.3): the client
            // answers the new Demand Active and finalizes again.
            hasReactivated = true
            isAwaitingReactivation = true
            write(MockKRDPFixtures.deactivateAll(), context: context)
            write(MockKRDPFixtures.demandActive(), context: context)
        default:
            if options.clipboardFiles.isEmpty || options.remoteClipboardText != nil || options.waitForCompatibilityTraffic {
                releaseGraphicsHandshake(context: context)
            }
        }
    }

    private func maybeReleaseCompatibilityGraphicsFrame(context: ChannelHandlerContext) {
        guard options.waitForCompatibilityTraffic else {
            return
        }

        let transcript = transcript.value
        let audioMessages = transcript.audioClientMessages.map(\.typeName)
        guard transcript.inputEvents.isEmpty == false,
              transcript.clientClipboardMessages.map(\.typeName).contains("clipboard-format-data-response"),
              transcript.receivedLocalClipboardText != nil,
              transcript.deviceRedirectionClientMessages.contains("rdpdr-client-id-confirm"),
              transcript.deviceRedirectionClientMessages.contains("rdpdr-client-name"),
              transcript.deviceRedirectionClientMessages.contains("rdpdr-client-capability"),
              transcript.deviceRedirectionClientMessages.contains("rdpdr-device-list-announce"),
              transcript.displayControlLayouts.isEmpty == false,
              ["audio-formats", "audio-quality-mode", "audio-training", "audio-wave-confirm"]
              .allSatisfy(audioMessages.contains)
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
        for packet in MockKRDPFixtures.graphicsFrameUpdatePackets(behavior: options.graphicsBehavior) {
            write(packet, context: context)
        }
        stage = .graphicsFrameAcknowledge
    }

    private func write(_ packet: Data, context: ChannelHandlerContext) {
        var buffer = context.channel.allocator.buffer(capacity: packet.count)
        buffer.writeBytes(packet)
        context.writeAndFlush(wrapOutboundOut(buffer), promise: nil)
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

    static func x224ConnectionFailure(code: UInt32) -> Data {
        var negotiationFailure = Data([
            0x03, 0x00, 0x08, 0x00,
        ])
        negotiationFailure.appendLittleEndianUInt32(code)
        return Data([
            0x03, 0x00, 0x00, 0x13,
            0x0E, 0xD0, 0x00, 0x00,
            0x00, 0x00, 0x00,
        ]) + negotiationFailure
    }

    static func mcsConnectResponse(
        clipboardEnabled: Bool = false,
        audioEnabled: Bool = false,
        clientRequestedProtocols: RDPSecurityProtocols = [.tls, .credSSP]
    ) -> Data {
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
        var serverCoreData = Data([
            0x01, 0x0C,
            0x0C,
            0x00,
            0x05, 0x00, 0x08, 0x00,
        ])
        serverCoreData.appendLittleEndianUInt32(clientRequestedProtocols.rawValue)
        let serverSecurityData = Data([
            0x02, 0x0C, 0x0C, 0x00,
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
        ])
        let serverBlocks = serverCoreData + serverNetworkData + serverSecurityData + serverMessageChannelData
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

    static func autoDetectRequest(requestType: UInt16 = 0x1001) -> Data {
        var payload = Data()
        payload.appendLittleEndianUInt16(0x1000)
        payload.appendLittleEndianUInt16(0)
        payload.appendUInt8(0x06)
        payload.appendUInt8(0x00)
        payload.appendLittleEndianUInt16(1)
        payload.appendLittleEndianUInt16(requestType)
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
              try cursor.readLittleEndianUInt32() > 0,
              try cursor.readLittleEndianUInt32() == 24,
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

        let redirectionLength = UInt16(12 + fields.count)
        let totalLength = UInt16(8 + Int(redirectionLength))
        var payload = Data()
        payload.appendLittleEndianUInt16(totalLength)
        payload.appendLittleEndianUInt16(0x000A)
        payload.appendLittleEndianUInt16(0)
        payload.appendLittleEndianUInt16(0)
        payload.appendLittleEndianUInt16(0x0400)
        payload.appendLittleEndianUInt16(redirectionLength)
        payload.appendLittleEndianUInt32(4)
        payload.appendLittleEndianUInt32(RDPServerRedirectionPDU.Flags.loadBalanceInfo.rawValue)
        payload.append(fields)
        return mcsSendDataIndication(
            channelID: MockKRDPConstants.ioChannelID,
            userData: payload
        )
    }

    static func licenseValidClient() -> Data {
        licenseError(code: 0x0000_0007, stateTransition: 0x0000_0002)
    }

    static func licenseError(code: UInt32, stateTransition: UInt32) -> Data {
        var payload = Data()
        payload.appendLittleEndianUInt16(0x0080)
        payload.appendLittleEndianUInt16(0)
        payload.appendUInt8(0xFF)
        payload.appendUInt8(0x03)
        payload.appendLittleEndianUInt16(16)
        payload.appendLittleEndianUInt32(code)
        payload.appendLittleEndianUInt32(stateTransition)
        payload.appendLittleEndianUInt16(0x0004)
        payload.appendLittleEndianUInt16(0)
        return mcsSendDataIndication(
            channelID: MockKRDPConstants.ioChannelID,
            userData: payload
        )
    }

    static func serverLicenseRequest(certificatePayload: Data = proprietaryServerCertificate()) -> Data {
        var productInfo = Data()
        productInfo.appendLittleEndianUInt32(0x0006_0001)
        productInfo.appendLicenseUnicodeString("Microsoft Corporation")
        productInfo.appendLicenseUnicodeString("A02")

        var keyExchangeAlgorithms = Data()
        keyExchangeAlgorithms.appendLittleEndianUInt32(0x0000_0001)

        var body = Data((0 ..< 32).map(UInt8.init))
        body.append(productInfo)
        body.appendLicenseBlob(type: 0x000D, payload: keyExchangeAlgorithms)
        body.appendLicenseBlob(type: 0x0003, payload: certificatePayload)
        body.appendLittleEndianUInt32(1)
        body.appendLicenseBlob(type: 0x000E, payload: Data("localhost\u{0}".utf8))

        var payload = Data()
        payload.appendLittleEndianUInt16(0x0080)
        payload.appendLittleEndianUInt16(0)
        payload.appendUInt8(0x01)
        payload.appendUInt8(0x03)
        payload.appendLittleEndianUInt16(UInt16(body.count + 4))
        payload.append(body)
        return mcsSendDataIndication(
            channelID: MockKRDPConstants.ioChannelID,
            userData: payload
        )
    }

    static func expectClientNewLicenseRequest(_ userData: Data) throws {
        var cursor = ByteCursor(userData)
        guard try cursor.readLittleEndianUInt16() == 0x0080,
              try cursor.readLittleEndianUInt16() == 0,
              try cursor.readUInt8() == 0x13,
              try cursor.readUInt8() == 0x03 else {
            throw MockKRDPServerError.invalidClientPDU
        }
        let messageSize = try Int(cursor.readLittleEndianUInt16())
        guard messageSize == cursor.remaining + 4,
              try cursor.readLittleEndianUInt32() == 0x0000_0001,
              try cursor.readLittleEndianUInt32() == 0x0401_0000,
              (try cursor.readData(count: 32)).count == 32 else {
            throw MockKRDPServerError.invalidClientPDU
        }
        let encryptedPremaster = try cursor.readLicenseBlob()
        let username = try cursor.readLicenseBlob()
        let machineName = try cursor.readLicenseBlob()
        guard encryptedPremaster.type == 0x0002,
              encryptedPremaster.data.count > 8,
              username.type == 0x000F,
              username.data.last == 0,
              machineName.type == 0x0010,
              machineName.data.last == 0,
              cursor.remaining == 0 else {
            throw MockKRDPServerError.invalidClientPDU
        }
    }

    static func expectClientLicenseInformation(_ userData: Data) throws {
        var cursor = ByteCursor(userData)
        guard try cursor.readLittleEndianUInt16() == 0x0080,
              try cursor.readLittleEndianUInt16() == 0,
              try cursor.readUInt8() == 0x12,
              try cursor.readUInt8() == 0x03 else {
            throw MockKRDPServerError.invalidClientPDU
        }
        let messageSize = try Int(cursor.readLittleEndianUInt16())
        guard messageSize == cursor.remaining + 4,
              try cursor.readLittleEndianUInt32() == 0x0000_0001,
              try cursor.readLittleEndianUInt32() == 0x0401_0000,
              (try cursor.readData(count: 32)).count == 32 else {
            throw MockKRDPServerError.invalidClientPDU
        }
        let encryptedPremaster = try cursor.readLicenseBlob()
        let licenseInfo = try cursor.readLicenseBlob()
        let encryptedHardwareID = try cursor.readLicenseBlob()
        let mac = try cursor.readData(count: 16)
        guard encryptedPremaster.type == 0x0002,
              encryptedPremaster.data.count > 8,
              licenseInfo.type == 0x0001,
              licenseInfo.data == Data([0x30, 0x82, 0x01, 0x02]),
              encryptedHardwareID.type == 0x0001,
              !encryptedHardwareID.data.isEmpty,
              mac.count == 16,
              cursor.remaining == 0 else {
            throw MockKRDPServerError.invalidClientPDU
        }
    }

    static func demandActive() -> Data {
        let sourceDescriptor = Data("RDPKitMock".utf8)
        var capabilities = Data()
        capabilities.appendLittleEndianUInt16(2)
        capabilities.appendLittleEndianUInt16(0)
        capabilities.appendLittleEndianUInt16(0x0001)
        capabilities.appendLittleEndianUInt16(4)
        capabilities.append(inputCapabilitySet())

        var data = Data()
        data.appendLittleEndianUInt16(UInt16(18 + sourceDescriptor.count + capabilities.count))
        data.appendLittleEndianUInt16(0x0011)
        data.appendLittleEndianUInt16(MockKRDPConstants.serverUserID)
        data.appendLittleEndianUInt32(MockKRDPConstants.shareID)
        data.appendLittleEndianUInt16(UInt16(sourceDescriptor.count))
        data.appendLittleEndianUInt16(UInt16(capabilities.count))
        data.append(sourceDescriptor)
        data.append(capabilities)
        data.appendLittleEndianUInt32(0)
        return mcsSendDataIndication(
            channelID: MockKRDPConstants.ioChannelID,
            userData: data
        )
    }

    private static func inputCapabilitySet() -> Data {
        var data = Data()
        data.appendLittleEndianUInt16(0x000D)
        data.appendLittleEndianUInt16(88)
        data.appendLittleEndianUInt16(0x0115)
        data.appendLittleEndianUInt16(0)
        data.append(Data(repeating: 0, count: 80))
        return data
    }

    static func serverSynchronize() -> Data {
        var payload = Data()
        payload.appendLittleEndianUInt16(0x0001)
        payload.appendLittleEndianUInt16(MockKRDPConstants.serverUserID)
        return shareDataPacket(pduType2: 0x1F, payload: payload)
    }

    static func monitorLayout() -> Data {
        var payload = Data()
        payload.appendLittleEndianUInt32(1)
        payload.appendLittleEndianUInt32(0)
        payload.appendLittleEndianUInt32(0)
        payload.appendLittleEndianUInt32(1279)
        payload.appendLittleEndianUInt32(719)
        payload.appendLittleEndianUInt32(0x0000_0001)
        return shareDataPacket(pduType2: 0x37, payload: payload, pduSource: 0)
    }

    static func saveSessionInfo() -> Data {
        var payload = Data()
        payload.appendLittleEndianUInt32(0x0000_0002)
        payload.append(Data(repeating: 0, count: 576))
        return shareDataPacket(pduType2: 0x26, payload: payload)
    }

    static func controlGranted() -> Data {
        var payload = Data()
        payload.appendLittleEndianUInt16(0x0002)
        payload.appendLittleEndianUInt16(MockKRDPConstants.serverUserID)
        payload.appendLittleEndianUInt32(UInt32(MockKRDPConstants.userChannelID))
        return shareDataPacket(pduType2: 0x14, payload: payload)
    }

    static func serverControlCooperate() -> Data {
        var payload = Data()
        payload.appendLittleEndianUInt16(0x0004)
        payload.appendLittleEndianUInt16(0)
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

    static func setErrorInfo(_ errorInfo: UInt32) -> Data {
        var payload = Data()
        payload.appendLittleEndianUInt32(errorInfo)
        return shareDataPacket(pduType2: 0x2F, payload: payload, pduSource: 0)
    }

    static func pointerColorUpdate() -> Data {
        var payload = Data()
        payload.appendLittleEndianUInt16(0x0006)
        payload.appendLittleEndianUInt16(0)
        payload.appendLittleEndianUInt16(2)
        payload.appendLittleEndianUInt16(1)
        payload.appendLittleEndianUInt16(3)
        payload.appendLittleEndianUInt16(1)
        payload.appendLittleEndianUInt16(1)
        payload.appendLittleEndianUInt16(2)
        payload.appendLittleEndianUInt16(4)
        payload.append(Data([0xaa, 0xbb, 0xcc, 0x00]))
        payload.append(Data([0xff, 0x00]))
        return shareDataPacket(pduType2: 0x1B, payload: payload)
    }

    static func cachedPointerUpdate() -> Data {
        var payload = Data()
        payload.appendLittleEndianUInt16(0x0007)
        payload.appendLittleEndianUInt16(0)
        payload.appendLittleEndianUInt16(2)
        return shareDataPacket(pduType2: 0x1B, payload: payload)
    }

    static func deactivateAll() -> Data {
        var userData = Data()
        userData.appendLittleEndianUInt16(13)
        userData.appendLittleEndianUInt16(0x0016)
        userData.appendLittleEndianUInt16(MockKRDPConstants.serverUserID)
        userData.appendLittleEndianUInt32(MockKRDPConstants.shareID)
        userData.appendLittleEndianUInt16(1)
        userData.appendUInt8(0)
        return mcsSendDataIndication(
            channelID: MockKRDPConstants.ioChannelID,
            userData: userData
        )
    }

    static func disconnectProviderUltimatum(reason: UInt8 = 3) -> Data {
        Data([
            0x03, 0x00, 0x00, 0x09,
            0x02, 0xF0, 0x80,
            0x20 | ((reason >> 1) & 0x01),
            (reason & 0x01) << 7,
        ])
    }

    static func dynamicCapabilitiesRequest(version: UInt16 = 2) -> Data {
        precondition((1 ... 3).contains(version))
        var payload = Data()
        payload.appendUInt8(RDPDynamicVirtualChannelHeader(command: .capabilities).encodedByte)
        payload.appendUInt8(0)
        payload.appendLittleEndianUInt16(version)
        if version >= 2 {
            payload.append(contentsOf: [0x33, 0x33, 0x11, 0x11, 0x3D, 0x0A, 0xA7, 0x04])
        }
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

    /// Splits a payload into the 1,600-byte chunks the client advertises
    /// (VCChunkSize, [MS-RDPBCGR] 2.2.7.1.10, 3.1.5.2.1).
    static func clipboardPackets(_ payload: Data) -> [Data] {
        let chunkSize = RDPStaticVirtualChannelPDU.defaultChunkByteCount
        return fragmentedStaticVirtualChannelPackets(
            payload,
            chunkSizes: Array(repeating: chunkSize, count: payload.count / chunkSize + 1),
            channelID: MockKRDPConstants.clipboardChannelID
        )
    }

    static func graphicsCreateRequest() -> Data {
        staticVirtualChannelPacket(graphicsCreateRequestPayload())
    }

    static func fragmentedGraphicsCreateRequest() -> [Data] {
        fragmentedStaticVirtualChannelPackets(graphicsCreateRequestPayload(), chunkSizes: [7, 11])
    }

    private static func graphicsCreateRequestPayload() -> Data {
        var payload = Data()
        payload.appendUInt8(RDPDynamicVirtualChannelHeader(command: .create).encodedByte)
        payload.appendUInt8(UInt8(MockKRDPConstants.graphicsDynamicChannelID))
        payload.append(Data(RDPGFXChannel.name.utf8))
        payload.appendUInt8(0)
        return payload
    }

    static func graphicsCapsConfirm(
        capability: RDPGFXCapabilitySet = MockKRDPGraphicsCapabilitySelection.fixedVersion81
            .selectedCapability(from: nil)
    ) -> Data {
        let capability = capability.encoded
        let confirm = graphicsMessage(commandID: RDPGFXCommandID.capsConfirm, payload: capability)
        return graphicsDynamicPacket(segmentedGraphicsData(confirm))
    }

    static func compressedGraphicsCapsConfirmFirst(
        capability: RDPGFXCapabilitySet = MockKRDPGraphicsCapabilitySelection.fixedVersion81
            .selectedCapability(from: nil)
    ) -> Data {
        let capability = capability.encoded
        let confirm = graphicsMessage(commandID: RDPGFXCommandID.capsConfirm, payload: capability)
        return compressedGraphicsDynamicFirstPacket(segmentedGraphicsData(confirm))
    }

    static func fragmentedCompressedGraphicsCapsConfirmFirst(
        capability: RDPGFXCapabilitySet = MockKRDPGraphicsCapabilitySelection.fixedVersion81
            .selectedCapability(from: nil)
    ) -> [Data] {
        let capability = capability.encoded
        let confirm = segmentedGraphicsData(graphicsMessage(commandID: RDPGFXCommandID.capsConfirm, payload: capability))
        let firstCount = min(8, confirm.count - 1)
        guard firstCount > 0 else {
            return [compressedGraphicsDynamicFirstPacket(confirm)]
        }
        return [
            compressedGraphicsDynamicFirstPacket(
                Data(confirm.prefix(firstCount)),
                totalLength: UInt32(confirm.count)
            ),
            graphicsDynamicPacket(Data(confirm.dropFirst(firstCount))),
        ]
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
                version: 8,
                formats: [.pcmStereo48k16Bit]
            ).encoded(),
            channelID: MockKRDPConstants.audioDynamicChannelID
        )
    }

    static func audioTraining() -> Data {
        var payload = Data()
        payload.appendLittleEndianUInt16(0x1234)
        payload.appendLittleEndianUInt16(12)
        payload.append(Data([0xAA, 0xBB, 0xCC, 0xDD]))
        return dynamicPacket(
            RDPAudioPDU(messageType: RDPAudioMessageType.training, payload: payload).encoded(),
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
        case .sendFirstFrame,
             .sendCompressedCapsConfirmFirstFrame,
             .sendFragmentedCompressedCapsConfirmFirstFrame,
             .closeAfterFirstFrame,
             .setErrorInfoThenCloseAfterFirstFrame:
            [graphicsDynamicPacket(segmentedGraphicsData(avc420FrameMessages()))]
        case .sendPointerUpdatesBeforeFirstFrame:
            [pointerColorUpdate(), cachedPointerUpdate(), graphicsDynamicPacket(segmentedGraphicsData(avc420FrameMessages()))]
        case .setErrorInfoLogoffBeforeFrame:
            [
                setErrorInfo(0x0000_000C),
                deactivateAll(),
                disconnectProviderUltimatum(),
            ]
        case .sendFragmentedBitmapCompositionFrame:
            fragmentedGraphicsDynamicPackets(zgfxMultipart(bitmapCompositionFrameMessages()))
        case .sendClearCodecBandsFrame:
            [graphicsDynamicPacket(segmentedGraphicsData(clearCodecBandsFrameMessages()))]
        case .sendCAVideoRemoteFXFrame:
            [graphicsDynamicPacket(segmentedGraphicsData(cavideoRemoteFXFrameMessages()))]
        case .sendCAProgressiveFrame:
            [graphicsDynamicPacket(segmentedGraphicsData(caprogressiveFrameMessages()))]
        case .sendVideoBeforeBitmapCompositionFrame:
            [graphicsDynamicPacket(segmentedGraphicsData(videoBeforeBitmapCompositionFrameMessages()))]
        case .sendMultipleVideoUpdatesInFrame:
            [graphicsDynamicPacket(segmentedGraphicsData(multipleVideoUpdatesInFrameMessages()))]
        case .sendTwoFramesInOnePayload:
            [graphicsDynamicPacket(segmentedGraphicsData(
                avc420FrameMessages()
                    + startFrameMessage(frameID: 2)
                    + wireToSurfaceMessage()
                    + endFrameMessage(frameID: 2)
            ))]
        case .sendMultipleBitmapSurfacesInFrame:
            [graphicsDynamicPacket(segmentedGraphicsData(multipleBitmapSurfacesInFrameMessages()))]
        case .sendMalformedAVCFrame:
            [graphicsDynamicPacket(segmentedGraphicsData(malformedAVCFrameMessages()))]
        case .sendInvalidGraphicsPDU:
            [graphicsDynamicPacket(Data([0x12, 0x00, 0x00]))]
        case .sendCompressedCAVideoRemoteFXFrame:
            [compressedGraphicsDynamicPacket(segmentedGraphicsData(cavideoRemoteFXFrameMessages()))]
        case .sendUnsupportedCompressedDynamicData:
            [invalidCompressedGraphicsDynamicPacket(Data([0x12, 0x00]))]
        case .sendCompressedDataLargerThanOnePDU:
            // RDP8-lite segment that expands to 8,192 x 0x41 ([MS-RDPEDYC] 2.2.3.4).
            [invalidCompressedGraphicsDynamicPacket(Data([0xE0, 0x26, 0x20, 0xC4, 0x3F, 0xFD, 0xFF, 0xE0, 0x05]))]
        case .sendSoftSyncBeforeFrame:
            [softSyncRequest(), graphicsDynamicPacket(segmentedGraphicsData(avc420FrameMessages()))]
        case .sendUnknownCloseBeforeFrame:
            [
                dynamicCloseRequest(channelID: 0x00FE_ED00),
                graphicsDynamicPacket(segmentedGraphicsData(avc420FrameMessages())),
            ]
        case .sendEmptyFrameThenStall:
            [graphicsEmptyFrameUpdate()]
        case .stallAfterFragmentedCapsConfirm:
            []
        }
    }

    static func avc420FrameMessages() -> Data {
        let messages = createSurfaceMessage()
            + mapSurfaceToOutputMessage(surfaceID: 1, x: 0, y: 0)
            + startFrameMessage()
            + wireToSurfaceMessage()
            + endFrameMessage()
        return messages
    }

    static func malformedAVCFrameMessages() -> Data {
        createSurfaceMessage()
            + startFrameMessage(frameID: 13)
            + wireToSurfaceMessage(bitmapData: Data([0x00]))
            + endFrameMessage(frameID: 13)
    }

    static func multipleVideoUpdatesInFrameMessages() -> Data {
        createSurfaceMessage(surfaceID: 1)
            + createSurfaceMessage(surfaceID: 2)
            + mapSurfaceToOutputMessage(surfaceID: 1, x: 0, y: 0)
            + mapSurfaceToOutputMessage(surfaceID: 2, x: 64, y: 0)
            + startFrameMessage(frameID: 11)
            + wireToSurfaceMessage(surfaceID: 1)
            + wireToSurfaceMessage(surfaceID: 2)
            + endFrameMessage(frameID: 11)
    }

    static func multipleBitmapSurfacesInFrameMessages() -> Data {
        createSurfaceMessage(surfaceID: 1, width: 2, height: 2)
            + createSurfaceMessage(surfaceID: 2, width: 2, height: 2)
            + mapSurfaceToOutputMessage(surfaceID: 1, x: 0, y: 0)
            + mapSurfaceToOutputMessage(surfaceID: 2, x: 2, y: 0)
            + startFrameMessage(frameID: 12)
            + solidFillMessage(
                surfaceID: 1,
                color: [0x01, 0x02, 0x03, 0xFF],
                rects: [RDPGFXRect16(left: 0, top: 0, right: 2, bottom: 2)]
            )
            + solidFillMessage(
                surfaceID: 2,
                color: [0x04, 0x05, 0x06, 0xFF],
                rects: [RDPGFXRect16(left: 0, top: 0, right: 2, bottom: 2)]
            )
            + endFrameMessage(frameID: 12)
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

    static func caprogressiveFrameMessages() -> Data {
        createSurfaceMessage(width: 64, height: 64)
            + mapSurfaceToOutputMessage(surfaceID: 1, x: 0, y: 0)
            + startFrameMessage(frameID: 10)
            + wireToSurface2Message(
                surfaceID: 1,
                codecID: RDPGFXCodecID.caProgressive,
                codecContextID: 0,
                pixelFormat: 0x20,
                bitmapData: caprogressiveRemoteFXGrayTileStream(tailData: Data([0xDE, 0xAD, 0xBE, 0xEF]))
            )
            + endFrameMessage(frameID: 10)
    }

    static func videoBeforeBitmapCompositionFrameMessages() -> Data {
        createSurfaceMessage()
            + mapSurfaceToOutputMessage(surfaceID: 1, x: 0, y: 0)
            + startFrameMessage(frameID: 9)
            + wireToSurfaceMessage()
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
            + wireToSurfaceMessage()
            + endFrameMessage()
        return graphicsDynamicPacket(segmentedGraphicsData(messages))
    }

    @discardableResult
    static func expectSendDataRequest(_ packet: Data, channelID expectedChannelID: UInt16) throws -> MockMCSSendDataRequest {
        let request = try mcsSendDataRequest(fromTPKT: packet)
        guard request.initiator == MockKRDPConstants.userChannelID,
              request.channelID == expectedChannelID
        else {
            throw MockKRDPServerError.invalidClientPDU
        }
        return request
    }

    static func staticVirtualChannelPayload(from packet: Data) throws -> Data {
        let request = try mcsSendDataRequest(fromTPKT: packet)
        guard request.initiator == MockKRDPConstants.userChannelID,
              request.channelID == MockKRDPConstants.dynamicChannelID
        else {
            throw MockKRDPServerError.invalidClientPDU
        }
        return try RDPStaticVirtualChannelPDU.parse(fromUserData: request.userData, maximumChunkByteCount: RDPStaticVirtualChannelPDU.maximumPayloadByteCount).payload
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

    static func clientConfirmActiveCapabilityTypes(from userData: Data) throws -> [UInt16] {
        var cursor = ByteCursor(userData)
        let totalLength = try Int(cursor.readLittleEndianUInt16())
        let pduType = try cursor.readLittleEndianUInt16()
        _ = try cursor.readLittleEndianUInt16()
        guard totalLength == userData.count,
              pduType == 0x0013
        else {
            throw MockKRDPServerError.invalidClientPDU
        }

        _ = try cursor.readLittleEndianUInt32()
        _ = try cursor.readLittleEndianUInt16()
        let sourceDescriptorLength = try Int(cursor.readLittleEndianUInt16())
        let combinedCapabilitiesLength = try Int(cursor.readLittleEndianUInt16())
        guard sourceDescriptorLength <= cursor.remaining,
              combinedCapabilitiesLength >= 4,
              combinedCapabilitiesLength <= cursor.remaining - sourceDescriptorLength
        else {
            throw MockKRDPServerError.invalidClientPDU
        }

        _ = try cursor.readData(count: sourceDescriptorLength)
        var capabilityCursor = try ByteCursor(cursor.readData(count: combinedCapabilitiesLength))
        let capabilityCount = try Int(capabilityCursor.readLittleEndianUInt16())
        _ = try capabilityCursor.readLittleEndianUInt16()

        var capabilityTypes: [UInt16] = []
        capabilityTypes.reserveCapacity(capabilityCount)
        for _ in 0 ..< capabilityCount {
            guard capabilityCursor.remaining >= 4 else {
                throw MockKRDPServerError.invalidClientPDU
            }
            let type = try capabilityCursor.readLittleEndianUInt16()
            let length = try Int(capabilityCursor.readLittleEndianUInt16())
            guard length >= 4,
                  length - 4 <= capabilityCursor.remaining
            else {
                throw MockKRDPServerError.invalidClientPDU
            }
            _ = try capabilityCursor.readData(count: length - 4)
            capabilityTypes.append(type)
        }
        guard capabilityCursor.remaining == 0 else {
            throw MockKRDPServerError.invalidClientPDU
        }
        return capabilityTypes
    }

    static func clientSynchronizeTargetUser(from userData: Data) throws -> UInt16? {
        guard let shareData = try clientShareDataPDU(from: userData),
              shareData.pduType2 == 0x1F,
              shareData.payload.count == 4
        else {
            return nil
        }
        var cursor = ByteCursor(shareData.payload)
        let messageType = try cursor.readLittleEndianUInt16()
        guard messageType == 0x0001 else {
            throw MockKRDPServerError.invalidClientPDU
        }
        return try cursor.readLittleEndianUInt16()
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
            case 0x0000:
                _ = try cursor.readLittleEndianUInt16()
                let toggleFlags = try cursor.readLittleEndianUInt32()
                events.append(.synchronize(toggleFlags: RDPToggleKeyFlags(rawValue: toggleFlags)))
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
        guard let layout = try RDPDisplayControlMonitorLayoutPDU.parseIfPresent(from: payload) else {
            return nil
        }
        let primary = layout.monitors.first { $0.flags & RDPDisplayControlMonitorFlags.primary != 0 }
            ?? layout.monitors[0]
        return MockDisplayControlLayoutSummary(
            monitorCount: UInt32(layout.monitors.count),
            primaryWidth: primary.width,
            primaryHeight: primary.height,
            primaryDesktopScaleFactor: primary.desktopScaleFactor,
            primaryDeviceScaleFactor: primary.deviceScaleFactor
        )
    }

    static func dynamicCreateResponse(_ payload: Data) -> (channelID: UInt32, status: Int32)? {
        var cursor = ByteCursor(payload)
        guard let header = try? RDPDynamicVirtualChannelHeader(byte: cursor.readUInt8()),
              header.command == .create,
              let channelID = try? cursor.readDynamicVirtualChannelID(lengthCode: header.channelIDLength),
              let status = try? cursor.readLittleEndianUInt32(),
              cursor.remaining == 0
        else {
            return nil
        }
        return (channelID, Int32(bitPattern: status))
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
        let encodedRotation = Int(flags & RDPPointerFlags.wheelRotationMask)
        return flags & RDPPointerFlags.wheelNegative == 0
            ? encodedRotation
            : encodedRotation - 0x0200
    }

    private static func shareDataPacket(
        pduType2: UInt8,
        payload: Data,
        pduSource: UInt16 = MockKRDPConstants.serverUserID
    ) -> Data {
        let userData = rdpShareDataPDUData(
            shareID: MockKRDPConstants.shareID,
            pduSource: pduSource,
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

    private static func fragmentedStaticVirtualChannelPackets(
        _ payload: Data,
        chunkSizes: [Int],
        channelID: UInt16 = MockKRDPConstants.dynamicChannelID
    ) -> [Data] {
        var packets: [Data] = []
        var offset = 0
        var chunkIndex = 0
        while offset < payload.count {
            let requestedSize = chunkIndex < chunkSizes.count ? chunkSizes[chunkIndex] : payload.count - offset
            let chunkSize = min(requestedSize, payload.count - offset)
            var flags = RDPStaticVirtualChannelFlags.showProtocol
            if offset == 0 {
                flags |= RDPStaticVirtualChannelFlags.first
            }
            if offset + chunkSize == payload.count {
                flags |= RDPStaticVirtualChannelFlags.last
            }
            var userData = Data()
            userData.appendLittleEndianUInt32(UInt32(payload.count))
            userData.appendLittleEndianUInt32(flags)
            userData.append(payload.subdata(in: offset ..< offset + chunkSize))
            packets.append(mcsSendDataIndication(channelID: channelID, userData: userData))
            offset += chunkSize
            chunkIndex += 1
        }
        return packets
    }

    /// Wraps graphics messages in an uncompressed single RDP_SEGMENTED_DATA segment.
    private static func segmentedGraphicsData(_ messages: Data) -> Data {
        Data([0xE0, 0x04]) + messages
    }

    private static func graphicsDynamicPacket(_ payload: Data) -> Data {
        dynamicPacket(payload, channelID: MockKRDPConstants.graphicsDynamicChannelID)
    }

    private static func compressedGraphicsDynamicPacket(_ payload: Data) -> Data {
        invalidCompressedGraphicsDynamicPacket(rdp8UncompressedBulkSegment(payload))
    }

    private static func compressedGraphicsDynamicFirstPacket(_ payload: Data, totalLength: UInt32? = nil) -> Data {
        let totalLength = totalLength ?? UInt32(payload.count)
        precondition(totalLength <= UInt16.max)
        var dynamicPayload = Data()
        dynamicPayload.appendUInt8(RDPDynamicVirtualChannelHeader(
            channelIDLength: dynamicVirtualChannelIDLengthCode(MockKRDPConstants.graphicsDynamicChannelID),
            sp: 1,
            command: .dataFirstCompressed
        ).encodedByte)
        dynamicPayload.appendDynamicVirtualChannelID(MockKRDPConstants.graphicsDynamicChannelID)
        dynamicPayload.appendLittleEndianUInt16(UInt16(totalLength))
        dynamicPayload.append(rdp8UncompressedBulkSegment(payload))
        return staticVirtualChannelPacket(dynamicPayload)
    }

    private static func invalidCompressedGraphicsDynamicPacket(_ payload: Data) -> Data {
        var dynamicPayload = Data()
        dynamicPayload.appendUInt8(RDPDynamicVirtualChannelHeader(
            channelIDLength: dynamicVirtualChannelIDLengthCode(MockKRDPConstants.graphicsDynamicChannelID),
            command: .dataCompressed
        ).encodedByte)
        dynamicPayload.appendDynamicVirtualChannelID(MockKRDPConstants.graphicsDynamicChannelID)
        dynamicPayload.append(payload)
        return staticVirtualChannelPacket(dynamicPayload)
    }

    private static func rdp8UncompressedBulkSegment(_ payload: Data) -> Data {
        var data = Data()
        data.appendUInt8(0xE0)
        data.appendUInt8(0x06)
        data.append(payload)
        return data
    }

    private static func softSyncRequest() -> Data {
        var payload = Data()
        payload.appendUInt8(RDPDynamicVirtualChannelHeader(command: .softSyncRequest).encodedByte)
        payload.appendUInt8(0)
        payload.appendLittleEndianUInt32(8)
        payload.appendLittleEndianUInt16(0x0001)
        payload.appendLittleEndianUInt16(0)
        return staticVirtualChannelPacket(payload)
    }

    private static func fragmentedGraphicsDynamicPackets(_ payload: Data) -> [Data] {
        let firstPayloadCount = Int(dynamicVirtualChannelDataFirstPayloadLength(
            channelIDLengthCode: dynamicVirtualChannelIDLengthCode(MockKRDPConstants.graphicsDynamicChannelID),
            lengthCode: 1,
            totalLength: UInt32(payload.count)
        ))
        guard firstPayloadCount < payload.count else {
            return [graphicsDynamicPacket(payload)]
        }
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

    static func dynamicCloseRequest(channelID: UInt32) -> Data {
        staticVirtualChannelPacket(RDPDynamicVirtualChannelClosePDU(channelID: channelID).encoded())
    }

    static func dynamicCreateRequest(channelID: UInt32, channelName: String) -> Data {
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

    private static func wireToSurface2Message(
        surfaceID: UInt16,
        codecID: UInt16,
        codecContextID: UInt32,
        pixelFormat: UInt8,
        bitmapData: Data
    ) -> Data {
        var payload = Data()
        payload.appendLittleEndianUInt16(surfaceID)
        payload.appendLittleEndianUInt16(codecID)
        payload.appendLittleEndianUInt32(codecContextID)
        payload.appendUInt8(pixelFormat)
        payload.appendLittleEndianUInt32(UInt32(bitmapData.count))
        payload.append(bitmapData)
        return graphicsMessage(commandID: RDPGFXCommandID.wireToSurface2, payload: payload)
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
            payload.appendLittleEndianUInt16(UInt16(bitPattern: point.x))
            payload.appendLittleEndianUInt16(UInt16(bitPattern: point.y))
        }
        return graphicsMessage(commandID: RDPGFXCommandID.cacheToSurface, payload: payload)
    }

    private static func endFrameMessage(frameID: UInt32 = MockKRDPConstants.frameID) -> Data {
        var payload = Data()
        payload.appendLittleEndianUInt32(frameID)
        return graphicsMessage(commandID: RDPGFXCommandID.endFrame, payload: payload)
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
}

private extension Data {
    mutating func appendLicenseUnicodeString(_ value: String) {
        var bytes = Data()
        for codeUnit in value.utf16 {
            bytes.appendLittleEndianUInt16(codeUnit)
        }
        bytes.appendLittleEndianUInt16(0)
        appendLittleEndianUInt32(UInt32(bytes.count))
        append(bytes)
    }

    mutating func appendLicenseBlob(type: UInt16, payload: Data) {
        appendLittleEndianUInt16(type)
        appendLittleEndianUInt16(UInt16(payload.count))
        append(payload)
    }

    func containsNTLMChannelBindings(_ expectedValue: Data) -> Bool {
        var offset = 0
        while offset + 4 <= count {
            let avID = UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
            let length = Int(UInt16(self[offset + 2]) | UInt16(self[offset + 3]) << 8)
            offset += 4
            guard length <= count - offset else {
                return false
            }
            if avID == 0 {
                return false
            }
            if avID == 10,
               length == expectedValue.count,
               self[offset ..< offset + length].elementsEqual(expectedValue)
            {
                return true
            }
            offset += length
        }
        return false
    }
}

private extension ByteCursor {
    mutating func readLicenseBlob() throws -> (type: UInt16, data: Data) {
        let type = try readLittleEndianUInt16()
        let length = try Int(readLittleEndianUInt16())
        return (type, try readData(count: length))
    }
}

enum MockKRDPTLS {
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

    static func ntlmChannelBindingsHash() throws -> Data {
        guard let certificate = try certificates().first else {
            throw MockKRDPServerError.invalidClientPDU
        }
        return try RDPCredSSPCertificate.ntlmChannelBindingsHash(
            fromCertificateDER: Data(certificate.toDERBytes())
        )
    }

    static func rdpX509CertificateChain() throws -> Data {
        guard let certificate = try certificates().first else {
            throw MockKRDPServerError.invalidClientPDU
        }
        let certificateDER = Data(try certificate.toDERBytes())
        var chain = Data()
        chain.appendLittleEndianUInt32(2)
        chain.appendLittleEndianUInt32(UInt32(certificateDER.count))
        chain.append(certificateDER)
        chain.appendLittleEndianUInt32(UInt32(certificateDER.count))
        chain.append(certificateDER)
        chain.append(Data(repeating: 0, count: 16))
        var serverCertificate = Data()
        serverCertificate.appendLittleEndianUInt32(2)
        serverCertificate.append(chain)
        return serverCertificate
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
