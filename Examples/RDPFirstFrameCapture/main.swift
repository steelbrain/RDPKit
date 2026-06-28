import CoreGraphics
import Foundation
import ImageIO
import RDPKit
import UniformTypeIdentifiers

private struct CaptureArguments {
    var host: String?
    var port: UInt16 = 3389
    var username: String?
    var domain: String?
    var passwordEnv: String?
    var timeoutSeconds: Int = 30
    var frames: Int = 1
    var graphicsCapabilityProfile: RDPGraphicsCapabilityProfile = .automatic
    var hideCertificateWarnings = false
    var outputPath: String?
    var transcriptPath: String?
}

private enum CaptureError: Error, CustomStringConvertible {
    case missingValue(String)
    case missingHost
    case missingOutput
    case missingCredential(String)
    case missingPasswordEnv(String)
    case invalidPort(String)
    case invalidTimeout(String)
    case invalidFrames(String)
    case invalidGraphicsProfile(String)
    case connectionFailed(String)
    case missingFrames
    case noDecodableFrames(String)
    case incompleteCapture(decoded: Int, requested: Int, lastError: String?)
    case outputDirectoryFailed(String, String)
    case imageDestinationFailed(String)
    case imageWriteFailed(String)

    var description: String {
        switch self {
        case let .missingValue(option):
            "missing value for \(option)"
        case .missingHost:
            "missing required --host"
        case .missingOutput:
            "missing required --output"
        case let .missingCredential(message):
            message
        case let .missingPasswordEnv(name):
            "password environment variable \(name) is not set or is empty"
        case let .invalidPort(value):
            "invalid --port \(value)"
        case let .invalidTimeout(value):
            "invalid --timeout-seconds \(value)"
        case let .invalidFrames(value):
            "invalid --frames \(value)"
        case let .invalidGraphicsProfile(value):
            "invalid --graphics-profile \(value)"
        case let .connectionFailed(message):
            message
        case .missingFrames:
            "connection did not produce RDPGFX video frame snapshots"
        case let .noDecodableFrames(message):
            "connection produced video frame snapshots, but none decoded: \(message)"
        case let .incompleteCapture(decoded, requested, lastError):
            if let lastError {
                "decoded \(decoded) of \(requested) requested frames; last decode error: \(lastError)"
            } else {
                "decoded \(decoded) of \(requested) requested frames"
            }
        case let .outputDirectoryFailed(directory, reason):
            "could not create output directory \(directory): \(reason)"
        case let .imageDestinationFailed(path):
            "could not create PNG image destination at \(path)"
        case let .imageWriteFailed(path):
            "could not write PNG image to \(path)"
        }
    }
}

