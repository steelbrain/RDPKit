import Foundation

public struct RDPProbeWarning: Encodable, Equatable, Sendable {
    public var code: String
    public var message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
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
    public var certificateTrusted: Bool?
    public var certificateSHA256: String?
    public var earlyUserAuthorizationResult: UInt32?
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
    public var rdpIssuedClientLicense: RDPStoredClientLicense?
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
    public var rdpFastPathUpdateMessages: [RDPFastPathUpdateSummary]?
    public var rdpGraphicsFailureUpdateResponseHex: String?
    public var rdpGraphicsFailureUpdatePayloadHex: String?
    public var rdpGraphicsFailureUpdateMessages: [RDPGFXMessageSummary]?
    public var rdpGraphicsFailureUpdateMessageIndex: Int?
    public var rdpGraphicsFrameAcknowledgeHexes: [String]?
    public var rdpGraphicsFrames: [RDPGraphicsFrameSnapshot]?
    public var rdpGraphicsFirstFrame: RDPGraphicsFrameSnapshot?
    public var rdpRemoteTerminationErrorInfo: UInt32?
    public var rdpRemoteTerminationErrorInfoName: String?
    public var rdpRemoteTerminationDisconnectReason: UInt8?
    public var rdpRemoteTerminationDisconnectReasonName: String?
    public var rdpDisplayControlChannelID: UInt32?
    public var rdpDisplayControlChannelCreateResponseHex: String?
    public var rdpDisplayControlCapsHex: String?
    public var rdpDisplayControlCaps: RDPDisplayControlCapabilities?
    public var rdpClipboardChannelID: UInt16?
    public var rdpClipboardMessages: [RDPClipboardMessageSummary]?
    public var rdpClipboardSentMessages: [RDPClipboardMessageSummary]?
    public var rdpAudioChannelID: UInt16?
    public var rdpAudioMessages: [RDPAudioMessageSummary]?
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
        certificateTrusted: Bool? = nil,
        certificateSHA256: String? = nil,
        earlyUserAuthorizationResult: UInt32? = nil,
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
        rdpIssuedClientLicense: RDPStoredClientLicense? = nil,
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
        rdpFastPathUpdateMessages: [RDPFastPathUpdateSummary]? = nil,
        rdpGraphicsFailureUpdateResponseHex: String? = nil,
        rdpGraphicsFailureUpdatePayloadHex: String? = nil,
        rdpGraphicsFailureUpdateMessages: [RDPGFXMessageSummary]? = nil,
        rdpGraphicsFailureUpdateMessageIndex: Int? = nil,
        rdpGraphicsFrameAcknowledgeHexes: [String]? = nil,
        rdpGraphicsFrames: [RDPGraphicsFrameSnapshot]? = nil,
        rdpGraphicsFirstFrame: RDPGraphicsFrameSnapshot? = nil,
        rdpRemoteTerminationErrorInfo: UInt32? = nil,
        rdpRemoteTerminationErrorInfoName: String? = nil,
        rdpRemoteTerminationDisconnectReason: UInt8? = nil,
        rdpRemoteTerminationDisconnectReasonName: String? = nil,
        rdpDisplayControlChannelID: UInt32? = nil,
        rdpDisplayControlChannelCreateResponseHex: String? = nil,
        rdpDisplayControlCapsHex: String? = nil,
        rdpDisplayControlCaps: RDPDisplayControlCapabilities? = nil,
        rdpClipboardChannelID: UInt16? = nil,
        rdpClipboardMessages: [RDPClipboardMessageSummary]? = nil,
        rdpClipboardSentMessages: [RDPClipboardMessageSummary]? = nil,
        rdpAudioChannelID: UInt16? = nil,
        rdpAudioMessages: [RDPAudioMessageSummary]? = nil,
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
        self.certificateTrusted = certificateTrusted
        self.certificateSHA256 = certificateSHA256
        self.earlyUserAuthorizationResult = earlyUserAuthorizationResult
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
        self.rdpIssuedClientLicense = rdpIssuedClientLicense
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
        self.rdpFastPathUpdateMessages = rdpFastPathUpdateMessages
        self.rdpGraphicsFailureUpdateResponseHex = rdpGraphicsFailureUpdateResponseHex
        self.rdpGraphicsFailureUpdatePayloadHex = rdpGraphicsFailureUpdatePayloadHex
        self.rdpGraphicsFailureUpdateMessages = rdpGraphicsFailureUpdateMessages
        self.rdpGraphicsFailureUpdateMessageIndex = rdpGraphicsFailureUpdateMessageIndex
        self.rdpGraphicsFrameAcknowledgeHexes = rdpGraphicsFrameAcknowledgeHexes
        self.rdpGraphicsFrames = rdpGraphicsFrames
        self.rdpGraphicsFirstFrame = rdpGraphicsFirstFrame ?? rdpGraphicsFrames?.first
        self.rdpRemoteTerminationErrorInfo = rdpRemoteTerminationErrorInfo
        self.rdpRemoteTerminationErrorInfoName = rdpRemoteTerminationErrorInfoName
        self.rdpRemoteTerminationDisconnectReason = rdpRemoteTerminationDisconnectReason
        self.rdpRemoteTerminationDisconnectReasonName = rdpRemoteTerminationDisconnectReasonName
        self.rdpDisplayControlChannelID = rdpDisplayControlChannelID
        self.rdpDisplayControlChannelCreateResponseHex = rdpDisplayControlChannelCreateResponseHex
        self.rdpDisplayControlCapsHex = rdpDisplayControlCapsHex
        self.rdpDisplayControlCaps = rdpDisplayControlCaps
        self.rdpClipboardChannelID = rdpClipboardChannelID
        self.rdpClipboardMessages = rdpClipboardMessages
        self.rdpClipboardSentMessages = rdpClipboardSentMessages
        self.rdpAudioChannelID = rdpAudioChannelID
        self.rdpAudioMessages = rdpAudioMessages
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
    case protocolViolation(String)
    case cancelled
    /// The `onGraphicsFrame` handler threw; the server's data was not at fault.
    case graphicsFrameHandler(any Error)

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
        case let .protocolViolation(message):
            message
        case .cancelled:
            "cancelled"
        case let .graphicsFrameHandler(error):
            "graphics frame handler failed: \(error)"
        }
    }
}
