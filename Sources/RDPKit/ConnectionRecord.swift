import Foundation

/// The connection sequence phases ([MS-RDPBCGR] 1.3.1.1), reported as
/// `RDPConnectionReport.stage`: the one a failure happened in, or the last
/// one the session reached.
public enum RDPConnectionStage: String, Sendable {
    /// The TCP connection and the X.224 security negotiation.
    case negotiation = "x224-rdp-negotiation"
    /// The TLS handshake and the server certificate check.
    case tlsHandshake = "tls-handshake"
    /// Network Level Authentication.
    case credSSP = "credssp"
    /// RDSTLS authentication with the credentials a Server Redirection gave.
    case rdSTLS = "rdstls"
    /// The Early User Authorization Result.
    case earlyUserAuthorization = "early-user-authorization"
    /// MCS connect and the channel joins.
    case channelConnection = "mcs-channel-connection"
    /// The Client Info PDU, up to the server's next step.
    case clientInfo = "rdp-client-info"
    /// Connect-time auto-detection.
    case autoDetect = "rdp-auto-detect"
    /// Licensing.
    case licensing = "rdp-licensing"
    /// The Demand Active and Confirm Active exchange.
    case confirmActive = "rdp-confirm-active"
    /// Connection finalization.
    case finalization = "rdp-connection-finalization"
    /// Graphics, from opening the RDPGFX channel to the end of the session.
    case graphics = "rdp-graphics-dynamic-channel"
}

/// Why the server ended the session: the last non-zero Set Error Info code
/// ([MS-RDPBCGR] 2.2.5.1.1) and the MCS Disconnect Provider Ultimatum reason.
public struct RDPRemoteTermination: Encodable, Equatable, Sendable, CustomStringConvertible {
    public enum Category: String, Encodable, Sendable {
        /// The user logged off, or disconnected from inside the session.
        case user
        /// An administrator logged the user off or disconnected the session,
        /// or the server is shutting down or restarting.
        case admin
        /// The server's idle or active session time limit ran out.
        case timeLimit
        /// Another connection took over the session.
        case replaced
        /// The server denied the connection, or the user may not connect.
        case accessDenied
        /// The server does not accept saved credentials: the user has to enter them.
        case freshCredentialsRequired
        /// Licensing failed.
        case licensing
        /// The server, a part of the remote session, or a Connection Broker failed.
        case serverError
        /// The server rejected something the client sent.
        case protocolError
        /// The server gave no reason: no Set Error Info code, and a Disconnect
        /// Provider Ultimatum with rn-user-requested.
        case unspecified
        /// A code RDPKit does not know, or another Disconnect Provider Ultimatum reason.
        case unknown
    }

    public var errorInfo: UInt32?
    public var disconnectReason: UInt8?

    public init(errorInfo: UInt32? = nil, disconnectReason: UInt8? = nil) {
        self.errorInfo = errorInfo
        self.disconnectReason = disconnectReason
    }

    public var category: Category {
        guard let errorInfo else {
            return disconnectReason == MCSDisconnectProviderUltimatumPDU.userRequested.reason ? .unspecified : .unknown
        }
        return switch errorInfo {
        case 0x0000_000B, 0x0000_000C: .user
        case 0x0000_0001, 0x0000_0002, 0x0000_0019, 0x0000_001A: .admin
        case 0x0000_0003, 0x0000_0004: .timeLimit
        case 0x0000_0005: .replaced
        case 0x0000_0007, 0x0000_0009: .accessDenied
        case 0x0000_000A: .freshCredentialsRequired
        case 0x0000_0100 ... 0x0000_010A: .licensing
        case 0x0000_0006, 0x0000_000F ... 0x0000_0012, 0x0000_0017, 0x0000_0018, 0x0000_0400 ... 0x0000_0412: .serverError
        case 0x0000_10C9 ... 0x0000_1195: .protocolError
        default: .unknown
        }
    }

    /// Whether this is a normal end, not a failure, for a session whose
    /// graphics have opened: the user, an administrator, a time limit or
    /// another connection ended it, or the server gave no reason.
    public var isNormalEnd: Bool {
        [.user, .admin, .timeLimit, .replaced, .unspecified].contains(category)
    }

