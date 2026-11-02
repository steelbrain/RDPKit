import Foundation
@testable import RDPKit
import Testing

@Test func keyframeRequestsArePacedAndStopUntilVideoDecodesAgain() {
    var throttle = RDPKeyframeRequestThrottle()
    let start = Date()
    func requests(atIntervals intervals: [Double]) -> [Bool] {
        intervals.map { throttle.shouldRequest(at: start.addingTimeInterval($0 * RDPKeyframeRequestThrottle.minimumInterval)) }
    }

    #expect(requests(atIntervals: [0, 0.5, 1, 2, 3]) == [true, false, true, true, false])
    throttle.recordDecodedVideo()
    #expect(requests(atIntervals: [4]) == [true])
}

/// A failed decode is not shown but goes on, a cancelled one ends the session.
@Test func frameDecodeCompletionSaysWhetherTheFrameWasShown() throws {
    try RDPFrameDecodeCompletion.decoded.requirePresented()
    let notPresented = #expect(throws: RDPGraphicsFrameNotPresented.self) {
        try RDPFrameDecodeCompletion.failed(errorDescription: "awaiting a keyframe").requirePresented()
    }
    #expect(notPresented?.reason == "awaiting a keyframe")
    #expect(throws: RDPFrameDecodeQueueError.cancelled) {
        try RDPFrameDecodeCompletion.cancelled.requirePresented()
    }
}

/// The layout asking for a keyframe never changes the desktop: the one last sent while it is
/// unanswered, then the server's monitors at the scale last sent, and none Display Control
/// cannot send as they are.
@Test func keyframeRequestLayoutKeepsTheServersDesktop() throws {
    let layouts = RDPDisplayLayoutRecord(connectLayout: .singlePrimary(width: 1280, height: 720, desktopScaleFactor: 200))
    #expect(layouts.keyframeRequestLayout() == nil)

    let server = [
        RDPRemoteMonitor(rect: RDPFrameRect(left: 0, top: 0, right: 1920, bottom: 1080), isPrimary: true),
        RDPRemoteMonitor(rect: RDPFrameRect(left: 1920, top: 0, right: 3200, bottom: 1024), isPrimary: false),
    ]
    layouts.noteResetGraphics(monitors: server, issues: [])
    let atConnectScale = try RDPMonitorLayout(
        remoteMonitors: server,
        scaleFactors: RDPDisplayScaleFactors(desktopScaleFactor: 200, deviceScaleFactor: 100)
    )
    #expect(layouts.keyframeRequestLayout() == atConnectScale)

    let sent = RDPMonitorLayout.singlePrimary(width: 2560, height: 1440, desktopScaleFactor: 150, deviceScaleFactor: 140)
    layouts.noteSent(sent)
    #expect(layouts.keyframeRequestLayout() == sent)

    // The server answered with a desktop of its own choosing, which stays.
    let answered = [RDPRemoteMonitor(rect: RDPFrameRect(left: 0, top: 0, right: 2400, bottom: 1350), isPrimary: true)]
    layouts.noteResetGraphics(monitors: answered, issues: [])
    #expect(layouts.keyframeRequestLayout() == (try RDPMonitorLayout(
        remoteMonitors: answered,
        scaleFactors: RDPDisplayScaleFactors(desktopScaleFactor: 150, deviceScaleFactor: 140)
    )))

    layouts.noteResetGraphics(monitors: [RDPRemoteMonitor(rect: RDPFrameRect(left: 0, top: 0, right: 1279, bottom: 720), isPrimary: true)], issues: [])
    #expect(layouts.keyframeRequestLayout() == nil)
}

private func displayControlPackets() throws -> (channel: Data, caps: Data) {
    func drdynvc(_ payload: Data) -> Data {
        mcsSendDataIndication(
            channelID: KRdpCapture.drdynvcChannelID,
            userData: RDPStaticVirtualChannelPDU(payload: payload).encodedUserData()
        )
    }
    var caps = Data()
    for value: UInt32 in [5, 20, 4, 3840, 2400] {
        caps.appendLittleEndianUInt32(value)
    }
    return (
        drdynvc(Data([0x10, 0x02]) + Data("Microsoft::Windows::RDS::DisplayControl".utf8) + Data([0])),
        drdynvc(RDPDynamicVirtualChannelDataPDU(channelID: 2, payload: caps).encoded())
    )
}

