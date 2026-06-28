import Foundation
import NIOCore
import NIOPosix
@preconcurrency import NIOSSL
@testable import RDPKit

/// A local socket server that replays a captured ``RDPWireEvent`` transcript.
///
/// It terminates TLS and performs NLA (CredSSP/NTLM) live — those layers carry
/// fresh nonces/timestamps every run and cannot be replayed verbatim — then
/// feeds the recorded server→client application PDUs back in wire order, gated
/// on client packet arrivals. Each captured TCP connection (the transcript
/// splits at every client X.224 request) is replayed on the corresponding
/// inbound socket, so a recorded server-redirection reconnect is reproduced:
/// segment 0 plays on the first connection (ending in the redirect PDU) and
/// segment 1 plays on the client's reconnect (through to the first video frame).
final class RDPTranscriptReplayServer {
    struct ConnectionSegment {
        /// The server→client X.224 Connection Confirm bytes (plaintext).
        var x224Response: Data
        /// Whether the captured connection performed an NLA (security) exchange.
        var usesCredSSP: Bool
        /// Application-layer events (both directions) in wire order.
        var appEvents: [RDPWireEvent]
    }

    let port: UInt16
    private let group: MultiThreadedEventLoopGroup
    private let channel: Channel

    private init(port: UInt16, group: MultiThreadedEventLoopGroup, channel: Channel) {
        self.port = port
        self.group = group
        self.channel = channel
    }

