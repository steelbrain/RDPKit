import Foundation
import NIOCore
import NIOPosix
@preconcurrency import NIOSSL
@testable import RDPKit
import Testing

// Live-session behaviour against the KRdp capture: the recorded negotiation
// (Fixtures/krdp-negotiation-transcript.json) runs up to its first frame, and
// each test appends the server traffic it needs, or scripts the connection
// once the recording ends.

@Test func informationalRedirectionDoesNotEndTheSession() throws {
    // LB_NOREDIRECT: "for informational purposes only" ([MS-RDPBCGR] 2.2.13.1).
    let redirection = KRdpCapture.ioPacket(KRdpCapture.redirection(
        flags: RDPServerRedirectionPDU.Flags.noRedirect.rawValue | RDPServerRedirectionPDU.Flags.loadBalanceInfo.rawValue
    ))
    let run = try KRdpCapture.run(
        appending: [redirection, KRdpCapture.emptyGraphicsFrame(id: 1)],
        frameCaptureLimit: 2
    )

    #expect(run.report.error == nil)
    #expect(run.report.status == "success")
    #expect(run.report.rdpGraphicsFrameAcknowledgeHexes?.count == 2)
    #expect(run.report.warnings.contains { $0.code == "informational-redirection" })
}

@Test func unknownAutoDetectRequestAndMalformedSaveSessionInfoDoNotEndTheSession() throws {
    var unknownAutoDetect = Data()
    unknownAutoDetect.appendLittleEndianUInt16(0x1000) // SEC_AUTODETECT_REQ
    unknownAutoDetect.appendLittleEndianUInt16(0)
    unknownAutoDetect.append(contentsOf: [0x06, 0x00])
    unknownAutoDetect.appendLittleEndianUInt16(0x0042)
    unknownAutoDetect.appendLittleEndianUInt16(0x7777)
    var malformedAutoDetect = Data()
    malformedAutoDetect.appendLittleEndianUInt16(0x1000)
    malformedAutoDetect.appendLittleEndianUInt16(0)
    malformedAutoDetect.append(contentsOf: [0x09, 0x00]) // RTT request headerLength must be 6
    malformedAutoDetect.appendLittleEndianUInt16(0x0043)
    malformedAutoDetect.appendLittleEndianUInt16(0x0001)
    // INFOTYPE_LOGON_LONG with a truncated body ([MS-RDPBCGR] 2.2.10.1.1).
    var saveSessionInfo = Data()
    saveSessionInfo.appendLittleEndianUInt32(0x0000_0001)
    saveSessionInfo.append(Data(repeating: 0, count: 6))

    let run = try KRdpCapture.run(
        appending: [
            KRdpCapture.messageChannelPacket(unknownAutoDetect),
            KRdpCapture.messageChannelPacket(malformedAutoDetect),
            KRdpCapture.ioPacket(KRdpCapture.shareData(pduType2: 0x26, payload: saveSessionInfo)),
            KRdpCapture.emptyGraphicsFrame(id: 1),
        ],
        frameCaptureLimit: 2
    )

    #expect(run.report.error == nil)
    #expect(run.report.rdpGraphicsFrameAcknowledgeHexes?.count == 2)
    #expect(run.report.warnings.contains { $0.code == "auto-detect-error" })
}

