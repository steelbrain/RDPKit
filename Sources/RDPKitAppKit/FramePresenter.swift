#if os(macOS)
import AppKit
import QuartzCore
import RDPKit

/// Paces decoded frames to the display for an `RDPRemoteDesktopVideoView`. The first frame
/// shows at once; each later one waits for the next refresh of the window's display, and a
/// frame that comes while one waits replaces it. It owns the clock, whose `clockView` the app
/// adds anywhere in the window the video shows in, and the frame waiting for it, which turning
/// pacing off or `flush()` shows and `clear()` drops.
@available(macOS 14, *)
@MainActor
public final class RDPFramePresenter {
    /// What became of a frame handed to `present(_:)`.
    public enum Outcome: Equatable, Sendable {
        /// Shown at once.
        case shown
        /// Waiting for the display's next refresh.
        case waiting
        /// Waiting in place of a frame that waited, which is never shown: a skipped presentation.
        case replaced
    }

    /// The clock, to add to the window the video shows in; it is hidden and draws nothing.
    public let clockView = RDPFramePresentationClock(frame: .zero)
    public let videoView: RDPRemoteDesktopVideoView
    /// Called with each frame once the video view shows it, at once or at a refresh.
    public var onShow: ((RDPDecodedFramePresentation) -> Void)?
    /// Called with the screen's timing and the clock's state whenever they change, with the
    /// display link's refresh interval once it fires.
    public var onTimingChange: ((RDPFramePacingState) -> Void)?
    /// The timing last published.
    public private(set) var timing = RDPFramePacingState()
    /// Whether frames after the first wait for the display; on by default. Turned off, the frame
    /// waiting shows at once, and so do the frames after it.
    public var isPacing = true {
        didSet {
            guard isPacing != oldValue else {
                return
            }
            updateClock()
            if !isPacing {
                flush()
            }
        }
    }

    private let buffer = RDPFramePresentationBuffer()
    private var hasShownFrame = false
    private var lastPresentationID = 0

    public init(videoView: RDPRemoteDesktopVideoView) {
        self.videoView = videoView
        clockView.isHidden = true
        clockView.onFrame = { [weak self] displayLink in
            self?.refresh(displayLink)
        }
        clockView.onTimingChange = { [weak self] state in
            self?.publish(state)
        }
    }

    /// Shows `presentation` at once, or holds it for the display's next refresh.
    @discardableResult
    public func present(_ presentation: RDPDecodedFramePresentation) -> Outcome {
        // The clock runs once a frame has shown, so the first one shows at once.
        guard clockView.requestFrame() else {
            show(presentation)
            return .shown
        }
        return buffer.replacePendingPresentation(presentation) ? .replaced : .waiting
    }

    /// Shows the frame waiting for the display at once, as when a session ends; false when none
    /// waits.
    @discardableResult
    public func flush() -> Bool {
        guard let presentation = buffer.takePendingPresentation() else {
            return false
        }
        show(presentation)
        return true
    }

    /// Drops the frame waiting and takes the shown one off the video view, as for a new
    /// session, whose first frame then shows at once.
    public func clear() {
        buffer.clear()
        hasShownFrame = false
        updateClock()
        videoView.clear()
    }

    private func show(_ presentation: RDPDecodedFramePresentation) {
        lastPresentationID += 1
        videoView.present(presentation, id: lastPresentationID)
        if !hasShownFrame {
            hasShownFrame = true
            updateClock()
        }
        onShow?(presentation)
    }

    /// The clock runs once a frame has shown, so the first one never waits for it.
    private func updateClock() {
        clockView.isEnabled = isPacing && hasShownFrame
    }

    private func refresh(_ displayLink: CADisplayLink) {
        publish(timing.updatingDisplayLinkDuration(displayLink.duration))
        flush()
    }

    private func publish(_ state: RDPFramePacingState) {
        guard state != timing else {
            return
        }
        timing = state
        onTimingChange?(state)
    }
}
#endif
