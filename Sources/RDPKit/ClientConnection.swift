import Foundation
import NIOCore

/// One connection to one server, from TCP connect to the end of the session
/// ([MS-RDPBCGR] 1.3.1.1). It runs on the thread that called
/// `RDPSessionClient.run`/`connect` and keeps everything it learns in
/// `report`.
final class RDPClientConnection {
    let configuration: RDPConnectionConfiguration
    let callbacks: RDPSessionCallbacks
    /// Frames to capture before the session ends; nil runs until the server ends it.
    let targetFrameCount: Int?
    var report: RDPConnectionReport
    var stage = RDPConnectionStage.negotiation
    var transport: RDPTransport?
    /// A Server Redirection PDU that ended this connection ([MS-RDPBCGR] 3.1.5.2).
    var redirection: RDPServerRedirectionPDU?

    // Security and channel connection.
    var selectedProtocols = RDPSecurityProtocols(rawValue: 0)
    var userChannelID: UInt16 = 0
    var ioChannelID: UInt16 = 0
    var messageChannelID: UInt16?
    var staticChannelNames: [UInt16: String] = [:]
    var drdynvcChannelID: UInt16?
    /// Display control, held back until the first graphics frame.
    var pendingDisplayControlSession: RDPDisplayControlSession?
    var serverCertificatePublicKey: RDPRSAPublicKey?
    let clientName = MCSConnectInitialConfiguration().clientName

    // Licensing and activation.
    var licensingComplete = false
    var licenseKeys: RDPLicenseKeys?
    var sawConnectTimeAutoDetect = false
    var autoDetectMeter = RDPAutoDetectBandwidthMeter()
    var share: RDPActiveShare?
    var awaitingPostConfirmActiveResponse = false
    var isDeactivated = false
    /// The input session `onInputReady` last handed out.
    var inputSession: RDPInputSession?
    var termination: RDPRemoteTermination?
    /// A non-zero Set Error Info was followed by Deactivate All: the server is
    /// disconnecting, and only the disconnect reason is still to come.
    var isTerminating = false
    var sessionEnded = false
    /// When the connection milestone being waited for must be reached.
    var phaseDeadline: NIODeadline?
    /// The session's desktop size: the one requested, then each Demand
    /// Active's ([MS-RDPBCGR] 1.3.1.3, 2.2.7.1.2).
    var desktopWidth: UInt16
    var desktopHeight: UInt16

    // Static virtual channels.
    var maximumChunkByteCount = RDPStaticVirtualChannelPDU.maximumPayloadByteCount
    var staticChannelReassemblers: [UInt16: RDPStaticVirtualChannelReassembler] = [:]
    var clipboard: RDPClipboardSession?
    let clipboardSentLog = RDPClipboardSentLog()
    var audio: RDPAudioSession?
    var deviceRedirection: RDPDeviceRedirectionSession?

    // Dynamic virtual channels.
    var dynamicChannelVersion: UInt16?
    var dynamicChannels: [UInt32: RDPDynamicChannelKind] = [:]
    var dynamicChannelFragments: [UInt32: RDPDynamicChannelFragment] = [:]
    var dynamicChannelDecompressors: [UInt32: RDPZGFXDecompressor] = [:]
    var dynamicAudio: RDPAudioSession?

    // Graphics.
    var graphicsChannelID: UInt32?
    var graphicsDecoder = RDPGFXServerTransportDecoder()
    var graphicsCompositor: RDPGFXSurfaceCompositor?
    let clearCodec = RDPClearCodecDecoder()
    var graphicsFrameTracker = RDPGFXLogicalFrameTracker()
    /// The current RDPGFX frame's updates for the decoder, in wire order.
    var pendingGraphicsUpdates: [RDPPendingGraphicsUpdate] = []
    /// Surfaces deleted, and the decoder's cache slots evicted, after the last delivered
    /// snapshot; the next one names them.
    var deletedGraphicsSurfaceIDs: [UInt16] = []
    var evictedGraphicsCacheSlots: [UInt16] = []
    var graphicsFramesDecoded: UInt32 = 0
    /// Created on first use at the current desktop size, again after a resize.
    private var primarySurfaceStorage: RDPPrimarySurfaceCompositor?
    var fastPathReassembler = RDPFastPathOutputFragmentReassembler(
        maximumBufferedByteCount: RDPStaticVirtualChannelReassembler.defaultMaximumTotalLength
    )
    var primaryFramesCaptured = 0
    let pointerState = RDPRemotePointerState()