    /// The code's name, such as ERRINFO_IDLE_TIMEOUT, or ERRINFO_0x… for a code without one.
    public var errorInfoName: String? {
        errorInfo.map { Self.errorInfoNames[$0] ?? "ERRINFO_0x\(String(format: "%08x", $0))" }
    }

    /// The reason's name, such as rn-user-requested.
    public var disconnectReasonName: String? {
        disconnectReason.map { MCSDisconnectProviderUltimatumPDU(reason: $0).reasonName }
    }

    public var description: String {
        guard let name = errorInfoName ?? disconnectReasonName else {
            return "server ended the session"
        }
        return "server ended the session with \(name)"
    }

    /// The names of the Set Error Info codes, spelled as [MS-RDPBCGR] 2.2.5.1.1
    /// spells them, typos included (ERRINFO_BADSUPRESSOUTPUTPDU). FreeRDP
    /// spells the RDP-specific codes, 0x10C9-0x1195, differently.
    private static let errorInfoNames: [UInt32: String] = [
        0x0000_0001: "ERRINFO_RPC_INITIATED_DISCONNECT",
        0x0000_0002: "ERRINFO_RPC_INITIATED_LOGOFF",
        0x0000_0003: "ERRINFO_IDLE_TIMEOUT",
        0x0000_0004: "ERRINFO_LOGON_TIMEOUT",
        0x0000_0005: "ERRINFO_DISCONNECTED_BY_OTHERCONNECTION",
        0x0000_0006: "ERRINFO_OUT_OF_MEMORY",
        0x0000_0007: "ERRINFO_SERVER_DENIED_CONNECTION",
        0x0000_0009: "ERRINFO_SERVER_INSUFFICIENT_PRIVILEGES",
        0x0000_000A: "ERRINFO_SERVER_FRESH_CREDENTIALS_REQUIRED",
        0x0000_000B: "ERRINFO_RPC_INITIATED_DISCONNECT_BYUSER",
        0x0000_000C: "ERRINFO_LOGOFF_BY_USER",
        0x0000_000F: "ERRINFO_CLOSE_STACK_ON_DRIVER_NOT_READY",
        0x0000_0010: "ERRINFO_SERVER_DWM_CRASH",
        0x0000_0011: "ERRINFO_CLOSE_STACK_ON_DRIVER_FAILURE",
        0x0000_0012: "ERRINFO_CLOSE_STACK_ON_DRIVER_IFACE_FAILURE",
        0x0000_0017: "ERRINFO_SERVER_WINLOGON_CRASH",
        0x0000_0018: "ERRINFO_SERVER_CSRSS_CRASH",
        0x0000_0019: "ERRINFO_SERVER_SHUTDOWN",
        0x0000_001A: "ERRINFO_SERVER_REBOOT",
        0x0000_0100: "ERRINFO_LICENSE_INTERNAL",
        0x0000_0101: "ERRINFO_LICENSE_NO_LICENSE_SERVER",
        0x0000_0102: "ERRINFO_LICENSE_NO_LICENSE",
        0x0000_0103: "ERRINFO_LICENSE_BAD_CLIENT_MSG",
        0x0000_0104: "ERRINFO_LICENSE_HWID_DOESNT_MATCH_LICENSE",
        0x0000_0105: "ERRINFO_LICENSE_BAD_CLIENT_LICENSE",
        0x0000_0106: "ERRINFO_LICENSE_CANT_FINISH_PROTOCOL",
        0x0000_0107: "ERRINFO_LICENSE_CLIENT_ENDED_PROTOCOL",
        0x0000_0108: "ERRINFO_LICENSE_BAD_CLIENT_ENCRYPTION",
        0x0000_0109: "ERRINFO_LICENSE_CANT_UPGRADE_LICENSE",
        0x0000_010A: "ERRINFO_LICENSE_NO_REMOTE_CONNECTIONS",
        0x0000_0400: "ERRINFO_CB_DESTINATION_NOT_FOUND",
        0x0000_0402: "ERRINFO_CB_LOADING_DESTINATION",
        0x0000_0404: "ERRINFO_CB_REDIRECTING_TO_DESTINATION",
        0x0000_0405: "ERRINFO_CB_SESSION_ONLINE_VM_WAKE",
        0x0000_0406: "ERRINFO_CB_SESSION_ONLINE_VM_BOOT",
        0x0000_0407: "ERRINFO_CB_SESSION_ONLINE_VM_NO_DNS",
        0x0000_0408: "ERRINFO_CB_DESTINATION_POOL_NOT_FREE",
        0x0000_0409: "ERRINFO_CB_CONNECTION_CANCELLED",
        0x0000_0410: "ERRINFO_CB_CONNECTION_ERROR_INVALID_SETTINGS",
        0x0000_0411: "ERRINFO_CB_SESSION_ONLINE_VM_BOOT_TIMEOUT",
        0x0000_0412: "ERRINFO_CB_SESSION_ONLINE_VM_SESSMON_FAILED",
        0x0000_10C9: "ERRINFO_UNKNOWNPDUTYPE2",
        0x0000_10CA: "ERRINFO_UNKNOWNPDUTYPE",
        0x0000_10CB: "ERRINFO_DATAPDUSEQUENCE",
        0x0000_10CD: "ERRINFO_CONTROLPDUSEQUENCE",
        0x0000_10CE: "ERRINFO_INVALIDCONTROLPDUACTION",
        0x0000_10CF: "ERRINFO_INVALIDINPUTPDUTYPE",
        0x0000_10D0: "ERRINFO_INVALIDINPUTPDUMOUSE",
        0x0000_10D1: "ERRINFO_INVALIDREFRESHRECTPDU",
        0x0000_10D2: "ERRINFO_CREATEUSERDATAFAILED",
        0x0000_10D3: "ERRINFO_CONNECTFAILED",
        0x0000_10D4: "ERRINFO_CONFIRMACTIVEWRONGSHAREID",
        0x0000_10D5: "ERRINFO_CONFIRMACTIVEWRONGORIGINATOR",
        0x0000_10DA: "ERRINFO_PERSISTENTKEYPDUBADLENGTH",
        0x0000_10DB: "ERRINFO_PERSISTENTKEYPDUILLEGALFIRST",
        0x0000_10DC: "ERRINFO_PERSISTENTKEYPDUTOOMANYTOTALKEYS",
        0x0000_10DD: "ERRINFO_PERSISTENTKEYPDUTOOMANYCACHEKEYS",
        0x0000_10DE: "ERRINFO_INPUTPDUBADLENGTH",
        0x0000_10DF: "ERRINFO_BITMAPCACHEERRORPDUBADLENGTH",
        0x0000_10E0: "ERRINFO_SECURITYDATATOOSHORT",
        0x0000_10E1: "ERRINFO_VCHANNELDATATOOSHORT",
        0x0000_10E2: "ERRINFO_SHAREDATATOOSHORT",
        0x0000_10E3: "ERRINFO_BADSUPRESSOUTPUTPDU",
        0x0000_10E5: "ERRINFO_CONFIRMACTIVEPDUTOOSHORT",
        0x0000_10E7: "ERRINFO_CAPABILITYSETTOOSMALL",
        0x0000_10E8: "ERRINFO_CAPABILITYSETTOOLARGE",
        0x0000_10E9: "ERRINFO_NOCURSORCACHE",
        0x0000_10EA: "ERRINFO_BADCAPABILITIES",
        0x0000_10EC: "ERRINFO_VIRTUALCHANNELDECOMPRESSIONERR",
        0x0000_10ED: "ERRINFO_INVALIDVCCOMPRESSIONTYPE",
        0x0000_10EF: "ERRINFO_INVALIDCHANNELID",
        0x0000_10F0: "ERRINFO_VCHANNELSTOOMANY",
        0x0000_10F3: "ERRINFO_REMOTEAPPSNOTENABLED",
        0x0000_10F4: "ERRINFO_CACHECAPNOTSET",
        0x0000_10F5: "ERRINFO_BITMAPCACHEERRORPDUBADLENGTH2",
        0x0000_10F6: "ERRINFO_OFFSCRCACHEERRORPDUBADLENGTH",
        0x0000_10F7: "ERRINFO_DNGCACHEERRORPDUBADLENGTH",
        0x0000_10F8: "ERRINFO_GDIPLUSPDUBADLENGTH",
        0x0000_1111: "ERRINFO_SECURITYDATATOOSHORT2",
        0x0000_1112: "ERRINFO_SECURITYDATATOOSHORT3",
        0x0000_1113: "ERRINFO_SECURITYDATATOOSHORT4",
        0x0000_1114: "ERRINFO_SECURITYDATATOOSHORT5",
        0x0000_1115: "ERRINFO_SECURITYDATATOOSHORT6",
        0x0000_1116: "ERRINFO_SECURITYDATATOOSHORT7",
        0x0000_1117: "ERRINFO_SECURITYDATATOOSHORT8",
        0x0000_1118: "ERRINFO_SECURITYDATATOOSHORT9",
        0x0000_1119: "ERRINFO_SECURITYDATATOOSHORT10",
        0x0000_111A: "ERRINFO_SECURITYDATATOOSHORT11",
        0x0000_111B: "ERRINFO_SECURITYDATATOOSHORT12",
        0x0000_111C: "ERRINFO_SECURITYDATATOOSHORT13",
        0x0000_111D: "ERRINFO_SECURITYDATATOOSHORT14",
        0x0000_111E: "ERRINFO_SECURITYDATATOOSHORT15",
        0x0000_111F: "ERRINFO_SECURITYDATATOOSHORT16",
        0x0000_1120: "ERRINFO_SECURITYDATATOOSHORT17",
        0x0000_1121: "ERRINFO_SECURITYDATATOOSHORT18",
        0x0000_1122: "ERRINFO_SECURITYDATATOOSHORT19",
        0x0000_1123: "ERRINFO_SECURITYDATATOOSHORT20",
        0x0000_1124: "ERRINFO_SECURITYDATATOOSHORT21",
        0x0000_1125: "ERRINFO_SECURITYDATATOOSHORT22",
        0x0000_1126: "ERRINFO_SECURITYDATATOOSHORT23",
        0x0000_1129: "ERRINFO_BADMONITORDATA",
        0x0000_112A: "ERRINFO_VCDECOMPRESSEDREASSEMBLEFAILED",
        0x0000_112B: "ERRINFO_VCDATATOOLONG",
        0x0000_112C: "ERRINFO_BAD_FRAME_ACK_DATA",
        0x0000_112D: "ERRINFO_GRAPHICSMODENOTSUPPORTED",
        0x0000_112E: "ERRINFO_GRAPHICSSUBSYSTEMRESETFAILED",
        0x0000_112F: "ERRINFO_GRAPHICSSUBSYSTEMFAILED",
        0x0000_1130: "ERRINFO_TIMEZONEKEYNAMELENGTHTOOSHORT",
        0x0000_1131: "ERRINFO_TIMEZONEKEYNAMELENGTHTOOLONG",
        0x0000_1132: "ERRINFO_DYNAMICDSTDISABLEDFIELDMISSING",
        0x0000_1133: "ERRINFO_VCDECODINGERROR",
        0x0000_1134: "ERRINFO_VIRTUALDESKTOPTOOLARGE",
        0x0000_1135: "ERRINFO_MONITORGEOMETRYVALIDATIONFAILED",
        0x0000_1136: "ERRINFO_INVALIDMONITORCOUNT",
        0x0000_1191: "ERRINFO_UPDATESESSIONKEYFAILED",
        0x0000_1192: "ERRINFO_DECRYPTFAILED",
        0x0000_1193: "ERRINFO_ENCRYPTFAILED",
        0x0000_1194: "ERRINFO_ENCPKGMISMATCH",
        0x0000_1195: "ERRINFO_DECRYPTFAILED2",
    ]
}

