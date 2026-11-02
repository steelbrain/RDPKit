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
    let renderer = try #require(view.layer?.sublayers?.first?.sublayers?.first as? AVSampleBufferDisplayLayer).sampleBufferRenderer
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
/// layer and clips it, in the view's coordinates, and nil fills the view again.
@MainActor
@Test func aVideoLayoutPlacesAndClipsTheVideo() throws {
    let view = RDPRemoteDesktopVideoView(frame: CGRect(x: 0, y: 0, width: 200, height: 100))
    view.layout()
    let container = try #require(view.layer?.sublayers?.first)
    let displayLayer = try #require(container.sublayers?.first as? AVSampleBufferDisplayLayer)
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

    view.videoLayout = RDPRemoteDesktopVideoLayout(videoFrame: CGRect(x: 10, y: 0, width: 180, height: 100))
    #expect(container.frame == CGRect(x: 0, y: 0, width: 200, height: 100))
    #expect(container.masksToBounds == false)
    #expect(displayLayer.frame == CGRect(x: 10, y: 0, width: 180, height: 100))

    view.videoLayout = nil
    #expect(displayLayer.frame == CGRect(x: 0, y: 0, width: 200, height: 100))
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
