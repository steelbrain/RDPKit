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
    /// The answer to the CredSSP credentials: the next layer's messages, unless
    /// the server rejects them with a TSRequest errorCode ([MS-CSSP] 2.2.1, 3.1.5).
    /// Neither a TPKT, a fast-path header nor an EUA result starts with its 0x30 tag.
    indirect case credSSPResult(then: RDPTransportFraming)
}

enum RDPTransportPacketFraming {
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
                throw RDPConnectionError.receive("received invalid TPKT reserved byte \(byteAt(1))", failure: .protocolViolation)
            }
            let length = Int(byteAt(2)) << 8 | Int(byteAt(3))
            guard length >= 4 else {
                throw RDPConnectionError.receive("received invalid TPKT length \(length)", failure: .protocolViolation)
            }
            return length
        }

        // fpOutputHeader action MUST be FASTPATH_OUTPUT_ACTION_FASTPATH (0).
        guard byteAt(0) & 0x03 == 0 else {
            throw RDPConnectionError.receive("received invalid Fast-Path action \(byteAt(0) & 0x03)", failure: .protocolViolation)
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
            throw RDPConnectionError.receive("received invalid Fast-Path length \(length)", failure: .protocolViolation)
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
            throw RDPConnectionError.receive(
                "received invalid CredSSP ASN.1 tag 0x\(String(format: "%02x", byteAt(0)))",
                failure: .protocolViolation
            )
        }
        let firstLengthByte = byteAt(1)
        if firstLengthByte & 0x80 == 0 {
            return 2 + Int(firstLengthByte)
        }
        let lengthByteCount = Int(firstLengthByte & 0x7F)
        guard (1 ... 2).contains(lengthByteCount) else {
            throw RDPConnectionError.receive("received invalid CredSSP ASN.1 length", failure: .protocolViolation)
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
final class RDPTransportReader: ChannelDuplexHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    static let pauseReadingMessageCount = 64
    static let resumeReadingMessageCount = 16

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
    private(set) var failure: Error?
    private var readPending = false
    /// Whether `wake` came while nothing waited, so the next wait ends at once.
    private var isWoken = false
    /// The certificate chain the server presented in the TLS handshake, leaf first.
    var presentedCertificates: [NIOSSLCertificate] = []

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
        } else if isWoken {
            isWoken = false
            promise.succeed(Data())
        } else {
            waiter = promise
        }
    }

    /// Ends the session loop's wait with an empty message, which no server message is, so it
    /// runs work another thread queued for it; with no wait, the next one ends at once. Only
    /// the session loop's receive expects it: what calls this exists only once that loop runs.
    func wake() {
        if let waiter {
            self.waiter = nil
            waiter.succeed(Data())
        } else {
            isWoken = true
        }
    }

    /// Fails `promise` if it still waits; queued and later messages are kept.
    /// A timeout that fires after its receive completed leaves the next one alone.
    func abandon(_ promise: EventLoopPromise<Data>, error: Error) {
        guard let waiter, waiter.futureResult === promise.futureResult else {
            return
        }
        self.waiter = nil
        waiter.fail(error)
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
            if case .credSSPResult = framing {
                failWithCredSSPResult(data)
                return
            }
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
        if case let .credSSPResult(next) = framing, readable > 0, byteAt(0) != 0x30 {
            framing = next
        }
        do {
            let length: Int? = switch framing {
            case .rdp:
                try RDPTransportPacketFraming.packetLength(readableByteCount: readable, byteAt: byteAt)
            case .credSSP, .credSSPResult:
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

    private func failWithCredSSPResult(_ message: Data) {
        let errorCode = (try? RDPCredSSPTSRequest.parse(message))?.errorCode
        fail(errorCode.map { RDPCredSSPError.serverError($0) }
            ?? RDPConnectionError.protocolViolation("server answered the CredSSP credentials with a TSRequest"))
        context?.close(promise: nil)
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
    /// True from joining the MCS domain until `disconnect` sends the ultimatum.
    private let owesDisconnectUltimatum: NIOLoopBoundBox<Bool>

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
        let owesDisconnectUltimatum = NIOLoopBoundBox.makeBoxSendingValue(false, eventLoop: channel.eventLoop)
        self.owesDisconnectUltimatum = owesDisconnectUltimatum
        cancellationRegistration = callbacks.cancellation?.register {
            Self.disconnect(channel, owesDisconnectUltimatum: owesDisconnectUltimatum)
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
        let cancel: @Sendable () -> Void = {
            result.fail(RDPConnectionError.cancelled)
            connected.whenSuccess { $0.close(promise: nil) }
        }
        let registration = callbacks.cancellation?.register(cancel)
        defer { registration?.cancel() }

        let channel: Channel
        do {
            channel = try wait(for: result.futureResult, callbacks: callbacks, onCancel: cancel)
        } catch let error as RDPConnectionError {
            throw error
        } catch ChannelError.connectTimeout {
            throw RDPConnectionError.connect(RDPSocketError(errno: ETIMEDOUT), "timed out after \(timeoutSeconds) seconds")
        } catch let error as NIOConnectionError {
            if error.connectionErrors.isEmpty, let dnsError = error.dnsAError ?? error.dnsAAAAError {
                throw RDPConnectionError.addressResolution(connectionErrorDescription(dnsError))
            }
            let last = error.connectionErrors.last?.error
            throw RDPConnectionError.connect(
                RDPSocketError(errno: (last as? IOError)?.errnoCode),
                last.map(connectionErrorDescription) ?? String(describing: error)
            )
        } catch {
            throw RDPConnectionError.connect(
                RDPSocketError(errno: (error as? IOError)?.errnoCode),
                connectionErrorDescription(error)
            )
        }
        let reader: NIOLoopBound<RDPTransportReader>
        do {
            reader = try eventLoop.submit {
                try NIOLoopBound(channel.pipeline.syncOperations.handler(type: RDPTransportReader.self), eventLoop: eventLoop)
            }.wait()
        } catch {
            // Only closing empties the pipeline: the server dropped the connection as it accepted it.
            throw RDPConnectionError(.connectionClosed, description: "connect failed: the server closed the connection")
        }
        return RDPTransport(channel: channel, reader: reader, timeoutSeconds: timeoutSeconds, callbacks: callbacks)
    }

    func close() {
        channel.close(promise: nil)
    }

    /// The TLS 1.2 RSA key exchange suites BoringSSL offers, AEAD first.
    static let rsaKeyExchangeCipherSuites: [NIOTLSCipher] = [
        .TLS_RSA_WITH_AES_256_GCM_SHA384,
        .TLS_RSA_WITH_AES_128_GCM_SHA256,
        .TLS_RSA_WITH_AES_256_CBC_SHA,
        .TLS_RSA_WITH_AES_128_CBC_SHA,
    ]

    /// From now on `disconnect` sends the Disconnect Provider Ultimatum.
    func noteJoinedDomain() {
        let owesDisconnectUltimatum = owesDisconnectUltimatum
        channel.eventLoop.execute {
            owesDisconnectUltimatum.value = true
        }
    }

    /// Ends the session from this side: once the MCS domain is joined, the
    /// Disconnect Provider Ultimatum with rn-user-requested goes out before
    /// the connection closes ([MS-RDPBCGR] 1.3.1.4.1, 3.1.5.1.1).
    func disconnect() {
        Self.disconnect(channel, owesDisconnectUltimatum: owesDisconnectUltimatum)
    }

    private static func disconnect(_ channel: Channel, owesDisconnectUltimatum: NIOLoopBoundBox<Bool>) {
        channel.eventLoop.execute {
            if owesDisconnectUltimatum.value {
                owesDisconnectUltimatum.value = false
                let packet = MCSDisconnectProviderUltimatumPDU.userRequested.encodedTPKT()
                channel.writeAndFlush(channel.allocator.buffer(bytes: packet), promise: nil)
            }
            channel.close(promise: nil)
        }
    }

    /// Waits for `future`, polling `shouldCancel` about once a second. An
    /// `RDPConnectionCancellation` needs no polling: it closes the channel,
    /// which fails the future at once.
    private static func wait<Value: Sendable>(
        for future: EventLoopFuture<Value>,
        callbacks: RDPSessionCallbacks,
        onCancel: () -> Void
    ) throws -> Value {
        if callbacks.shouldCancel != nil {
            let completed = DispatchSemaphore(value: 0)
            future.whenComplete { _ in
                completed.signal()
            }
            while completed.wait(timeout: .now() + 1) == .timedOut {
                if callbacks.isCancelled {
                    onCancel()
                    throw RDPConnectionError.cancelled
                }
            }
        }
        return try future.wait()
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
            try Self.wait(for: channel.writeAndFlush(buffer), callbacks: callbacks, onCancel: disconnect)
        } catch let error as RDPConnectionError {
            throw error
        } catch {
            try callbacks.throwIfCancelled()
            if let rejection = serverRejection() {
                throw rejection
            }
            // The server closed the connection: receiving reports how, after the
            // messages it sent first, such as a Set Error Info and its Disconnect
            // Provider Ultimatum (gnome-remote-desktop ends sessions with those).
            guard channel.isActive else {
                return
            }
            throw RDPConnectionError.send(connectionErrorDescription(error))
        }
    }

    /// Why the server ended the connection, when it said so before closing: a
    /// CredSSP server can reject the credentials and close while the client is
    /// already sending the next layer, so that write fails for this reason.
    private func serverRejection() -> Error? {
        let reader = reader
        let failure = (try? channel.eventLoop.submit { reader.value.failure }.wait()) ?? nil
        return failure is RDPCredSSPError || failure is RDPConnectionError ? failure : nil
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

    /// Ends the session loop's current or next wait for a message from any thread, with the
    /// empty message `RDPTransportReader.wake` explains.
    var wake: @Sendable () -> Void {
        let reader = reader
        let eventLoop = channel.eventLoop
        return {
            eventLoop.execute {
                reader.value.wake()
            }
        }
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
                    disconnect()
                    throw RDPConnectionError.cancelled
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
                reader.value.abandon(promise, error: RDPTransportError.timedOut)
            }
            promise.futureResult.whenComplete { _ in
                timeout.cancel()
            }
        }
        return try promise.futureResult.wait()
    }

    /// Starts TLS on the open connection and returns the certificate chain the
    /// server presented and the negotiated version once the handshake completes.
    /// The handshake accepts any certificate; the caller evaluates the chain.
    func startTLS(
        serverHostname: String?,
        legacyRSAKeyExchange: Bool = false
    ) throws -> (certificates: [NIOSSLCertificate], version: TLSVersion?) {
        var configuration = TLSConfiguration.makeClientConfiguration()
        // Verification runs, so the callback below sees the presented chain,
        // but the callback replaces all of BoringSSL's checks.
        configuration.certificateVerification = .noHostnameVerification
        // Windows RDP can issue RSA certificates without digitalSignature,
        // which BoringSSL rejects on the TLS 1.3 certificate path.
        configuration.maximumTLSVersion = .tlsv12
        if legacyRSAKeyExchange {
            // In TLS 1.2 only ECDHE needs digitalSignature; RSA key exchange needs keyEncipherment.
            configuration.cipherSuiteValues = Self.rsaKeyExchangeCipherSuites
        }
        configuration.shutdownTimeout = .seconds(1)
        let context = try NIOSSLContext(configuration: configuration)

        let channel = channel
        let reader = reader
        let timeoutSeconds = timeoutSeconds
        let handshake = channel.eventLoop.makePromise(of: Void.self)
        let tls = NIOLoopBoundBox.makeEmptyBox(valueType: NIOSSLClientHandler.self, eventLoop: channel.eventLoop)
        channel.eventLoop.execute {
            do {
                let handler = try NIOSSLClientHandler(context: context, serverHostname: serverHostname) { chain, verified in
                    reader.value.presentedCertificates = chain
                    verified.succeed(.certificateVerified)
                }
                try channel.pipeline.syncOperations.addHandler(handler, position: .first)
                tls.value = handler
                reader.value.awaitHandshake(handshake)
            } catch {
                // A channel the server already closed refuses the handler.
                handshake.fail(reader.value.failure ?? error)
            }
        }
        let timeout = channel.eventLoop.scheduleTask(in: .seconds(Int64(timeoutSeconds))) {
            handshake.fail(RDPConnectionError.tls("TLS handshake timed out after \(timeoutSeconds) seconds", failure: .timedOut))
            channel.close(promise: nil)
        }
        handshake.futureResult.whenComplete { _ in
            timeout.cancel()
        }
        do {
            try Self.wait(for: handshake.futureResult, callbacks: callbacks, onCancel: disconnect)
        } catch let error as RDPConnectionError {
            throw error
        } catch RDPTransportError.closed {
            try callbacks.throwIfCancelled()
            throw RDPConnectionError.tls("connection closed before the TLS handshake completed", failure: .connectionClosed)
        } catch {
            try callbacks.throwIfCancelled()
            // NIOSSL keeps BoringSSL's error codes private, so the reason is matched by name.
            if !legacyRSAKeyExchange, String(describing: error).contains("KEY_USAGE_BIT_INCORRECT") {
                throw RDPConnectionError.tls(
                    "the server's certificate does not allow ECDHE key exchange (KEY_USAGE_BIT_INCORRECT); "
                        + "legacyRSAKeyExchange allows RSA key exchange",
                    failure: .tlsKeyUsageIncorrect
                )
            }
            throw RDPConnectionError.tls(String(describing: error))
        }

        // The handler, not a pipeline lookup: a server that closes right after
        // the handshake has already emptied the pipeline.
        return try channel.eventLoop.submit {
            (reader.value.presentedCertificates, tls.value?.tlsVersion)
        }.wait()
    }
}
