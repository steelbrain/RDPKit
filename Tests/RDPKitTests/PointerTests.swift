import Foundation
@testable import RDPKit
import Testing

@Test func parsesPointerPositionUpdate() throws {
    let update = try RDPServerPointerUpdate.parsePayload(Data([
        0x03, 0x00, 0x00, 0x00,
        0x34, 0x12, 0x56, 0x00,
    ]))

    #expect(update == .position(RDPPoint16(x: 0x1234, y: 0x0056)))
    #expect(update.typeName == "pointer-position")
}

@Test func parsesSystemPointerUpdates() throws {
    let hidden = try RDPServerPointerUpdate.parsePayload(Data([
        0x01, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
    ]))
    let systemDefault = try RDPServerPointerUpdate.parsePayload(Data([
        0x01, 0x00, 0x00, 0x00,
        0x00, 0x7f, 0x00, 0x00,
    ]))

    #expect(hidden == .system(type: 0x0000_0000))
    #expect(hidden.typeName == "pointer-system-hidden")
    #expect(systemDefault == .system(type: 0x0000_7F00))
    #expect(systemDefault.typeName == "pointer-system-default")
}

@Test func parsesColorPointerUpdateWithOptionalPad() throws {
    let update = try RDPServerPointerUpdate.parsePayload(Data([
        0x06, 0x00, 0x00, 0x00,
        0x02, 0x00,
        0x01, 0x00, 0x03, 0x00,
        0x02, 0x00,
        0x02, 0x00,
        0x04, 0x00,
        0x0c, 0x00,
        0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff,
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06,
        0x11, 0x22, 0x33, 0x44,
        0x00,
    ]))

    #expect(update == .color(RDPColorPointerAttribute(
        cacheIndex: 2,
        hotSpot: RDPPoint16(x: 1, y: 3),
        width: 2,
        height: 2,
        xorMaskData: Data([0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06]),
        andMaskData: Data([0x11, 0x22, 0x33, 0x44])
    )))
}

@Test func parsesNewPointerUpdate() throws {
    let update = try RDPServerPointerUpdate.parsePayload(Data([
        0x08, 0x00, 0x00, 0x00,
        0x20, 0x00,
        0x03, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x01, 0x00,
        0x01, 0x00,
        0x02, 0x00,
        0x04, 0x00,
        0x01, 0x02, 0x03, 0x04,
        0xff, 0x00,
    ]))

    #expect(update == .pointer(RDPNewPointerAttribute(
        xorBitsPerPixel: 32,
        colorPointer: RDPColorPointerAttribute(
            cacheIndex: 3,
            hotSpot: RDPPoint16(x: 0, y: 0),
            width: 1,
            height: 1,
            xorMaskData: Data([0x01, 0x02, 0x03, 0x04]),
            andMaskData: Data([0xff, 0x00])
        )
    )))
    #expect(update.typeName == "pointer-new")
}

@Test func parsesNewPointerUpdateWithPackedOneBitXorMask() throws {
    let update = try RDPServerPointerUpdate.parsePayload(Data([
        0x08, 0x00, 0x00, 0x00,
        0x01, 0x00,
        0x03, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x07, 0x00,
        0x02, 0x00,
        0x04, 0x00,
        0x04, 0x00,
        0xaa, 0x00, 0xbb, 0x00,
        0xcc, 0x00, 0xdd, 0x00,
    ]))

    guard case let .pointer(pointer) = update else {
        Issue.record("Expected new pointer update")
        return
    }
    #expect(pointer.xorBitsPerPixel == 1)
    #expect(pointer.colorPointer.width == 7)
    #expect(pointer.colorPointer.height == 2)
    #expect(pointer.colorPointer.xorMaskData == Data([0xaa, 0x00, 0xbb, 0x00]))
    #expect(pointer.colorPointer.andMaskData == Data([0xcc, 0x00, 0xdd, 0x00]))
}

@Test func parsesCachedPointerUpdate() throws {
    let update = try RDPServerPointerUpdate.parsePayload(Data([
        0x07, 0x00, 0x00, 0x00,
        0x19, 0x00,
    ]))

    #expect(update == .cached(cacheIndex: 25))
    #expect(update.typeName == "pointer-cached")
}

