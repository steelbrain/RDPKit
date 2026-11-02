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
    /// "success" or "failure" once the run returns, "running" in an
    /// `RDPLiveConnectionReport` snapshot before that, and "dry-run" from `dryRun`.
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
    /// The TCP connect attempt under way, or the one that connected or failed, from 1;
    /// above 1 after ``RDPConnectionConfiguration/connectAttempts`` retried. Nil before the
    /// first. An ``RDPLiveConnectionReport`` shows it as it changes, so an app can say it is
    /// trying again.
    public var connectAttempt: Int?
    /// When the next TCP connect attempt starts, while the client waits for it after
    /// `connectAttempt` failed; nil otherwise. An ``RDPLiveConnectionReport`` shows it, so an
    /// app can say when it tries again: attempt `connectAttempt + 1` of
    /// ``RDPConnectionConfiguration/connectAttempts``.
    public var nextConnectAttemptDate: Date?
    /// The configured credentials' user name and `domain` or, with none, those a Server
    /// Redirection named with its password cookie, which the reconnect's Client Info PDU
    /// carries.
    public var username: String?
    public var domain: String?
    public var passwordConfigured: Bool
    public var requestedProtocols: [String]
    public var requestHex: String
    public var responseHex: String?
    public var negotiationFlags: UInt8?
    public var selectedProtocols: [String]?
    /// Whether the server checks the credentials before the session starts: it selected CredSSP
    /// (Network Level Authentication), with or without Early User Authorization, or RDSTLS,
    /// which end the connection on a wrong password before activation. False when it selected
    /// TLS alone: the server then starts the session whatever the password and asks on its own
    /// logon screen, where the user may sign in with another, so a client saves a password only
    /// when this is true. Nil until the negotiation, and for the connection a redirection led
    /// to, that connection's. The sessions handlers get carry it in their
    /// ``RDPConnectionContext``.
    public var credentialsVerifiedBeforeActivation: Bool?
    public var failureCode: UInt32?
    public var tlsProtocol: String?
    /// Whether the TLS handshake offered only RSA key exchange, which has no forward secrecy:
    /// `RDPConnectionConfiguration.legacyRSAKeyExchange` is `.always`, or `.fallback` and the
    /// certificate of the server first connected to refused ECDHE. Nil until a handshake completes.
    public var usedLegacyRSAKeyExchange: Bool?
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
    /// True when the server's licensing failed, or the server ended the connection for a
    /// licensing reason, after the client presented its stored license and before the session
    /// activated, and the run connected again from the start without it, as it does once;
    /// nil otherwise. A license the server issues then reaches `onClientLicenseIssued` to replace
    /// the stored one; while none does, the next run presents the stored one again, and costs a
    /// connection more, unless the application drops it.
    public var rdpStoredClientLicenseRejected: Bool?
    /// The latest auto-reconnect cookie the server sent, for reconnecting to the session
    /// through ``RDPConnectionConfiguration/autoReconnectCookie``. It is a secret, and
    /// the report's encoding keeps only its logon ID.
    public var rdpAutoReconnectCookie: RDPAutoReconnectCookie?
    /// How the server last said a user logged on to the session ([MS-RDPBCGR] 2.2.10.1); nil
    /// until it does, and an ``RDPLiveConnectionReport``'s snapshot holds it once it arrives.
    /// Without Network Level Authentication or RDSTLS a server activates the session whatever
    /// the credentials, and asks for others on its own logon screen when they are wrong, so
    /// activation says nothing about them. A user who logs on at that screen is notified too,
    /// so this says the session is signed in, not with which credentials.
    public var rdpLogonNotification: RDPLogonNotification?
    /// The latest logon error notification the server sent ([MS-RDPBCGR] 2.2.10.1.1.4.1.1).
    public var rdpLogonErrorInfo: RDPLogonErrorInfo?
    public var rdpPostLicensingResponseHex: String?
    public var rdpPostLicensingResponseType: String?
    /// The monitors of the server's latest Monitor Layout PDU ([MS-RDPBCGR] 2.2.12.1), where
    /// they are in the desktop as a frame's ``RDPGraphicsFrameSnapshot/monitors`` are in the
    /// graphics output. Servers send one to a client that sent a
    /// ``RDPConnectionConfiguration/monitorLayout`` or set
    /// ``RDPConnectionConfiguration/receivesServerMonitorLayout``, and an ``RDPLiveConnectionReport``'s
    /// snapshot holds it as soon as it arrives. Windows 11 and gnome-remote-desktop 51 send it
    /// right after each Demand Active, so before `onInputReady` hands out that activation's
    /// input session (observed live). In a session without RDPGFX, whose frames carry no
    /// monitors, Windows 11 sends a new one when a Display Control layout reactivates it; a
    /// layout RDPGFX carries comes in frames' monitors instead.
    public var rdpMonitorLayout: [RDPRemoteMonitor]?
    /// What is off about ``rdpMonitorLayout`` as the server laid it out, in its bounding box.
    public var rdpMonitorLayoutIssues: RDPRemoteMonitorLayoutIssues?
    /// The toggle keys the server last said are on, in a Set Keyboard Indicators PDU
    /// ([MS-RDPBCGR] 2.2.8.2.1.1); an ``RDPLiveConnectionReport``'s snapshot holds them as soon
    /// as they arrive. They can drift from the client's keyboard, such as when another client of
    /// the session or a server setting changes them, and Caps Lock then types the other case;
    /// ``RDPInputStateTracker/synchronizationEvents(toggleFlags:)`` sets them again. The input
    /// session has them too, as ``RDPInputSession/serverToggleKeys``.
    public var rdpKeyboardIndicators: RDPToggleKeyFlags?
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
    /// The PDUs around the failing one, at most 64 of an update that can hold millions.
    public var rdpGraphicsFailureUpdateMessages: [RDPGFXMessageSummary]?
    /// Where in the update the failing PDU is; nil when the update did not decode into PDUs.
    public var rdpGraphicsFailureUpdateMessageIndex: Int?
    /// Where in the update the first of `rdpGraphicsFailureUpdateMessages` is; nil when the
    /// update did not decode into PDUs.
    public var rdpGraphicsFailureUpdateFirstMessageIndex: Int?
    /// How many PDUs the update held; nil when it did not decode into PDUs.
    public var rdpGraphicsFailureUpdateMessageCount: Int?
    /// The first frame acknowledgements sent: as many as a capture run's
    /// frames, 8 in a live session.
    public var rdpGraphicsFrameAcknowledgeHexes: [String]?
    /// How many frame acknowledgements the session sent: RDPGFX_FRAME_ACKNOWLEDGE_PDU
    /// ([MS-RDPEGFX] 2.2.2.13) and TS_FRAME_ACKNOWLEDGE_PDU ([MS-RDPRFX] 2.2.3.3).
    public var rdpGraphicsFrameAcknowledgeCount: Int?
    /// How many layouts the session sent through Display Control to ask for a keyframe after
    /// video failed to decode (``RDPConnectionConfiguration/recoversVideoWithLayoutResend``).
    public var rdpKeyframeRequestCount: Int?
    public var rdpGraphicsFrames: [RDPGraphicsFrameSnapshot]?
    public var rdpGraphicsFirstFrame: RDPGraphicsFrameSnapshot?
    /// The frames the `onGraphicsFrame` handler showed on this connection: it returned without
    /// throwing `RDPGraphicsFrameNotPresented`. Nil until it shows one; `rdpGraphicsFirstFrame`
    /// is the first that came, shown or not.
    public var presentedFrameCount: Int?
    /// The frames the handler showed over the whole run: `presentedFrameCount` and those of the
    /// connections before this one, such as the one whose Server Redirection led here. Nil
    /// until one is shown. Whether the run showed a desktop, for an app telling a session that
    /// ended from one that never got that far, as after a redirection's target fails.
    public var runPresentedFrameCount: Int?
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
        credentialsVerifiedBeforeActivation: Bool? = nil,
        failureCode: UInt32? = nil,
        tlsProtocol: String? = nil,
        usedLegacyRSAKeyExchange: Bool? = nil,
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
        rdpStoredClientLicenseRejected: Bool? = nil,
        rdpAutoReconnectCookie: RDPAutoReconnectCookie? = nil,
        rdpLogonNotification: RDPLogonNotification? = nil,
        rdpLogonErrorInfo: RDPLogonErrorInfo? = nil,
        rdpPostLicensingResponseHex: String? = nil,
        rdpPostLicensingResponseType: String? = nil,
        rdpMonitorLayout: [RDPRemoteMonitor]? = nil,
        rdpMonitorLayoutIssues: RDPRemoteMonitorLayoutIssues? = nil,
        rdpKeyboardIndicators: RDPToggleKeyFlags? = nil,
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
        rdpGraphicsFailureUpdateFirstMessageIndex: Int? = nil,
        rdpGraphicsFailureUpdateMessageCount: Int? = nil,
        rdpGraphicsFrameAcknowledgeHexes: [String]? = nil,
        rdpGraphicsFrameAcknowledgeCount: Int? = nil,
        rdpKeyframeRequestCount: Int? = nil,
        rdpGraphicsFrames: [RDPGraphicsFrameSnapshot]? = nil,
        rdpGraphicsFirstFrame: RDPGraphicsFrameSnapshot? = nil,
        presentedFrameCount: Int? = nil,
        runPresentedFrameCount: Int? = nil,
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
        self.credentialsVerifiedBeforeActivation = credentialsVerifiedBeforeActivation
        self.failureCode = failureCode
        self.tlsProtocol = tlsProtocol
        self.usedLegacyRSAKeyExchange = usedLegacyRSAKeyExchange
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
        self.rdpStoredClientLicenseRejected = rdpStoredClientLicenseRejected
        self.rdpAutoReconnectCookie = rdpAutoReconnectCookie
        self.rdpLogonNotification = rdpLogonNotification
        self.rdpLogonErrorInfo = rdpLogonErrorInfo
        self.rdpPostLicensingResponseHex = rdpPostLicensingResponseHex
        self.rdpPostLicensingResponseType = rdpPostLicensingResponseType
        self.rdpMonitorLayout = rdpMonitorLayout
        self.rdpMonitorLayoutIssues = rdpMonitorLayoutIssues
        self.rdpKeyboardIndicators = rdpKeyboardIndicators
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
        self.rdpGraphicsFailureUpdateFirstMessageIndex = rdpGraphicsFailureUpdateFirstMessageIndex
        self.rdpGraphicsFailureUpdateMessageCount = rdpGraphicsFailureUpdateMessageCount
        self.rdpGraphicsFrameAcknowledgeHexes = rdpGraphicsFrameAcknowledgeHexes
        self.rdpGraphicsFrameAcknowledgeCount = rdpGraphicsFrameAcknowledgeCount
        self.rdpKeyframeRequestCount = rdpKeyframeRequestCount
        self.rdpGraphicsFrames = rdpGraphicsFrames
        self.rdpGraphicsFirstFrame = rdpGraphicsFirstFrame ?? rdpGraphicsFrames?.first
        self.presentedFrameCount = presentedFrameCount
        self.runPresentedFrameCount = runPresentedFrameCount
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
    /// The server did not answer the connection request with the X.224 Connection Confirm
    /// every Remote Desktop server sends first ([MS-RDPBCGR] 2.2.1.2); `reason` says what came
    /// instead. Another protocol's reply means another service; a close, reset or silence can
    /// also be a host at its connection limit or a firewall that blocks Remote Desktop.
    case noConnectionConfirm(reason: RDPNoConnectionConfirmReason)
    /// The server selected a security protocol RDPKit does not support, such
    /// as Standard RDP Security.
    case unsupportedSecurityProtocol
    /// The TLS handshake failed, or the server's certificate could not be read.
    case tls
    /// The server's RSA certificate does not allow digitalSignature, so the
    /// TLS handshake refuses ECDHE key exchange (KEY_USAGE_BIT_INCORRECT). No
    /// credential was sent yet. `RDPConnectionConfiguration.legacyRSAKeyExchange` at
    /// `.fallback` connects again with RSA key exchange within the run, but for a Server
    /// Redirection's target, and `.always` offers it from the start.
    case tlsKeyUsageIncorrect
    /// The server answered Network Level Authentication with this CredSSP version, below
    /// 5, whose proof of the TLS key is the encryption oracle of CVE-2018-0886, and RDPKit
    /// refused it as Windows clients do. No credential was sent yet; connecting again with
    /// `RDPConnectionConfiguration.legacyCredSSP` set can succeed, when the report's
    /// `redirectionDepth` is 0. Above 0 the server was a Server Redirection's target, which
    /// that setting does not cover.
    case legacyCredSSPVersion(version: Int)
    /// The server requires Network Level Authentication (CredSSP), and the
    /// configuration has no credentials.
    case credentialsRequired
    /// The server rejected the credentials during Network Level Authentication
    /// with this NTSTATUS ([MS-CSSP] 2.2.1).
    case credSSP(status: RDPLogonStatus)
    /// The server closed or reset the connection during Network Level Authentication after
    /// the client proved its credentials, before answering them, and gave no NTSTATUS: a
    /// CredSSP version 2 server, which has no errorCode to send ([MS-CSSP] 2.2.1), rejects a
    /// sign-in this way, so the credentials may be wrong. A close before they go out is
    /// `connectionClosed` or `connectionLost`.
    case credSSPClosedAfterCredentials
    /// The Early User Authorization Result denied access ([MS-RDPBCGR] 2.2.10.2).
    case earlyUserAuthorizationDenied
    /// The server rejected the credentials a Server Redirection gave, during RDSTLS
    /// authentication, with this result code. The redirection named the user and password;
    /// gnome-remote-desktop's are one-time credentials of its own.
    case rdSTLS(resultCode: RDPRDSTLSResultCode)
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
    /// than the Client Info PDU ([MS-RDPBCGR] 2.2.1.11.1.1) or NTLM holds.
    /// The server was not at fault.
    case invalidConfiguration
    /// RDPKit failed on this device: the system could not generate random
    /// bytes, or RDPKit broke its own sequence. The server was not at fault.
    case clientFailure
    /// The `onGraphicsFrame` handler threw an error other than `RDPGraphicsFrameNotPresented`.
    case graphicsFrameHandler
    /// A live session activated, but showed no frame within
    /// `RDPConnectionConfiguration.timeoutSeconds`: the `onGraphicsFrame` handler got
    /// `framesReceived` frames and threw `RDPGraphicsFrameNotPresented` for each, the last
    /// with `lastNotPresentedReason`; with none, the server sent no frame, or did not set up its
    /// graphics. Connecting again can bring the desktop; a connection that showed a frame
    /// never ends this way, though the one a Server Redirection leads to can after the one
    /// before showed frames, which `RDPConnectionReport.runPresentedFrameCount` counts. A run
    /// that captures frames
    /// (`RDPConnectionConfiguration.graphicsFrameCaptureLimit`) times out with `timedOut`.
    case noFramePresented(framesReceived: Int, lastNotPresentedReason: String?)
}

/// What came in place of the X.224 Connection Confirm.
public enum RDPNoConnectionConfirmReason: Encodable, Equatable, Sendable {
    /// The server closed the connection.
    case closed
    /// The connection was reset or broke.
    case reset
    /// Nothing came within `RDPConnectionConfiguration.timeoutSeconds`.
    case timedOut
    /// Bytes that are not a Connection Confirm, such as another protocol's greeting: the first
    /// 16 of them, or fewer when fewer came.
    case unexpectedReply(firstBytes: Data)
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

    /// The `onGraphicsFrame` handler threw. RDPKit had parsed the frame, but what the handler
    /// did with it, such as decoding its video, may still have failed on the server's data.
    static func graphicsFrameHandler(_ error: any Error) -> RDPConnectionError {
        RDPConnectionError(.graphicsFrameHandler, description: "graphics frame handler failed: \(error)")
    }
}
