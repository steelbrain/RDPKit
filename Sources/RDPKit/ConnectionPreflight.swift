import CryptoKit
import Darwin
import Foundation
@preconcurrency import NIOCore
import NIOPosix
@preconcurrency import NIOSSL
import NIOTLS
import Security

public typealias RDPGraphicsFrameHandler = (RDPGraphicsFrameSnapshot) -> Void
public typealias RDPCancellationHandler = @Sendable () -> Bool
public typealias RDPInputSessionHandler = @Sendable (RDPInputSession) -> Void
public typealias RDPDisplayControlSessionHandler = @Sendable (RDPDisplayControlSession) -> Void
public typealias RDPClipboardSessionHandler = @Sendable (RDPClipboardSession) -> Void
public typealias RDPClipboardTextHandler = @Sendable (String) -> Void
public typealias RDPClipboardFileGroupDescriptorHandler = @Sendable (RDPClipboardFileGroupDescriptorW) -> Void
public typealias RDPClipboardFileContentsHandler = @Sendable (RDPClipboardFileContentsResponse) -> Void
public typealias RDPAudioSampleHandler = @Sendable (RDPAudioSample) -> Void
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

public final class RDPConnectionCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var handlers: [UUID: () -> Void] = [:]

    public init() {}

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    public func cancel() {
        let handlersToRun: [() -> Void]
        lock.lock()
        guard !cancelled else {
            lock.unlock()
            return
        }
        cancelled = true
        handlersToRun = Array(handlers.values)
        handlers.removeAll()
        lock.unlock()

        for handler in handlersToRun {
            handler()
        }
    }

    fileprivate func register(_ handler: @escaping () -> Void) -> RDPConnectionCancellationRegistration {
        let id = UUID()
        let shouldRunImmediately: Bool
        lock.lock()
        if cancelled {
            shouldRunImmediately = true
        } else {
            shouldRunImmediately = false
            handlers[id] = handler
        }
        lock.unlock()

        if shouldRunImmediately {
            handler()
        }
        return RDPConnectionCancellationRegistration { [weak self] in
            self?.unregister(id)
        }
    }

    private func unregister(_ id: UUID) {
        lock.lock()
        handlers.removeValue(forKey: id)
        lock.unlock()
    }
}

private final class RDPConnectionCancellationRegistration {
    private let lock = NSLock()
    private var isActive = true
    private let unregister: () -> Void

    init(unregister: @escaping () -> Void) {
        self.unregister = unregister
    }

    deinit {
        cancel()
    }

    func cancel() {
        lock.lock()
        guard isActive else {
            lock.unlock()
            return
        }
        isActive = false
        lock.unlock()
        unregister()
    }
}

public struct RDPConnectionConfiguration: Sendable, Equatable {
    public var host: String
    public var port: UInt16
    public var credentials: RDPCredentials?
    public var timeoutSeconds: Int
    public var hideCertificateWarnings: Bool
    public var graphicsFrameCaptureLimit: Int?
    public var desktopWidth: UInt16
    public var desktopHeight: UInt16
    public var clipboardEnabled: Bool
    public var audioPlaybackEnabled: Bool
    public var graphicsCapabilityProfile: RDPGraphicsCapabilityProfile
    var redirectionRoutingToken: Data?
    var redirectionDepth: Int

    public init(
        host: String,
        port: UInt16 = 3389,
        credentials: RDPCredentials? = nil,
        timeoutSeconds: Int = 10,
        hideCertificateWarnings: Bool = false,
        graphicsFrameCaptureLimit: Int? = 1,
        desktopWidth: UInt16 = 1280,
        desktopHeight: UInt16 = 720,
        clipboardEnabled: Bool = true,
        audioPlaybackEnabled: Bool = false,
        graphicsCapabilityProfile: RDPGraphicsCapabilityProfile = .automatic
    ) {
        self.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        self.port = port
        self.credentials = credentials
        self.timeoutSeconds = max(1, timeoutSeconds)
        self.hideCertificateWarnings = hideCertificateWarnings
        self.graphicsFrameCaptureLimit = graphicsFrameCaptureLimit.map { min(120, max(1, $0)) }
        self.desktopWidth = min(8192, max(640, desktopWidth))
        self.desktopHeight = min(8192, max(480, desktopHeight))
        self.clipboardEnabled = clipboardEnabled
        self.audioPlaybackEnabled = audioPlaybackEnabled
        self.graphicsCapabilityProfile = graphicsCapabilityProfile
        self.redirectionRoutingToken = nil
        self.redirectionDepth = 0
    }

    public init(
        target: RDPConnectionTarget,
        credentials: RDPCredentials? = nil,
        timeoutSeconds: Int = 10,
        hideCertificateWarnings: Bool = false,
        graphicsFrameCaptureLimit: Int? = 1,
        desktopSize: RDPDesktopSize,
        clipboardEnabled: Bool = true,
        audioPlaybackEnabled: Bool = false,
        graphicsCapabilityProfile: RDPGraphicsCapabilityProfile = .automatic
    ) {
        self.init(
            host: target.host,
            port: target.port,
            credentials: credentials,
            timeoutSeconds: timeoutSeconds,
            hideCertificateWarnings: hideCertificateWarnings,
            graphicsFrameCaptureLimit: graphicsFrameCaptureLimit,
            desktopWidth: desktopSize.width,
            desktopHeight: desktopSize.height,
            clipboardEnabled: clipboardEnabled,
            audioPlaybackEnabled: audioPlaybackEnabled,
            graphicsCapabilityProfile: graphicsCapabilityProfile
        )
    }

    public var identity: RDPConnectionIdentity {
        RDPConnectionIdentity(
            host: host,
            port: port,
            username: credentials?.username ?? "",
            domain: credentials?.domain
        )
    }

    public var displayName: String {
        identity.displayName
    }

    var staticVirtualChannels: [RDPStaticVirtualChannel] {
        var channels: [RDPStaticVirtualChannel] = [.drdynvc]
        if clipboardEnabled {
            channels.append(.cliprdr)
        }
        if audioPlaybackEnabled {
            channels.append(.rdpdr)
            channels.append(.rdpsnd)
        }
        return channels
    }
}

public struct RDPProbeWarning: Encodable, Equatable, Sendable {
    public var code: String
    public var message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public struct RDPServerCertificateInfo: Encodable, Equatable, Sendable {
    public var trusted: Bool
    public var sha256: String?
    public var warnings: [RDPProbeWarning]

    public init(trusted: Bool, sha256: String?, warnings: [RDPProbeWarning]) {
        self.trusted = trusted
        self.sha256 = sha256
        self.warnings = warnings
    }
}

public typealias RDPServerCertificateHandler = @Sendable (RDPServerCertificateInfo) -> Void

public enum RDPVideoCodec: String, Encodable, Equatable, Sendable {
    case h264
    case hevc

    public var displayName: String {
        switch self {
        case .h264:
            "H.264"
        case .hevc:
            "HEVC"
        }
    }

    public func nalUnitTypes(from data: Data) -> [UInt8] {
        switch self {
        case .h264:
            RDPH264AnnexB.nalUnitTypes(from: data)
        case .hevc:
            RDPHEVCAnnexB.nalUnitTypes(from: data)
        }
    }
}

public enum RDPGraphicsFrameContentKind: String, Encodable, Equatable, Sendable {
    case video
    case bitmap
}

public enum RDPGraphicsPathDescription {
    public static func describe(report: RDPPreflightReport?) -> String {
        guard let report else {
            return "not negotiated"
        }
        return describe(
            selectedCapabilityVersion: report.rdpGraphicsSelectedCapabilityVersion,
            selectedCapabilityFlags: report.rdpGraphicsSelectedCapabilityFlags,
            firstFrame: report.rdpGraphicsFirstFrame,
            updateMessages: report.rdpGraphicsUpdateMessages
        )
    }

    public static func describe(
        selectedCapabilityVersion: UInt32?,
        selectedCapabilityFlags: UInt32?,
        firstFrame: RDPGraphicsFrameSnapshot?,
        updateMessages: [RDPGFXMessageSummary]?
    ) -> String {
        let capability = capabilityDescription(
            version: selectedCapabilityVersion,
            flags: selectedCapabilityFlags
        )
        if let firstFrame {
            if firstFrame.contentKind == .bitmap,
               let update = updateMessages?.first(where: { $0.codecName != nil })
            {
                return "\(capability) -> \(updateDescription(update)) -> \(frameDescription(firstFrame))"
            }
            return "\(capability) -> \(frameDescription(firstFrame))"
        }
        if let update = updateMessages?.first(where: { $0.codecName != nil }) {
            return "\(capability) -> \(updateDescription(update))"
        }
        return capability
    }

    private static func capabilityDescription(version: UInt32?, flags: UInt32?) -> String {
        guard let version else {
            return "graphics not confirmed"
        }

        var parts: [String]
        switch version {
        case RDPGFXCapabilityVersion.version107:
            parts = ["RDPGFX v10.7"]
            if let flags, flags & RDPGFXCapabilityFlags.avcThinClient != 0 {
                parts.append("AVC thin-client")
            }
            if let flags, flags & RDPGFXCapabilityFlags.scaledMapDisabled != 0 {
                parts.append("scaled-map disabled")
            }
        case RDPGFXCapabilityVersion.version81:
            parts = ["RDPGFX v8.1"]
            if let flags, flags & RDPGFXCapabilityFlags.thinClient != 0 {
                parts.append("thin-client")
            }
            if let flags, flags & RDPGFXCapabilityFlags.avc420Enabled != 0 {
                parts.append("AVC420")
            }
        case RDPGFXCapabilityVersion.version8:
            parts = ["RDPGFX v8"]
            if let flags, flags & RDPGFXCapabilityFlags.thinClient != 0 {
                parts.append("thin-client")
            }
        default:
            parts = ["RDPGFX 0x\(String(format: "%08x", version))"]
        }

        if let flags {
            parts.append("flags=0x\(String(format: "%08x", flags))")
        }
        return parts.joined(separator: " ")
    }

    private static func frameDescription(_ frame: RDPGraphicsFrameSnapshot) -> String {
        if frame.contentKind == .video {
            return "\(frame.codecName)/\(frame.videoCodec.displayName)"
        }
        return frame.codecName
    }

    private static func updateDescription(_ message: RDPGFXMessageSummary) -> String {
        guard let codecName = message.codecName else {
            return message.typeName
        }
        if codecName == "caprogressive",
           let tileCount = message.progressiveRegionTileCount
        {
            return "\(message.typeName) \(codecName) tiles=\(tileCount)"
        }
        if codecName == "cavideo",
           let tileCount = message.cavideoTileCount,
           let entropy = message.cavideoTileSetEntropyAlgorithms?.last
        {
            return "\(message.typeName) \(codecName) remotefx tiles=\(tileCount) entropy=\(entropy)"
        }
        return "\(message.typeName) \(codecName)"
    }
}

public struct RDPFrameRect: Encodable, Equatable, Sendable {
    public var left: UInt16
    public var top: UInt16
    public var right: UInt16
    public var bottom: UInt16

    public init(left: UInt16, top: UInt16, right: UInt16, bottom: UInt16) {
        self.left = left
        self.top = top
        self.right = right
        self.bottom = bottom
    }

    init(_ rect: RDPGFXRect16) {
        self.init(left: rect.left, top: rect.top, right: rect.right, bottom: rect.bottom)
    }

    public var width: UInt16 {
        right >= left ? right - left : 0
    }

    public var height: UInt16 {
        bottom >= top ? bottom - top : 0
    }
}

public struct RDPGraphicsFrameSnapshot: Encodable, Equatable, Sendable {
    public var frameID: UInt32?
    public var surfaceID: UInt16
    public var codecID: UInt16
    public var codecName: String
    public var videoCodec: RDPVideoCodec
    public var pixelFormat: UInt8
    public var destinationRect: RDPFrameRect
    public var regionRects: [RDPFrameRect]
    public var encodedVideoData: Data
    public var contentKind: RDPGraphicsFrameContentKind
    public var decodedBitmapData: Data?
    public var decodedBitmapBytesPerRow: Int?

    public init(
        frameID: UInt32?,
        surfaceID: UInt16,
        codecID: UInt16,
        codecName: String,
        videoCodec: RDPVideoCodec = .h264,
        pixelFormat: UInt8,
        destinationRect: RDPFrameRect,
        regionRects: [RDPFrameRect],
        h264AnnexBData: Data
    ) {
        self.init(
            frameID: frameID,
            surfaceID: surfaceID,
            codecID: codecID,
            codecName: codecName,
            videoCodec: videoCodec,
            pixelFormat: pixelFormat,
            destinationRect: destinationRect,
            regionRects: regionRects,
            encodedVideoData: h264AnnexBData
        )
    }

    init(
        frameID: UInt32?,
        surfaceID: UInt16,
        codecID: UInt16,
        codecName: String,
        videoCodec: RDPVideoCodec = .h264,
        pixelFormat: UInt8,
        destinationRect: RDPGFXRect16,
        regionRects: [RDPGFXRect16],
        h264AnnexBData: Data
    ) {
        self.init(
            frameID: frameID,
            surfaceID: surfaceID,
            codecID: codecID,
            codecName: codecName,
            videoCodec: videoCodec,
            pixelFormat: pixelFormat,
            destinationRect: RDPFrameRect(destinationRect),
            regionRects: regionRects.map(RDPFrameRect.init),
            encodedVideoData: h264AnnexBData
        )
    }

    public init(
        frameID: UInt32?,
        surfaceID: UInt16,
        codecID: UInt16,
        codecName: String,
        videoCodec: RDPVideoCodec = .h264,
        pixelFormat: UInt8,
        destinationRect: RDPFrameRect,
        regionRects: [RDPFrameRect],
        encodedVideoData: Data,
        contentKind: RDPGraphicsFrameContentKind = .video,
        decodedBitmapData: Data? = nil,
        decodedBitmapBytesPerRow: Int? = nil
    ) {
        self.frameID = frameID
        self.surfaceID = surfaceID
        self.codecID = codecID
        self.codecName = codecName
        self.videoCodec = videoCodec
        self.pixelFormat = pixelFormat
        self.destinationRect = destinationRect
        self.regionRects = regionRects
        self.encodedVideoData = encodedVideoData
        self.contentKind = contentKind
        self.decodedBitmapData = decodedBitmapData
        self.decodedBitmapBytesPerRow = decodedBitmapBytesPerRow
    }

    init(
        frameID: UInt32?,
        surfaceID: UInt16,
        codecID: UInt16,
        codecName: String,
        videoCodec: RDPVideoCodec = .h264,
        pixelFormat: UInt8,
        destinationRect: RDPGFXRect16,
        regionRects: [RDPGFXRect16],
        encodedVideoData: Data
    ) {
        self.init(
            frameID: frameID,
            surfaceID: surfaceID,
            codecID: codecID,
            codecName: codecName,
            videoCodec: videoCodec,
            pixelFormat: pixelFormat,
            destinationRect: RDPFrameRect(destinationRect),
            regionRects: regionRects.map(RDPFrameRect.init),
            encodedVideoData: encodedVideoData
        )
    }

    public var width: UInt16 {
        destinationRect.width
    }

    public var height: UInt16 {
        destinationRect.height
    }

    public var h264AnnexBData: Data {
        encodedVideoData
    }

    public var videoByteCount: Int {
        guard contentKind == .video else {
            return 0
        }
        return encodedVideoData.count
    }

    public var videoNalUnitTypes: [UInt8] {
        guard contentKind == .video else {
            return []
        }
        return videoCodec.nalUnitTypes(from: encodedVideoData)
    }

    public var bitmapByteCount: Int {
        decodedBitmapData?.count ?? 0
    }

    public var payloadByteCount: Int {
        contentKind == .bitmap ? bitmapByteCount : videoByteCount
    }

    public var h264ByteCount: Int {
        videoCodec == .h264 ? videoByteCount : 0
    }

    public var h264NalUnitTypes: [UInt8] {
        videoCodec == .h264 ? videoNalUnitTypes : []
    }

    enum CodingKeys: String, CodingKey {
        case frameID
        case surfaceID
        case codecID
        case codecName
        case contentKind
        case videoCodec
        case videoCodecName
        case pixelFormat
        case destinationRect
        case regionRects
        case videoByteCount
        case videoNalUnitTypes
        case h264ByteCount
        case h264NalUnitTypes
        case bitmapByteCount
        case decodedBitmapBytesPerRow
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(frameID, forKey: .frameID)
        try container.encode(surfaceID, forKey: .surfaceID)
        try container.encode(codecID, forKey: .codecID)
        try container.encode(codecName, forKey: .codecName)
        try container.encode(contentKind, forKey: .contentKind)
        try container.encode(videoCodec, forKey: .videoCodec)
        try container.encode(videoCodec.displayName, forKey: .videoCodecName)
        try container.encode(pixelFormat, forKey: .pixelFormat)
        try container.encode(destinationRect, forKey: .destinationRect)
        try container.encode(regionRects, forKey: .regionRects)
        try container.encode(videoByteCount, forKey: .videoByteCount)
        try container.encode(videoNalUnitTypes, forKey: .videoNalUnitTypes)
        try container.encode(h264ByteCount, forKey: .h264ByteCount)
        try container.encode(h264NalUnitTypes, forKey: .h264NalUnitTypes)
        try container.encode(bitmapByteCount, forKey: .bitmapByteCount)
        try container.encodeIfPresent(decodedBitmapBytesPerRow, forKey: .decodedBitmapBytesPerRow)
    }
}

public struct RDPPreflightReport: Encodable, Equatable, Sendable {
    public var status: String
    public var stage: String
    public var target: String
    public var username: String?
    public var domain: String?
    public var passwordConfigured: Bool
    public var requestedProtocols: [String]
    public var requestHex: String
    public var responseHex: String?
    public var negotiationFlags: UInt8?
    public var selectedProtocols: [String]?
    public var failureCode: UInt32?
    public var tlsProtocol: String?
    public var tlsCipherSuite: String?
    public var certificateTrusted: Bool?
    public var certificateSHA256: String?
    public var mcsConnectInitialHex: String?
    public var mcsConnectResponseHex: String?
    public var mcsConnectResult: String?
    public var mcsServerUserDataKey: String?
    public var mcsIOChannelID: UInt16?
    public var mcsMessageChannelID: UInt16?
    public var mcsStaticChannels: [RDPStaticVirtualChannelAssignment]?
    public var mcsErectDomainRequestHex: String?
    public var mcsAttachUserRequestHex: String?
    public var mcsAttachUserConfirmHex: String?
    public var mcsAttachUserResult: String?
    public var mcsUserChannelID: UInt16?
    public var mcsJoinedChannels: [RDPChannelJoinReport]?
    public var rdpClientInfoSent: Bool?
    public var rdpClientInfoCredentialsIncluded: Bool?
    public var rdpClientInfoRequestBytes: Int?
    public var rdpClientInfoResponseHex: String?
    public var rdpAutoDetectRequestType: String?
    public var rdpAutoDetectSequenceNumber: UInt16?
    public var rdpAutoDetectResponseHex: String?
    public var rdpPostAutoDetectResponseHex: String?
    public var rdpPostAutoDetectResponseType: String?
    public var rdpLicensingResponseType: String?
    public var rdpLicensingErrorCode: UInt32?
    public var rdpPostLicensingResponseHex: String?
    public var rdpPostLicensingResponseType: String?
    public var rdpDemandActiveShareID: UInt32?
    public var rdpDemandActiveCapabilitySets: [RDPCapabilitySetSummary]?
    public var rdpConfirmActiveRequestHex: String?
    public var rdpConfirmActiveCapabilitySets: [RDPCapabilitySetSummary]?
    public var rdpPostConfirmActiveResponseHex: String?
    public var rdpPostConfirmActiveResponseType: String?
    public var rdpClientSynchronizeRequestHex: String?
    public var rdpClientControlCooperateRequestHex: String?
    public var rdpClientControlRequestHex: String?
    public var rdpClientFontListRequestHex: String?
    public var rdpFinalizationResponseHexes: [String]?
    public var rdpFinalizationResponseTypes: [String]?
    public var rdpDynamicChannelRequestHexes: [String]?
    public var rdpDynamicChannelRequestTypes: [String]?
    public var rdpDynamicChannelCapabilitiesVersion: UInt16?
    public var rdpDynamicChannelCapabilitiesResponseHex: String?
    public var rdpGraphicsChannelName: String?
    public var rdpGraphicsChannelID: UInt32?
    public var rdpGraphicsChannelCreateResponseHex: String?
    public var rdpGraphicsCapabilityProfile: RDPGraphicsCapabilityProfile
    public var rdpGraphicsCapsAdvertiseHex: String?
    public var rdpGraphicsResponseHex: String?
    public var rdpGraphicsResponseType: String?
    public var rdpGraphicsSelectedCapabilityVersion: UInt32?
    public var rdpGraphicsSelectedCapabilityFlags: UInt32?
    public var rdpGraphicsUpdateResponseCount: Int?
    public var rdpGraphicsUpdateResponseHexes: [String]?
    public var rdpGraphicsUpdateMessages: [RDPGFXMessageSummary]?
    public var rdpGraphicsFailureUpdateResponseHex: String?
    public var rdpGraphicsFailureUpdatePayloadHex: String?
    public var rdpGraphicsFailureUpdateMessages: [RDPGFXMessageSummary]?
    public var rdpGraphicsFailureUpdateMessageIndex: Int?
    public var rdpGraphicsFrameAcknowledgeHexes: [String]?
    public var rdpGraphicsFrames: [RDPGraphicsFrameSnapshot]?
    public var rdpGraphicsFirstFrame: RDPGraphicsFrameSnapshot?
    public var rdpDisplayControlChannelID: UInt32?
    public var rdpDisplayControlChannelCreateResponseHex: String?
    public var rdpDisplayControlCapsHex: String?
    public var rdpDisplayControlCaps: RDPDisplayControlCapabilities?
    public var rdpClipboardChannelID: UInt16?
    public var rdpClipboardMessages: [RDPClipboardMessageSummary]?
    public var rdpClipboardMessageHexes: [String]?
    public var rdpClipboardSentMessages: [RDPClipboardMessageSummary]?
    public var rdpClipboardSentMessageHexes: [String]?
    public var rdpClipboardProbeTextUTF16CodeUnitCount: Int?
    public var rdpClipboardReceivedTextUTF16CodeUnitCount: Int?
    public var rdpClipboardReceivedTextMatchesProbe: Bool?
    public var rdpInputProbeEvents: [String]?
    public var rdpAudioChannelID: UInt16?
    public var rdpAudioMessages: [RDPAudioMessageSummary]?
    public var rdpAudioMessageHexes: [String]?
    public var warnings: [RDPProbeWarning]
    public var nextStage: String?
    public var error: String?