@Test func parsesPointerUpdateFromShareDataPDU() throws {
    let shareData = try #require(try RDPShareDataPDU.parseIfPresent(fromTPKT: shareDataPacket(
        type: 0x1B,
        payload: Data([
            0x03, 0x00, 0x00, 0x00,
            0x01, 0x00, 0x02, 0x00,
        ])
    )))

    #expect(try RDPServerPointerUpdate.parseIfPresent(from: shareData) == .position(RDPPoint16(x: 1, y: 2)))
    #expect(shareData.pointerUpdate == .position(RDPPoint16(x: 1, y: 2)))
}

@Test func resolvesPointerStateAndCachedImages() throws {
    let state = RDPRemotePointerState()
    let image = RDPColorPointerAttribute(
        cacheIndex: 2,
        hotSpot: RDPPoint16(x: 1, y: 3),
        width: 2,
        height: 1,
        xorMaskData: Data([0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff]),
        andMaskData: Data([0x11, 0x22])
    )
    let expected = RDPRemotePointerImage(
        cacheIndex: 2,
        hotSpot: RDPRemotePoint(x: 1, y: 3),
        width: 2,
        height: 1,
        xorBitsPerPixel: 24,
        xorMaskData: image.xorMaskData,
        andMaskData: image.andMaskData
    )

    #expect(try state.apply(.position(RDPPoint16(x: 8, y: 9))) == .position(RDPRemotePoint(x: 8, y: 9)))
    #expect(try state.apply(.system(type: 0)) == .hidden)
    #expect(try state.apply(.system(type: 0x0000_7F00)) == .systemDefault)
    #expect(try state.apply(.color(image)) == .image(expected))
    #expect(try state.apply(.cached(cacheIndex: 2)) == .cachedImage(expected))
}

@Test func pointerStateCachesNewAndLargePointerImages() throws {
    let state = RDPRemotePointerState()
    let first = RDPNewPointerAttribute(
        xorBitsPerPixel: 32,
        colorPointer: pointerAttribute(cacheIndex: 3, marker: 0x11)
    )
    let replacement = RDPNewPointerAttribute(
        xorBitsPerPixel: 16,
        colorPointer: pointerAttribute(cacheIndex: 3, marker: 0x22)
    )

    guard case let .image(firstImage) = try state.apply(.pointer(first)) else {
        Issue.record("Expected a resolved pointer image")
        return
    }
    #expect(firstImage.xorBitsPerPixel == 32)
    #expect(try state.apply(.cached(cacheIndex: 3)) == .cachedImage(firstImage))

    guard case let .image(replacementImage) = try state.apply(.largePointer(replacement)) else {
        Issue.record("Expected a resolved large pointer image")
        return
    }
    #expect(replacementImage.xorBitsPerPixel == 16)
    #expect(replacementImage.xorMaskData == Data([0x22, 0x22]))
    #expect(try state.apply(.cached(cacheIndex: 3)) == .cachedImage(replacementImage))
}

@Test func pointerStateHandlesCacheReferencesAndRejectsOutOfRangeIndices() throws {
    let state = RDPRemotePointerState()

    #expect(try state.apply(.cached(cacheIndex: 0)) == .unresolvedCachedImage(cacheIndex: 0))
    #expect(throws: RDPDecodeError.invalidPointerPDU) {
        try state.apply(.color(pointerAttribute(cacheIndex: 32, marker: 0x11)))
    }
    #expect(throws: RDPDecodeError.invalidPointerPDU) {
        try state.apply(.cached(cacheIndex: 32))
    }
}

