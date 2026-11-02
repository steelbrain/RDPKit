#if os(macOS)
import AppKit
import AVFoundation
import RDPKit
@testable import RDPKitAppKit
import Testing

/// On macOS 15 and later frames go to the display layer's `sampleBufferRenderer`, before and
/// after the display is cleared.
@MainActor
@Test func framesRenderThroughTheDisplayLayersSampleBufferRenderer() throws {
    guard #available(macOS 15, *) else {
        return
    }
    let view = RDPRemoteDesktopVideoView(frame: CGRect(x: 0, y: 0, width: 64, height: 64))
    let renderer = view.displayLayer.sampleBufferRenderer
    var imageBuffer: CVPixelBuffer?
    #expect(CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32BGRA, nil, &imageBuffer) == kCVReturnSuccess)
    let presentation = try RDPDecodedFramePresentation(
        frame: graphicsFrame(width: 16, height: 16),
        imageBuffer: #require(imageBuffer)
    )
    #expect(renderer.status == .unknown)

    view.present(presentation, id: 1)
    #expect(renderer.status == .rendering)
    view.clear()
    view.present(presentation, id: 2)
    #expect(renderer.status == .rendering)
    #expect(renderer.error == nil)
}

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

@Test func aFailedLayerShowsTheLastFrameAgainOnce() {
    #expect(rdpShouldResendLastPresentation(
        hasLastPresentation: true,
        didResendLastPresentation: false,
        rendererFailed: true,
        requiresFlushToResume: false
    ))
    #expect(rdpShouldResendLastPresentation(
        hasLastPresentation: true,
        didResendLastPresentation: false,
        rendererFailed: false,
        requiresFlushToResume: true
    ))
    #expect(!rdpShouldResendLastPresentation(
        hasLastPresentation: true,
        didResendLastPresentation: true,
        rendererFailed: true,
        requiresFlushToResume: false
    ))
    #expect(!rdpShouldResendLastPresentation(
        hasLastPresentation: false,
        didResendLastPresentation: false,
        rendererFailed: true,
        requiresFlushToResume: true
    ))
    #expect(!rdpShouldResendLastPresentation(
        hasLastPresentation: true,
        didResendLastPresentation: false,
        rendererFailed: false,
        requiresFlushToResume: false
    ))
}

