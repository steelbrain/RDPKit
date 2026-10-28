import Foundation

// Threading: `RDPPreflightClient.run`/`connect` block the calling thread for
// the whole session; call them from a dedicated thread, never from an event
// loop or a Swift concurrency executor. Every handler below runs synchronously
// on that thread, except `RDPWireReceiveHandler`, which runs on the NIO event
// loop and must not block. A slow handler delays every channel.

/// Receives each decoded graphics frame. Throwing ends the session with
/// `RDPPreflightError.graphicsFrameHandler`; the frame is not acknowledged.
public typealias RDPGraphicsFrameHandler = (RDPGraphicsFrameSnapshot) throws -> Void
public typealias RDPRemotePointerHandler = @Sendable (RDPRemotePointerUpdate) -> Void
/// Called after connection finalization, and again with a new session after a
/// server deactivation-reactivation (MS-RDPBCGR 1.3.1.3).
public typealias RDPInputSessionHandler = @Sendable (RDPInputSession) -> Void
public typealias RDPDisplayControlSessionHandler = @Sendable (RDPDisplayControlSession) -> Void
public typealias RDPClipboardSessionHandler = @Sendable (RDPClipboardSession) -> Void
public typealias RDPClipboardTextHandler = @Sendable (String) -> Void
public typealias RDPClipboardFileGroupDescriptorHandler = @Sendable (RDPClipboardFileGroupDescriptorW) -> Void
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
    var onClipboardFileGroupDescriptor: RDPClipboardFileGroupDescriptorHandler?
    var onClipboardFileContents: RDPClipboardFileContentsHandler?
    var onAudioSample: RDPAudioSampleHandler?
    var onCertificate: RDPServerCertificateHandler?
    var onWireReceive: RDPWireReceiveHandler?
    var wireTranscript: RDPWireTranscript?
    var cancellation: RDPConnectionCancellation?
    var shouldCancel: RDPCancellationHandler?

    var isCancelled: Bool {
        cancellation?.isCancelled == true || shouldCancel?() == true
    }

    func throwIfCancelled() throws {
        if isCancelled {
            throw RDPPreflightError.cancelled
        }
    }
}
