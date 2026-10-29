import Foundation

// Threading: see `RDPSessionClient`.

/// Receives each decoded graphics frame. Throwing ends the session with
/// `RDPConnectionFailure.graphicsFrameHandler`; the frame is not acknowledged.
public typealias RDPGraphicsFrameHandler = (RDPGraphicsFrameSnapshot) throws -> Void
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
/// without `onClipboardContent`. Not called while `fetchesRemoteCopies` is off; a copy that
/// came then is reported once it is turned back on, unless a newer copy, local or remote,
/// replaced it first. Windows 11 sends an empty Format List when its clipboard is emptied;
/// gnome-remote-desktop 51 sends nothing then.
public typealias RDPClipboardRemoteCopyUnavailableHandler = @Sendable (_ isEmpty: Bool) -> Void
public typealias RDPClipboardFileContentsHandler = @Sendable (RDPClipboardFileContentsResponse) -> Void
public typealias RDPAudioSampleHandler = @Sendable (RDPAudioSample) -> Void
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
}
