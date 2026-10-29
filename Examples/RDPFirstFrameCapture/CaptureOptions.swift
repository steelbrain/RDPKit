import Foundation
import RDPCommandLineSupport
import RDPKit

struct FirstFrameCaptureOptions: Equatable {
    var connection = RDPCommandLineConnectionOptions(timeoutSeconds: 30)
    var settleSeconds = 30
    var outputPath: String?
    var transcriptPath: String?

    static func parse(_ arguments: [String]) throws -> FirstFrameCaptureOptions {
        var options = FirstFrameCaptureOptions()
        var cursor = RDPCommandLineArguments(arguments)
        while let option = cursor.nextOption() {
            if try options.connection.parse(option, from: &cursor) {
                continue
            }
            switch option {
            case "--settle-seconds":
                options.settleSeconds = try cursor.positiveInteger(for: option)
            case "--output":
                options.outputPath = try cursor.value(for: option)
            case "--capture-transcript":
                options.transcriptPath = try cursor.value(for: option)
            default:
                throw RDPCommandLineError.unknownOption(option)
            }
        }
        return options
    }

    func requiredOutputPath() throws -> String {
        guard let outputPath, outputPath.isEmpty == false else {
            throw RDPCommandLineError.missingRequiredOption("--output")
        }
        return outputPath
    }

    /// A live session with no frame limit: a capture limit would end it after that many
    /// frames, seconds into the settle window on a server that sends 30 a second.
    func configuration(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> RDPConnectionConfiguration {
        try connection.configuration(
            credentials: connection.credentials(environment: environment),
            graphicsFrameCaptureLimit: nil,
            clipboardEnabled: false
        )
    }
}

enum FirstFrameCaptureError: Error, CustomStringConvertible {
    case connectionFailed(String)
    case missingFrames
    case noDecodableFrames(String)
    case outputDirectoryFailed(String, String)
    case imageDestinationFailed(String)
    case imageWriteFailed(String)

    var description: String {
        switch self {
        case let .connectionFailed(message):
            message
        case .missingFrames:
            "connection did not produce RDPGFX video frame snapshots"
        case let .noDecodableFrames(message):
            "connection produced video frame snapshots, but none decoded: \(message)"
        case let .outputDirectoryFailed(directory, reason):
            "could not create output directory \(directory): \(reason)"
        case let .imageDestinationFailed(path):
            "could not create PNG image destination at \(path)"
        case let .imageWriteFailed(path):
            "could not write PNG image to \(path)"
        }
    }
}

/// Collects results from the decode queue's thread; the main thread reads them after the session.
final class LatestDecodedFrameRecorder<Value>: @unchecked Sendable {
    struct Snapshot {
        var decodedFrameCount = 0
        var latest: Value?
        var lastFailure: String?
    }

    private let lock = NSLock()
    private var state = Snapshot()

    var snapshot: Snapshot {
        lock.withLock { state }
    }

    func recordDecoded(_ value: Value) {
        lock.withLock {
            state.decodedFrameCount += 1
            state.latest = value
        }
    }

    func recordFailure(_ description: String) {
        lock.withLock {
            state.lastFailure = description
        }
    }
}