    public init(
        status: String,
        stage: String,
        target: String,
        username: String? = nil,
        domain: String? = nil,
        passwordConfigured: Bool,
        requestedProtocols: [String],
        requestHex: String,
        responseHex: String? = nil,
        negotiationFlags: UInt8? = nil,
        selectedProtocols: [String]? = nil,
        failureCode: UInt32? = nil,
        tlsProtocol: String? = nil,
        tlsCipherSuite: String? = nil,
        certificateTrusted: Bool? = nil,
        certificateSHA256: String? = nil,
        mcsConnectInitialHex: String? = nil,
        mcsConnectResponseHex: String? = nil,
        mcsConnectResult: String? = nil,
        mcsServerUserDataKey: String? = nil,
        mcsIOChannelID: UInt16? = nil,
        mcsMessageChannelID: UInt16? = nil,
        mcsStaticChannels: [RDPStaticVirtualChannelAssignment]? = nil,
        mcsErectDomainRequestHex: String? = nil,
        mcsAttachUserRequestHex: String? = nil,
        mcsAttachUserConfirmHex: String? = nil,
        mcsAttachUserResult: String? = nil,
        mcsUserChannelID: UInt16? = nil,
        mcsJoinedChannels: [RDPChannelJoinReport]? = nil,
        rdpClientInfoSent: Bool? = nil,
        rdpClientInfoCredentialsIncluded: Bool? = nil,
        rdpClientInfoRequestBytes: Int? = nil,
        rdpClientInfoResponseHex: String? = nil,
        rdpAutoDetectRequestType: String? = nil,
        rdpAutoDetectSequenceNumber: UInt16? = nil,
        rdpAutoDetectResponseHex: String? = nil,
        rdpPostAutoDetectResponseHex: String? = nil,
        rdpPostAutoDetectResponseType: String? = nil,
        rdpLicensingResponseType: String? = nil,
        rdpLicensingErrorCode: UInt32? = nil,
        rdpPostLicensingResponseHex: String? = nil,
        rdpPostLicensingResponseType: String? = nil,
        rdpDemandActiveShareID: UInt32? = nil,
        rdpDemandActiveCapabilitySets: [RDPCapabilitySetSummary]? = nil,
        rdpConfirmActiveRequestHex: String? = nil,
        rdpConfirmActiveCapabilitySets: [RDPCapabilitySetSummary]? = nil,
        rdpPostConfirmActiveResponseHex: String? = nil,
        rdpPostConfirmActiveResponseType: String? = nil,
        rdpClientSynchronizeRequestHex: String? = nil,
        rdpClientControlCooperateRequestHex: String? = nil,
        rdpClientControlRequestHex: String? = nil,
        rdpClientFontListRequestHex: String? = nil,
        rdpFinalizationResponseHexes: [String]? = nil,
        rdpFinalizationResponseTypes: [String]? = nil,
        rdpDynamicChannelRequestHexes: [String]? = nil,
        rdpDynamicChannelRequestTypes: [String]? = nil,
        rdpDynamicChannelCapabilitiesVersion: UInt16? = nil,
        rdpDynamicChannelCapabilitiesResponseHex: String? = nil,
        rdpGraphicsChannelName: String? = nil,
        rdpGraphicsChannelID: UInt32? = nil,
        rdpGraphicsChannelCreateResponseHex: String? = nil,
        rdpGraphicsCapabilityProfile: RDPGraphicsCapabilityProfile = .automatic,
        rdpGraphicsCapsAdvertiseHex: String? = nil,
        rdpGraphicsResponseHex: String? = nil,
        rdpGraphicsResponseType: String? = nil,
        rdpGraphicsSelectedCapabilityVersion: UInt32? = nil,
        rdpGraphicsSelectedCapabilityFlags: UInt32? = nil,
        rdpGraphicsUpdateResponseCount: Int? = nil,
        rdpGraphicsUpdateResponseHexes: [String]? = nil,
        rdpGraphicsUpdateMessages: [RDPGFXMessageSummary]? = nil,
        rdpGraphicsFailureUpdateResponseHex: String? = nil,
        rdpGraphicsFailureUpdatePayloadHex: String? = nil,
        rdpGraphicsFailureUpdateMessages: [RDPGFXMessageSummary]? = nil,
        rdpGraphicsFailureUpdateMessageIndex: Int? = nil,
        rdpGraphicsFrameAcknowledgeHexes: [String]? = nil,
        rdpGraphicsFrames: [RDPGraphicsFrameSnapshot]? = nil,
        rdpGraphicsFirstFrame: RDPGraphicsFrameSnapshot? = nil,
        rdpDisplayControlChannelID: UInt32? = nil,
        rdpDisplayControlChannelCreateResponseHex: String? = nil,
        rdpDisplayControlCapsHex: String? = nil,
        rdpDisplayControlCaps: RDPDisplayControlCapabilities? = nil,
        rdpClipboardChannelID: UInt16? = nil,
        rdpClipboardMessages: [RDPClipboardMessageSummary]? = nil,
        rdpClipboardMessageHexes: [String]? = nil,
        rdpClipboardSentMessages: [RDPClipboardMessageSummary]? = nil,
        rdpClipboardSentMessageHexes: [String]? = nil,
        rdpClipboardProbeTextUTF16CodeUnitCount: Int? = nil,
        rdpClipboardReceivedTextUTF16CodeUnitCount: Int? = nil,
        rdpClipboardReceivedTextMatchesProbe: Bool? = nil,
        rdpInputProbeEvents: [String]? = nil,
        rdpAudioChannelID: UInt16? = nil,
        rdpAudioMessages: [RDPAudioMessageSummary]? = nil,
        rdpAudioMessageHexes: [String]? = nil,
        warnings: [RDPProbeWarning],
        nextStage: String? = nil,
        error: String? = nil
    ) {
        self.status = status
        self.stage = stage
        self.target = target
        self.username = username
        self.domain = domain
        self.passwordConfigured = passwordConfigured
        self.requestedProtocols = requestedProtocols
        self.requestHex = requestHex
        self.responseHex = responseHex
        self.negotiationFlags = negotiationFlags
        self.selectedProtocols = selectedProtocols
        self.failureCode = failureCode
        self.tlsProtocol = tlsProtocol
        self.tlsCipherSuite = tlsCipherSuite
        self.certificateTrusted = certificateTrusted
        self.certificateSHA256 = certificateSHA256
        self.mcsConnectInitialHex = mcsConnectInitialHex
        self.mcsConnectResponseHex = mcsConnectResponseHex
        self.mcsConnectResult = mcsConnectResult
        self.mcsServerUserDataKey = mcsServerUserDataKey
        self.mcsIOChannelID = mcsIOChannelID
        self.mcsMessageChannelID = mcsMessageChannelID
        self.mcsStaticChannels = mcsStaticChannels
        self.mcsErectDomainRequestHex = mcsErectDomainRequestHex
        self.mcsAttachUserRequestHex = mcsAttachUserRequestHex
        self.mcsAttachUserConfirmHex = mcsAttachUserConfirmHex
        self.mcsAttachUserResult = mcsAttachUserResult
        self.mcsUserChannelID = mcsUserChannelID
        self.mcsJoinedChannels = mcsJoinedChannels
        self.rdpClientInfoSent = rdpClientInfoSent
        self.rdpClientInfoCredentialsIncluded = rdpClientInfoCredentialsIncluded
        self.rdpClientInfoRequestBytes = rdpClientInfoRequestBytes
        self.rdpClientInfoResponseHex = rdpClientInfoResponseHex
        self.rdpAutoDetectRequestType = rdpAutoDetectRequestType
        self.rdpAutoDetectSequenceNumber = rdpAutoDetectSequenceNumber
        self.rdpAutoDetectResponseHex = rdpAutoDetectResponseHex
        self.rdpPostAutoDetectResponseHex = rdpPostAutoDetectResponseHex
        self.rdpPostAutoDetectResponseType = rdpPostAutoDetectResponseType
        self.rdpLicensingResponseType = rdpLicensingResponseType
        self.rdpLicensingErrorCode = rdpLicensingErrorCode
        self.rdpPostLicensingResponseHex = rdpPostLicensingResponseHex
        self.rdpPostLicensingResponseType = rdpPostLicensingResponseType
        self.rdpDemandActiveShareID = rdpDemandActiveShareID
        self.rdpDemandActiveCapabilitySets = rdpDemandActiveCapabilitySets
        self.rdpConfirmActiveRequestHex = rdpConfirmActiveRequestHex
        self.rdpConfirmActiveCapabilitySets = rdpConfirmActiveCapabilitySets
        self.rdpPostConfirmActiveResponseHex = rdpPostConfirmActiveResponseHex
        self.rdpPostConfirmActiveResponseType = rdpPostConfirmActiveResponseType
        self.rdpClientSynchronizeRequestHex = rdpClientSynchronizeRequestHex
        self.rdpClientControlCooperateRequestHex = rdpClientControlCooperateRequestHex
        self.rdpClientControlRequestHex = rdpClientControlRequestHex
        self.rdpClientFontListRequestHex = rdpClientFontListRequestHex
        self.rdpFinalizationResponseHexes = rdpFinalizationResponseHexes
        self.rdpFinalizationResponseTypes = rdpFinalizationResponseTypes
        self.rdpDynamicChannelRequestHexes = rdpDynamicChannelRequestHexes
        self.rdpDynamicChannelRequestTypes = rdpDynamicChannelRequestTypes
        self.rdpDynamicChannelCapabilitiesVersion = rdpDynamicChannelCapabilitiesVersion
        self.rdpDynamicChannelCapabilitiesResponseHex = rdpDynamicChannelCapabilitiesResponseHex
        self.rdpGraphicsChannelName = rdpGraphicsChannelName
        self.rdpGraphicsChannelID = rdpGraphicsChannelID
        self.rdpGraphicsChannelCreateResponseHex = rdpGraphicsChannelCreateResponseHex
        self.rdpGraphicsCapabilityProfile = rdpGraphicsCapabilityProfile
        self.rdpGraphicsCapsAdvertiseHex = rdpGraphicsCapsAdvertiseHex
        self.rdpGraphicsResponseHex = rdpGraphicsResponseHex
        self.rdpGraphicsResponseType = rdpGraphicsResponseType
        self.rdpGraphicsSelectedCapabilityVersion = rdpGraphicsSelectedCapabilityVersion
        self.rdpGraphicsSelectedCapabilityFlags = rdpGraphicsSelectedCapabilityFlags
        self.rdpGraphicsUpdateResponseCount = rdpGraphicsUpdateResponseCount
        self.rdpGraphicsUpdateResponseHexes = rdpGraphicsUpdateResponseHexes
        self.rdpGraphicsUpdateMessages = rdpGraphicsUpdateMessages
        self.rdpGraphicsFailureUpdateResponseHex = rdpGraphicsFailureUpdateResponseHex
        self.rdpGraphicsFailureUpdatePayloadHex = rdpGraphicsFailureUpdatePayloadHex
        self.rdpGraphicsFailureUpdateMessages = rdpGraphicsFailureUpdateMessages
        self.rdpGraphicsFailureUpdateMessageIndex = rdpGraphicsFailureUpdateMessageIndex
        self.rdpGraphicsFrameAcknowledgeHexes = rdpGraphicsFrameAcknowledgeHexes
        self.rdpGraphicsFrames = rdpGraphicsFrames
        self.rdpGraphicsFirstFrame = rdpGraphicsFirstFrame ?? rdpGraphicsFrames?.first
        self.rdpDisplayControlChannelID = rdpDisplayControlChannelID
        self.rdpDisplayControlChannelCreateResponseHex = rdpDisplayControlChannelCreateResponseHex
        self.rdpDisplayControlCapsHex = rdpDisplayControlCapsHex
        self.rdpDisplayControlCaps = rdpDisplayControlCaps
        self.rdpClipboardChannelID = rdpClipboardChannelID
        self.rdpClipboardMessages = rdpClipboardMessages
        self.rdpClipboardMessageHexes = rdpClipboardMessageHexes
        self.rdpClipboardSentMessages = rdpClipboardSentMessages
        self.rdpClipboardSentMessageHexes = rdpClipboardSentMessageHexes
        self.rdpClipboardProbeTextUTF16CodeUnitCount = rdpClipboardProbeTextUTF16CodeUnitCount
        self.rdpClipboardReceivedTextUTF16CodeUnitCount = rdpClipboardReceivedTextUTF16CodeUnitCount
        self.rdpClipboardReceivedTextMatchesProbe = rdpClipboardReceivedTextMatchesProbe
        self.rdpInputProbeEvents = rdpInputProbeEvents
        self.rdpAudioChannelID = rdpAudioChannelID
        self.rdpAudioMessages = rdpAudioMessages
        self.rdpAudioMessageHexes = rdpAudioMessageHexes
        self.warnings = warnings
        self.nextStage = nextStage
        self.error = error
    }
}

public enum RDPPreflightError: Error, CustomStringConvertible {
    case addressResolution(String)
    case connect(String)
    case send(String)
    case receive(String)
    case tls(String)
    case cancelled

    public var description: String {
        switch self {
        case let .addressResolution(message):
            "address resolution failed: \(message)"
        case let .connect(message):
            "connect failed: \(message)"
        case let .send(message):
            "send failed: \(message)"
        case let .receive(message):
            "receive failed: \(message)"
        case let .tls(message):
            "TLS failed: \(message)"
        case .cancelled:
            "cancelled"
        }
    }
}

public struct RDPPreflightClient: Sendable {
    public init() {}

    public func dryRun(configuration: RDPConnectionConfiguration) -> RDPPreflightReport {
        let request = X224ConnectionRequest()
        let packet = request.encodedTPKT()

        return RDPPreflightReport(
            status: "dry-run",
            stage: "x224-rdp-negotiation-request",
            target: targetString(host: configuration.host, port: configuration.port),
            username: configuration.credentials?.username,
            domain: configuration.credentials?.domain,
            passwordConfigured: configuration.credentials != nil,
            requestedProtocols: request.negotiationRequest.requestedProtocols.names,
            requestHex: packet.rdpHexString,
            responseHex: nil,
            negotiationFlags: nil,
            selectedProtocols: nil,
            failureCode: nil,
            tlsProtocol: nil,
            tlsCipherSuite: nil,
            certificateTrusted: nil,
            certificateSHA256: nil,
            rdpGraphicsCapabilityProfile: configuration.graphicsCapabilityProfile,
            warnings: [],
            nextStage: "send negotiation request to server",
            error: nil
        )
    }

    public func run(
        configuration: RDPConnectionConfiguration,
        onGraphicsFrame: RDPGraphicsFrameHandler? = nil,
        onInputReady: RDPInputSessionHandler? = nil,
        onDisplayControlReady: RDPDisplayControlSessionHandler? = nil,
        onClipboardReady: RDPClipboardSessionHandler? = nil,
        onClipboardText: RDPClipboardTextHandler? = nil,
        onClipboardFileGroupDescriptor: RDPClipboardFileGroupDescriptorHandler? = nil,
        onClipboardFileContents: RDPClipboardFileContentsHandler? = nil,
        onAudioSample: RDPAudioSampleHandler? = nil,
        onCertificate: RDPServerCertificateHandler? = nil,
        onWireReceive: RDPWireReceiveHandler? = nil,
        cancellation: RDPConnectionCancellation? = nil,
        shouldCancel: RDPCancellationHandler? = nil
    ) -> RDPPreflightReport {
        do {
            return try connect(
                configuration: configuration,
                onGraphicsFrame: onGraphicsFrame,
                onInputReady: onInputReady,
                onDisplayControlReady: onDisplayControlReady,
                onClipboardReady: onClipboardReady,
                onClipboardText: onClipboardText,
                onClipboardFileGroupDescriptor: onClipboardFileGroupDescriptor,
                onClipboardFileContents: onClipboardFileContents,
                onAudioSample: onAudioSample,
                onCertificate: onCertificate,
                onWireReceive: onWireReceive,
                cancellation: cancellation,
                shouldCancel: shouldCancel
            )
        } catch {
            return failureReport(configuration: configuration, error: error)
        }
    }

