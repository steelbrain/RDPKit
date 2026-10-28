import Darwin
import Foundation
@preconcurrency import NIOCore
import NIOPosix
@preconcurrency import NIOSSL
import NIOTLS

/// How the inbound byte stream is split into messages.
enum RDPTransportFraming: Equatable, Sendable {
    /// TPKT-framed X.224 or fast-path PDUs ([MS-RDPBCGR] 2.2.9.1.2).
    case rdp
    /// One DER-encoded TSRequest ([MS-CSSP] 2.2.1).
    case credSSP
    /// The 4-byte Early User Authorization Result PDU ([MS-RDPBCGR] 2.2.10.2).
    case earlyUserAuthorizationResult
}

enum RDPTransportPacketFraming {
    static func packetLength(from data: Data) throws -> Int? {
        try packetLength(readableByteCount: data.count) { index in
            data[data.index(data.startIndex, offsetBy: index)]
        }
    }

    /// The length of the TPKT or fast-path PDU at the start of the stream, or
    /// nil until enough of its header has arrived.
    static func packetLength(
        readableByteCount: Int,
        byteAt: (Int) -> UInt8
    ) throws -> Int? {
        guard readableByteCount >= 2 else {
            return nil
        }

        if byteAt(0) == TPKT.version {
            guard readableByteCount >= 4 else {
                return nil
            }
            guard byteAt(1) == 0 else {
                throw RDPPreflightError.receive("received invalid TPKT reserved byte \(byteAt(1))")
            }
            let length = Int(byteAt(2)) << 8 | Int(byteAt(3))
            guard length >= 4 else {
                throw RDPPreflightError.receive("received invalid TPKT length \(length)")
            }
            return length
        }

        // fpOutputHeader action MUST be FASTPATH_OUTPUT_ACTION_FASTPATH (0).
        guard byteAt(0) & 0x03 == 0 else {
            throw RDPPreflightError.receive("received invalid Fast-Path action \(byteAt(0) & 0x03)")
        }
        let firstLengthByte = byteAt(1)
        let length: Int
        if firstLengthByte & 0x80 == 0 {
            length = Int(firstLengthByte)
        } else {
            guard readableByteCount >= 3 else {
                return nil
            }
            length = Int(firstLengthByte & 0x7F) << 8 | Int(byteAt(2))
        }
        guard length >= 3 else {
            throw RDPPreflightError.receive("received invalid Fast-Path length \(length)")
        }
        return length
    }

    /// The length of the DER TSRequest at the start of the stream. TSRequests
    /// carry a few kilobytes of NTLM data, so larger lengths are rejected rather
    /// than buffered.
    static func credSSPMessageLength(readableByteCount: Int, byteAt: (Int) -> UInt8) throws -> Int? {
        guard readableByteCount >= 2 else {
            return nil
        }
        guard byteAt(0) == 0x30 else {
            throw RDPPreflightError.receive("received invalid CredSSP ASN.1 tag 0x\(String(format: "%02x", byteAt(0)))")
        }
        let firstLengthByte = byteAt(1)
        if firstLengthByte & 0x80 == 0 {
            return 2 + Int(firstLengthByte)
        }
        let lengthByteCount = Int(firstLengthByte & 0x7F)
        guard (1 ... 2).contains(lengthByteCount) else {
            throw RDPPreflightError.receive("received invalid CredSSP ASN.1 length")
        }
        guard readableByteCount >= 2 + lengthByteCount else {
            return nil
        }
        var payloadLength = 0
        for index in 0 ..< lengthByteCount {
            payloadLength = payloadLength << 8 | Int(byteAt(2 + index))
        }
        return 2 + lengthByteCount + payloadLength
    }
}

enum RDPTransportError: Error {
    case closed
    case timedOut
}

/// Whether a connection error is the peer closing the connection: a TCP
/// close, or one without TLS close_notify, as RDP servers commonly do.
/// Anything else (a reset, a TLS error, a keepalive timeout) is a lost connection.
func isConnectionClose(_ error: Error) -> Bool {
    switch error {
    case RDPTransportError.closed, NIOSSLError.uncleanShutdown:
        true
    default:
        false
    }
}

