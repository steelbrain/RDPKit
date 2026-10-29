import AppKit
import QuartzCore
import RDPKit

/// Paces presentation to the display: a frame waits for the window's next refresh. The display
/// link runs only while a frame waits, so an idle desktop does not wake the main thread.
final class RDPFramePresentationClockNSView: NSView {
    private var displayLink: CADisplayLink?
    /// Whether the display link has fired on the window's screen. Until it does, its `duration`
    /// is 0 or the previous screen's, so the timing published leaves it out.
    private var displayLinkHasFiredOnScreen = false
    private weak var observedWindow: NSWindow?
    private var isEnabled = false
    private var isPresentationPending = false
    private var lastPublishedState = RDPFramePacingState()
    private var onFrame: ((CADisplayLink) -> Void)?
    private var onTimingChange: ((RDPFramePacingState) -> Void)?

    deinit {
        MainActor.assumeIsolated {
            stopDisplayLink()
            stopObservingWindow()
            onFrame = nil
            onTimingChange = nil
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureDisplayLink(for: window)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            stopDisplayLink()
            stopObservingWindow()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        publishTiming()
    }

    func configure(
        isEnabled: Bool,
        onFrame: @escaping (CADisplayLink) -> Void,
        onTimingChange: @escaping (RDPFramePacingState) -> Void
    ) {
        let wasEnabled = self.isEnabled
        self.isEnabled = isEnabled
        if !isEnabled {
            isPresentationPending = false
        }
        self.onFrame = onFrame
        self.onTimingChange = onTimingChange
        configureDisplayLink(for: window)
        updateDisplayLinkPause()
        if wasEnabled != isEnabled {
            publish(lastPublishedState.updatingClock(
                displayLinkDuration: firedDisplayLinkDuration,
                hasDisplayLink: displayLink != nil,
                isPaused: !isEnabled
            ))
        }
    }

    /// Runs the display link until its next refresh calls `onFrame`. Returns false when there is
    /// no clock to wait for, and the caller presents at once.
    func schedulePresentation() -> Bool {
        guard isEnabled, let displayLink else {
            return false
        }
        isPresentationPending = true
        displayLink.isPaused = false
        return true
    }

    /// Whether the display link waits for a refresh.
    var isDisplayLinkRunning: Bool {
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

    private func stopObservingWindow() {
        if let observedWindow {
            NotificationCenter.default.removeObserver(
                self,
                name: NSWindow.didChangeScreenNotification,
                object: observedWindow
            )
            NotificationCenter.default.removeObserver(
                self,
                name: NSApplication.didChangeScreenParametersNotification,
                object: nil
            )
        }
        observedWindow = nil
    }

    private func updateDisplayLinkPause() {
        displayLink?.isPaused = !(isEnabled && isPresentationPending)
    }

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
