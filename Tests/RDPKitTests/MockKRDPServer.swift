import Foundation
import NIOCore
import NIOPosix
@preconcurrency import NIOSSL
@testable import RDPKit

final class MockKRDPServer {
    let port: UInt16

    private let group: MultiThreadedEventLoopGroup
    private let channel: Channel

    private init(port: UInt16, group: MultiThreadedEventLoopGroup, channel: Channel) {
        self.port = port
        self.group = group
        self.channel = channel
    }

    static func start(
        clipboardFiles: [RDPClipboardLocalFile] = [],
        graphicsBehavior: MockKRDPGraphicsBehavior = .sendFirstFrame
    ) throws -> MockKRDPServer {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            let tlsContext = try NIOSSLContext(configuration: MockKRDPTLS.configuration())
            let channel = try ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { channel in
                    channel.pipeline.addHandler(MockKRDPServerHandler(
                        tlsContext: tlsContext,
                        graphicsBehavior: graphicsBehavior,
                        clipboardFiles: clipboardFiles
                    ))
                }
                .bind(host: "127.0.0.1", port: 0)
                .wait()

            guard let port = channel.localAddress?.port,
                  let serverPort = UInt16(exactly: port)
            else {
                throw MockKRDPServerError.missingPort
            }

            return MockKRDPServer(port: serverPort, group: group, channel: channel)
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

enum MockKRDPGraphicsBehavior {
    case sendFirstFrame
    case sendEmptyFrameThenStall
    case stallAfterCapsConfirm
}

enum MockKRDPServerError: Error {
    case missingPort
    case invalidClientPDU
}

private enum MockKRDPConstants {
    static let userChannelID: UInt16 = 1002
    static let ioChannelID: UInt16 = 1003
    static let dynamicChannelID: UInt16 = 1004
    static let messageChannelID: UInt16 = 1005
    static let serverUserID: UInt16 = 1006
    static let clipboardChannelID: UInt16 = 1007
    static let shareID: UInt32 = 0x0001_03EE
    static let graphicsDynamicChannelID: UInt32 = 7
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

private final class MockKRDPServerHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private enum Stage {
        case x224
        case mcsConnectInitial
        case erectDomain
        case attachUser
        case channelJoin(Int)
        case clientInfo
        case autoDetectResponse
        case confirmActive
        case finalization(Int)
        case dynamicCapabilitiesResponse
        case graphicsCreateResponse
        case graphicsCapsAdvertise
        case graphicsFrameAcknowledge
        case done
    }

    private let tlsContext: NIOSSLContext
    private let graphicsBehavior: MockKRDPGraphicsBehavior
    private let clipboardFiles: [RDPClipboardLocalFile]
    private var stage = Stage.x224
    private var received = Data()
    private var didReleaseGraphicsHandshake = false

    init(
        tlsContext: NIOSSLContext,
        graphicsBehavior: MockKRDPGraphicsBehavior,
        clipboardFiles: [RDPClipboardLocalFile]
    ) {
        self.tlsContext = tlsContext
        self.graphicsBehavior = graphicsBehavior
        self.clipboardFiles = clipboardFiles
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
        while let packet = nextTPKT() {
            try handle(packet, context: context)
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

    private func handle(_ packet: Data, context: ChannelHandlerContext) throws {
        if try handleClipboardPacketIfPresent(packet, context: context) {
            return
        }

        switch stage {
        case .x224:
            _ = try TPKT.unwrap(packet)
            writePacket(MockKRDPFixtures.x224ConnectionConfirm(), context: context)
            let tlsHandler = NIOSSLServerHandler(context: tlsContext)
            try context.channel.pipeline.syncOperations.addHandler(tlsHandler, position: .first)
            stage = .mcsConnectInitial

        case .mcsConnectInitial:
            _ = try X224DataTPDU.unwrap(packet)
            writePacket(MockKRDPFixtures.mcsConnectResponse(clipboardEnabled: clipboardEnabled), context: context)
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
            let joinChannelIDs = MockKRDPFixtures.joinChannelIDs(clipboardEnabled: clipboardEnabled)
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
            if nextCount == 4 {
                writePacket(MockKRDPFixtures.controlGranted(), context: context)
                writePacket(MockKRDPFixtures.fontMap(), context: context)
                if clipboardEnabled {
                    writePacket(MockKRDPFixtures.clipboardMonitorReady(), context: context)
                    writePacket(MockKRDPFixtures.clipboardCapabilities(), context: context)
                    writePacket(MockKRDPFixtures.clipboardFormatList(), context: context)
                } else {
                    releaseGraphicsHandshake(context: context)
                }
                stage = .dynamicCapabilitiesResponse
            } else {
                stage = .finalization(nextCount)
            }

        case .dynamicCapabilitiesResponse:
            _ = try MockKRDPFixtures.staticVirtualChannelPayload(from: packet)
            writePacket(MockKRDPFixtures.graphicsCreateRequest(), context: context)
            stage = .graphicsCreateResponse

        case .graphicsCreateResponse:
            _ = try MockKRDPFixtures.staticVirtualChannelPayload(from: packet)
            stage = .graphicsCapsAdvertise

        case .graphicsCapsAdvertise:
            _ = try MockKRDPFixtures.staticVirtualChannelPayload(from: packet)
            writePacket(MockKRDPFixtures.graphicsCapsConfirm(), context: context)
            switch graphicsBehavior {
            case .sendFirstFrame:
                writePacket(MockKRDPFixtures.graphicsFrameUpdate(), context: context)
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

    private var clipboardEnabled: Bool {
        clipboardFiles.isEmpty == false
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
        if let request = try RDPClipboardFormatDataRequestPDU.parseIfPresent(from: clipboardPDU) {
            let response = clipboardFormatDataResponse(for: request)
            writePacket(MockKRDPFixtures.clipboardPacket(response.encoded()), context: context)
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

    private func clipboardFormatDataResponse(
        for request: RDPClipboardFormatDataRequestPDU
    ) -> RDPClipboardFormatDataResponsePDU {
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

    @discardableResult
    private func writePacket(_ packet: Data, context: ChannelHandlerContext) -> EventLoopFuture<Void> {
        var buffer = context.channel.allocator.buffer(capacity: packet.count)
        buffer.writeBytes(packet)
        return context.writeAndFlush(wrapOutboundOut(buffer))
    }
}

extension MockKRDPServerHandler: @unchecked Sendable {}

private enum MockKRDPFixtures {
    static func joinChannelIDs(clipboardEnabled: Bool) -> [UInt16] {
        var channelIDs = [
            MockKRDPConstants.userChannelID,
            MockKRDPConstants.ioChannelID,
            MockKRDPConstants.dynamicChannelID,
        ]
        if clipboardEnabled {
            channelIDs.append(MockKRDPConstants.clipboardChannelID)
        }
        channelIDs.append(MockKRDPConstants.messageChannelID)
        return channelIDs
    }

    static func x224ConnectionConfirm() -> Data {
        Data([
            0x03, 0x00, 0x00, 0x13,
            0x0E, 0xD0, 0x00, 0x00,
            0x00, 0x00, 0x00,
            0x02, 0x0B, 0x08, 0x00,
            0x01, 0x00, 0x00, 0x00,
        ])
    }

    static func mcsConnectResponse(clipboardEnabled: Bool = false) -> Data {
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
        let serverNetworkData: Data
        if clipboardEnabled {
            serverNetworkData = Data([
                0x03, 0x0C, 0x0C, 0x00,
                0xEB, 0x03,
                0x02, 0x00,
                0xEC, 0x03,
                0xEF, 0x03,
            ])
        } else {
            serverNetworkData = Data([
                0x03, 0x0C, 0x0C, 0x00,
                0xEB, 0x03,
                0x01, 0x00,
                0xEC, 0x03,
                0x00, 0x00,
            ])
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
        let sourceDescriptor = Data("KRdpMock".utf8)
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

    static func clipboardFormatList() -> Data {
        clipboardPacket(RDPClipboardFormatListPDU(entries: [
            RDPClipboardFormatListEntry(
                formatID: MockKRDPConstants.remoteFileGroupDescriptorWFormatID,
                formatName: RDPClipboardRegisteredFormatName.fileGroupDescriptorW
            ),
            RDPClipboardFormatListEntry(
                formatID: MockKRDPConstants.remoteFileContentsFormatID,
                formatName: RDPClipboardRegisteredFormatName.fileContents
            ),
        ]).encoded())
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

    static func graphicsCapsConfirm() -> Data {
        let flags = RDPGFXCapabilityFlags.smallCache | RDPGFXCapabilityFlags.avc420Enabled
        let capability = RDPGFXCapabilitySet.version81(flags: flags).encoded
        let confirm = graphicsMessage(commandID: RDPGFXCommandID.capsConfirm, payload: capability)
        return graphicsDynamicPacket(confirm)
    }

    static func graphicsFrameUpdate() -> Data {
        let messages = createSurfaceMessage()
            + startFrameMessage()
            + wireToSurfaceMessage()
            + endFrameMessage()
        return graphicsDynamicPacket(messages)
    }

    static func graphicsEmptyFrameUpdate() -> Data {
        let messages = createSurfaceMessage()
            + startFrameMessage()
            + endFrameMessage()
        return graphicsDynamicPacket(messages)
    }

    static func expectSendDataRequest(_ packet: Data, channelID expectedChannelID: UInt16) throws {
        let request = try clientSendDataRequest(from: packet)
        guard request.initiator == MockKRDPConstants.userChannelID,
              request.channelID == expectedChannelID
        else {
            throw MockKRDPServerError.invalidClientPDU
        }
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
        let dynamicPayload = RDPDynamicVirtualChannelDataPDU(
            channelID: MockKRDPConstants.graphicsDynamicChannelID,
            payload: payload
        ).encoded()
        return staticVirtualChannelPacket(dynamicPayload)
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

    private static func createSurfaceMessage() -> Data {
        var payload = Data()
        payload.appendLittleEndianUInt16(1)
        payload.appendLittleEndianUInt16(MockKRDPConstants.width)
        payload.appendLittleEndianUInt16(MockKRDPConstants.height)
        payload.appendUInt8(0x20)
        return graphicsMessage(commandID: RDPGFXCommandID.createSurface, payload: payload)
    }

    private static func startFrameMessage() -> Data {
        var payload = Data()
        payload.appendLittleEndianUInt32(0)
        payload.appendLittleEndianUInt32(MockKRDPConstants.frameID)
        return graphicsMessage(commandID: RDPGFXCommandID.startFrame, payload: payload)
    }

    private static func wireToSurfaceMessage() -> Data {
        let bitmapData = avc420BitmapStream()
        var payload = Data()
        payload.appendLittleEndianUInt16(1)
        payload.appendLittleEndianUInt16(RDPGFXCodecID.avc420)
        payload.appendUInt8(0x20)
        payload.appendLittleEndianUInt16(0)
        payload.appendLittleEndianUInt16(0)
        payload.appendLittleEndianUInt16(MockKRDPConstants.width)
        payload.appendLittleEndianUInt16(MockKRDPConstants.height)
        payload.appendLittleEndianUInt32(UInt32(bitmapData.count))
        payload.append(bitmapData)
        return graphicsMessage(commandID: RDPGFXCommandID.wireToSurface1, payload: payload)
    }

    private static func endFrameMessage() -> Data {
        var payload = Data()
        payload.appendLittleEndianUInt32(MockKRDPConstants.frameID)
        return graphicsMessage(commandID: RDPGFXCommandID.endFrame, payload: payload)
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
        let certificates = try NIOSSLCertificate.fromPEMBytes(Array(certificatePEM.utf8))
        let privateKey = try NIOSSLPrivateKey(bytes: Array(privateKeyPEM.utf8), format: .pem)
        return TLSConfiguration.makeServerConfiguration(
            certificateChain: certificates.map { .certificate($0) },
            privateKey: .privateKey(privateKey)
        )
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
