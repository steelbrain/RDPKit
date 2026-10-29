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

    #expect(caps.capabilities == RDPDisplayControlCapabilities(
        maxNumMonitors: 4,
        maxMonitorAreaFactorA: 8192,
        maxMonitorAreaFactorB: 8192
    ))
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
    let staticPDU = try RDPStaticVirtualChannelPDU.parse(fromUserData: request.userData, maximumChunkByteCount: RDPStaticVirtualChannelPDU.maximumPayloadByteCount)
    let dynamicPDU = try #require(try RDPDynamicVirtualChannelDataPDU.parseIfPresent(from: staticPDU.payload))

    #expect(request.initiator == 1001)
    #expect(request.channelID == 1004)
    #expect(staticPDU.flags == RDPStaticVirtualChannelFlags.complete)
    #expect(staticPDU.flags & RDPStaticVirtualChannelFlags.showProtocol == 0)
    #expect(dynamicPDU.channelID == 9)
    #expect(try RDPDisplayControlMonitorLayoutPDU.parseIfPresent(from: dynamicPDU.payload) != nil)
}

@Test func endedDisplayControlSessionSendsNothing() throws {
    let channel = EmbeddedChannel()
    try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 3389)).wait()
    let session = RDPDisplayControlSession(
        dynamicChannelID: 2,
        capabilities: RDPDisplayControlCapabilities(maxNumMonitors: 1, maxMonitorAreaFactorA: 3840, maxMonitorAreaFactorB: 2160),
        userChannelID: 1007,
        staticChannelID: 1004,
        channel: channel
    )

    session.sendSingleMonitorLayout(width: 1280, height: 720)
    channel.embeddedEventLoop.run()
    #expect(try channel.readOutbound(as: ByteBuffer.self) != nil)

    session.end()
    session.sendSingleMonitorLayout(width: 1280, height: 720)
    channel.embeddedEventLoop.run()
    #expect(try channel.readOutbound(as: ByteBuffer.self) == nil)
    _ = try channel.finish()
}

