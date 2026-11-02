import AppKit
import AVFoundation
import QuartzCore
import RDPKit
import RDPKitAppKit

@MainActor
final class RDPRemoteDesktopRenderer {
    private weak var view: RDPRemoteDesktopVideoView?
    private var latestPresentation: (presentation: RDPDecodedFramePresentation, id: Int)?

    func attach(_ view: RDPRemoteDesktopVideoView) {
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
