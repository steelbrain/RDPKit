import Foundation
import NIOCore
import NIOEmbedded
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

@Test func ignoresNonCapsDisplayControlPDU() throws {
    let caps = try RDPDisplayControlCapsPDU.parseIfPresent(from: hexData("""
    02 00 00 00 08 00 00 00
    """))

    #expect(caps == nil)
}

@Test func rejectsMalformedDisplayControlCapsPDU() {
    #expect(throws: RDPDecodeError.invalidDynamicVirtualChannelPDU) {
        try RDPDisplayControlCapsPDU.parseIfPresent(from: hexData("""
        05 00 00 00 13 00 00 00
        04 00 00 00 00 20 00 00 00 20 00 00
        """))
    }
    #expect(throws: RDPDecodeError.invalidDynamicVirtualChannelPDU) {
        try RDPDisplayControlCapsPDU.parseIfPresent(from: hexData("""
        05 00 00 00 14 00 00 00
        04 00 00 00 00 20 00 00
        """))
    }
    #expect(throws: RDPDecodeError.invalidDynamicVirtualChannelPDU) {
        try RDPDisplayControlCapsPDU.parseIfPresent(from: hexData("""
        05 00 00 00 14 00 00 00
        04 00 00 00 00 20 00 00 00 20 00 00 00
        """))
    }
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

