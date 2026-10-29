import AppKit
@testable import RDPClient
import Testing

/// A clock whose window went away moves to a new window observing screen changes once: its
/// weak window reference reads nil by then, which once left the old observer behind.
@MainActor
@Test func frameClockObservesScreenChangesOnceAfterItsWindowGoesAway() async throws {
    _ = NSApplication.shared
    let clock = RDPFramePresentationClockNSView(frame: .zero)
    let timings = PublishedTimings()
    weak var closedWindow: NSWindow?
    autoreleasepool {
        let window = clockWindow()
        window.contentView?.addSubview(clock)
        clock.configure(isEnabled: false, onFrame: { _ in }, onTimingChange: { _ in timings.count += 1 })
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