/// A short reason for a network error, such as "Connection reset by peer".
func connectionErrorDescription(_ error: Error) -> String {
    switch error {
    case let error as IOError:
        String(cString: strerror(error.errnoCode))
    case let error as SocketAddressError.UnknownHost:
        error.errorDescription
    default:
        String(describing: error)
    }
}

/// The one inbound handler of a connection. It splits the stream according to
/// the current framing, queues complete messages for the connection thread, and
/// stops reading from the socket while that queue is full.
private final class RDPTransportReader: ChannelDuplexHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private static let pauseReadingMessageCount = 64
    private static let resumeReadingMessageCount = 16

    var framing = RDPTransportFraming.rdp
    /// The transcript layer server messages are recorded under; nil records nothing.
    var recordedLayer: RDPWireLayer? = .x224
    private let onWireReceive: RDPWireReceiveHandler?
    private let transcript: RDPWireTranscript?
    private var context: ChannelHandlerContext?
    private var received: ByteBuffer?
    private var messages = CircularBuffer<Data>()
    private var waiter: EventLoopPromise<Data>?
    private var handshake: EventLoopPromise<Void>?
    private var failure: Error?
    private var readPending = false

    init(onWireReceive: RDPWireReceiveHandler?, transcript: RDPWireTranscript?) {
        self.onWireReceive = onWireReceive
        self.transcript = transcript
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        fail(RDPTransportError.closed)
        self.context = nil
    }

    func setFraming(_ framing: RDPTransportFraming) {
        self.framing = framing
        parseReceivedMessages()
    }

    func next(_ promise: EventLoopPromise<Data>) {
        if let message = messages.popFirst() {
            promise.succeed(message)
            resumeReadingIfNeeded()
        } else if let failure {
            promise.fail(failure)
        } else {
            waiter = promise
        }
    }

    /// Fails only the pending receive; queued and later messages are kept.
    func abandonWaiter(_ error: Error) {
        waiter?.fail(error)
        waiter = nil
    }

    func awaitHandshake(_ promise: EventLoopPromise<Void>) {
        if let failure {
            promise.fail(failure)
        } else {
            handshake = promise
        }
    }

    func read(context: ChannelHandlerContext) {
        if messages.count >= Self.pauseReadingMessageCount {
            readPending = true
        } else {
            context.read()
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var bytes = unwrapInboundIn(data)
        if received == nil {
            received = bytes
        } else {
            received?.writeBuffer(&bytes)
        }
        parseReceivedMessages()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let tlsEvent = event as? TLSUserEvent, case .handshakeCompleted = tlsEvent {
            handshake?.succeed(())
            handshake = nil
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelInactive(context: ChannelHandlerContext) {
        fail(RDPTransportError.closed)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        fail(error)
        context.close(promise: nil)
    }

    private func parseReceivedMessages() {
        while failure == nil, let length = nextMessageLength(), let message = received?.readBytes(length: length) {
            let data = Data(message)
            onWireReceive?(RDPWireReceiveSample(byteCount: data.count, receivedAt: Date()))
            if let recordedLayer {
                transcript?.record(direction: .serverToClient, layer: recordedLayer, bytes: data, capturePayload: true)
            }
            if let waiter {
                self.waiter = nil
                waiter.succeed(data)
            } else {
                messages.append(data)
            }
        }
        if received?.readableBytes == 0 {
            received = nil
        } else if let readerIndex = received?.readerIndex, readerIndex >= 64 * 1024 {
            received?.discardReadBytes()
        }
    }

    private func nextMessageLength() -> Int? {
        guard let received else {
            return nil
        }
        let readable = received.readableBytes
        let byteAt: (Int) -> UInt8 = { received.getInteger(at: received.readerIndex + $0) ?? 0 }
        do {
            let length: Int? = switch framing {
            case .rdp:
                try RDPTransportPacketFraming.packetLength(readableByteCount: readable, byteAt: byteAt)
            case .credSSP:
                try RDPTransportPacketFraming.credSSPMessageLength(readableByteCount: readable, byteAt: byteAt)
            case .earlyUserAuthorizationResult:
                4
            }
            guard let length, readable >= length else {
                return nil
            }
            return length
        } catch {
            fail(error)
            context?.close(promise: nil)
            return nil
        }
    }

    private func resumeReadingIfNeeded() {
        guard readPending, messages.count <= Self.resumeReadingMessageCount, let context else {
            return
        }
        readPending = false
        context.read()
    }

    private func fail(_ error: Error) {
        guard failure == nil else {
            return
        }
        failure = error
        received = nil
        waiter?.fail(error)
        waiter = nil
        handshake?.fail(error)
        handshake = nil
    }
}

/// A TCP connection to the server, owned by the connection thread. Reads are
/// delivered by `RDPTransportReader` on the event loop; this side blocks on them.
final class RDPTransport {
    let channel: Channel
    let timeoutSeconds: Int
    /// The transcript layer client messages are recorded under; nil records nothing.
    private var recordedLayer: RDPWireLayer? = .x224
    private let reader: NIOLoopBound<RDPTransportReader>
    private let callbacks: RDPSessionCallbacks
    private let cancellationRegistration: RDPConnectionCancellationRegistration?

    private init(
        channel: Channel,
        reader: NIOLoopBound<RDPTransportReader>,
        timeoutSeconds: Int,
        callbacks: RDPSessionCallbacks
    ) {
        self.channel = channel
        self.reader = reader
        self.timeoutSeconds = timeoutSeconds
        self.callbacks = callbacks
        cancellationRegistration = callbacks.cancellation?.register {
            channel.close(promise: nil)
        }
    }

    deinit {
        cancellationRegistration?.cancel()
        channel.close(promise: nil)
    }

    /// Connects with Happy Eyeballs over every resolved address, bounded by
    /// `timeoutSeconds` and cancellable while it runs.
    static func connect(
        host: String,
        port: UInt16,
        timeoutSeconds: Int,
        callbacks: RDPSessionCallbacks
    ) throws -> RDPTransport {
        try callbacks.throwIfCancelled()
        let eventLoop = MultiThreadedEventLoopGroup.singleton.next()
        let onWireReceive = callbacks.onWireReceive
        let transcript = callbacks.wireTranscript
        let connected = ClientBootstrap(group: eventLoop)
            .connectTimeout(.seconds(Int64(timeoutSeconds)))
            .channelOption(.socketOption(.so_keepalive), value: 1)
            // Notice a silently dead peer within about a minute; nothing in
            // the session requires the server to send.
            .channelOption(.tcpOption(.init(rawValue: TCP_KEEPALIVE)), value: 30)
            .channelOption(.tcpOption(.init(rawValue: TCP_KEEPINTVL)), value: 10)
            .channelOption(.tcpOption(.init(rawValue: TCP_KEEPCNT)), value: 3)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(
                        RDPTransportReader(onWireReceive: onWireReceive, transcript: transcript)
                    )
                }
            }
            .connect(host: host, port: Int(port))

        let result = eventLoop.makePromise(of: Channel.self)
        connected.cascade(to: result)
        let registration = callbacks.cancellation?.register {
            result.fail(RDPPreflightError.cancelled)
            connected.whenSuccess { $0.close(promise: nil) }
        }
        defer { registration?.cancel() }

        let channel: Channel
        do {
            channel = try result.futureResult.wait()
        } catch let error as RDPPreflightError {
            throw error
        } catch ChannelError.connectTimeout {
            throw RDPPreflightError.connect("timed out after \(timeoutSeconds) seconds")
        } catch {
            throw RDPPreflightError.connect(String(describing: error))
        }
        let reader = try eventLoop.submit {
            try NIOLoopBound(channel.pipeline.syncOperations.handler(type: RDPTransportReader.self), eventLoop: eventLoop)
        }.wait()
        return RDPTransport(channel: channel, reader: reader, timeoutSeconds: timeoutSeconds, callbacks: callbacks)
    }

    func close() {
        channel.close(promise: nil)
    }

    /// Sends one message. Application messages are recorded length-only:
    /// their payload can carry credentials and replay does not need it.
    func send(_ packet: Data) throws {
        if let recordedLayer {
            callbacks.wireTranscript?.record(
                direction: .clientToServer,
                layer: recordedLayer,
                bytes: packet,
                capturePayload: recordedLayer == .x224
            )
        }
        var buffer = channel.allocator.buffer(capacity: packet.count)
        buffer.writeBytes(packet)
        do {
            try channel.writeAndFlush(buffer).wait()
        } catch {
            try callbacks.throwIfCancelled()
            throw RDPPreflightError.send(String(describing: error))
        }
    }

    /// Switches how inbound bytes are split; bytes already buffered are
    /// re-split, so call this before the peer can send in the new format.
    func setFraming(_ framing: RDPTransportFraming) throws {
        let reader = reader
        try channel.eventLoop.submit {
            reader.value.setFraming(framing)
        }.wait()
    }

    func setRecordedLayer(_ layer: RDPWireLayer?) throws {
        recordedLayer = layer
        let reader = reader
        try channel.eventLoop.submit {
            reader.value.recordedLayer = layer
        }.wait()
    }

    /// Waits for the next message. A nil `timeout` waits until the connection
    /// closes; `RDPTransportError.timedOut` leaves the connection usable.
    func receive(timeout: TimeAmount?) throws -> Data {
        try callbacks.throwIfCancelled()
        let deadline = timeout.map { NIODeadline.now() + $0 }
        while true {
            // A polled `shouldCancel` is checked at least once a second.
            var slice = deadline
            if callbacks.shouldCancel != nil {
                let poll = NIODeadline.now() + .seconds(1)
                slice = deadline.map { min($0, poll) } ?? poll
            }
            do {
                return try receive(until: slice)
            } catch RDPTransportError.timedOut where slice != deadline {
                if callbacks.isCancelled {
                    close()
                    throw RDPPreflightError.cancelled
                }
                if let deadline, deadline <= .now() {
                    throw RDPTransportError.timedOut
                }
            } catch {
                try callbacks.throwIfCancelled()
                throw error
            }
        }
    }

    private func receive(until deadline: NIODeadline?) throws -> Data {
        let eventLoop = channel.eventLoop
        let reader = reader
        let promise = eventLoop.makePromise(of: Data.self)
        eventLoop.execute {
            reader.value.next(promise)
        }
        if let deadline {
            let timeout = eventLoop.scheduleTask(deadline: deadline) {
                reader.value.abandonWaiter(RDPTransportError.timedOut)
            }
            promise.futureResult.whenComplete { _ in
                timeout.cancel()
            }
        }
        return try promise.futureResult.wait()
    }

    /// Starts TLS on the open connection and returns the server's certificates
    /// and negotiated version once the handshake completes.
    func startTLS(serverHostname: String?) throws -> (certificates: [NIOSSLCertificate], version: TLSVersion?) {
        var configuration = TLSConfiguration.makeClientConfiguration()
        configuration.certificateVerification = .none
        // Windows RDP can issue RSA certificates without digitalSignature,
        // which BoringSSL rejects on the TLS 1.3 certificate path.
        configuration.maximumTLSVersion = .tlsv12
        configuration.shutdownTimeout = .seconds(1)
        let context = try NIOSSLContext(configuration: configuration)

        let channel = channel
        let reader = reader
        let timeoutSeconds = timeoutSeconds
        let handshake = channel.eventLoop.makePromise(of: Void.self)
        try channel.eventLoop.submit {
            let tls = try NIOSSLClientHandler(context: context, serverHostname: serverHostname)
            try channel.pipeline.syncOperations.addHandler(tls, position: .first)
            reader.value.awaitHandshake(handshake)
        }.wait()
        let timeout = channel.eventLoop.scheduleTask(in: .seconds(Int64(timeoutSeconds))) {
            handshake.fail(RDPPreflightError.tls("TLS handshake timed out after \(timeoutSeconds) seconds"))
            channel.close(promise: nil)
        }
        handshake.futureResult.whenComplete { _ in
            timeout.cancel()
        }
        do {
            try handshake.futureResult.wait()
        } catch let error as RDPPreflightError {
            throw error
        } catch RDPTransportError.closed {
            try callbacks.throwIfCancelled()
            throw RDPPreflightError.tls("connection closed before the TLS handshake completed")
        } catch {
            try callbacks.throwIfCancelled()
            throw RDPPreflightError.tls(String(describing: error))
        }

        return try channel.eventLoop.submit {
            let tls = try channel.pipeline.syncOperations.handler(type: NIOSSLClientHandler.self)
            return (tls.peerCertificate.map { [$0] } ?? [], tls.tlsVersion)
        }.wait()
    }
}
