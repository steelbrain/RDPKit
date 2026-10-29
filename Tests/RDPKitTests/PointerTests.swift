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

    #expect(shareData.pointerUpdate == .position(RDPPoint16(x: 1, y: 2)))
}

@Test func resolvesPointerStateAndCachedImages() throws {
    let state = RDPRemotePointerState()
    let image = RDPColorPointerAttribute(
        cacheIndex: 2,
        hotSpot: RDPPoint16(x: 1, y: 0),
        width: 2,
        height: 1,
        xorMaskData: Data([0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff]),
        andMaskData: Data([0x11, 0x22])
    )
    let expected = RDPRemotePointerImage(
        cacheIndex: 2,
        hotSpot: RDPRemotePoint(x: 1, y: 0),
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

@Test func pointerStateClampsHotSpotOntoPointerImage() throws {
    let state = RDPRemotePointerState()
    var attribute = pointerAttribute(cacheIndex: 1, marker: 0x11)
    attribute.hotSpot = RDPPoint16(x: 5, y: 9)

    guard case let .image(image) = try state.apply(.pointer(RDPNewPointerAttribute(
        xorBitsPerPixel: 16,
        colorPointer: attribute
    ))) else {
        Issue.record("Expected a resolved pointer image")
        return
    }
    #expect(image.hotSpot == RDPRemotePoint(x: 0, y: 0))
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

@Test func decodesKRDPFastPathNewPointerWithoutAndMask() throws {
    let url = try #require(Bundle.module.url(
        forResource: "krdp-negotiation-transcript",
        withExtension: "json",
        subdirectory: "Fixtures"
    ))
    let events = try JSONDecoder().decode([RDPWireEvent].self, from: Data(contentsOf: url))
    let newPointerBytes = try #require(events.first { $0.sequence == 36 }?.bytes)
    let cachedPointerBytes = try #require(events.first { $0.sequence == 37 }?.bytes)

    let newPointer = try RDPFastPathOutputPDU.parse(newPointerBytes)
    let cachedPointer = try RDPFastPathOutputPDU.parse(cachedPointerBytes)
    guard case let .pointer(pointer) = try #require(newPointer.updates.first?.pointerUpdate) else {
        Issue.record("Expected a fast-path new pointer")
        return
    }
    #expect(pointer.xorBitsPerPixel == 32)
    #expect(pointer.colorPointer.width == 46)
    #expect(pointer.colorPointer.height == 46)
    #expect(pointer.colorPointer.hotSpot == RDPPoint16(x: 7, y: 3))
    #expect(pointer.colorPointer.xorMaskData.count == 46 * 46 * 4)
    #expect(pointer.colorPointer.andMaskData.isEmpty)

    let state = RDPRemotePointerState()
    guard case let .image(image) = try state.apply(.pointer(pointer)) else {
        Issue.record("Expected a resolved pointer image")
        return
    }
    let cachedUpdate = try #require(cachedPointer.updates.first?.pointerUpdate)
    #expect(try state.apply(cachedUpdate) == .cachedImage(image))
}

@Test func rejectsMissingAndMaskBelowThirtyTwoBitsPerPixel() {
    var cursor = ByteCursor(Data([
        0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x01, 0x00,
        0x01, 0x00,
        0x00, 0x00,
        0x04, 0x00,
        0x01, 0x02, 0x03, 0x00,
    ]))

    #expect(throws: RDPDecodeError.invalidPointerPDU) {
        try RDPColorPointerAttribute.parse(from: &cursor)
    }
}

@Test func rejectsInvalidPointerUpdates() throws {
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
    let malformed = try RDPShareDataPDU.parseIfPresent(fromTPKT: shareDataPacket(
        type: 0x1B,
        payload: Data([0x02, 0x00, 0x00, 0x00])
    ))
    #expect(malformed?.pointerUpdate == nil)
    #expect(malformed?.pointerDecodeError == .invalidPointerPDU)
}

@Test func pointerBitmapDecodesOneBitMasksTopDown() throws {
    // Rows from the top: black, white, transparent; transparent, transparent, white. Unlike
    // other depths, the first scan-line is the top one, as rdesktop and FreeRDP read it.
    // Each scan-line is padded to 2 bytes; the unused bits and the pad bytes are set.
    let bitmap = try #require(RDPRemotePointerBitmap(pointerImage(
        width: 3,
        height: 2,
        xorBitsPerPixel: 1,
        xorMask: [0x5f, 0xff, 0x3f, 0xff],
        andMask: [0x3f, 0xff, 0xdf, 0xff]
    )))

    #expect(bitmap.width == 3)
    #expect(bitmap.height == 2)
    #expect(bitmap.bytesPerRow == 12)
    #expect(bitmap.pixels == pointerPixels(black, white, clear, clear, clear, white))
}

