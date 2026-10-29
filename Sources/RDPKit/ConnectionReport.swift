import Foundation

public struct RDPConnectionWarning: Encodable, Equatable, Sendable {
    public var code: String
    public var message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public struct RDPConnectionReport: Encodable, Equatable, Sendable {
    public var status: String
    public var stage: String
    /// The host:port this connection went to: after a Server Redirection, the
    /// one the redirection named.
    public var target: String
    /// How many Server Redirections led to `target` ([MS-RDPBCGR] 3.1.5.2): 0
    /// for the configured server, at most 2. Above 0, the configured server
    /// took the logon and handed the session on, so a failure here is the
    /// target's, not that server's.
    public var redirectionDepth: Int
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
    /// The latest auto-reconnect cookie the server sent, for reconnecting to the session
    /// through ``RDPConnectionConfiguration/autoReconnectCookie``. It is a secret, and
    /// the report's encoding keeps only its logon ID.
    public var rdpAutoReconnectCookie: RDPAutoReconnectCookie?
    public var rdpPostLicensingResponseHex: String?
    public var rdpPostLicensingResponseType: String?
    /// The monitors of the server's latest Monitor Layout PDU ([MS-RDPBCGR] 2.2.12.1), where
    /// they are in the desktop as a frame's ``RDPGraphicsFrameSnapshot/monitors`` are in the
    /// graphics output. Servers send one to a client that sent a
    /// ``RDPConnectionConfiguration/monitorLayout``.
    public var rdpMonitorLayout: [RDPRemoteMonitor]?
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
    public var warnings: [RDPConnectionWarning]
    public var nextStage: String?
    /// Why the connection failed, in words, for diagnostics; `failure` says it for code.
    public var error: String?
    /// Why the connection failed; nil when the session ran and ended normally.
    public var failure: RDPConnectionFailure?

    public init(
        status: String,
        stage: String,
        target: String,
        redirectionDepth: Int = 0,
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
        rdpAutoReconnectCookie: RDPAutoReconnectCookie? = nil,
        rdpPostLicensingResponseHex: String? = nil,
        rdpPostLicensingResponseType: String? = nil,
        rdpMonitorLayout: [RDPRemoteMonitor]? = nil,
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
        warnings: [RDPConnectionWarning],
        nextStage: String? = nil,
        error: String? = nil,
        failure: RDPConnectionFailure? = nil
    ) {
        self.status = status
        self.stage = stage
        self.target = target
        self.redirectionDepth = redirectionDepth
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
        self.rdpAutoReconnectCookie = rdpAutoReconnectCookie
        self.rdpPostLicensingResponseHex = rdpPostLicensingResponseHex
        self.rdpPostLicensingResponseType = rdpPostLicensingResponseType
        self.rdpMonitorLayout = rdpMonitorLayout
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
        self.failure = failure
    }
}

public extension RDPConnectionReport {
    /// `stage` as a value; nil for a report no connection made, such as a dry run's.
    var connectionStage: RDPConnectionStage? {
        RDPConnectionStage(rawValue: stage)
    }

    /// How the server ended the session, when it said: from the
    /// `rdpRemoteTermination` fields.
    var remoteTermination: RDPRemoteTermination? {
        guard rdpRemoteTerminationErrorInfo != nil || rdpRemoteTerminationDisconnectReason != nil else {
            return nil
        }
        return RDPRemoteTermination(
            errorInfo: rdpRemoteTerminationErrorInfo,
            disconnectReason: rdpRemoteTerminationDisconnectReason
        )
    }
}

/// Why a connection attempt or session failed. `RDPConnectionReport.error`
/// and `RDPConnectionError.description` give the details in words.
public enum RDPConnectionFailure: Encodable, Equatable, Sendable {
    /// The host name did not resolve.
    case addressResolution
    /// The TCP connection failed.
    case connect(error: RDPSocketError)
    /// The server refused the security negotiation with RDP_NEG_FAILURE ([MS-RDPBCGR] 2.2.1.2.2).
    case negotiation(code: RDPNegotiationFailureCode)
    /// The server selected a security protocol RDPKit does not support, such
    /// as Standard RDP Security.
    case unsupportedSecurityProtocol
    /// The TLS handshake failed, or the server's certificate could not be read.
    case tls
    /// The server's RSA certificate does not allow digitalSignature, so the
    /// TLS handshake refuses ECDHE key exchange (KEY_USAGE_BIT_INCORRECT). No
    /// credential was sent yet; connecting again with
    /// `RDPConnectionConfiguration.legacyRSAKeyExchange` set can succeed.
    case tlsKeyUsageIncorrect
    /// The server requires Network Level Authentication (CredSSP), and the
    /// configuration has no credentials.
    case credentialsRequired
    /// The server rejected the credentials during Network Level Authentication
    /// with this NTSTATUS ([MS-CSSP] 2.2.1).
    case credSSP(status: RDPLogonStatus)
    /// The Early User Authorization Result denied access ([MS-RDPBCGR] 2.2.10.2).
    case earlyUserAuthorizationDenied
    /// Licensing failed with this Licensing Error Message dwErrorCode ([MS-RDPBCGR] 2.2.1.12.1.3).
    case licensing(errorCode: UInt32)
    /// The server ended the session: before it ran, or for a reason that is
    /// not a normal end (`RDPRemoteTermination.isNormalEnd`).
    case serverTermination(termination: RDPRemoteTermination)
    /// The connection broke: a reset, a TLS error or a keepalive timeout.
    case connectionLost
    /// The server closed the connection without saying why.
    case connectionClosed
    /// The server did not answer, or did not reach the next step of the
    /// connection, within `RDPConnectionConfiguration.timeoutSeconds`.
    case timedOut
    /// The run was cancelled.
    case cancelled
    /// The server broke the protocol, or needs something RDPKit does not support.
    case protocolViolation
    /// The configuration holds something RDPKit cannot send: credentials longer
    /// than the Client Info PDU ([MS-RDPBCGR] 2.2.1.11.1.1) or NTLM holds, or a
    /// `storedClientLicense` too large for the Client License Information PDU.
    /// The server was not at fault.
    case invalidConfiguration
    /// RDPKit failed on this device: the system could not generate random
    /// bytes, or RDPKit broke its own sequence. The server was not at fault.
    case clientFailure
    /// The `onGraphicsFrame` handler threw.
    case graphicsFrameHandler
}

/// A failed TCP connect: its errno and the kind of failure that is.
public struct RDPSocketError: Encodable, Equatable, Sendable {
    public enum Category: String, Encodable, Sendable {
        /// Nothing accepts connections on the port, or a firewall refused it (ECONNREFUSED).
        case refused
        /// The host cannot be reached (EHOSTUNREACH, EHOSTDOWN). On Apple
        /// platforms local network privacy also fails a connection into the
        /// local network with EHOSTUNREACH, so this can mean the app may not
        /// use the local network.
        case hostUnreachable
        /// This device has no route to the host's network (ENETUNREACH, ENETDOWN).
        case networkUnreachable
        /// The host did not answer (ETIMEDOUT), or not within `timeoutSeconds`.
        case timedOut
        /// The system refused to make the connection (EACCES, EPERM).
        case notPermitted
        /// Another errno, or none.
        case other
    }

