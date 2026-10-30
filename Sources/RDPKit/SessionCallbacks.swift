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
/// and the first graphics frame has been delivered, so the first layout sent finds an output
/// to resize: KRdp 6.8 ignores a layout that arrives before its video stream starts.
public typealias RDPDisplayControlSessionHandler = @Sendable (RDPDisplayControlSession) -> Void
public typealias RDPClipboardSessionHandler = @Sendable (RDPClipboardSession) -> Void
public typealias RDPClipboardTextHandler = @Sendable (String) -> Void
/// Receives every format fetched of a remote copy. Setting it makes the session fetch
/// HTML, RTF and bitmaps as well as text; `onClipboardText` still receives the text.
public typealias RDPClipboardContentHandler = @Sendable (RDPClipboardContent) -> Void
public typealias RDPClipboardFileGroupDescriptorHandler = @Sendable (RDPClipboardFileGroupDescriptorW) -> Void
/// Called for a remote copy none of which is fetched, so the copy delivered before is no
/// longer the server's: `isEmpty` when the server's clipboard was emptied (an empty Format
/// List), and otherwise it holds only formats the session does not fetch, such as a bitmap
/// without `onClipboardContent`, or every format asked for of it failed or came back empty.
/// A rich copy some formats of which arrive goes to `onClipboardContent` without the rest.
/// Not called while `fetchesRemoteCopies` is off; a copy that came then is reported once it
/// is turned back on, unless a newer copy, local or remote, replaced it first. Windows 11
/// sends an empty Format List when its clipboard is emptied; gnome-remote-desktop 51 sends
/// nothing then.
public typealias RDPClipboardRemoteCopyUnavailableHandler = @Sendable (_ isEmpty: Bool) -> Void
public typealias RDPClipboardFileContentsHandler = @Sendable (RDPClipboardFileContentsResponse) -> Void
public typealias RDPAudioSampleHandler = @Sendable (RDPAudioSample) -> Void
/// How long audio that `onAudioSample` hands on now waits before it is heard: the audio
/// queued ahead of it and the output's latency, as `RDPAudioPlayer.playbackDelay` reports.
/// Called on the session's thread after each `onAudioSample`. The Wave Confirm for the
/// sample reports when it is heard ([MS-RDPEA] 2.2.3.8), so the server can keep video in
/// step with the sound; FreeRDP adds its audio device's latency the same way.
public typealias RDPAudioPlaybackDelayHandler = @Sendable () -> Duration
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
