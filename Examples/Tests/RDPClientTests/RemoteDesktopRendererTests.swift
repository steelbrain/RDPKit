import AppKit
@testable import RDPClient
import RDPKit
import Testing

@Test
func unchangedHealthyDisplayEnqueuesWithoutFlushing() {
    let disposition = rdpSampleBufferDisplayDisposition(
        displayFormatWillChange: false,
        rendererFailed: false,
        requiresFlushToResume: false
    )

    #expect(disposition == .enqueue)
}

@Test(arguments: [
    (true, false, false),
    (false, true, false),
    (false, false, true),
])
func displayResetConditionsFlushBeforeEnqueue(
    displayFormatWillChange: Bool,
    rendererFailed: Bool,
    requiresFlushToResume: Bool
) {
    let disposition = rdpSampleBufferDisplayDisposition(
        displayFormatWillChange: displayFormatWillChange,
        rendererFailed: rendererFailed,
        requiresFlushToResume: requiresFlushToResume
    )

    #expect(disposition == .flushAndEnqueue)
}

@MainActor
@Test func keysGoToTheDesktopOnceItAppears() {
    _ = NSApplication.shared
    let window = NSWindow(
        contentRect: CGRect(x: 0, y: 0, width: 200, height: 200),
        styleMask: [.titled],
        backing: .buffered,
        defer: true
    )
    let canvas = RemoteDesktopCanvasNSView()
    window.contentView = canvas
    let frame = RDPFrameMetadata(RDPGraphicsFrameSnapshot(
        frameID: nil,
        surfaceID: 0,
        codecID: 0,
        codecName: "test",
        pixelFormat: 0,
        destinationRect: RDPFrameRect(left: 0, top: 0, right: 100, bottom: 100),
        regionRects: [],
        encodedVideoData: Data()
    ))

    canvas.update(frame: nil, hasPresentedFrame: false, emptyMessage: "", inputSession: nil, isConnecting: true)
    #expect(window.firstResponder === window)
    canvas.update(frame: frame, hasPresentedFrame: true, emptyMessage: "", inputSession: nil, isConnecting: true)

    #expect(window.firstResponder is RemoteInputCaptureNSView)
}