    /// The errno; ETIMEDOUT also when `RDPConnectionConfiguration.timeoutSeconds`
    /// ran out first, and nil when the failure had none.
    public let errno: Int32?
    public let category: Category

    public init(errno: Int32?) {
        self.errno = errno
        category = switch errno {
        case ECONNREFUSED: .refused
        case EHOSTUNREACH, EHOSTDOWN: .hostUnreachable
        case ENETUNREACH, ENETDOWN: .networkUnreachable
        case ETIMEDOUT: .timedOut
        case EACCES, EPERM: .notPermitted
        default: .other
        }
    }
}

/// Why a connection failed: `failure` for code, `description` in words.
/// `RDPSessionClient.connect` throws it with the report `run` returns for the
/// same failure; a report carries the two as `failure` and `error`.
public struct RDPConnectionError: Error, CustomStringConvertible, Sendable {
    public var failure: RDPConnectionFailure
    public var description: String
    /// The report `RDPSessionClient.run` returns for this failure: the stage
    /// reached, the negotiation and `redirectionDepth`. `connect` attaches it,
    /// and throws only before the TLS handshake, so it holds no captured frames
    /// and stays small. Nil on an error `connect` did not throw.
    public var report: RDPConnectionReport?

    public init(_ failure: RDPConnectionFailure, description: String, report: RDPConnectionReport? = nil) {
        self.failure = failure
        self.description = description
        self.report = report
    }

    /// The report's `redirectionDepth`: above 0 when the connection that failed
    /// was one a Server Redirection asked for, not the configured server.
    public var redirectionDepth: Int {
        report?.redirectionDepth ?? 0
    }

    /// The report's `target`: the host:port of the connection that failed, the
    /// redirection's target when `redirectionDepth` is above 0.
    public var target: String? {
        report?.target
    }
}

extension RDPConnectionError {
    static let cancelled = RDPConnectionError(.cancelled, description: "cancelled")

    static func addressResolution(_ message: String) -> RDPConnectionError {
        RDPConnectionError(.addressResolution, description: "address resolution failed: \(message)")
    }

    static func connect(_ error: RDPSocketError, _ message: String) -> RDPConnectionError {
        RDPConnectionError(.connect(error: error), description: "connect failed: \(message)")
    }

    static func send(_ message: String) -> RDPConnectionError {
        RDPConnectionError(.connectionLost, description: "send failed: \(message)")
    }

    static func receive(_ message: String, failure: RDPConnectionFailure = .connectionLost) -> RDPConnectionError {
        RDPConnectionError(failure, description: "receive failed: \(message)")
    }

    static func tls(_ message: String, failure: RDPConnectionFailure = .tls) -> RDPConnectionError {
        RDPConnectionError(failure, description: "TLS failed: \(message)")
    }

    static func protocolViolation(_ message: String) -> RDPConnectionError {
        RDPConnectionError(.protocolViolation, description: message)
    }

    static func invalidConfiguration(_ message: String) -> RDPConnectionError {
        RDPConnectionError(.invalidConfiguration, description: message)
    }

    static func clientFailure(_ message: String) -> RDPConnectionError {
        RDPConnectionError(.clientFailure, description: message)
    }

    /// The `onGraphicsFrame` handler threw; the server's data was not at fault.
    static func graphicsFrameHandler(_ error: any Error) -> RDPConnectionError {
        RDPConnectionError(.graphicsFrameHandler, description: "graphics frame handler failed: \(error)")
    }
}
