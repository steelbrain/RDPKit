#if os(macOS)
import AppKit
@testable import RDPKitAppKit
import Testing

/// These tests count the timings a clock publishes, and the first posts a screen change, which
/// every clock observes, so they run one at a time.
@Suite(.serialized)
@MainActor
struct FramePresentationClockPublishingTests {
    /// A clock whose window went away moves to a new window observing screen changes once: its
    /// weak window reference reads nil by then, which once left the old observer behind.
    @Test func frameClockObservesScreenChangesOnceAfterItsWindowGoesAway() async throws {
        _ = NSApplication.shared
        let clock = RDPFramePresentationClock(frame: .zero)
        let timings = PublishedTimings()
        weak var closedWindow: NSWindow?
        autoreleasepool {
            let window = clockWindow()
            window.contentView?.addSubview(clock)
            clock.onTimingChange = { _ in timings.count += 1 }
            closedWindow = window
        }
        try #require(closedWindow == nil)

        let window = clockWindow()
        window.contentView?.addSubview(clock)
        await drainMainQueue()
        let published = timings.count
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
        await drainMainQueue()

        #expect(timings.count == published + 1)
        clock.removeFromSuperview()
    }

    /// Turning the clock on or off publishes its state, for the diagnostics that show it.
    @Test func turningTheClockOnOrOffPublishesItsState() async throws {
        _ = NSApplication.shared
        let clock = RDPFramePresentationClock(frame: .zero)
        var states: [RDPFramePacingState] = []
        clock.onTimingChange = { states.append($0) }
        let window = clockWindow()
        window.contentView?.addSubview(clock)
        await drainMainQueue()
        #expect(states.last?.hasDisplayLink == true)
        #expect(states.last?.isDisplayLinkPaused == true)
        let published = states.count

        clock.isEnabled = true
        await drainMainQueue()
        #expect(states.count == published + 1)
        #expect(states.last?.isDisplayLinkPaused == false)
        #expect(states.last?.clockState == "window display link")

        clock.isEnabled = true
        clock.isEnabled = false
        await drainMainQueue()
        #expect(states.count == published + 2)
        #expect(states.last?.isDisplayLinkPaused == true)
        clock.removeFromSuperview()
    }
}

@MainActor
private final class PublishedTimings {
    var count = 0
}

@MainActor
private func clockWindow() -> NSWindow {
    let window = NSWindow(
        contentRect: CGRect(x: 0, y: 0, width: 200, height: 200),
        styleMask: [.titled],
        backing: .buffered,
        defer: true
    )
    window.isReleasedWhenClosed = false
    return window
}

/// Runs what the main queue holds, such as the clock's published timings.
@MainActor
private func drainMainQueue() async {
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async {
            continuation.resume()
        }
    }
}

@Test func framePacingStateNormalizesDisplayLinkTiming() {
    let state = RDPFramePacingState(
        screenName: "Studio Display",
        backingScaleFactor: 2,
        maximumFramesPerSecond: nil,
        minimumRefreshInterval: 1.0 / 120.0,
        maximumRefreshInterval: 1.0 / 48.0,
        displayUpdateGranularity: 0,
        displayLinkDuration: 0.0167,
        hasDisplayLink: true,
        isDisplayLinkPaused: false
    )

    #expect(state.displayLinkDuration == 1.0 / 60.0)
    #expect(state.displayLinkFramesPerSecond == 60)
    #expect(state.maximumRefreshRate == 120)
    #expect(state.clockState == "window display link")
}

@Test func framePacingStateMarksUpdatedDisplayLinkActive() {
    let state = RDPFramePacingState().updatingDisplayLinkDuration(1.0 / 120.0)

    #expect(state.hasDisplayLink)
    #expect(state.isDisplayLinkPaused == false)
    #expect(state.displayLinkFramesPerSecond == 120)
    #expect(state.clockState == "window display link")
}

/// Until the display link fires on a screen, its duration is 0 or the previous screen's, so the
/// clock shows the screen's maximum refresh rate instead.
@Test func framePacingStateShowsTheScreensMaximumUntilTheDisplayLinkFires() {
    let unfired = RDPFramePacingState(maximumFramesPerSecond: 120, hasDisplayLink: true)
    #expect(unfired.displayLinkFramesPerSecond == 120)
    #expect(RDPFramePacingState(minimumRefreshInterval: 1.0 / 60.0, hasDisplayLink: true).displayLinkFramesPerSecond == 60)
    #expect(RDPFramePacingState(maximumFramesPerSecond: 120).displayLinkFramesPerSecond == nil)

    // A 60 Hz link moved to a 120 Hz screen: its old duration is dropped until it fires there.
    let movedScreen = RDPFramePacingState(maximumFramesPerSecond: 120, displayLinkDuration: 1.0 / 60.0, hasDisplayLink: true)
        .updatingClock(displayLinkDuration: nil, hasDisplayLink: true, isPaused: true)
    #expect(movedScreen.displayLinkDuration == nil)
    #expect(movedScreen.displayLinkFramesPerSecond == 120)
    #expect(movedScreen.updatingDisplayLinkDuration(1.0 / 96.0).displayLinkFramesPerSecond == 96)
}

/// A session that showed no frame in time says whether the server sent none or RDPClient could
/// not show those it sent.
#endif