/// How many graphics diagnostics a report keeps. Live sessions (no capture
/// target) keep a fixed handful so memory stays flat for hours.
func recordedGraphicsFrameLimit(targetFrameCount: Int?) -> Int {
    targetFrameCount.map { max(1, $0) } ?? 1
}

func recordedGraphicsMessageLimit(targetFrameCount: Int?) -> Int {
    guard let targetFrameCount else {
        return 16
    }
    return max(16, min(Int.max / 4, max(1, targetFrameCount)) * 4)
}

func recordedGraphicsAcknowledgeLimit(targetFrameCount: Int?) -> Int {
    targetFrameCount.map { max(1, $0) } ?? 8
}

/// Diagnostic lists that are not tied to the capture target.
enum RDPRecordLimit {
    static let packets = 8
    static let messages = 64
    static let warnings = 32
    static let failurePayloadByteCount = 64 * 1024
}

extension Array {
    /// Appends to a diagnostic list, dropping the oldest entries past `limit`.
    mutating func appendCapped(_ element: Element, limit: Int) {
        append(element)
        if count > limit {
            removeFirst(count - limit)
        }
    }
}

extension Optional {
    mutating func appendCapped<Element>(_ element: Element, limit: Int) where Wrapped == [Element] {
        if self == nil {
            self = []
        }
        self?.appendCapped(element, limit: limit)
    }