/// A non-clean Set Error Info and Deactivate All followed by a Demand Active
/// is a reactivation ([MS-RDPBCGR] 1.3.1.3): the session goes on past the
/// one-second wait for a disconnect, at the new desktop size.
@Test func reactivationContinuesAtTheNewDesktopSize() throws {
    let events = try KRdpCapture.events()
    var errorInfo = Data()
    errorInfo.appendLittleEndianUInt32(0x0000_0007)
    var deactivate = Data()
    deactivate.appendLittleEndianUInt32(KRdpCapture.shareID)
    deactivate.append(contentsOf: [0x01, 0x00, 0x00])
    let demandActive = try KRdpCapture.settingDesktopSize(of: #require(events[19].bytes), width: 1600, height: 900)
    let finalization = try [21, 22, 27, 28].map { try #require(events[$0].bytes) }
    // Fast-path frames before and well after the reactivation, the second
    // in the corner of the new desktop, outside the old one.
    let corner = KRdpCapture.fastPathSurfaceBits(left: 1599, top: 899, pixel: Data([1, 2, 3, 0xFF]))

    let run = try KRdpCapture.run(
        appending: [
            KRdpCapture.fastPathSurfaceBits(left: 0, top: 0, pixel: Data([1, 2, 3, 0xFF])),
            KRdpCapture.ioPacket(KRdpCapture.shareData(pduType2: 0x2F, payload: errorInfo)),
            KRdpCapture.ioPacket(KRdpCapture.shareControl(type: 0x6, body: deactivate)),
            demandActive,
        ] + finalization,
        frameCaptureLimit: 2
    ) { channel in
        channel.eventLoop.scheduleTask(in: .milliseconds(1500)) {
            var buffer = channel.allocator.buffer(capacity: corner.count)
            buffer.writeBytes(corner)
            channel.writeAndFlush(buffer, promise: nil)
        }
    }

    #expect(run.report.error == nil)
    #expect(run.report.rdpRemoteTerminationErrorInfo == nil)
    #expect(run.clientPackets.compactMap(KRdpCapture.confirmActiveDesktopSize).map { [$0.width, $0.height] }
        == [[1280, 720], [1600, 900]])
    let primaryFrames = run.report.rdpGraphicsFrames?.filter { $0.codecName == "surface-bgra" } ?? []
    #expect(primaryFrames.map(\.regionRects) == [
        [RDPFrameRect(left: 0, top: 0, right: 1, bottom: 1)],
        [RDPFrameRect(left: 1599, top: 899, right: 1600, bottom: 900)],
    ])
}

/// A live session that has shown frames still bounds a reactivation: a
/// Demand Active the server never finalizes ends the session at the timeout
/// instead of leaving it waiting forever.
@Test func liveReactivationThatNeverFinalizesTimesOut() throws {
    let events = try KRdpCapture.events()
    var deactivate = Data()
    deactivate.appendLittleEndianUInt32(KRdpCapture.shareID)
    deactivate.append(contentsOf: [0x01, 0x00, 0x00])
    let run = try KRdpCapture.run(
        appending: [
            KRdpCapture.ioPacket(KRdpCapture.shareControl(type: 0x6, body: deactivate)),
            #require(events[19].bytes),
        ],
        frameCaptureLimit: nil,
        timeoutSeconds: 1,
        guardSeconds: 8
    )

    #expect(run.report.rdpGraphicsFirstFrame != nil)
    #expect(run.report.error == "server did not grant control during connection finalization")
}

/// Video updates are held until the frame ends, so a server that never ends
/// its frame must not grow them without bound.
@Test func frameThatNeverEndsIsBounded() throws {
    let updates = (0 ... RDPClientConnection.maximumPendingVideoFrameCount).map { _ in
        KRdpCapture.graphicsPacket(KRdpCapture.avc420Update())
    }
    let run = try KRdpCapture.run(
        appending: [KRdpCapture.graphicsPacket(KRdpCapture.startFrame(id: 1))] + updates,
        frameCaptureLimit: 2,
        timeoutSeconds: 3
    )

    #expect(run.report.error == "server sent more than 64 video updates without ending the frame")
}

/// The next snapshot names each surface deleted since the last one once, so a server that
/// creates and deletes surfaces it never shows cannot grow the list without bound.
@Test func surfacesDeletedBetweenSnapshotsAreNamedOnce() throws {
    var create = Data()
    create.appendLittleEndianUInt16(5)
    create.appendLittleEndianUInt16(16)
    create.appendLittleEndianUInt16(16)
    create.appendUInt8(0x20)
    var delete = Data()
    delete.appendLittleEndianUInt16(5)
    let cycles = (2 ... 4).map { id in
        KRdpCapture.graphicsPacket(
            KRdpCapture.startFrame(id: UInt32(id))
                + graphicsMessage(commandID: RDPGFXCommandID.createSurface, payload: create)
                + graphicsMessage(commandID: RDPGFXCommandID.deleteSurface, payload: delete)
                + KRdpCapture.endFrame(id: UInt32(id))
        )
    }
    let run = try KRdpCapture.run(
        appending: cycles + [
            KRdpCapture.graphicsPacket(KRdpCapture.startFrame(id: 5) + KRdpCapture.avc420Update() + KRdpCapture.endFrame(id: 5)),
        ],
        frameCaptureLimit: 5
    )

    #expect(run.report.error == nil)
    #expect(run.report.rdpGraphicsFrames?.last?.deletedSurfaceIDs == [5])
}

