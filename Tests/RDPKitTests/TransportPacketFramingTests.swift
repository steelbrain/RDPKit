import Foundation
import NIOCore
import NIOEmbedded
import NIOPosix
@testable import RDPKit
import Testing

@Test func parsesTPKTTransportPacketLength() throws {
    let packet = Data([0x03, 0x00, 0x00, 0x07, 0x02, 0xF0, 0x80])

    #expect(try RDPTransportPacketFraming.packetLength(from: packet) == 7)
}

@Test func rejectsTPKTTransportPacketWithNonzeroReservedByte() throws {
    do {
        _ = try RDPTransportPacketFraming.packetLength(from: Data([0x03, 0x01, 0x00, 0x07]))
        #expect(Bool(false), "Expected invalid TPKT reserved byte to throw")
    } catch let error as RDPConnectionError {
        #expect(error.description == "receive failed: received invalid TPKT reserved byte 1")
    }
}

@Test func rejectsTPKTTransportPacketLengthSmallerThanHeader() throws {
    do {
        _ = try RDPTransportPacketFraming.packetLength(from: Data([0x03, 0x00, 0x00, 0x03]))
        #expect(Bool(false), "Expected invalid TPKT length to throw")
    } catch let error as RDPConnectionError {
        #expect(error.description == "receive failed: received invalid TPKT length 3")
    }
}

@Test func waitsForPartialTPKTTransportPacketHeader() throws {
    let packet = Data([0x03, 0x00, 0x00])

    #expect(try RDPTransportPacketFraming.packetLength(from: packet) == nil)
}

@Test func parsesFastPathTransportPacketLength() throws {
    let packet = Data([0x00, 0x08, 0x03, 0xEA, 0x00, 0x00, 0x00, 0x00])

    #expect(try RDPTransportPacketFraming.packetLength(from: packet) == 8)
}

@Test func parsesExtendedFastPathTransportPacketLength() throws {
    let packet = Data([0x00, 0x81, 0x00])

    #expect(try RDPTransportPacketFraming.packetLength(from: packet) == 0x0100)
}

@Test func rejectsInvalidFastPathTransportPacketLength() throws {
    do {
        _ = try RDPTransportPacketFraming.packetLength(from: Data([0x00, 0x02]))
        #expect(Bool(false), "Expected invalid Fast-Path length to throw")
    } catch let error as RDPConnectionError {
        #expect(error.description == "receive failed: received invalid Fast-Path length 2")
    }
}

@Test func rejectsFastPathOutputHeaderWithNonFastPathAction() throws {
    #expect(throws: RDPConnectionError.self) {
        try RDPTransportPacketFraming.packetLength(from: Data([0x01, 0x05]))
    }
}

@Test func framesCredSSPMessagesByTheirDERLength() throws {
    func length(_ bytes: [UInt8]) throws -> Int? {
        try RDPTransportPacketFraming.credSSPMessageLength(readableByteCount: bytes.count) { bytes[$0] }
    }

    #expect(try length([0x30, 0x03]) == 5)
    #expect(try length([0x30, 0x82, 0x01]) == nil)
    #expect(try length([0x30, 0x82, 0x01, 0x00]) == 260)
    #expect(throws: RDPConnectionError.self) { try length([0x31, 0x03]) }
    #expect(throws: RDPConnectionError.self) { try length([0x30, 0x83, 0x01, 0x00, 0x00]) }
}

// MARK: Transport reader

private let tpkt = Data([0x03, 0x00, 0x00, 0x07, 0x02, 0xF0, 0x80])

@Test func readerResplitsBufferedBytesWhenTheFramingChanges() throws {
    let (channel, reader, _) = try readerChannel()
    reader.setFraming(.credSSP)
    try channel.writeInbound(buffer(Data(tpkt.prefix(1))))
    reader.setFraming(.rdp)
    try channel.writeInbound(buffer(Data(tpkt.dropFirst())))

    #expect(try nextMessage(reader, channel) == tpkt)
}

@Test func readerHoldsSocketReadsWhileItsQueueIsFull() throws {
    let (channel, reader, reads) = try readerChannel()
    let queued = RDPTransportReader.pauseReadingMessageCount + 6
    try channel.writeInbound(buffer(Data((0 ..< queued).flatMap { _ in tpkt })))

    let readsBefore = reads.count
    channel.read()
    #expect(reads.count == readsBefore)

    for _ in 0 ..< queued - RDPTransportReader.resumeReadingMessageCount - 1 {
        _ = try nextMessage(reader, channel)
    }
    #expect(reads.count == readsBefore)
    _ = try nextMessage(reader, channel)
    #expect(reads.count == readsBefore + 1)
}

