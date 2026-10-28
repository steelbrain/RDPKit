import Foundation

/// The connection sequence phases ([MS-RDPBCGR] 1.3.1.1), reported as
/// `RDPPreflightReport.stage`.
enum RDPConnectionStage: String {
    case negotiation = "x224-rdp-negotiation"
    case tlsHandshake = "tls-handshake"
    case credSSP = "credssp"
    case earlyUserAuthorization = "early-user-authorization"
    case channelConnection = "mcs-channel-connection"
    case clientInfo = "rdp-client-info"
    case autoDetect = "rdp-auto-detect"
    case licensing = "rdp-licensing"
    case confirmActive = "rdp-confirm-active"
    case finalization = "rdp-connection-finalization"
    case graphics = "rdp-graphics-dynamic-channel"
}

/// Why the server ended the session: the last Set Error Info PDU
/// ([MS-RDPBCGR] 2.2.5.1.1) and the MCS Disconnect Provider Ultimatum reason.
struct RDPRemoteTermination: Equatable, Sendable {
    var errorInfo: UInt32?
    var disconnectReason: UInt8?

    /// Logoff and disconnects the user asked for; anything else is an error.
    var isClean: Bool {
        if let errorInfo {
            return [0x0000_0001, 0x0000_0002, 0x0000_000B, 0x0000_000C].contains(errorInfo)
        }
        return disconnectReason == 3
    }

    var errorInfoName: String? {
        errorInfo.map { errorInfo in
            switch errorInfo {
            case 0x0000_0001: "ERRINFO_RPC_INITIATED_DISCONNECT"
            case 0x0000_0002: "ERRINFO_RPC_INITIATED_LOGOFF"
            case 0x0000_000B: "ERRINFO_RPC_INITIATED_DISCONNECT_BY_USER"
            case 0x0000_000C: "ERRINFO_LOGOFF_BY_USER"
            default: "ERRINFO_0x\(String(format: "%08x", errorInfo))"
            }
        }
    }

    var disconnectReasonName: String? {
        disconnectReason.map { MCSDisconnectProviderUltimatumPDU(reason: $0).reasonName }
    }

    var description: String {
        guard let name = errorInfoName ?? disconnectReasonName else {
            return "server ended the session"
        }
        return "server ended the session with \(name)"
    }
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

/// Clipboard PDUs the session sent; filled from whichever thread sends them.
final class RDPClipboardSentLog: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [RDPClipboardMessageSummary] = []

    func append(_ summary: RDPClipboardMessageSummary) {
        lock.withLock {
            messages.appendCapped(summary, limit: RDPRecordLimit.messages)
        }
    }

    var snapshot: [RDPClipboardMessageSummary] {
        lock.withLock { messages }
    }
}