/// KRdp's one 3840x2400 monitor, at the replay's connect scale, as the session asks for it.
private func krdpKeyframeRequestLayout() throws -> Data {
    let layout = try RDPMonitorLayout(
        remoteMonitors: [RDPRemoteMonitor(rect: RDPFrameRect(left: 0, top: 0, right: 3840, bottom: 2400), isPrimary: true)],
        scaleFactors: RDPDisplayScaleFactors(desktopScaleFactor: 100, deviceScaleFactor: 100)
    )
    return RDPDynamicVirtualChannelDataPDU(
        channelID: 2,
        payload: RDPDisplayControlMonitorLayoutPDU(monitors: layout.monitors).encoded()
    ).encoded()
}

/// Video the handler does not show makes the session ask for a keyframe with the server's own
/// layout, at once when Display Control is up, or once it opens.
@Test(arguments: [false, true])
func videoThatIsNotShownAsksForAKeyframe(displayControlOpensLate: Bool) throws {
    let displayControl = try displayControlPackets()
    let firstFrame = try KRdpCapture.events()[39...].map { try #require($0.bytes) }
    let layoutData = try krdpKeyframeRequestLayout()
    let run = try KRdpCapture.run(
        prefix: 39,
        appending: displayControlOpensLate
            ? firstFrame + [displayControl.channel, displayControl.caps]
            : [displayControl.channel, displayControl.caps] + firstFrame,
        frameCaptureLimit: nil,
        onTrailingClientPacket: { channel, packet in
            if packet.range(of: layoutData) != nil {
                KRdpCapture.endConnection(channel, .close)
            }
        },
        onGraphicsFrame: { _ in
            throw RDPGraphicsFrameNotPresented(reason: "awaiting a keyframe")
        }
    )

    #expect(run.clientPackets.contains { $0.range(of: layoutData) != nil })
    #expect(run.report.rdpKeyframeRequestCount == 1)
}

/// Video shown before Display Control opens drops the request held for it, and a session with
/// recovery off asks for nothing. The client cancels the session from the last callback before
/// the request would go out, so the server is still there to take it.
@Test(arguments: [true, false])
func keyframeRecoverySendsNothingOnceVideoIsShownOrWhenOff(recovers: Bool) throws {
    let displayControl = try displayControlPackets()
    let firstFrame = try KRdpCapture.events()[39...].map { try #require($0.bytes) }
    let layoutData = try krdpKeyframeRequestLayout()
    let shownVideo = KRdpCapture.graphicsPacket(
        KRdpCapture.startFrame(id: 900) + KRdpCapture.avc420Update() + KRdpCapture.endFrame(id: 900)
    )
    let cancellation = RDPConnectionCancellation()
    let handled = Locked(0)
    let run = try KRdpCapture.run(
        prefix: 39,
        appending: recovers
            ? firstFrame + [shownVideo, displayControl.channel, displayControl.caps]
            : [displayControl.channel, displayControl.caps] + firstFrame,
        frameCaptureLimit: nil,
        recoversVideoWithLayoutResend: recovers,
        onGraphicsFrame: { _ in
            let count = handled.withLock { $0 += 1; return $0 }
            if count == 1 {
                if !recovers {
                    cancellation.cancel()
                }
                throw RDPGraphicsFrameNotPresented(reason: "awaiting a keyframe")
            }
        },
        onDisplayControlReady: { _ in
            if recovers {
                cancellation.cancel()
            }
        },
        cancellation: cancellation
    )

    #expect(handled.value == (recovers ? 2 : 1))
    #expect(!run.clientPackets.contains { $0.range(of: layoutData) != nil })
    #expect(run.report.rdpKeyframeRequestCount == nil)
}