/// A second RDPGFX channel replaces the first: data still arriving on the
/// old channel ID must not reach the new channel's decoder.
@Test func recreatedGraphicsChannelForgetsTheOldChannelID() throws {
    let events = try KRdpCapture.events()
    // KRdp's CapsConfirm (event 35), after its DVC and segment headers.
    let capsConfirm = try #require(events[35].bytes).dropFirst(27)
    let create = Data([0x10, 0x02]) + Data("Microsoft::Windows::RDS::Graphics".utf8) + Data([0])
    let run = try KRdpCapture.run(
        appending: [
            mcsSendDataIndication(
                channelID: KRdpCapture.drdynvcChannelID,
                userData: RDPStaticVirtualChannelPDU(payload: create).encodedUserData()
            ),
            KRdpCapture.graphicsPacket(Data(capsConfirm), channelID: 2),
            KRdpCapture.graphicsPacket(Data([0x12, 0x00, 0x00]), channelID: 1),
            KRdpCapture.graphicsPacket(KRdpCapture.startFrame(id: 1) + KRdpCapture.endFrame(id: 1), channelID: 2),
            KRdpCapture.graphicsPacket(KRdpCapture.startFrame(id: 2) + KRdpCapture.endFrame(id: 2), channelID: 2),
        ],
        frameCaptureLimit: 2
    )

    #expect(run.report.error == nil)
    #expect(run.report.rdpGraphicsChannelID == 2)
    // totalFramesDecoded restarts with the channel, so both frames are captured on it.
    let acknowledgesOnChannel2 = run.clientPackets.filter { $0.range(of: Data([0x30, 0x02, 0x0D, 0x00])) != nil }
    #expect(acknowledgesOnChannel2.count == 2)
}

