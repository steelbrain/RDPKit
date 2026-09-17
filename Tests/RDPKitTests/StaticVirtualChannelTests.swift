import Foundation
@testable import RDPKit
import Testing

@Test func staticVirtualChannelWrapsSinglePayloadWithChannelHeader() {
    let pdu = RDPStaticVirtualChannelPDU(payload: Data([0x50, 0x00, 0x02, 0x00]))

    #expect(pdu.encodedUserData().rdpHexString == "04 00 00 00 03 00 00 00 50 00 02 00")
    #expect(pdu.isComplete)
}

@Test func staticVirtualChannelCanRequestShowProtocolFraming() {
    let pdu = RDPStaticVirtualChannelPDU(
        payload: Data([0x07, 0x00, 0x00, 0x00]),
        flags: RDPStaticVirtualChannelFlags.first
            | RDPStaticVirtualChannelFlags.last
            | RDPStaticVirtualChannelFlags.showProtocol
    )

    #expect(pdu.encodedUserData().rdpHexString == "04 00 00 00 13 00 00 00 07 00 00 00")
    #expect(pdu.isComplete)
}

@Test func staticVirtualChannelDefaultChunkSizeMatchesSpec() {
    #expect(RDPStaticVirtualChannelPDU.maximumPayloadByteCount == 1_600)
    #expect(RDPStaticVirtualChannelPDU.canEncodeSinglePayload(Data(repeating: 0xAA, count: 1_600)))
    #expect(!RDPStaticVirtualChannelPDU.canEncodeSinglePayload(Data(repeating: 0xAA, count: 1_601)))
}

@Test func staticVirtualChannelParsesFromMCSDataIndication() throws {
    let packet = Data([
        0x03, 0x00, 0x00, 0x1A,
        0x02, 0xF0, 0x80,
        0x68, 0x00, 0x06, 0x03, 0xEC, 0x70, 0x0C,
        0x04, 0x00, 0x00, 0x00,
        0x03, 0x00, 0x00, 0x00,
        0x50, 0x00, 0x02, 0x00,
    ])

    let pdu = try #require(try RDPStaticVirtualChannelPDU.parseIfPresent(
        fromTPKT: packet,
        channelID: 1004
    ))

    #expect(pdu.totalLength == 4)
    #expect(pdu.flags == 0x0000_0003)
    #expect(pdu.payload == Data([0x50, 0x00, 0x02, 0x00]))
    #expect(pdu.isComplete)
}

@Test func staticVirtualChannelParsesMaximumDefaultChunk() throws {
    let payload = Data(repeating: 0xAA, count: RDPStaticVirtualChannelPDU.maximumPayloadByteCount)
    let pdu = try RDPStaticVirtualChannelPDU.parse(fromUserData: staticChannelUserData(
        totalLength: UInt32(payload.count),
        flags: RDPStaticVirtualChannelFlags.complete,
        payload: payload
    ))

    #expect(pdu.totalLength == UInt32(payload.count))
    #expect(pdu.payload == payload)
}

@Test func staticVirtualChannelParsesNegotiatedLargerChunk() throws {
    let payload = Data(repeating: 0xAA, count: RDPStaticVirtualChannelPDU.maximumPayloadByteCount + 1)
    let pdu = try RDPStaticVirtualChannelPDU.parse(
        fromUserData: staticChannelUserData(
            totalLength: UInt32(payload.count),
            flags: RDPStaticVirtualChannelFlags.complete,
            payload: payload
        ),
        maximumChunkByteCount: payload.count
    )

    #expect(pdu.totalLength == UInt32(payload.count))
    #expect(pdu.payload == payload)
}

@Test func staticVirtualChannelParsesNegotiatedLargerChunkFromMCSDataIndication() throws {
    let payload = Data(repeating: 0xAA, count: RDPStaticVirtualChannelPDU.maximumPayloadByteCount + 1)
    let packet = staticVirtualChannelPacket(
        totalLength: UInt32(payload.count),
        flags: RDPStaticVirtualChannelFlags.complete,
        payload: payload,
        channelID: 1004
    )

    let pdu = try #require(try RDPStaticVirtualChannelPDU.parseIfPresent(
        fromTPKT: packet,
        channelID: 1004,
        maximumChunkByteCount: payload.count
    ))

    #expect(pdu.totalLength == UInt32(payload.count))
    #expect(pdu.payload == payload)
}

