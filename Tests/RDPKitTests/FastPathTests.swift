import Foundation
@testable import RDPKit
import Testing

@Test func parsesFastPathSynchronizeAndPointerPositionUpdates() throws {
    let packet = fastPathPacket([
        fastPathUpdate(code: 0x3, payload: Data()),
        fastPathUpdate(code: 0x8, payload: Data([0x34, 0x12, 0x78, 0x56])),
    ])

    let pdu = try RDPFastPathOutputPDU.parse(packet)

    #expect(pdu.flags.isEmpty)
    #expect(pdu.dataSignature == nil)
    #expect(pdu.updates.count == 2)
    #expect(pdu.updates[0].typeName == "fastpath-synchronize")
    #expect(pdu.updates[0].fragmentation == .single)
    #expect(pdu.summaries[1] == RDPFastPathUpdateSummary(
        typeName: "fastpath-pointer-position",
        fragmentation: "single",
        compressed: false,
        byteCount: 4,
        pointerTypeName: "pointer-position"
    ))
    #expect(pdu.updates[1].pointerUpdate == .position(RDPPoint16(x: 0x1234, y: 0x5678)))
}

@Test func parsesExtendedFastPathLengthAndCachedPointerUpdate() throws {
    var updates = Data()
    for _ in 0 ..< 44 {
        updates.append(fastPathUpdate(code: 0x0, payload: Data()))
    }
    updates.append(fastPathUpdate(code: 0xA, payload: Data([0x05, 0x00])))
    let packet = fastPathPacket(updates)

    let pdu = try RDPFastPathOutputPDU.parse(packet)

    #expect(pdu.updates.last?.pointerUpdate == .cached(cacheIndex: 5))
}

@Test func parsesFastPathPointerSystemUpdates() throws {
    let pdu = try RDPFastPathOutputPDU.parse(fastPathPacket([
        fastPathUpdate(code: 0x5, payload: Data()),
        fastPathUpdate(code: 0x6, payload: Data()),
    ]))

    #expect(pdu.updates[0].pointerUpdate == .system(type: 0x0000_0000))
    #expect(pdu.updates[1].pointerUpdate == .system(type: 0x0000_7F00))
}

@Test func parsesFastPathNewPointerWithPackedOneBitXorMask() throws {
    let pdu = try RDPFastPathOutputPDU.parse(fastPathPacket([
        fastPathUpdate(code: 0xB, payload: newPointerPayload(xorBitsPerPixel: 1)),
    ]))

    guard case let .pointer(pointer) = pdu.updates[0].pointerUpdate else {
        Issue.record("Expected fast-path new pointer")
        return
    }
    #expect(pointer.xorBitsPerPixel == 1)
    #expect(pointer.colorPointer.width == 7)
    #expect(pointer.colorPointer.height == 2)
    #expect(pointer.colorPointer.xorMaskData == Data([0xaa, 0x00, 0xbb, 0x00]))
    #expect(pointer.colorPointer.andMaskData == Data([0xcc, 0x00, 0xdd, 0x00]))
    #expect(pdu.summaries[0].pointerTypeName == "pointer-new")
}

@Test func parsesFastPathLargePointerUpdate() throws {
    let pdu = try RDPFastPathOutputPDU.parse(fastPathPacket([
        fastPathUpdate(code: 0xC, payload: largePointerPayload()),
    ]))

    guard case let .largePointer(pointer) = pdu.updates[0].pointerUpdate else {
        Issue.record("Expected fast-path large pointer")
        return
    }
    #expect(pointer.xorBitsPerPixel == 32)
    #expect(pointer.colorPointer.width == 97)
    #expect(pointer.colorPointer.height == 1)
    #expect(pointer.colorPointer.xorMaskData.count == 388)
    #expect(pointer.colorPointer.andMaskData.count == 14)
    #expect(pdu.summaries[0].pointerTypeName == "pointer-large")
}

@Test func parsesFastPathCompressedBitmapUpdateHeader() throws {
    let packet = fastPathPacket([
        fastPathUpdate(
            code: 0x1,
            compressionFlags: 0x20,
            payload: Data([0x01, 0x02, 0x03])
        ),
    ])

    let pdu = try RDPFastPathOutputPDU.parse(packet)

    #expect(pdu.updates[0].typeName == "fastpath-bitmap")
    #expect(pdu.updates[0].compressionFlags == 0x20)
    #expect(pdu.updates[0].updateData == Data([0x01, 0x02, 0x03]))
    #expect(pdu.summaries[0].compressed)
}