/// A second DisplayControl channel replaces the first, as a second RDPGFX channel does: the
/// session made for the old channel, and capabilities still arriving on it, are dropped.
@Test func recreatedDisplayControlChannelForgetsTheOldChannelID() throws {
    func drdynvc(_ payload: Data) -> Data {
        mcsSendDataIndication(
            channelID: KRdpCapture.drdynvcChannelID,
            userData: RDPStaticVirtualChannelPDU(payload: payload).encodedUserData()
        )
    }
    func create(_ channelID: UInt8) -> Data {
        drdynvc(Data([0x10, channelID]) + Data("Microsoft::Windows::RDS::DisplayControl".utf8) + Data([0]))
    }
    var caps = Data()
    caps.appendLittleEndianUInt32(5)
    caps.appendLittleEndianUInt32(20)
    caps.appendLittleEndianUInt32(1)
    caps.appendLittleEndianUInt32(3840)
    caps.appendLittleEndianUInt32(2160)
    let oldCaps = drdynvc(RDPDynamicVirtualChannelDataPDU(channelID: 2, payload: caps).encoded())
    // The capture after its CapsConfirm (event 38), up to its first frame.
    let firstFrame = try KRdpCapture.events()[39...].map { try #require($0.bytes) }
    let announced = Locked([UInt32]())
    let run = try KRdpCapture.run(
        prefix: 39,
        appending: [create(2), oldCaps, create(3), oldCaps] + firstFrame,
        onDisplayControlReady: { session in announced.withLock { $0.append(session.dynamicChannelID) } }
    )

    #expect(run.report.error == nil)
    #expect(run.report.rdpDisplayControlChannelID == 3)
    #expect(announced.value.isEmpty)
}

/// A session for a DisplayControl channel the server replaced sends nothing; the new
/// channel's session sends ([MS-RDPEDISP] 2.2.2.1).
@Test func replacedDisplayControlChannelsSessionSendsNothing() throws {
    func drdynvc(_ payload: Data) -> Data {
        mcsSendDataIndication(
            channelID: KRdpCapture.drdynvcChannelID,
            userData: RDPStaticVirtualChannelPDU(payload: payload).encodedUserData()
        )
    }
    func create(_ channelID: UInt8) -> Data {
        drdynvc(Data([0x10, channelID]) + Data("Microsoft::Windows::RDS::DisplayControl".utf8) + Data([0]))
    }
    var caps = Data()
    caps.appendLittleEndianUInt32(5)
    caps.appendLittleEndianUInt32(20)
    caps.appendLittleEndianUInt32(1)
    caps.appendLittleEndianUInt32(3840)
    caps.appendLittleEndianUInt32(2160)
    func capsPacket(_ channelID: UInt32) -> Data {
        drdynvc(RDPDynamicVirtualChannelDataPDU(channelID: channelID, payload: caps).encoded())
    }
    func layoutData(_ channelID: UInt32) -> Data {
        RDPDynamicVirtualChannelDataPDU(
            channelID: channelID,
            payload: RDPDisplayControlMonitorLayoutPDU.singlePrimary(width: 1280, height: 720).encoded()
        ).encoded()
    }
    // The capture after its CapsConfirm (event 38), up to its first frame.
    let firstFrame = try KRdpCapture.events()[39...].map { try #require($0.bytes) }
    let sessions = Locked([RDPDisplayControlSession]())
    let run = try KRdpCapture.run(
        prefix: 39,
        appending: [create(2), capsPacket(2)] + firstFrame + [create(3), capsPacket(3)],
        frameCaptureLimit: nil,
        onTrailingClientPacket: { [newLayout = layoutData(3)] channel, packet in
            if packet.range(of: newLayout) != nil {
                KRdpCapture.endConnection(channel, .close)
            }
        },
        onDisplayControlReady: { session in
            let handedOut = sessions.withLock { sessions -> [RDPDisplayControlSession] in
                sessions.append(session)
                return sessions
            }
            for session in handedOut where handedOut.count == 2 {
                session.sendSingleMonitorLayout(width: 1280, height: 720)
            }
        }
    )

    #expect(sessions.value.map(\.dynamicChannelID) == [2, 3])
    #expect(run.clientPackets.contains { $0.range(of: layoutData(3)) != nil })
    #expect(!run.clientPackets.contains { $0.range(of: layoutData(2)) != nil })
}

/// Each connection milestone must arrive within the timeout however much
/// other traffic the server sends; here a pointer update every 200 ms, which
/// used to reset the wait forever.
@Test(arguments: [
    // Demand Active answered (event 20), no Synchronize/Control/Font Map.
    (21, "server did not grant control during connection finalization"),
    // RDPGFX caps advertised (event 34), no CapsConfirm.
    (35, "server did not confirm RDPGFX capabilities"),
    // CapsConfirm, but no frame for a capture run.
    (39, "receive failed: RDP Graphics Update timed out after 1 seconds"),
])
func chattyServerStillMissesTheMilestoneDeadline(prefix: Int, error: String) throws {
    // Without a deadline the run lasts until the guard cancels it.
    let run = try KRdpCapture.run(
        prefix: prefix,
        timeoutSeconds: 1,
        guardSeconds: 8,
        onEnd: KRdpCapture.repeatedly(KRdpCapture.pointerHidden, every: .milliseconds(200))
    )

    #expect(run.report.error == error)
}

/// How a live session's connection ends decides the outcome: a close, with
/// or without TLS close_notify, is a normal end; a reset or a broken TLS
/// record is a lost connection.
@Test(arguments: [
    (KRdpCapture.ConnectionEnd.close, nil),
    (KRdpCapture.ConnectionEnd.reset, "receive failed: connection lost: Connection reset by peer"),
    (KRdpCapture.ConnectionEnd.corruptTLSRecord, "receive failed: connection lost:"),
] as [(KRdpCapture.ConnectionEnd, String?)])
func liveSessionReportsALostConnectionAsAFailure(end: KRdpCapture.ConnectionEnd, error: String?) throws {
    // Once the client acknowledges the frame: it has the frame and sends nothing
    // more, so a close finds nothing unread and stays a clean close.
    let run = try KRdpCapture.run(frameCaptureLimit: nil, onTrailingClientPacket: { channel, packet in
        if packet.containsSubsequence(KRdpCapture.frameAcknowledgeHeader) {
            KRdpCapture.endConnection(channel, end)
        }
    })

    #expect(run.report.rdpGraphicsFirstFrame != nil)
    if let error {
        #expect(run.report.status == "failure")
        #expect(run.report.error?.hasPrefix(error) == true)
    } else {
        #expect(run.report.status == "success")
        #expect(run.report.error == nil)
    }
}

// MARK: - Transport waits

@Test func refusedConnectionSaysWhy() throws {
    // A port the system just handed out and nothing holds refuses connections.
    let socketFD = socket(AF_INET, SOCK_STREAM, 0)
    try #require(socketFD >= 0)
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let bound = withUnsafeMutablePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(socketFD, $0, length) == 0 && getsockname(socketFD, $0, &length) == 0
        }
    }
    close(socketFD)
    try #require(bound)

    let error = #expect(throws: RDPConnectionError.self) {
        try RDPSessionClient().connect(configuration: RDPConnectionConfiguration(
            host: "127.0.0.1",
            port: UInt16(bigEndian: address.sin_port)
        ))
    }
    #expect(error.map(String.init(describing:)) == "connect failed: Connection refused")
}

