import AppKit
import RDPKit

struct RDPSessionEndReason: Equatable {
    enum Kind: Equatable {
        case cancelled
        case failed
        case ended
    }

    var kind: Kind
    var message: String

    init(kind: Kind, message: String) {
        self.kind = kind
        self.message = message
    }

    static let cancelled = RDPSessionEndReason(
        kind: .cancelled,
        message: "Connection cancelled by user."
    )

    init(report: RDPConnectionReport) {
        if report.status == "failure" || report.error != nil {
            kind = .failed
            message = report.error ?? "Connection failed at \(report.stage)."
        } else if report.nextStage == "rdp-session-ended", report.rdpGraphicsChannelName == nil {
            kind = .ended
            message = "Remote session ended before opening the RDPGFX dynamic channel\(Self.terminationSuffix(report))."
        } else if report.nextStage == "rdp-session-ended", report.rdpGraphicsFrames?.isEmpty != false {
            kind = .ended
            message = "Remote session ended before producing a graphics frame\(Self.terminationSuffix(report))."
        } else {
            kind = .ended
            message = "Remote session disconnected."
        }
    }

    private static func terminationSuffix(_ report: RDPConnectionReport) -> String {
        if let errorInfoName = report.rdpRemoteTerminationErrorInfoName {
            return " (\(errorInfoName))"
        }
        if let disconnectReasonName = report.rdpRemoteTerminationDisconnectReasonName {
            return " (\(disconnectReasonName))"
        }
        return ""
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
        "\(statusText): \(message)"
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
