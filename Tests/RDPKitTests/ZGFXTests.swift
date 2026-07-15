import Foundation
@testable import RDPKit
import Testing

@Test func decompressesMixedMultipartZGFXSegments() throws {
    let encoded = Data([
        0xE1,
        0x03, 0x00,
        0x2B, 0x00, 0x00, 0x00,
        0x11, 0x00, 0x00, 0x00,
        0x04,
        0x54, 0x68, 0x65, 0x20, 0x71, 0x75, 0x69, 0x63,
        0x6B, 0x20, 0x62, 0x72, 0x6F, 0x77, 0x6E, 0x20,
        0x0E, 0x00, 0x00, 0x00,
        0x04,
        0x66, 0x6F, 0x78, 0x20, 0x6A, 0x75, 0x6D, 0x70,
        0x73, 0x20, 0x6F, 0x76, 0x65,
        0x10, 0x00, 0x00, 0x00,
        0x24,
        0x39, 0x08, 0x0E, 0x91, 0xF8, 0xD8, 0x61, 0x3D,
        0x1E, 0x44, 0x06, 0x43, 0x79, 0x9C, 0x02,
    ])

    let decoded = try RDPZGFXDecompressor().decompress(encoded)

    #expect(String(decoding: decoded, as: UTF8.self) == "The quick brown fox jumps over the lazy dog")
}

@Test func decompressesSpecExampleCompressedLiteralAndMatchSegment() throws {
    let decoded = try RDPZGFXDecompressor().decompress(Data([
        0xE0,
        0x24,
        0xCE, 0x9B, 0x19, 0x62, 0x18,
        0x00,
    ]))

    #expect(decoded == Data([0x01, 0x02, 0xFF, 0x65, 0x65, 0x65, 0x65, 0x65]))
}

@Test func decompressesSpecExampleUnencodedSingleSegment() throws {
    let encoded = Data([
        0xE0,
        0x04,
        0x54, 0x68, 0x65, 0x20, 0x71, 0x75, 0x69, 0x63,
        0x6B, 0x20, 0x62, 0x72, 0x6F, 0x77, 0x6E, 0x20,
        0x66, 0x6F, 0x78, 0x20, 0x6A, 0x75, 0x6D, 0x70,
        0x73, 0x20, 0x6F, 0x76, 0x65, 0x72, 0x20, 0x74,
        0x68, 0x65, 0x20, 0x6C, 0x61, 0x7A, 0x79, 0x20,
        0x64, 0x6F, 0x67,
    ])

    let decoded = try RDPZGFXDecompressor().decompress(encoded)

    #expect(String(decoding: decoded, as: UTF8.self) == "The quick brown fox jumps over the lazy dog")
}

@Test func decompressesUnencodedRDP8LiteSingleSegment() throws {
    let decoded = try RDPZGFXDecompressor.rdp8Lite().decompress(Data([
        0xE0,
        0x06,
        0x64, 0x79, 0x6E, 0x76, 0x63,
    ]))

    #expect(String(decoding: decoded, as: UTF8.self) == "dynvc")
}

@Test func rejectsRDP8LiteHeaderInDefaultRDP8Profile() {
    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        try RDPZGFXDecompressor().decompress(Data([
            0xE0,
            0x06,
            0x64, 0x79, 0x6E, 0x76, 0x63,
        ]))
    }
}

@Test func rejectsRDP8HeaderInRDP8LiteProfile() {
    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        try RDPZGFXDecompressor.rdp8Lite().decompress(Data([
            0xE0,
            0x04,
            0x64, 0x79, 0x6E, 0x76, 0x63,
        ]))
    }
}

@Test func rejectsMultipartRDP8LiteData() {
    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        try RDPZGFXDecompressor.rdp8Lite().decompress(Data([
            0xE1,
            0x01, 0x00,
            0x01, 0x00, 0x00, 0x00,
            0x02, 0x00, 0x00, 0x00,
            0x06, 0x41,
        ]))
    }
}