@Test func rejectsInvalidPointerUpdates() {
    #expect(throws: RDPDecodeError.invalidPointerPDU) {
        try RDPServerPointerUpdate.parsePayload(Data([0x02, 0x00, 0x00, 0x00]))
    }
    #expect(throws: RDPDecodeError.invalidPointerPDU) {
        try RDPServerPointerUpdate.parsePayload(Data([
            0x01, 0x00, 0x00, 0x00,
            0x01, 0x00, 0x00, 0x00,
        ]))
    }
    #expect(throws: RDPDecodeError.invalidPointerPDU) {
        try RDPServerPointerUpdate.parsePayload(Data([
            0x06, 0x00, 0x00, 0x00,
            0x02, 0x00,
            0x01, 0x00, 0x03, 0x00,
            0x02, 0x00,
            0x02, 0x00,
            0x02, 0x00,
            0x06, 0x00,
            0xaa, 0xbb, 0xcc, 0xdd,
        ]))
    }
    #expect(throws: RDPDecodeError.invalidPointerPDU) {
        try RDPServerPointerUpdate.parsePayload(Data([
            0x06, 0x00, 0x00, 0x00,
            0x02, 0x00,
            0x01, 0x00, 0x03, 0x00,
            0x02, 0x00,
            0x02, 0x00,
            0x02, 0x00,
            0x06, 0x00,
            0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff,
            0x11, 0x22,
        ]))
    }
    #expect(throws: RDPDecodeError.invalidPointerPDU) {
        var oversizedColor = Data([
            0x06, 0x00, 0x00, 0x00,
            0x02, 0x00,
            0x00, 0x00, 0x00, 0x00,
            0x61, 0x00,
            0x01, 0x00,
            0x0e, 0x00,
            0x24, 0x01,
        ])
        oversizedColor.append(Data(repeating: 0, count: 292))
        _ = try RDPServerPointerUpdate.parsePayload(oversizedColor)
    }
    #expect(throws: RDPDecodeError.invalidPointerPDU) {
        try RDPServerPointerUpdate.parsePayload(Data([
            0x08, 0x00, 0x00, 0x00,
            0x00, 0x00,
            0x03, 0x00,
            0x00, 0x00, 0x00, 0x00,
            0x01, 0x00,
            0x01, 0x00,
            0x02, 0x00,
            0x00, 0x00,
            0xff, 0x00,
        ]))
    }
    #expect(throws: RDPDecodeError.invalidPointerPDU) {
        var oversizedNewPointer = Data([
            0x08, 0x00, 0x00, 0x00,
            0x20, 0x00,
            0x03, 0x00,
            0x00, 0x00, 0x00, 0x00,
            0x01, 0x00,
            0x61, 0x00,
            0xc2, 0x00,
            0x84, 0x01,
        ])
        oversizedNewPointer.append(Data(repeating: 0, count: 582))
        _ = try RDPServerPointerUpdate.parsePayload(oversizedNewPointer)
    }
    #expect(throws: RDPDecodeError.invalidPointerPDU) {
        try RDPShareDataPDU.parseIfPresent(fromTPKT: shareDataPacket(
            type: 0x1B,
            payload: Data([0x02, 0x00, 0x00, 0x00])
        ))
    }
}

private func shareDataPacket(type: UInt8, payload: Data) -> Data {
    var userData = Data()
    userData.appendLittleEndianUInt16(UInt16(18 + payload.count))
    userData.appendLittleEndianUInt16(0x0017)
    userData.appendLittleEndianUInt16(1005)
    userData.appendLittleEndianUInt32(0x0001_0000)
    userData.appendUInt8(0)
    userData.appendUInt8(1)
    userData.appendLittleEndianUInt16(UInt16(payload.count + 4))
    userData.appendUInt8(type)
    userData.appendUInt8(0)
    userData.appendLittleEndianUInt16(0)
    userData.append(payload)
    return mcsSendDataIndication(channelID: 1003, userData: userData)
}

private func pointerAttribute(cacheIndex: UInt16, marker: UInt8) -> RDPColorPointerAttribute {
    RDPColorPointerAttribute(
        cacheIndex: cacheIndex,
        hotSpot: RDPPoint16(x: 0, y: 0),
        width: 1,
        height: 1,
        xorMaskData: Data([marker, marker]),
        andMaskData: Data([0xff, 0x00])
    )
}

private func mcsSendDataIndication(channelID: UInt16, userData: Data) -> Data {
    var data = Data()
    data.appendUInt8(0x68)
    data.appendBigEndianUInt16(1005 - 1001)
    data.appendBigEndianUInt16(channelID)
    data.appendUInt8(0x70)
    data.appendPERLength(userData.count)
    data.append(userData)
    return X224DataTPDU.wrap(data)
}
