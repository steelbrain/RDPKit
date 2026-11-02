import Foundation

/// Paces the keyframe requests sent after video fails to decode: one at most every
/// ``minimumInterval``, and at most ``maximumUnansweredRequests`` until video decodes again, so
/// video that never decodes does not make the server lay out its graphics again forever.
struct RDPKeyframeRequestThrottle: Sendable {
    static let minimumInterval: TimeInterval = 3
    static let maximumUnansweredRequests = 3

    private var lastRequestAt: Date?
    private var unansweredRequests = 0

    /// Whether a request is due at `date`; counts it when it is.
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

extension RDPClientConnection {
    /// Video the frame handler did not show waits for a keyframe, which Windows 11 and
    /// gnome-remote-desktop send only for a layout sent again: the session asks for one when
    /// it is due, or once Display Control is handed out.
    func videoFrameWasNotPresented() {
        guard configuration.recoversVideoWithLayoutResend,
              keyframeRequests.shouldRequest(at: Date())
        else {
            return
        }
        isKeyframeRequestHeld = true
        sendHeldKeyframeRequest()
    }

    func videoFrameWasPresented() {
        keyframeRequests.recordDecodedVideo()
        isKeyframeRequestHeld = false
    }

    /// Sends a held request through the Display Control session handed out, if it still sends;
    /// a request no layout can make without changing the desktop is dropped.
    func sendHeldKeyframeRequest() {
        guard isKeyframeRequestHeld,
              let session = displayControlSession,
              !session.isEnded
        else {
            return
        }
        isKeyframeRequestHeld = false
        guard (try? session.requestKeyframe()) == true else {
            appendWarning(
                code: "keyframe-request-skipped",
                message: "video waits for a keyframe, but no layout keeps the server's desktop as it is"
            )
            return
        }
        report.rdpKeyframeRequestCount = (report.rdpKeyframeRequestCount ?? 0) + 1
    }
}