@Test func pointerBitmapDecodesSixteenBitsAsRGB565() throws {
    // Rows from the top: red, green; grey, transparent.
    let bitmap = try #require(RDPRemotePointerBitmap(pointerImage(
        width: 2,
        height: 2,
        xorBitsPerPixel: 16,
        xorMask: [0x10, 0x84, 0x00, 0x00, 0x00, 0xf8, 0xe0, 0x07],
        andMask: [0x40, 0x00, 0x00, 0x00]
    )))

    #expect(bitmap.pixels == pointerPixels(
        [0xff, 0x00, 0x00, 0xff], [0x00, 0xff, 0x00, 0xff],
        [132, 130, 132, 0xff], clear
    ))
}

@Test func pointerBitmapDecodesTwentyFourBitsWithPaddedRows() throws {
    // 3 pixels of 3 bytes take 9 bytes, padded to 10 with 0xee.
    let bitmap = try #require(RDPRemotePointerBitmap(pointerImage(
        width: 3,
        height: 2,
        xorBitsPerPixel: 24,
        xorMask: [
            0x00, 0x00, 0x00, 0xc0, 0xb0, 0xa0, 0x00, 0x00, 0x00, 0xee,
            0x30, 0x20, 0x10, 0x60, 0x50, 0x40, 0x00, 0x00, 0x00, 0xee,
        ],
        andMask: [0x80, 0x00, 0x20, 0x00]
    )))

    #expect(bitmap.pixels == pointerPixels(
        [0x10, 0x20, 0x30, 0xff], [0x40, 0x50, 0x60, 0xff], clear,
        clear, [0xa0, 0xb0, 0xc0, 0xff], black
    ))
}

@Test func pointerBitmapPremultipliesThirtyTwoBitAlphaAndIgnoresAndMask() throws {
    // The half-transparent orange's red exceeds its alpha, so the colors are not premultiplied.
    // AND bits are set under the orange and both bottom pixels; with no alpha the white one
    // would invert the screen.
    let bitmap = try #require(RDPRemotePointerBitmap(pointerImage(
        width: 2,
        height: 2,
        xorBitsPerPixel: 32,
        xorMask: [
            0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0xff,
            0x00, 0x40, 0xff, 0x80, 0x10, 0x20, 0x30, 0x00,
        ],
        andMask: [0xc0, 0x00, 0x80, 0x00]
    )))

    #expect(bitmap.pixels == pointerPixels(
        [0x80, 0x20, 0x00, 0x80], clear,
        white, black
    ))
}

@Test func pointerBitmapKeepsPremultipliedThirtyTwoBitColors() throws {
    // No color exceeds its alpha, so the colors are already premultiplied, as Windows sends them.
    let bitmap = try #require(RDPRemotePointerBitmap(pointerImage(
        width: 2,
        height: 1,
        xorBitsPerPixel: 32,
        xorMask: [0x00, 0x20, 0x80, 0x80, 0x10, 0x10, 0x10, 0x40],
        andMask: [0xc0, 0x00]
    )))

    #expect(bitmap.pixels == pointerPixels([0x80, 0x20, 0x00, 0x80], [0x10, 0x10, 0x10, 0x40]))
}

@Test func pointerBitmapTakesThirtyTwoBitShapeFromAlphaWithoutAndMask() throws {
    let bitmap = try #require(RDPRemotePointerBitmap(pointerImage(
        width: 1,
        height: 2,
        xorBitsPerPixel: 32,
        xorMask: [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff, 0xff],
        andMask: []
    )))
    let invisible = try #require(RDPRemotePointerBitmap(pointerImage(
        width: 1,
        height: 1,
        xorBitsPerPixel: 32,
        xorMask: [0x10, 0x20, 0x30, 0x00],
        andMask: []
    )))

    #expect(bitmap.pixels == pointerPixels([0xff, 0x00, 0x00, 0xff], clear))
    #expect(invisible.pixels == pointerPixels(clear))
}