    public func connect(
        configuration: RDPConnectionConfiguration,
        onGraphicsFrame: RDPGraphicsFrameHandler? = nil,
        onInputReady: RDPInputSessionHandler? = nil,
        onDisplayControlReady: RDPDisplayControlSessionHandler? = nil,
        onClipboardReady: RDPClipboardSessionHandler? = nil,
        onClipboardText: RDPClipboardTextHandler? = nil,
        onClipboardFileGroupDescriptor: RDPClipboardFileGroupDescriptorHandler? = nil,
        onClipboardFileContents: RDPClipboardFileContentsHandler? = nil,
        onAudioSample: RDPAudioSampleHandler? = nil,
        onCertificate: RDPServerCertificateHandler? = nil,
        onWireReceive: RDPWireReceiveHandler? = nil,
        cancellation: RDPConnectionCancellation? = nil,
        shouldCancel: RDPCancellationHandler? = nil
    ) throws -> RDPPreflightReport {
        try throwIfCancelled(shouldCancel, cancellation: cancellation)
        let request = X224ConnectionRequest(routingToken: configuration.redirectionRoutingToken)
        let packet = request.encodedTPKT()
        let connection = try connectAndNegotiate(
            host: configuration.host,
            port: configuration.port,
            timeoutSeconds: configuration.timeoutSeconds,
            packet: packet,
            onWireReceive: onWireReceive,
            cancellation: cancellation
        )
        try throwIfCancelled(shouldCancel, cancellation: cancellation)

        var callerOwnsConnectionFD = true
        defer {
            if callerOwnsConnectionFD {
                close(connection.fd)
            }
        }

        let selectedProtocols: [String]?
        let selectedSecurityProtocols: RDPSecurityProtocols?
        let failureCode: UInt32?
        switch connection.confirm.negotiationResult {
        case let .selected(protocols):
            selectedProtocols = protocols.names
            selectedSecurityProtocols = protocols
            failureCode = nil
        case let .failure(code):
            selectedProtocols = nil
            selectedSecurityProtocols = nil
            failureCode = code
        case nil:
            selectedProtocols = nil
            selectedSecurityProtocols = nil
            failureCode = nil
        }

        let usesTLS = selectedSecurityProtocols?.contains(.tls) == true
            || selectedSecurityProtocols?.contains(.credSSP) == true
            || selectedSecurityProtocols?.contains(.credSSPWithEarlyUserAuth) == true
        let usesCredSSP = selectedSecurityProtocols?.contains(.credSSP) == true
            || selectedSecurityProtocols?.contains(.credSSPWithEarlyUserAuth) == true

        if usesTLS {
            callerOwnsConnectionFD = false
            do {
                let mcsConfiguration = MCSConnectInitialConfiguration(
                    desktopWidth: configuration.desktopWidth,
                    desktopHeight: configuration.desktopHeight,
                    selectedProtocol: selectedSecurityProtocols ?? .tls,
                    channels: configuration.staticVirtualChannels,
                    advertiseMessageChannel: (connection.confirm.negotiationFlags ?? 0)
                        & RDPNegotiationResponseFlags.extendedClientDataSupported != 0
                )
                let tls = try performTLSHandshake(
                    fd: connection.fd,
                    host: configuration.host,
                    timeoutSeconds: configuration.timeoutSeconds,
                    hideCertificateWarnings: configuration.hideCertificateWarnings,
                    credentials: configuration.credentials,
                    credSSPRequired: usesCredSSP,
                    mcsConfiguration: mcsConfiguration,
                    graphicsFrameCaptureLimit: configuration.graphicsFrameCaptureLimit,
                    graphicsCapabilityProfile: configuration.graphicsCapabilityProfile,
                    onGraphicsFrame: onGraphicsFrame,
                    onInputReady: onInputReady,
                    onDisplayControlReady: onDisplayControlReady,
                    onClipboardReady: onClipboardReady,
                    onClipboardText: onClipboardText,
                    onClipboardFileGroupDescriptor: onClipboardFileGroupDescriptor,
                    onClipboardFileContents: onClipboardFileContents,
                    onAudioSample: onAudioSample,
                    onCertificate: onCertificate,
                    onWireReceive: onWireReceive,
                    cancellation: cancellation,
                    shouldCancel: shouldCancel
                )
                guard let mcsSequence = tls.mcsConnectionSequence else {
                    throw RDPPreflightError.receive("MCS channel connection sequence did not run")
                }
                let mcsSequenceSucceeded = mcsSequence.sequenceSucceeded
                if let serverRedirection = mcsSequence.serverRedirection,
                   let routingToken = serverRedirection.routingToken,
                   configuration.redirectionDepth < 2
                {
                    var redirectedConfiguration = configuration
                    redirectedConfiguration.host = serverRedirection.targetHost ?? configuration.host
                    redirectedConfiguration.redirectionRoutingToken = routingToken
                    if let username = serverRedirection.username,
                       let password = serverRedirection.password
                    {
                        redirectedConfiguration.credentials = RDPCredentials(
                            username: username,
                            domain: serverRedirection.domain,
                            password: password
                        )
                    }
                    redirectedConfiguration.redirectionDepth += 1
                    return try connect(
                        configuration: redirectedConfiguration,
                        onGraphicsFrame: onGraphicsFrame,
                        onInputReady: onInputReady,
                        onDisplayControlReady: onDisplayControlReady,
                        onClipboardReady: onClipboardReady,
                        onClipboardText: onClipboardText,
                        onClipboardFileGroupDescriptor: onClipboardFileGroupDescriptor,
                        onClipboardFileContents: onClipboardFileContents,
                        onAudioSample: onAudioSample,
                        onCertificate: onCertificate,
                        onWireReceive: onWireReceive,
                        cancellation: cancellation,
                        shouldCancel: shouldCancel
                    )
                }

                return RDPPreflightReport(
                    status: mcsSequenceSucceeded ? "success" : "failure",
                    stage: mcsSequence.currentStage,
                    target: targetString(host: configuration.host, port: configuration.port),
                    username: configuration.credentials?.username,
                    domain: configuration.credentials?.domain,
                    passwordConfigured: configuration.credentials != nil,
                    requestedProtocols: request.negotiationRequest.requestedProtocols.names,
                    requestHex: packet.rdpHexString,
                    responseHex: connection.response.rdpHexString,
                    negotiationFlags: connection.confirm.negotiationFlags,
                    selectedProtocols: selectedProtocols,
                    failureCode: failureCode,
                    tlsProtocol: tls.protocolName,
                    tlsCipherSuite: tls.cipherSuite,
                    certificateTrusted: tls.certificateTrusted,
                    certificateSHA256: tls.certificateSHA256,
                    mcsConnectInitialHex: mcsSequence.connectInitial.rdpHexString,
                    mcsConnectResponseHex: mcsSequence.connectResponseData.rdpHexString,
                    mcsConnectResult: mcsSequence.connectResponse.resultName,
                    mcsServerUserDataKey: mcsSequence.connectResponse.serverUserDataKey,
                    mcsIOChannelID: mcsSequence.connectResponse.ioChannelID,
                    mcsMessageChannelID: mcsSequence.connectResponse.messageChannelID,
                    mcsStaticChannels: mcsSequence.connectResponse.staticChannelAssignments,
                    mcsErectDomainRequestHex: mcsSequence.erectDomainRequest?.rdpHexString,
                    mcsAttachUserRequestHex: mcsSequence.attachUserRequest?.rdpHexString,
                    mcsAttachUserConfirmHex: mcsSequence.attachUserConfirmData?.rdpHexString,
                    mcsAttachUserResult: mcsSequence.attachUserConfirm?.resultName,
                    mcsUserChannelID: mcsSequence.attachUserConfirm?.userChannelID,
                    mcsJoinedChannels: mcsSequence.joinedChannels,
                    rdpClientInfoSent: mcsSequence.clientInfoRequestByteCount != nil,
                    rdpClientInfoCredentialsIncluded: mcsSequence.clientInfoCredentialsIncluded,
                    rdpClientInfoRequestBytes: mcsSequence.clientInfoRequestByteCount,
                    rdpClientInfoResponseHex: mcsSequence.clientInfoResponseData?.rdpHexString,
                    rdpAutoDetectRequestType: mcsSequence.autoDetectRequest?.requestTypeName,
                    rdpAutoDetectSequenceNumber: mcsSequence.autoDetectRequest?.sequenceNumber,
                    rdpAutoDetectResponseHex: mcsSequence.autoDetectResponseData?.rdpHexString,
                    rdpPostAutoDetectResponseHex: mcsSequence.postAutoDetectResponseData?.rdpHexString,
                    rdpPostAutoDetectResponseType: mcsSequence.postAutoDetectShareControl?.typeName,
                    rdpLicensingResponseType: mcsSequence.licenseResponse?.typeName,
                    rdpLicensingErrorCode: mcsSequence.licenseResponse?.errorCode,
                    rdpPostLicensingResponseHex: mcsSequence.postLicensingResponseData?.rdpHexString,
                    rdpPostLicensingResponseType: mcsSequence.postLicensingShareControl?.typeName,
                    rdpDemandActiveShareID: mcsSequence.demandActive?.shareID,
                    rdpDemandActiveCapabilitySets: mcsSequence.demandActive?.capabilitySets,
                    rdpConfirmActiveRequestHex: mcsSequence.confirmActiveRequestData?.rdpHexString,
                    rdpConfirmActiveCapabilitySets: mcsSequence.confirmActiveCapabilitySets,
                    rdpPostConfirmActiveResponseHex: mcsSequence.postConfirmActiveResponseData?.rdpHexString,
                    rdpPostConfirmActiveResponseType: mcsSequence.postConfirmActiveShareData?.typeName
                        ?? mcsSequence.postConfirmActiveShareControl?.typeName,
                    rdpClientSynchronizeRequestHex: mcsSequence.clientSynchronizeRequestData?.rdpHexString,
                    rdpClientControlCooperateRequestHex: mcsSequence.clientControlCooperateRequestData?.rdpHexString,
                    rdpClientControlRequestHex: mcsSequence.clientControlRequestData?.rdpHexString,
                    rdpClientFontListRequestHex: mcsSequence.clientFontListRequestData?.rdpHexString,
                    rdpFinalizationResponseHexes: mcsSequence.finalizationResponseData.map(\.rdpHexString),
                    rdpFinalizationResponseTypes: mcsSequence.finalizationResponses.map(\.typeName),
                    rdpDynamicChannelRequestHexes: mcsSequence.dynamicChannelRequestData.map(\.rdpHexString),
                    rdpDynamicChannelRequestTypes: mcsSequence.dynamicChannelRequestTypes,
                    rdpDynamicChannelCapabilitiesVersion: mcsSequence.dynamicChannelCapabilitiesRequest?.version,
                    rdpDynamicChannelCapabilitiesResponseHex: mcsSequence
                        .dynamicChannelCapabilitiesResponseData?.rdpHexString,
                    rdpGraphicsChannelName: mcsSequence.graphicsChannelCreateRequest?.channelName,
                    rdpGraphicsChannelID: mcsSequence.graphicsChannelCreateRequest?.channelID,
                    rdpGraphicsChannelCreateResponseHex: mcsSequence.graphicsChannelCreateResponseData?.rdpHexString,
                    rdpGraphicsCapabilityProfile: configuration.graphicsCapabilityProfile,
                    rdpGraphicsCapsAdvertiseHex: mcsSequence.graphicsCapsAdvertiseData?.rdpHexString,
                    rdpGraphicsResponseHex: mcsSequence.graphicsResponseData?.rdpHexString,
                    rdpGraphicsResponseType: mcsSequence.graphicsResponse?.typeName,
                    rdpGraphicsSelectedCapabilityVersion: mcsSequence.graphicsCapsConfirm?.capabilitySet.version,
                    rdpGraphicsSelectedCapabilityFlags: mcsSequence.graphicsCapsConfirm?.capabilitySet.flags,
                    rdpGraphicsUpdateResponseCount: mcsSequence.graphicsUpdateResponseCount,
                    rdpGraphicsUpdateResponseHexes: mcsSequence.graphicsUpdateResponseData.map(\.rdpHexString),
                    rdpGraphicsUpdateMessages: mcsSequence.graphicsUpdateMessages,
                    rdpGraphicsFailureUpdateResponseHex: mcsSequence.graphicsFailureUpdateResponseData?.rdpHexString,
                    rdpGraphicsFailureUpdatePayloadHex: mcsSequence.graphicsFailureUpdatePayloadData?.rdpHexString,
                    rdpGraphicsFailureUpdateMessages: mcsSequence.graphicsFailureUpdateMessages,
                    rdpGraphicsFailureUpdateMessageIndex: mcsSequence.graphicsFailureUpdateMessageIndex,
                    rdpGraphicsFrameAcknowledgeHexes: mcsSequence.graphicsFrameAcknowledgeData.map(\.rdpHexString),
                    rdpGraphicsFrames: mcsSequence.graphicsFrames,
                    rdpGraphicsFirstFrame: mcsSequence.firstGraphicsFrame,
                    rdpDisplayControlChannelID: mcsSequence.displayControlChannelCreateRequest?.channelID,
                    rdpDisplayControlChannelCreateResponseHex: mcsSequence
                        .displayControlChannelCreateResponseData?.rdpHexString,
                    rdpDisplayControlCapsHex: mcsSequence.displayControlCapsData?.rdpHexString,
                    rdpDisplayControlCaps: mcsSequence.displayControlCaps,
                    rdpClipboardChannelID: mcsSequence.clipboardChannelID,
                    rdpClipboardMessages: mcsSequence.clipboardMessages,
                    rdpClipboardMessageHexes: mcsSequence.clipboardMessageData.map(\.rdpHexString),
                    rdpClipboardSentMessages: mcsSequence.clipboardSentMessages,
                    rdpClipboardSentMessageHexes: mcsSequence.clipboardSentMessageData.map(\.rdpHexString),
                    rdpAudioChannelID: mcsSequence.audioChannelID,
                    rdpAudioMessages: mcsSequence.audioMessages,
                    rdpAudioMessageHexes: mcsSequence.audioMessageData.map(\.rdpHexString),
                    warnings: tls.warnings,
                    nextStage: mcsSequenceSucceeded ? mcsSequence.nextStage : nil,
                    error: mcsSequenceSucceeded ? nil : mcsSequence.failureMessage
                )
            } catch {
                return RDPPreflightReport(
                    status: "failure",
                    stage: "tls-upgrade",
                    target: targetString(host: configuration.host, port: configuration.port),
                    username: configuration.credentials?.username,
                    domain: configuration.credentials?.domain,
                    passwordConfigured: configuration.credentials != nil,
                    requestedProtocols: request.negotiationRequest.requestedProtocols.names,
                    requestHex: packet.rdpHexString,
                    responseHex: connection.response.rdpHexString,
                    negotiationFlags: connection.confirm.negotiationFlags,
                    selectedProtocols: selectedProtocols,
                    failureCode: failureCode,
                    tlsProtocol: nil,
                    tlsCipherSuite: nil,
                    certificateTrusted: nil,
                    certificateSHA256: nil,
                    rdpGraphicsCapabilityProfile: configuration.graphicsCapabilityProfile,
                    warnings: [],
                    nextStage: nil,
                    error: String(describing: error)
                )
            }
        }

        return RDPPreflightReport(
            status: "success",
            stage: "x224-rdp-negotiation",
            target: targetString(host: configuration.host, port: configuration.port),
            username: configuration.credentials?.username,
            domain: configuration.credentials?.domain,
            passwordConfigured: configuration.credentials != nil,
            requestedProtocols: request.negotiationRequest.requestedProtocols.names,
            requestHex: packet.rdpHexString,
            responseHex: connection.response.rdpHexString,
            negotiationFlags: connection.confirm.negotiationFlags,
            selectedProtocols: selectedProtocols,
            failureCode: failureCode,
            tlsProtocol: nil,
            tlsCipherSuite: nil,
            certificateTrusted: nil,
            certificateSHA256: nil,
            rdpGraphicsCapabilityProfile: configuration.graphicsCapabilityProfile,
            warnings: [],
            nextStage: selectedProtocols?.contains("tls") == true ? "tls-upgrade" : nil,
            error: nil
        )
    }

    private func failureReport(configuration: RDPConnectionConfiguration, error: Error) -> RDPPreflightReport {
        let request = X224ConnectionRequest()
        return RDPPreflightReport(
            status: "failure",
            stage: "x224-rdp-negotiation",
            target: targetString(host: configuration.host, port: configuration.port),
            username: configuration.credentials?.username,
            domain: configuration.credentials?.domain,
            passwordConfigured: configuration.credentials != nil,
            requestedProtocols: request.negotiationRequest.requestedProtocols.names,
            requestHex: request.encodedTPKT().rdpHexString,
            responseHex: nil,
            negotiationFlags: nil,
            selectedProtocols: nil,
            failureCode: nil,
            tlsProtocol: nil,
            tlsCipherSuite: nil,
            certificateTrusted: nil,
            certificateSHA256: nil,
            rdpGraphicsCapabilityProfile: configuration.graphicsCapabilityProfile,
            warnings: [],
            nextStage: nil,
            error: String(describing: error)
        )
    }
}

private struct NegotiatedConnection {
    var fd: Int32
    var response: Data
    var confirm: X224ConnectionConfirm
}

private struct TLSProbeResult {
    var protocolName: String
    var cipherSuite: String?
    var certificateTrusted: Bool?
    var certificateSHA256: String?
    var mcsConnectionSequence: MCSConnectionSequence?
    var warnings: [RDPProbeWarning]
}

private struct MCSConnectionSequence {
    var connectInitial: Data
    var connectResponseData: Data
    var connectResponse: MCSConnectResponse
    var erectDomainRequest: Data?
    var attachUserRequest: Data?
    var attachUserConfirmData: Data?
    var attachUserConfirm: MCSAttachUserConfirm?
    var expectedJoinCount: Int
    var joinedChannels: [RDPChannelJoinReport]
    var clientInfoRequestByteCount: Int? = nil
    var clientInfoCredentialsIncluded: Bool? = nil
    var clientInfoResponseData: Data? = nil
    var clientInfoError: String? = nil
    var autoDetectRequest: RDPServerAutoDetectRequest? = nil
    var autoDetectResponseData: Data? = nil
    var postAutoDetectResponseData: Data? = nil
    var postAutoDetectShareControl: RDPShareControlPDU? = nil
    var autoDetectError: String? = nil
    var licenseResponse: RDPServerLicensePDU? = nil
    var postLicensingResponseData: Data? = nil
    var postLicensingShareControl: RDPShareControlPDU? = nil
    var licensingError: String? = nil
    var demandActive: RDPDemandActivePDU? = nil
    var confirmActiveRequestData: Data? = nil
    var confirmActiveCapabilitySets: [RDPCapabilitySetSummary]? = nil
    var postConfirmActiveResponseData: Data? = nil
    var postConfirmActiveShareControl: RDPShareControlPDU? = nil
    var postConfirmActiveShareData: RDPShareDataPDU? = nil
    var activationError: String? = nil
    var clientSynchronizeRequestData: Data? = nil
    var clientControlCooperateRequestData: Data? = nil
    var clientControlRequestData: Data? = nil
    var clientFontListRequestData: Data? = nil
    var finalizationResponseData: [Data] = []
    var finalizationResponses: [RDPShareDataPDU] = []
    var finalizationError: String? = nil
    var dynamicChannelRequestData: [Data] = []
    var dynamicChannelRequestTypes: [String] = []
    var dynamicChannelCapabilitiesRequest: RDPDynamicVirtualChannelCapabilitiesRequest? = nil
    var dynamicChannelCapabilitiesResponseData: Data? = nil
    var graphicsChannelCreateRequest: RDPDynamicVirtualChannelCreateRequest? = nil
    var graphicsChannelCreateResponseData: Data? = nil
    var graphicsCapsAdvertiseData: Data? = nil
    var serverRedirectionData: Data? = nil
    var serverRedirection: RDPServerRedirectionPDU? = nil
    var graphicsResponseData: Data? = nil
    var graphicsResponse: RDPGFXHeader? = nil
    var graphicsCapsConfirm: RDPGFXCapsConfirmPDU? = nil
    var graphicsUpdateResponseCount: Int = 0
    var graphicsUpdateResponseData: [Data] = []
    var graphicsUpdateMessages: [RDPGFXMessageSummary] = []
    var graphicsFailureUpdateResponseData: Data? = nil
    var graphicsFailureUpdatePayloadData: Data? = nil
    var graphicsFailureUpdateMessages: [RDPGFXMessageSummary] = []
    var graphicsFailureUpdateMessageIndex: Int? = nil
    var graphicsFrameAcknowledgeData: [Data] = []
    var graphicsFrames: [RDPGraphicsFrameSnapshot] = []
    var firstGraphicsFrame: RDPGraphicsFrameSnapshot? = nil
    var graphicsError: String? = nil
    var displayControlChannelCreateRequest: RDPDynamicVirtualChannelCreateRequest? = nil
    var displayControlChannelCreateResponseData: Data? = nil
    var displayControlCapsData: Data? = nil
    var displayControlCaps: RDPDisplayControlCapabilities? = nil
    var clipboardChannelID: UInt16? = nil
    var clipboardMessageData: [Data] = []
    var clipboardMessages: [RDPClipboardMessageSummary] = []
    var clipboardSentMessageData: [Data] = []
    var clipboardSentMessages: [RDPClipboardMessageSummary] = []
    var audioChannelID: UInt16? = nil
    var audioMessageData: [Data] = []
    var audioMessages: [RDPAudioMessageSummary] = []

    var channelConnectionSucceeded: Bool {
        connectResponse.result == 0
            && attachUserConfirm?.result == 0
            && attachUserConfirm?.userChannelID != nil
            && joinedChannels.count == expectedJoinCount
            && joinedChannels.allSatisfy { $0.result == "rt-successful" }
    }

    var sequenceSucceeded: Bool {
        guard channelConnectionSucceeded, clientInfoResponseData != nil else {
            return false
        }
        if autoDetectRequest != nil {
            guard autoDetectResponseData != nil, postAutoDetectResponseData != nil else {
                return false
            }
        }
        if licenseResponse?.typeName == "license-error-valid-client" {
            guard postLicensingResponseData != nil else {
                return false
            }
        }
        if demandActive != nil {
            guard confirmActiveRequestData != nil,
                  postConfirmActiveShareData?.typeName == "server-synchronize"
            else {
                return false
            }
        }
        if finalizationAttempted {
            guard connectionFinalized else {
                return false
            }
        }
        if graphicsAttempted {
            guard graphicsCapsConfirm != nil else {
                return false
            }
            guard graphicsError == nil else {
                return false
            }
            if graphicsUpdatesAttempted {
                return !graphicsUpdateMessages.isEmpty
                    && graphicsFrameAcknowledgeData.isEmpty == false
            }
            return true
        }
        return true
    }

    var clientInfoAttempted: Bool {
        clientInfoRequestByteCount != nil || clientInfoError != nil
    }

    var autoDetectAttempted: Bool {
        autoDetectRequest != nil || autoDetectError != nil
    }

    var activationAttempted: Bool {
        demandActive != nil || confirmActiveRequestData != nil || activationError != nil
    }

    var finalizationAttempted: Bool {
        clientSynchronizeRequestData != nil
            || clientControlCooperateRequestData != nil
            || clientControlRequestData != nil
            || clientFontListRequestData != nil
            || !finalizationResponses.isEmpty
            || finalizationError != nil
    }

    var connectionFinalized: Bool {
        finalizationResponses.contains(where: {
            $0.typeName == "font-map" || $0.typeName == "control-granted-control"
        })
    }

    var graphicsAttempted: Bool {
        !dynamicChannelRequestData.isEmpty
            || dynamicChannelCapabilitiesRequest != nil
            || dynamicChannelCapabilitiesResponseData != nil
            || graphicsChannelCreateRequest != nil
            || graphicsChannelCreateResponseData != nil
            || graphicsCapsAdvertiseData != nil
            || graphicsResponseData != nil
            || graphicsUpdatesAttempted
            || graphicsError != nil
    }

    var graphicsUpdatesAttempted: Bool {
        !graphicsUpdateResponseData.isEmpty
            || graphicsUpdateResponseCount > 0
            || !graphicsUpdateMessages.isEmpty
            || !graphicsFrameAcknowledgeData.isEmpty
            || !graphicsFrames.isEmpty
    }

    var currentStage: String {
        if graphicsAttempted {
            return "rdp-graphics-dynamic-channel"
        }
        if finalizationAttempted {
            return "rdp-connection-finalization"
        }
        if activationAttempted {
            return "rdp-confirm-active"
        }
        if licenseResponse != nil || licensingError != nil {
            return "rdp-licensing"
        }
        if autoDetectAttempted {
            return "rdp-auto-detect"
        }
        if clientInfoAttempted {
            return "rdp-client-info"
        }
        return "mcs-channel-connection"
    }

    var nextStage: String {
        if graphicsCapsConfirm != nil {
            if graphicsFrameAcknowledgeData.isEmpty == false {
                return "rdp-graphics-frame-decode"
            }
            return "rdp-graphics-pipeline-updates"
        }
        if graphicsAttempted {
            return "rdp-open-graphics-dynamic-channel"
        }
        if connectionFinalized {
            return "rdp-open-graphics-dynamic-channel"
        }
        if finalizationAttempted {
            return "rdp-wait-for-control-granted"
        }
        if postConfirmActiveShareData?.typeName == "server-synchronize" {
            return "rdp-connection-finalization"
        }
        if let postConfirmActiveShareData {
            return "rdp-handle-\(postConfirmActiveShareData.typeName)"
        }
        if demandActive != nil {
            return "rdp-confirm-active"
        }
        if let postLicensingShareControl {
            switch postLicensingShareControl.typeName {
            case "server-demand-active":
                return "rdp-confirm-active"
            case "server-deactivate-all":
                return "rdp-deactivation-reactivation-or-disconnect"
            default:
                return "rdp-handle-\(postLicensingShareControl.typeName)"
            }
        }
        if licenseResponse?.typeName == "license-error-valid-client" {
            return "rdp-server-activation"
        }
        if let postAutoDetectShareControl {
            switch postAutoDetectShareControl.typeName {
            case "server-demand-active":
                return "rdp-confirm-active"
            case "server-deactivate-all":
                return "rdp-deactivation-reactivation-or-disconnect"
            default:
                return "rdp-handle-\(postAutoDetectShareControl.typeName)"
            }
        }
        if autoDetectRequest != nil {
            return "rdp-licensing-or-server-activation"
        }
        return "rdp-auto-detect-or-server-activation"
    }

    var failureMessage: String? {
        guard connectResponse.result == 0 else {
            return "MCS Connect Response result: \(connectResponse.resultName)"
        }
        guard let attachUserConfirm else {
            return "server did not send an MCS Attach User Confirm"
        }
        guard attachUserConfirm.result == 0 else {
            return "MCS Attach User Confirm result: \(attachUserConfirm.resultName)"
        }
        guard attachUserConfirm.userChannelID != nil else {
            return "MCS Attach User Confirm did not include a user channel ID"
        }
        guard joinedChannels.count == expectedJoinCount else {
            return "joined \(joinedChannels.count) of \(expectedJoinCount) MCS channels"
        }
        if let failedJoin = joinedChannels.first(where: { $0.result != "rt-successful" }) {
            return "MCS Channel Join Confirm result for \(failedJoin.name): \(failedJoin.result)"
        }
        guard clientInfoRequestByteCount != nil else {
            return "RDP Client Info PDU was not sent"
        }
        guard clientInfoResponseData != nil else {
            return clientInfoError ?? "server did not respond to RDP Client Info PDU"
        }
        if autoDetectRequest != nil {
            guard autoDetectResponseData != nil else {
                return autoDetectError ?? "RDP Auto-Detect response was not sent"
            }
            guard postAutoDetectResponseData != nil else {
                return autoDetectError ?? "server did not respond after RDP Auto-Detect response"
            }
        } else if let autoDetectError {
            return autoDetectError
        }
        if licenseResponse?.typeName == "license-error-valid-client" {
            guard postLicensingResponseData != nil else {
                return licensingError ?? "server did not respond after valid client licensing PDU"
            }
        } else if let licensingError {
            return licensingError
        }
        if demandActive != nil {
            guard confirmActiveRequestData != nil else {
                return activationError ?? "RDP Confirm Active PDU was not sent"
            }
            guard postConfirmActiveResponseData != nil else {
                return activationError ?? "server did not respond after RDP Confirm Active PDU"
            }
            guard postConfirmActiveShareData?.typeName == "server-synchronize" else {
                return activationError ?? "server did not send Synchronize PDU after RDP Confirm Active PDU"
            }
        } else if let activationError {
            return activationError
        }
        if finalizationAttempted {
            guard clientSynchronizeRequestData != nil,
                  clientControlCooperateRequestData != nil,
                  clientControlRequestData != nil,
                  clientFontListRequestData != nil
            else {
                return finalizationError ?? "RDP connection finalization request batch was not sent"
            }
            guard connectionFinalized else {
                return finalizationError ?? "server did not grant control during connection finalization"
            }
        } else if let finalizationError {
            return finalizationError
        }
        if graphicsAttempted {
            guard dynamicChannelCapabilitiesRequest != nil else {
                return graphicsError ?? "server did not send DRDYNVC capabilities request"
            }
            guard dynamicChannelCapabilitiesResponseData != nil else {
                return graphicsError ?? "DRDYNVC capabilities response was not sent"
            }
            guard graphicsChannelCreateRequest != nil else {
                return graphicsError ?? "server did not request the RDPGFX dynamic channel"
            }
            guard graphicsChannelCreateResponseData != nil else {
                return graphicsError ?? "RDPGFX dynamic channel create response was not sent"
            }
            guard graphicsCapsAdvertiseData != nil else {
                return graphicsError ?? "RDPGFX capabilities advertise PDU was not sent"
            }
            if let serverRedirection {
                if let targetHost = serverRedirection.targetHost {
                    return graphicsError ?? "server requested RDP redirection to \(targetHost)"
                }
                return graphicsError ?? "server requested RDP redirection"
            }
            guard graphicsCapsConfirm != nil else {
                return graphicsError ?? "server did not confirm RDPGFX capabilities"
            }
            if graphicsUpdatesAttempted {
                guard !graphicsUpdateMessages.isEmpty else {
                    return graphicsError ?? "server graphics update did not contain RDPGFX messages"
                }
                guard !graphicsFrameAcknowledgeData.isEmpty else {
                    return graphicsError ?? "RDPGFX frame acknowledgement was not sent"
                }
            }
            if let graphicsError {
                return graphicsError
            }
        } else if let graphicsError {
            return graphicsError
        }
        return nil
    }
}

private struct MCSChannelJoinTarget {
    var name: String
    var channelID: UInt16
}

private struct RDPConnectionFinalizationResult {
    var clientSynchronizeRequestData: Data
    var clientControlCooperateRequestData: Data
    var clientControlRequestData: Data
    var clientFontListRequestData: Data
    var responseData: [Data]
    var responses: [RDPShareDataPDU]
    var error: String?

