import Foundation
@testable import RDPKit
import Testing

@Test func decodesInterleavedRLEColorImageAndForegroundBackgroundImage() throws {
    // First row: a regular color image with four literal 16-bpp pixels.
    // Second row: set foreground to 0x00FF, then XOR pixels 0 and 2.
    let stream = Data([
        0x84,
        0x01, 0x00,
        0x02, 0x00,
        0x03, 0x00,
        0x04, 0x00,
        0xD0, 0x03,
        0xFF, 0x00,
        0x05,
    ])

    let decoded = try RDPInterleavedBitmapDecoder.decode(
        stream,
        width: 4,
        height: 2,
        bitsPerPixel: 16
    )

    #expect(decoded == Data([
        0x01, 0x00,
        0x02, 0x00,
        0x03, 0x00,
        0x04, 0x00,
        0xFE, 0x00,
        0x02, 0x00,
        0xFC, 0x00,
        0x04, 0x00,
    ]))
}

@Test func decodesAllInterleavedRLERunFamilies() throws {
    let stream = Data([
        0x64, 0x11, // regular color run: four 0x11 pixels
        0xC2, 0x22, // lite set-foreground run: two 0x22 pixels
        0xE1, 0x33, 0x44, // lite dithered run: one pixel pair
        0xF9, // special FGBG mask 0x03: eight pixels
        0xFD, // white
        0xFE, // black
    ])

    let decoded = try RDPInterleavedBitmapDecoder.decode(
        stream,
        width: 18,
        height: 1,
        bitsPerPixel: 8
    )

    #expect(decoded == Data([
        0x11, 0x11, 0x11, 0x11,
        0x22, 0x22,
        0x33, 0x44,
        0x22, 0x22, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0xFF, 0x00,
    ]))
}

@Test func decodesConsecutiveBackgroundRunsWithInsertedForegroundPixel() throws {
    let decoded = try RDPInterleavedBitmapDecoder.decode(
        Data([0x03, 0x03]),
        width: 6,
        height: 1,
        bitsPerPixel: 8
    )

    #expect(decoded == Data([0x00, 0x00, 0x00, 0xFF, 0x00, 0x00]))
}

@Test func decodesMegaMegaInterleavedRLEOrders() throws {
    let decoded = try RDPInterleavedBitmapDecoder.decode(
        Data([
            0xF3, 0x02, 0x00, 0x34, 0x12,
            0xF4, 0x02, 0x00, 0x78, 0x56, 0xBC, 0x9A,
        ]),
        width: 4,
        height: 1,
        bitsPerPixel: 16
    )

    #expect(decoded == Data([
        0x34, 0x12, 0x34, 0x12,
        0x78, 0x56, 0xBC, 0x9A,
    ]))
}

@Test func rejectsMalformedInterleavedRLEStreams() {
    #expect(throws: RDPDecodeError.invalidGraphicsUpdatePDU) {
        try RDPInterleavedBitmapDecoder.decode(Data([0x64]), width: 4, height: 1, bitsPerPixel: 8)
    }
    #expect(throws: RDPDecodeError.invalidGraphicsUpdatePDU) {
        try RDPInterleavedBitmapDecoder.decode(Data([0x65, 0x01]), width: 4, height: 1, bitsPerPixel: 8)
    }
    #expect(throws: RDPDecodeError.invalidGraphicsUpdatePDU) {
        try RDPInterleavedBitmapDecoder.decode(Data([0xFB]), width: 1, height: 1, bitsPerPixel: 8)
    }
    #expect(throws: RDPDecodeError.invalidGraphicsUpdatePDU) {
        try RDPInterleavedBitmapDecoder.decode(Data([0xFE]), width: 1, height: 1, bitsPerPixel: 32)
    }
}