/// [MS-RDPEDISP] 2.2.2.2: a 40-byte DISPLAYCONTROL_MONITOR_LAYOUT for each monitor, in the
/// layout's order, with a signed left and top.
@Test func encodesMultiMonitorDisplayControlMonitorLayoutPDU() throws {
    let layout = try RDPMonitorLayout(monitors: [
        .singlePrimary(width: 1920, height: 1080),
        RDPDisplayControlMonitorLayout(
            left: -1280,
            top: 120,
            width: 1280,
            height: 1024,
            physicalWidth: 380,
            physicalHeight: 300,
            orientation: 90,
            desktopScaleFactor: 150,
            deviceScaleFactor: 140
        ),
    ])
    let encoded = RDPDisplayControlMonitorLayoutPDU(monitors: layout.monitors).encoded()

    #expect(encoded == hexData("""
    02 00 00 00 60 00 00 00
    28 00 00 00 02 00 00 00
    01 00 00 00 00 00 00 00 00 00 00 00
    80 07 00 00 38 04 00 00
    00 00 00 00 00 00 00 00
    00 00 00 00 64 00 00 00 64 00 00 00
    00 00 00 00 00 fb ff ff 78 00 00 00
    00 05 00 00 00 04 00 00
    7c 01 00 00 2c 01 00 00
    5a 00 00 00 96 00 00 00 8c 00 00 00
    """))
    #expect(try RDPDisplayControlMonitorLayoutPDU.parseIfPresent(from: encoded)?.monitors == layout.monitors)
}

private func primaryMonitor(width: UInt32 = 800, height: UInt32 = 600) -> RDPDisplayControlMonitorLayout {
    RDPDisplayControlMonitorLayout(flags: RDPDisplayControlMonitorFlags.primary, width: width, height: height)
}

/// Each of [MS-RDPEDISP] 2.2.2.2.1's rules, with the error that names what breaks it.
@Test(arguments: [
    ([], .noMonitors),
    (
        [primaryMonitor(width: 200, height: 200)]
            + (1 ... 16).map { RDPDisplayControlMonitorLayout(left: Int32($0) * 200, width: 200, height: 200) },
        .tooManyMonitors(count: 17, maximum: 16)
    ),
    ([primaryMonitor(width: 801)], .invalidWidth(monitor: 0)),
    ([primaryMonitor(width: 198)], .invalidWidth(monitor: 0)),
    ([primaryMonitor(width: 8194)], .invalidWidth(monitor: 0)),
    ([primaryMonitor(), RDPDisplayControlMonitorLayout(left: 800, width: 800, height: 199)], .invalidHeight(monitor: 1)),
    ([primaryMonitor(height: 8193)], .invalidHeight(monitor: 0)),
    (
        [RDPDisplayControlMonitorLayout(flags: RDPDisplayControlMonitorFlags.primary | 0x2, width: 800, height: 600)],
        .unsupportedFlags(monitor: 0)
    ),
    (
        [primaryMonitor(), RDPDisplayControlMonitorLayout(left: 800, width: 800, height: 600, orientation: 45)],
        .invalidOrientation(monitor: 1)
    ),
    ([RDPDisplayControlMonitorLayout(flags: 1, width: 800, height: 600, desktopScaleFactor: 99)], .invalidScaleFactors(monitor: 0)),
    ([RDPDisplayControlMonitorLayout(flags: 1, width: 800, height: 600, deviceScaleFactor: 150)], .invalidScaleFactors(monitor: 0)),
    ([RDPDisplayControlMonitorLayout(width: 800, height: 600)], .primaryMonitorCount(0)),
    ([primaryMonitor(), RDPDisplayControlMonitorLayout(flags: 1, left: 800, width: 800, height: 600)], .primaryMonitorCount(2)),
    ([RDPDisplayControlMonitorLayout(flags: 1, top: -1, width: 800, height: 600)], .primaryMonitorNotAtOrigin),
    ([primaryMonitor(), RDPDisplayControlMonitorLayout(left: 799, width: 800, height: 600)], .overlappingMonitors(0, 1)),
    (
        [
            primaryMonitor(),
            RDPDisplayControlMonitorLayout(left: 800, width: 800, height: 600),
            RDPDisplayControlMonitorLayout(left: -900, width: 800, height: 600),
        ],
        .detachedMonitor(monitor: 2)
    ),
    (
        [primaryMonitor(width: 8192)] + (1 ... 4).map {
            RDPDisplayControlMonitorLayout(left: Int32($0) * 8192, width: 8192, height: 600)
        },
        .desktopTooLarge(maximum: 32766)
    ),
] as [([RDPDisplayControlMonitorLayout], RDPMonitorLayoutError)])
func monitorLayoutRefusesALayoutBreakingTheRules(monitors: [RDPDisplayControlMonitorLayout], error: RDPMonitorLayoutError) {
    #expect(throws: error) {
        try RDPMonitorLayout(monitors: monitors)
    }
}

/// Monitors form one group when each reaches every other through monitors that touch, along an
/// edge or at a corner. Separate groups, each monitor touching another, still make a layout
/// Display Control sends: [MS-RDPEDISP] 3.1.5.2 asks no more, and Windows 11 applies it.
@Test func monitorLayoutTellsWhetherItsMonitorsFormOneGroup() throws {
    let right = RDPDisplayControlMonitorLayout(left: 800, width: 800, height: 600)
    let below = RDPDisplayControlMonitorLayout(top: 600, width: 800, height: 600)
    let diagonal = RDPDisplayControlMonitorLayout(left: 800, top: 600, width: 800, height: 600)
    let farRight = RDPDisplayControlMonitorLayout(left: 1600, width: 800, height: 600)
    let farthestRight = RDPDisplayControlMonitorLayout(left: 2400, width: 800, height: 600)
    let separate = [
        RDPDisplayControlMonitorLayout(left: 2000, width: 800, height: 600),
        RDPDisplayControlMonitorLayout(left: 2800, width: 800, height: 600),
    ]

    #expect(try RDPMonitorLayout(monitors: [primaryMonitor()]).formsOneGroup)
    #expect(try RDPMonitorLayout(monitors: [primaryMonitor(), right]).formsOneGroup)
    #expect(try RDPMonitorLayout(monitors: [primaryMonitor(), diagonal]).formsOneGroup)
    #expect(try RDPMonitorLayout(monitors: [primaryMonitor(), below, right]).formsOneGroup)
    // The first monitor reaches the primary one only through the two between them.
    #expect(try RDPMonitorLayout(monitors: [farthestRight, primaryMonitor(), farRight, right]).formsOneGroup)
    #expect(try !RDPMonitorLayout(monitors: [primaryMonitor(), right] + separate).formsOneGroup)
}

/// Monitors left of and above the primary one have negative coordinates; the desktop is the
/// bounding box of them all.
@Test func monitorLayoutsDesktopIsTheMonitorsBoundingBox() throws {
    let layout = try RDPMonitorLayout(monitors: [
        .singlePrimary(width: 1920, height: 1080),
        RDPDisplayControlMonitorLayout(left: -1280, top: 120, width: 1280, height: 1024),
        RDPDisplayControlMonitorLayout(top: -1440, width: 2560, height: 1440),
    ])
    let single = RDPMonitorLayout.singlePrimary(width: 1441, height: 900, desktopScaleFactor: 150, deviceScaleFactor: 159)

    #expect(layout.desktopWidth == 3840)
    #expect(layout.desktopHeight == 2584)
    #expect(single.monitors == [
        .singlePrimary(width: 1441, height: 900, desktopScaleFactor: 150, deviceScaleFactor: 159),
    ])
    #expect(single.desktopWidth == 1440)
    #expect(single.desktopHeight == 900)
}

@Test func monitorIsPrimaryReadsAndSetsThePrimaryFlag() {
    var monitor = RDPDisplayControlMonitorLayout(width: 800, height: 600)
    #expect(!monitor.isPrimary)

    monitor.isPrimary = true
    #expect(monitor.flags == RDPDisplayControlMonitorFlags.primary)
    #expect(monitor.isPrimary)

    monitor.isPrimary = false
    #expect(monitor.flags == 0)
    #expect(RDPDisplayControlMonitorLayout.singlePrimary(width: 800, height: 600).isPrimary)
}

/// [MS-RDPEDISP] 2.2.2.1: at most MaxNumMonitors monitors, covering at most MaxNumMonitors ×
/// MaxMonitorAreaFactorA × MaxMonitorAreaFactorB pixels.
@Test func monitorLayoutNamesTheServerCapabilityItExceeds() throws {
    let layout = try RDPMonitorLayout(monitors: [
        .singlePrimary(width: 1920, height: 1080),
        RDPDisplayControlMonitorLayout(left: 1920, width: 1920, height: 1080),
    ])

    #expect(throws: RDPMonitorLayoutError.tooManyMonitors(count: 2, maximum: 1)) {
        try layout.validate(for: RDPDisplayControlCapabilities(
            maxNumMonitors: 1,
            maxMonitorAreaFactorA: 8192,
            maxMonitorAreaFactorB: 8192
        ))
    }
    #expect(throws: RDPMonitorLayoutError.areaTooLarge(area: 4_147_200, maximum: 4_143_360)) {
        try layout.validate(for: RDPDisplayControlCapabilities(
            maxNumMonitors: 2,
            maxMonitorAreaFactorA: 1920,
            maxMonitorAreaFactorB: 1079
        ))
    }
    try layout.validate(for: RDPDisplayControlCapabilities(
        maxNumMonitors: 2,
        maxMonitorAreaFactorA: 1920,
        maxMonitorAreaFactorB: 1080
    ))
}

/// The DisplayControl payloads `channel` has to send.
private func outboundDisplayControlPayloads(_ channel: EmbeddedChannel) throws -> [Data] {
    channel.embeddedEventLoop.run()
    var payloads: [Data] = []
    while var outbound = try channel.readOutbound(as: ByteBuffer.self) {
        let outboundBytes = outbound.readBytes(length: outbound.readableBytes)
        let packet = try Data(#require(outboundBytes))
        let request = try mcsSendDataRequest(fromTPKT: packet)
        let staticPDU = try RDPStaticVirtualChannelPDU.parse(
            fromUserData: request.userData,
            maximumChunkByteCount: RDPStaticVirtualChannelPDU.maximumPayloadByteCount
        )
        try payloads.append(#require(try RDPDynamicVirtualChannelDataPDU.parseIfPresent(from: staticPDU.payload)).payload)
    }
    return payloads
}

/// A layout the server's capabilities allow goes out whole; one they do not throws and sends
/// nothing.
@Test func displayControlSessionSendsAMultiMonitorLayout() throws {
    let channel = EmbeddedChannel()
    try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 3389)).wait()
    let session = RDPDisplayControlSession(
        dynamicChannelID: 9,
        capabilities: RDPDisplayControlCapabilities(
            maxNumMonitors: 2,
            maxMonitorAreaFactorA: 8192,
            maxMonitorAreaFactorB: 8192
        ),
        userChannelID: 1001,
        staticChannelID: 1004,
        channel: channel
    )
    let layout = try RDPMonitorLayout(monitors: [
        .singlePrimary(width: 1920, height: 1080),
        RDPDisplayControlMonitorLayout(left: 1920, top: -360, width: 2560, height: 1440),
    ])
    let tooMany = try RDPMonitorLayout(monitors: layout.monitors + [
        RDPDisplayControlMonitorLayout(left: -800, width: 800, height: 600),
    ])

    #expect(throws: RDPMonitorLayoutError.tooManyMonitors(count: 3, maximum: 2)) {
        try session.send(tooMany)
    }
    try session.send(layout)
    let payloads = try outboundDisplayControlPayloads(channel)

    #expect(payloads.count == 1)
    #expect(try payloads.first.flatMap(RDPDisplayControlMonitorLayoutPDU.parseIfPresent)?.monitors == layout.monitors)
    _ = try channel.finish()
}

/// The single-monitor calls send what sending ``RDPMonitorLayout/singlePrimary`` sends.
@Test func singleMonitorCallsSendTheSinglePrimaryLayout() throws {
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

    session.sendSingleMonitorLayout(width: 1441, height: 900, desktopScaleFactor: 150, deviceScaleFactor: 159)
    session.send(RDPDisplayRequest(
        width: 1441,
        height: 900,
        scaleFactors: RDPDisplayScaleFactors(desktopScaleFactor: 150, deviceScaleFactor: 159)
    ))
    try session.send(.singlePrimary(width: 1441, height: 900, desktopScaleFactor: 150, deviceScaleFactor: 159))
    let payloads = try outboundDisplayControlPayloads(channel)

    #expect(payloads.count == 3)
    #expect(Set(payloads) == [
        RDPDisplayControlMonitorLayoutPDU.singlePrimary(
            width: 1440,
            height: 900,
            desktopScaleFactor: 150,
            deviceScaleFactor: 140
        ).encoded(),
    ])
    _ = try channel.finish()
}

/// A layout of several monitors reaches the server on the session's DisplayControl channel
/// ([MS-RDPEDISP] 2.2.2.2).
@Test func multiMonitorLayoutReachesTheServer() throws {
    func drdynvc(_ payload: Data) -> Data {
        mcsSendDataIndication(
            channelID: KRdpCapture.drdynvcChannelID,
            userData: RDPStaticVirtualChannelPDU(payload: payload).encodedUserData()
        )
    }
    var caps = Data()
    caps.appendLittleEndianUInt32(5)
    caps.appendLittleEndianUInt32(20)
    caps.appendLittleEndianUInt32(4)
    caps.appendLittleEndianUInt32(3840)
    caps.appendLittleEndianUInt32(2160)
    let layout = try RDPMonitorLayout(monitors: [
        .singlePrimary(width: 1920, height: 1080),
        RDPDisplayControlMonitorLayout(left: -1920, width: 1920, height: 1080, deviceScaleFactor: 140),
    ])
    let layoutData = RDPDynamicVirtualChannelDataPDU(
        channelID: 2,
        payload: RDPDisplayControlMonitorLayoutPDU(monitors: layout.monitors).encoded()
    ).encoded()
    // The capture after its CapsConfirm (event 38), up to its first frame.
    let firstFrame = try KRdpCapture.events()[39...].map { try #require($0.bytes) }
    let sendErrors = Locked([String]())
    let run = try KRdpCapture.run(
        prefix: 39,
        appending: [
            drdynvc(Data([0x10, 0x02]) + Data("Microsoft::Windows::RDS::DisplayControl".utf8) + Data([0])),
            drdynvc(RDPDynamicVirtualChannelDataPDU(channelID: 2, payload: caps).encoded()),
        ] + firstFrame,
        frameCaptureLimit: nil,
        onTrailingClientPacket: { channel, packet in
            if packet.range(of: layoutData) != nil {
                KRdpCapture.endConnection(channel, .close)
            }
        },
        onDisplayControlReady: { session in
            do {
                try session.send(layout)
            } catch {
                sendErrors.withLock { $0.append(String(describing: error)) }
            }
        }
    )

    #expect(sendErrors.value.isEmpty)
    #expect(run.clientPackets.contains { $0.range(of: layoutData) != nil })
}