private struct FirstFrameCapture {
    static func main() {
        do {
            let arguments = try parseArguments(CommandLine.arguments)
            let credentials = try loadCredentials(from: arguments)
            let outputPath = try requiredOutputPath(arguments)

            let decoder = RDPVideoToolboxFrameDecoder()
            let candidateFrameLimit = arguments.frames + max(3, arguments.frames)
            var decodedFrameCount = 0
            var decodeFailureCount = 0
            var lastDecodeError: Error?
            let cancellation = RDPConnectionCancellation()
            let wireTranscript = arguments.transcriptPath.map { _ in RDPWireTranscript() }
            let report = RDPPreflightClient().run(
                configuration: RDPConnectionConfiguration(
                    host: try requiredHost(arguments),
                    port: arguments.port,
                    credentials: credentials,
                    timeoutSeconds: arguments.timeoutSeconds,
                    hideCertificateWarnings: arguments.hideCertificateWarnings,
                    graphicsFrameCaptureLimit: candidateFrameLimit,
                    clipboardEnabled: false,
                    graphicsCapabilityProfile: arguments.graphicsCapabilityProfile
                ),
                onGraphicsFrame: { frame in
                    // Freeze the transcript the moment video frames start flowing:
                    // it captures the whole negotiation up to, but not past, here.
                    wireTranscript?.stop()
                    guard decodedFrameCount < arguments.frames else {
                        return
                    }
                    do {
                        try autoreleasepool {
                            let frameOutputPath = outputPathForFrame(
                                outputPath,
                                index: decodedFrameCount,
                                totalCount: arguments.frames
                            )
                            let decodedImage = try decoder.decode(frame)
                            let image = try RDPH264DecodedFrameImage.cropToDestinationRect(decodedImage, frame: frame)
                            try writePNG(image, to: frameOutputPath)
                            decodedFrameCount += 1
                            let codecDescription = codecDescription(for: frame)
                            print("""
                            wrote \(frameOutputPath)
                            frame: \(frame.width)x\(frame.height) \(codecDescription) \(frame.payloadByteCount) bytes
                            nal types: \(frame.videoNalUnitTypes.map(String.init).joined(separator: "/"))
                            """)
                            if decodedFrameCount >= arguments.frames {
                                cancellation.cancel()
                            }
                        }
                    } catch {
                        decodeFailureCount += 1
                        lastDecodeError = error
                        let codecDescription = codecDescription(for: frame)
                        fputs("""
                        decode failed: \(frame.width)x\(frame.height) \(codecDescription) \(frame.payloadByteCount) bytes
                        \(String(describing: error))
                        """, stderr)
                        fputs("\n", stderr)
                    }
                },
                wireTranscript: wireTranscript,
                cancellation: cancellation
            )

            if let transcriptPath = arguments.transcriptPath, let wireTranscript {
                try writeTranscript(wireTranscript, to: transcriptPath)
            }

            guard decodedFrameCount > 0 else {
                guard report.status == "success" else {
                    throw CaptureError.connectionFailed(report.error ?? "RDP preflight failed at \(report.stage)")
                }
                if decodeFailureCount > 0,
                   let lastDecodeError
                {
                    throw CaptureError.noDecodableFrames(String(describing: lastDecodeError))
                }
                throw CaptureError.missingFrames
            }
            guard decodedFrameCount >= arguments.frames else {
                throw CaptureError.incompleteCapture(
                    decoded: decodedFrameCount,
                    requested: arguments.frames,
                    lastError: lastDecodeError.map { String(describing: $0) }
                )
            }
            guard report.status == "success" || cancellation.isCancelled else {
                throw CaptureError.connectionFailed(report.error ?? "RDP preflight failed at \(report.stage)")
            }
        } catch {
            fputs("\(String(describing: error))\n", stderr)
            printUsage()
            exit(1)
        }
    }

    private static func codecDescription(for frame: RDPGraphicsFrameSnapshot) -> String {
        frame.contentKind == .video
            ? "\(frame.codecName)/\(frame.videoCodec.displayName)"
            : frame.codecName
    }

