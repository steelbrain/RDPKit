import AppKit
import RDPKit

struct RDPSessionEndReason: Equatable {
    enum Kind: Equatable {
        case cancelled
        case failed
        case ended
    }

    var kind: Kind
    /// What happened, in words for the user.
    var message: String
    /// What RDPKit said, for diagnostics: its error, or the server's termination code.
    var detail: String?
    /// Whether entering the credentials again can help.
    var offersCredentials: Bool

    init(kind: Kind, message: String, detail: String? = nil, offersCredentials: Bool = false) {
        self.kind = kind
        self.message = message
        self.detail = detail
        self.offersCredentials = offersCredentials
    }

    static let cancelled = RDPSessionEndReason(
        kind: .cancelled,
        message: "Connection cancelled by user."
    )

    init(report: RDPConnectionReport) {
        let termination = report.remoteTermination
        if let failure = report.failure {
            self = Self.failure(failure, error: report.error)
        } else if report.status == "failure" || report.error != nil {
            self = RDPSessionEndReason(kind: .failed, message: "The connection failed.", detail: report.error ?? "failed at \(report.stage)")
        } else if report.rdpGraphicsFirstFrame != nil {
            // Checked first: a server without RDPGFX sends frames as bitmap updates.
            self = RDPSessionEndReason(
                kind: .ended,
                message: termination.map(Self.message(for:)) ?? "The server closed the connection.",
                detail: termination?.description
            )
        } else if report.nextStage == "rdp-session-ended" {
            let missingStep = report.rdpGraphicsChannelName == nil
                ? "opening the RDPGFX dynamic channel"
                : "producing a graphics frame"
            self = RDPSessionEndReason(
                kind: .ended,
                message: termination.map { "\(Self.message(for: $0)) This happened before the desktop appeared." }
                    ?? "The session ended before the desktop appeared.",
                detail: "\(termination?.description ?? "session ended") before \(missingStep)"
            )
        } else {
            self = RDPSessionEndReason(kind: .ended, message: "The remote session ended.", detail: termination?.description)
        }
    }

    private static func failure(_ failure: RDPConnectionFailure, error: String?) -> RDPSessionEndReason {
        let credentialsMessage = "The server requires Network Level Authentication: enter a user name and password."
        let (text, offersCredentials): (String, Bool) = switch failure {
        case .addressResolution:
            ("The server's name could not be found. Check the host name and your network connection.", false)
        case let .connect(socketError):
            (message(for: socketError), false)
        case .negotiation(code: .hybridRequiredByServer):
            (credentialsMessage, true)
        case .negotiation(code: .sslWithUserAuthRequiredByServer):
            ("The server requires a client certificate, which RDPClient does not support.", false)
        case .negotiation(code: .sslNotAllowedByServer):
            ("The server offers only Standard RDP Security, which RDPClient does not support.", false)
        case .unsupportedSecurityProtocol:
            ("The server chose a security protocol RDPClient does not support, such as Standard RDP Security.", false)
        case .negotiation(code: .sslCertificateNotOnServer):
            ("The server has no certificate to secure the connection with.", false)
        case .negotiation:
            ("The server refused the security RDPClient offered.", false)
        case .tls:
            ("A secure connection to the server could not be set up.", false)
        case .tlsKeyUsageIncorrect:
            ("The server's certificate does not allow the key exchange RDPClient offered.", false)
        case .credentialsRequired:
            (credentialsMessage, true)
        case let .credSSP(status):
            message(for: status)
        case .earlyUserAuthorizationDenied:
            ("The server denied this account access.", false)
        case .licensing:
            ("The server could not license this connection. Its administrator has to check its Remote Desktop licensing.", false)
        case let .serverTermination(termination):
            (message(for: termination), termination.category == .freshCredentialsRequired)
        case .connectionLost:
            ("The connection to the server was lost.", false)
        case .connectionClosed:
            ("The server closed the connection.", false)
        case .timedOut:
            ("The server did not respond in time.", false)
        case .cancelled:
            (Self.cancelled.message, false)
        case .protocolViolation:
            ("The server sent something RDPClient cannot handle.", false)
        case .graphicsFrameHandler:
            ("RDPClient could not show the remote desktop.", false)
        }
        return RDPSessionEndReason(
            kind: failure == .cancelled ? .cancelled : .failed,
            message: text,
            detail: error,
            offersCredentials: offersCredentials
        )
    }

    private static func message(for error: RDPSocketError) -> String {
        switch error.category {
        case .refused:
            "The server refused the connection. Check that Remote Desktop is on and the port is right."
        case .hostUnreachable:
            "The server could not be reached. If it is on your local network, check that RDPClient may use "
                + "the local network in System Settings > Privacy & Security > Local Network."
        case .networkUnreachable:
            "This Mac has no route to the server's network. Check your network connection or VPN."
        case .timedOut:
            "The server did not answer. Check the host name and port, and that no firewall blocks the connection."
        case .notPermitted:
            "macOS did not allow the connection, for example because of a firewall or network filter."
        case .other:
            "The connection to the server could not be made."
        }
    }