    /// Appends to a diagnostic list until it holds `limit` entries; `element`
    /// is only built when it is kept, since most calls come once the list is full.
    mutating func appendIfRoom<Element>(_ element: @autoclosure () -> Element, limit: Int) where Wrapped == [Element] {
        guard hasRoom(limit: limit) else {
            return
        }
        if self == nil {
            self = []
        }
        self?.append(element())
    }

    func hasRoom<Element>(limit: Int) -> Bool where Wrapped == [Element] {
        (self?.count ?? 0) < limit
    }
}

/// A running connection's report, which any thread can read while
/// `RDPSessionClient.run` or `connect` runs, for example to show diagnostics
/// during a session. Pass it to the call as `liveReport`.
///
/// ``snapshot`` copies the report so far: `status` is "running", `stage` the
/// one the connection is in, and `nextStage` nil. After a Server Redirection
/// it is the redirection target's. Once the call returns, it is the report
/// the call returned or attached to the error `connect` threw.
public final class RDPLiveConnectionReport: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: RDPConnectionReportStorage?

    public init() {}

    /// A copy of the report so far; nil until the call starts connecting. The
    /// copy shares the report's lists and takes a lock the connection holds
    /// only while it records a change, so reading it often costs little.
    public var snapshot: RDPConnectionReport? {
        lock.withLock { storage }?.report
    }

    /// Reads the report of the connection now starting, such as a redirection's.
    func follow(_ storage: RDPConnectionReportStorage) {
        lock.withLock { self.storage = storage }
    }
}

/// One connection's report. The connection thread fills it, clipboard sends
/// add to it from whichever thread sends them, and `RDPLiveConnectionReport`
/// copies it; each access holds the lock, so a copy never sees half a change.
final class RDPConnectionReportStorage: @unchecked Sendable {
    /// Recursive, so touching `report` again during an access trips Swift's exclusivity
    /// check, which names the access, instead of hanging the connection thread.
    private let lock = NSRecursiveLock()
    private var stored: RDPConnectionReport
    /// The run returned the report: clipboard sends after that leave it as it is.
    private var isFinished = false

    init(_ report: RDPConnectionReport) {
        stored = report
    }

    var report: RDPConnectionReport {
        _read {
            lock.lock()
            defer { lock.unlock() }
            yield stored
        }
        _modify {
            lock.lock()
            defer { lock.unlock() }
            yield &stored
        }
    }

    func recordClipboardSent(_ summary: RDPClipboardMessageSummary) {
        lock.withLock {
            if !isFinished {
                stored.rdpClipboardSentMessages.appendCapped(summary, limit: RDPRecordLimit.messages)
            }
        }
    }

    /// The report as the run returns it.
    func finish() -> RDPConnectionReport {
        lock.withLock {
            isFinished = true
            return stored
        }
    }
}