@Test func parsesFastPathPayloadWhenCompressionFlagsArePresentButPayloadIsPlain() throws {
    let pdu = try RDPFastPathOutputPDU.parse(fastPathPacket([
        fastPathUpdate(
            code: 0x8,
            compressionFlags: 0x00,
            payload: Data([0x34, 0x12, 0x78, 0x56])
        ),
        fastPathUpdate(
            code: 0x4,
            compressionFlags: 0x00,
            payload: surfaceFrameMarker(action: 0, frameID: 7)
        ),
    ]))

    #expect(pdu.updates[0].pointerUpdate == .position(RDPPoint16(x: 0x1234, y: 0x5678)))
    #expect(pdu.updates[1].surfaceCommands?.map(\.typeName) == ["surface-frame-marker"])
    #expect(pdu.summaries.allSatisfy { !$0.compressed })
}

@Test func leavesCompressedFastPathPayloadOpaque() throws {
    let pdu = try RDPFastPathOutputPDU.parse(fastPathPacket([
        fastPathUpdate(
            code: 0x4,
            compressionFlags: 0x20,
            payload: Data([0xFF])
        ),
    ]))

    #expect(pdu.updates[0].surfaceCommands == nil)
    #expect(pdu.summaries[0].compressed)
}

@Test func acceptsFlushedCompressedFastPathPayloadAsOpaque() throws {
    let pdu = try RDPFastPathOutputPDU.parse(fastPathPacket([
        fastPathUpdate(
            code: 0x4,
            compressionFlags: 0xA0,
            payload: Data([0xFF])
        ),
    ]))

    #expect(pdu.updates[0].compressionFlags == 0xA0)
    #expect(pdu.updates[0].surfaceCommands == nil)
    #expect(pdu.summaries[0].compressed)
}

@Test func acceptsFragmentedFastPathSurfaceCommandsWithoutPayloadParsing() throws {
    let pdu = try RDPFastPathOutputPDU.parse(fastPathPacket([
        fastPathUpdate(code: 0x4, fragmentation: 0x2, payload: Data([0x01, 0x00])),
        fastPathUpdate(code: 0x4, fragmentation: 0x1, payload: Data([0x00])),
    ]))

    #expect(pdu.updates.map(\.fragmentation) == [.first, .last])
    #expect(pdu.updates[0].surfaceCommands == nil)
    #expect(pdu.updates[1].surfaceCommands == nil)
    #expect(pdu.summaries.map(\.fragmentation) == ["first", "last"])
    #expect(pdu.summaries.allSatisfy { $0.surfaceCommandTypeNames == nil })
}

@Test func reassemblesFragmentedFastPathSurfaceCommands() throws {
    let payload = surfaceFrameMarker(action: 0, frameID: 0x0102_0304)
    let pdu = try RDPFastPathOutputPDU.parse(fastPathPacket([
        fastPathUpdate(code: 0x4, fragmentation: 0x2, payload: Data(payload.prefix(3))),
        fastPathUpdate(code: 0x4, fragmentation: 0x3, payload: Data(payload.dropFirst(3).prefix(2))),
        fastPathUpdate(code: 0x4, fragmentation: 0x1, payload: Data(payload.dropFirst(5))),
    ]))
    var reassembler = RDPFastPathOutputFragmentReassembler()

    let first = try reassembler.append(pdu.updates[0])
    let next = try reassembler.append(pdu.updates[1])
    let reassembled = try #require(try reassembler.append(pdu.updates[2]))

    #expect(first == nil)
    #expect(next == nil)
    #expect(reassembler.isActive == false)
    #expect(reassembled.fragmentation == .single)
    #expect(reassembled.surfaceCommands?.map(\.typeName) == ["surface-frame-marker"])
}

@Test func reassemblesFragmentedFastPathUpdateWhenCompressionFlagsChange() throws {
    let pdu = try RDPFastPathOutputPDU.parse(fastPathPacket([
        fastPathUpdate(code: 0x4, fragmentation: 0x2, compressionFlags: 0x80, payload: Data([0x01])),
        fastPathUpdate(code: 0x4, fragmentation: 0x1, compressionFlags: 0x20, payload: Data([0x02])),
    ]))
    var reassembler = RDPFastPathOutputFragmentReassembler()

    #expect(try reassembler.append(pdu.updates[0]) == nil)
    let reassembled = try #require(try reassembler.append(pdu.updates[1]))

    #expect(reassembled.compressionFlags == 0xA0)
    #expect(reassembled.updateData == Data([0x01, 0x02]))
    #expect(reassembled.isCompressedPayload)
}

@Test func rejectsInvalidFastPathFragmentSequence() throws {
    let pdu = try RDPFastPathOutputPDU.parse(fastPathPacket([
        fastPathUpdate(code: 0x4, fragmentation: 0x1, payload: Data([0x00])),
    ]))
    var reassembler = RDPFastPathOutputFragmentReassembler()

    #expect(throws: RDPDecodeError.invalidFastPathOutputPDU) {
        _ = try reassembler.append(pdu.updates[0])
    }
}