    var completed: Bool {
        responses.contains(where: {
            $0.typeName == "font-map" || $0.typeName == "control-granted-control"
        })
    }
}

private struct RDPGraphicsDynamicChannelResult {
    var dynamicChannelRequestData: [Data] = []
    var dynamicChannelRequestTypes: [String] = []
    var dynamicChannelCapabilitiesRequest: RDPDynamicVirtualChannelCapabilitiesRequest? = nil
    var dynamicChannelCapabilitiesResponseData: Data? = nil
    var graphicsChannelCreateRequest: RDPDynamicVirtualChannelCreateRequest? = nil
    var graphicsChannelCreateResponseData: Data? = nil
    var graphicsCapsAdvertiseData: Data? = nil
    var serverRedirectionData: Data? = nil
    var serverRedirection: RDPServerRedirectionPDU? = nil
    var graphicsResponseData: Data? = nil
    var graphicsResponse: RDPGFXHeader? = nil
    var graphicsCapsConfirm: RDPGFXCapsConfirmPDU? = nil
    var graphicsUpdateResponseCount: Int = 0
    var graphicsUpdateResponseData: [Data] = []
    var latestGraphicsUpdateResponseData: Data? = nil
    var graphicsUpdateMessages: [RDPGFXMessageSummary] = []
    var graphicsFailureUpdateResponseData: Data? = nil
    var graphicsFailureUpdatePayloadData: Data? = nil
    var graphicsFailureUpdateMessages: [RDPGFXMessageSummary] = []
    var graphicsFailureUpdateMessageIndex: Int? = nil
    var graphicsFrameAcknowledgeData: [Data] = []
    var graphicsFrames: [RDPGraphicsFrameSnapshot] = []
    var firstGraphicsFrame: RDPGraphicsFrameSnapshot? = nil
    var pendingGraphicsFrames: [RDPGraphicsFrameSnapshot] = []
    var displayControlChannelCreateRequest: RDPDynamicVirtualChannelCreateRequest? = nil
    var displayControlChannelCreateResponseData: Data? = nil
    var displayControlCapsData: Data? = nil
    var displayControlCaps: RDPDisplayControlCapabilities? = nil
    var clipboardMessageData: [Data] = []
    var clipboardMessages: [RDPClipboardMessageSummary] = []
    var audioMessageData: [Data] = []
    var audioMessages: [RDPAudioMessageSummary] = []
    var error: String? = nil
}

private struct RDPDynamicVirtualChannelFragment {
    var channelID: UInt32
    var totalLength: UInt32
    var payload: Data
}

private func targetString(host: String, port: UInt16) -> String {
    "\(host):\(port)"
}

private func throwIfCancelled(
    _ shouldCancel: RDPCancellationHandler?,
    cancellation: RDPConnectionCancellation?
) throws {
    if cancellation?.isCancelled == true || shouldCancel?() == true {
        throw RDPPreflightError.cancelled
    }
}

private func openSocket(host: String, port: UInt16, timeoutSeconds: Int) throws -> Int32 {
    var hints = addrinfo(
        ai_flags: 0,
        ai_family: AF_UNSPEC,
        ai_socktype: SOCK_STREAM,
        ai_protocol: IPPROTO_TCP,
        ai_addrlen: 0,
        ai_canonname: nil,
        ai_addr: nil,
        ai_next: nil
    )
    var result: UnsafeMutablePointer<addrinfo>?
    let lookup = getaddrinfo(host, String(port), &hints, &result)
    guard lookup == 0, let result else {
        throw RDPPreflightError.addressResolution(String(cString: gai_strerror(lookup)))
    }
    defer { freeaddrinfo(result) }

    var current: UnsafeMutablePointer<addrinfo>? = result
    var lastError = "no addresses"

    while let address = current {
        let fd = socket(address.pointee.ai_family, address.pointee.ai_socktype, address.pointee.ai_protocol)
        if fd < 0 {
            lastError = String(cString: strerror(errno))
            current = address.pointee.ai_next
            continue
        }

        do {
            try configureTimeout(fd: fd, timeoutSeconds: timeoutSeconds)
            guard Darwin.connect(fd, address.pointee.ai_addr, address.pointee.ai_addrlen) == 0 else {
                throw RDPPreflightError.connect(String(cString: strerror(errno)))
            }
            return fd
        } catch {
            lastError = String(describing: error)
            close(fd)
            current = address.pointee.ai_next
        }
    }

    throw RDPPreflightError.connect(lastError)
}

private func connectAndNegotiate(
    host: String,
    port: UInt16,
    timeoutSeconds: Int,
    packet: Data,
    onWireReceive: RDPWireReceiveHandler?,
    cancellation: RDPConnectionCancellation?
) throws -> NegotiatedConnection {
    let fd = try openSocket(host: host, port: port, timeoutSeconds: timeoutSeconds)
    let cancellationRegistration = cancellation?.register {
        _ = Darwin.shutdown(fd, SHUT_RDWR)
    }
    do {
        try sendAll(fd: fd, packet: packet)
        let response = try receiveTPKT(
            fd: fd,
            timeoutSeconds: timeoutSeconds,
            timeoutDescription: "X224 Connection Confirm"
        )
        onWireReceive?(RDPWireReceiveSample(byteCount: response.count, receivedAt: Date()))
        let confirm = try X224ConnectionConfirm.parse(fromTPKT: response)
        cancellationRegistration?.cancel()
        return NegotiatedConnection(fd: fd, response: response, confirm: confirm)
    } catch {
        cancellationRegistration?.cancel()
        close(fd)
        throw error
    }
}

private func configureTimeout(fd: Int32, timeoutSeconds: Int) throws {
    var timeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
    let size = socklen_t(MemoryLayout<timeval>.size)
    guard setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, size) == 0 else {
        throw RDPPreflightError.receive(String(cString: strerror(errno)))
    }
    guard setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, size) == 0 else {
        throw RDPPreflightError.send(String(cString: strerror(errno)))
    }
}

private func sendAll(fd: Int32, packet: Data) throws {
    try packet.withUnsafeBytes { buffer in
        guard let base = buffer.baseAddress else { return }
        var sent = 0
        while sent < buffer.count {
            let result = Darwin.send(fd, base.advanced(by: sent), buffer.count - sent, 0)
            guard result > 0 else {
                throw RDPPreflightError.send(String(cString: strerror(errno)))
            }
            sent += result
        }
    }
}

private func receiveTPKT(fd: Int32, timeoutSeconds: Int, timeoutDescription: String) throws -> Data {
    var header = [UInt8](repeating: 0, count: 4)
    try receiveExact(
        fd: fd,
        into: &header,
        timeoutSeconds: timeoutSeconds,
        timeoutDescription: timeoutDescription
    )
    let length = Int(header[2]) << 8 | Int(header[3])
    guard length >= 4 else {
        throw RDPPreflightError.receive("received invalid TPKT length \(length)")
    }

    var packet = Data(header)
    guard length > header.count else {
        return packet
    }

    var body = [UInt8](repeating: 0, count: length - header.count)
    try receiveExact(
        fd: fd,
        into: &body,
        timeoutSeconds: timeoutSeconds,
        timeoutDescription: timeoutDescription
    )
    packet.append(contentsOf: body)
    return packet
}

private func receiveExact(
    fd: Int32,
    into buffer: inout [UInt8],
    timeoutSeconds: Int,
    timeoutDescription: String
) throws {
    var received = 0
    while received < buffer.count {
        let remainingByteCount = buffer.count - received
        let count = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
            guard let baseAddress = rawBuffer.baseAddress else {
                return 0
            }
            return Darwin.recv(fd, baseAddress.advanced(by: received), remainingByteCount, 0)
        }

        if count > 0 {
            received += count
            continue
        }

        if count == 0 {
            throw RDPPreflightError.receive("connection closed before receiving \(timeoutDescription)")
        }

        let receiveErrno = errno
        if receiveErrno == EINTR {
            continue
        }
        if receiveErrno == EAGAIN || receiveErrno == EWOULDBLOCK {
            throw RDPPreflightError.receive("\(timeoutDescription) timed out after \(timeoutSeconds) seconds")
        }
        throw RDPPreflightError.receive(String(cString: strerror(receiveErrno)))
    }
}

private final class TLSHandshakeCompletionHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer

    private let promise: EventLoopPromise<Void>
    private var completed = false

    init(promise: EventLoopPromise<Void>) {
        self.promise = promise
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let tlsEvent = event as? TLSUserEvent, case .handshakeCompleted = tlsEvent {
            succeed()
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelInactive(context: ChannelHandlerContext) {
        fail(RDPPreflightError.tls("connection closed before TLS handshake completed"))
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        fail(error)
        context.close(promise: nil)
    }

    func fail(_ error: Error) {
        guard !completed else { return }
        completed = true
        promise.fail(error)
    }

    private func succeed() {
        guard !completed else { return }
        completed = true
        promise.succeed(())
    }
}

extension TLSHandshakeCompletionHandler: @unchecked Sendable {}

private final class TLSTPKTStreamHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer

    private let onWireReceive: RDPWireReceiveHandler?
    private var received = Data()
    private var receivedReadOffset = 0
    private var packets: [Data] = []
    private var pending: [EventLoopPromise<Data>] = []
    private var failure: Error?

    init(onWireReceive: RDPWireReceiveHandler? = nil) {
        self.onWireReceive = onWireReceive
    }

    func nextPacket(on channel: Channel) -> EventLoopFuture<Data> {
        let promise = channel.eventLoop.makePromise(of: Data.self)
        channel.eventLoop.execute {
            if let failure = self.failure {
                promise.fail(failure)
            } else if !self.packets.isEmpty {
                promise.succeed(self.packets.removeFirst())
            } else {
                self.pending.append(promise)
            }
        }
        return promise.futureResult
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        if let bytes = buffer.readBytes(length: buffer.readableBytes) {
            received.append(contentsOf: bytes)
        }
        completeIfPossible(context: context)
    }

    func channelInactive(context: ChannelHandlerContext) {
        fail(RDPPreflightError.receive("connection closed before receiving a TPKT response"))
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        fail(error)
        context.close(promise: nil)
    }

    func fail(_ error: Error) {
        guard failure == nil else { return }
        failure = error
        received = Data()
        receivedReadOffset = 0
        for promise in pending {
            promise.fail(error)
        }
        pending.removeAll()
        packets.removeAll()
    }

    private func completeIfPossible(context: ChannelHandlerContext) {
        while receivedReadableBytes >= 2 {
            let length: Int
            do {
                guard let parsedLength = try RDPTransportPacketFraming.packetLength(
                    readableByteCount: receivedReadableBytes,
                    byteAt: receivedByte(at:)
                ) else {
                    return
                }
                length = parsedLength
            } catch {
                fail(error)
                context.close(promise: nil)
                return
            }

            guard receivedReadableBytes >= length else {
                return
            }

            let packetStart = received.index(received.startIndex, offsetBy: receivedReadOffset)
            let packetEnd = received.index(packetStart, offsetBy: length)
            let packet = received.subdata(in: packetStart ..< packetEnd)
            receivedReadOffset += length
            compactReceivedBufferIfNeeded()
            onWireReceive?(RDPWireReceiveSample(byteCount: packet.count, receivedAt: Date()))
            if pending.isEmpty {
                packets.append(packet)
            } else {
                pending.removeFirst().succeed(packet)
            }
        }
    }

    private var receivedReadableBytes: Int {
        received.count - receivedReadOffset
    }

    private func receivedByte(at relativeOffset: Int) -> UInt8 {
        received[
            received.index(
                received.startIndex,
                offsetBy: receivedReadOffset + relativeOffset
            )
        ]
    }

    private func compactReceivedBufferIfNeeded() {
        guard receivedReadOffset > 0 else {
            return
        }

        if receivedReadOffset == received.count {
            received = Data()
            receivedReadOffset = 0
            return
        }

        guard receivedReadOffset >= 64 * 1024,
              receivedReadOffset * 2 >= received.count
        else {
            return
        }

        let unreadStart = received.index(received.startIndex, offsetBy: receivedReadOffset)
        received = received.subdata(in: unreadStart ..< received.endIndex)
        receivedReadOffset = 0
    }
}

extension TLSTPKTStreamHandler: @unchecked Sendable {}

enum RDPTransportPacketFraming {
    static func packetLength(from data: Data) throws -> Int? {
        try packetLength(readableByteCount: data.count) { index in
            data[data.index(data.startIndex, offsetBy: index)]
        }
    }

    static func packetLength(
        readableByteCount: Int,
        byteAt: (Int) -> UInt8
    ) throws -> Int? {
        guard readableByteCount >= 2 else {
            return nil
        }

        guard byteAt(0) != TPKT.version else {
            guard readableByteCount >= 4 else {
                return nil
            }

            let length = Int(byteAt(2)) << 8 | Int(byteAt(3))
            guard length >= 4 else {
                throw RDPPreflightError.receive("received invalid TPKT length \(length)")
            }
            return length
        }

        let firstLengthByte = byteAt(1)
        let length: Int
        if firstLengthByte & 0x80 == 0 {
            length = Int(firstLengthByte)
        } else {
            guard readableByteCount >= 3 else {
                return nil
            }
            length = Int(firstLengthByte & 0x7F) << 8 | Int(byteAt(2))
        }

        guard length >= 3, length <= 0x8000 else {
            throw RDPPreflightError.receive("received invalid Fast-Path length \(length)")
        }
        return length
    }
}

private final class TLSASN1StreamHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer

    private let onWireReceive: RDPWireReceiveHandler?
    private var received = Data()
    private var receivedReadOffset = 0
    private var messages: [Data] = []
    private var pending: [EventLoopPromise<Data>] = []
    private var failure: Error?

    init(onWireReceive: RDPWireReceiveHandler? = nil) {
        self.onWireReceive = onWireReceive
    }

    func nextMessage(on channel: Channel) -> EventLoopFuture<Data> {
        let promise = channel.eventLoop.makePromise(of: Data.self)
        channel.eventLoop.execute {
            if let failure = self.failure {
                promise.fail(failure)
            } else if !self.messages.isEmpty {
                promise.succeed(self.messages.removeFirst())
            } else {
                self.pending.append(promise)
            }
        }
        return promise.futureResult
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        if let bytes = buffer.readBytes(length: buffer.readableBytes) {
            received.append(contentsOf: bytes)
        }
        completeIfPossible(context: context)
    }

    func channelInactive(context: ChannelHandlerContext) {
        fail(RDPPreflightError.receive("connection closed before receiving a CredSSP response"))
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        fail(error)
        context.close(promise: nil)
    }

    func fail(_ error: Error) {
        guard failure == nil else { return }
        failure = error
        received = Data()
        receivedReadOffset = 0
        for promise in pending {
            promise.fail(error)
        }
        pending.removeAll()
        messages.removeAll()
    }

    private func completeIfPossible(context: ChannelHandlerContext) {
        while receivedReadableBytes >= 2 {
            let length: Int
            do {
                guard let parsedLength = try derMessageLength() else {
                    return
                }
                length = parsedLength
            } catch {
                fail(error)
                context.close(promise: nil)
                return
            }

            guard receivedReadableBytes >= length else {
                return
            }

            let messageStart = received.index(received.startIndex, offsetBy: receivedReadOffset)
            let messageEnd = received.index(messageStart, offsetBy: length)
            let message = received.subdata(in: messageStart ..< messageEnd)
            receivedReadOffset += length
            compactReceivedBufferIfNeeded()
            onWireReceive?(RDPWireReceiveSample(byteCount: message.count, receivedAt: Date()))
            if pending.isEmpty {
                messages.append(message)
            } else {
                pending.removeFirst().succeed(message)
            }
        }
    }

    private func derMessageLength() throws -> Int? {
        guard receivedReadableBytes >= 2 else {
            return nil
        }
        guard receivedByte(at: 0) == 0x30 else {
            throw RDPPreflightError.receive(
                "received invalid CredSSP ASN.1 tag 0x\(String(format: "%02x", receivedByte(at: 0)))"
            )
        }

        let firstLengthByte = receivedByte(at: 1)
        if firstLengthByte & 0x80 == 0 {
            return 2 + Int(firstLengthByte)
        }

        let lengthByteCount = Int(firstLengthByte & 0x7F)
        guard lengthByteCount > 0, lengthByteCount <= 4 else {
            throw RDPPreflightError.receive("received invalid CredSSP ASN.1 length")
        }
        guard receivedReadableBytes >= 2 + lengthByteCount else {
            return nil
        }

        var payloadLength = 0
        for index in 0 ..< lengthByteCount {
            payloadLength = (payloadLength << 8) | Int(receivedByte(at: 2 + index))
        }
        return 2 + lengthByteCount + payloadLength
    }

    private var receivedReadableBytes: Int {
        received.count - receivedReadOffset
    }

    private func receivedByte(at relativeOffset: Int) -> UInt8 {
        received[
            received.index(
                received.startIndex,
                offsetBy: receivedReadOffset + relativeOffset
            )
        ]
    }

    private func compactReceivedBufferIfNeeded() {
        guard receivedReadOffset > 0 else {
            return
        }

        if receivedReadOffset == received.count {
            received = Data()
            receivedReadOffset = 0
            return
        }

        guard receivedReadOffset >= 64 * 1024,
              receivedReadOffset * 2 >= received.count
        else {
            return
        }

        let unreadStart = received.index(received.startIndex, offsetBy: receivedReadOffset)
        received = received.subdata(in: unreadStart ..< received.endIndex)
        receivedReadOffset = 0
    }
}

extension TLSASN1StreamHandler: @unchecked Sendable {}

private func performTLSHandshake(
    fd: Int32,
    host: String,
    timeoutSeconds: Int,
    hideCertificateWarnings: Bool,
    credentials: RDPCredentials? = nil,
    credSSPRequired: Bool,
    mcsConfiguration: MCSConnectInitialConfiguration? = nil,
    graphicsFrameCaptureLimit: Int?,
    graphicsCapabilityProfile: RDPGraphicsCapabilityProfile,
    onGraphicsFrame: RDPGraphicsFrameHandler?,
    onInputReady: RDPInputSessionHandler?,
    onDisplayControlReady: RDPDisplayControlSessionHandler?,
    onClipboardReady: RDPClipboardSessionHandler?,
    onClipboardText: RDPClipboardTextHandler?,
    onClipboardFileGroupDescriptor: RDPClipboardFileGroupDescriptorHandler?,
    onClipboardFileContents: RDPClipboardFileContentsHandler?,
    onAudioSample: RDPAudioSampleHandler?,
    onCertificate: RDPServerCertificateHandler?,
    onWireReceive: RDPWireReceiveHandler?,
    cancellation: RDPConnectionCancellation?,
    shouldCancel: RDPCancellationHandler?
) throws -> TLSProbeResult {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    var channel: Channel?
    var fdTransferredToNIO = false
    defer {
        if let channel {
            try? channel.close().wait()
        } else if !fdTransferredToNIO {
            close(fd)
        }
        try? group.syncShutdownGracefully()
    }

    let bootstrap = ClientBootstrap(group: group)
        .channelInitializer { channel in
            channel.eventLoop.makeSucceededFuture(())
        }

    fdTransferredToNIO = true
    channel = try bootstrap.withConnectedSocket(fd).wait()
    guard let channel else {
        throw RDPPreflightError.tls("failed to attach NIO to the connected socket")
    }
    let cancellationRegistration = cancellation?.register {
        channel.eventLoop.execute {
            channel.close(promise: nil)
        }
    }
    defer {
        cancellationRegistration?.cancel()
    }

    var tlsConfiguration = TLSConfiguration.makeClientConfiguration()
    tlsConfiguration.certificateVerification = .none
    // Windows RDP can issue RSA certificates without digitalSignature,
    // which BoringSSL rejects on the TLS 1.3 certificate path.
    tlsConfiguration.maximumTLSVersion = .tlsv12

    let tlsContext = try NIOSSLContext(configuration: tlsConfiguration)
    let handshakePromise = channel.eventLoop.makePromise(of: Void.self)
    let handshakeHandler = TLSHandshakeCompletionHandler(promise: handshakePromise)
    try channel.pipeline.addHandler(handshakeHandler).wait()
    try channel.eventLoop.submit {
        let tlsHandler = try NIOSSLClientHandler(
            context: tlsContext,
            serverHostname: sniHostname(for: host)
        )
        try channel.pipeline.syncOperations.addHandler(tlsHandler, position: .first)
    }.wait()

    let timeoutTask = channel.eventLoop.scheduleTask(in: .seconds(Int64(timeoutSeconds))) {
        handshakeHandler.fail(RDPPreflightError.tls("TLS handshake timed out after \(timeoutSeconds) seconds"))
        channel.close(promise: nil)
    }
    handshakePromise.futureResult.whenComplete { _ in
        timeoutTask.cancel()
    }
    try handshakePromise.futureResult.wait()

    let peerCertificates = try channel.eventLoop.submit {
        try channel.pipeline.syncOperations
            .handler(type: NIOSSLClientHandler.self)
            .peerCertificate
            .map { [$0] } ?? []
    }.wait()
    let negotiatedTLSVersion = try channel.eventLoop.submit {
        try channel.pipeline.syncOperations
            .handler(type: NIOSSLClientHandler.self)
            .tlsVersion
    }.wait()

    let trustResult = try inspectPeerCertificates(
        peerCertificates,
        host: host,
        hideCertificateWarnings: hideCertificateWarnings
    )
    onCertificate?(trustResult)
    if credSSPRequired {
        guard let credentials else {
            throw RDPCredSSPError.missingCredentials
        }
        try performCredSSPHandshake(
            on: channel,
            credentials: credentials,
            certificates: peerCertificates,
            timeoutSeconds: timeoutSeconds,
            onWireReceive: onWireReceive,
            cancellation: cancellation,
            shouldCancel: shouldCancel
        )
    }
    let mcsConnectionSequence = try mcsConfiguration.map { configuration in
        try performMCSConnectionSequence(
            configuration: configuration,
            on: channel,
            timeoutSeconds: timeoutSeconds,
            credentials: credentials,
            graphicsFrameCaptureLimit: graphicsFrameCaptureLimit,
            graphicsCapabilityProfile: graphicsCapabilityProfile,
            onGraphicsFrame: onGraphicsFrame,
            onInputReady: onInputReady,
            onDisplayControlReady: onDisplayControlReady,
            onClipboardReady: onClipboardReady,
            onClipboardText: onClipboardText,
            onClipboardFileGroupDescriptor: onClipboardFileGroupDescriptor,
            onClipboardFileContents: onClipboardFileContents,
            onAudioSample: onAudioSample,
            onWireReceive: onWireReceive,
            cancellation: cancellation,
            shouldCancel: shouldCancel
        )
    }

    return TLSProbeResult(
        protocolName: tlsVersionName(negotiatedTLSVersion),
        cipherSuite: nil,
        certificateTrusted: trustResult.trusted,
        certificateSHA256: trustResult.sha256,
        mcsConnectionSequence: mcsConnectionSequence,
        warnings: trustResult.warnings
    )
}