    static func start(
        transcript: [RDPWireEvent],
        credentials: RDPCredentials
    ) throws -> RDPTranscriptReplayServer {
        let segments = segment(transcript)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            let tlsContext = try NIOSSLContext(configuration: MockKRDPTLS.configuration())
            let connectionLog = MockKRDPConnectionLog()
            let channel = try ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { channel in
                    channel.pipeline.addHandler(RDPTranscriptReplayHandler(
                        tlsContext: tlsContext,
                        credentials: credentials,
                        segments: segments,
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
            return RDPTranscriptReplayServer(port: serverPort, group: group, channel: channel)
        } catch {
            try? group.syncShutdownGracefully()
            throw error
        }
    }

    func stop() {
        try? channel.close().wait()
        try? group.syncShutdownGracefully()
    }

    /// Splits a flat transcript into per-TCP-connection segments. A new segment
    /// begins at each client→server X.224 request.
    static func segment(_ events: [RDPWireEvent]) -> [ConnectionSegment] {
        var segments: [ConnectionSegment] = []
        var x224Response = Data()
        var usesCredSSP = false
        var appEvents: [RDPWireEvent] = []
        var started = false

        func flush() {
            guard started else { return }
            segments.append(ConnectionSegment(
                x224Response: x224Response,
                usesCredSSP: usesCredSSP,
                appEvents: appEvents
            ))
        }

        for event in events {
            switch event.layer {
            case .x224:
                if event.direction == .clientToServer {
                    flush()
                    x224Response = Data()
                    usesCredSSP = false
                    appEvents = []
                    started = true
                } else if let bytes = event.bytes {
                    x224Response = bytes
                }
            case .security:
                usesCredSSP = true
            case .application:
                appEvents.append(event)
            }
        }
        flush()
        return segments
    }
}

private final class RDPTranscriptReplayHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private enum Stage {
        case x224
        case credSSP
        case application
        case done
    }

    private let tlsContext: NIOSSLContext
    private let credentials: RDPCredentials
    private let segments: [RDPTranscriptReplayServer.ConnectionSegment]
    private let connectionLog: MockKRDPConnectionLog

    private var segment: RDPTranscriptReplayServer.ConnectionSegment?
    private var stage = Stage.x224
    private var received = Data()
    private var credSSPServer: MockCredSSPServer?
    /// Cursor into the active segment's application events.
    private var appIndex = 0

    init(
        tlsContext: NIOSSLContext,
        credentials: RDPCredentials,
        segments: [RDPTranscriptReplayServer.ConnectionSegment],
        connectionLog: MockKRDPConnectionLog
    ) {
        self.tlsContext = tlsContext
        self.credentials = credentials
        self.segments = segments
        self.connectionLog = connectionLog
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        if let bytes = buffer.readBytes(length: buffer.readableBytes) {
            received.append(contentsOf: bytes)
        }
        do {
            try process(context: context)
        } catch {
            context.fireErrorCaught(error)
            context.close(promise: nil)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error _: Error) {
        context.close(promise: nil)
    }

    private func process(context: ChannelHandlerContext) throws {
        while true {
            switch stage {
            case .x224:
                guard let packet = nextTPKT() else { return }
                try handleX224(packet, context: context)
            case .credSSP:
                guard let message = try nextASN1Message() else { return }
                try handleCredSSP(message, context: context)
            case .application:
                guard nextTPKT() != nil else { return }
                advanceClientBarrier()
                pumpServerEvents(context: context)
            case .done:
                // Drain and ignore any trailing client packets.
                guard nextTPKT() != nil else { return }
            }
        }
    }

    private func handleX224(_ packet: Data, context: ChannelHandlerContext) throws {
        _ = try TPKT.unwrap(packet)
        let index = connectionLog.registerConnection() - 1
        guard index < segments.count else {
            throw MockKRDPServerError.invalidClientPDU
        }
        let segment = segments[index]
        self.segment = segment
        appIndex = 0

        writeRaw(segment.x224Response, context: context)
        let tlsHandler = NIOSSLServerHandler(context: tlsContext)
        try context.channel.pipeline.syncOperations.addHandler(tlsHandler, position: .first)

        if segment.usesCredSSP {
            credSSPServer = try MockCredSSPServer(credentials: credentials, transcript: MockKRDPServerTranscript())
            stage = .credSSP
        } else {
            stage = .application
            pumpServerEvents(context: context)
        }
    }

    private func handleCredSSP(_ message: Data, context: ChannelHandlerContext) throws {
        guard let credSSPServer else {
            throw MockKRDPServerError.invalidClientPDU
        }
        if let response = try credSSPServer.handle(message) {
            writeRaw(response, context: context)
        }
        if credSSPServer.isComplete {
            stage = .application
            pumpServerEvents(context: context)
        }
    }

    /// Skips the next application event if it is a client→server barrier.
    private func advanceClientBarrier() {
        guard let segment else { return }
        if appIndex < segment.appEvents.count,
           segment.appEvents[appIndex].direction == .clientToServer
        {
            appIndex += 1
        }
    }

    /// Emits consecutive server→client application PDUs until the next
    /// client→server barrier (or the end of the segment).
    private func pumpServerEvents(context: ChannelHandlerContext) {
        guard let segment else { return }
        while appIndex < segment.appEvents.count {
            let event = segment.appEvents[appIndex]
            guard event.direction == .serverToClient else { break }
            if let bytes = event.bytes {
                writeRaw(bytes, context: context)
            }
            appIndex += 1
        }
        if appIndex >= segment.appEvents.count {
            stage = .done
        }
    }

    private func nextTPKT() -> Data? {
        guard received.count >= 4 else { return nil }
        let length = Int(received[received.index(received.startIndex, offsetBy: 2)]) << 8
            | Int(received[received.index(received.startIndex, offsetBy: 3)])
        guard length >= 4, received.count >= length else { return nil }
        let packet = Data(received.prefix(length))
        received.removeFirst(length)
        return packet
    }

    private func nextASN1Message() throws -> Data? {
        guard received.count >= 2 else { return nil }
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
            guard received.count >= headerLength else { return nil }
            var length = 0
            for offset in 0 ..< lengthByteCount {
                let byte = received[received.index(received.startIndex, offsetBy: 2 + offset)]
                length = (length << 8) | Int(byte)
            }
            payloadLength = length
        }
        let totalLength = headerLength + payloadLength
        guard received.count >= totalLength else { return nil }
        let message = Data(received.prefix(totalLength))
        received.removeFirst(totalLength)
        return message
    }

    @discardableResult
    private func writeRaw(_ packet: Data, context: ChannelHandlerContext) -> EventLoopFuture<Void> {
        var buffer = context.channel.allocator.buffer(capacity: packet.count)
        buffer.writeBytes(packet)
        return context.writeAndFlush(wrapOutboundOut(buffer))
    }
}

extension RDPTranscriptReplayHandler: @unchecked Sendable {}