@Test func rejectsFastPathFragmentSequenceWithMixedCompressionPresence() throws {
    let pdu = try RDPFastPathOutputPDU.parse(fastPathPacket([
        fastPathUpdate(code: 0x4, fragmentation: 0x2, compressionFlags: 0x20, payload: Data([0x01])),
        fastPathUpdate(code: 0x4, fragmentation: 0x1, payload: Data([0x02])),
    ]))
    var reassembler = RDPFastPathOutputFragmentReassembler()

    #expect(try reassembler.append(pdu.updates[0]) == nil)
    #expect(throws: RDPDecodeError.invalidFastPathOutputPDU) {
        _ = try reassembler.append(pdu.updates[1])
    }
}

@Test func rejectsFastPathFragmentThatExceedsAdvertisedBufferSize() throws {
    let pdu = try RDPFastPathOutputPDU.parse(fastPathPacket([
        fastPathUpdate(code: 0x4, fragmentation: 0x2, payload: Data(repeating: 0, count: 5)),
    ]))
    var reassembler = RDPFastPathOutputFragmentReassembler(maximumBufferedByteCount: 4)

    #expect(throws: RDPDecodeError.invalidFastPathOutputPDU) {
        _ = try reassembler.append(pdu.updates[0])
    }
    #expect(reassembler.isActive == false)
}

@Test func rejectsFastPathFragmentSequenceThatExceedsAdvertisedBufferSize() throws {
    let pdu = try RDPFastPathOutputPDU.parse(fastPathPacket([
        fastPathUpdate(code: 0x4, fragmentation: 0x2, payload: Data([0x01, 0x00, 0x00])),
        fastPathUpdate(code: 0x4, fragmentation: 0x1, payload: Data([0x00, 0x00])),
    ]))
    var reassembler = RDPFastPathOutputFragmentReassembler(maximumBufferedByteCount: 4)

    #expect(try reassembler.append(pdu.updates[0]) == nil)
    #expect(throws: RDPDecodeError.invalidFastPathOutputPDU) {
        _ = try reassembler.append(pdu.updates[1])
    }
    #expect(reassembler.isActive == false)
}

@Test func parsesEncryptedFastPathPacketWithoutDecodingCiphertext() throws {
    let packet = encryptedFastPathPacket(
        signature: Data([0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17]),
        payload: Data([0xFF, 0xEE, 0xDD])
    )

    let pdu = try RDPFastPathOutputPDU.parse(packet)

    #expect(pdu.flags == [.encrypted])
    #expect(pdu.dataSignature == Data([0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17]))
    #expect(pdu.encryptedPayload == Data([0xFF, 0xEE, 0xDD]))
    #expect(pdu.updates.isEmpty)
    #expect(pdu.summaries == [
        RDPFastPathUpdateSummary(
            typeName: "fastpath-encrypted",
            fragmentation: nil,
            compressed: false,
            byteCount: 3,
            pointerTypeName: nil
        ),
    ])
}

@Test func rejectsFastPathPacketWithReservedOutputHeaderBits() throws {
    #expect(throws: RDPDecodeError.invalidFastPathOutputPDU) {
        _ = try RDPFastPathOutputPDU.parse(Data([0x04, 0x03, 0x03, 0x00, 0x00]))
    }
}

@Test func rejectsFastPathSecureChecksumWithoutEncryption() throws {
    #expect(throws: RDPDecodeError.invalidFastPathOutputPDU) {
        _ = try RDPFastPathOutputPDU.parse(Data([0x40, 0x03, 0x03]))
    }
}

@Test func rejectsFastPathPacketWithDeclaredLengthMismatch() throws {
    #expect(throws: RDPDecodeError.invalidFastPathOutputPDU) {
        _ = try RDPFastPathOutputPDU.parse(Data([0x00, 0x04, 0x03, 0x00, 0x00]))
    }
}

@Test func rejectsFastPathUpdateWithReservedCompressionValue() throws {
    #expect(throws: RDPDecodeError.invalidFastPathOutputPDU) {
        _ = try RDPFastPathOutputPDU.parse(fastPathPacket(Data([0x43, 0x00, 0x00])))
    }
}

