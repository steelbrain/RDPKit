import Foundation
import RDPKit

public struct RDPFirstFrameCaptureArguments: Equatable {
    public var host: String?
    public var port: UInt16
    public var username: String?
    public var domain: String?
    public var passwordEnv: String?
    public var timeoutSeconds: Int
    public var settleSeconds: Int
    public var desktopWidth: UInt16
    public var desktopHeight: UInt16
    public var graphicsCapabilityProfile: RDPGraphicsCapabilityProfile
    public var hideCertificateWarnings: Bool
    public var outputPath: String?
    public var transcriptPath: String?

    public init(
        host: String? = nil,
        port: UInt16 = 3389,
        username: String? = nil,
        domain: String? = nil,
        passwordEnv: String? = nil,
        timeoutSeconds: Int = 30,
        settleSeconds: Int = 30,
        desktopWidth: UInt16 = 1280,
        desktopHeight: UInt16 = 720,
        graphicsCapabilityProfile: RDPGraphicsCapabilityProfile = .automatic,
        hideCertificateWarnings: Bool = false,
        outputPath: String? = nil,
        transcriptPath: String? = nil
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.domain = domain
        self.passwordEnv = passwordEnv
        self.timeoutSeconds = timeoutSeconds
        self.settleSeconds = settleSeconds
        self.desktopWidth = desktopWidth
        self.desktopHeight = desktopHeight
        self.graphicsCapabilityProfile = graphicsCapabilityProfile
        self.hideCertificateWarnings = hideCertificateWarnings
        self.outputPath = outputPath
        self.transcriptPath = transcriptPath
    }
}

public enum RDPFirstFrameCaptureError: Error, CustomStringConvertible, Equatable {
    public static let maximumFrameCaptureLimit = 120

    case missingValue(String)
    case missingHost
    case missingOutput
    case missingCredential(String)
    case missingPasswordEnv(String)
    case invalidPort(String)
    case invalidTimeout(String)
    case invalidSettle(String)
    case invalidDesktopWidth(String)
    case invalidDesktopHeight(String)
    case invalidGraphicsProfile(String)
    case connectionFailed(String)
    case missingFrames
    case noDecodableFrames(String)
    case outputDirectoryFailed(String, String)
    case imageDestinationFailed(String)
    case imageWriteFailed(String)

    public var description: String {
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
        case let .invalidSettle(value):
            "invalid --settle-seconds \(value)"
        case let .invalidDesktopWidth(value):
            "invalid --desktop-width \(value); expected 640...8192"
        case let .invalidDesktopHeight(value):
            "invalid --desktop-height \(value); expected 480...8192"
        case let .invalidGraphicsProfile(value):
            "invalid --graphics-profile \(value)"
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

public enum RDPFirstFrameCaptureArgumentParser {
    public static func parse(_ values: [String]) throws -> RDPFirstFrameCaptureArguments {
        var args = RDPFirstFrameCaptureArguments()
        var index = 1

        while index < values.count {
            let value = values[index]
            switch value {
            case "--host":
                index += 1
                guard index < values.count else { throw RDPFirstFrameCaptureError.missingValue(value) }
                args.host = values[index]
            case "--port":
                index += 1
                guard index < values.count else { throw RDPFirstFrameCaptureError.missingValue(value) }
                guard let port = UInt16(values[index]) else {
                    throw RDPFirstFrameCaptureError.invalidPort(values[index])
                }
                args.port = port
            case "--username":
                index += 1
                guard index < values.count else { throw RDPFirstFrameCaptureError.missingValue(value) }
                args.username = values[index]
            case "--domain":
                index += 1
                guard index < values.count else { throw RDPFirstFrameCaptureError.missingValue(value) }
                args.domain = values[index]
            case "--password-env":
                index += 1
                guard index < values.count else { throw RDPFirstFrameCaptureError.missingValue(value) }
                args.passwordEnv = values[index]
            case "--timeout-seconds":
                index += 1
                guard index < values.count else { throw RDPFirstFrameCaptureError.missingValue(value) }
                guard let timeout = Int(values[index]), timeout > 0 else {
                    throw RDPFirstFrameCaptureError.invalidTimeout(values[index])
                }
                args.timeoutSeconds = timeout
            case "--settle-seconds":
                index += 1
                guard index < values.count else { throw RDPFirstFrameCaptureError.missingValue(value) }
                guard let settleSeconds = Int(values[index]), settleSeconds > 0 else {
                    throw RDPFirstFrameCaptureError.invalidSettle(values[index])
                }
                args.settleSeconds = settleSeconds
            case "--desktop-width":
                index += 1
                guard index < values.count else { throw RDPFirstFrameCaptureError.missingValue(value) }
                guard let width = UInt16(values[index]), (640 ... 8192).contains(width) else {
                    throw RDPFirstFrameCaptureError.invalidDesktopWidth(values[index])
                }
                args.desktopWidth = width
            case "--desktop-height":
                index += 1
                guard index < values.count else { throw RDPFirstFrameCaptureError.missingValue(value) }
                guard let height = UInt16(values[index]), (480 ... 8192).contains(height) else {
                    throw RDPFirstFrameCaptureError.invalidDesktopHeight(values[index])
                }
                args.desktopHeight = height
            case "--graphics-profile":
                index += 1
                guard index < values.count else { throw RDPFirstFrameCaptureError.missingValue(value) }
                guard let profile = RDPGraphicsCapabilityProfile(rawValue: values[index]) else {
                    throw RDPFirstFrameCaptureError.invalidGraphicsProfile(values[index])
                }
                args.graphicsCapabilityProfile = profile
            case "--hide-certificate-warnings":
                args.hideCertificateWarnings = true
            case "--output":
                index += 1
                guard index < values.count else { throw RDPFirstFrameCaptureError.missingValue(value) }
                args.outputPath = values[index]
            case "--capture-transcript":
                index += 1
                guard index < values.count else { throw RDPFirstFrameCaptureError.missingValue(value) }
                args.transcriptPath = values[index]
            default:
                throw RDPFirstFrameCaptureError.missingValue("unknown option \(value)")
            }
            index += 1
        }

        return args
    }

    public static func requiredHost(_ args: RDPFirstFrameCaptureArguments) throws -> String {
        guard let host = args.host, !host.isEmpty else {
            throw RDPFirstFrameCaptureError.missingHost
        }
        return host
    }

    public static func requiredOutputPath(_ args: RDPFirstFrameCaptureArguments) throws -> String {
        guard let outputPath = args.outputPath, !outputPath.isEmpty else {
            throw RDPFirstFrameCaptureError.missingOutput
        }
        return outputPath
    }
}

public struct RDPLatestCapture<Value> {
    public private(set) var decodedFrameCount: Int
    public private(set) var latest: Value?

    public init() {
        decodedFrameCount = 0
        latest = nil
    }

    public mutating func record(_ value: Value) {
        decodedFrameCount += 1
        latest = value
    }
}