/// `shouldCancel` is polled while the transport waits on something other than
/// a receive; here a TLS handshake the server never answers.
@Test func shouldCancelStopsAStalledTLSHandshake() throws {
    let server = try ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
        .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
        .childChannelInitializer { channel in
            channel.eventLoop.makeCompletedFuture {
                try channel.pipeline.syncOperations.addHandler(SelectTLSThenStall())
            }
        }
        .bind(host: "127.0.0.1", port: 0)
        .wait()
    defer { server.close(promise: nil) }

    let started = Date()
    let report = RDPSessionClient().run(
        configuration: RDPConnectionConfiguration(
            host: "127.0.0.1",
            port: UInt16(try #require(server.localAddress?.port)),
            timeoutSeconds: 60
        ),
        shouldCancel: { Date().timeIntervalSince(started) > 0.5 }
    )

    #expect(report.error == "cancelled")
    #expect(Date().timeIntervalSince(started) < 10)
}

/// Answers the X.224 Connection Request by selecting TLS, then never speaks again.
private final class SelectTLSThenStall: ChannelInboundHandler, Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    // TPKT, X.224 Connection Confirm, RDP_NEG_RSP selecting PROTOCOL_SSL ([MS-RDPBCGR] 2.2.1.2).
    private static let connectionConfirm: [UInt8] = [
        0x03, 0x00, 0x00, 0x13, 0x0E, 0xD0, 0x00, 0x00, 0x12, 0x34, 0x00,
        0x02, 0x00, 0x08, 0x00, 0x01, 0x00, 0x00, 0x00,
    ]

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let request = unwrapInboundIn(data)
        guard request.getInteger(at: request.readerIndex + 5, as: UInt8.self) == 0xE0 else {
            return
        }
        context.writeAndFlush(wrapOutboundOut(ByteBuffer(bytes: Self.connectionConfirm)), promise: nil)
    }
}

// MARK: - KRdp capture harness

/// The KRdp capture's channels: I/O 1003, drdynvc 1004, message 1005, and
/// RDPGFX on dynamic channel 1, all uncompressed.
enum KRdpCapture {
    static let ioChannelID: UInt16 = 1003
    static let drdynvcChannelID: UInt16 = 1004
    static let messageChannelID: UInt16 = 1005
    static let graphicsChannelID: UInt32 = 1
    /// How a client RDPGFX_FRAME_ACKNOWLEDGE_PDU on the graphics channel starts:
    /// DVC Data with a one-byte channel ID, then the RDPGFX command ID.
    static let frameAcknowledgeHeader = Data([0x30, UInt8(graphicsChannelID), 0x0D, 0x00])

