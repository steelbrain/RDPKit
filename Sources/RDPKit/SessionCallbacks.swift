import Foundation

// Threading: see `RDPSessionClient`.

/// Receives each decoded graphics frame. Throwing ends the session with
/// `RDPConnectionFailure.graphicsFrameHandler`; the frame is not acknowledged. Throwing
/// `RDPGraphicsFrameNotPresented` instead goes on with the session.
public typealias RDPGraphicsFrameHandler = (RDPGraphicsFrameSnapshot) throws -> Void

/// Thrown by an `onGraphicsFrame` handler for a frame it could not show, such as video that
/// failed to decode and waits for a keyframe. The session goes on and acknowledges the frame,
/// so the server keeps sending, but the frame does not count as shown. A live session waits
/// for its first frame only within `RDPConnectionConfiguration.timeoutSeconds`, and that is
/// the first frame the handler returns from; when none is shown in time, the session ends
/// with `RDPConnectionFailure.graphicsFrameHandler` and the last `reason`.
public struct RDPGraphicsFrameNotPresented: Error, CustomStringConvertible, Sendable {
    public var reason: String

    public init(reason: String) {
        self.reason = reason
    }

    public var description: String {
        reason
    }
}

public typealias RDPRemotePointerHandler = @Sendable (RDPRemotePointerUpdate) -> Void
/// Called after connection finalization, and again with a new session after a
/// server deactivation-reactivation (MS-RDPBCGR 1.3.1.3). A session sends nothing
/// once the server deactivates it, so resynchronize held keys on the new one.
public typealias RDPInputSessionHandler = @Sendable (RDPInputSession) -> Void
/// Called once the server's DisplayControl capabilities have arrived ([MS-RDPEDISP] 2.2.2.1)
/// and so has the first graphics frame, so the first layout sent finds an output to resize:
/// KRdp 6.8 ignores a layout that arrives before its video stream starts. It runs before
/// `onGraphicsFrame` gets that frame, so a handler whose first frame fails to decode can ask
/// for a keyframe (`RDPDisplayControlSession.resendLayout()`); the session's
/// `serverMonitors` already hold that frame's monitors.
public typealias RDPDisplayControlSessionHandler = @Sendable (RDPDisplayControlSession) -> Void
public typealias RDPClipboardSessionHandler = @Sendable (RDPClipboardSession) -> Void
/// Receives the text of a remote copy, with the copy's number, which is higher than that of
/// every copy, local or remote, before it: an application that hands the copy to another
/// thread, such as the main one, checks there with `RDPClipboardSession.hasPublished(since:)`
/// whether a publish replaced it meanwhile, and downloads a copy of files under its number
/// (`RDPClipboardSession.downloadRemoteFiles`). The other remote-copy handlers get it too.
public typealias RDPClipboardTextHandler = @Sendable (_ text: String, _ copyNumber: Int) -> Void
/// Receives every format fetched of a remote copy, and its number. Setting it makes the
/// session fetch HTML, RTF and bitmaps as well as text; `onClipboardText` still receives the
/// text.
public typealias RDPClipboardContentHandler = @Sendable (_ content: RDPClipboardContent, _ copyNumber: Int) -> Void
/// Receives the file list of a remote copy of files, and its number. Without it, such a copy
/// is fetched as any other, for the text or other formats it may offer beside the files; one
/// that offers none goes to `onClipboardRemoteCopyUnavailable`.
public typealias RDPClipboardFileGroupDescriptorHandler = @Sendable (
    _ list: RDPClipboardFileGroupDescriptorW,
    _ copyNumber: Int
) -> Void
/// Called, with its number, for a remote copy none of which is fetched, so the copy delivered
/// before is no longer the server's: `isEmpty` when the server's clipboard was emptied (an empty Format
/// List), and otherwise it holds only formats the session does not fetch, such as a bitmap
/// without `onClipboardContent` or files without `onClipboardFileGroupDescriptor`, or every
/// format asked for of it failed or came back empty.
/// A rich copy some formats of which arrive goes to `onClipboardContent` without the rest.
/// While `fetchesRemoteCopies` is off, it is called only for the server's clipboard emptied,
/// which brings nothing of it; another copy that came then is reported once fetching is
/// turned back on, unless a newer copy, local or remote, replaced it first. Windows 11
/// sends an empty Format List when its clipboard is emptied; gnome-remote-desktop 51 sends
/// nothing then.
public typealias RDPClipboardRemoteCopyUnavailableHandler = @Sendable (_ isEmpty: Bool, _ copyNumber: Int) -> Void
public typealias RDPClipboardFileContentsHandler = @Sendable (RDPClipboardFileContentsResponse) -> Void
public typealias RDPAudioSampleHandler = @Sendable (RDPAudioSample) -> Void
/// How long the sample `onAudioSample` is about to get will wait before it is heard: the
/// audio queued ahead of it and the output's latency, as `RDPAudioPlayer.playbackDelay`
/// reports. Called on the session's thread just before each `onAudioSample`; audio an app
/// has handed on that has not reached its player yet, such as samples on their way to the
/// main actor, is not counted. The Wave Confirm then reports when the sample is heard
/// ([MS-RDPEA] 2.2.3.8), so the server can keep video in step with the sound; FreeRDP's
/// second confirm adds its audio device's latency the same way.
public typealias RDPAudioPlaybackDelayHandler = @Sendable () -> Duration
/// Returns the client license to present when a server asks for one ([MS-RDPELE] 1.3.3), in
/// place of `RDPConnectionConfiguration.storedClientLicense`. Called on the session's thread
/// only once a server starts licensing, at most once per connection, so an application reads
/// its store, such as the Keychain, only then; the connection's deadline for its next step
/// starts once it returns, so a Keychain prompt takes none of that time.
public typealias RDPStoredClientLicenseProvider = @Sendable () -> RDPStoredClientLicense?
/// Receives a client license the server issued, new or upgraded ([MS-RDPELE] 2.2.2.6, 2.2.2.7),
/// on the session's thread as soon as it arrives, so an application can save it before the
/// session starts; `RDPConnectionReport.rdpIssuedClientLicense` holds it too. The
/// connection's deadline for its next step starts once it returns.
public typealias RDPClientLicenseIssuedHandler = @Sendable (RDPStoredClientLicense) -> Void
/// Runs on the NIO event loop for every server message, before it is processed.
public typealias RDPWireReceiveHandler = @Sendable (RDPWireReceiveSample) -> Void

