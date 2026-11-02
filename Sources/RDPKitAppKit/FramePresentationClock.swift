#if os(macOS)
import AppKit
import QuartzCore
import RDPKit

/// Paces presentation to the display: an invisible view whose window's display link calls
/// `onFrame` at the next refresh after `requestFrame()`. The link runs only while a frame waits,
/// so an idle desktop does not wake the main thread, and the screen's timing is read again only
/// when the window, its screen or the screen's mode changes.
@available(macOS 14, *)
public final class RDPFramePresentationClock: NSView {
    /// Called at the first refresh after `requestFrame()`; it can request the next one.
    public var onFrame: ((CADisplayLink) -> Void)?
    /// Called, on a later turn of the main queue, with the screen's timing and the clock's
    /// state whenever they change.
    public var onTimingChange: ((RDPFramePacingState) -> Void)?

    /// Whether frames wait for the display; turning it off drops a frame's request, and
    /// `requestFrame()` then returns false so the caller presents at once.
    public var isEnabled = false {
        didSet {
            guard isEnabled != oldValue else {
                return
            }
            if !isEnabled {
                isPresentationPending = false
            }
            updateDisplayLinkPause()
            publish(lastPublishedState.updatingClock(
                displayLinkDuration: firedDisplayLinkDuration,
                hasDisplayLink: displayLink != nil,
                isPaused: !isEnabled
            ))
        }
    }

    private var displayLink: CADisplayLink?
    /// Whether the display link has fired on the window's screen. Until it does, its `duration`
    /// is 0 or the previous screen's, so the timing published leaves it out.
    private var displayLinkHasFiredOnScreen = false
    private weak var observedWindow: NSWindow?
    private var isPresentationPending = false
    private var lastPublishedState = RDPFramePacingState()

    deinit {
        MainActor.assumeIsolated {
            stopDisplayLink()
            stopObservingWindow()
            onFrame = nil
            onTimingChange = nil
        }
    }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureDisplayLink(for: window)
    }

    override public func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            stopDisplayLink()
            stopObservingWindow()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override public func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        publishTiming()
    }

    /// Runs the display link until its next refresh calls `onFrame`. Returns false when there is
    /// no clock to wait for, off or with no window, and the caller presents at once.
    @discardableResult
    public func requestFrame() -> Bool {
        guard isEnabled, let displayLink else {
            return false
        }
        isPresentationPending = true
        displayLink.isPaused = false
        return true
    }

    /// Whether the display link waits for a refresh.
    public var isDisplayLinkRunning: Bool {
        displayLink.map { !$0.isPaused } ?? false
    }

    private func configureDisplayLink(for nextWindow: NSWindow?) {
        guard observedWindow !== nextWindow || (nextWindow != nil && displayLink == nil) else {
            return
        }

        stopDisplayLink()
        stopObservingWindow()
        observedWindow = nextWindow

        guard let nextWindow else {
            publishTiming()
            return
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenDidChange(_:)),
            name: NSWindow.didChangeScreenNotification,
            object: nextWindow
        )
        // A display's refresh rate or mode can change while the window stays on it.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenDidChange(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        let nextDisplayLink = nextWindow.displayLink(
            target: self,
            selector: #selector(displayLinkFired(_:))
        )
        nextDisplayLink.isPaused = !(isEnabled && isPresentationPending)
        nextDisplayLink.add(to: .main, forMode: .common)
        displayLink = nextDisplayLink
        publishTiming()
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
        displayLinkHasFiredOnScreen = false
    }

    /// Removes both observers even once the window is gone: `observedWindow` is weak, and
    /// reads nil while the window deallocates, which would leave the screen-parameters
    /// observer behind, and add it a second time for the next window.
    private func stopObservingWindow() {
        NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeScreenNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSApplication.didChangeScreenParametersNotification, object: nil)
        observedWindow = nil
    }

    private func updateDisplayLinkPause() {
        displayLink?.isPaused = !(isEnabled && isPresentationPending)
    }

    /// Not private, so tests can stand in for a refresh.
    @objc func displayLinkFired(_ displayLink: CADisplayLink) {
        displayLinkHasFiredOnScreen = true
        isPresentationPending = false
        updateDisplayLinkPause()
        onFrame?(displayLink)
    }

    @objc private func screenDidChange(_: Notification) {
        // The link's duration is the old screen's or refresh rate's until it fires again.
        displayLinkHasFiredOnScreen = false
        publishTiming()
    }

    private var firedDisplayLinkDuration: TimeInterval? {
        displayLinkHasFiredOnScreen ? displayLink?.duration : nil
    }

    /// Reads the screen, so only a window, screen or backing change calls it.
    private func publishTiming() {
        publish(RDPFramePacingState.current(
            window: observedWindow,
            displayLinkDuration: firedDisplayLinkDuration,
            hasDisplayLink: displayLink != nil,
            isPaused: !isEnabled
        ))
    }

    private func publish(_ nextState: RDPFramePacingState) {
        lastPublishedState = nextState
        DispatchQueue.main.async { [weak self] in
            self?.onTimingChange?(nextState)
        }
    }
}

/// Holds the one decoded frame waiting for the clock's next refresh: a frame that arrives
/// while one waits replaces it, which a client counts as a skipped presentation.
@MainActor
public final class RDPFramePresentationBuffer {
    private var pendingPresentation: RDPDecodedFramePresentation?

    public init() {}

    /// Returns whether a waiting frame was replaced.
    public func replacePendingPresentation(_ presentation: RDPDecodedFramePresentation) -> Bool {
        let replacedPendingPresentation = pendingPresentation != nil
        pendingPresentation = presentation
        return replacedPendingPresentation
    }

    public func takePendingPresentation() -> RDPDecodedFramePresentation? {
        let presentation = pendingPresentation
        pendingPresentation = nil
        return presentation
    }

    public func clear() {
        pendingPresentation = nil
    }
}
#endif