@Test func staticVirtualChannelRejectsOversizedDefaultChunk() {
    let payload = Data(repeating: 0xAA, count: RDPStaticVirtualChannelPDU.maximumPayloadByteCount + 1)

    #expect(throws: RDPDecodeError.invalidStaticVirtualChannelPDU) {
        try RDPStaticVirtualChannelPDU.parse(fromUserData: staticChannelUserData(
            totalLength: UInt32(payload.count),
            flags: RDPStaticVirtualChannelFlags.complete,
            payload: payload
        ))
    }
}

@Test func staticVirtualChannelRejectsCompressionFlags() {
    #expect(throws: RDPDecodeError.invalidStaticVirtualChannelPDU) {
        try RDPStaticVirtualChannelPDU.parse(fromUserData: staticChannelUserData(
            totalLength: 4,
            flags: RDPStaticVirtualChannelFlags.complete | RDPStaticVirtualChannelFlags.compressed,
            payload: Data([0x50, 0x00, 0x02, 0x00])
        ))
    }
}

@Test func staticVirtualChannelIgnoresShadowPersistentFlag() throws {
    let pdu = try RDPStaticVirtualChannelPDU.parse(fromUserData: staticChannelUserData(
        totalLength: 4,
        flags: RDPStaticVirtualChannelFlags.complete | RDPStaticVirtualChannelFlags.shadowPersistent,
        payload: Data([0x50, 0x00, 0x02, 0x00])
    ))

    #expect(pdu.payload == Data([0x50, 0x00, 0x02, 0x00]))
    #expect(pdu.flags & RDPStaticVirtualChannelFlags.shadowPersistent != 0)
}

@Test func staticVirtualChannelRejectsUndefinedFlags() {
    #expect(throws: RDPDecodeError.invalidStaticVirtualChannelPDU) {
        try RDPStaticVirtualChannelPDU.parse(fromUserData: staticChannelUserData(
            totalLength: 4,
            flags: RDPStaticVirtualChannelFlags.complete | 0x0000_0100,
            payload: Data([0x50, 0x00, 0x02, 0x00])
        ))
    }
}

@Test func staticVirtualChannelRejectsSinglePDUWithMismatchedLength() {
    var userData = Data()
    userData.appendLittleEndianUInt32(8)
    userData.appendLittleEndianUInt32(RDPStaticVirtualChannelFlags.complete)
    userData.append(contentsOf: [0x50, 0x00, 0x02, 0x00])

    #expect(throws: RDPDecodeError.invalidStaticVirtualChannelPDU) {
        try RDPStaticVirtualChannelPDU.parse(fromUserData: userData)
    }
}

@Test func staticVirtualChannelParsesFirstChunkWithoutShowProtocol() throws {
    let pdu = try RDPStaticVirtualChannelPDU.parse(fromUserData: staticChannelUserData(
        totalLength: 8,
        flags: RDPStaticVirtualChannelFlags.first,
        payload: Data([0x50, 0x00, 0x02, 0x00])
    ))

    #expect(pdu.totalLength == 8)
    #expect(pdu.hasFirstChunkFlag)
    #expect(!pdu.hasLastChunkFlag)
    #expect(!pdu.isComplete)
    #expect(!pdu.isStandalone)
}

@Test func staticVirtualChannelParsesLastChunkWithoutShowProtocol() throws {
    let pdu = try RDPStaticVirtualChannelPDU.parse(fromUserData: staticChannelUserData(
        totalLength: 8,
        flags: RDPStaticVirtualChannelFlags.last,
        payload: Data([0x50, 0x00, 0x02, 0x00])
    ))

    #expect(pdu.totalLength == 8)
    #expect(!pdu.hasFirstChunkFlag)
    #expect(pdu.hasLastChunkFlag)
    #expect(!pdu.isComplete)
}

@Test func staticVirtualChannelRejectsChunkWithTotalLengthBelowPayload() {
    #expect(throws: RDPDecodeError.invalidStaticVirtualChannelPDU) {
        try RDPStaticVirtualChannelPDU.parse(fromUserData: staticChannelUserData(
            totalLength: 3,
            flags: RDPStaticVirtualChannelFlags.first,
            payload: Data([0x50, 0x00, 0x02, 0x00])
        ))
    }
}

