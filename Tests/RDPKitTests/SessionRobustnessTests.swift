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
    #expect(run.report.rdpGraphicsFrameAcknowledgeCount == 2)
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

/// A reactivation can set a desktop wider than 8192 pixels: Windows 11 sends a Demand Active
/// of 11520x2160 when a Display Control layout of three 3840x2160 monitors resizes a session
/// without RDPGFX (observed live). The client confirms it and draws its far corner.
@Test func reactivationTakesADesktopWiderThan8192Pixels() throws {
    let run = try runReactivation(toWidth: 11520, height: 2160, thenDrawingAt: (11519, 2159))

    #expect(run.report.error == nil)
    #expect(run.clientPackets.compactMap(KRdpCapture.confirmActiveDesktopSize).map { [$0.width, $0.height] }
        == [[1280, 720], [11520, 2160]])
    let primaryFrames = run.report.rdpGraphicsFrames?.filter { $0.codecName == "surface-bgra" } ?? []
    #expect(primaryFrames.last?.regionRects == [RDPFrameRect(left: 11519, top: 2159, right: 11520, bottom: 2160)])
}

/// A Demand Active desktop past what the client takes keeps the size it had: wider than the
/// 32,766 pixels of the largest desktop RDP describes ([MS-RDPBCGR] 2.2.1.3.6, [MS-RDPEGFX]
/// 2.2.2.14), or with a primary surface past the memory RDPGFX surfaces may take.
@Test(arguments: [[32767, 2160], [2160, 32767], [32766, 32766], [0, 2160]])
func reactivationIgnoresADesktopTheClientDoesNotTake(size: [UInt16]) throws {
    let run = try runReactivation(toWidth: size[0], height: size[1], thenDrawingAt: (1279, 719))

    #expect(run.report.error == nil)
    #expect(run.clientPackets.compactMap(KRdpCapture.confirmActiveDesktopSize).map { [$0.width, $0.height] }
        == [[1280, 720], [1280, 720]])
}