@Test func pointerBitmapCombinesThirtyTwoBitsWithoutAlphaWithAndMask() throws {
    // AND 1, 0, 1, 1: transparent, a color, transparent next to an inverting pixel, and
    // an inverting pixel whose XOR is not white.
    let bitmap = try #require(RDPRemotePointerBitmap(pointerImage(
        width: 4,
        height: 1,
        xorBitsPerPixel: 32,
        xorMask: [
            0x00, 0x00, 0x00, 0x00, 0x30, 0x20, 0x10, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x56, 0x34, 0x12, 0x00,
        ],
        andMask: [0xb0, 0x00]
    )))

    #expect(bitmap.pixels == pointerPixels(clear, [0x10, 0x20, 0x30, 0xff], white, black))
}

@Test func pointerBitmapDrawsInvertingPixelsBlackWithWhiteOutline() throws {
    // Rows from the top, with I inverting and B black:
    // . . . .      W W W .
    // . I . .  ->  W B W .
    // B . . .      B W W .
    let bitmap = try #require(RDPRemotePointerBitmap(pointerImage(
        width: 4,
        height: 3,
        xorBitsPerPixel: 1,
        xorMask: [0x00, 0x00, 0x40, 0x00, 0x00, 0x00],
        andMask: [0xf0, 0x00, 0xf0, 0x00, 0x70, 0x00]
    )))

    #expect(bitmap.pixels == pointerPixels(
        white, white, white, clear,
        white, black, white, clear,
        black, white, white, clear
    ))
}

@Test func pointerBitmapClampsHotSpotIntoImage() throws {
    let inside = try #require(RDPRemotePointerBitmap(pointerImage(
        width: 2,
        height: 2,
        xorBitsPerPixel: 1,
        xorMask: [0x00, 0x00, 0x00, 0x00],
        andMask: [0x00, 0x00, 0x00, 0x00],
        hotSpot: RDPRemotePoint(x: 1, y: 0)
    )))
    let outside = try #require(RDPRemotePointerBitmap(pointerImage(
        width: 2,
        height: 2,
        xorBitsPerPixel: 1,
        xorMask: [0x00, 0x00, 0x00, 0x00],
        andMask: [0x00, 0x00, 0x00, 0x00],
        hotSpot: RDPRemotePoint(x: 9, y: 7)
    )))

    #expect(inside.hotSpot == RDPRemotePoint(x: 1, y: 0))
    #expect(outside.hotSpot == RDPRemotePoint(x: 1, y: 1))
}

@Test func pointerBitmapRejectsMalformedImages() {
    // 2x2 at 24 bpp: 6-byte XOR rows and 2-byte AND rows.
    let xorMask = [UInt8](repeating: 0, count: 12)
    let andMask = [UInt8](repeating: 0, count: 4)
    let malformed = [
        pointerImage(width: 0, height: 2, xorBitsPerPixel: 24, xorMask: [], andMask: []),
        pointerImage(width: 2, height: 0, xorBitsPerPixel: 24, xorMask: [], andMask: []),
        pointerImage(width: 2, height: 2, xorBitsPerPixel: 24, xorMask: Array(xorMask.dropLast()), andMask: andMask),
        pointerImage(width: 2, height: 2, xorBitsPerPixel: 24, xorMask: xorMask + [0], andMask: andMask),
        pointerImage(width: 2, height: 2, xorBitsPerPixel: 24, xorMask: xorMask, andMask: Array(andMask.dropLast())),
        pointerImage(width: 2, height: 2, xorBitsPerPixel: 24, xorMask: xorMask, andMask: []),
        pointerImage(width: 2, height: 2, xorBitsPerPixel: 32, xorMask: xorMask, andMask: andMask),
        pointerImage(width: 2, height: 2, xorBitsPerPixel: 0, xorMask: [], andMask: andMask),
        // Palette and other depths, with masks of the right length.
        pointerImage(width: 2, height: 2, xorBitsPerPixel: 4, xorMask: andMask, andMask: andMask),
        pointerImage(width: 2, height: 2, xorBitsPerPixel: 8, xorMask: andMask, andMask: andMask),
        pointerImage(width: 2, height: 2, xorBitsPerPixel: 15, xorMask: Array(xorMask[..<8]), andMask: andMask),
    ]

    for image in malformed {
        #expect(RDPRemotePointerBitmap(image) == nil)
    }
}