@Test func decompressesSpecExampleOverlappingMatchSegment() throws {
    let decoded = try RDPZGFXDecompressor().decompress(Data([
        0xE0,
        0x24,
        0x20, 0x90, 0x88, 0x71, 0x1F, 0xB2,
        0x01,
    ]))

    #expect(String(decoding: decoded, as: UTF8.self) == String(repeating: "ABC", count: 20))
}

@Test func decompressesEmptyMultipartZGFXData() throws {
    let decoded = try RDPZGFXDecompressor().decompress(Data([
        0xE1,
        0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
    ]))

    #expect(decoded.isEmpty)
}

@Test func rejectsSingleZGFXDataWithoutBulkSegmentHeader() {
    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        try RDPZGFXDecompressor().decompress(Data([
            0xE0,
        ]))
    }
}

@Test func rejectsMultipartZGFXDataWithTrailingBytes() {
    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        try RDPZGFXDecompressor().decompress(Data([
            0xE1,
            0x01, 0x00,
            0x01, 0x00, 0x00, 0x00,
            0x02, 0x00, 0x00, 0x00,
            0x04, 0x41,
            0x00,
        ]))
    }
}

@Test func rejectsRDP8BulkEncodedDataWithReservedHeaderBits() {
    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        try RDPZGFXDecompressor().decompress(Data([
            0xE0,
            0x14,
            0x41,
        ]))
    }
    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        try RDPZGFXDecompressor().decompress(Data([
            0xE0,
            0x64,
            0x41,
            0x00,
        ]))
    }
}

@Test func rejectsCompressedRDP8BulkEncodedDataWithoutTrailer() {
    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        try RDPZGFXDecompressor().decompress(Data([
            0xE0,
            0x24,
        ]))
    }
}

@Test func rejectsZGFXSegmentAboveDecodedSizeLimit() {
    var uncompressed = Data([0xE0, 0x04])
    uncompressed.append(Data(repeating: 0, count: 65_536))

    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        try RDPZGFXDecompressor().decompress(uncompressed)
    }

    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        try RDPZGFXDecompressor().decompress(Data([
            0xE0, 0x24,
            0x20, 0xC4, 0x3F, 0xFF, 0xBF, 0xFF, 0x80,
            0x07,
        ]))
    }
}

@Test func acceptsZGFXSegmentAtDecodedSizeLimit() throws {
    let decoded = try RDPZGFXDecompressor().decompress(Data([
        0xE0, 0x24,
        0x20, 0xC4, 0x3F, 0xFF, 0xBF, 0xFF, 0x00,
        0x07,
    ]))

    #expect(decoded == Data(repeating: 0x41, count: 65_535))
}

@Test func rejectsRDP8LiteSegmentAboveDecodedSizeLimit() {
    var uncompressed = Data([0xE0, 0x06])
    uncompressed.append(Data(repeating: 0, count: 8_193))

    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        try RDPZGFXDecompressor.rdp8Lite().decompress(uncompressed)
    }

    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        try RDPZGFXDecompressor.rdp8Lite().decompress(Data([
            0xE0, 0x26,
            0x20, 0xC4, 0x3F, 0xFE, 0x00, 0x00,
            0x03,
        ]))
    }
}

@Test func acceptsRDP8LiteSegmentAtDecodedSizeLimit() throws {
    let decoded = try RDPZGFXDecompressor.rdp8Lite().decompress(Data([
        0xE0, 0x26,
        0x20, 0xC4, 0x3F, 0xFD, 0xFF, 0xE0,
        0x05,
    ]))

    #expect(decoded == Data(repeating: 0x41, count: 8_192))
}

@Test func rejectsReservedLongZGFXLiteralCode() {
    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        try RDPZGFXDecompressor().decompress(Data([
            0xE0, 0x24,
            0x00, 0x00,
            0x07,
        ]))
    }
}