/// A Monitor Layout PDU after a reactivation's Demand Active, as Windows 11 sends one when a
/// Display Control layout reactivates a session without RDPGFX (observed live), is in the live
/// report by the time `onInputReady` hands out the reactivated session's input.
@Test func liveReportHoldsTheMonitorLayoutOfAReactivation() throws {
    let events = try KRdpCapture.events()
    var deactivate = Data()
    deactivate.appendLittleEndianUInt32(KRdpCapture.shareID)
    deactivate.append(contentsOf: [0x01, 0x00, 0x00])
    let finalization = try [21, 22, 27, 28].map { try #require(events[$0].bytes) }
    let liveReport = RDPLiveConnectionReport()
    let layoutsAtInputReady = Locked<[[RDPRemoteMonitor]?]>([])

    let run = try KRdpCapture.run(
        appending: [
            KRdpCapture.fastPathSurfaceBits(left: 0, top: 0, pixel: Data([1, 2, 3, 0xFF])),
            KRdpCapture.ioPacket(KRdpCapture.shareControl(type: 0x6, body: deactivate)),
            #require(events[19].bytes),
            KRdpCapture.monitorLayout([
                RDPMonitorDefinition(left: 0, top: 0, right: 1279, bottom: 719, flags: RDPMonitorDefinition.primary),
                RDPMonitorDefinition(left: 1280, top: 0, right: 2559, bottom: 719, flags: 0),
            ]),
        ] + finalization,
        frameCaptureLimit: 2,
        onEnd: { channel in
            channel.eventLoop.scheduleTask(in: .milliseconds(1500)) {
                let frame = KRdpCapture.fastPathSurfaceBits(left: 1, top: 1, pixel: Data([1, 2, 3, 0xFF]))
                var buffer = channel.allocator.buffer(capacity: frame.count)
                buffer.writeBytes(frame)
                channel.writeAndFlush(buffer, promise: nil)
            }
        },
        onInputReady: { _ in layoutsAtInputReady.withLock { $0.append(liveReport.snapshot?.rdpMonitorLayout) } },
        liveReport: liveReport
    )
    let layout = [
        RDPRemoteMonitor(rect: RDPFrameRect(left: 0, top: 0, right: 1280, bottom: 720), isPrimary: true),
        RDPRemoteMonitor(rect: RDPFrameRect(left: 1280, top: 0, right: 2560, bottom: 720), isPrimary: false),
    ]

    #expect(run.report.error == nil)
    #expect(layoutsAtInputReady.value == [nil, layout])
    #expect(run.report.rdpMonitorLayout == layout)
}

/// Replays the capture, a frame, then Deactivate All and the capture's Demand Active at
/// `width` x `height` with its finalization, and 1.5 s later a one-pixel frame at `point`.
private func runReactivation(
    toWidth width: UInt16,
    height: UInt16,
    thenDrawingAt point: (left: UInt16, top: UInt16)
) throws -> KRdpCapture.Run {
    let events = try KRdpCapture.events()
    var deactivate = Data()
    deactivate.appendLittleEndianUInt32(KRdpCapture.shareID)
    deactivate.append(contentsOf: [0x01, 0x00, 0x00])
    let demandActive = try KRdpCapture.settingDesktopSize(of: #require(events[19].bytes), width: width, height: height)
    let finalization = try [21, 22, 27, 28].map { try #require(events[$0].bytes) }
    let frame = KRdpCapture.fastPathSurfaceBits(left: point.left, top: point.top, pixel: Data([1, 2, 3, 0xFF]))

    return try KRdpCapture.run(
        appending: [
            KRdpCapture.fastPathSurfaceBits(left: 0, top: 0, pixel: Data([1, 2, 3, 0xFF])),
            KRdpCapture.ioPacket(KRdpCapture.shareControl(type: 0x6, body: deactivate)),
            demandActive,
        ] + finalization,
        frameCaptureLimit: 2
    ) { channel in
        channel.eventLoop.scheduleTask(in: .milliseconds(1500)) {
            var buffer = channel.allocator.buffer(capacity: frame.count)
            buffer.writeBytes(frame)
            channel.writeAndFlush(buffer, promise: nil)
        }
    }
}

/// A cancellation stops what is left of a fast-path PDU: cancelled as its pointer position
/// is handled, the bitmap update after it is never drawn, and stopping it is no decode
/// error. A bitmap update stops between rectangles too, as one can hold thousands.
@Test func cancellingStopsTheUpdatesLeftInAFastPathPDU() throws {
    // TS_UPDATE_BITMAP_DATA of one uncompressed 32 bpp pixel ([MS-RDPBCGR] 2.2.9.1.1.3.1.2).
    var bitmap = Data()
    for value: UInt16 in [0x0001, 1, 0, 0, 0, 0, 1, 1, 32, 0, 4] {
        bitmap.appendLittleEndianUInt16(value)
    }
    bitmap.append(contentsOf: [1, 2, 3, 0xFF])
    // TS_POINT16 of a position the capture never sends.
    var position = Data()
    position.appendLittleEndianUInt16(1234)
    position.appendLittleEndianUInt16(567)
    let cancellation = RDPConnectionCancellation()
    let bitmapFrames = Locked(0)
    let run = try KRdpCapture.run(
        appending: [fastPathPacket([
            // FASTPATH_UPDATETYPE_PTR_POSITION, then FASTPATH_UPDATETYPE_BITMAP.
            fastPathUpdate(code: 0x8, payload: position),
            fastPathUpdate(code: 0x1, payload: bitmap),
        ])],
        frameCaptureLimit: nil,
        onGraphicsFrame: { frame in
            if frame.contentKind == .bitmap {
                bitmapFrames.withLock { $0 += 1 }
            }
        },
        onRemotePointer: { update in
            if update == .position(RDPRemotePoint(x: 1234, y: 567)) {
                cancellation.cancel()
            }
        },
        cancellation: cancellation
    )

    #expect(run.report.failure == .cancelled)
    #expect(bitmapFrames.value == 0)
    #expect(!run.report.warnings.contains { $0.code == "graphics-decode-error" })
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

/// A deactivated session waits for the next Demand Active: a close or silence
/// before it fails the session as that close or that timeout.
@Test(arguments: [
    (true, RDPConnectionFailure.connectionClosed),
    (false, RDPConnectionFailure.timedOut),
])
func deactivatedSessionThatNeverReactivatesFails(closes: Bool, failure: RDPConnectionFailure) throws {
    var deactivate = Data()
    deactivate.appendLittleEndianUInt32(KRdpCapture.shareID)
    deactivate.append(contentsOf: [0x01, 0x00, 0x00])
    // Closed once the client acknowledges the frame, which comes before the
    // Deactivate All, so the close finds nothing unread.
    let run = try KRdpCapture.run(
        appending: [KRdpCapture.ioPacket(KRdpCapture.shareControl(type: 0x6, body: deactivate))],
        frameCaptureLimit: nil,
        timeoutSeconds: 1,
        guardSeconds: 8,
        onTrailingClientPacket: { channel, packet in
            if closes, packet.containsSubsequence(KRdpCapture.frameAcknowledgeHeader) {
                KRdpCapture.endConnection(channel, .close)
            }
        }
    )

    #expect(run.report.rdpGraphicsFirstFrame != nil)
    #expect(run.report.status == "failure")
    #expect(run.report.error == "server deactivated the session during RDP graphics updates")
    #expect(run.report.failure == failure)
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

/// An Alpha update over video copies its whole rectangle and is held until the frame ends, so
/// a few bytes each on the wire, a server that never ends the frame must not grow them without bound.
@Test func frameWhoseUpdatesHoldTooManyBytesIsBounded() throws {
    let updates = (0 ... RDPClientConnection.maximumPendingGraphicsDesktopCount).map { _ in
        KRdpCapture.graphicsPacket(KRdpCapture.alphaUpdate())
    }
    let run = try KRdpCapture.run(
        appending: [KRdpCapture.graphicsPacket(KRdpCapture.startFrame(id: 1) + KRdpCapture.avc420Update())] + updates,
        frameCaptureLimit: 2,
        timeoutSeconds: 3
    )

    #expect(run.report.error == "server sent more than 16 desktops of updates without ending the frame")
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
/// used to reset the wait forever. A live session's first frame is such a
/// milestone too.
@Test(arguments: [
    // Demand Active answered (event 20), no Synchronize/Control/Font Map.
    (21, 1, "server did not grant control during connection finalization"),
    // RDPGFX caps advertised (event 34), no CapsConfirm.
    (35, 1, "server did not confirm RDPGFX capabilities"),
    // CapsConfirm, but no frame for a capture run.
    (39, 1, "receive failed: RDP Graphics Update timed out after 1 seconds"),
    // Finalization done (event 28), but no RDPGFX channel or other frame for a live session.
    (29, nil, "receive failed: RDP Graphics Update timed out after 1 seconds"),
    // CapsConfirm, but no first frame for a live session.
    (39, nil, "receive failed: RDP Graphics Update timed out after 1 seconds"),
] as [(Int, Int?, String)])
func chattyServerStillMissesTheMilestoneDeadline(prefix: Int, frameCaptureLimit: Int?, error: String) throws {
    // Without a deadline the run lasts until the guard cancels it.
    let run = try KRdpCapture.run(
        prefix: prefix,
        frameCaptureLimit: frameCaptureLimit,
        timeoutSeconds: 1,
        guardSeconds: 8,
        onEnd: KRdpCapture.repeatedly(KRdpCapture.pointerHidden, every: .milliseconds(200))
    )

    #expect(run.report.error == error)
    #expect(run.report.failure == .timedOut)
}

/// An empty frame gives a live session nothing to show, so it does not put
/// off the deadline for the first frame.
@Test func emptyFramesDoNotPostponeALiveSessionsFirstFrame() throws {
    let run = try KRdpCapture.run(
        prefix: 39,
        frameCaptureLimit: nil,
        timeoutSeconds: 1,
        guardSeconds: 8,
        onEnd: KRdpCapture.repeatedly(KRdpCapture.emptyGraphicsFrame(id: 1), every: .milliseconds(200))
    )

    #expect(run.report.rdpGraphicsFirstFrame == nil)
    #expect(run.report.rdpGraphicsFrameAcknowledgeHexes?.isEmpty == false)
    #expect(run.report.error == "receive failed: RDP Graphics Update timed out after 1 seconds")
}

/// Once a live session shows frames it waits for the next one indefinitely,
/// through silence or other traffic, until the guard cancels it.
@Test(arguments: [false, true])
func liveSessionWaitsIndefinitelyAfterItsFirstFrame(chatty: Bool) throws {
    let run = try KRdpCapture.run(
        frameCaptureLimit: nil,
        timeoutSeconds: 1,
        guardSeconds: 3,
        onEnd: chatty ? KRdpCapture.repeatedly(KRdpCapture.pointerHidden, every: .milliseconds(200)) : nil
    )

    #expect(run.report.rdpGraphicsFirstFrame != nil)
    #expect(run.report.error == "cancelled")
}

/// A frame the handler cannot show, such as video it fails to decode, is acknowledged and the
/// session goes on, but the frame is not the first a live session waits for: frames that keep
/// failing end it at the timeout, whether they come through RDPGFX or as bitmap updates.
@Test(arguments: [
    // The capture's own first frame, then a video frame every 200 ms.
    (nil, KRdpCapture.graphicsPacket(KRdpCapture.startFrame(id: 2) + KRdpCapture.avc420Update() + KRdpCapture.endFrame(id: 2))),
    // Finalization done (event 28), then a bitmap update every 200 ms.
    (29, KRdpCapture.fastPathSurfaceBits(left: 0, top: 0, pixel: Data([1, 2, 3, 0xFF]))),
] as [(Int?, Data)])
func liveSessionEndsWhenTheHandlerShowsNoFrameInTime(prefix: Int?, frame: Data) throws {
    let handled = Locked(0)
    let run = try KRdpCapture.run(
        prefix: prefix,
        frameCaptureLimit: nil,
        timeoutSeconds: 1,
        guardSeconds: 8,
        onEnd: KRdpCapture.repeatedly(frame, every: .milliseconds(200)),
        onGraphicsFrame: { _ in
            handled.withLock { $0 += 1 }
            throw RDPGraphicsFrameNotPresented(reason: "awaiting a keyframe")
        }
    )

    #expect(run.report.rdpGraphicsFirstFrame != nil)
    #expect(handled.value > 2)
    if prefix == nil {
        #expect((run.report.rdpGraphicsFrameAcknowledgeCount ?? 0) > 2)
    }
    #expect(run.report.failure == .graphicsFrameHandler)
    #expect(run.report.error == "graphics frame handler showed no frame within 1 seconds: awaiting a keyframe")
}

/// The first frame the handler shows ends the wait, as any frame does for a handler that never
/// throws `RDPGraphicsFrameNotPresented`.
@Test func aFrameTheHandlerShowsEndsALiveSessionsWaitForItsFirstFrame() throws {
    let handled = Locked(0)
    let run = try KRdpCapture.run(
        frameCaptureLimit: nil,
        timeoutSeconds: 1,
        guardSeconds: 3,
        onEnd: KRdpCapture.repeatedly(
            KRdpCapture.graphicsPacket(KRdpCapture.startFrame(id: 2) + KRdpCapture.avc420Update() + KRdpCapture.endFrame(id: 2)),
            every: .milliseconds(200)
        ),
        onGraphicsFrame: { _ in
            // The capture's frame, then the first repeated one, fail to show.
            if handled.withLock({ count in
                count += 1
                return count <= 2
            }) {
                throw RDPGraphicsFrameNotPresented(reason: "awaiting a keyframe")
            }
        }
    )

    #expect(handled.value > 2)
    #expect(run.report.error == "cancelled")
}

/// A live session keeps the first 8 frame acknowledgements, and counts them all.
@Test func liveSessionCountsEveryFrameAcknowledgement() throws {
    let frameIDs = UInt32(0x5EED_0001) ... 0x5EED_000C
    let lastFrameID = withUnsafeBytes(of: frameIDs.upperBound.littleEndian) { Data($0) }
    let run = try KRdpCapture.run(
        appending: frameIDs.map { KRdpCapture.emptyGraphicsFrame(id: $0) },
        frameCaptureLimit: nil,
        onTrailingClientPacket: { channel, packet in
            if packet.containsSubsequence(KRdpCapture.frameAcknowledgeHeader), packet.containsSubsequence(lastFrameID) {
                KRdpCapture.endConnection(channel, .close)
            }
        }
    )
    let acknowledgements = run.clientPackets.filter { $0.containsSubsequence(KRdpCapture.frameAcknowledgeHeader) }

    #expect(run.report.status == "success")
    #expect(acknowledgements.count > frameIDs.count)
    #expect(run.report.rdpGraphicsFrameAcknowledgeCount == acknowledgements.count)
    #expect(run.report.rdpGraphicsFrameAcknowledgeHexes?.count == 8)
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
        #expect(run.report.failure == .connectionLost)
    } else {
        #expect(run.report.status == "success")
        #expect(run.report.error == nil)
        #expect(run.report.failure == nil)
    }
}

/// Once a session shows frames, the server ending it for the user, an
/// administrator, a time limit or another connection is a normal end, and
/// any other reason a failure ([MS-RDPBCGR] 2.2.5.1.1).
@Test(arguments: [
    (0x0000_0001, .admin, true),
    (0x0000_0003, .timeLimit, true),
    (0x0000_0005, .replaced, true),
    (0x0000_000C, .user, true),
    (0x0000_0009, .accessDenied, false),
    (0x0000_0103, .licensing, false),
    (0x0000_10D2, .protocolError, false),
] as [(UInt32, RDPRemoteTermination.Category, Bool)])
func liveSessionEndsNormallyOnlyForReasonsThatAreNoFailure(
    errorInfo: UInt32,
    category: RDPRemoteTermination.Category,
    isNormalEnd: Bool
) throws {
    var setErrorInfo = Data()
    setErrorInfo.appendLittleEndianUInt32(errorInfo)
    let ending = KRdpCapture.ioPacket(KRdpCapture.shareData(pduType2: 0x2F, payload: setErrorInfo))
        + MCSDisconnectProviderUltimatumPDU.userRequested.encodedTPKT()
    let run = try KRdpCapture.run(frameCaptureLimit: nil, onTrailingClientPacket: { channel, packet in
        if packet.containsSubsequence(KRdpCapture.frameAcknowledgeHeader) {
            channel.writeAndFlush(channel.allocator.buffer(bytes: ending), promise: nil)
            KRdpCapture.endConnection(channel, .close)
        }
    })

    let termination = RDPRemoteTermination(errorInfo: errorInfo, disconnectReason: 3)
    #expect(termination.category == category)
    #expect(run.report.rdpGraphicsFirstFrame != nil)
    #expect(run.report.remoteTermination == termination)
    #expect(run.report.nextStage == (isNormalEnd ? "rdp-session-ended" : nil))
    if isNormalEnd {
        #expect(run.report.status == "success")
        #expect(run.report.failure == nil)
        #expect(run.report.error == nil)
    } else {
        #expect(run.report.status == "failure")
        #expect(run.report.failure == .serverTermination(termination: termination))
        #expect(run.report.error == termination.description)
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

    let configuration = RDPConnectionConfiguration(host: "127.0.0.1", port: UInt16(bigEndian: address.sin_port))
    let error = #expect(throws: RDPConnectionError.self) {
        try RDPSessionClient().connect(configuration: configuration)
    }
    #expect(error.map(String.init(describing:)) == "connect failed: Connection refused")
    #expect(error?.failure == .connect(error: RDPSocketError(errno: ECONNREFUSED)))

    let report = RDPSessionClient().run(configuration: configuration)
    #expect(report.connectionStage == .negotiation)
    #expect(report.failure == error?.failure)
    // connect's error carries the report run returns, from the configured server.
    #expect(error?.report == report)
    #expect(error?.redirectionDepth == 0)
    #expect(error?.target == configuration.target)
    guard case let .connect(socketError)? = report.failure else {
        Issue.record("expected a connect failure, got \(String(describing: report.failure))")
        return
    }
    #expect(socketError.category == .refused)
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
    /// The run is cancelled, through `cancellation`, after `guardSeconds` so a
    /// hang fails the test instead of stalling it.
    static func run(
        prefix: Int? = nil,
        appending packets: [Data] = [],
        frameCaptureLimit: Int? = 1,
        timeoutSeconds: Int = 10,
        guardSeconds: Double = 20,
        onEnd: (@Sendable (Channel) -> Void)? = nil,
        onTrailingClientPacket: (@Sendable (Channel, Data) -> Void)? = nil,
        onGraphicsFrame: RDPGraphicsFrameHandler? = nil,
        onInputReady: RDPInputSessionHandler? = nil,
        onDisplayControlReady: RDPDisplayControlSessionHandler? = nil,
        onRemotePointer: RDPRemotePointerHandler? = nil,
        liveReport: RDPLiveConnectionReport? = nil,
        cancellation: RDPConnectionCancellation = RDPConnectionCancellation()
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
            onGraphicsFrame: onGraphicsFrame,
            onRemotePointer: onRemotePointer,
            onInputReady: onInputReady,
            onDisplayControlReady: onDisplayControlReady,
            liveReport: liveReport,
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

    /// A Monitor Layout PDU of `monitors` ([MS-RDPBCGR] 2.2.12.1).
    static func monitorLayout(_ monitors: [RDPMonitorDefinition]) -> Data {
        var payload = Data()
        payload.appendLittleEndianUInt32(UInt32(monitors.count))
        for monitor in monitors {
            payload.append(monitor.encoded())
        }
        return ioPacket(shareData(pduType2: 0x37, payload: payload))
    }

    /// A Server Redirection PDU carrying a routing token ([MS-RDPBCGR] 2.2.13.3.1).
    static func redirection(flags: UInt32, password: Data? = nil, trailingBytes: Data = Data()) -> Data {
        var fields = Data()
        let cookie = Data("Cookie: msts=3640205228.15629.0000\r\n".utf8)
        fields.appendLittleEndianUInt32(UInt32(cookie.count))
        fields.append(cookie)
        if let password {
            fields.appendLittleEndianUInt32(UInt32(password.count))
            fields.append(password)
        }
        fields.append(trailingBytes)
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

    /// A WireToSurface1 Alpha update of one run over the capture's whole surface 1
    /// ([MS-RDPEGFX] 2.2.4.3).
    static func alphaUpdate() -> Data {
        var stream = Data()
        stream.appendLittleEndianUInt16(0x414C)
        stream.appendLittleEndianUInt16(1)
        stream.append(contentsOf: [0x80, 0xFF, 0xFF, 0xFF])
        stream.appendLittleEndianUInt32(1280 * 720)
        var body = Data()
        body.appendLittleEndianUInt16(1)
        body.appendLittleEndianUInt16(RDPGFXCodecID.alpha)
        body.appendUInt8(0x21)
        body.append(contentsOf: [0, 0, 0, 0, 0x00, 0x05, 0xD0, 0x02])
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