    init(configuration: RDPConnectionConfiguration, callbacks: RDPSessionCallbacks) {
        self.configuration = configuration
        self.callbacks = callbacks
        targetFrameCount = configuration.graphicsFrameCaptureLimit.map { max(1, $0) }
        desktopWidth = configuration.desktopWidth
        desktopHeight = configuration.desktopHeight
        let request = configuration.connectionRequest
        report = RDPConnectionReport(
            status: "failure",
            stage: RDPConnectionStage.negotiation.rawValue,
            target: configuration.target,
            username: configuration.credentials?.username,
            domain: configuration.credentials?.domain,
            passwordConfigured: configuration.credentials != nil,
            requestedProtocols: request.negotiationRequest.requestedProtocols.names,
            requestHex: request.encodedTPKT().rdpHexString,
            rdpGraphicsCapabilityProfile: configuration.graphicsCapabilityProfile,
            warnings: []
        )
    }

    deinit {
        transport?.close()
    }

    var primarySurface: RDPPrimarySurfaceCompositor {
        if let primarySurfaceStorage {
            return primarySurfaceStorage
        }
        let surface = RDPPrimarySurfaceCompositor(width: desktopWidth, height: desktopHeight)
        primarySurfaceStorage = surface
        return surface
    }

    /// Takes the desktop size a Demand Active sets; a new size replaces the primary surface.
    func resizeDesktop(width: UInt16, height: UInt16) {
        guard (width, height) != (desktopWidth, desktopHeight) else {
            return
        }
        desktopWidth = width
        desktopHeight = height
        primarySurfaceStorage = nil
    }

    /// Connects and runs the X.224 negotiation ([MS-RDPBCGR] 3.2.5.3.1-2).
    /// Returns false when the negotiation response ends the connection; the
    /// reason is in `report.error`.
    func negotiate() throws -> Bool {
        let transport = try RDPTransport.connect(
            host: configuration.host,
            port: configuration.port,
            timeoutSeconds: configuration.timeoutSeconds,
            callbacks: callbacks
        )
        self.transport = transport
        let request = configuration.connectionRequest
        try transport.send(request.encodedTPKT())
        let response = try receive("X224 Connection Confirm")
        report.responseHex = response.rdpHexString
        let confirm = try X224ConnectionConfirm.parse(fromTPKT: response)
        report.negotiationFlags = confirm.negotiationFlags

        switch confirm.negotiationResult {
        case let .selected(protocols):
            report.selectedProtocols = protocols.names
            guard request.negotiationRequest.requestedProtocols.canSelect(protocols) else {
                return end(error: "server selected an unrequested security protocol")
            }
            guard protocols.usesTLS else {
                return end(error: protocols.rawValue == 0
                    ? "standard RDP security is not supported"
                    : "selected security protocol is not supported")
            }
            selectedProtocols = protocols
            return true
        case let .failure(code):
            report.failureCode = code
            return end(error: "RDP negotiation failed with code 0x\(String(format: "%08x", code))")
        case nil:
            return end(error: "standard RDP security is not supported")
        }
    }

    /// Runs everything after the negotiation and returns the final report.
    func runSession() -> RDPConnectionReport {
        do {
            try establishSecurity()
            try connectChannels()
            try sendClientInfo()
            while !sessionEnded {
                try receiveAndDispatch()
            }
        } catch {
            fail(error)
        }
        return finishReport()
    }