    struct Run {
        var report: RDPConnectionReport
        var clientPackets: [Data]
    }

    static func events() throws -> [RDPWireEvent] {
        try loadTranscriptFixture("krdp-negotiation-transcript")
    }

    /// Replays the capture (or its first `prefix` events) followed by
    /// `appending`, then hands the connection to `onEnd`, and to
    /// `onTrailingClientPacket` with each packet the client sends after that.
    /// The run is cancelled after `guardSeconds` so a hang fails the test
    /// instead of stalling it.
    static func run(
        prefix: Int? = nil,
        appending packets: [Data] = [],
        frameCaptureLimit: Int? = 1,
        timeoutSeconds: Int = 10,
        guardSeconds: Double = 20,
        onEnd: (@Sendable (Channel) -> Void)? = nil,
        onTrailingClientPacket: (@Sendable (Channel, Data) -> Void)? = nil,
        onDisplayControlReady: RDPDisplayControlSessionHandler? = nil
    ) throws -> Run {
        var events = try events()
        if let prefix {
            events = Array(events.prefix(prefix))
        }
        for packet in packets {
            events.append(RDPWireEvent(
                sequence: events.count,
                direction: .serverToClient,
                layer: .application,
                byteCount: packet.count,
                hex: packet.rdpHexString
            ))
        }
        let credentials = RDPCredentials(username: "rdp-user", password: "rdp-user")
        let server = try RDPTranscriptReplayServer(
            transcript: events,
            credentials: credentials,
            onSegmentEnd: onEnd,
            onTrailingClientPacket: onTrailingClientPacket
        )
        defer { server.stop() }

        let cancellation = RDPConnectionCancellation()
        DispatchQueue(label: "KRdpCapture.guard").asyncAfter(deadline: .now() + guardSeconds) {
            cancellation.cancel()
        }
        let report = RDPSessionClient().run(
            configuration: RDPConnectionConfiguration(
                host: "127.0.0.1",
                port: server.port,
                credentials: credentials,
                timeoutSeconds: timeoutSeconds,
                hideCertificateWarnings: true,
                graphicsFrameCaptureLimit: frameCaptureLimit,
                desktopWidth: 1280,
                desktopHeight: 720,
                clipboardEnabled: false,
                graphicsCapabilityProfile: .avcThinClient
            ),
            onDisplayControlReady: onDisplayControlReady,
            cancellation: cancellation
        )
        cancellation.cancel()
        server.waitForClientsToClose()
        return Run(report: report, clientPackets: server.clientPackets.value)
    }

    static func ioPacket(_ userData: Data) -> Data {
        mcsSendDataIndication(channelID: ioChannelID, userData: userData)
    }

    static func messageChannelPacket(_ userData: Data) -> Data {
        mcsSendDataIndication(channelID: messageChannelID, userData: userData)
    }

    /// A Share Control PDU of `type` from the server channel ([MS-RDPBCGR] 2.2.8.1.1.1.1).
    static func shareControl(type: UInt16, body: Data) -> Data {
        var data = Data()
        data.appendLittleEndianUInt16(UInt16(6 + body.count))
        data.appendLittleEndianUInt16(type | 0x10)
        data.appendLittleEndianUInt16(0x03EA)
        data.append(body)
        return data
    }

    /// A Share Data PDU for the capture's share ([MS-RDPBCGR] 2.2.8.1.1.1.2).
    static func shareData(pduType2: UInt8, payload: Data) -> Data {
        var body = Data()
        body.appendLittleEndianUInt32(shareID)
        body.appendUInt8(0)
        body.appendUInt8(1)
        body.appendLittleEndianUInt16(UInt16(payload.count))
        body.appendUInt8(pduType2)
        body.appendUInt8(0)
        body.appendLittleEndianUInt16(0)
        body.append(payload)
        return shareControl(type: 0x7, body: body)
    }

    static let shareID: UInt32 = 0x0001_03EE

