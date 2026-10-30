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
    /// The scale the session starts at, in the Client Core Data ([MS-RDPBCGR] 2.2.1.3.2):
    /// desktopScaleFactor is clamped to 100-500 and deviceScaleFactor rounded to 100, 140
    /// or 180. Display Control can change it later.
    public var scaleFactors: RDPDisplayScaleFactors
    /// The desktop's physical size, sent with the scale factors; nil, or a size servers
    /// ignore (under 10 mm or over 10,000 mm), sends none.
    public var physicalSize: RDPDisplayPhysicalSize?
    /// The monitors the session starts with; nil starts one of desktopWidth x desktopHeight.
    /// They go in Client Monitor Data and Client Monitor Extended Data ([MS-RDPBCGR] 2.2.1.3.6,
    /// 2.2.1.3.10), and the desktop is their bounding box, up to the 32,766 pixels each way
    /// Client Monitor Data allows: Windows 11 and gnome-remote-desktop 51 start one of three
    /// 3840x2160 monitors at 11520x2160 (observed live). A server that does not accept extended
    /// client data blocks gets neither, and the session starts as without a layout. A layout
    /// whose monitors form separate groups is dropped, as Windows 11 makes one monitor of their
    /// bounding box; Display Control can ask for it once the session runs.
    public var monitorLayout: RDPMonitorLayout?
    /// Joins cliprdr. Joining sends the Format List [MS-RDPECLIP] 1.3.2.1 requires at startup, of
    /// what the client has published, empty until it publishes; Windows 11 takes that as the
    /// client's copy and empties the server's clipboard (observed live; gnome-remote-desktop 51
    /// keeps it). A client that must leave the server's clipboard alone, and can wait for a
    /// reconnect to share, keeps this off; `RDPClipboardSession.fetchesRemoteCopies` controls
    /// only what the client fetches.
    public var clipboardEnabled: Bool
    public var audioPlaybackEnabled: Bool
    public var earlyUserAuthorizationEnabled: Bool
    public var graphicsCapabilityProfile: RDPGraphicsCapabilityProfile
    public var storedClientLicense: RDPStoredClientLicense?
    /// An earlier session's ``RDPConnectionReport/rdpAutoReconnectCookie``, which asks the
    /// server to reconnect to that session ([MS-RDPBCGR] 5.5). It does not replace the
    /// credentials CredSSP needs.
    public var autoReconnectCookie: RDPAutoReconnectCookie?
    public var keyboardLayout: RDPKeyboardLayout
    public var keyboardType: RDPKeyboardType
    /// An OEM-dependent value; 0 for most keyboards.
    public var keyboardSubType: UInt32
    public var keyboardFunctionKeyCount: UInt32
    /// Offers only TLS 1.2 RSA key exchange cipher suites. Some servers' RSA certificates
    /// allow keyEncipherment but not the digitalSignature that ECDHE key exchange needs, and
    /// the handshake with them fails with `KEY_USAGE_BIT_INCORRECT`. RSA key exchange has no
    /// forward secrecy, so set this only to retry after that failure.
    public var legacyRSAKeyExchange: Bool
    /// Local folders the server sees as drives. Sharing one joins the rdpsnd channel too.
    public var sharedDrives: [RDPSharedDrive]
    /// The name servers show for this client, in session lists, for per-device licensing
    /// and as the NTLM workstation of a Network Level Authentication logon: at most 15
    /// characters ([MS-RDPBCGR] 2.2.1.3.2). Control characters are dropped and a longer
    /// name is cut; with nothing left it is "RDPKIT".
    public var clientName: String
    var redirectionRoutingToken: Data?
    var redirectionSessionID: UInt32?
    var redirectionPasswordCookie: Data?
    /// Set after a Server Redirection whose password is PK-encrypted: the reconnect offers
    /// RDSTLS beside TLS and CredSSP, and authenticates with these when the target selects it.
    var redirectionRDSTLSCredentials: RDPRDSTLSPasswordCredentials?
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
        scaleFactors: RDPDisplayScaleFactors = RDPDisplayScaleFactors(desktopScaleFactor: 100, deviceScaleFactor: 100),
        physicalSize: RDPDisplayPhysicalSize? = nil,
        monitorLayout: RDPMonitorLayout? = nil,
        clipboardEnabled: Bool = true,
        audioPlaybackEnabled: Bool = false,
        earlyUserAuthorizationEnabled: Bool = false,
        graphicsCapabilityProfile: RDPGraphicsCapabilityProfile = .automatic,
        storedClientLicense: RDPStoredClientLicense? = nil,
        autoReconnectCookie: RDPAutoReconnectCookie? = nil,
        keyboardLayout: RDPKeyboardLayout = .unitedStates,
        keyboardType: RDPKeyboardType = .ibmEnhanced,
        keyboardSubType: UInt32 = 0,
        keyboardFunctionKeyCount: UInt32 = 12,
        legacyRSAKeyExchange: Bool = false,
        sharedDrives: [RDPSharedDrive] = [],
        clientName: String = "RDPKIT"
    ) {
        self.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        self.port = port
        self.credentials = credentials
        self.timeoutSeconds = max(1, timeoutSeconds)
        self.hideCertificateWarnings = hideCertificateWarnings
        self.graphicsFrameCaptureLimit = graphicsFrameCaptureLimit.map { min(120, max(1, $0)) }
        (self.desktopWidth, self.desktopHeight) = Self.validDesktopSize(width: desktopWidth, height: desktopHeight)
        self.scaleFactors = scaleFactors.clamped
        self.physicalSize = physicalSize?.isValid == true ? physicalSize : nil
        self.monitorLayout = Self.validMonitorLayout(monitorLayout)
        self.clipboardEnabled = clipboardEnabled
        self.audioPlaybackEnabled = audioPlaybackEnabled
        self.earlyUserAuthorizationEnabled = earlyUserAuthorizationEnabled
        self.graphicsCapabilityProfile = graphicsCapabilityProfile
        self.storedClientLicense = storedClientLicense
        self.autoReconnectCookie = autoReconnectCookie
        self.keyboardLayout = keyboardLayout
        self.keyboardType = keyboardType
        self.keyboardSubType = keyboardSubType
        self.keyboardFunctionKeyCount = keyboardFunctionKeyCount
        self.legacyRSAKeyExchange = legacyRSAKeyExchange
        self.sharedDrives = sharedDrives
        self.clientName = Self.validClientName(clientName)
        self.redirectionRoutingToken = nil
        self.redirectionSessionID = nil
        self.redirectionPasswordCookie = nil
        self.redirectionRDSTLSCredentials = nil
        self.redirectionDepth = 0
    }

    public init(
        target: RDPConnectionTarget,
        credentials: RDPCredentials? = nil,
        timeoutSeconds: Int = 10,
        hideCertificateWarnings: Bool = false,
        graphicsFrameCaptureLimit: Int? = 1,
        desktopSize: RDPDesktopSize,
        scaleFactors: RDPDisplayScaleFactors = RDPDisplayScaleFactors(desktopScaleFactor: 100, deviceScaleFactor: 100),
        physicalSize: RDPDisplayPhysicalSize? = nil,
        monitorLayout: RDPMonitorLayout? = nil,
        clipboardEnabled: Bool = true,
        audioPlaybackEnabled: Bool = false,
        earlyUserAuthorizationEnabled: Bool = false,
        graphicsCapabilityProfile: RDPGraphicsCapabilityProfile = .automatic,
        storedClientLicense: RDPStoredClientLicense? = nil,
        autoReconnectCookie: RDPAutoReconnectCookie? = nil,
        keyboardLayout: RDPKeyboardLayout = .unitedStates,
        keyboardType: RDPKeyboardType = .ibmEnhanced,
        keyboardSubType: UInt32 = 0,
        keyboardFunctionKeyCount: UInt32 = 12,
        legacyRSAKeyExchange: Bool = false,
        sharedDrives: [RDPSharedDrive] = [],
        clientName: String = "RDPKIT"
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
            scaleFactors: scaleFactors,
            physicalSize: physicalSize,
            monitorLayout: monitorLayout,
            clipboardEnabled: clipboardEnabled,
            audioPlaybackEnabled: audioPlaybackEnabled,
            earlyUserAuthorizationEnabled: earlyUserAuthorizationEnabled,
            graphicsCapabilityProfile: graphicsCapabilityProfile,
            storedClientLicense: storedClientLicense,
            autoReconnectCookie: autoReconnectCookie,
            keyboardLayout: keyboardLayout,
            keyboardType: keyboardType,
            keyboardSubType: keyboardSubType,
            keyboardFunctionKeyCount: keyboardFunctionKeyCount,
            legacyRSAKeyExchange: legacyRSAKeyExchange,
            sharedDrives: sharedDrives,
            clientName: clientName
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

    /// `name` without control characters or surrounding spaces, cut between characters to
    /// the 15 UTF-16 code units Client Core Data holds before its terminator; "RDPKIT" when
    /// nothing is left.
    static func validClientName(_ name: String) -> String {
        let characters = name.filter { character in
            !character.unicodeScalars.contains { $0.properties.generalCategory == .control }
        }
        var valid = ""
        for character in characters.trimmingCharacters(in: .whitespaces) {
            guard valid.utf16.count + character.utf16.count <= 15 else {
                break
            }
            valid.append(character)
        }
        valid = valid.trimmingCharacters(in: .whitespaces)
        return valid.isEmpty ? "RDPKIT" : valid
    }

    /// The size clamped to 640-8192 x 480-8192, as the initializer clamps desktopWidth and
    /// desktopHeight.
    static func validDesktopSize(width: UInt16, height: UInt16) -> (width: UInt16, height: UInt16) {
        (min(8192, max(640, width)), min(8192, max(480, height)))
    }

    /// `layout` when its monitors form one group. [MS-RDPBCGR] 2.2.1.3.6 does not rule out
    /// separate groups, but given them Windows 11 starts one monitor of their bounding box, and
    /// with the automatic graphics profile confirms RDPGFX with AVC_DISABLED and AVC_THINCLIENT
    /// together, which [MS-RDPEGFX] 2.2.3.6 forbids, so without AVC. Monitors touching only at
    /// a corner start as sent (observed live).
    static func validMonitorLayout(_ layout: RDPMonitorLayout?) -> RDPMonitorLayout? {
        guard let layout, layout.formsOneGroup else {
            return nil
        }
        return layout
    }

    /// The monitor layout to send at connect: none to a server that does not accept extended
    /// client data blocks ([MS-RDPBCGR] 2.2.1.3), and none that the initializer would drop,
    /// since it can be set after it.
    func connectionMonitorLayout(extendedClientDataSupported: Bool) -> RDPMonitorLayout? {
        extendedClientDataSupported ? Self.validMonitorLayout(monitorLayout) : nil
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
        if audioPlaybackEnabled || !sharedDrives.isEmpty {
            channels.append(.rdpdr)
            // Windows 11 sends nothing on rdpdr unless rdpsnd is joined too (FreeRDP joins
            // a "fake" rdpsnd for drives). With audio off, INFO_NOAUDIOPLAYBACK keeps the
            // server from sending audio on it.
            channels.append(.rdpsnd)
        }
        return channels
    }

    var negotiationRequest: RDPNegotiationRequest {
        var protocols: RDPSecurityProtocols = earlyUserAuthorizationEnabled
            ? [.tls, .credSSP, .credSSPWithEarlyUserAuth]
            : [.tls, .credSSP]
        // After a redirection with RDSTLS credentials, FreeRDP 3.32 asks for RDSTLS and,
        // when the target refuses it, connects again for CredSSP (nego_attempt_rdstls).
        // Offering both does that in one connection: a FreeRDP-based server with RDSTLS
        // security on selects it when it is offered (rdp_server_accept_nego), and
        // gnome-remote-desktop's handover daemon has it on (grd-session-rdp.c).
        if redirectionRDSTLSCredentials != nil {
            protocols.insert(.rdSTLS)
        }
        return RDPNegotiationRequest(requestedProtocols: protocols)
    }

    var connectionRequest: X224ConnectionRequest {
        X224ConnectionRequest(routingToken: redirectionRoutingToken, negotiationRequest: negotiationRequest)
    }

    var target: String {
        "\(host):\(port)"
    }
}