    /// Ends the attempt with `error` as the reason, for `run` after a thrown
    /// negotiation error.
    func failedReport(_ error: Error) -> RDPConnectionReport {
        fail(error)
        return finishReport()
    }

    private func end(error: String) -> Bool {
        report.error = error
        return false
    }

    private func fail(_ error: Error) {
        transport?.close()
        guard report.error == nil else {
            return
        }
        report.error = callbacks.isCancelled ? RDPConnectionError.cancelled.description : String(describing: error)
    }

    func finishReport() -> RDPConnectionReport {
        transport?.close()
        report.stage = stage.rawValue
        if clipboard != nil {
            report.rdpClipboardSentMessages = clipboardSentLog.snapshot
        }
        if let termination {
            report.rdpRemoteTerminationErrorInfo = termination.errorInfo
            report.rdpRemoteTerminationErrorInfoName = termination.errorInfoName
            report.rdpRemoteTerminationDisconnectReason = termination.disconnectReason
            report.rdpRemoteTerminationDisconnectReasonName = termination.disconnectReasonName
        }
        if report.error == nil {
            report.status = "success"
            report.nextStage = nextStage
        } else {
            report.status = "failure"
            report.nextStage = nil
        }
        return report
    }

    private var nextStage: String {
        if termination != nil {
            return "rdp-session-ended"
        }
        if graphicsCompositor != nil {
            return report.rdpGraphicsFrameAcknowledgeHexes?.isEmpty == false
                ? "rdp-graphics-frame-decode"
                : "rdp-graphics-pipeline-updates"
        }
        return "rdp-open-graphics-dynamic-channel"
    }

    // MARK: Sending and receiving

    func send(_ packet: Data) throws {
        guard let transport else {
            throw RDPConnectionError.send("not connected")
        }
        try transport.send(packet)
    }

    /// Sends `payload` on a static virtual channel as one complete chunk.
    func sendStaticChannelPayload(_ payload: Data, channelID: UInt16) throws -> Data {
        let packet = RDPStaticVirtualChannelPDU(payload: payload, flags: RDPStaticVirtualChannelFlags.complete)
            .encodedTPKT(initiator: userChannelID, channelID: channelID)
        try send(packet)
        return packet
    }

    /// Receives one message during the fixed request/response steps of the
    /// connection sequence.
    func receive(_ description: String) throws -> Data {
        guard let transport else {
            throw RDPConnectionError.receive("not connected")
        }
        do {
            return try transport.receive(timeout: .seconds(Int64(configuration.timeoutSeconds)))
        } catch RDPTransportError.timedOut {
            throw RDPConnectionError.receive(
                "\(description) timed out after \(configuration.timeoutSeconds) seconds"
            )
        } catch let error as RDPConnectionError {
            throw error
        } catch let error as RDPCredSSPError {
            // The server rejected the CredSSP credentials.
            throw error
        } catch {
            try callbacks.throwIfCancelled()
            guard isConnectionClose(error) else {
                throw RDPConnectionError.receive(
                    "connection lost before receiving \(description): \(connectionErrorDescription(error))"
                )
            }
            throw RDPConnectionError.receive("connection closed before receiving \(description)")
        }
    }

    func appendWarning(code: String, message: String) {
        report.warnings.appendCapped(RDPConnectionWarning(code: code, message: message), limit: RDPRecordLimit.warnings)
    }
}

/// The share established by the last Demand Active / Confirm Active exchange.
struct RDPActiveShare {
    var shareID: UInt32
    var serverInputFlags: UInt16?
    /// Both sides sent TS_FRAME_ACKNOWLEDGE_CAPABILITYSET ([MS-RDPBCGR] 2.2.7.2.11).
    var acknowledgesFrames: Bool
    var finalization = RDPConnectionFinalizationTracker()
}

enum RDPDynamicChannelKind {
    case graphics
    case displayControl
    case audio
}

struct RDPDynamicChannelFragment {
    var totalLength: Int
    var payload: Data
}
