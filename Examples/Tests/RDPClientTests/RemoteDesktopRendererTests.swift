import AppKit
@testable import RDPClient
import RDPKit
import RDPKitAppKit
import Testing

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

    canvas.update(frame: nil, hasPresentedFrame: false, emptyMessage: "", inputSession: nil, keyboard: .unitedStates, isConnecting: true)
    #expect(window.firstResponder === window)
    canvas.update(frame: frame, hasPresentedFrame: true, emptyMessage: "", inputSession: nil, keyboard: .unitedStates, isConnecting: true)

    #expect(window.firstResponder is RDPRemoteInputView)
}

private func graphicsFrame(width: UInt16, height: UInt16) -> RDPGraphicsFrameSnapshot {
    RDPGraphicsFrameSnapshot(
        frameID: nil,
        surfaceID: 0,
        codecID: 0,
        codecName: "test",
        pixelFormat: 0,
        destinationRect: RDPFrameRect(left: 0, top: 0, right: width, bottom: height),
        regionRects: [],
        encodedVideoData: Data()
    )
}

private func frameMetadata(width: UInt16, height: UInt16) -> RDPFrameMetadata {
    RDPFrameMetadata(graphicsFrame(width: width, height: height))
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

    canvas.update(frame: frame, hasPresentedFrame: true, emptyMessage: "", inputSession: nil, keyboard: .unitedStates, isConnecting: true)
    canvas.layoutSubtreeIfNeeded()

    let viewport = RDPRemoteDisplayViewport(frame: frame, bounds: canvas.bounds, coordinateOrigin: .bottomLeft)
    let desktop = canvas.displayView.frame
    let desktopPixels = canvas.convertToBacking(desktop)
    #expect(canvas.convertToBacking(viewport.contentRect).minX == 0.5)
    #expect(desktop.size == CGSize(width: 1000 / scale, height: 700 / scale))
    #expect(desktopPixels.minX == desktopPixels.minX.rounded())
    #expect(desktopPixels.minY == desktopPixels.minY.rounded())
    #expect(desktop == RDPRemoteDisplayViewport(frame: frame, view: canvas).contentRect)
    #expect(canvas.displayView.layer?.sublayers?.first?.frame == canvas.displayView.bounds)
    #expect(canvas.window === window)
}

private final class RecordedPointerInput: RDPInputEventSending {
    let supportsUnicodeInput = true
    var events: [RDPSlowPathInputEvent] = []

    func send(_ events: [RDPSlowPathInputEvent]) {
        self.events += events
    }
}

@MainActor
@Test func pointerInputMapsToTheDesktopWhereItIsDrawn() throws {
    let view = RDPRemoteInputView()
    let (window, scale) = placeOnePixelWiderThanTheDesktop(view)
    let input = RecordedPointerInput()
    view.inputSession = input
    let frame = frameMetadata(width: 1000, height: 700)
    view.rdpFrame = frame
    let desktop = RDPRemoteDisplayViewport(frame: frame, view: view).contentRect
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
    try move(to: CGPoint(x: desktop.midX, y: desktop.minY))
    #expect(input.events.isEmpty)
    // AppKit reports the mouse in the top pixel row at maxY, and in the bottom one above minY.
    try move(to: CGPoint(x: desktop.minX, y: desktop.maxY))
    try move(to: CGPoint(x: desktop.maxX - quarterPixel, y: desktop.minY + quarterPixel))
    #expect(input.events == [.pointerMove(x: 0, y: 0), .pointerMove(x: 999, y: 699)])
    #expect(view.window === window)
}

/// A drag past the letterbox goes to the desktop's nearest edge, its bottom row included.
@MainActor
@Test func pointerDragPastTheDesktopClampsToItsEdge() throws {
    let view = RDPRemoteInputView()
    let (window, _) = placeOnePixelWiderThanTheDesktop(view)
    let input = RecordedPointerInput()
    view.inputSession = input
    let frame = frameMetadata(width: 1000, height: 700)
    view.rdpFrame = frame
    let desktop = RDPRemoteDisplayViewport(frame: frame, view: view).contentRect
    func drag(to location: CGPoint) throws {
        view.mouseDragged(with: try #require(NSEvent.mouseEvent(
            with: .leftMouseDragged,
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

    try drag(to: CGPoint(x: desktop.minX - 50, y: desktop.minY - 50))
    try drag(to: CGPoint(x: desktop.maxX + 50, y: desktop.maxY + 50))
    #expect(input.events == [.pointerMove(x: 0, y: 699), .pointerMove(x: 999, y: 0)])
    #expect(view.window === window)
}