@Test func staticVirtualChannelParsesStandaloneNoFlagPDU() throws {
    let pdu = try RDPStaticVirtualChannelPDU.parse(fromUserData: staticChannelUserData(
        totalLength: 4,
        flags: 0,
        payload: Data([0x50, 0x00, 0x02, 0x00])
    ))

    #expect(!pdu.isComplete)
    #expect(pdu.isStandalone)
    #expect(pdu.payload == Data([0x50, 0x00, 0x02, 0x00]))
}

@Test func staticVirtualChannelParsesNoFlagMiddleChunk() throws {
    let pdu = try RDPStaticVirtualChannelPDU.parse(fromUserData: staticChannelUserData(
        totalLength: 8,
        flags: 0,
        payload: Data([0x50, 0x00, 0x02, 0x00])
    ))

    #expect(pdu.totalLength == 8)
    #expect(!pdu.isComplete)
    #expect(!pdu.isStandalone)
}

@Test func staticVirtualChannelReassemblerRejectsNoFlagMiddleChunkWithoutOpenMessage() {
    var reassembler = RDPStaticVirtualChannelReassembler()

    #expect(throws: RDPDecodeError.invalidStaticVirtualChannelPDU) {
        try reassembler.append(try chunk(totalLength: 8, flags: 0, payload: [0x50, 0x00, 0x02, 0x00]))
    }
}

@Test func staticVirtualChannelParsesEmptySuspendAndResumePDUs() throws {
    for flag in [RDPStaticVirtualChannelFlags.suspend, RDPStaticVirtualChannelFlags.resume] {
        let pdu = try RDPStaticVirtualChannelPDU.parse(fromUserData: staticChannelUserData(
            totalLength: 0,
            flags: flag,
            payload: Data()
        ))

        #expect(pdu.isFlowControl)
        #expect(!pdu.isComplete)
        #expect(!pdu.isStandalone)
    }
}

@Test func staticVirtualChannelRejectsFlowControlPDUWithPayload() {
    #expect(throws: RDPDecodeError.invalidStaticVirtualChannelPDU) {
        try RDPStaticVirtualChannelPDU.parse(fromUserData: staticChannelUserData(
            totalLength: 1,
            flags: RDPStaticVirtualChannelFlags.suspend,
            payload: Data([0x00])
        ))
    }
}

@Test func staticVirtualChannelRejectsFlowControlPDUWithDataFlags() {
    #expect(throws: RDPDecodeError.invalidStaticVirtualChannelPDU) {
        try RDPStaticVirtualChannelPDU.parse(fromUserData: staticChannelUserData(
            totalLength: 0,
            flags: RDPStaticVirtualChannelFlags.suspend | RDPStaticVirtualChannelFlags.first,
            payload: Data()
        ))
    }
    #expect(throws: RDPDecodeError.invalidStaticVirtualChannelPDU) {
        try RDPStaticVirtualChannelPDU.parse(fromUserData: staticChannelUserData(
            totalLength: 0,
            flags: RDPStaticVirtualChannelFlags.suspend | RDPStaticVirtualChannelFlags.resume,
            payload: Data()
        ))
    }
}

@Test func staticVirtualChannelReassemblesChunkedPDUs() throws {
    var reassembler = RDPStaticVirtualChannelReassembler()
    #expect(try reassembler.append(
        try chunk(totalLength: 9, flags: .first, payload: [1, 2, 3], showProtocol: true)
    ) == nil)
    #expect(try reassembler.append(
        try chunk(totalLength: 9, flags: 0, payload: [4, 5, 6], showProtocol: true)
    ) == nil)

    let complete = try #require(try reassembler.append(
        try chunk(totalLength: 9, flags: .last, payload: [7, 8, 9], showProtocol: true)
    ))

    #expect(complete.totalLength == 9)
    #expect(complete.flags == RDPStaticVirtualChannelFlags.completeWithShowProtocol)
    #expect(complete.payload == Data([1, 2, 3, 4, 5, 6, 7, 8, 9]))
    #expect(complete.isComplete)
}

@Test func staticVirtualChannelReassemblerReturnsStandalonePDUAndIgnoresFlowControl() throws {
    var reassembler = RDPStaticVirtualChannelReassembler()
    let suspend = try RDPStaticVirtualChannelPDU.parse(fromUserData: staticChannelUserData(
        totalLength: 0,
        flags: RDPStaticVirtualChannelFlags.suspend,
        payload: Data()
    ))
    let standalone = try RDPStaticVirtualChannelPDU.parse(fromUserData: staticChannelUserData(
        totalLength: 3,
        flags: 0,
        payload: Data([1, 2, 3])
    ))

    #expect(try reassembler.append(suspend) == nil)
    #expect(try reassembler.append(standalone) == standalone)
}