// An idle desktop leaves the display link paused; a frame that arrives runs it for one refresh.
@MainActor
@Test func thePresentationClockRunsOnlyWhileAFrameWaits() {
    _ = NSApplication.shared
    let window = NSWindow(
        contentRect: CGRect(x: 0, y: 0, width: 200, height: 200),
        styleMask: [.titled],
        backing: .buffered,
        defer: true
    )
    let clock = RDPFramePresentationClock()
    var refreshCount = 0
    clock.onFrame = { _ in refreshCount += 1 }
    func configure(isEnabled: Bool) {
        clock.isEnabled = isEnabled
    }
    defer {
        window.contentView = nil
    }

    configure(isEnabled: true)
    #expect(!clock.requestFrame())

    window.contentView = clock
    configure(isEnabled: false)
    #expect(!clock.requestFrame())
    #expect(!clock.isDisplayLinkRunning)

    configure(isEnabled: true)
    #expect(!clock.isDisplayLinkRunning)
    #expect(clock.requestFrame())
    #expect(clock.isDisplayLinkRunning)
    configure(isEnabled: true)
    #expect(clock.isDisplayLinkRunning)

    clock.displayLinkFired(window.displayLink(target: clock, selector: #selector(clock.displayLinkFired(_:))))
    #expect(refreshCount == 1)
    #expect(!clock.isDisplayLinkRunning)

    #expect(clock.requestFrame())
    #expect(clock.isDisplayLinkRunning)
    configure(isEnabled: false)
    #expect(!clock.isDisplayLinkRunning)
    configure(isEnabled: true)
    #expect(!clock.isDisplayLinkRunning)
}


/// Without a layout the video fills the view, letterboxed by the layer; a layout places the
/// layer and clips it, in the view's coordinates, and nil fills the view again. The display
/// layer stays in its container throughout, as moving it could drop the image it shows.
@MainActor
@Test func aVideoLayoutPlacesAndClipsTheVideo() throws {
    let view = RDPRemoteDesktopVideoView(frame: CGRect(x: 0, y: 0, width: 200, height: 100))
    view.layout()
    let displayLayer = view.displayLayer
    let container = try #require(displayLayer.superlayer)
    #expect(container.superlayer === view.layer)
    #expect(container.frame == CGRect(x: 0, y: 0, width: 200, height: 100))
    #expect(displayLayer.frame == CGRect(x: 0, y: 0, width: 200, height: 100))
    #expect(container.masksToBounds == false)

    view.videoLayout = RDPRemoteDesktopVideoLayout(
        videoFrame: CGRect(x: -100, y: 0, width: 400, height: 100),
        clipRect: CGRect(x: 20, y: 10, width: 160, height: 80)
    )
    #expect(container.frame == CGRect(x: 20, y: 10, width: 160, height: 80))
    #expect(container.masksToBounds)
    #expect(displayLayer.frame == CGRect(x: -120, y: -10, width: 400, height: 100))
    #expect(displayLayer.superlayer === container)

    view.videoLayout = RDPRemoteDesktopVideoLayout(videoFrame: CGRect(x: 10, y: 0, width: 180, height: 100))
    #expect(container.frame == CGRect(x: 0, y: 0, width: 200, height: 100))
    #expect(container.masksToBounds == false)
    #expect(displayLayer.frame == CGRect(x: 10, y: 0, width: 180, height: 100))

    view.videoLayout = nil
    #expect(displayLayer.frame == CGRect(x: 0, y: 0, width: 200, height: 100))
    #expect(displayLayer.superlayer === container)
    #expect(container.superlayer === view.layer)
}

/// A viewport's layout without a source rect is a layer the size of the view, moved as the
/// content rect moves onto a whole pixel, so the frame letterboxes in it right where the
/// content rect is; with a source rect it is the content rect.
@Test func aViewportsLayoutShowsTheDesktopOnAWholePixel() {
    // 1280x720 fits 1001x700 at 563.0625 high, 68.46875 up, which a 2x screen puts at 68.5.
    var viewport = RDPRemoteDisplayViewport(
        remotePixelSize: CGSize(width: 1280, height: 720),
        bounds: CGRect(x: 0, y: 0, width: 1001, height: 700),
        coordinateOrigin: .bottomLeft,
        backingScaleFactor: 2
    )
    #expect(viewport.contentRect.minY == 68.5)

    let whole = RDPRemoteDesktopVideoLayout(viewport: viewport)
    #expect(whole.clipRect == nil)
    #expect(whole.videoFrame == CGRect(x: 0, y: 0.03125, width: 1001, height: 700))
    let letterboxed = RDPRemoteDisplayViewport(
        remotePixelSize: viewport.remotePixelSize,
        bounds: whole.videoFrame,
        coordinateOrigin: .bottomLeft
    ).contentRect
    #expect(letterboxed == viewport.contentRect)

    viewport.sourceRect = CGRect(x: 0, y: 0, width: 640, height: 720)
    #expect(RDPRemoteDesktopVideoLayout(viewport: viewport) == RDPRemoteDesktopVideoLayout(videoFrame: viewport.contentRect))
}

/// Moving to a display of another scale changes the video's scale without animating it, once
/// the layers are on screen: layers not yet committed never animate.
@MainActor
@Test func aScaleChangeDoesNotAnimateTheVideo() {
    let window = ScaledWindow()
    window.scale = 2
    let view = RDPRemoteDesktopVideoView(frame: CGRect(x: 0, y: 0, width: 200, height: 100))
    window.contentView = view
    defer { window.contentView = nil }
    #expect(view.displayLayer.contentsScale == 2)
    CATransaction.flush()

    window.scale = 1
    view.viewDidChangeBackingProperties()
    #expect(view.displayLayer.contentsScale == 1)
    #expect(view.displayLayer.animationKeys() == nil)
}

/// `onFrame` can ask for the next refresh, and the display link keeps running for it.
@MainActor
@Test func onFrameCanRequestTheNextFrame() {
    let window = ScaledWindow()
    let clock = RDPFramePresentationClock()
    window.contentView = clock
    defer {
        clock.onFrame = nil
        window.contentView = nil
    }
    clock.isEnabled = true
    var refreshCount = 0
    clock.onFrame = { _ in
        refreshCount += 1
        if refreshCount == 1 {
            #expect(clock.requestFrame())
        }
    }
    let displayLink = window.displayLink(target: clock, selector: #selector(clock.displayLinkFired(_:)))

    #expect(clock.requestFrame())
    clock.displayLinkFired(displayLink)
    #expect(refreshCount == 1)
    #expect(clock.isDisplayLinkRunning)
    clock.displayLinkFired(displayLink)
    #expect(refreshCount == 2)
    #expect(!clock.isDisplayLinkRunning)
}

/// A window whose backing scale a test sets.
private final class ScaledWindow: NSWindow {
    var scale: CGFloat?

    convenience init() {
        self.init(
            contentRect: CGRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        isReleasedWhenClosed = false
    }

    override var backingScaleFactor: CGFloat {
        scale ?? super.backingScaleFactor
    }
}

/// A new source rect shows the last frame again, cropped the new way, since an idle desktop
/// sends no frame to show it with.
@MainActor
@Test func aNewSourceRectShowsTheLastFrameAgain() throws {
    let view = RDPRemoteDesktopVideoView(frame: CGRect(x: 0, y: 0, width: 64, height: 64))
    var imageBuffer: CVPixelBuffer?
    #expect(CVPixelBufferCreate(kCFAllocatorDefault, 32, 16, kCVPixelFormatType_32BGRA, nil, &imageBuffer) == kCVReturnSuccess)
    let presentation = try RDPDecodedFramePresentation(
        frame: graphicsFrame(width: 32, height: 16),
        imageBuffer: #require(imageBuffer)
    )
    view.present(presentation, id: 1)
    let left = RDPFrameRect(left: 0, top: 0, right: 16, bottom: 16)

    view.sourceRect = left
    #expect(view.sourceRect == left)
    #expect(view.sampleBufferFactory.willChangeDisplayFormat(for: presentation) == false)
    // With nothing shown there is nothing to show again.
    view.clear()
    view.sourceRect = nil
    #expect(view.sampleBufferFactory.willChangeDisplayFormat(for: presentation))
}

/// A frame that arrives while one waits replaces it, which counts as a skipped presentation.
@MainActor
@Test func thePresentationBufferHoldsTheLatestFrame() throws {
    var imageBuffer: CVPixelBuffer?
    #expect(CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32BGRA, nil, &imageBuffer) == kCVReturnSuccess)
    let first = try RDPDecodedFramePresentation(frame: graphicsFrame(width: 16, height: 16), imageBuffer: #require(imageBuffer))
    let second = try RDPDecodedFramePresentation(frame: graphicsFrame(width: 16, height: 8), imageBuffer: #require(imageBuffer))
    let buffer = RDPFramePresentationBuffer()

    #expect(buffer.takePendingPresentation() == nil)
    #expect(buffer.replacePendingPresentation(first) == false)
    #expect(buffer.replacePendingPresentation(second))
    #expect(buffer.takePendingPresentation()?.frame.destinationRect.bottom == 8)
    #expect(buffer.takePendingPresentation() == nil)
    #expect(buffer.replacePendingPresentation(first) == false)
    buffer.clear()
    #expect(buffer.takePendingPresentation() == nil)
}

/// A presentation of a `width` pixel wide frame, so tests tell frames apart by width.
private func presentation(width: UInt16) throws -> RDPDecodedFramePresentation {
    var imageBuffer: CVPixelBuffer?
    #expect(CVPixelBufferCreate(kCFAllocatorDefault, Int(width), 16, kCVPixelFormatType_32BGRA, nil, &imageBuffer) == kCVReturnSuccess)
    return try RDPDecodedFramePresentation(frame: graphicsFrame(width: width, height: 16), imageBuffer: #require(imageBuffer))
}

/// The first frame shows at once; later ones wait for the next refresh, which shows the last
/// to come, and publishes the display link's interval. A frame that came while one waited
/// replaced it.
@MainActor
@Test func aPresenterShowsTheFirstFrameAtOnceAndPacesTheRest() throws {
    let window = ScaledWindow()
    let videoView = RDPRemoteDesktopVideoView(frame: CGRect(x: 0, y: 0, width: 200, height: 100))
    let presenter = RDPFramePresenter(videoView: videoView)
    window.contentView = videoView
    videoView.addSubview(presenter.clockView)
    defer { window.contentView = nil }
    var shown: [UInt16] = []
    presenter.onShow = { shown.append($0.frame.width) }
    var timings: [RDPFramePacingState] = []
    presenter.onTimingChange = { timings.append($0) }

    #expect(try presenter.present(presentation(width: 16)) == .shown)
    #expect(shown == [16])
    #expect(try presenter.present(presentation(width: 24)) == .waiting)
    #expect(try presenter.present(presentation(width: 32)) == .replaced)
    #expect(shown == [16])
    #expect(presenter.clockView.isDisplayLinkRunning)

    let displayLink = window.displayLink(target: presenter.clockView, selector: #selector(RDPFramePresentationClock.displayLinkFired(_:)))
    presenter.clockView.displayLinkFired(displayLink)
    #expect(shown == [16, 32])
    #expect(timings.last?.displayLinkDuration == presenter.timing.displayLinkDuration)
    #expect(timings.last == presenter.timing)
    #expect(presenter.flush() == false)
}

/// Turning pacing off shows the frame waiting, and the ones after it at once; `flush()` shows
/// the frame waiting; `clear()` drops it, and the next frame is a first one again.
@MainActor
@Test func aPresenterFlushesAndClears() throws {
    let window = ScaledWindow()
    let videoView = RDPRemoteDesktopVideoView(frame: CGRect(x: 0, y: 0, width: 200, height: 100))
    let presenter = RDPFramePresenter(videoView: videoView)
    window.contentView = videoView
    videoView.addSubview(presenter.clockView)
    defer { window.contentView = nil }
    var shown: [UInt16] = []
    presenter.onShow = { shown.append($0.frame.width) }

    try presenter.present(presentation(width: 16))
    try presenter.present(presentation(width: 24))
    #expect(presenter.flush())
    #expect(shown == [16, 24])
    #expect(presenter.flush() == false)

    try presenter.present(presentation(width: 32))
    presenter.isPacing = false
    #expect(shown == [16, 24, 32])
    #expect(try presenter.present(presentation(width: 40)) == .shown)
    #expect(!presenter.clockView.isDisplayLinkRunning)

    presenter.isPacing = true
    #expect(try presenter.present(presentation(width: 48)) == .waiting)
    presenter.clear()
    #expect(presenter.flush() == false)
    #expect(try presenter.present(presentation(width: 56)) == .shown)
    #expect(shown == [16, 24, 32, 40, 56])
}

/// Without a window there is no display to wait for, so every frame shows at once.
@MainActor
@Test func aPresenterWithNoWindowShowsEveryFrame() throws {
    let presenter = RDPFramePresenter(videoView: RDPRemoteDesktopVideoView(frame: .zero))
    #expect(try presenter.present(presentation(width: 16)) == .shown)
    #expect(try presenter.present(presentation(width: 24)) == .shown)
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
#endif
