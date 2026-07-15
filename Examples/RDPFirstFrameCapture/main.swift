import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import RDPFirstFrameCaptureSupport
import RDPKit
import UniformTypeIdentifiers

private struct FirstFrameCapture {
    static func main() {
        do {
            if CommandLine.arguments.dropFirst().contains(where: { $0 == "-h" || $0 == "--help" }) {
                printUsage()
                exit(0)
            }
            let arguments = try RDPFirstFrameCaptureArgumentParser.parse(CommandLine.arguments)
            let credentials = try loadCredentials(from: arguments)
            let outputPath = try RDPFirstFrameCaptureArgumentParser.requiredOutputPath(arguments)

            let imageContext = CIContext()
            var decodeFailureCount = 0
            var lastDecodeError: Error?
            var latestCapture = RDPLatestCapture<DecodedFrameSelection>()
            let cancellation = RDPConnectionCancellation()
            let decodeQueue = RDPLatestFrameDecodeQueue(
                shouldCancel: { cancellation.isCancelled },
                onDecoded: { presentation, _, _, _ in
                    let image = CIImage(cvImageBuffer: presentation.imageBuffer)
                    guard let capturedImage = imageContext.createCGImage(image, from: image.extent) else {
                        decodeFailureCount += 1
                        lastDecodeError = RDPFirstFrameCaptureError.imageDestinationFailed(outputPath)
                        return
                    }
                    latestCapture.record(DecodedFrameSelection(
                        frame: presentation.frame,
                        image: capturedImage
                    ))
                },
                onDecodeFailed: { _, errorDescription in
                    decodeFailureCount += 1
                    lastDecodeError = RDPFirstFrameCaptureError.noDecodableFrames(errorDescription)
                    fputs("decode failed: \(errorDescription)\n", stderr)
                },
                onSkippedFrames: { _, _ in }
            )
            let wireTranscript = arguments.transcriptPath.map { _ in RDPWireTranscript() }
            scheduleCancellation(
                cancellation,
                after: arguments.settleSeconds
            )
            let report = RDPPreflightClient().run(
                configuration: RDPConnectionConfiguration(
                    host: try RDPFirstFrameCaptureArgumentParser.requiredHost(arguments),
                    port: arguments.port,
                    credentials: credentials,
                    timeoutSeconds: arguments.timeoutSeconds,
                    hideCertificateWarnings: arguments.hideCertificateWarnings,
                    graphicsFrameCaptureLimit: RDPFirstFrameCaptureError.maximumFrameCaptureLimit,
                    desktopWidth: arguments.desktopWidth,
                    desktopHeight: arguments.desktopHeight,
                    clipboardEnabled: false,
                    graphicsCapabilityProfile: arguments.graphicsCapabilityProfile
                ),
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

            if let transcriptPath = arguments.transcriptPath, let wireTranscript {
                try writeTranscript(wireTranscript, to: transcriptPath)
            }

            let selectedFrame = try requireDecodedFrame(
                latestCapture: latestCapture,
                report: report,
                decodeFailureCount: decodeFailureCount,
                lastDecodeError: lastDecodeError
            )
            try writePNG(selectedFrame.image, to: outputPath)
            let frameCodecDescription = describeCodec(for: selectedFrame.frame)
            print("""
            wrote \(outputPath)
            decoded frames: \(latestCapture.decodedFrameCount)
            selected frame: latest after \(arguments.settleSeconds)s
            frame: \(selectedFrame.frame.width)x\(selectedFrame.frame.height) \(frameCodecDescription) \(selectedFrame.frame.payloadByteCount) bytes
            nal types: \(selectedFrame.frame.videoNalUnitTypes.map(String.init).joined(separator: "/"))
            """)
            guard report.status == "success" || cancellation.isCancelled else {
                throw RDPFirstFrameCaptureError.connectionFailed(report.error ?? "RDP preflight failed at \(report.stage)")
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

    private static func requireDecodedFrame(
        latestCapture: RDPLatestCapture<DecodedFrameSelection>,
        report: RDPPreflightReport,
        decodeFailureCount: Int,
        lastDecodeError: Error?
    ) throws -> DecodedFrameSelection {
        if let selected = latestCapture.latest {
            return selected
        }
        try handleMissingDecodedFrame(
            report: report,
            decodeFailureCount: decodeFailureCount,
            lastDecodeError: lastDecodeError
        )
    }

    private static func handleMissingDecodedFrame(
        report: RDPPreflightReport,
        decodeFailureCount: Int,
        lastDecodeError: Error?
    ) throws -> Never {
        guard report.status == "success" else {
            throw RDPFirstFrameCaptureError.connectionFailed(report.error ?? "RDP preflight failed at \(report.stage)")
        }
        if report.nextStage == "rdp-session-ended", report.rdpGraphicsChannelName == nil {
            let suffix = remoteTerminationSuffix(report)
            throw RDPFirstFrameCaptureError.connectionFailed(
                "remote session ended before opening the RDPGFX dynamic channel\(suffix)"
            )
        }
        if report.nextStage == "rdp-session-ended" {
            let suffix = remoteTerminationSuffix(report)
            throw RDPFirstFrameCaptureError.connectionFailed(
                "remote session ended before producing an RDPGFX video frame\(suffix)"
            )
        }
        if decodeFailureCount > 0,
           let lastDecodeError
        {
            throw RDPFirstFrameCaptureError.noDecodableFrames(String(describing: lastDecodeError))
        }
        throw RDPFirstFrameCaptureError.missingFrames
    }

    private static func remoteTerminationSuffix(_ report: RDPPreflightReport) -> String {
        if let errorInfoName = report.rdpRemoteTerminationErrorInfoName {
            return " (\(errorInfoName))"
        }
        if let disconnectReasonName = report.rdpRemoteTerminationDisconnectReasonName {
            return " (\(disconnectReasonName))"
        }
        return ""
    }

    private static func loadCredentials(from args: RDPFirstFrameCaptureArguments) throws -> RDPCredentials? {
        let hasAnyCredentialInput = args.username != nil || args.domain != nil || args.passwordEnv != nil
        guard hasAnyCredentialInput else {
            return nil
        }

        guard let username = args.username, !username.isEmpty else {
            throw RDPFirstFrameCaptureError.missingCredential("--username is required when credentials are provided")
        }
        guard let passwordEnv = args.passwordEnv, !passwordEnv.isEmpty else {
            throw RDPFirstFrameCaptureError.missingCredential("--password-env is required when credentials are provided")
        }
        guard let password = ProcessInfo.processInfo.environment[passwordEnv], !password.isEmpty else {
            throw RDPFirstFrameCaptureError.missingPasswordEnv(passwordEnv)
        }

        return RDPCredentials(username: username, domain: args.domain, password: password)
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
            throw RDPFirstFrameCaptureError.imageDestinationFailed(path)
        }

        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw RDPFirstFrameCaptureError.imageWriteFailed(path)
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
            throw RDPFirstFrameCaptureError.outputDirectoryFailed(directory.path, String(describing: error))
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

private struct DecodedFrameSelection {
    var frame: RDPGraphicsFrameSnapshot
    var image: CGImage
}

FirstFrameCapture.main()
