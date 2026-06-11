import Foundation
@testable import RDPKit
import Testing

@Test func parsesDisplayControlCapsPDU() throws {
    let caps = try #require(try RDPDisplayControlCapsPDU.parseIfPresent(from: hexData("""
    05 00 00 00 14 00 00 00
    04 00 00 00 00 20 00 00 00 20 00 00
    """)))

    #expect(caps.maxNumMonitors == 4)
    #expect(caps.maxMonitorAreaFactorA == 8192)
    #expect(caps.maxMonitorAreaFactorB == 8192)
}

@Test func encodesSinglePrimaryDisplayControlMonitorLayoutPDU() {
    let layout = RDPDisplayControlMonitorLayoutPDU.singlePrimary(width: 1440, height: 900)

    #expect(layout.encoded() == hexData("""
    02 00 00 00 38 00 00 00
    28 00 00 00 01 00 00 00
    01 00 00 00 00 00 00 00 00 00 00 00
    a0 05 00 00 84 03 00 00
    00 00 00 00 00 00 00 00
    00 00 00 00 64 00 00 00 64 00 00 00
    """))
}

@Test func displayControlMonitorLayoutClampsWidthToEvenProtocolRange() {
    let small = RDPDisplayControlMonitorLayout.singlePrimary(width: 199, height: 199)
    let odd = RDPDisplayControlMonitorLayout.singlePrimary(width: 1441, height: 900)
    let large = RDPDisplayControlMonitorLayout.singlePrimary(width: 8193, height: 9000)

    #expect(small.width == 200)
    #expect(small.height == 200)
    #expect(odd.width == 1440)
    #expect(large.width == 8192)
    #expect(large.height == 8192)
}

@Test func displayControlMonitorLayoutCarriesScaleFactors() {
    let layout = RDPDisplayControlMonitorLayoutPDU.singlePrimary(
        width: 1440,
        height: 900,
        desktopScaleFactor: 200,
        deviceScaleFactor: 180
    )

    #expect(layout.monitors[0].desktopScaleFactor == 200)
    #expect(layout.monitors[0].deviceScaleFactor == 180)
    #expect(layout.encoded().suffix(8) == hexData("c8 00 00 00 b4 00 00 00"))
}

@Test func displayControlMonitorLayoutNormalizesScaleFactors() {
    let low = RDPDisplayControlMonitorLayout.singlePrimary(
        width: 1440,
        height: 900,
        desktopScaleFactor: 99,
        deviceScaleFactor: 119
    )
    let middle = RDPDisplayControlMonitorLayout.singlePrimary(
        width: 1440,
        height: 900,
        desktopScaleFactor: 150,
        deviceScaleFactor: 159
    )
    let high = RDPDisplayControlMonitorLayout.singlePrimary(
        width: 1440,
        height: 900,
        desktopScaleFactor: 501,
        deviceScaleFactor: 181
    )

    #expect(low.desktopScaleFactor == 100)
    #expect(low.deviceScaleFactor == 100)
    #expect(middle.desktopScaleFactor == 150)
    #expect(middle.deviceScaleFactor == 140)
    #expect(high.desktopScaleFactor == 500)
    #expect(high.deviceScaleFactor == 180)
}

private func hexData(_ value: String) -> Data {
    let bytes = value.split(whereSeparator: { $0.isWhitespace }).compactMap { UInt8($0, radix: 16) }
    return Data(bytes)
}
