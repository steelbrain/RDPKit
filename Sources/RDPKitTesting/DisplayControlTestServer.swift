import Foundation
import NIOCore
import NIOEmbedded
import RDPKit

/// The server's end of a Display Control channel in memory, so an app's tests drive its
/// `onDisplayControlReady` code with a real `RDPDisplayControlSession`. The test lays out the
/// server's monitors as a ResetGraphics does, ends the session as a server that replaces its
/// channel does, and reads the layouts the session sent.
public final class RDPDisplayControlTestServer: @unchecked Sendable {
    /// The session, to hand to the app's `onDisplayControlReady` handler.
    public let session: RDPDisplayControlSession
    private let channel: NIOAsyncTestingChannel
    private let layouts: RDPDisplayLayoutRecord
    private let sent: Sent

    /// A session whose server allows what `capabilities` say, of a connection that started
    /// with `connectLayout`; the server has laid out no monitors yet.
    public init(
        capabilities: RDPDisplayControlCapabilities = RDPDisplayControlCapabilities(
            maxNumMonitors: 16,
            maxMonitorAreaFactorA: 8192,
            maxMonitorAreaFactorB: 8192
        ),
        connectLayout: RDPMonitorLayout = .singlePrimary(width: 1280, height: 720)
    ) async throws {
        let channel = NIOAsyncTestingChannel()
        try await channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 3389))
        let sent = Sent()
        let layouts = RDPDisplayLayoutRecord(connectLayout: connectLayout) { layout in
            sent.lock.withLock { sent.layouts.append(layout) }
        }
        self.channel = channel
        self.layouts = layouts
        self.sent = sent
        session = RDPDisplayControlSession(
            dynamicChannelID: 2,
            capabilities: capabilities,
            userChannelID: 1007,
            staticChannelID: 1004,
            channel: channel,
            layouts: layouts
        )
    }

    deinit {
        let channel = channel
        Task { try? await channel.close() }
    }

    /// The layouts the session sent, in order: those `send(_:)` returned true for, and the
    /// keyframe requests and resends that went out.
    public var sentLayouts: [RDPMonitorLayout] {
        sent.lock.withLock { sent.layouts }
    }

    /// Lays out the server's graphics again, as a ResetGraphics does: the session's
    /// `serverMonitors` and `serverMonitorLayoutIssues` become these, its `graphicsResetCount`
    /// goes up by one, and the layout last sent is answered. `outputRect` is the graphics
    /// output, the desktop of a server that lists no monitors.
    ///
    /// Returns the layout the frames after this ResetGraphics carry, as `RDPLiveSession`
    /// delivers it to `onServerLayout`, for a test that feeds it to the app's handler.
    @discardableResult
    public func resetGraphics(
        monitors: [RDPRemoteMonitor],
        issues: RDPRemoteMonitorLayoutIssues = [],
        outputRect: RDPFrameRect? = nil
    ) -> RDPServerLayout {
        let resetCount = layouts.noteResetGraphics(outputRect: outputRect, monitors: monitors, issues: issues)
        return RDPServerLayout(
            monitors: monitors,
            monitorLayoutIssues: issues,
            graphicsResetCount: resetCount,
            graphicsOutputRect: outputRect
        )
    }

    /// Ends the session, as a server does when it opens another Display Control channel: it
    /// `isEnded` and sends nothing more.
    public func endSession() {
        session.end()
    }
}

private final class Sent: @unchecked Sendable {
    let lock = NSLock()
    var layouts: [RDPMonitorLayout] = []
}