@Test func pointerBitmapMakesPremultipliedCGImage() throws {
    let bitmap = try #require(RDPRemotePointerBitmap(pointerImage(
        width: 3,
        height: 2,
        xorBitsPerPixel: 1,
        xorMask: [0x20, 0x00, 0x40, 0x00],
        andMask: [0xc0, 0x00, 0x20, 0x00]
    )))
    let image = try #require(bitmap.cgImage)

    #expect(image.width == 3)
    #expect(image.height == 2)
    #expect(image.bytesPerRow == 12)
    #expect(image.bitsPerPixel == 32)
    #expect(image.alphaInfo == .premultipliedLast)
    #expect(image.dataProvider?.data as Data? == bitmap.pixels)
}

@Test func pointerBitmapDecodesKRDPAlphaPointer() throws {
    let url = try #require(Bundle.module.url(
        forResource: "krdp-negotiation-transcript",
        withExtension: "json",
        subdirectory: "Fixtures"
    ))
    let events = try JSONDecoder().decode([RDPWireEvent].self, from: Data(contentsOf: url))
    let newPointer = try RDPFastPathOutputPDU.parse(try #require(events.first { $0.sequence == 36 }?.bytes))
    let update = try #require(newPointer.updates.first?.pointerUpdate)
    guard case let .image(image) = try RDPRemotePointerState().apply(update) else {
        Issue.record("Expected a resolved pointer image")
        return
    }

    let bitmap = try #require(RDPRemotePointerBitmap(image))
    let pixels = [UInt8](bitmap.pixels)
    let alphas = stride(from: 3, to: pixels.count, by: 4).map { pixels[$0] }
    #expect(bitmap.width == 46)
    #expect(bitmap.height == 46)
    #expect(bitmap.hotSpot == RDPRemotePoint(x: 7, y: 3))
    // Some of KRdp's colors exceed their alpha, so they are not premultiplied; the bitmap's are.
    #expect(stride(from: 0, to: pixels.count, by: 4).allSatisfy {
        max(pixels[$0], pixels[$0 + 1], pixels[$0 + 2]) <= pixels[$0 + 3]
    })
    // Read bottom-up, the arrow starts at the top and its last 10 rows are empty.
    #expect(alphas[..<46].contains { $0 != 0 })
    #expect(alphas[(46 * 36)...].allSatisfy { $0 == 0 })
}

@Test func pointerBitmapDrawsWindowsPointersAsWindowsDoes() throws {
    // Over black and over white, each pointer matches Windows' own drawing of the cursor, except
    // where Windows XORs the screen: those pixels are black, and the transparent ones next to
    // them white.
    for pointer in try capturedPointers("windows-pointers") {
        let bitmap = try #require(RDPRemotePointerBitmap(pointer.image))
        let pixels = [UInt8](bitmap.pixels)
        let overBlack = try [UInt8](#require(pointer.drawnOverBlack))
        let overWhite = try [UInt8](#require(pointer.drawnOverWhite))
        // A pixel Windows draws darker over white than over black XORs the screen.
        let xors = (0 ..< pointer.width * pointer.height).map { index in
            (index * 3 ..< index * 3 + 3).contains { overWhite[$0] < overBlack[$0] }
        }
        #expect(bitmap.hotSpot == RDPRemotePoint(x: pointer.hotSpot[0], y: pointer.hotSpot[1]))
        for index in xors.indices {
            let ours = Array(pixels[index * 4 ..< index * 4 + 4])
            let windows = (overBlack[index * 3 ..< index * 3 + 3], overWhite[index * 3 ..< index * 3 + 3])
            if xors[index] {
                #expect(ours == black, "\(pointer.name) pixel \(index)")
            } else if ours == white, windows.0.allSatisfy({ $0 == 0 }), windows.1.allSatisfy({ $0 == 0xff }) {
                let (row, column) = index.quotientAndRemainder(dividingBy: pointer.width)
                #expect(
                    (max(row - 1, 0) ... min(row + 1, pointer.height - 1)).contains { neighborRow in
                        (max(column - 1, 0) ... min(column + 1, pointer.width - 1)).contains {
                            xors[neighborRow * pointer.width + $0]
                        }
                    },
                    "\(pointer.name) pixel \(index)"
                )
            } else {
                // Premultiplied colors drawn over black, then over white.
                #expect(Array(windows.0) == Array(ours[0 ..< 3]), "\(pointer.name) pixel \(index)")
                #expect(
                    windows.1.map(Int.init) == ours[0 ..< 3].map { Int($0) + 0xff - Int(ours[3]) },
                    "\(pointer.name) pixel \(index)"
                )
            }
        }
    }
}