private func performCredSSPHandshake(
    on channel: Channel,
    credentials: RDPCredentials,
    certificates: [NIOSSLCertificate],
    timeoutSeconds: Int,
    onWireReceive: RDPWireReceiveHandler?,
    cancellation: RDPConnectionCancellation?,
    shouldCancel: RDPCancellationHandler?
) throws {
    try throwIfCancelled(shouldCancel, cancellation: cancellation)
    guard let leafCertificate = certificates.first else {
        throw RDPPreflightError.tls("server did not provide a TLS certificate")
    }

    let subjectPublicKey = try RDPCredSSPCertificate.subjectPublicKey(
        fromCertificateDER: Data(leafCertificate.toDERBytes())
    )
    let ntlmContext = RDPCredSSPNTLMContext(credentials: credentials)
    let reader = TLSASN1StreamHandler(onWireReceive: onWireReceive)
    try channel.pipeline.addHandler(reader).wait()
    defer {
        try? channel.pipeline.removeHandler(reader).wait()
    }

    var negotiatedVersion = 6
    var inputToken: Data?
    // Windows RDP expects the v5+ nonce from the first client TSRequest.
    let clientNonce = credSSPNonce()

    while true {
        try throwIfCancelled(shouldCancel, cancellation: cancellation)
        let step = try ntlmContext.initialize(inputToken: inputToken)
        var request = RDPCredSSPTSRequest(
            version: negotiatedVersion,
            negoTokens: step.outputToken.map { [$0] } ?? [],
            clientNonce: negotiatedVersion >= 5 ? clientNonce : nil
        )

        if step.isComplete {
            switch negotiatedVersion {
            case 5...:
                request.pubKeyAuth = try ntlmContext.wrap(
                    RDPCredSSPPublicKeyBinding.clientServerHash(
                        subjectPublicKey: subjectPublicKey,
                        nonce: clientNonce
                    )
                )
            case 2...4:
                request.pubKeyAuth = try ntlmContext.wrap(subjectPublicKey)
            default:
                throw RDPCredSSPError.unsupportedVersion(negotiatedVersion)
            }
        }

        try sendApplicationPacket(request.encoded(), on: channel)
        if step.isComplete {
            break
        }

        let response = try receiveCredSSPMessage(
            on: channel,
            reader: reader,
            timeoutSeconds: timeoutSeconds,
            cancellation: cancellation,
            shouldCancel: shouldCancel
        )
        try validateCredSSP(response)
        negotiatedVersion = try effectiveCredSSPVersion(response.version)
        guard let serverToken = response.negoTokens.last else {
            throw RDPCredSSPError.missingToken
        }
        inputToken = serverToken
    }

    let bindingResponse = try receiveCredSSPMessage(
        on: channel,
        reader: reader,
        timeoutSeconds: timeoutSeconds,
        cancellation: cancellation,
        shouldCancel: shouldCancel
    )
    try validateCredSSP(bindingResponse)
    negotiatedVersion = try effectiveCredSSPVersion(bindingResponse.version)
    guard let serverPubKeyAuth = bindingResponse.pubKeyAuth else {
        throw RDPCredSSPError.missingPubKeyAuth
    }

    let serverBinding = try ntlmContext.unwrap(serverPubKeyAuth)
    let expectedServerBinding: Data
    switch negotiatedVersion {
    case 5...:
        expectedServerBinding = RDPCredSSPPublicKeyBinding.serverClientHash(
            subjectPublicKey: subjectPublicKey,
            nonce: clientNonce
        )
    case 2...4:
        expectedServerBinding = try RDPCredSSPPublicKeyBinding.legacyServerResponse(
            subjectPublicKey: subjectPublicKey
        )
    default:
        throw RDPCredSSPError.unsupportedVersion(negotiatedVersion)
    }
    guard serverBinding == expectedServerBinding else {
        throw RDPCredSSPError.serverBindingMismatch
    }

    let authInfo = try ntlmContext.wrap(RDPCredSSPCredentials.passwordCredentials(credentials))
    try sendApplicationPacket(
        RDPCredSSPTSRequest(
            version: negotiatedVersion,
            authInfo: authInfo,
            clientNonce: negotiatedVersion >= 5 ? clientNonce : nil
        ).encoded(),
        on: channel
    )
}

private func receiveCredSSPMessage(
    on channel: Channel,
    reader: TLSASN1StreamHandler,
    timeoutSeconds: Int,
    cancellation: RDPConnectionCancellation?,
    shouldCancel: RDPCancellationHandler?
) throws -> RDPCredSSPTSRequest {
    try throwIfCancelled(shouldCancel, cancellation: cancellation)
    let response = reader.nextMessage(on: channel)
    let cancellationRegistration = cancellation?.register {
        channel.eventLoop.execute {
            reader.fail(RDPPreflightError.cancelled)
            channel.close(promise: nil)
        }
    }
    defer {
        cancellationRegistration?.cancel()
    }
    let timeoutTask = channel.eventLoop.scheduleTask(in: .seconds(Int64(timeoutSeconds))) {
        reader.fail(RDPPreflightError.receive("CredSSP response timed out after \(timeoutSeconds) seconds"))
        channel.close(promise: nil)
    }
    response.whenComplete { _ in
        timeoutTask.cancel()
    }
    return try RDPCredSSPTSRequest.parse(response.wait())
}

private func validateCredSSP(_ response: RDPCredSSPTSRequest) throws {
    if let errorCode = response.errorCode {
        throw RDPCredSSPError.serverError(errorCode)
    }
}

private func effectiveCredSSPVersion(_ version: Int) throws -> Int {
    guard version >= 2 else {
        throw RDPCredSSPError.unsupportedVersion(version)
    }
    return min(version, 6)
}

private func credSSPNonce() -> Data {
    var nonce = Data()
    for _ in 0 ..< 32 {
        nonce.append(UInt8.random(in: .min ... .max))
    }
    return nonce
}

