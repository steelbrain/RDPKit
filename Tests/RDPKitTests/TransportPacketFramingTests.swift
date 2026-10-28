import Foundation
import NIOCore
import NIOEmbedded
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
    } catch let error as RDPPreflightError {
        #expect(error.description == "receive failed: received invalid TPKT reserved byte 1")
    }
}

@Test func rejectsTPKTTransportPacketLengthSmallerThanHeader() throws {
    do {
        _ = try RDPTransportPacketFraming.packetLength(from: Data([0x03, 0x00, 0x00, 0x03]))
        #expect(Bool(false), "Expected invalid TPKT length to throw")
    } catch let error as RDPPreflightError {
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
    } catch let error as RDPPreflightError {
        #expect(error.description == "receive failed: received invalid Fast-Path length 2")
    }
}

@Test func rejectsFastPathOutputHeaderWithNonFastPathAction() throws {
    #expect(throws: RDPPreflightError.self) {
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
    #expect(throws: RDPPreflightError.self) { try length([0x31, 0x03]) }
    #expect(throws: RDPPreflightError.self) { try length([0x30, 0x83, 0x01, 0x00, 0x00]) }
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
