#if os(macOS)
import AppKit
import AVFoundation
import QuartzCore
import RDPKit

/// Where `RDPRemoteDesktopVideoView` lays out its video, in the view's coordinates.
public struct RDPRemoteDesktopVideoLayout: Equatable, Sendable {
    /// Where the video layer goes; the layer aspect-fits the frame into it.
    public var videoFrame: CGRect
    /// What the video is clipped to, such as the monitors a client shows; nil shows all of it.
    public var clipRect: CGRect?

    public init(videoFrame: CGRect, clipRect: CGRect? = nil) {
        self.videoFrame = videoFrame
        self.clipRect = clipRect
    }
}

/// Shows decoded frames through an `AVSampleBufferDisplayLayer`, letterboxed in the view unless
/// `videoLayout` places them. A change of format, a layer that failed to decode and one that
/// needs a flush to resume are flushed before the next frame, and a layer that fails between
/// frames shows the last one again once, since an idle remote desktop sends no new one. Moving
/// to a display of another scale changes the layer's scale without animating it. Layers added
/// to the view's own layer go above the video.
public final class RDPRemoteDesktopVideoView: NSView {
    /// Holds the display layer for good: moving a sample-buffer layer to another parent may drop
    /// the image it shows, which an idle remote desktop would never send again. Without a clip
    /// it is the view's size; with one it clips the video to it. A rectangular clip with no
    /// mask stays a cheap scissor, where a mask would render every frame through an offscreen
    /// pass.
    private let videoContainer = CALayer()
    private let displayLayer = AVSampleBufferDisplayLayer()
    let sampleBufferFactory = RDPFrameSampleBufferFactory()
    private var lastPresentationID: Int?
    /// Shown again when the layer fails between frames; an idle remote screen sends no new one.
    private var lastPresentation: RDPDecodedFramePresentation?
    private var didResendLastPresentation = false
    private var displayLayerObservers: [any NSObjectProtocol] = []

    /// Where the video goes, such as a frame of the whole desktop clipped to chosen monitors;
    /// nil letterboxes it in the view. Applied at once, without animation.
    public var videoLayout: RDPRemoteDesktopVideoLayout? {
        didSet {
            if videoLayout != oldValue {
                layOutVideo()
            }
        }
    }

    /// The part of each frame to show, such as one monitor of the desktop
    /// (`RDPFrameSampleBufferFactory.sourceRect`); nil shows the whole frame. A change shows
    /// the last frame again, cropped the new way.
    public var sourceRect: RDPFrameRect? {
        get {
            sampleBufferFactory.sourceRect
        }
        set {
            guard newValue != sampleBufferFactory.sourceRect else {
                return
            }
            sampleBufferFactory.sourceRect = newValue
            if let lastPresentation {
                _ = enqueue(lastPresentation)
            }
        }
    }