private func performMCSConnectionSequence(
    configuration: MCSConnectInitialConfiguration,
    on channel: Channel,
    timeoutSeconds: Int,
    credentials: RDPCredentials?,
    graphicsFrameCaptureLimit: Int?,
    graphicsCapabilityProfile: RDPGraphicsCapabilityProfile,
    onGraphicsFrame: RDPGraphicsFrameHandler?,
    onInputReady: RDPInputSessionHandler?,
    onDisplayControlReady: RDPDisplayControlSessionHandler?,
    onClipboardReady: RDPClipboardSessionHandler?,
    onClipboardText: RDPClipboardTextHandler?,
    onClipboardFileGroupDescriptor: RDPClipboardFileGroupDescriptorHandler?,
    onClipboardFileContents: RDPClipboardFileContentsHandler?,
    onAudioSample: RDPAudioSampleHandler?,
    onWireReceive: RDPWireReceiveHandler?,
    cancellation: RDPConnectionCancellation?,
    shouldCancel: RDPCancellationHandler?
) throws -> MCSConnectionSequence {
    let tpktReader = TLSTPKTStreamHandler(onWireReceive: onWireReceive)
    try channel.pipeline.addHandler(tpktReader).wait()
    defer {
        try? channel.pipeline.removeHandler(tpktReader).wait()
    }

    let connectInitial = MCSConnectInitialPDU(configuration: configuration).encodedTPKT()
    let connectResponseData = try sendApplicationPacketAndReceiveTPKT(
        connectInitial,
        on: channel,
        reader: tpktReader,
        timeoutSeconds: timeoutSeconds,
        timeoutDescription: "MCS Connect Response"
    )
    let connectResponse = try MCSConnectResponse.parse(
        fromTPKT: connectResponseData,
        requestedChannels: configuration.channels
    )

    guard connectResponse.result == 0 else {
        return MCSConnectionSequence(
            connectInitial: connectInitial,
            connectResponseData: connectResponseData,
            connectResponse: connectResponse,
            erectDomainRequest: nil,
            attachUserRequest: nil,
            attachUserConfirmData: nil,
            attachUserConfirm: nil,
            expectedJoinCount: 0,
            joinedChannels: []
        )
    }

    let erectDomainRequest = MCSErectDomainRequestPDU().encodedTPKT()
    try sendApplicationPacket(erectDomainRequest, on: channel)

    let attachUserRequest = MCSAttachUserRequestPDU().encodedTPKT()
    let attachUserConfirmData = try sendApplicationPacketAndReceiveTPKT(
        attachUserRequest,
        on: channel,
        reader: tpktReader,
        timeoutSeconds: timeoutSeconds,
        timeoutDescription: "MCS Attach User Confirm"
    )
    let attachUserConfirm = try MCSAttachUserConfirm.parse(fromTPKT: attachUserConfirmData)

    guard attachUserConfirm.result == 0, let userChannelID = attachUserConfirm.userChannelID else {
        return MCSConnectionSequence(
            connectInitial: connectInitial,
            connectResponseData: connectResponseData,
            connectResponse: connectResponse,
            erectDomainRequest: erectDomainRequest,
            attachUserRequest: attachUserRequest,
            attachUserConfirmData: attachUserConfirmData,
            attachUserConfirm: attachUserConfirm,
            expectedJoinCount: 0,
            joinedChannels: []
        )
    }

    let joinTargets = channelJoinTargets(
        userChannelID: userChannelID,
        connectResponse: connectResponse
    )
    var joinedChannels: [RDPChannelJoinReport] = []
    for target in joinTargets {
        let request = MCSChannelJoinRequestPDU(
            initiator: userChannelID,
            channelID: target.channelID
        ).encodedTPKT()
        let confirmData = try sendApplicationPacketAndReceiveTPKT(
            request,
            on: channel,
            reader: tpktReader,
            timeoutSeconds: timeoutSeconds,
            timeoutDescription: "MCS Channel Join Confirm for \(target.name)"
        )
        let confirm = try MCSChannelJoinConfirm.parse(fromTPKT: confirmData)
        joinedChannels.append(RDPChannelJoinReport(
            name: target.name,
            channelID: target.channelID,
            requestHex: request.rdpHexString,
            confirmHex: confirmData.rdpHexString,
            result: confirm.resultName
        ))

        guard confirm.result == 0 else {
            break
        }
    }

    guard joinedChannels.count == joinTargets.count,
          joinedChannels.allSatisfy({ $0.result == "rt-successful" }),
          let ioChannelID = connectResponse.ioChannelID
    else {
        return MCSConnectionSequence(
            connectInitial: connectInitial,
            connectResponseData: connectResponseData,
            connectResponse: connectResponse,
            erectDomainRequest: erectDomainRequest,
            attachUserRequest: attachUserRequest,
            attachUserConfirmData: attachUserConfirmData,
            attachUserConfirm: attachUserConfirm,
            expectedJoinCount: joinTargets.count,
            joinedChannels: joinedChannels
        )
    }

    let clientInfo = RDPClientInfoPDU(credentials: credentials)
    let clientInfoRequest: Data
    do {
        clientInfoRequest = try clientInfo.encodedTPKT(
            userChannelID: userChannelID,
            ioChannelID: ioChannelID
        )
    } catch {
        return MCSConnectionSequence(
            connectInitial: connectInitial,
            connectResponseData: connectResponseData,
            connectResponse: connectResponse,
            erectDomainRequest: erectDomainRequest,
            attachUserRequest: attachUserRequest,
            attachUserConfirmData: attachUserConfirmData,
            attachUserConfirm: attachUserConfirm,
            expectedJoinCount: joinTargets.count,
            joinedChannels: joinedChannels,
            clientInfoRequestByteCount: nil,
            clientInfoCredentialsIncluded: clientInfo.credentialsIncluded,
            clientInfoResponseData: nil,
            clientInfoError: String(describing: error)
        )
    }

    let clientInfoResponseData: Data
    do {
        clientInfoResponseData = try sendApplicationPacketAndReceiveTPKT(
            clientInfoRequest,
            on: channel,
            reader: tpktReader,
            timeoutSeconds: timeoutSeconds,
            timeoutDescription: "RDP Client Info Response"
        )
    } catch {
        return MCSConnectionSequence(
            connectInitial: connectInitial,
            connectResponseData: connectResponseData,
            connectResponse: connectResponse,
            erectDomainRequest: erectDomainRequest,
            attachUserRequest: attachUserRequest,
            attachUserConfirmData: attachUserConfirmData,
            attachUserConfirm: attachUserConfirm,
            expectedJoinCount: joinTargets.count,
            joinedChannels: joinedChannels,
            clientInfoRequestByteCount: clientInfoRequest.count,
            clientInfoCredentialsIncluded: clientInfo.credentialsIncluded,
            clientInfoResponseData: nil,
            clientInfoError: String(describing: error)
        )
    }

    let autoDetectRequest: RDPServerAutoDetectRequest?
    do {
        autoDetectRequest = try RDPServerAutoDetectRequest.parseIfPresent(fromTPKT: clientInfoResponseData)
    } catch {
        return MCSConnectionSequence(
            connectInitial: connectInitial,
            connectResponseData: connectResponseData,
            connectResponse: connectResponse,
            erectDomainRequest: erectDomainRequest,
            attachUserRequest: attachUserRequest,
            attachUserConfirmData: attachUserConfirmData,
            attachUserConfirm: attachUserConfirm,
            expectedJoinCount: joinTargets.count,
            joinedChannels: joinedChannels,
            clientInfoRequestByteCount: clientInfoRequest.count,
            clientInfoCredentialsIncluded: clientInfo.credentialsIncluded,
            clientInfoResponseData: clientInfoResponseData,
            clientInfoError: nil,
            autoDetectError: String(describing: error)
        )
    }

    var autoDetectResponse: Data?
    let serverActivationResponseData: Data
    let postAutoDetectResponseData: Data?
    if let autoDetectRequest {
        do {
            let autoDetectResult = try performRDPAutoDetectExchange(
                initialRequest: autoDetectRequest,
                userChannelID: userChannelID,
                fallbackMessageChannelID: connectResponse.messageChannelID,
                on: channel,
                reader: tpktReader,
                timeoutSeconds: timeoutSeconds
            )
            autoDetectResponse = autoDetectResult.lastResponse
            serverActivationResponseData = autoDetectResult.activationResponseData
        } catch {
            return MCSConnectionSequence(
                connectInitial: connectInitial,
                connectResponseData: connectResponseData,
                connectResponse: connectResponse,
                erectDomainRequest: erectDomainRequest,
                attachUserRequest: attachUserRequest,
                attachUserConfirmData: attachUserConfirmData,
                attachUserConfirm: attachUserConfirm,
                expectedJoinCount: joinTargets.count,
                joinedChannels: joinedChannels,
                clientInfoRequestByteCount: clientInfoRequest.count,
                clientInfoCredentialsIncluded: clientInfo.credentialsIncluded,
                clientInfoResponseData: clientInfoResponseData,
                clientInfoError: nil,
                autoDetectRequest: autoDetectRequest,
                autoDetectResponseData: autoDetectResponse,
                postAutoDetectResponseData: nil,
                autoDetectError: String(describing: error)
            )
        }
        postAutoDetectResponseData = serverActivationResponseData
    } else {
        autoDetectResponse = nil
        serverActivationResponseData = clientInfoResponseData
        postAutoDetectResponseData = nil
    }

    do {
        let licenseResponse: RDPServerLicensePDU?
        do {
            licenseResponse = try RDPServerLicensePDU.parseIfPresent(fromTPKT: serverActivationResponseData)
        } catch {
            return MCSConnectionSequence(
                connectInitial: connectInitial,
                connectResponseData: connectResponseData,
                connectResponse: connectResponse,
                erectDomainRequest: erectDomainRequest,
                attachUserRequest: attachUserRequest,
                attachUserConfirmData: attachUserConfirmData,
                attachUserConfirm: attachUserConfirm,
                expectedJoinCount: joinTargets.count,
                joinedChannels: joinedChannels,
                clientInfoRequestByteCount: clientInfoRequest.count,
                clientInfoCredentialsIncluded: clientInfo.credentialsIncluded,
                clientInfoResponseData: clientInfoResponseData,
                clientInfoError: nil,
                autoDetectRequest: autoDetectRequest,
                autoDetectResponseData: autoDetectResponse,
                postAutoDetectResponseData: postAutoDetectResponseData,
                autoDetectError: nil,
                licensingError: String(describing: error)
            )
        }
        let postAutoDetectShareControl = licenseResponse == nil
            ? try RDPShareControlPDU.parseIfPresent(fromTPKT: serverActivationResponseData)
            : nil

        if licenseResponse?.typeName == "license-error-valid-client" {
            let postLicensingResponseData: Data
            do {
                postLicensingResponseData = try receiveApplicationTPKT(
                    on: channel,
                    reader: tpktReader,
                    timeoutSeconds: timeoutSeconds,
                    timeoutDescription: "RDP Post Licensing Response"
                )
            } catch {
                return MCSConnectionSequence(
                    connectInitial: connectInitial,
                    connectResponseData: connectResponseData,
                    connectResponse: connectResponse,
                    erectDomainRequest: erectDomainRequest,
                    attachUserRequest: attachUserRequest,
                    attachUserConfirmData: attachUserConfirmData,
                    attachUserConfirm: attachUserConfirm,
                    expectedJoinCount: joinTargets.count,
                    joinedChannels: joinedChannels,
                    clientInfoRequestByteCount: clientInfoRequest.count,
                    clientInfoCredentialsIncluded: clientInfo.credentialsIncluded,
                    clientInfoResponseData: clientInfoResponseData,
                    clientInfoError: nil,
                    autoDetectRequest: autoDetectRequest,
                    autoDetectResponseData: autoDetectResponse,
                    postAutoDetectResponseData: postAutoDetectResponseData,
                    postAutoDetectShareControl: postAutoDetectShareControl,
                    autoDetectError: nil,
                    licenseResponse: licenseResponse,
                    postLicensingResponseData: nil,
                    postLicensingShareControl: nil,
                    licensingError: String(describing: error)
                )
            }

            do {
                let postLicensingShareControl = try RDPShareControlPDU.parseIfPresent(
                    fromTPKT: postLicensingResponseData
                )
                let demandActive: RDPDemandActivePDU?
                do {
                    demandActive = try RDPDemandActivePDU.parseIfPresent(fromTPKT: postLicensingResponseData)
                } catch {
                    return MCSConnectionSequence(
                        connectInitial: connectInitial,
                        connectResponseData: connectResponseData,
                        connectResponse: connectResponse,
                        erectDomainRequest: erectDomainRequest,
                        attachUserRequest: attachUserRequest,
                        attachUserConfirmData: attachUserConfirmData,
                        attachUserConfirm: attachUserConfirm,
                        expectedJoinCount: joinTargets.count,
                        joinedChannels: joinedChannels,
                        clientInfoRequestByteCount: clientInfoRequest.count,
                        clientInfoCredentialsIncluded: clientInfo.credentialsIncluded,
                        clientInfoResponseData: clientInfoResponseData,
                        clientInfoError: nil,
                        autoDetectRequest: autoDetectRequest,
                        autoDetectResponseData: autoDetectResponse,
                        postAutoDetectResponseData: postAutoDetectResponseData,
                        postAutoDetectShareControl: postAutoDetectShareControl,
                        autoDetectError: nil,
                        licenseResponse: licenseResponse,
                        postLicensingResponseData: postLicensingResponseData,
                        postLicensingShareControl: postLicensingShareControl,
                        licensingError: nil,
                        activationError: String(describing: error)
                    )
                }

                if let demandActive {
                    let confirmActive = RDPClientConfirmActivePDU(
                        shareID: demandActive.shareID,
                        desktopWidth: configuration.desktopWidth,
                        desktopHeight: configuration.desktopHeight
                    )
                    let confirmActiveRequest = confirmActive.encodedTPKT(
                        userChannelID: userChannelID,
                        ioChannelID: ioChannelID
                    )

                    let postConfirmActiveResponseData: Data
                    do {
                        postConfirmActiveResponseData = try sendApplicationPacketAndReceiveTPKT(
                            confirmActiveRequest,
                            on: channel,
                            reader: tpktReader,
                            timeoutSeconds: timeoutSeconds,
                            timeoutDescription: "RDP Post Confirm Active Response"
                        )
                    } catch {
                        return MCSConnectionSequence(
                            connectInitial: connectInitial,
                            connectResponseData: connectResponseData,
                            connectResponse: connectResponse,
                            erectDomainRequest: erectDomainRequest,
                            attachUserRequest: attachUserRequest,
                            attachUserConfirmData: attachUserConfirmData,
                            attachUserConfirm: attachUserConfirm,
                            expectedJoinCount: joinTargets.count,
                            joinedChannels: joinedChannels,
                            clientInfoRequestByteCount: clientInfoRequest.count,
                            clientInfoCredentialsIncluded: clientInfo.credentialsIncluded,
                            clientInfoResponseData: clientInfoResponseData,
                            clientInfoError: nil,
                            autoDetectRequest: autoDetectRequest,
                            autoDetectResponseData: autoDetectResponse,
                            postAutoDetectResponseData: postAutoDetectResponseData,
                            postAutoDetectShareControl: postAutoDetectShareControl,
                            autoDetectError: nil,
                            licenseResponse: licenseResponse,
                            postLicensingResponseData: postLicensingResponseData,
                            postLicensingShareControl: postLicensingShareControl,
                            licensingError: nil,
                            demandActive: demandActive,
                            confirmActiveRequestData: confirmActiveRequest,
                            confirmActiveCapabilitySets: confirmActive.capabilitySets,
                            postConfirmActiveResponseData: nil,
                            postConfirmActiveShareControl: nil,
                            postConfirmActiveShareData: nil,
                            activationError: String(describing: error)
                        )
                    }

                    do {
                        let postConfirmActiveShareControl = try RDPShareControlPDU.parseIfPresent(
                            fromTPKT: postConfirmActiveResponseData
                        )
                        let postConfirmActiveShareData = try RDPShareDataPDU.parseIfPresent(
                            fromTPKT: postConfirmActiveResponseData
                        )
                        let finalizationResult = postConfirmActiveShareData?.typeName == "server-synchronize"
                            ? performRDPConnectionFinalization(
                                shareID: demandActive.shareID,
                                userChannelID: userChannelID,
                                ioChannelID: ioChannelID,
                                on: channel,
                                reader: tpktReader,
                                timeoutSeconds: timeoutSeconds
                            )
                            : nil
                        let connectionFinalized = finalizationResult?.completed == true
                        if connectionFinalized {
                            onInputReady?(
                                RDPInputSession(
                                    shareID: demandActive.shareID,
                                    userChannelID: userChannelID,
                                    ioChannelID: ioChannelID,
                                    channel: channel
                                )
                            )
                        }
                        let clipboardChannelID = connectResponse.staticChannelAssignments.first(
                            where: { $0.name == RDPStaticVirtualChannel.cliprdr.name }
                        )?.channelID
                        var clipboardSentMessageData: [Data] = []
                        var clipboardSentMessages: [RDPClipboardMessageSummary] = []
                        let clipboardSession = clipboardChannelID.map {
                            RDPClipboardSession(
                                userChannelID: userChannelID,
                                staticChannelID: $0,
                                channel: channel,
                                sentMessageHandler: { summary, packet in
                                    clipboardSentMessages.append(summary)
                                    clipboardSentMessageData.append(packet)
                                }
                            )
                        }
                        let audioChannelID = connectResponse.staticChannelAssignments.first(
                            where: { $0.name == RDPStaticVirtualChannel.rdpsnd.name }
                        )?.channelID
                        let audioSession = audioChannelID.map {
                            RDPAudioSession(
                                userChannelID: userChannelID,
                                staticChannelID: $0,
                                channel: channel
                            )
                        }
                        let deviceRedirectionChannelID = connectResponse.staticChannelAssignments.first(
                            where: { $0.name == RDPStaticVirtualChannel.rdpdr.name }
                        )?.channelID
                        let deviceRedirectionSession = deviceRedirectionChannelID.map {
                            RDPDeviceRedirectionSession(
                                userChannelID: userChannelID,
                                staticChannelID: $0,
                                channel: channel,
                                computerName: configuration.clientName
                            )
                        }
                        var clipboardMessageData: [Data] = []
                        var clipboardMessages: [RDPClipboardMessageSummary] = []
                        var audioMessageData: [Data] = []
                        var audioMessages: [RDPAudioMessageSummary] = []
                        if let clipboardSession,
                           let finalizationResponseData = finalizationResult?.responseData
                        {
                            for packet in finalizationResponseData {
                                _ = try handleClipboardPacket(
                                    packet,
                                    session: clipboardSession,
                                    onClipboardReady: onClipboardReady,
                                    onClipboardText: onClipboardText,
                                    onClipboardFileGroupDescriptor: onClipboardFileGroupDescriptor,
                                    onClipboardFileContents: onClipboardFileContents,
                                    messageData: &clipboardMessageData,
                                    messages: &clipboardMessages
                                )
                            }
                        }
                        if let audioSession,
                           let finalizationResponseData = finalizationResult?.responseData
                        {
                            for packet in finalizationResponseData {
                                _ = try handleAudioPacket(
                                    packet,
                                    session: audioSession,
                                    onAudioSample: onAudioSample,
                                    messageData: &audioMessageData,
                                    messages: &audioMessages
                                )
                            }
                        }
                        if let deviceRedirectionSession,
                           let finalizationResponseData = finalizationResult?.responseData
                        {
                            for packet in finalizationResponseData {
                                _ = try handleDeviceRedirectionPacket(
                                    packet,
                                    session: deviceRedirectionSession
                                )
                            }
                        }
                        let graphicsResult: RDPGraphicsDynamicChannelResult?
                        if connectionFinalized,
                           let dynamicChannelID = connectResponse.staticChannelAssignments.first(
                               where: { $0.name == RDPStaticVirtualChannel.drdynvc.name }
                           )?.channelID
                        {
                            graphicsResult = performRDPGraphicsDynamicChannelHandshake(
                                userChannelID: userChannelID,
                                staticChannelID: dynamicChannelID,
                                on: channel,
                                reader: tpktReader,
                                timeoutSeconds: timeoutSeconds,
                                frameCaptureLimit: graphicsFrameCaptureLimit,
                                graphicsCapabilityProfile: graphicsCapabilityProfile,
                                onGraphicsFrame: onGraphicsFrame,
                                onDisplayControlReady: onDisplayControlReady,
                                clipboardSession: clipboardSession,
                                audioSession: audioSession,
                                onClipboardReady: onClipboardReady,
                                onClipboardText: onClipboardText,
                                onClipboardFileGroupDescriptor: onClipboardFileGroupDescriptor,
                                onClipboardFileContents: onClipboardFileContents,
                                onAudioSample: onAudioSample,
                                deviceRedirectionSession: deviceRedirectionSession,
                                cancellation: cancellation,
                                shouldCancel: shouldCancel
                            )
                        } else {
                            graphicsResult = nil
                        }

                        return MCSConnectionSequence(
                            connectInitial: connectInitial,
                            connectResponseData: connectResponseData,
                            connectResponse: connectResponse,
                            erectDomainRequest: erectDomainRequest,
                            attachUserRequest: attachUserRequest,
                            attachUserConfirmData: attachUserConfirmData,
                            attachUserConfirm: attachUserConfirm,
                            expectedJoinCount: joinTargets.count,
                            joinedChannels: joinedChannels,
                            clientInfoRequestByteCount: clientInfoRequest.count,
                            clientInfoCredentialsIncluded: clientInfo.credentialsIncluded,
                            clientInfoResponseData: clientInfoResponseData,
                            clientInfoError: nil,
                            autoDetectRequest: autoDetectRequest,
                            autoDetectResponseData: autoDetectResponse,
                            postAutoDetectResponseData: postAutoDetectResponseData,
                            postAutoDetectShareControl: postAutoDetectShareControl,
                            autoDetectError: nil,
                            licenseResponse: licenseResponse,
                            postLicensingResponseData: postLicensingResponseData,
                            postLicensingShareControl: postLicensingShareControl,
                            licensingError: nil,
                            demandActive: demandActive,
                            confirmActiveRequestData: confirmActiveRequest,
                            confirmActiveCapabilitySets: confirmActive.capabilitySets,
                            postConfirmActiveResponseData: postConfirmActiveResponseData,
                            postConfirmActiveShareControl: postConfirmActiveShareControl,
                            postConfirmActiveShareData: postConfirmActiveShareData,
                            activationError: nil,
                            clientSynchronizeRequestData: finalizationResult?.clientSynchronizeRequestData,
                            clientControlCooperateRequestData: finalizationResult?.clientControlCooperateRequestData,
                            clientControlRequestData: finalizationResult?.clientControlRequestData,
                            clientFontListRequestData: finalizationResult?.clientFontListRequestData,
                            finalizationResponseData: finalizationResult?.responseData ?? [],
                            finalizationResponses: finalizationResult?.responses ?? [],
                            finalizationError: finalizationResult?.error,
                            dynamicChannelRequestData: graphicsResult?.dynamicChannelRequestData ?? [],
                            dynamicChannelRequestTypes: graphicsResult?.dynamicChannelRequestTypes ?? [],
                            dynamicChannelCapabilitiesRequest: graphicsResult?.dynamicChannelCapabilitiesRequest,
                            dynamicChannelCapabilitiesResponseData: graphicsResult?.dynamicChannelCapabilitiesResponseData,
                            graphicsChannelCreateRequest: graphicsResult?.graphicsChannelCreateRequest,
                            graphicsChannelCreateResponseData: graphicsResult?.graphicsChannelCreateResponseData,
                            graphicsCapsAdvertiseData: graphicsResult?.graphicsCapsAdvertiseData,
                            serverRedirectionData: graphicsResult?.serverRedirectionData,
                            serverRedirection: graphicsResult?.serverRedirection,
                            graphicsResponseData: graphicsResult?.graphicsResponseData,
                            graphicsResponse: graphicsResult?.graphicsResponse,
                            graphicsCapsConfirm: graphicsResult?.graphicsCapsConfirm,
                            graphicsUpdateResponseCount: graphicsResult?.graphicsUpdateResponseCount ?? 0,
                            graphicsUpdateResponseData: graphicsResult?.graphicsUpdateResponseData ?? [],
                            graphicsUpdateMessages: graphicsResult?.graphicsUpdateMessages ?? [],
                            graphicsFailureUpdateResponseData: graphicsResult?.graphicsFailureUpdateResponseData,
                            graphicsFailureUpdatePayloadData: graphicsResult?.graphicsFailureUpdatePayloadData,
                            graphicsFailureUpdateMessages: graphicsResult?.graphicsFailureUpdateMessages ?? [],
                            graphicsFailureUpdateMessageIndex: graphicsResult?.graphicsFailureUpdateMessageIndex,
                            graphicsFrameAcknowledgeData: graphicsResult?.graphicsFrameAcknowledgeData ?? [],
                            graphicsFrames: graphicsResult?.graphicsFrames ?? [],
                            firstGraphicsFrame: graphicsResult?.firstGraphicsFrame,
                            graphicsError: graphicsResult?.error,
                            displayControlChannelCreateRequest: graphicsResult?.displayControlChannelCreateRequest,
                            displayControlChannelCreateResponseData: graphicsResult?.displayControlChannelCreateResponseData,
                            displayControlCapsData: graphicsResult?.displayControlCapsData,
                            displayControlCaps: graphicsResult?.displayControlCaps,
                            clipboardChannelID: clipboardChannelID,
                            clipboardMessageData: clipboardMessageData + (graphicsResult?.clipboardMessageData ?? []),
                            clipboardMessages: clipboardMessages + (graphicsResult?.clipboardMessages ?? []),
                            clipboardSentMessageData: clipboardSentMessageData,
                            clipboardSentMessages: clipboardSentMessages,
                            audioChannelID: audioChannelID,
                            audioMessageData: audioMessageData + (graphicsResult?.audioMessageData ?? []),
                            audioMessages: audioMessages + (graphicsResult?.audioMessages ?? [])
                        )
                    } catch {
                        return MCSConnectionSequence(
                            connectInitial: connectInitial,
                            connectResponseData: connectResponseData,
                            connectResponse: connectResponse,
                            erectDomainRequest: erectDomainRequest,
                            attachUserRequest: attachUserRequest,
                            attachUserConfirmData: attachUserConfirmData,
                            attachUserConfirm: attachUserConfirm,
                            expectedJoinCount: joinTargets.count,
                            joinedChannels: joinedChannels,
                            clientInfoRequestByteCount: clientInfoRequest.count,
                            clientInfoCredentialsIncluded: clientInfo.credentialsIncluded,
                            clientInfoResponseData: clientInfoResponseData,
                            clientInfoError: nil,
                            autoDetectRequest: autoDetectRequest,
                            autoDetectResponseData: autoDetectResponse,
                            postAutoDetectResponseData: postAutoDetectResponseData,
                            postAutoDetectShareControl: postAutoDetectShareControl,
                            autoDetectError: nil,
                            licenseResponse: licenseResponse,
                            postLicensingResponseData: postLicensingResponseData,
                            postLicensingShareControl: postLicensingShareControl,
                            licensingError: nil,
                            demandActive: demandActive,
                            confirmActiveRequestData: confirmActiveRequest,
                            confirmActiveCapabilitySets: confirmActive.capabilitySets,
                            postConfirmActiveResponseData: postConfirmActiveResponseData,
                            postConfirmActiveShareControl: nil,
                            postConfirmActiveShareData: nil,
                            activationError: String(describing: error)
                        )
                    }
                }

                return MCSConnectionSequence(
                    connectInitial: connectInitial,
                    connectResponseData: connectResponseData,
                    connectResponse: connectResponse,
                    erectDomainRequest: erectDomainRequest,
                    attachUserRequest: attachUserRequest,
                    attachUserConfirmData: attachUserConfirmData,
                    attachUserConfirm: attachUserConfirm,
                    expectedJoinCount: joinTargets.count,
                    joinedChannels: joinedChannels,
                    clientInfoRequestByteCount: clientInfoRequest.count,
                    clientInfoCredentialsIncluded: clientInfo.credentialsIncluded,
                    clientInfoResponseData: clientInfoResponseData,
                    clientInfoError: nil,
                    autoDetectRequest: autoDetectRequest,
                    autoDetectResponseData: autoDetectResponse,
                    postAutoDetectResponseData: postAutoDetectResponseData,
                    postAutoDetectShareControl: postAutoDetectShareControl,
                    autoDetectError: nil,
                    licenseResponse: licenseResponse,
                    postLicensingResponseData: postLicensingResponseData,
                    postLicensingShareControl: postLicensingShareControl,
                    licensingError: nil,
                    demandActive: nil,
                    activationError: nil
                )
            } catch {
                return MCSConnectionSequence(
                    connectInitial: connectInitial,
                    connectResponseData: connectResponseData,
                    connectResponse: connectResponse,
                    erectDomainRequest: erectDomainRequest,
                    attachUserRequest: attachUserRequest,
                    attachUserConfirmData: attachUserConfirmData,
                    attachUserConfirm: attachUserConfirm,
                    expectedJoinCount: joinTargets.count,
                    joinedChannels: joinedChannels,
                    clientInfoRequestByteCount: clientInfoRequest.count,
                    clientInfoCredentialsIncluded: clientInfo.credentialsIncluded,
                    clientInfoResponseData: clientInfoResponseData,
                    clientInfoError: nil,
                    autoDetectRequest: autoDetectRequest,
                    autoDetectResponseData: autoDetectResponse,
                    postAutoDetectResponseData: postAutoDetectResponseData,
                    postAutoDetectShareControl: postAutoDetectShareControl,
                    autoDetectError: nil,
                    licenseResponse: licenseResponse,
                    postLicensingResponseData: postLicensingResponseData,
                    postLicensingShareControl: nil,
                    licensingError: String(describing: error)
                )
            }
        }

        return MCSConnectionSequence(
            connectInitial: connectInitial,
            connectResponseData: connectResponseData,
            connectResponse: connectResponse,
            erectDomainRequest: erectDomainRequest,
            attachUserRequest: attachUserRequest,
            attachUserConfirmData: attachUserConfirmData,
            attachUserConfirm: attachUserConfirm,
            expectedJoinCount: joinTargets.count,
            joinedChannels: joinedChannels,
            clientInfoRequestByteCount: clientInfoRequest.count,
            clientInfoCredentialsIncluded: clientInfo.credentialsIncluded,
            clientInfoResponseData: clientInfoResponseData,
            clientInfoError: nil,
            autoDetectRequest: autoDetectRequest,
            autoDetectResponseData: autoDetectResponse,
            postAutoDetectResponseData: postAutoDetectResponseData,
            postAutoDetectShareControl: postAutoDetectShareControl,
            autoDetectError: nil,
            licenseResponse: licenseResponse,
            licensingError: nil
        )
    } catch {
        return MCSConnectionSequence(
            connectInitial: connectInitial,
            connectResponseData: connectResponseData,
            connectResponse: connectResponse,
            erectDomainRequest: erectDomainRequest,
            attachUserRequest: attachUserRequest,
            attachUserConfirmData: attachUserConfirmData,
            attachUserConfirm: attachUserConfirm,
            expectedJoinCount: joinTargets.count,
            joinedChannels: joinedChannels,
            clientInfoRequestByteCount: clientInfoRequest.count,
            clientInfoCredentialsIncluded: clientInfo.credentialsIncluded,
            clientInfoResponseData: clientInfoResponseData,
            clientInfoError: nil,
            autoDetectRequest: autoDetectRequest,
            autoDetectResponseData: autoDetectResponse,
            postAutoDetectResponseData: nil,
            autoDetectError: String(describing: error)
        )
    }
}

private struct RDPAutoDetectExchangeResult {
    var lastResponse: Data
    var activationResponseData: Data
}

private func performRDPAutoDetectExchange(
    initialRequest: RDPServerAutoDetectRequest,
    userChannelID: UInt16,
    fallbackMessageChannelID: UInt16?,
    on channel: Channel,
    reader: TLSTPKTStreamHandler,
    timeoutSeconds: Int
) throws -> RDPAutoDetectExchangeResult {
    var request = initialRequest

    while true {
        let responseChannelID = request.channelID != 0
            ? request.channelID
            : fallbackMessageChannelID ?? 0
        guard responseChannelID != 0 else {
            throw RDPPreflightError.receive(
                "server sent RDP Auto-Detect request without an assigned message channel"
            )
        }

        let response = request.response.encodedTPKT(
            userChannelID: userChannelID,
            messageChannelID: responseChannelID
        )
        let nextPacket = try sendApplicationPacketAndReceiveTPKT(
            response,
            on: channel,
            reader: reader,
            timeoutSeconds: timeoutSeconds,
            timeoutDescription: "RDP Post Auto-Detect Response"
        )

        guard let nextRequest = try RDPServerAutoDetectRequest.parseIfPresent(fromTPKT: nextPacket) else {
            return RDPAutoDetectExchangeResult(
                lastResponse: response,
                activationResponseData: nextPacket
            )
        }
        request = nextRequest
    }
}

private func channelJoinTargets(
    userChannelID: UInt16,
    connectResponse: MCSConnectResponse
) -> [MCSChannelJoinTarget] {
    var targets = [MCSChannelJoinTarget(name: "user", channelID: userChannelID)]
    if let ioChannelID = connectResponse.ioChannelID {
        targets.append(MCSChannelJoinTarget(name: "io", channelID: ioChannelID))
    }
    targets.append(contentsOf: connectResponse.staticChannelAssignments.map {
        MCSChannelJoinTarget(name: $0.name, channelID: $0.channelID)
    })
    if let messageChannelID = connectResponse.messageChannelID, messageChannelID != 0 {
        targets.append(MCSChannelJoinTarget(name: "message", channelID: messageChannelID))
    }
    return targets
}

private func performRDPConnectionFinalization(
    shareID: UInt32,
    userChannelID: UInt16,
    ioChannelID: UInt16,
    on channel: Channel,
    reader: TLSTPKTStreamHandler,
    timeoutSeconds: Int
) -> RDPConnectionFinalizationResult {
    let clientSynchronizeRequest = RDPClientSynchronizePDU(shareID: shareID)
        .encodedTPKT(userChannelID: userChannelID, ioChannelID: ioChannelID)
    let clientControlCooperateRequest = RDPClientControlPDU.cooperate(shareID: shareID)
        .encodedTPKT(userChannelID: userChannelID, ioChannelID: ioChannelID)
    let clientControlRequest = RDPClientControlPDU.requestControl(shareID: shareID)
        .encodedTPKT(userChannelID: userChannelID, ioChannelID: ioChannelID)
    let clientFontListRequest = RDPClientFontListPDU(shareID: shareID)
        .encodedTPKT(userChannelID: userChannelID, ioChannelID: ioChannelID)

    var result = RDPConnectionFinalizationResult(
        clientSynchronizeRequestData: clientSynchronizeRequest,
        clientControlCooperateRequestData: clientControlCooperateRequest,
        clientControlRequestData: clientControlRequest,
        clientFontListRequestData: clientFontListRequest,
        responseData: [],
        responses: [],
        error: nil
    )

    do {
        try sendApplicationPacket(clientSynchronizeRequest, on: channel)
        try sendApplicationPacket(clientControlCooperateRequest, on: channel)
        try sendApplicationPacket(clientControlRequest, on: channel)
    } catch {
        result.error = String(describing: error)
        return result
    }

    do {
        var sentFontList = false
        for _ in 0 ..< 8 {
            let packet = try receiveApplicationTPKT(
                on: channel,
                reader: reader,
                timeoutSeconds: timeoutSeconds,
                timeoutDescription: "RDP Connection Finalization Response"
            )
            result.responseData.append(packet)

            if let response = try RDPShareDataPDU.parseIfPresent(fromTPKT: packet) {
                result.responses.append(response)
                if response.typeName == "control-granted-control", sentFontList == false {
                    try sendApplicationPacket(clientFontListRequest, on: channel)
                    sentFontList = true
                }
                if response.typeName == "font-map" {
                    break
                }
            }
        }
    } catch {
        if result.completed {
            return result
        }
        result.error = String(describing: error)
        return result
    }

    if !result.completed {
        result.error = "server did not grant control during connection finalization"
    }
    return result
}

