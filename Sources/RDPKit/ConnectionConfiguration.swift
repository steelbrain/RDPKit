import Foundation

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
    public var earlyUserAuthorizationEnabled: Bool
    public var graphicsCapabilityProfile: RDPGraphicsCapabilityProfile
    public var storedClientLicense: RDPStoredClientLicense?
    public var keyboardLayout: RDPKeyboardLayout
    public var keyboardType: RDPKeyboardType
    /// An OEM-dependent value; 0 for most keyboards.
    public var keyboardSubType: UInt32
    public var keyboardFunctionKeyCount: UInt32
    var redirectionRoutingToken: Data?
    var redirectionSessionID: UInt32?
    var redirectionPasswordCookie: Data?
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
        earlyUserAuthorizationEnabled: Bool = false,
        graphicsCapabilityProfile: RDPGraphicsCapabilityProfile = .automatic,
        storedClientLicense: RDPStoredClientLicense? = nil,
        keyboardLayout: RDPKeyboardLayout = .unitedStates,
        keyboardType: RDPKeyboardType = .ibmEnhanced,
        keyboardSubType: UInt32 = 0,
        keyboardFunctionKeyCount: UInt32 = 12
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
        self.earlyUserAuthorizationEnabled = earlyUserAuthorizationEnabled
        self.graphicsCapabilityProfile = graphicsCapabilityProfile
        self.storedClientLicense = storedClientLicense
        self.keyboardLayout = keyboardLayout
        self.keyboardType = keyboardType
        self.keyboardSubType = keyboardSubType
        self.keyboardFunctionKeyCount = keyboardFunctionKeyCount
        self.redirectionRoutingToken = nil
        self.redirectionSessionID = nil
        self.redirectionPasswordCookie = nil
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
        earlyUserAuthorizationEnabled: Bool = false,
        graphicsCapabilityProfile: RDPGraphicsCapabilityProfile = .automatic,
        storedClientLicense: RDPStoredClientLicense? = nil,
        keyboardLayout: RDPKeyboardLayout = .unitedStates,
        keyboardType: RDPKeyboardType = .ibmEnhanced,
        keyboardSubType: UInt32 = 0,
        keyboardFunctionKeyCount: UInt32 = 12
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
            earlyUserAuthorizationEnabled: earlyUserAuthorizationEnabled,
            graphicsCapabilityProfile: graphicsCapabilityProfile,
            storedClientLicense: storedClientLicense,
            keyboardLayout: keyboardLayout,
            keyboardType: keyboardType,
            keyboardSubType: keyboardSubType,
            keyboardFunctionKeyCount: keyboardFunctionKeyCount
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

    var clientKeyboard: RDPClientKeyboard {
        RDPClientKeyboard(
            layout: keyboardLayout,
            type: keyboardType,
            subType: keyboardSubType,
            functionKeyCount: keyboardFunctionKeyCount
        )
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

    var negotiationRequest: RDPNegotiationRequest {
        RDPNegotiationRequest(
            requestedProtocols: earlyUserAuthorizationEnabled
                ? [.tls, .credSSP, .credSSPWithEarlyUserAuth]
                : [.tls, .credSSP]
        )
    }

    var connectionRequest: X224ConnectionRequest {
        X224ConnectionRequest(routingToken: redirectionRoutingToken, negotiationRequest: negotiationRequest)
    }

    var target: String {
        "\(host):\(port)"
    }
}