@Test func staticVirtualChannelReassemblerRejectsOversizedChunk() throws {
    var reassembler = RDPStaticVirtualChannelReassembler()
    let payload = Data(repeating: 0xAA, count: RDPStaticVirtualChannelPDU.maximumPayloadByteCount + 1)
    let pdu = try RDPStaticVirtualChannelPDU.parse(
        fromUserData: staticChannelUserData(
            totalLength: UInt32(payload.count),
            flags: RDPStaticVirtualChannelFlags.first | RDPStaticVirtualChannelFlags.showProtocol,
            payload: payload
        ),
        maximumChunkByteCount: payload.count
    )

    #expect(throws: RDPDecodeError.invalidStaticVirtualChannelPDU) {
        try reassembler.append(pdu)
    }
}

@Test func staticVirtualChannelReassemblerRejectsInvalidSequences() throws {
    var missingFirst = RDPStaticVirtualChannelReassembler()
    #expect(throws: RDPDecodeError.invalidStaticVirtualChannelPDU) {
        try missingFirst.append(try chunk(totalLength: 4, flags: .last, payload: [1, 2]))
    }

    var mismatchedLength = RDPStaticVirtualChannelReassembler()
    _ = try mismatchedLength.append(try chunk(totalLength: 4, flags: .first, payload: [1, 2]))
    #expect(throws: RDPDecodeError.invalidStaticVirtualChannelPDU) {
        try mismatchedLength.append(try chunk(totalLength: 5, flags: .last, payload: [3, 4]))
    }

    var shortFinal = RDPStaticVirtualChannelReassembler()
    _ = try shortFinal.append(try chunk(totalLength: 5, flags: .first, payload: [1, 2]))
    #expect(throws: RDPDecodeError.invalidStaticVirtualChannelPDU) {
        try shortFinal.append(try chunk(totalLength: 5, flags: .last, payload: [3, 4]))
    }
}

@Test func staticVirtualChannelReassemblesSpecChunkedSequence() throws {
    let message = specChunkedMessage()
    var reassembler = RDPStaticVirtualChannelReassembler()

    #expect(try reassembler.append(
        try chunk(totalLength: 2_062, flags: .first, payload: Array(message[0 ..< 1_000]))
    ) == nil)
    #expect(reassembler.isReassembling)
    #expect(try reassembler.append(
        try chunk(totalLength: 2_062, flags: 0, payload: Array(message[1_000 ..< 2_000]))
    ) == nil)
    #expect(reassembler.isReassembling)

    let complete = try #require(try reassembler.append(
        try chunk(totalLength: 2_062, flags: .last, payload: Array(message[2_000 ..< 2_062]))
    ))

    #expect(complete.totalLength == 2_062)
    #expect(complete.payload.count == 2_062)
    #expect(complete.payload == message)
    #expect(complete.flags == RDPStaticVirtualChannelFlags.complete)
    #expect(complete.isComplete)
    #expect(!reassembler.isReassembling)
}

@Test func staticVirtualChannelReassemblesFirstAndLastChunkPair() throws {
    var reassembler = RDPStaticVirtualChannelReassembler()
    #expect(try reassembler.append(try chunk(totalLength: 6, flags: .first, payload: [1, 2, 3])) == nil)

    let complete = try #require(try reassembler.append(try chunk(totalLength: 6, flags: .last, payload: [4, 5, 6])))

    #expect(complete.totalLength == 6)
    #expect(complete.payload == Data([1, 2, 3, 4, 5, 6]))
    #expect(complete.flags == RDPStaticVirtualChannelFlags.complete)
}

