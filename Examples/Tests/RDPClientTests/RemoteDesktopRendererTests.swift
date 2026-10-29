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

    canvas.update(frame: nil, hasPresentedFrame: false, emptyMessage: "", inputSession: nil, keyboardLayout: .unitedStates, isConnecting: true)
    #expect(window.firstResponder === window)
    canvas.update(frame: frame, hasPresentedFrame: true, emptyMessage: "", inputSession: nil, keyboardLayout: .unitedStates, isConnecting: true)

    #expect(window.firstResponder is RemoteInputCaptureNSView)
}

private func frameMetadata(width: UInt16, height: UInt16) -> RDPFrameMetadata {
    RDPFrameMetadata(RDPGraphicsFrameSnapshot(
        frameID: nil,
        surfaceID: 0,
        codecID: 0,
        codecName: "test",
        pixelFormat: 0,
        destinationRect: RDPFrameRect(left: 0, top: 0, right: width, bottom: height),
        regionRects: [],
        encodedVideoData: Data()
    ))
}

/// Places `view` one pixel wider than a 1000x700 desktop, whose width Display Control made even:
/// shown at 1:1, the desktop is centered half a pixel off.
@MainActor
private func placeOnePixelWiderThanTheDesktop(_ view: NSView) -> (window: NSWindow, scale: CGFloat) {
    _ = NSApplication.shared
    let window = NSWindow(
        contentRect: CGRect(x: 0, y: 0, width: 1100, height: 800),
        styleMask: [.titled],
        backing: .buffered,
        defer: true
    )
    let scale = window.backingScaleFactor
    view.frame = CGRect(x: 0, y: 0, width: 1001 / scale, height: 700 / scale)
    window.contentView?.addSubview(view)
    return (window, scale)
}

@MainActor
@Test func theDesktopIsDrawnOnWholePixelsWhenTheViewIsOnePixelWider() {
    let canvas = RemoteDesktopCanvasNSView()
    let (window, scale) = placeOnePixelWiderThanTheDesktop(canvas)
    let frame = frameMetadata(width: 1000, height: 700)

    canvas.update(frame: frame, hasPresentedFrame: true, emptyMessage: "", inputSession: nil, keyboardLayout: .unitedStates, isConnecting: true)
    canvas.layoutSubtreeIfNeeded()

    let viewport = RDPRemoteDisplayViewport(frame: frame, bounds: canvas.bounds, coordinateOrigin: .bottomLeft)
    let desktop = canvas.displayView.frame
    let desktopPixels = canvas.convertToBacking(desktop)
    #expect(canvas.convertToBacking(viewport.contentRect).minX == 0.5)
    #expect(desktop.size == CGSize(width: 1000 / scale, height: 700 / scale))
    #expect(desktopPixels.minX == desktopPixels.minX.rounded())
    #expect(desktopPixels.minY == desktopPixels.minY.rounded())
    #expect(desktop == canvas.backingAlignedDesktopRect(of: viewport))
    #expect(canvas.displayView.layer?.sublayers?.first?.frame == canvas.displayView.bounds)
    #expect(canvas.window === window)
}

private final class RecordedPointerInput: RDPInputEventSending {
    var events: [RDPSlowPathInputEvent] = []

    func send(_ events: [RDPSlowPathInputEvent]) {
        self.events += events
    }
}

@MainActor
@Test func pointerInputMapsToTheDesktopWhereItIsDrawn() throws {
    let view = RemoteInputCaptureNSView()
    let (window, scale) = placeOnePixelWiderThanTheDesktop(view)
    let input = RecordedPointerInput()
    view.inputSession = input
    let frame = frameMetadata(width: 1000, height: 700)
    view.rdpFrame = frame
    let desktop = view.backingAlignedDesktopRect(
        of: RDPRemoteDisplayViewport(frame: frame, bounds: view.bounds, coordinateOrigin: .bottomLeft)
    )
    let quarterPixel = 0.25 / scale
    func move(to location: CGPoint) throws {
        view.mouseMoved(with: try #require(NSEvent.mouseEvent(
            with: .mouseMoved,
            location: location,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 0,
            pressure: 0
        )))
    }

    try move(to: CGPoint(x: desktop.minX - quarterPixel, y: desktop.midY))
    #expect(input.events.isEmpty)
    try move(to: CGPoint(x: desktop.minX, y: desktop.maxY - quarterPixel))
    try move(to: CGPoint(x: desktop.maxX - quarterPixel, y: desktop.minY))
    #expect(input.events == [.pointerMove(x: 0, y: 0), .pointerMove(x: 999, y: 699)])
    #expect(view.window === window)
}