public struct RDPWireReceiveSample: Encodable, Equatable, Sendable {
    public var byteCount: Int
    public var receivedAt: Date

    public init(byteCount: Int, receivedAt: Date) {
        self.byteCount = byteCount
        self.receivedAt = receivedAt
    }

    public var megabits: Double {
        Double(byteCount) * 8 / 1_000_000
    }
}

/// The handlers and cancellation sources of one `run`/`connect` call.
struct RDPSessionCallbacks {
    var onGraphicsFrame: RDPGraphicsFrameHandler?
    var onRemotePointer: RDPRemotePointerHandler?
    var onInputReady: RDPInputSessionHandler?
    var onDisplayControlReady: RDPDisplayControlSessionHandler?
    var onClipboardReady: RDPClipboardSessionHandler?
    var onClipboardText: RDPClipboardTextHandler?
    var onClipboardContent: RDPClipboardContentHandler?
    var onClipboardFileGroupDescriptor: RDPClipboardFileGroupDescriptorHandler?
    var onClipboardFileContents: RDPClipboardFileContentsHandler?
    var onClipboardRemoteCopyUnavailable: RDPClipboardRemoteCopyUnavailableHandler?
    var onAudioSample: RDPAudioSampleHandler?
    var audioPlaybackDelay: RDPAudioPlaybackDelayHandler?
    var onCertificate: RDPServerCertificateHandler?
    var storedClientLicenseProvider: RDPStoredClientLicenseProvider?
    var onClientLicenseIssued: RDPClientLicenseIssuedHandler?
    var onWireReceive: RDPWireReceiveHandler?
    var wireTranscript: RDPWireTranscript?
    var liveReport: RDPLiveConnectionReport?
    var cancellation: RDPConnectionCancellation?
    var shouldCancel: RDPCancellationHandler?

    var isCancelled: Bool {
        cancellation?.isCancelled == true || shouldCancel?() == true
    }

    func throwIfCancelled() throws {
        if isCancelled {
            throw RDPConnectionError.cancelled
        }
    }

    /// Whether `cancellation` is cancelled. It never polls `shouldCancel`, so any thread may
    /// check it as often as it likes: decoding checks it between the updates a message holds
    /// and between RemoteFX tiles, which in a debug build can take seconds to get through.
    var isCancelledWithoutPolling: @Sendable () -> Bool {
        let cancellation = cancellation
        return { cancellation?.isCancelled == true }
    }

    /// Throws `RDPConnectionError.cancelled` when `isCancelledWithoutPolling` says so.
    func throwIfCancelledWithoutPolling() throws {
        if isCancelledWithoutPolling() {
            throw RDPConnectionError.cancelled
        }
    }
}