    /// A Server Redirection PDU carrying a routing token ([MS-RDPBCGR] 2.2.13.3.1).
    static func redirection(flags: UInt32, password: Data? = nil) -> Data {
        var fields = Data()
        let cookie = Data("Cookie: msts=3640205228.15629.0000\r\n".utf8)
        fields.appendLittleEndianUInt32(UInt32(cookie.count))
        fields.append(cookie)
        if let password {
            fields.appendLittleEndianUInt32(UInt32(password.count))
            fields.append(password)
        }
        var body = Data()
        body.appendLittleEndianUInt16(0)
        body.appendLittleEndianUInt16(0x0400)
        body.appendLittleEndianUInt16(UInt16(12 + fields.count))
        body.appendLittleEndianUInt32(7)
        body.appendLittleEndianUInt32(flags | (password == nil ? 0 : RDPServerRedirectionPDU.Flags.password.rawValue))
        body.append(fields)
        return shareControl(type: 0xA, body: body)
    }

    /// RDPGFX PDUs on the capture's graphics channel, as one uncompressed
    /// RDP8 segment ([MS-RDPEGFX] 2.2.5.1) in a complete DVC message.
    static func graphicsPacket(_ messages: Data, channelID: UInt32 = graphicsChannelID) -> Data {
        let dynamic = RDPDynamicVirtualChannelDataPDU(channelID: channelID, payload: Data([0xE0, 0x04]) + messages).encoded()
        return mcsSendDataIndication(
            channelID: drdynvcChannelID,
            userData: RDPStaticVirtualChannelPDU(payload: dynamic).encodedUserData()
        )
    }

    static func startFrame(id: UInt32) -> Data {
        var body = Data()
        body.appendLittleEndianUInt32(0)
        body.appendLittleEndianUInt32(id)
        return graphicsMessage(commandID: RDPGFXCommandID.startFrame, payload: body)
    }

    static func endFrame(id: UInt32) -> Data {
        var body = Data()
        body.appendLittleEndianUInt32(id)
        return graphicsMessage(commandID: RDPGFXCommandID.endFrame, payload: body)
    }

    /// A WireToSurface1 AVC420 update for the capture's surface 1 ([MS-RDPEGFX] 2.2.2.1, 2.2.4.4).
    static func avc420Update() -> Data {
        var stream = Data()
        stream.appendLittleEndianUInt32(1)
        stream.append(contentsOf: [0, 0, 0, 0, 16, 0, 16, 0])
        stream.append(contentsOf: [22, 100])
        stream.append(contentsOf: [0x00, 0x00, 0x00, 0x01, 0x65, 0x88])
        var body = Data()
        body.appendLittleEndianUInt16(1)
        body.appendLittleEndianUInt16(RDPGFXCodecID.avc420)
        body.appendUInt8(0x20)
        body.append(contentsOf: [0, 0, 0, 0, 16, 0, 16, 0])
        body.appendLittleEndianUInt32(UInt32(stream.count))
        body.append(stream)
        return graphicsMessage(commandID: RDPGFXCommandID.wireToSurface1, payload: body)
    }

    static func emptyGraphicsFrame(id: UInt32) -> Data {
        graphicsPacket(startFrame(id: id) + endFrame(id: id))
    }

    /// A fast-path Set Surface Bits update of one uncompressed 32 bpp pixel ([MS-RDPBCGR] 2.2.9.2.1).
    static func fastPathSurfaceBits(left: UInt16, top: UInt16, pixel: Data) -> Data {
        var command = Data()
        command.appendLittleEndianUInt16(0x0001)
        command.appendLittleEndianUInt16(left)
        command.appendLittleEndianUInt16(top)
        command.appendLittleEndianUInt16(left + 1)
        command.appendLittleEndianUInt16(top + 1)
        command.append(contentsOf: [32, 0, 0, 0])
        command.appendLittleEndianUInt16(1)
        command.appendLittleEndianUInt16(1)
        command.appendLittleEndianUInt32(UInt32(pixel.count))
        command.append(pixel)
        return fastPathPacket(fastPathUpdate(code: 0x04, payload: command))
    }