    /// The message, and whether entering the credentials again can help.
    private static func message(for status: RDPLogonStatus) -> (String, Bool) {
        switch status {
        case .logonFailure, .wrongPassword, .noSuchUser:
            ("The user name or password is incorrect.", true)
        case .accountLockedOut:
            ("The account is locked out. Try again later, or ask an administrator to unlock it.", false)
        case .accountDisabled:
            ("The account is disabled.", false)
        case .accountExpired:
            ("The account has expired.", false)
        case .passwordExpired:
            ("The password has expired. Change it, then connect again.", false)
        case .passwordMustChange:
            ("The password must be changed before the first sign-in. Change it, then connect again.", false)
        case .logonTypeNotGranted:
            ("The account may not sign in remotely. An administrator can add it to the Remote Desktop Users group.", false)
        case .accountRestriction:
            ("The account's restrictions do not allow this sign-in; an account without a password cannot sign in remotely.", false)
        case .invalidLogonHours:
            ("The account may not sign in at this time.", false)
        case .invalidWorkstation:
            ("The account may not sign in from this computer.", false)
        default:
            ("The server refused the sign-in.", false)
        }
    }

    private static func message(for termination: RDPRemoteTermination) -> String {
        switch termination.category {
        case .user:
            "The remote session was signed out or disconnected from within."
        case .admin:
            "An administrator ended the session, or the server is shutting down or restarting."
        case .timeLimit:
            "The session reached the server's idle or session time limit."
        case .replaced:
            "Another connection took over the session."
        case .accessDenied:
            "The server denied the connection, or the account may not connect."
        case .freshCredentialsRequired:
            "The server requires the credentials to be entered again."
        case .licensing:
            "The server could not license this connection."
        case .serverError:
            "The session ended because of an error on the server."
        case .protocolError:
            "The server rejected something RDPClient sent."
        case .unspecified, .unknown:
            "The server ended the session."
        }
    }

    var title: String {
        switch kind {
        case .cancelled:
            return "Disconnected"
        case .failed:
            return "Connection Failed"
        case .ended:
            return "Disconnected"
        }
    }

    var statusText: String {
        switch kind {
        case .cancelled:
            return "Cancelled"
        case .failed:
            return "Failed"
        case .ended:
            return "Disconnected"
        }
    }

    var systemImage: String {
        switch kind {
        case .cancelled:
            return "xmark.circle"
        case .failed:
            return "exclamationmark.triangle.fill"
        case .ended:
            return "power"
        }
    }

    var diagnosticValue: String {
        ["\(statusText): \(message)", detail].compactMap { $0 }.joined(separator: "\n")
    }
}

/// Paces the keyframe requests sent after video fails to decode: one at most every few seconds,
/// and only a few until video decodes again, so video that never decodes does not make the
/// server reset its graphics forever.
struct RDPKeyframeRequestThrottle {
    static let minimumInterval: TimeInterval = 3
    static let maximumUnansweredRequests = 3

    private var lastRequestAt: Date?
    private var unansweredRequests = 0

    mutating func shouldRequest(at date: Date) -> Bool {
        guard unansweredRequests < Self.maximumUnansweredRequests else {
            return false
        }
        if let lastRequestAt, date.timeIntervalSince(lastRequestAt) < Self.minimumInterval {
            return false
        }
        lastRequestAt = date
        unansweredRequests += 1
        return true
    }

    mutating func recordDecodedVideo() {
        unansweredRequests = 0
    }
}

/// Paces the sizes Follow View Size sends over Display Control: a size goes out once the view
/// has kept it for a moment, and never when the server was last sent it.
struct RDPDisplayResizeDebounce {
    static let delayNanoseconds: UInt64 = 350_000_000

    /// The request last sent, by following the view or from the size fields.
    private(set) var lastSent: RDPDisplayRequest?
    /// The view's size while it waits out the delay.
    private(set) var pending: RDPDisplayRequest?

    /// Returns whether `request` has to wait out the delay. It replaces the waiting request even
    /// when the server already has it, so a size the view only passed through is never sent.
    mutating func viewChanged(to request: RDPDisplayRequest) -> Bool {
        pending = request == lastSent ? nil : request
        return pending != nil
    }

    /// Whether `request`, having waited out the delay, is to be sent: false when the view has
    /// changed since, or the server was sent it meanwhile.
    mutating func settle(_ request: RDPDisplayRequest) -> Bool {
        guard pending == request else {
            return false
        }
        pending = nil
        return request != lastSent
    }

    mutating func recordSent(_ request: RDPDisplayRequest) {
        lastSent = request
    }

    /// Drops the waiting request; `forgettingLastSent` also forgets what the server was sent.
    mutating func cancel(forgettingLastSent: Bool) {
        pending = nil
        if forgettingLastSent {
            lastSent = nil
        }
    }
}