@Test func pointerBitmapKeepsWindowsPremultipliedColors() throws {
    // The probe cursor's colors, which Windows holds not premultiplied, from the top: red at
    // alpha 128 at (0, 0), white at alpha 64 at (0, 16), opaque magenta under AND bits of 1
    // at (24, 0), and transparent black under AND bits of 0 at (24, 20).
    let probe = try #require(capturedPointers("windows-pointers").first { $0.name == "alpha-probe" })
    let pixels = try [UInt8](#require(RDPRemotePointerBitmap(probe.image)).pixels)
    func pixel(row: Int, column: Int) -> [UInt8] {
        Array(pixels[(row * probe.width + column) * 4 ..< (row * probe.width + column) * 4 + 4])
    }

    #expect(pixel(row: 0, column: 0) == [0x80, 0x00, 0x00, 0x80])
    #expect(pixel(row: 0, column: 16) == [0x40, 0x40, 0x40, 0x40])
    #expect(pixel(row: 24, column: 0) == [0xff, 0x00, 0xff, 0xff])
    #expect(pixel(row: 24, column: 20) == clear)
}

@Test func pointerBitmapKeepsGNOMEPremultipliedColors() throws {
    // gnome-remote-desktop 51.0's arrow has a white fill, yet no soft edge pixel's color exceeds
    // its alpha: the colors are premultiplied, so they pass through.
    let arrow = try #require(capturedPointers("gnome-pointers").first)
    let xorMask = [UInt8](arrow.xorMask)
    let pixels = try [UInt8](#require(RDPRemotePointerBitmap(arrow.image)).pixels)
    // The wire's blue, green, red and alpha bytes, bottom-up.
    var wirePixels: [UInt8] = []
    for row in (0 ..< arrow.height).reversed() {
        for pixel in stride(from: row * arrow.width * 4, to: (row + 1) * arrow.width * 4, by: 4) {
            wirePixels += [xorMask[pixel + 2], xorMask[pixel + 1], xorMask[pixel], xorMask[pixel + 3]]
        }
    }

    #expect(arrow.andMask.isEmpty)
    #expect(pixels == wirePixels)
}

/// Pointers captured from servers on 2026-10-29: `windows-pointers` from Windows 11 25H2 (build
/// 26200), each with Windows' own drawing of the cursor (DrawIconEx) over black and over white
/// as RGB rows from the top, and `gnome-pointers` from gnome-remote-desktop 51.0. Windows'
/// `-probe` pointers are test cursors: `monochrome-probe` made by CreateCursor, which arrives at
/// 24 bpp; `alpha-probe` with alpha; `color-probe` without alpha, with inverting and XOR-red
/// pixels.
private struct CapturedPointer: Decodable {
    var name: String
    var xorBitsPerPixel: UInt16
    var width: Int
    var height: Int
    var hotSpot: [UInt16]
    var xorMask: Data
    var andMask: Data
    var drawnOverBlack: Data?
    var drawnOverWhite: Data?

    var image: RDPRemotePointerImage {
        RDPRemotePointerImage(
            cacheIndex: 0,
            hotSpot: RDPRemotePoint(x: hotSpot[0], y: hotSpot[1]),
            width: UInt16(width),
            height: UInt16(height),
            xorBitsPerPixel: xorBitsPerPixel,
            xorMaskData: xorMask,
            andMaskData: andMask
        )
    }
}

private func capturedPointers(_ name: String) throws -> [CapturedPointer] {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try JSONDecoder().decode([CapturedPointer].self, from: Data(contentsOf: url))
}

private let black: [UInt8] = [0x00, 0x00, 0x00, 0xff]
private let white: [UInt8] = [0xff, 0xff, 0xff, 0xff]
private let clear: [UInt8] = [0x00, 0x00, 0x00, 0x00]

private func pointerPixels(_ pixels: [UInt8]...) -> Data {
    Data(pixels.flatMap { $0 })
}

private func pointerImage(
    width: UInt16,
    height: UInt16,
    xorBitsPerPixel: UInt16,
    xorMask: [UInt8],
    andMask: [UInt8],
    hotSpot: RDPRemotePoint = RDPRemotePoint(x: 0, y: 0)
) -> RDPRemotePointerImage {
    RDPRemotePointerImage(
        cacheIndex: 0,
        hotSpot: hotSpot,
        width: width,
        height: height,
        xorBitsPerPixel: xorBitsPerPixel,
        xorMaskData: Data(xorMask),
        andMaskData: Data(andMask)
    )
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