    override public init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureLayers()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureLayers()
    }

    deinit {
        MainActor.assumeIsolated {
            clear()
            displayLayerObservers.forEach(NotificationCenter.default.removeObserver)
        }
    }

    override public func layout() {
        super.layout()
        layOutVideo()
    }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateContentsScale()
    }

    override public func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            clear()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override public func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateContentsScale()
    }

    /// Shows `presentation`, unless the frame with `id` is already shown.
    public func present(_ presentation: RDPDecodedFramePresentation, id: Int) {
        guard lastPresentationID != id else {
            return
        }
        if enqueue(presentation) {
            lastPresentationID = id
            lastPresentation = presentation
            didResendLastPresentation = false
        }
    }

    /// Removes the shown image too, so a later session never flashes the last one's desktop
    /// and its pixel buffer is released.
    public func clear() {
        flushQueuedSamples(removingImage: true)
        lastPresentationID = nil
        lastPresentation = nil
        didResendLastPresentation = false
        sampleBufferFactory.reset()
    }

    private func layOutVideo() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let clipRect = videoLayout?.clipRect
        let containerFrame = clipRect ?? bounds
        videoContainer.masksToBounds = clipRect != nil
        videoContainer.frame = containerFrame
        displayLayer.frame = (videoLayout?.videoFrame ?? bounds).offsetBy(dx: -containerFrame.minX, dy: -containerFrame.minY)
        updateContentsScale()
        CATransaction.commit()
    }

    private func enqueue(_ presentation: RDPDecodedFramePresentation) -> Bool {
        let disposition = rdpSampleBufferDisplayDisposition(
            displayFormatWillChange: sampleBufferFactory.willChangeDisplayFormat(for: presentation),
            rendererFailed: rendererFailed,
            requiresFlushToResume: rendererRequiresFlushToResume
        )
        switch disposition {
        case .flushAndEnqueue:
            flushQueuedSamples()
        case .enqueue:
            break
        }

        do {
            try enqueueSampleBuffer(sampleBufferFactory.makeSampleBuffer(for: presentation))
            return true
        } catch {
            flushQueuedSamples()
            return false
        }
    }

    /// Shows the last frame again once, so a layer that failed or needs a flush does not stay
    /// blank until the remote screen changes.
    private func displayLayerNeedsRecovery() {
        guard rdpShouldResendLastPresentation(
            hasLastPresentation: lastPresentation != nil,
            didResendLastPresentation: didResendLastPresentation,
            rendererFailed: rendererFailed,
            requiresFlushToResume: rendererRequiresFlushToResume
        ),
            let lastPresentation
        else {
            return
        }
        didResendLastPresentation = true
        _ = enqueue(lastPresentation)
    }

    private func configureLayers() {
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        displayLayer.backgroundColor = NSColor.black.cgColor
        displayLayer.videoGravity = .resizeAspect
        videoContainer.addSublayer(displayLayer)
        layer?.addSublayer(videoContainer)
        updateContentsScale()
        observeDisplayLayer()
    }

    /// AVFoundation can post these on its own threads. The observer runs on the posting thread
    /// and only schedules the recovery on the main thread, so the post never waits for it.
    private func observeDisplayLayer() {
        let names: [NSNotification.Name]
        let object: AnyObject
        if #available(macOS 15, *) {
            names = [
                AVSampleBufferVideoRenderer.didFailToDecodeNotification,
                AVSampleBufferVideoRenderer.requiresFlushToResumeDecodingDidChangeNotification,
            ]
            object = displayLayer.sampleBufferRenderer
        } else {
            names = [
                .AVSampleBufferDisplayLayerFailedToDecode,
                .AVSampleBufferDisplayLayerRequiresFlushToResumeDecodingDidChange,
            ]
            object = displayLayer
        }
        displayLayerObservers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: object, queue: nil) { [weak self] _ in
                DispatchQueue.main.async {
                    self?.displayLayerNeedsRecovery()
                }
            }
        }
    }

    /// Without actions: the layer is no view's own, so nothing turns off its implicit animations,
    /// and moving to a display of another scale would animate the change.
    private func updateContentsScale() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        CATransaction.commit()
    }

    // macOS 15 deprecates the layer's own queue for its `sampleBufferRenderer`, which these use
    // there; macOS 13 and 14 keep the layer's calls.

    private var rendererFailed: Bool {
        if #available(macOS 15, *) {
            displayLayer.sampleBufferRenderer.status == .failed
        } else {
            displayLayer.status == .failed
        }
    }

    private var rendererRequiresFlushToResume: Bool {
        if #available(macOS 15, *) {
            displayLayer.sampleBufferRenderer.requiresFlushToResumeDecoding
        } else {
            displayLayer.requiresFlushToResumeDecoding
        }
    }

    private func enqueueSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        if #available(macOS 15, *) {
            displayLayer.sampleBufferRenderer.enqueue(sampleBuffer)
        } else {
            displayLayer.enqueue(sampleBuffer)
        }
    }

    private func flushQueuedSamples(removingImage: Bool = false) {
        if #available(macOS 15, *) {
            if removingImage {
                displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
            } else {
                displayLayer.sampleBufferRenderer.flush()
            }
        } else if removingImage {
            displayLayer.flushAndRemoveImage()
        } else {
            displayLayer.flush()
        }
    }
}

enum RDPRemoteDesktopSampleBufferDisplayDisposition: Equatable {
    case enqueue
    case flushAndEnqueue
}

func rdpSampleBufferDisplayDisposition(
    displayFormatWillChange: Bool,
    rendererFailed: Bool,
    requiresFlushToResume: Bool
) -> RDPRemoteDesktopSampleBufferDisplayDisposition {
    if displayFormatWillChange || rendererFailed || requiresFlushToResume {
        return .flushAndEnqueue
    }
    return .enqueue
}

/// Once per frame: a layer that fails again on the same frame waits for the next one rather than
/// retrying in a loop.
func rdpShouldResendLastPresentation(
    hasLastPresentation: Bool,
    didResendLastPresentation: Bool,
    rendererFailed: Bool,
    requiresFlushToResume: Bool
) -> Bool {
    hasLastPresentation && !didResendLastPresentation && (rendererFailed || requiresFlushToResume)
}
#endif
