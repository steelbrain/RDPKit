import Foundation
@testable import RDPKit
import Testing

@Test func decodesRawRDP6ARGBPlanes() throws {
    let decoded = try RDP6BitmapDecoder.decode(
        Data([
            0x00,
            0x40, 0x80,
            0x11, 0x22,
            0x33, 0x44,
            0x55, 0x66,
            0x00,
        ]),
        width: 2,
        height: 1
    )

    #expect(decoded == Data([
        0x55, 0x33, 0x11, 0x40,
        0x66, 0x44, 0x22, 0x80,
    ]))
}

@Test func decodesRDP6RLEDeltaPlanesFromSpecificationExample() throws {
    let encodedPlane: [UInt8] = [
        0x13, 0xFF, 0x20, 0xFE, 0xFD,
        0x60, 0x01, 0x7D, 0xF5, 0xC2, 0x9A, 0x38,
        0x60, 0x01, 0x67, 0x8B, 0xA3, 0x78, 0xAF,
    ]
    let stream = Data([0x30] + encodedPlane + encodedPlane + encodedPlane)
    let decoded = try RDP6BitmapDecoder.decode(stream, width: 6, height: 3)
    let expectedPlane: [UInt8] = [
        255, 255, 255, 255, 254, 253,
        254, 192, 132, 96, 75, 25,
        253, 140, 62, 14, 135, 193,
    ]
    var expected = Data()
    for value in expectedPlane {
        expected.append(contentsOf: [value, value, value, 0xFF])
    }

    #expect(decoded == expected)
}

@Test func decodesRDP6ExtraLongRuns() throws {
    let encodedPlane: [UInt8] = [0x1F, 0x41, 0xF2, 0x52]
    let decoded = try RDP6BitmapDecoder.decode(
        Data([0x30] + encodedPlane + encodedPlane + encodedPlane),
        width: 100,
        height: 1
    )

    #expect(decoded == Data(repeating: 0x41, count: 3).withOpaqueAlpha(pixelCount: 100))
}

@Test func decodesRDP6AYCoCgColorLossAndAlpha() throws {
    let decoded = try RDP6BitmapDecoder.decode(
        Data([0x01, 0x7F, 100, 20, 0xFB]),
        width: 1,
        height: 1
    )

    #expect(decoded == Data([85, 95, 125, 0x7F]))
}

@Test func compensatesForMicrosoftNoAlphaYCoCgConversion() throws {
    let decoded = try RDP6BitmapDecoder.decode(
        Data([0x21, 100, 20, 0xFB]),
        width: 1,
        height: 1
    )

    #expect(decoded == Data([125, 95, 85, 0xFF]))
}

@Test func superSamplesOddSizedRDP6ChromaPlanes() throws {
    let decoded = try RDP6BitmapDecoder.decode(
        Data([
            0x09,
            0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
            100, 100, 100, 100, 100, 100, 100, 100, 100,
            10, 20, 30, 40,
            0, 0, 0, 0,
        ]),
        width: 3,
        height: 3
    )

    let blueValues = stride(from: 0, to: decoded.count, by: 4).map { decoded[$0] }
    #expect(blueValues == [90, 90, 80, 90, 90, 80, 70, 70, 60])
}

@Test func rejectsMalformedRDP6BitmapStreams() {
    let malformedStreams: [(Data, Int, Int)] = [
        (Data([0x40]), 1, 1), // Reserved header bit.
        (Data([0x08]), 1, 1), // Chroma subsampling without AYCoCg.
        (Data([0x30, 0x00]), 1, 1), // Zero RLE control byte.
        (Data([0x30, 0x23, 0x01, 0x02]), 1, 1), // Segment crosses its scan line.
        (Data([0x20, 0x01, 0x02]), 1, 1), // Truncated raw planes.
        (Data([0x20, 1, 2, 3, 4, 5]), 1, 1), // More than one raw pad byte.
        (Data([0x30, 0x11, 0x11, 0x11]), 16, 1), // Long run crosses its scan line.
    ]

    for (stream, width, height) in malformedStreams {
        #expect(throws: RDPDecodeError.invalidGraphicsUpdatePDU) {
            try RDP6BitmapDecoder.decode(stream, width: width, height: height)
        }
    }
}

private extension Data {
    func withOpaqueAlpha(pixelCount: Int) -> Data {
        var result = Data(capacity: pixelCount * 4)
        for _ in 0 ..< pixelCount {
            result.append(self)
            result.append(0xFF)
        }
        return result
    }
}
