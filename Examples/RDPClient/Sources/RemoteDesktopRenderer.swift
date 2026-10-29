import AppKit
import AVFoundation
import QuartzCore
import RDPKit

@MainActor
final class RDPRemoteDesktopRenderer {
    private weak var view: RemoteDesktopSampleBufferNSView?
    private var latestPresentation: (presentation: RDPDecodedFramePresentation, id: Int)?

    func attach(_ view: RemoteDesktopSampleBufferNSView) {
        guard self.view !== view else {
            return
        }
        self.view = view
        if let latestPresentation {
            view.present(latestPresentation.presentation, id: latestPresentation.id)
            self.latestPresentation = nil
        }
    }

    func present(_ presentation: RDPDecodedFramePresentation, id: Int) {
        guard let view else {
            latestPresentation = (presentation, id)
            return
        }
        latestPresentation = nil
        view.present(presentation, id: id)
    }

    func clear() {
        latestPresentation = nil
        view?.clear()
    }
}

final class RemoteDesktopSampleBufferNSView: NSView {
    private let displayLayer = AVSampleBufferDisplayLayer()
    private let sampleBufferFactory = RDPFrameSampleBufferFactory()
    private var lastPresentationID: Int?
    /// Shown again when the layer fails between frames; an idle remote screen sends no new one.
    private var lastPresentation: RDPDecodedFramePresentation?
    private var didResendLastPresentation = false
    private var displayLayerObservers: [any NSObjectProtocol] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureLayers()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureLayers()
    }

    deinit {
        MainActor.assumeIsolated {
            clear()
            displayLayerObservers.forEach(NotificationCenter.default.removeObserver)
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = bounds
        updateContentsScale()
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateContentsScale()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            clear()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateContentsScale()
    }

    func present(_ presentation: RDPDecodedFramePresentation, id: Int) {
        guard lastPresentationID != id else {
            return
        }
        if enqueue(presentation) {
            lastPresentationID = id
            lastPresentation = presentation
            didResendLastPresentation = false
        }
    }

    func clear() {
        displayLayer.flushAndRemoveImage()
        lastPresentationID = nil
        lastPresentation = nil
        didResendLastPresentation = false
        sampleBufferFactory.reset()
    }

    private func enqueue(_ presentation: RDPDecodedFramePresentation) -> Bool {
        let disposition = rdpSampleBufferDisplayDisposition(
            displayFormatWillChange: sampleBufferFactory.willChangeDisplayFormat(for: presentation),
            rendererFailed: displayLayer.status == .failed,
            requiresFlushToResume: displayLayer.requiresFlushToResumeDecoding
        )
        switch disposition {
        case .flushAndEnqueue:
            flushQueuedSamples()
        case .enqueue:
            break
        }

        do {
            let sampleBuffer = try sampleBufferFactory.makeSampleBuffer(for: presentation)
            displayLayer.enqueue(sampleBuffer)
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
            rendererFailed: displayLayer.status == .failed,
            requiresFlushToResume: displayLayer.requiresFlushToResumeDecoding
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
        layer?.addSublayer(displayLayer)
        updateContentsScale()
        observeDisplayLayer()
    }

    /// AVFoundation can post these on its own threads. The observer runs on the posting thread
    /// and only schedules the recovery on the main thread, so the post never waits for it.
    private func observeDisplayLayer() {
        displayLayerObservers = [
            NSNotification.Name.AVSampleBufferDisplayLayerFailedToDecode,
            .AVSampleBufferDisplayLayerRequiresFlushToResumeDecodingDidChange,
        ].map { name in
            NotificationCenter.default.addObserver(forName: name, object: displayLayer, queue: nil) { [weak self] _ in
                DispatchQueue.main.async {
                    self?.displayLayerNeedsRecovery()
                }
            }
        }
    }

    private func updateContentsScale() {
        displayLayer.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
    }

    private func flushQueuedSamples() {
        displayLayer.flush()
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

/// Holds the one decoded frame waiting for the next display-link tick.
@MainActor
final class RDPFramePresentationBuffer {
    private var pendingPresentation: RDPDecodedFramePresentation?

    func replacePendingPresentation(_ presentation: RDPDecodedFramePresentation) -> Bool {
        let replacedPendingPresentation = pendingPresentation != nil
        pendingPresentation = presentation
        return replacedPendingPresentation
    }

    func takePendingPresentation() -> RDPDecodedFramePresentation? {
        let presentation = pendingPresentation
        pendingPresentation = nil
        return presentation
    }

    func clear() {
        pendingPresentation = nil
    }
}

/// The report's first frame, decoded to show when a session ends before presenting one.
enum RDPReportFirstFrameDecodeResult: @unchecked Sendable {
    case decoded(
        presentation: RDPDecodedFramePresentation,
        receivedAt: Date,
        decodedAt: Date,
        timing: RDPFrameDecodeTiming
    )
    case failed(receivedAt: Date, errorDescription: String)
}

func decodeReportFirstFrame(_ frame: RDPGraphicsFrameSnapshot) -> RDPReportFirstFrameDecodeResult {
    autoreleasepool {
        let receivedAt = Date()
        do {
            let decodedFrame = try RDPVideoToolboxFrameDecoder().decodeDetailed(frame)
            let decodedAt = Date()
            return .decoded(
                presentation: RDPDecodedFramePresentation(frame: frame, imageBuffer: decodedFrame.imageBuffer),
                receivedAt: receivedAt,
                decodedAt: decodedAt,
                timing: RDPFrameDecodeTiming(
                    samplePreparationMilliseconds: decodedFrame.samplePreparationMilliseconds,
                    videoToolboxMilliseconds: decodedFrame.videoToolboxMilliseconds,
                    imageConversionMilliseconds: decodedFrame.imageConversionMilliseconds,
                    totalMilliseconds: decodedAt.timeIntervalSince(receivedAt) * 1000,
                    decodedPixelFormat: decodedFrame.decodedPixelFormat,
                    usesHardwareAcceleration: decodedFrame.usesHardwareAcceleration
                )
            )
        } catch {
            return .failed(receivedAt: receivedAt, errorDescription: String(describing: error))
        }
    }
}