@Test func rejectsFastPathUpdateWithInvalidCompressionFlags() throws {
    #expect(throws: RDPDecodeError.invalidFastPathOutputPDU) {
        _ = try RDPFastPathOutputPDU.parse(fastPathPacket([
            fastPathUpdate(code: 0x8, compressionFlags: 0x04, payload: Data([0, 0, 0, 0])),
        ]))
    }
    #expect(throws: RDPDecodeError.invalidFastPathOutputPDU) {
        _ = try RDPFastPathOutputPDU.parse(fastPathPacket([
            fastPathUpdate(code: 0x8, compressionFlags: 0x40, payload: Data([0, 0, 0, 0])),
        ]))
    }
    #expect(throws: RDPDecodeError.invalidFastPathOutputPDU) {
        _ = try RDPFastPathOutputPDU.parse(fastPathPacket([
            fastPathUpdate(code: 0x8, compressionFlags: 0x10, payload: Data([0, 0, 0, 0])),
        ]))
    }
}

@Test func rejectsFastPathSynchronizeUpdateWithPayload() throws {
    #expect(throws: RDPDecodeError.invalidFastPathOutputPDU) {
        _ = try RDPFastPathOutputPDU.parse(fastPathPacket([
            fastPathUpdate(code: 0x3, payload: Data([0x00])),
        ]))
    }
}

@Test func rejectsFastPathPointerPositionWithBadLength() throws {
    #expect(throws: RDPDecodeError.invalidFastPathOutputPDU) {
        _ = try RDPFastPathOutputPDU.parse(fastPathPacket([
            fastPathUpdate(code: 0x8, payload: Data([0x00, 0x00])),
        ]))
    }
}

@Test func leavesMalformedFastPathLargePointerShapeOpaque() throws {
    var payload = largePointerPayload()
    payload[14] = 0x01

    let pdu = try RDPFastPathOutputPDU.parse(fastPathPacket([
        fastPathUpdate(code: 0xC, payload: payload),
    ]))

    #expect(pdu.updates[0].typeName == "fastpath-pointer-large")
    #expect(pdu.updates[0].pointerUpdate == nil)
    #expect(pdu.summaries[0].pointerTypeName == nil)
}

private func fastPathPacket(_ updates: [Data]) -> Data {
    fastPathPacket(updates.reduce(into: Data()) { $0.append($1) })
}

private func fastPathPacket(_ updates: Data) -> Data {
    let length = 1 + (updates.count + 2 < 0x80 ? 1 : 2) + updates.count
    var data = Data()
    data.appendUInt8(0x00)
    if length < 0x80 {
        data.appendUInt8(UInt8(length))
    } else {
        data.appendUInt8(0x80 | UInt8((length >> 8) & 0x7F))
        data.appendUInt8(UInt8(length & 0xFF))
    }
    data.append(updates)
    return data
}

private func encryptedFastPathPacket(signature: Data, payload: Data) -> Data {
    var data = Data()
    data.appendUInt8(0x80)
    data.appendUInt8(UInt8(2 + signature.count + payload.count))
    data.append(signature)
    data.append(payload)
    return data
}

private func newPointerPayload(xorBitsPerPixel: UInt16) -> Data {
    var data = Data()
    data.appendLittleEndianUInt16(xorBitsPerPixel)
    data.appendLittleEndianUInt16(3)
    data.appendLittleEndianUInt16(0)
    data.appendLittleEndianUInt16(0)
    data.appendLittleEndianUInt16(7)
    data.appendLittleEndianUInt16(2)
    data.appendLittleEndianUInt16(4)
    data.appendLittleEndianUInt16(4)
    data.append(Data([0xaa, 0x00, 0xbb, 0x00]))
    data.append(Data([0xcc, 0x00, 0xdd, 0x00]))
    return data
}

private func largePointerPayload() -> Data {
    var data = Data()
    data.appendLittleEndianUInt16(32)
    data.appendLittleEndianUInt16(4)
    data.appendLittleEndianUInt16(1)
    data.appendLittleEndianUInt16(2)
    data.appendLittleEndianUInt16(97)
    data.appendLittleEndianUInt16(1)
    data.appendLittleEndianUInt32(14)
    data.appendLittleEndianUInt32(388)
    data.append(Data(repeating: 0xaa, count: 388))
    data.append(Data(repeating: 0x55, count: 14))
    return data
}

private func surfaceFrameMarker(action: UInt16, frameID: UInt32) -> Data {
    var data = Data()
    data.appendLittleEndianUInt16(0x0004)
    data.appendLittleEndianUInt16(action)
    data.appendLittleEndianUInt32(frameID)
    return data
}

private func fastPathUpdate(
    code: UInt8,
    fragmentation: UInt8 = 0,
    compressionFlags: UInt8? = nil,
    payload: Data
) -> Data {
    var data = Data()
    var header = code | (fragmentation << 4)
    if compressionFlags != nil {
        header |= 0x80
    }
    data.appendUInt8(header)
    if let compressionFlags {
        data.appendUInt8(compressionFlags)
    }
    data.appendLittleEndianUInt16(UInt16(payload.count))
    data.append(payload)
    return data
}
