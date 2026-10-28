import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import RDPCommandLineSupport
import RDPKit
import UniformTypeIdentifiers

private struct DecodedFrameSelection {
    var frame: RDPGraphicsFrameSnapshot
    var image: CGImage
}

private enum FirstFrameCapture {
    static func main() {
        if RDPCommandLineArguments.requestsHelp(CommandLine.arguments) {
            printUsage()
            exit(0)
        }
        do {
            let options = try FirstFrameCaptureOptions.parse(CommandLine.arguments)
            let outputPath = try options.requiredOutputPath()
            let configuration = try options.connection.configuration(
                credentials: options.connection.credentials(),
                graphicsFrameCaptureLimit: FirstFrameCaptureOptions.maximumFrameCaptureLimit,
                clipboardEnabled: false
            )

            let imageContext = CIContext()
            let recorder = LatestDecodedFrameRecorder<DecodedFrameSelection>()
            let cancellation = RDPConnectionCancellation()
            let decodeQueue = RDPFrameDecodeQueue(
                shouldCancel: { cancellation.isCancelled },
                onDecoded: { presentation, _, _, _ in
                    let image = CIImage(cvImageBuffer: presentation.imageBuffer)
                    guard let capturedImage = imageContext.createCGImage(image, from: image.extent) else {
                        recorder.recordFailure("could not convert the decoded frame to an image")
                        return
                    }
                    recorder.recordDecoded(DecodedFrameSelection(frame: presentation.frame, image: capturedImage))
                },
                onDecodeFailed: { _, errorDescription in
                    recorder.recordFailure(errorDescription)
                    fputs("decode failed: \(errorDescription)\n", stderr)
                }
            )
            let wireTranscript = options.transcriptPath.map { _ in RDPWireTranscript() }
            scheduleCancellation(cancellation, after: options.settleSeconds)
            let report = RDPClient().run(
                configuration: configuration,
                onGraphicsFrame: { frame in
                    // Freeze the transcript the moment video frames start flowing:
                    // it captures the whole negotiation up to, but not past, here.
                    wireTranscript?.stop()
                    try decodeQueue.submitAndWait(
                        frame,
                        receivedAt: Date(),
                        shouldContinue: { cancellation.isCancelled == false }
                    ).requireDecoded()
                },
                wireTranscript: wireTranscript,
                cancellation: cancellation
            )
            decodeQueue.cancel()

            if let transcriptPath = options.transcriptPath, let wireTranscript {
                try writeTranscript(wireTranscript, to: transcriptPath)
            }

            let capture = recorder.snapshot
            guard let selectedFrame = capture.latest else {
                throw missingDecodedFrameError(report: report, lastDecodeFailure: capture.lastFailure)
            }
            try writePNG(selectedFrame.image, to: outputPath)
            let frame = selectedFrame.frame
            print("""
            wrote \(outputPath)
            decoded frames: \(capture.decodedFrameCount)
            selected frame: latest after \(options.settleSeconds)s
            frame: \(frame.width)x\(frame.height) \(describeCodec(for: frame)) \(frame.payloadByteCount) bytes
            nal types: \(frame.videoNalUnitTypes.map(String.init).joined(separator: "/"))
            """)
            guard report.status == "success" || cancellation.isCancelled else {
                throw FirstFrameCaptureError.connectionFailed(report.error ?? "RDP connection failed at \(report.stage)")
            }
        } catch {
            fputs("\(String(describing: error))\n", stderr)
            printUsage()
            exit(1)
        }
    }

    private static func describeCodec(for frame: RDPGraphicsFrameSnapshot) -> String {
        frame.contentKind == .video
            ? "\(frame.codecName)/\(frame.videoCodec.displayName)"
            : frame.codecName
    }

    private static func scheduleCancellation(_ cancellation: RDPConnectionCancellation, after seconds: Int) {
        Thread.detachNewThread {
            Thread.sleep(forTimeInterval: TimeInterval(seconds))
            cancellation.cancel()
        }
    }

    private static func missingDecodedFrameError(report: RDPConnectionReport, lastDecodeFailure: String?) -> Error {
        guard report.status == "success" else {
            return FirstFrameCaptureError.connectionFailed(report.error ?? "RDP connection failed at \(report.stage)")
        }
        if report.nextStage == "rdp-session-ended" {
            let missing = report.rdpGraphicsChannelName == nil
                ? "opening the RDPGFX dynamic channel"
                : "producing an RDPGFX video frame"
            return FirstFrameCaptureError.connectionFailed(
                "remote session ended before \(missing)\(remoteTerminationSuffix(report))"
            )
        }
        if let lastDecodeFailure {
            return FirstFrameCaptureError.noDecodableFrames(lastDecodeFailure)
        }
        return FirstFrameCaptureError.missingFrames
    }

    private static func remoteTerminationSuffix(_ report: RDPConnectionReport) -> String {
        if let errorInfoName = report.rdpRemoteTerminationErrorInfoName {
            return " (\(errorInfoName))"
        }
        if let disconnectReasonName = report.rdpRemoteTerminationDisconnectReasonName {
            return " (\(disconnectReasonName))"
        }
        return ""
    }

    private static func writeTranscript(_ transcript: RDPWireTranscript, to path: String) throws {
        let url = URL(fileURLWithPath: path)
        try createOutputDirectory(for: url)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(transcript.events)
        try data.write(to: url)
        let serverEvents = transcript.events.filter { $0.direction == .serverToClient }.count
        print("wrote transcript \(path): \(transcript.events.count) events (\(serverEvents) server\u{2192}client)")
    }

    private static func writePNG(_ image: CGImage, to path: String) throws {
        let url = URL(fileURLWithPath: path)
        try createOutputDirectory(for: url)

        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw FirstFrameCaptureError.imageDestinationFailed(path)
        }

        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw FirstFrameCaptureError.imageWriteFailed(path)
        }
    }

    private static func createOutputDirectory(for url: URL) throws {
        let directory = url.deletingLastPathComponent()
        guard directory.path != "." else {
            return
        }

        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        } catch {
            throw FirstFrameCaptureError.outputDirectoryFailed(directory.path, String(describing: error))
        }
    }

    private static func printUsage() {
        print("""
        Usage: RDPFirstFrameCapture --host <host> --output <frame.png> [--port 3389] [--username <name>] [--domain <domain>] [--password-env <env>] [--timeout-seconds 30] [--settle-seconds 30] [--desktop-width 1280] [--desktop-height 720] [--graphics-profile automatic|avcThinClient|avc420|legacy] [--hide-certificate-warnings] [--capture-transcript <transcript.json>]

        Connects to an RDP host, decodes RDPGFX frames for --settle-seconds,
        and writes the latest decoded frame as a PNG.
        With --capture-transcript, also dumps the negotiation wire exchange (up to the
        first video frame) as JSON for use as a deterministic replay regression fixture.
        """)
    }
}

FirstFrameCapture.main()