    /// `demandActive` with its Bitmap Capability Set's desktop size replaced ([MS-RDPBCGR] 2.2.7.1.2).
    static func settingDesktopSize(of demandActive: Data, width: UInt16, height: UInt16) throws -> Data {
        var packet = demandActive
        let offset = try #require(bitmapCapabilityOffset(in: packet))
        packet.replaceSubrange(offset + 12 ..< offset + 16, with: [
            UInt8(width & 0xFF), UInt8(width >> 8), UInt8(height & 0xFF), UInt8(height >> 8),
        ])
        return packet
    }

    /// The desktop size in a client Confirm Active PDU's Bitmap Capability Set.
    static func confirmActiveDesktopSize(_ packet: Data) -> (width: UInt16, height: UInt16)? {
        let bytes = [UInt8](packet)
        guard bytes.count > 22, bytes[7] == 0x64, let offset = bitmapCapabilityOffset(in: packet) else {
            return nil
        }
        return (UInt16(bytes[offset + 12]) | UInt16(bytes[offset + 13]) << 8,
                UInt16(bytes[offset + 14]) | UInt16(bytes[offset + 15]) << 8)
    }

    /// Where the Bitmap Capability Set starts in a Demand or Confirm Active TPKT.
    private static func bitmapCapabilityOffset(in packet: Data) -> Int? {
        let bytes = [UInt8](packet)
        func uint16(_ offset: Int) -> Int {
            Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
        }
        // TPKT (4), X.224 Data (3), MCS header (5), PER length (1 or 2).
        let userData = 13 + (bytes[13] & 0x80 == 0 ? 1 : 2)
        guard bytes.count > userData + 14, uint16(userData + 2) & 0xF == 0x3 || uint16(userData + 2) & 0xF == 0x1 else {
            return nil
        }
        // Share Control header (6), shareID (4), then the descriptor lengths;
        // Confirm Active has an originatorID (2) before them.
        let lengths = userData + 10 + (uint16(userData + 2) & 0xF == 0x3 ? 2 : 0)
        var offset = lengths + 4 + uint16(lengths) + 4
        for _ in 0 ..< uint16(lengths + 4 + uint16(lengths)) {
            guard offset + 4 <= bytes.count else {
                return nil
            }
            if uint16(offset) == 0x0002 {
                return offset
            }
            offset += uint16(offset + 2)
        }
        return nil
    }

    enum ConnectionEnd: Sendable {
        /// TCP close without TLS close_notify.
        case close
        /// TCP reset.
        case reset
        /// Bytes that are not a TLS record.
        case corruptTLSRecord
    }

    /// Ends the connection below TLS, on the event loop.
    static func endConnection(_ channel: Channel, _ end: ConnectionEnd) {
        guard let tls = try? channel.pipeline.syncOperations.context(handlerType: NIOSSLServerHandler.self) else {
            return
        }
        switch end {
        case .close:
            tls.close(promise: nil)
        case .reset:
            (channel as? SocketOptionProvider)?.setSoLinger(linger(l_onoff: 1, l_linger: 0)).whenComplete { _ in
                endConnection(channel, .close)
            }
        case .corruptTLSRecord:
            var buffer = channel.allocator.buffer(capacity: 37)
            buffer.writeBytes(Data(repeating: 0x5A, count: 37))
            tls.writeAndFlush(NIOAny(buffer), promise: nil)
        }
    }

    /// A fast-path hidden-pointer update: traffic that advances no milestone.
    static let pointerHidden = Data([0x00, 0x05, 0x05, 0x00, 0x00])

    /// Sends `packet` every `interval` until the connection closes.
    static func repeatedly(_ packet: Data, every interval: TimeAmount) -> @Sendable (Channel) -> Void {
        { channel in
            let task = channel.eventLoop.scheduleRepeatedTask(initialDelay: interval, delay: interval) { _ in
                var buffer = channel.allocator.buffer(capacity: packet.count)
                buffer.writeBytes(packet)
                channel.writeAndFlush(buffer, promise: nil)
            }
            channel.closeFuture.whenComplete { _ in
                task.cancel()
            }
        }
    }
}