@Test func readerDeliversQueuedMessagesBeforeItsFailure() throws {
    let (channel, reader, _) = try readerChannel()
    try channel.writeInbound(buffer(tpkt + tpkt))
    channel.pipeline.fireErrorCaught(IOError(errnoCode: ECONNRESET, reason: "read"))

    #expect(try nextMessage(reader, channel) == tpkt)
    #expect(try nextMessage(reader, channel) == tpkt)
    #expect(throws: IOError.self) {
        try nextMessage(reader, channel)
    }
}

/// A receive's timeout that fires after the receive completed must not fail the next one.
@Test func readerTimeoutAbandonsOnlyItsOwnReceive() throws {
    let (channel, reader, _) = try readerChannel()
    let first = channel.eventLoop.makePromise(of: Data.self)
    reader.next(first)
    try channel.writeInbound(buffer(tpkt))
    #expect(try first.futureResult.wait() == tpkt)

    let second = channel.eventLoop.makePromise(of: Data.self)
    reader.next(second)
    reader.abandon(first, error: RDPTransportError.timedOut)
    try channel.writeInbound(buffer(tpkt))
    #expect(try second.futureResult.wait() == tpkt)

    let third = channel.eventLoop.makePromise(of: Data.self)
    reader.next(third)
    reader.abandon(third, error: RDPTransportError.timedOut)
    #expect(throws: RDPTransportError.self) {
        try third.futureResult.wait()
    }
}

/// A wake ends the wait with an empty message, which no server message is, or the next wait
/// when nothing waits; messages the server sent keep their order.
@Test func readerWakeEndsTheCurrentOrNextWaitWithAnEmptyMessage() throws {
    let (channel, reader, _) = try readerChannel()
    let waiting = channel.eventLoop.makePromise(of: Data.self)
    reader.next(waiting)
    reader.wake()
    #expect(try waiting.futureResult.wait() == Data())

    reader.wake()
    #expect(try nextMessage(reader, channel) == Data())
    try channel.writeInbound(buffer(tpkt))
    #expect(try nextMessage(reader, channel) == tpkt)

    try channel.writeInbound(buffer(tpkt))
    reader.wake()
    #expect(try nextMessage(reader, channel) == tpkt)
    #expect(try nextMessage(reader, channel) == Data())
}

/// After the CredSSP credentials the server either moves on to the next
/// layer or rejects them with a TSRequest errorCode ([MS-CSSP] 2.2.1).
@Test func readerReportsACredSSPErrorAnsweringTheCredentials() throws {
    let (channel, reader, _) = try readerChannel()
    reader.setFraming(.credSSPResult(then: .rdp))
    try channel.writeInbound(buffer(RDPCredSSPTSRequest(errorCode: 0xC000_006D).encoded()))

    let error = #expect(throws: RDPCredSSPError.self) {
        try nextMessage(reader, channel)
    }
    #expect(error.map(String.init(describing:)) == "CredSSP server returned STATUS_LOGON_FAILURE (0xc000006d)")

    let (accepted, acceptedReader, _) = try readerChannel()
    acceptedReader.setFraming(.credSSPResult(then: .rdp))
    try accepted.writeInbound(buffer(tpkt + tpkt))
    #expect(try nextMessage(acceptedReader, accepted) == tpkt)
    #expect(try nextMessage(acceptedReader, accepted) == tpkt)
}

/// A server that rejects the credentials and closes while the client is sending
/// the next layer fails that write; the client reports the rejection, not the write.
@Test func sendAfterACredSSPRejectionReportsTheRejection() throws {
    let server = try ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
        .childChannelInitializer { channel in
            channel.eventLoop.makeCompletedFuture {
                try channel.pipeline.syncOperations.addHandler(CredSSPRejectingHandler())
            }
        }
        .bind(host: "127.0.0.1", port: 0)
        .wait()
    defer { server.close(promise: nil) }
    let transport = try RDPTransport.connect(
        host: "127.0.0.1",
        port: UInt16(try #require(server.localAddress?.port)),
        timeoutSeconds: 10,
        callbacks: RDPSessionCallbacks()
    )
    defer { transport.close() }

    try transport.setFraming(.credSSPResult(then: .rdp))
    try transport.send(Data([0x30, 0x00]))
    try transport.channel.closeFuture.wait()

    let error = #expect(throws: RDPCredSSPError.self) {
        try transport.send(tpkt)
    }
    #expect(error.map(String.init(describing:)) == "CredSSP server returned STATUS_LOGON_FAILURE (0xc000006d)")
}