private func performRDPGraphicsDynamicChannelHandshake(
    userChannelID: UInt16,
    staticChannelID: UInt16,
    on channel: Channel,
    reader: TLSTPKTStreamHandler,
    timeoutSeconds: Int,
    frameCaptureLimit: Int?,
    graphicsCapabilityProfile: RDPGraphicsCapabilityProfile,
    onGraphicsFrame: RDPGraphicsFrameHandler?,
    onDisplayControlReady: RDPDisplayControlSessionHandler?,
    clipboardSession: RDPClipboardSession?,
    audioSession: RDPAudioSession?,
    onClipboardReady: RDPClipboardSessionHandler?,
    onClipboardText: RDPClipboardTextHandler?,
    onClipboardFileGroupDescriptor: RDPClipboardFileGroupDescriptorHandler?,
    onClipboardFileContents: RDPClipboardFileContentsHandler?,
    onAudioSample: RDPAudioSampleHandler?,
    deviceRedirectionSession: RDPDeviceRedirectionSession?,
    cancellation: RDPConnectionCancellation?,
    shouldCancel: RDPCancellationHandler?
) -> RDPGraphicsDynamicChannelResult {
    var result = RDPGraphicsDynamicChannelResult()
    let graphicsTransport = RDPGFXServerTransportDecoder()
    var dynamicAudioSession: RDPAudioSession?

    do {
        for _ in 0 ..< 16 {
            let packet = try receiveApplicationTPKT(
                on: channel,
                reader: reader,
                timeoutSeconds: timeoutSeconds,
                timeoutDescription: "RDP Graphics Dynamic Channel Request"
            )

            guard let staticPDU = try RDPStaticVirtualChannelPDU.parseIfPresent(
                fromTPKT: packet,
                channelID: staticChannelID
            ) else {
                if let redirection = try RDPServerRedirectionPDU.parseIfPresent(fromTPKT: packet) {
                    result.serverRedirectionData = packet
                    result.serverRedirection = redirection
                    result.error = "server requested RDP redirection"
                    return result
                }
                if let clipboardSession,
                   try handleClipboardPacket(
                       packet,
                       session: clipboardSession,
                       onClipboardReady: onClipboardReady,
                       onClipboardText: onClipboardText,
                       onClipboardFileGroupDescriptor: onClipboardFileGroupDescriptor,
                       onClipboardFileContents: onClipboardFileContents,
                       messageData: &result.clipboardMessageData,
                       messages: &result.clipboardMessages
                   )
                {
                    continue
                }
                if let audioSession,
                   try handleAudioPacket(
                       packet,
                       session: audioSession,
                       onAudioSample: onAudioSample,
                       messageData: &result.audioMessageData,
                       messages: &result.audioMessages
                   )
                {
                    continue
                }
                if let deviceRedirectionSession,
                   try handleDeviceRedirectionPacket(
                       packet,
                       session: deviceRedirectionSession
                   )
                {
                    continue
                }
                continue
            }
            result.dynamicChannelRequestData.append(packet)

            guard staticPDU.isComplete else {
                result.error = "fragmented static virtual channel PDUs are not implemented"
                return result
            }

            if let capabilitiesRequest = try RDPDynamicVirtualChannelCapabilitiesRequest.parseIfPresent(
                from: staticPDU.payload
            ) {
                result.dynamicChannelRequestTypes.append(capabilitiesRequest.typeName)
                result.dynamicChannelCapabilitiesRequest = capabilitiesRequest

                let responseVersion = max(UInt16(1), min(capabilitiesRequest.version, UInt16(2)))
                let responsePayload = RDPDynamicVirtualChannelCapabilitiesResponse(
                    version: responseVersion
                ).encoded()
                let responsePacket = RDPStaticVirtualChannelPDU(
                    payload: responsePayload,
                    flags: RDPStaticVirtualChannelFlags.completeWithShowProtocol
                )
                    .encodedTPKT(initiator: userChannelID, channelID: staticChannelID)
                result.dynamicChannelCapabilitiesResponseData = responsePacket
                try sendApplicationPacket(responsePacket, on: channel)

                if result.graphicsChannelCreateRequest == nil {
                    let createRequest = RDPDynamicVirtualChannelCreateRequest(
                        channelID: 1,
                        channelName: RDPGFXChannel.name
                    )
                    result.graphicsChannelCreateRequest = createRequest
                    let createPacket = RDPStaticVirtualChannelPDU(
                        payload: createRequest.encoded(),
                        flags: RDPStaticVirtualChannelFlags.completeWithShowProtocol
                    ).encodedTPKT(initiator: userChannelID, channelID: staticChannelID)
                    try sendApplicationPacket(createPacket, on: channel)

                    let graphicsPacket = graphicsCapsAdvertisePacket(
                        dynamicChannelID: createRequest.channelID,
                        userChannelID: userChannelID,
                        staticChannelID: staticChannelID,
                        graphicsCapabilityProfile: graphicsCapabilityProfile
                    )
                    result.graphicsCapsAdvertiseData = graphicsPacket
                    try sendApplicationPacket(graphicsPacket, on: channel)
                }
                continue
            }

            if let createResponse = try RDPDynamicVirtualChannelCreateResponse.parseIfPresent(
                from: staticPDU.payload
            ) {
                result.dynamicChannelRequestTypes.append("dynvc-create-response")
                if createResponse.channelID == result.graphicsChannelCreateRequest?.channelID,
                   createResponse.creationStatus == 0
                {
                    let graphicsPacket = graphicsCapsAdvertisePacket(
                        dynamicChannelID: createResponse.channelID,
                        userChannelID: userChannelID,
                        staticChannelID: staticChannelID,
                        graphicsCapabilityProfile: graphicsCapabilityProfile
                    )
                    result.graphicsCapsAdvertiseData = graphicsPacket
                    try sendApplicationPacket(graphicsPacket, on: channel)
                }
                continue
            }

            if let createRequest = try RDPDynamicVirtualChannelCreateRequest.parseIfPresent(
                from: staticPDU.payload
            ) {
                result.dynamicChannelRequestTypes.append("\(createRequest.typeName):\(createRequest.channelName)")

                if createRequest.channelName == RDPGFXChannel.name {
                    result.graphicsChannelCreateRequest = createRequest
                    let responsePayload = RDPDynamicVirtualChannelCreateResponse(
                        channelID: createRequest.channelID
                    ).encoded()
                    let responsePacket = RDPStaticVirtualChannelPDU(
                        payload: responsePayload,
                        flags: RDPStaticVirtualChannelFlags.completeWithShowProtocol
                    )
                        .encodedTPKT(initiator: userChannelID, channelID: staticChannelID)
                    result.graphicsChannelCreateResponseData = responsePacket
                    try sendApplicationPacket(responsePacket, on: channel)

                    let graphicsPacket = graphicsCapsAdvertisePacket(
                        dynamicChannelID: createRequest.channelID,
                        userChannelID: userChannelID,
                        staticChannelID: staticChannelID,
                        graphicsCapabilityProfile: graphicsCapabilityProfile
                    )
                    result.graphicsCapsAdvertiseData = graphicsPacket
                    try sendApplicationPacket(graphicsPacket, on: channel)
                } else if try handleDisplayControlCreateRequest(
                    createRequest,
                    userChannelID: userChannelID,
                    staticChannelID: staticChannelID,
                    on: channel,
                    result: &result
                ) {
                    continue
                } else if let audioDVCSession = try acceptDynamicAudioCreateRequest(
                    createRequest,
                    userChannelID: userChannelID,
                    staticChannelID: staticChannelID,
                    on: channel
                ) {
                    dynamicAudioSession = audioDVCSession
                    continue
                } else {
                    let responsePayload = RDPDynamicVirtualChannelCreateResponse(
                        channelID: createRequest.channelID,
                        creationStatus: Int32(bitPattern: 0x8000_4001)
                    ).encoded()
                    let responsePacket = RDPStaticVirtualChannelPDU(
                        payload: responsePayload,
                        flags: RDPStaticVirtualChannelFlags.completeWithShowProtocol
                    )
                        .encodedTPKT(initiator: userChannelID, channelID: staticChannelID)
                    try sendApplicationPacket(responsePacket, on: channel)
                }
                continue
            }

            if let dataPDU = try RDPDynamicVirtualChannelDataPDU.parseIfPresent(from: staticPDU.payload) {
                if let dynamicAudioSession,
                   dynamicAudioSession.handlesDynamicChannel(dataPDU.channelID)
                {
                    result.dynamicChannelRequestTypes.append("\(dataPDU.typeName):audio")
                    try handleDynamicAudioPayload(
                        dataPDU.payload,
                        packet: packet,
                        session: dynamicAudioSession,
                        onAudioSample: onAudioSample,
                        messageData: &result.audioMessageData,
                        messages: &result.audioMessages
                    )
                    continue
                }
                if try handleDisplayControlDataPDU(
                    dataPDU,
                    packet: packet,
                    userChannelID: userChannelID,
                    staticChannelID: staticChannelID,
                    on: channel,
                    onDisplayControlReady: onDisplayControlReady,
                    result: &result
                ) {
                    result.dynamicChannelRequestTypes.append("\(dataPDU.typeName):display-control")
                    continue
                }

                result.dynamicChannelRequestTypes.append(dataPDU.typeName)
                guard dataPDU.channelID == result.graphicsChannelCreateRequest?.channelID else {
                    continue
                }

                result.graphicsResponseData = packet
                let graphicsMessages = try graphicsTransport.decodeGraphicsMessages(from: dataPDU.payload)
                guard let graphicsHeader = graphicsMessages.first else {
                    result.error = "server sent empty RDPGFX segmented data"
                    return result
                }
                result.graphicsResponse = graphicsHeader
                if graphicsHeader.commandID == RDPGFXCommandID.capsConfirm {
                    result.graphicsCapsConfirm = try RDPGFXCapsConfirmPDU(
                        capabilitySet: RDPGFXCapabilitySet.parse(from: graphicsHeader.payload)
                    )
                    try receiveRDPGraphicsUpdateBatch(
                        userChannelID: userChannelID,
                        staticChannelID: staticChannelID,
                        dynamicChannelID: dataPDU.channelID,
                        on: channel,
                        reader: reader,
                        timeoutSeconds: timeoutSeconds,
                        frameCaptureLimit: frameCaptureLimit,
                        onGraphicsFrame: onGraphicsFrame,
                        onDisplayControlReady: onDisplayControlReady,
                        clipboardSession: clipboardSession,
                        audioSession: audioSession,
                        onClipboardReady: onClipboardReady,
                        onClipboardText: onClipboardText,
                        onClipboardFileGroupDescriptor: onClipboardFileGroupDescriptor,
                        onClipboardFileContents: onClipboardFileContents,
                        onAudioSample: onAudioSample,
                        dynamicAudioSession: dynamicAudioSession,
                        deviceRedirectionSession: deviceRedirectionSession,
                        cancellation: cancellation,
                        shouldCancel: shouldCancel,
                        graphicsTransport: graphicsTransport,
                        result: &result
                    )
                    return result
                }
                continue
            }

            result.dynamicChannelRequestTypes.append("dynvc-unknown")
        }
    } catch {
        result.error = String(describing: error)
        return result
    }

    result.error = "server did not confirm RDPGFX capabilities"
    return result
}

private func graphicsCapsAdvertisePacket(
    dynamicChannelID: UInt32,
    userChannelID: UInt16,
    staticChannelID: UInt16,
    graphicsCapabilityProfile: RDPGraphicsCapabilityProfile
) -> Data {
    let graphicsPayload = RDPGFXCapsAdvertisePDU(
        capabilitySets: graphicsCapabilityProfile.capabilitySets
    ).encoded()
    let dynamicPayload = RDPDynamicVirtualChannelDataPDU(
        channelID: dynamicChannelID,
        payload: graphicsPayload
    ).encoded()
    return RDPStaticVirtualChannelPDU(
        payload: dynamicPayload,
        flags: RDPStaticVirtualChannelFlags.completeWithShowProtocol
    ).encodedTPKT(initiator: userChannelID, channelID: staticChannelID)
}

private func handleDisplayControlCreateRequest(
    _ createRequest: RDPDynamicVirtualChannelCreateRequest,
    userChannelID: UInt16,
    staticChannelID: UInt16,
    on channel: Channel,
    result: inout RDPGraphicsDynamicChannelResult
) throws -> Bool {
    guard createRequest.channelName == RDPDisplayControlChannel.name else {
        return false
    }

    result.displayControlChannelCreateRequest = createRequest
    let responsePayload = RDPDynamicVirtualChannelCreateResponse(
        channelID: createRequest.channelID
    ).encoded()
    let responsePacket = RDPStaticVirtualChannelPDU(
        payload: responsePayload,
        flags: RDPStaticVirtualChannelFlags.completeWithShowProtocol
    )
        .encodedTPKT(initiator: userChannelID, channelID: staticChannelID)
    result.displayControlChannelCreateResponseData = responsePacket
    try sendApplicationPacket(responsePacket, on: channel)
    return true
}

private func handleDisplayControlDataPDU(
    _ dataPDU: RDPDynamicVirtualChannelDataPDU,
    packet: Data,
    userChannelID: UInt16,
    staticChannelID: UInt16,
    on channel: Channel,
    onDisplayControlReady: RDPDisplayControlSessionHandler?,
    result: inout RDPGraphicsDynamicChannelResult
) throws -> Bool {
    guard dataPDU.channelID == result.displayControlChannelCreateRequest?.channelID else {
        return false
    }

    if let caps = try RDPDisplayControlCapsPDU.parseIfPresent(from: dataPDU.payload) {
        result.displayControlCapsData = packet
        result.displayControlCaps = caps.capabilities
        onDisplayControlReady?(
            RDPDisplayControlSession(
                dynamicChannelID: dataPDU.channelID,
                userChannelID: userChannelID,
                staticChannelID: staticChannelID,
                channel: channel
            )
        )
    }
    return true
}

private func handleClipboardPacket(
    _ packet: Data,
    session: RDPClipboardSession,
    onClipboardReady: RDPClipboardSessionHandler?,
    onClipboardText: RDPClipboardTextHandler?,
    onClipboardFileGroupDescriptor: RDPClipboardFileGroupDescriptorHandler?,
    onClipboardFileContents: RDPClipboardFileContentsHandler?,
    messageData: inout [Data],
    messages: inout [RDPClipboardMessageSummary]
) throws -> Bool {
    guard let staticPDU = try RDPStaticVirtualChannelPDU.parseIfPresent(
        fromTPKT: packet,
        channelID: session.staticChannelID
    ) else {
        return false
    }
    guard staticPDU.isComplete else {
        throw RDPDecodeError.invalidStaticVirtualChannelPDU
    }

    let clipboardPDU = try RDPClipboardPDU.parse(from: staticPDU.payload)
    messageData.append(packet)
    messages.append(.summarize(clipboardPDU))

    if let capabilities = try RDPClipboardCapabilitiesPDU.parseIfPresent(from: clipboardPDU) {
        session.updateServerCapabilities(capabilities)
        return true
    }

    if clipboardPDU.header.messageType == RDPClipboardMessageType.monitorReady {
        session.sendClientCapabilities()
        onClipboardReady?(session)
        return true
    }

    if let formatList = try RDPClipboardFormatListPDU.parseIfPresent(from: clipboardPDU) {
        session.sendFormatListResponse(ok: true)
        if let fileGroupDescriptorWFormatID = formatList.fileGroupDescriptorWFormatID {
            session.requestFileGroupDescriptorW(formatID: fileGroupDescriptorWFormatID)
        } else if formatList.formatIDs.contains(RDPClipboardFormatID.unicodeText) {
            session.requestUnicodeText()
        }
        return true
    }

    if let request = try RDPClipboardFormatDataRequestPDU.parseIfPresent(from: clipboardPDU) {
        session.respondToFormatDataRequest(request)
        return true
    }

    if let request = try RDPClipboardFileContentsRequestPDU.parseIfPresent(from: clipboardPDU) {
        session.respondToFileContentsRequest(request)
        return true
    }

    if let response = try RDPClipboardFileContentsResponsePDU.parseIfPresent(from: clipboardPDU) {
        onClipboardFileContents?(response.response)
        return true
    }

    if let response = try RDPClipboardFormatDataResponsePDU.parseIfPresent(from: clipboardPDU) {
        let pendingResponse = session.takePendingFormatDataResponse()
        if response.ok {
            switch pendingResponse ?? .unicodeText {
            case .unicodeText:
                try onClipboardText?(response.decodedUnicodeText())
            case .fileGroupDescriptorW:
                try onClipboardFileGroupDescriptor?(response.decodedFileGroupDescriptorW())
            }
        }
        return true
    }

    return true
}

private func handleAudioPacket(
    _ packet: Data,
    session: RDPAudioSession,
    onAudioSample: RDPAudioSampleHandler?,
    messageData: inout [Data],
    messages: inout [RDPAudioMessageSummary]
) throws -> Bool {
    guard let staticPDU = try RDPStaticVirtualChannelPDU.parseIfPresent(
        fromTPKT: packet,
        channelID: session.staticChannelID
    ) else {
        return false
    }
    guard staticPDU.isComplete else {
        throw RDPDecodeError.invalidStaticVirtualChannelPDU
    }

    try handleAudioPayload(
        staticPDU.payload,
        packet: packet,
        session: session,
        onAudioSample: onAudioSample,
        messageData: &messageData,
        messages: &messages
    )
    return true
}

private func handleDynamicAudioPayload(
    _ payload: Data,
    packet: Data,
    session: RDPAudioSession,
    onAudioSample: RDPAudioSampleHandler?,
    messageData: inout [Data],
    messages: inout [RDPAudioMessageSummary]
) throws {
    try handleAudioPayload(
        payload,
        packet: packet,
        session: session,
        onAudioSample: onAudioSample,
        messageData: &messageData,
        messages: &messages
    )
}

private func handleAudioPayload(
    _ payload: Data,
    packet: Data,
    session: RDPAudioSession,
    onAudioSample: RDPAudioSampleHandler?,
    messageData: inout [Data],
    messages: inout [RDPAudioMessageSummary]
) throws {
    if let sample = try session.receiveWaveData(payload, receivedAt: Date()) {
        messageData.append(packet)
        messages.append(
            RDPAudioMessageSummary(
                typeName: "audio-wave-data",
                bodySize: UInt16(clamping: payload.count)
            )
        )
        onAudioSample?(sample)
        session.confirmConsumed(sample)
        return
    }

    let receivedAt = Date()
    let audioPDU = try RDPAudioPDU.parse(from: payload)
    messageData.append(packet)
    messages.append(.summarize(audioPDU))

    if let formats = try RDPAudioFormatsPDU.parseIfPresent(from: audioPDU) {
        session.respondToServerFormats(formats)
        return
    }

    if let training = try RDPAudioTrainingPDU.parseIfPresent(from: audioPDU) {
        session.respondToTraining(training)
        return
    }

    if let sample = try session.receive(audioPDU, receivedAt: receivedAt) {
        onAudioSample?(sample)
        session.confirmConsumed(sample)
    }
}

private func handleDeviceRedirectionPacket(
    _ packet: Data,
    session: RDPDeviceRedirectionSession
) throws -> Bool {
    guard let staticPDU = try RDPStaticVirtualChannelPDU.parseIfPresent(
        fromTPKT: packet,
        channelID: session.staticChannelID
    ) else {
        return false
    }
    guard staticPDU.isComplete else {
        throw RDPDecodeError.invalidStaticVirtualChannelPDU
    }

    let deviceRedirectionPDU = try RDPDeviceRedirectionPDU.parse(from: staticPDU.payload)
    try session.receive(deviceRedirectionPDU)
    return true
}

private func acceptDynamicAudioCreateRequest(
    _ createRequest: RDPDynamicVirtualChannelCreateRequest,
    userChannelID: UInt16,
    staticChannelID: UInt16,
    on channel: Channel
) throws -> RDPAudioSession? {
    guard createRequest.channelName == RDPAudioDynamicChannel.name else {
        return nil
    }

    let responsePayload = RDPDynamicVirtualChannelCreateResponse(
        channelID: createRequest.channelID
    ).encoded()
    let responsePacket = RDPStaticVirtualChannelPDU(
        payload: responsePayload,
        flags: RDPStaticVirtualChannelFlags.completeWithShowProtocol
    )
        .encodedTPKT(initiator: userChannelID, channelID: staticChannelID)
    try sendApplicationPacket(responsePacket, on: channel)
    return RDPAudioSession(
        userChannelID: userChannelID,
        dynamicStaticChannelID: staticChannelID,
        dynamicChannelID: createRequest.channelID,
        channel: channel
    )
}

