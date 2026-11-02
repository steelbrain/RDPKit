import Foundation
import RDPKit
import RDPKitTesting
import Testing

/// The test server's session sends as a connection's does, holds what the server laid out, and
/// ends when the test ends it.
@Test(.timeLimit(.minutes(1)))
func displayControlTestServerLaysOutAndEndsItsSession() async throws {
    let connectLayout = RDPMonitorLayout.singlePrimary(width: 1280, height: 720, desktopScaleFactor: 200)
    let server = try await RDPDisplayControlTestServer(connectLayout: connectLayout)
    let session = server.session
    #expect(session.connectLayout == connectLayout)
    #expect(session.serverMonitors.isEmpty)
    #expect(session.graphicsResetCount == 0)
    #expect(session.isEnded == false)

    let layout = RDPMonitorLayout.singlePrimary(width: 1920, height: 1080)
    #expect(try session.send(layout))
    #expect(session.isLastSentLayoutPending)
    let monitors = [RDPRemoteMonitor(rect: RDPFrameRect(left: 0, top: 0, right: 1920, bottom: 1080), isPrimary: true)]
    let serverLayout = server.resetGraphics(monitors: monitors, issues: .clipped)
    #expect(serverLayout == RDPServerLayout(monitors: monitors, monitorLayoutIssues: .clipped, graphicsResetCount: 1))
    #expect(session.serverMonitors == monitors)
    #expect(session.serverMonitorLayoutIssues == .clipped)
    #expect(session.graphicsResetCount == 1)
    #expect(session.isLastSentLayoutPending == false)
    #expect(try session.requestKeyframe())
    #expect(server.sentLayouts == [layout, layout])

    server.endSession()
    #expect(session.isEnded)
    #expect(try session.send(layout) == false)
    #expect(server.sentLayouts == [layout, layout])
}

/// The server's capabilities bound what the session sends, and one that lists no monitors is
/// asked for a keyframe at its graphics output's size.
@Test(.timeLimit(.minutes(1)))
func displayControlTestServerKeepsItsCapabilitiesAndOutput() async throws {
    let server = try await RDPDisplayControlTestServer(capabilities: RDPDisplayControlCapabilities(
        maxNumMonitors: 1,
        maxMonitorAreaFactorA: 1920,
        maxMonitorAreaFactorB: 1080
    ))
    #expect(throws: RDPMonitorLayoutError.self) {
        try server.session.send(.singlePrimary(width: 2560, height: 1440))
    }

    let output = RDPFrameRect(left: 0, top: 0, right: 1600, bottom: 900)
    #expect(server.resetGraphics(monitors: [], outputRect: output).graphicsOutputRect == output)
    #expect(server.resetGraphics(monitors: [], outputRect: output).graphicsResetCount == 2)
    #expect(try server.session.requestKeyframe())
    #expect(server.sentLayouts == [try RDPMonitorLayout(
        remoteMonitors: [RDPRemoteMonitor(rect: output, isPrimary: true)],
        scaleFactors: RDPDisplayScaleFactors(desktopScaleFactor: 100, deviceScaleFactor: 100)
    )])
}