    private static func parseArguments(_ values: [String]) throws -> CaptureArguments {
        var args = CaptureArguments()
        var index = 1

        while index < values.count {
            let value = values[index]
            switch value {
            case "--host":
                index += 1
                guard index < values.count else { throw CaptureError.missingValue(value) }
                args.host = values[index]
            case "--port":
                index += 1
                guard index < values.count else { throw CaptureError.missingValue(value) }
                guard let port = UInt16(values[index]) else { throw CaptureError.invalidPort(values[index]) }
                args.port = port
            case "--username":
                index += 1
                guard index < values.count else { throw CaptureError.missingValue(value) }
                args.username = values[index]
            case "--domain":
                index += 1
                guard index < values.count else { throw CaptureError.missingValue(value) }
                args.domain = values[index]
            case "--password-env":
                index += 1
                guard index < values.count else { throw CaptureError.missingValue(value) }
                args.passwordEnv = values[index]
            case "--timeout-seconds":
                index += 1
                guard index < values.count else { throw CaptureError.missingValue(value) }
                guard let timeout = Int(values[index]), timeout > 0 else {
                    throw CaptureError.invalidTimeout(values[index])
                }
                args.timeoutSeconds = timeout
            case "--frames":
                index += 1
                guard index < values.count else { throw CaptureError.missingValue(value) }
                guard let frames = Int(values[index]), frames > 0 else {
                    throw CaptureError.invalidFrames(values[index])
                }
                args.frames = frames
            case "--graphics-profile":
                index += 1
                guard index < values.count else { throw CaptureError.missingValue(value) }
                guard let profile = RDPGraphicsCapabilityProfile(rawValue: values[index]) else {
                    throw CaptureError.invalidGraphicsProfile(values[index])
                }
                args.graphicsCapabilityProfile = profile
            case "--hide-certificate-warnings":
                args.hideCertificateWarnings = true
            case "--output":
                index += 1
                guard index < values.count else { throw CaptureError.missingValue(value) }
                args.outputPath = values[index]
            case "--capture-transcript":
                index += 1
                guard index < values.count else { throw CaptureError.missingValue(value) }
                args.transcriptPath = values[index]
            case "-h", "--help":
                printUsage()
                exit(0)
            default:
                throw CaptureError.missingValue("unknown option \(value)")
            }
            index += 1
        }

        return args
    }

    private static func requiredHost(_ args: CaptureArguments) throws -> String {
        guard let host = args.host, !host.isEmpty else {
            throw CaptureError.missingHost
        }
        return host
    }

    private static func requiredOutputPath(_ args: CaptureArguments) throws -> String {
        guard let outputPath = args.outputPath, !outputPath.isEmpty else {
            throw CaptureError.missingOutput
        }
        return outputPath
    }

    private static func loadCredentials(from args: CaptureArguments) throws -> RDPCredentials? {
        let hasAnyCredentialInput = args.username != nil || args.domain != nil || args.passwordEnv != nil
        guard hasAnyCredentialInput else {
            return nil
        }

        guard let username = args.username, !username.isEmpty else {
            throw CaptureError.missingCredential("--username is required when credentials are provided")
        }
        guard let passwordEnv = args.passwordEnv, !passwordEnv.isEmpty else {
            throw CaptureError.missingCredential("--password-env is required when credentials are provided")
        }
        guard let password = ProcessInfo.processInfo.environment[passwordEnv], !password.isEmpty else {
            throw CaptureError.missingPasswordEnv(passwordEnv)
        }

        return RDPCredentials(username: username, domain: args.domain, password: password)
    }

    private static func outputPathForFrame(_ path: String, index: Int, totalCount: Int) -> String {
        guard totalCount > 1 else {
            return path
        }

        let url = URL(fileURLWithPath: path)
        let directory = url.deletingLastPathComponent()
        let extensionName = url.pathExtension.isEmpty ? "png" : url.pathExtension
        let baseName = url.deletingPathExtension().lastPathComponent
        return directory
            .appendingPathComponent("\(baseName)-\(index + 1)")
            .appendingPathExtension(extensionName)
            .path
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
            throw CaptureError.imageDestinationFailed(path)
        }

        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw CaptureError.imageWriteFailed(path)
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
            throw CaptureError.outputDirectoryFailed(directory.path, String(describing: error))
        }
    }

    private static func printUsage() {
        print("""
        Usage: RDPFirstFrameCapture --host <host> --output <frame.png> [--port 3389] [--username <name>] [--domain <domain>] [--password-env <env>] [--timeout-seconds 30] [--frames 1] [--graphics-profile automatic|avcThinClient|avc420|legacy] [--hide-certificate-warnings] [--capture-transcript <transcript.json>]

        Connects to an RDP host, captures RDPGFX frames, decodes them, and writes PNGs.
        With --capture-transcript, also dumps the negotiation wire exchange (up to the
        first video frame) as JSON for use as a deterministic replay regression fixture.
        """)
    }
}

FirstFrameCapture.main()