@Test func parsesDisplayControlMonitorLayoutPDU() throws {
    let pdu = try #require(try RDPDisplayControlMonitorLayoutPDU.parseIfPresent(from: hexData("""
    02 00 00 00 38 00 00 00
    28 00 00 00 01 00 00 00
    01 00 00 00 00 00 00 00 00 00 00 00
    a0 05 00 00 84 03 00 00
    00 00 00 00 00 00 00 00
    00 00 00 00 64 00 00 00 64 00 00 00
    """)))

    #expect(pdu.monitors == [
        RDPDisplayControlMonitorLayout.singlePrimary(width: 1440, height: 900),
    ])
}

@Test func rejectsMalformedDisplayControlMonitorLayoutPDU() {
    #expect(throws: RDPDecodeError.invalidDynamicVirtualChannelPDU) {
        try RDPDisplayControlMonitorLayoutPDU.parseIfPresent(from: hexData("""
        02 00 00 00 38 00 00 00
        27 00 00 00 01 00 00 00
        01 00 00 00 00 00 00 00 00 00 00 00
        a0 05 00 00 84 03 00 00
        00 00 00 00 00 00 00 00
        00 00 00 00 64 00 00 00 64 00 00 00
        """))
    }
    #expect(throws: RDPDecodeError.invalidDynamicVirtualChannelPDU) {
        try RDPDisplayControlMonitorLayoutPDU.parseIfPresent(from: hexData("""
        02 00 00 00 38 00 00 00
        28 00 00 00 02 00 00 00
        01 00 00 00 00 00 00 00 00 00 00 00
        a0 05 00 00 84 03 00 00
        00 00 00 00 00 00 00 00
        00 00 00 00 64 00 00 00 64 00 00 00
        """))
    }
    #expect(throws: RDPDecodeError.invalidDynamicVirtualChannelPDU) {
        try RDPDisplayControlMonitorLayoutPDU.parseIfPresent(from: hexData("""
        02 00 00 00 34 00 00 00
        28 00 00 00 01 00 00 00
        01 00 00 00 00 00 00 00 00 00 00 00
        a0 05 00 00 84 03 00 00
        00 00 00 00 00 00 00 00
        00 00 00 00 64 00 00 00
        """))
    }
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

@Test func displayControlMonitorLayoutValidatesServerCapabilities() {
    let capabilities = RDPDisplayControlCapabilities(
        maxNumMonitors: 1,
        maxMonitorAreaFactorA: 1920,
        maxMonitorAreaFactorB: 1080
    )
    let valid = RDPDisplayControlMonitorLayoutPDU.singlePrimary(width: 1920, height: 1080)
    let tooManyMonitors = RDPDisplayControlMonitorLayoutPDU(monitors: [
        .singlePrimary(width: 800, height: 600),
        .singlePrimary(width: 800, height: 600),
    ])
    let tooMuchArea = RDPDisplayControlMonitorLayoutPDU.singlePrimary(width: 2560, height: 1440)
    let oddWidth = RDPDisplayControlMonitorLayoutPDU(monitors: [
        RDPDisplayControlMonitorLayout(width: 801, height: 600),
    ])
    let invalidOrientation = RDPDisplayControlMonitorLayoutPDU(monitors: [
        RDPDisplayControlMonitorLayout(width: 800, height: 600, orientation: 45),
    ])
    let unknownFlags = RDPDisplayControlMonitorLayoutPDU(monitors: [
        RDPDisplayControlMonitorLayout(
            flags: RDPDisplayControlMonitorFlags.primary | 0x0000_0002,
            width: 800,
            height: 600
        ),
    ])

    #expect(valid.isValid(for: capabilities))
    #expect(!tooManyMonitors.isValid(for: capabilities))
    #expect(!tooMuchArea.isValid(for: capabilities))
    #expect(!oddWidth.isValid(for: capabilities))
    #expect(!invalidOrientation.isValid(for: capabilities))
    #expect(!unknownFlags.isValid(for: capabilities))
}

@Test func displayControlMonitorLayoutRequiresOnePrimaryAtOrigin() {
    let capabilities = RDPDisplayControlCapabilities(
        maxNumMonitors: 2,
        maxMonitorAreaFactorA: 8192,
        maxMonitorAreaFactorB: 8192
    )
    let noPrimary = RDPDisplayControlMonitorLayoutPDU(monitors: [
        RDPDisplayControlMonitorLayout(flags: 0, width: 800, height: 600),
    ])
    let twoPrimary = RDPDisplayControlMonitorLayoutPDU(monitors: [
        RDPDisplayControlMonitorLayout(flags: RDPDisplayControlMonitorFlags.primary, width: 800, height: 600),
        RDPDisplayControlMonitorLayout(
            flags: RDPDisplayControlMonitorFlags.primary,
            left: 800,
            width: 800,
            height: 600
        ),
    ])
    let primaryOffset = RDPDisplayControlMonitorLayoutPDU(monitors: [
        RDPDisplayControlMonitorLayout(
            flags: RDPDisplayControlMonitorFlags.primary,
            left: 1,
            width: 800,
            height: 600
        ),
    ])

    #expect(!noPrimary.isValid(for: capabilities))
    #expect(!twoPrimary.isValid(for: capabilities))
    #expect(!primaryOffset.isValid(for: capabilities))
}

@Test func displayControlMonitorLayoutRejectsOverlappingMonitors() {
    let capabilities = RDPDisplayControlCapabilities(
        maxNumMonitors: 2,
        maxMonitorAreaFactorA: 8192,
        maxMonitorAreaFactorB: 8192
    )
    let layout = RDPDisplayControlMonitorLayoutPDU(monitors: [
        RDPDisplayControlMonitorLayout(
            flags: RDPDisplayControlMonitorFlags.primary,
            width: 800,
            height: 600
        ),
        RDPDisplayControlMonitorLayout(left: 799, width: 800, height: 600),
    ])

    #expect(!layout.isValid(for: capabilities))
}

@Test func displayControlMonitorLayoutRequiresAdjacencyForMultiMonitorLayout() {
    let capabilities = RDPDisplayControlCapabilities(
        maxNumMonitors: 3,
        maxMonitorAreaFactorA: 8192,
        maxMonitorAreaFactorB: 8192
    )
    let disconnected = RDPDisplayControlMonitorLayoutPDU(monitors: [
        RDPDisplayControlMonitorLayout(
            flags: RDPDisplayControlMonitorFlags.primary,
            width: 800,
            height: 600
        ),
        RDPDisplayControlMonitorLayout(left: 900, width: 800, height: 600),
    ])
    let edgeAdjacent = RDPDisplayControlMonitorLayoutPDU(monitors: [
        RDPDisplayControlMonitorLayout(
            flags: RDPDisplayControlMonitorFlags.primary,
            width: 800,
            height: 600
        ),
        RDPDisplayControlMonitorLayout(left: 800, width: 800, height: 600),
    ])
    let cornerAdjacent = RDPDisplayControlMonitorLayoutPDU(monitors: [
        RDPDisplayControlMonitorLayout(
            flags: RDPDisplayControlMonitorFlags.primary,
            width: 800,
            height: 600
        ),
        RDPDisplayControlMonitorLayout(left: 800, top: 600, width: 800, height: 600),
    ])

    #expect(!disconnected.isValid(for: capabilities))
    #expect(edgeAdjacent.isValid(for: capabilities))
    #expect(cornerAdjacent.isValid(for: capabilities))
}

@Test func displayControlSessionSendsMonitorLayoutWithoutShowProtocolFlag() throws {
    let channel = EmbeddedChannel()
    try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 3389)).wait()
    let session = RDPDisplayControlSession(
        dynamicChannelID: 9,
        capabilities: RDPDisplayControlCapabilities(
            maxNumMonitors: 1,
            maxMonitorAreaFactorA: 8192,
            maxMonitorAreaFactorB: 8192
        ),
        userChannelID: 1001,
        staticChannelID: 1004,
        channel: channel
    )

    session.sendSingleMonitorLayout(width: 1440, height: 900)
    channel.embeddedEventLoop.run()
    var outbound = try #require(try channel.readOutbound(as: ByteBuffer.self))
    let outboundBytes = outbound.readBytes(length: outbound.readableBytes)
    let packet = Data(try #require(outboundBytes))
    let request = try mcsSendDataRequest(fromTPKT: packet)
    let staticPDU = try RDPStaticVirtualChannelPDU.parse(fromUserData: request.userData)
    let dynamicPDU = try #require(try RDPDynamicVirtualChannelDataPDU.parseIfPresent(from: staticPDU.payload))

    #expect(request.initiator == 1001)
    #expect(request.channelID == 1004)
    #expect(staticPDU.flags == RDPStaticVirtualChannelFlags.complete)
    #expect(staticPDU.flags & RDPStaticVirtualChannelFlags.showProtocol == 0)
    #expect(dynamicPDU.channelID == 9)
    #expect(try RDPDisplayControlMonitorLayoutPDU.parseIfPresent(from: dynamicPDU.payload) != nil)
}

private func mcsSendDataRequest(fromTPKT packet: Data) throws -> (initiator: UInt16, channelID: UInt16, userData: Data) {
    var cursor = try ByteCursor(X224DataTPDU.unwrap(packet))
    let header = try cursor.readUInt8()
    let initiator = try UInt16(1001 + cursor.readBigEndianUInt16())
    let channelID = try cursor.readBigEndianUInt16()
    _ = try cursor.readUInt8()
    let length = try cursor.readPERLength()
    let userData = try cursor.readData(count: length)
    guard header == 0x64, cursor.remaining == 0 else {
        throw RDPDecodeError.invalidMCSSendDataIndication
    }
    return (initiator, channelID, userData)
}

private func hexData(_ value: String) -> Data {
    let bytes = value.split(whereSeparator: { $0.isWhitespace }).compactMap { UInt8($0, radix: 16) }
    return Data(bytes)
}