/// A server that accepts and closes at once (a port forward with nothing behind
/// it) fails the connect, if it does, with a connection error, not NIO's.
@Test func connectingToAServerThatClosesAtOnceFailsWithAConnectionError() throws {
    let server = try ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
        .childChannelInitializer { channel in
            channel.close()
        }
        .bind(host: "127.0.0.1", port: 0)
        .wait()
    defer { server.close(promise: nil) }
    let port = UInt16(try #require(server.localAddress?.port))

    // The close races the connecting thread; enough busy attempts lose that race.
    let foreignErrors = Locked<[String]>([])
    DispatchQueue.concurrentPerform(iterations: 8) { _ in
        for _ in 0 ..< 100 {
            do {
                try RDPTransport.connect(
                    host: "127.0.0.1",
                    port: port,
                    timeoutSeconds: 10,
                    callbacks: RDPSessionCallbacks()
                ).close()
            } catch where !(error is RDPConnectionError) {
                foreignErrors.withLock { $0.append(String(describing: error)) }
            } catch {}
        }
    }
    #expect(foreignErrors.value == [])
}

/// A server can close after the X.224 Connection Confirm, before the client
/// starts TLS: the closed channel refuses the TLS handler.
@Test func startingTLSOnAClosedConnectionReportsTheClose() throws {
    let server = try ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
        .childChannelInitializer { channel in
            channel.eventLoop.makeCompletedFuture {
                try channel.pipeline.syncOperations.addHandler(ClosingHandler())
            }
        }
        .bind(host: "127.0.0.1", port: 0)
        .wait()
    defer { server.close(promise: nil) }
    let transport = try RDPTransport.connect(
        host: "127.0.0.1",
        port: UInt16(try #require(server.localAddress?.port)),
        timeoutSeconds: 10,
        callbacks: RDPSessionCallbacks()
    )
    try transport.send(X224ConnectionRequest().encodedTPKT())
    try transport.channel.closeFuture.wait()

    let error = #expect(throws: RDPConnectionError.self) {
        try transport.startTLS(serverHostname: nil)
    }
    #expect(error.map(String.init(describing:)) == "TLS failed: connection closed before the TLS handshake completed")
}

/// Closes the connection on the client's first bytes.
private final class ClosingHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = ByteBuffer

    func channelRead(context: ChannelHandlerContext, data _: NIOAny) {
        context.close(promise: nil)
    }
}

/// Answers the client's first bytes with a CredSSP errorCode, then closes.
private final class CredSSPRejectingHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    func channelRead(context: ChannelHandlerContext, data _: NIOAny) {
        let rejection = RDPCredSSPTSRequest(errorCode: 0xC000_006D).encoded()
        context.writeAndFlush(NIOAny(context.channel.allocator.buffer(bytes: rejection)), promise: nil)
        context.close(promise: nil)
    }
}

/// Counts the socket reads the transport reader lets through.
private final class ReadCounter: ChannelOutboundHandler, @unchecked Sendable {
    typealias OutboundIn = Never
    private(set) var count = 0

    func read(context: ChannelHandlerContext) {
        count += 1
        context.read()
    }
}

private func readerChannel() throws -> (EmbeddedChannel, RDPTransportReader, ReadCounter) {
    let channel = EmbeddedChannel()
    let reads = ReadCounter()
    let reader = RDPTransportReader(onWireReceive: nil, transcript: nil)
    try channel.pipeline.syncOperations.addHandler(reads)
    try channel.pipeline.syncOperations.addHandler(reader)
    return (channel, reader, reads)
}

private func buffer(_ data: Data) -> ByteBuffer {
    ByteBuffer(bytes: data)
}

/// The reader's next message; the reader must already have it.
private func nextMessage(_ reader: RDPTransportReader, _ channel: EmbeddedChannel) throws -> Data {
    let promise = channel.eventLoop.makePromise(of: Data.self)
    reader.next(promise)
    return try promise.futureResult.wait()
}

// TPKT entry point for tests; the reader frames from its byte buffer.
extension RDPTransportPacketFraming {
    static func packetLength(from data: Data) throws -> Int? {
        try packetLength(readableByteCount: data.count) { index in
            data[data.index(data.startIndex, offsetBy: index)]
        }
    }
}