@Test func staticVirtualChannelReassemblerDisambiguatesNoFlagChunks() throws {
    var reassembler = RDPStaticVirtualChannelReassembler()
    let standalone = try chunk(totalLength: 3, flags: 0, payload: [1, 2, 3])

    #expect(try reassembler.append(standalone) == standalone)
    #expect(!reassembler.isReassembling)

    #expect(try reassembler.append(try chunk(totalLength: 9, flags: .first, payload: [1, 2, 3])) == nil)
    #expect(try reassembler.append(try chunk(totalLength: 9, flags: 0, payload: [4, 5, 6])) == nil)

    let complete = try #require(try reassembler.append(try chunk(totalLength: 9, flags: .last, payload: [7, 8, 9])))

    #expect(complete.payload == Data([1, 2, 3, 4, 5, 6, 7, 8, 9]))
    #expect(try reassembler.append(standalone) == standalone)
}

@Test func staticVirtualChannelReassemblerRejectsOverlappingMessages() throws {
    var repeatedFirst = RDPStaticVirtualChannelReassembler()
    _ = try repeatedFirst.append(try chunk(totalLength: 6, flags: .first, payload: [1, 2, 3]))
    #expect(throws: RDPDecodeError.invalidStaticVirtualChannelPDU) {
        try repeatedFirst.append(try chunk(totalLength: 6, flags: .first, payload: [4, 5, 6]))
    }

    var completeWhileReassembling = RDPStaticVirtualChannelReassembler()
    _ = try completeWhileReassembling.append(try chunk(totalLength: 6, flags: .first, payload: [1, 2, 3]))
    #expect(throws: RDPDecodeError.invalidStaticVirtualChannelPDU) {
        try completeWhileReassembling.append(try chunk(
            totalLength: 3,
            flags: RDPStaticVirtualChannelFlags.complete,
            payload: [7, 8, 9]
        ))
    }

    var overflowingPayload = RDPStaticVirtualChannelReassembler()
    _ = try overflowingPayload.append(try chunk(totalLength: 4, flags: .first, payload: [1, 2, 3]))
    #expect(throws: RDPDecodeError.invalidStaticVirtualChannelPDU) {
        try overflowingPayload.append(try chunk(totalLength: 4, flags: 0, payload: [4, 5]))
    }
}

@Test func staticVirtualChannelReassemblerPassesFlowControlThroughOpenMessage() throws {
    var reassembler = RDPStaticVirtualChannelReassembler()
    let suspend = try RDPStaticVirtualChannelPDU.parse(fromUserData: staticChannelUserData(
        totalLength: 0,
        flags: RDPStaticVirtualChannelFlags.suspend,
        payload: Data()
    ))

    #expect(try reassembler.append(try chunk(totalLength: 6, flags: .first, payload: [1, 2, 3])) == nil)
    #expect(try reassembler.append(suspend) == nil)
    #expect(reassembler.isReassembling)

    let complete = try #require(try reassembler.append(try chunk(totalLength: 6, flags: .last, payload: [4, 5, 6])))

    #expect(complete.payload == Data([1, 2, 3, 4, 5, 6]))
}

private func specChunkedMessage() -> Data {
    Data((0 ..< 2_062).map { UInt8($0 % 251) })
}

private func staticChannelUserData(totalLength: UInt32, flags: UInt32, payload: Data) -> Data {
    var userData = Data()
    userData.appendLittleEndianUInt32(totalLength)
    userData.appendLittleEndianUInt32(flags)
    userData.append(payload)
    return userData
}

private func staticVirtualChannelPacket(
    totalLength: UInt32,
    flags: UInt32,
    payload: Data,
    channelID: UInt16
) -> Data {
    let userData = staticChannelUserData(totalLength: totalLength, flags: flags, payload: payload)
    var mcsData = Data()
    mcsData.appendUInt8(0x68)
    mcsData.appendBigEndianUInt16(1006 - 1001)
    mcsData.appendBigEndianUInt16(channelID)
    mcsData.appendUInt8(0x70)
    mcsData.appendPERLength(userData.count)
    mcsData.append(userData)
    return X224DataTPDU.wrap(mcsData)
}

private func chunk(
    totalLength: UInt32,
    flags: UInt32,
    payload: [UInt8],
    showProtocol: Bool = false
) throws -> RDPStaticVirtualChannelPDU {
    try RDPStaticVirtualChannelPDU.parse(fromUserData: staticChannelUserData(
        totalLength: totalLength,
        flags: showProtocol ? flags | RDPStaticVirtualChannelFlags.showProtocol : flags,
        payload: Data(payload)
    ))
}

private extension UInt32 {
    static let first = RDPStaticVirtualChannelFlags.first
    static let last = RDPStaticVirtualChannelFlags.last
}