private func receiveRDPGraphicsUpdateBatch(
    userChannelID: UInt16,
    staticChannelID: UInt16,
    dynamicChannelID: UInt32,
    on channel: Channel,
    reader: TLSTPKTStreamHandler,
    timeoutSeconds: Int,
    frameCaptureLimit: Int?,
    onGraphicsFrame: RDPGraphicsFrameHandler?,
    onDisplayControlReady: RDPDisplayControlSessionHandler?,
    clipboardSession: RDPClipboardSession?,
    audioSession: RDPAudioSession?,
    onClipboardReady: RDPClipboardSessionHandler?,
    onClipboardText: RDPClipboardTextHandler?,
    onClipboardFileGroupDescriptor: RDPClipboardFileGroupDescriptorHandler?,
    onClipboardFileContents: RDPClipboardFileContentsHandler?,
    onAudioSample: RDPAudioSampleHandler?,
    dynamicAudioSession initialDynamicAudioSession: RDPAudioSession?,
    deviceRedirectionSession: RDPDeviceRedirectionSession?,
    cancellation: RDPConnectionCancellation?,
    shouldCancel: RDPCancellationHandler?,
    graphicsTransport: RDPGFXServerTransportDecoder,
    result: inout RDPGraphicsDynamicChannelResult
) throws {
    var totalFramesDecoded: UInt32 = 0
    var activeFrameID: UInt32?
    var activeFrameContainsVideoUpdate = false
    var fragment: RDPDynamicVirtualChannelFragment?
    var audioFragment: RDPDynamicVirtualChannelFragment?
    var dynamicAudioSession = initialDynamicAudioSession
    let clearCodec = RDPClearCodecDecoder()
    let surfaceCompositor = RDPGFXSurfaceCompositor()
    let targetFrameCount = frameCaptureLimit.map { max(1, $0) }
    let packetLimit = targetFrameCount.map { max(256, 256 * $0) }

    var packetsRead = 0
    while packetLimit.map({ packetsRead < $0 }) ?? true {
        try throwIfCancelled(shouldCancel, cancellation: cancellation)
        packetsRead += 1
        let packetTimeoutSeconds = targetFrameCount != nil || result.firstGraphicsFrame == nil
            ? timeoutSeconds
            : nil
        let packet: Data
        do {
            packet = try receiveApplicationTPKT(
                on: channel,
                reader: reader,
                timeoutSeconds: packetTimeoutSeconds,
                timeoutDescription: "RDP Graphics Update",
                cancellation: cancellation,
                shouldCancel: shouldCancel
            )
        } catch {
            if targetFrameCount != nil,
               result.graphicsFrames.isEmpty == false,
               fragment == nil,
               audioFragment == nil
            {
                return
            }
            throw error
        }

        guard let staticPDU = try RDPStaticVirtualChannelPDU.parseIfPresent(
            fromTPKT: packet,
            channelID: staticChannelID
        ) else {
            if let clipboardSession,
               try handleClipboardPacket(
                   packet,
                   session: clipboardSession,
                   onClipboardReady: onClipboardReady,
                   onClipboardText: onClipboardText,
                   onClipboardFileGroupDescriptor: onClipboardFileGroupDescriptor,
                   onClipboardFileContents: onClipboardFileContents,
                   messageData: &result.clipboardMessageData,
                   messages: &result.clipboardMessages
               )
            {
                continue
            }
            if let audioSession,
               try handleAudioPacket(
                   packet,
                   session: audioSession,
                   onAudioSample: onAudioSample,
                   messageData: &result.audioMessageData,
                   messages: &result.audioMessages
               )
            {
                continue
            }
            if let deviceRedirectionSession,
               try handleDeviceRedirectionPacket(
                   packet,
                   session: deviceRedirectionSession
               )
            {
                continue
            }
            continue
        }
        guard staticPDU.isComplete else {
            result.error = "fragmented static virtual channel PDUs are not implemented"
            return
        }

        if let createRequest = try RDPDynamicVirtualChannelCreateRequest.parseIfPresent(from: staticPDU.payload) {
            result.dynamicChannelRequestData.append(packet)
            result.dynamicChannelRequestTypes.append("\(createRequest.typeName):\(createRequest.channelName)")
            if try handleDisplayControlCreateRequest(
                createRequest,
                userChannelID: userChannelID,
                staticChannelID: staticChannelID,
                on: channel,
                result: &result
            ) {
                continue
            }
            if let audioDVCSession = try acceptDynamicAudioCreateRequest(
                createRequest,
                userChannelID: userChannelID,
                staticChannelID: staticChannelID,
                on: channel
            ) {
                dynamicAudioSession = audioDVCSession
                continue
            }
            let responsePayload = RDPDynamicVirtualChannelCreateResponse(
                channelID: createRequest.channelID,
                creationStatus: Int32(bitPattern: 0x8000_4001)
            ).encoded()
            let responsePacket = RDPStaticVirtualChannelPDU(
                payload: responsePayload,
                flags: RDPStaticVirtualChannelFlags.completeWithShowProtocol
            )
                .encodedTPKT(initiator: userChannelID, channelID: staticChannelID)
            try sendApplicationPacket(responsePacket, on: channel)
            continue
        }

        if let dataFirst = try RDPDynamicVirtualChannelDataFirstPDU.parseIfPresent(from: staticPDU.payload) {
            if let dynamicAudioSession,
               dynamicAudioSession.handlesDynamicChannel(dataFirst.channelID)
            {
                guard dataFirst.payload.count <= Int(dataFirst.totalLength) else {
                    throw RDPDecodeError.invalidDynamicVirtualChannelPDU
                }
                result.dynamicChannelRequestTypes.append("\(dataFirst.typeName):audio")
                if dataFirst.payload.count == Int(dataFirst.totalLength) {
                    try handleDynamicAudioPayload(
                        dataFirst.payload,
                        packet: packet,
                        session: dynamicAudioSession,
                        onAudioSample: onAudioSample,
                        messageData: &result.audioMessageData,
                        messages: &result.audioMessages
                    )
                } else {
                    audioFragment = RDPDynamicVirtualChannelFragment(
                        channelID: dataFirst.channelID,
                        totalLength: dataFirst.totalLength,
                        payload: dataFirst.payload
                    )
                }
                continue
            }
            guard dataFirst.channelID == dynamicChannelID else {
                continue
            }
            guard dataFirst.payload.count <= Int(dataFirst.totalLength) else {
                throw RDPDecodeError.invalidDynamicVirtualChannelPDU
            }

            recordRDPGraphicsUpdatePacket(packet, result: &result)
            if dataFirst.payload.count == Int(dataFirst.totalLength) {
                if try processRDPGraphicsUpdatePayload(
                    dataFirst.payload,
                    dynamicChannelID: dynamicChannelID,
                    staticChannelID: staticChannelID,
                    userChannelID: userChannelID,
                    on: channel,
                    result: &result,
                    totalFramesDecoded: &totalFramesDecoded,
                    activeFrameID: &activeFrameID,
                    activeFrameContainsVideoUpdate: &activeFrameContainsVideoUpdate,
                    targetFrameCount: targetFrameCount,
                    onGraphicsFrame: onGraphicsFrame,
                    graphicsTransport: graphicsTransport,
                    clearCodec: clearCodec,
                    surfaceCompositor: surfaceCompositor
                ) {
                    return
                }
            } else {
                fragment = RDPDynamicVirtualChannelFragment(
                    channelID: dataFirst.channelID,
                    totalLength: dataFirst.totalLength,
                    payload: dataFirst.payload
                )
            }
            continue
        }

        guard let dataPDU = try RDPDynamicVirtualChannelDataPDU.parseIfPresent(from: staticPDU.payload) else {
            continue
        }
        if let dynamicAudioSession,
           dynamicAudioSession.handlesDynamicChannel(dataPDU.channelID)
        {
            result.dynamicChannelRequestTypes.append("\(dataPDU.typeName):audio")
            if var activeAudioFragment = audioFragment {
                activeAudioFragment.payload.append(dataPDU.payload)
                guard activeAudioFragment.payload.count <= Int(activeAudioFragment.totalLength) else {
                    throw RDPDecodeError.invalidDynamicVirtualChannelPDU
                }

                if activeAudioFragment.payload.count == Int(activeAudioFragment.totalLength) {
                    audioFragment = nil
                    try handleDynamicAudioPayload(
                        activeAudioFragment.payload,
                        packet: packet,
                        session: dynamicAudioSession,
                        onAudioSample: onAudioSample,
                        messageData: &result.audioMessageData,
                        messages: &result.audioMessages
                    )
                } else {
                    audioFragment = activeAudioFragment
                }
            } else {
                try handleDynamicAudioPayload(
                    dataPDU.payload,
                    packet: packet,
                    session: dynamicAudioSession,
                    onAudioSample: onAudioSample,
                    messageData: &result.audioMessageData,
                    messages: &result.audioMessages
                )
            }
            continue
        }
        if try handleDisplayControlDataPDU(
            dataPDU,
            packet: packet,
            userChannelID: userChannelID,
            staticChannelID: staticChannelID,
            on: channel,
            onDisplayControlReady: onDisplayControlReady,
            result: &result
        ) {
            result.dynamicChannelRequestTypes.append("\(dataPDU.typeName):display-control")
            continue
        }
        guard dataPDU.channelID == dynamicChannelID else {
            continue
        }

        recordRDPGraphicsUpdatePacket(packet, result: &result)
        if var activeFragment = fragment {
            activeFragment.payload.append(dataPDU.payload)
            guard activeFragment.payload.count <= Int(activeFragment.totalLength) else {
                throw RDPDecodeError.invalidDynamicVirtualChannelPDU
            }

            if activeFragment.payload.count == Int(activeFragment.totalLength) {
                fragment = nil
                if try processRDPGraphicsUpdatePayload(
                    activeFragment.payload,
                    dynamicChannelID: dynamicChannelID,
                    staticChannelID: staticChannelID,
                    userChannelID: userChannelID,
                    on: channel,
                    result: &result,
                    totalFramesDecoded: &totalFramesDecoded,
                    activeFrameID: &activeFrameID,
                    activeFrameContainsVideoUpdate: &activeFrameContainsVideoUpdate,
                    targetFrameCount: targetFrameCount,
                    onGraphicsFrame: onGraphicsFrame,
                    graphicsTransport: graphicsTransport,
                    clearCodec: clearCodec,
                    surfaceCompositor: surfaceCompositor
                ) {
                    return
                }
            } else {
                fragment = activeFragment
            }
        } else if try processRDPGraphicsUpdatePayload(
            dataPDU.payload,
            dynamicChannelID: dynamicChannelID,
            staticChannelID: staticChannelID,
            userChannelID: userChannelID,
            on: channel,
            result: &result,
            totalFramesDecoded: &totalFramesDecoded,
            activeFrameID: &activeFrameID,
            activeFrameContainsVideoUpdate: &activeFrameContainsVideoUpdate,
            targetFrameCount: targetFrameCount,
            onGraphicsFrame: onGraphicsFrame,
            graphicsTransport: graphicsTransport,
            clearCodec: clearCodec,
            surfaceCompositor: surfaceCompositor
        ) {
            return
        }
    }

    if result.graphicsFrames.isEmpty == false,
       fragment == nil
    {
        return
    }

    result.error = fragment == nil
        ? "server did not send an RDPGFX end-frame update"
        : "server did not complete fragmented RDPGFX update data"
}

private func recordRDPGraphicsUpdatePacket(
    _ packet: Data,
    result: inout RDPGraphicsDynamicChannelResult
) {
    result.graphicsUpdateResponseCount += 1
    result.latestGraphicsUpdateResponseData = packet
    if result.graphicsUpdateResponseData.count < 8 {
        result.graphicsUpdateResponseData.append(packet)
    }
}

private func processRDPGraphicsUpdatePayload(
    _ payload: Data,
    dynamicChannelID: UInt32,
    staticChannelID: UInt16,
    userChannelID: UInt16,
    on channel: Channel,
    result: inout RDPGraphicsDynamicChannelResult,
    totalFramesDecoded: inout UInt32,
    activeFrameID: inout UInt32?,
    activeFrameContainsVideoUpdate: inout Bool,
    targetFrameCount: Int?,
    onGraphicsFrame: RDPGraphicsFrameHandler?,
    graphicsTransport: RDPGFXServerTransportDecoder,
    clearCodec: RDPClearCodecDecoder,
    surfaceCompositor: RDPGFXSurfaceCompositor
) throws -> Bool {
    let graphicsMessages: [RDPGFXHeader]
    do {
        graphicsMessages = try graphicsTransport.decodeGraphicsMessages(from: payload)
    } catch {
        recordRDPGraphicsFailure(
            payload: payload,
            messages: [],
            messageIndex: nil,
            result: &result
        )
        throw error
    }

    guard !graphicsMessages.isEmpty else {
        result.error = "server sent empty RDPGFX update data"
        return true
    }
    let maximumRecordedFrames = recordedGraphicsFrameLimit(targetFrameCount: targetFrameCount)
    let maximumRecordedMessages = recordedGraphicsMessageLimit(targetFrameCount: targetFrameCount)
    let maximumRecordedAcknowledgements = recordedGraphicsAcknowledgeLimit(targetFrameCount: targetFrameCount)
    let shouldIncludeVideoDetailsInSummaries = targetFrameCount != nil

    var messageIndex: Int?
    do {
        for (index, message) in graphicsMessages.enumerated() {
            messageIndex = index
            if result.graphicsUpdateMessages.count < maximumRecordedMessages {
                try result.graphicsUpdateMessages.append(
                    RDPGFXMessageSummary.summarize(
                        message,
                        includeVideoDetails: shouldIncludeVideoDetailsInSummaries
                    )
                )
            }

            if message.commandID == RDPGFXCommandID.startFrame {
                activeFrameID = try RDPGFXStartFramePDU.parse(from: message).frameID
            }

            try surfaceCompositor.process(message, clearCodec: clearCodec)

            if message.commandID == RDPGFXCommandID.wireToSurface1 {
                let wire = try RDPGFXWireToSurface1PDU.parse(from: message)
                if wire.codecID == RDPGFXCodecID.avc420,
                   let avc420 = try? RDPGFXAVC420BitmapStream.parse(from: wire.bitmapData)
                {
                    let frameID = activeFrameID
                    if result.graphicsFrames.contains(where: { $0.frameID == frameID }) == false {
                        let frame = RDPGraphicsFrameSnapshot(
                            frameID: frameID,
                            surfaceID: wire.surfaceID,
                            codecID: wire.codecID,
                            codecName: RDPGFXCodecID.name(for: wire.codecID),
                            videoCodec: .h264,
                            pixelFormat: wire.pixelFormat,
                            destinationRect: wire.destinationRect,
                            regionRects: avc420.regionRects,
                            encodedVideoData: avc420.encodedBitstream
                        )
                        appendGraphicsFrame(frame, to: &result, maximumRecordedFrames: maximumRecordedFrames)
                        result.pendingGraphicsFrames.append(frame)
                        activeFrameContainsVideoUpdate = true
                    }
                }

                if wire.codecID == RDPGFXCodecID.avc444 || wire.codecID == RDPGFXCodecID.avc444v2,
                   let avc444 = try? RDPGFXAVC444BitmapStream.parse(from: wire.bitmapData),
                   let yuv420Stream = avc444.yuv420Stream
                {
                    let frameID = activeFrameID
                    if result.graphicsFrames.contains(where: { $0.frameID == frameID }) == false {
                        let frame = RDPGraphicsFrameSnapshot(
                            frameID: frameID,
                            surfaceID: wire.surfaceID,
                            codecID: wire.codecID,
                            codecName: RDPGFXCodecID.name(for: wire.codecID),
                            videoCodec: .h264,
                            pixelFormat: wire.pixelFormat,
                            destinationRect: wire.destinationRect,
                            regionRects: yuv420Stream.regionRects,
                            encodedVideoData: yuv420Stream.encodedBitstream
                        )
                        appendGraphicsFrame(frame, to: &result, maximumRecordedFrames: maximumRecordedFrames)
                        result.pendingGraphicsFrames.append(frame)
                        activeFrameContainsVideoUpdate = true
                    }
                }

            }

            if message.commandID == RDPGFXCommandID.endFrame {
                let endFrame = try RDPGFXEndFramePDU.parse(from: message)
                if !activeFrameContainsVideoUpdate,
                   let frame = surfaceCompositor.makeFrame(frameID: endFrame.frameID),
                   result.graphicsFrames.contains(where: { $0.frameID == frame.frameID }) == false
                {
                    appendGraphicsFrame(frame, to: &result, maximumRecordedFrames: maximumRecordedFrames)
                    result.pendingGraphicsFrames.append(frame)
                }
                totalFramesDecoded += 1
                let acknowledgePayload = RDPGFXFrameAcknowledgePDU(
                    frameID: endFrame.frameID,
                    totalFramesDecoded: totalFramesDecoded
                ).encoded()
                let dynamicPayload = RDPDynamicVirtualChannelDataPDU(
                    channelID: dynamicChannelID,
                    payload: acknowledgePayload
                ).encoded()
                let acknowledgePacket = RDPStaticVirtualChannelPDU(
                    payload: dynamicPayload,
                    flags: RDPStaticVirtualChannelFlags.completeWithShowProtocol
                )
                    .encodedTPKT(initiator: userChannelID, channelID: staticChannelID)
                if result.graphicsFrameAcknowledgeData.count < maximumRecordedAcknowledgements {
                    result.graphicsFrameAcknowledgeData.append(acknowledgePacket)
                }
                try sendApplicationPacket(acknowledgePacket, on: channel)
                let framesToEmit = result.pendingGraphicsFrames
                result.pendingGraphicsFrames.removeAll()
                framesToEmit.forEach { onGraphicsFrame?($0) }
                activeFrameID = nil
                activeFrameContainsVideoUpdate = false
                guard let targetFrameCount else {
                    return false
                }
                return totalFramesDecoded >= UInt32(targetFrameCount)
            }
        }
    } catch {
        recordRDPGraphicsFailure(
            payload: payload,
            messages: graphicsMessages,
            messageIndex: messageIndex,
            result: &result
        )
        throw error
    }
    return false
}

private func recordRDPGraphicsFailure(
    payload: Data,
    messages: [RDPGFXHeader],
    messageIndex: Int?,
    result: inout RDPGraphicsDynamicChannelResult
) {
    guard result.graphicsFailureUpdatePayloadData == nil else {
        return
    }

    result.graphicsFailureUpdateResponseData = result.latestGraphicsUpdateResponseData
    result.graphicsFailureUpdatePayloadData = payload
    result.graphicsFailureUpdateMessages = messages.map { message in
        (try? RDPGFXMessageSummary.summarize(message, includeVideoDetails: false))
            ?? RDPGFXMessageSummary(typeName: message.typeName)
    }
    result.graphicsFailureUpdateMessageIndex = messageIndex
}

func recordedGraphicsFrameLimit(targetFrameCount: Int?) -> Int {
    targetFrameCount.map { max(1, $0) } ?? 1
}

func recordedGraphicsMessageLimit(targetFrameCount: Int?) -> Int {
    guard let targetFrameCount else {
        return 16
    }
    let frameCount = min(Int.max / 4, max(1, targetFrameCount))
    return max(16, frameCount * 4)
}

func recordedGraphicsAcknowledgeLimit(targetFrameCount: Int?) -> Int {
    targetFrameCount.map { max(1, $0) } ?? 8
}

private func appendGraphicsFrame(
    _ frame: RDPGraphicsFrameSnapshot,
    to result: inout RDPGraphicsDynamicChannelResult,
    maximumRecordedFrames: Int
) {
    if result.firstGraphicsFrame == nil {
        result.firstGraphicsFrame = frame
    }
    result.graphicsFrames.append(frame)
    if result.graphicsFrames.count > maximumRecordedFrames {
        result.graphicsFrames.removeFirst(result.graphicsFrames.count - maximumRecordedFrames)
    }
}

private func sendApplicationPacket(
    _ packet: Data,
    on channel: Channel
) throws {
    var buffer = channel.allocator.buffer(capacity: packet.count)
    buffer.writeBytes(packet)
    try channel.writeAndFlush(buffer).wait()
}

private func sendApplicationPacketAndReceiveTPKT(
    _ packet: Data,
    on channel: Channel,
    reader: TLSTPKTStreamHandler,
    timeoutSeconds: Int,
    timeoutDescription: String
) throws -> Data {
    let response = reader.nextPacket(on: channel)
    try sendApplicationPacket(packet, on: channel)

    return try waitForApplicationTPKT(
        response,
        on: channel,
        reader: reader,
        timeoutSeconds: timeoutSeconds,
        timeoutDescription: timeoutDescription
    )
}

private func receiveApplicationTPKT(
    on channel: Channel,
    reader: TLSTPKTStreamHandler,
    timeoutSeconds: Int?,
    timeoutDescription: String,
    cancellation: RDPConnectionCancellation? = nil,
    shouldCancel: RDPCancellationHandler? = nil
) throws -> Data {
    try throwIfCancelled(shouldCancel, cancellation: cancellation)
    return try waitForApplicationTPKT(
        reader.nextPacket(on: channel),
        on: channel,
        reader: reader,
        timeoutSeconds: timeoutSeconds,
        timeoutDescription: timeoutDescription,
        cancellation: cancellation,
        shouldCancel: shouldCancel
    )
}

private func waitForApplicationTPKT(
    _ response: EventLoopFuture<Data>,
    on channel: Channel,
    reader: TLSTPKTStreamHandler,
    timeoutSeconds: Int?,
    timeoutDescription: String,
    cancellation: RDPConnectionCancellation? = nil,
    shouldCancel: RDPCancellationHandler? = nil
) throws -> Data {
    let cancellationRegistration = cancellation?.register {
        channel.eventLoop.execute {
            reader.fail(RDPPreflightError.cancelled)
            channel.close(promise: nil)
        }
    }
    defer {
        cancellationRegistration?.cancel()
    }

    if shouldCancel?() == true {
        channel.eventLoop.execute {
            reader.fail(RDPPreflightError.cancelled)
            channel.close(promise: nil)
        }
        throw RDPPreflightError.cancelled
    }
    if cancellation?.isCancelled == true {
        throw RDPPreflightError.cancelled
    }

    guard let timeoutSeconds else {
        return try response.wait()
    }
    let timeoutTask = channel.eventLoop.scheduleTask(in: .seconds(Int64(timeoutSeconds))) {
        reader.fail(RDPPreflightError.receive("\(timeoutDescription) timed out after \(timeoutSeconds) seconds"))
        channel.close(promise: nil)
    }
    response.whenComplete { _ in
        timeoutTask.cancel()
    }

    return try response.wait()
}

private func inspectPeerCertificates(
    _ certificates: [NIOSSLCertificate],
    host: String,
    hideCertificateWarnings: Bool
) throws -> RDPServerCertificateInfo {
    guard !certificates.isEmpty else {
        throw RDPPreflightError.tls("server did not provide a TLS certificate")
    }

    let secCertificates = try certificates.map { certificate -> SecCertificate in
        let der = try Data(certificate.toDERBytes())
        guard let secCertificate = SecCertificateCreateWithData(nil, der as CFData) else {
            throw RDPPreflightError.tls("failed to parse server certificate")
        }
        return secCertificate
    }

    let policy = SecPolicyCreateSSL(true, host as CFString)
    var trust: SecTrust?
    let status = SecTrustCreateWithCertificates(secCertificates as CFArray, policy, &trust)
    guard status == errSecSuccess, let trust else {
        throw RDPPreflightError.tls("failed to create server certificate trust")
    }

    var trustError: CFError?
    let trusted = SecTrustEvaluateWithError(trust, &trustError)
    let sha256 = leafCertificateSHA256(from: certificates[0])

    guard !trusted else {
        return RDPServerCertificateInfo(trusted: true, sha256: sha256, warnings: [])
    }

    let detail = trustError.map { CFErrorCopyDescription($0) as String? } ?? nil
    let message: String
    if let detail {
        message = "Server certificate is not trusted by this system: \(detail)"
    } else {
        message = "Server certificate is not trusted by this system."
    }

    let warnings = hideCertificateWarnings ? [] : [
        RDPProbeWarning(code: "unrecognized-certificate", message: message),
    ]

    return RDPServerCertificateInfo(trusted: false, sha256: sha256, warnings: warnings)
}

private func leafCertificateSHA256(from certificate: NIOSSLCertificate) -> String? {
    guard let der = try? certificate.toDERBytes() else {
        return nil
    }

    let digest = SHA256.hash(data: Data(der))
    return digest.map { String(format: "%02x", $0) }.joined(separator: ":")
}

private func tlsVersionName(_ value: TLSVersion?) -> String {
    switch value {
    case .tlsv1:
        "tls1.0"
    case .tlsv11:
        "tls1.1"
    case .tlsv12:
        "tls1.2"
    case .tlsv13:
        "tls1.3"
    case nil:
        "unknown"
    }
}

private func sniHostname(for host: String) -> String? {
    var ipv4 = in_addr()
    var ipv6 = in6_addr()
    let isIPAddress = host.withCString { pointer in
        inet_pton(AF_INET, pointer, &ipv4) == 1 || inet_pton(AF_INET6, pointer, &ipv6) == 1
    }

    guard !isIPAddress else {
        return nil
    }
    return host
}
