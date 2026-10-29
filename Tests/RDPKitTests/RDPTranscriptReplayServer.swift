import Foundation
import NIOCore
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
final class RDPTranscriptReplayServer: LoopbackTestServer {
    struct ConnectionSegment {
        /// The server→client X.224 Connection Confirm bytes (plaintext).
        var x224Response: Data
        /// Whether the captured connection performed an NLA (security) exchange.
        var usesCredSSP: Bool
        /// Application-layer events (both directions) in wire order.
        var appEvents: [RDPWireEvent]
    }

    /// Application-layer packets the client sent, in order, across connections.
    let clientPackets: Locked<[Data]>

    /// `onSegmentEnd` runs on the event loop once a connection's recorded
    /// server events are all sent, so a test can script what follows.
    init(
        transcript: [RDPWireEvent],
        credentials: RDPCredentials,
        onSegmentEnd: (@Sendable (Channel) -> Void)? = nil
    ) throws {
        let segments = Self.segment(transcript)
        let tlsContext = try NIOSSLContext(configuration: MockKRDPTLS.configuration())
        let connectionCount = Locked(0)
        let clientPackets = Locked<[Data]>([])
        self.clientPackets = clientPackets
        try super.init {
            RDPTranscriptReplayHandler(
                tlsContext: tlsContext,
                credentials: credentials,
                segments: segments,
                connectionCount: connectionCount,
                clientPackets: clientPackets,
                onSegmentEnd: onSegmentEnd
            )
        }
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
    private let connectionCount: Locked<Int>
    private let clientPackets: Locked<[Data]>
    private let onSegmentEnd: (@Sendable (Channel) -> Void)?

    private var segment: RDPTranscriptReplayServer.ConnectionSegment?
    private var stage = Stage.x224
    private var received = ClientByteStream()
    private var credSSPServer: MockCredSSPServer?
    /// Cursor into the active segment's application events.
    private var appIndex = 0
    /// Connect-time Bandwidth Measure Start and Network Characteristics Result
    /// requests have no client response (MS-RDPBCGR 2.2.14.1.2, 2.2.14.1.5), but
    /// the client build that captured the GNOME transcript answered them, so the
    /// next recorded client event after each one is not a barrier.
    private var unansweredAutoDetectRequests = 0

    private static func isUnansweredConnectTimeAutoDetectRequest(_ bytes: Data) -> Bool {
        guard let request = try? RDPServerAutoDetectRequest.parseIfPresent(fromTPKT: bytes) else {
            return false
        }
        return [0x1014, 0x0840, 0x0880, 0x08C0].contains(request.requestType)
    }

    init(
        tlsContext: NIOSSLContext,
        credentials: RDPCredentials,
        segments: [RDPTranscriptReplayServer.ConnectionSegment],
        connectionCount: Locked<Int>,
        clientPackets: Locked<[Data]>,
        onSegmentEnd: (@Sendable (Channel) -> Void)?
    ) {
        self.tlsContext = tlsContext
        self.credentials = credentials
        self.segments = segments
        self.connectionCount = connectionCount
        self.clientPackets = clientPackets
        self.onSegmentEnd = onSegmentEnd
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        if let bytes = buffer.readBytes(length: buffer.readableBytes) {
            received.append(bytes)
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
                guard let packet = try received.nextPacket() else { return }
                try handleX224(packet, context: context)
            case .credSSP:
                guard let message = try received.nextCredSSPMessage() else { return }
                try handleCredSSP(message, context: context)
            case .application:
                guard let packet = try received.nextPacket() else { return }
                clientPackets.withLock { $0.append(packet) }
                advanceClientBarrier()
                pumpServerEvents(context: context)
            case .done:
                // Record, but do not answer, trailing client packets.
                guard let packet = try received.nextPacket() else { return }
                clientPackets.withLock { $0.append(packet) }
            }
        }
    }

    private func handleX224(_ packet: Data, context: ChannelHandlerContext) throws {
        _ = try TPKT.unwrap(packet)
        let index = connectionCount.withLock { count in
            count += 1
            return count - 1
        }
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
            credSSPServer = try MockCredSSPServer(credentials: credentials)
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
            if event.direction == .clientToServer {
                guard unansweredAutoDetectRequests > 0 else { break }
                unansweredAutoDetectRequests -= 1
                appIndex += 1
                continue
            }
            if let bytes = event.bytes {
                writeRaw(bytes, context: context)
                if Self.isUnansweredConnectTimeAutoDetectRequest(bytes) {
                    unansweredAutoDetectRequests += 1
                }
            }
            appIndex += 1
        }
        if appIndex >= segment.appEvents.count {
            stage = .done
            onSegmentEnd?(context.channel)
        }
    }

    @discardableResult
    private func writeRaw(_ packet: Data, context: ChannelHandlerContext) -> EventLoopFuture<Void> {
        var buffer = context.channel.allocator.buffer(capacity: packet.count)
        buffer.writeBytes(packet)
        return context.writeAndFlush(wrapOutboundOut(buffer))
    }
}

extension RDPTranscriptReplayHandler: @unchecked Sendable {}
